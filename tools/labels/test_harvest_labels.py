"""Tests for harvest_labels.py. No network, no real store — everything here is
fixture-driven. The HTTP layer is faked via a callable matching the
(url) -> (status, headers, body_bytes) contract used by fetch_batch/harvest.
"""
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(__file__))

import harvest_labels as hl


def make_response(labels, status=200, headers=None):
    body = json.dumps({"labels": labels}).encode("utf-8")
    return status, (headers or {}), body


# --------------------------------------------------------------------------
# Batching
# --------------------------------------------------------------------------

def test_batching_covers_every_subject_exactly_once():
    subjects = ["s%d" % i for i in range(97)]
    batches = list(hl.iter_batches(subjects, 40))
    assert len(batches) == 3  # ceil(97/40) == 3
    seen = [s for batch in batches for s in batch]
    assert seen == subjects  # every subject exactly once, order preserved
    assert [len(b) for b in batches] == [40, 40, 17]


def test_batching_exact_multiple():
    subjects = list(range(80))
    batches = list(hl.iter_batches(subjects, 40))
    assert len(batches) == 2
    assert sum(len(b) for b in batches) == 80


def test_batching_empty():
    assert list(hl.iter_batches([], 40)) == []


# --------------------------------------------------------------------------
# fetch_batch: retries, 429/Retry-After, absent subjects
# --------------------------------------------------------------------------

def test_absent_subject_yields_no_rows_and_is_not_an_error():
    calls = []

    def http_get(url):
        calls.append(url)
        return make_response([])  # nobody in this batch has a label

    data = hl.fetch_batch(["did:plc:a", "did:plc:b"], http_get)
    assert data["labels"] == []
    assert len(calls) == 1


def test_neg_true_labels_are_retained():
    def http_get(url):
        return make_response([
            {"src": "did:plc:src1", "uri": "did:plc:subj1", "val": "!suspend",
             "cts": "2026-01-01T00:00:00Z", "neg": True},
        ])

    data = hl.fetch_batch(["did:plc:subj1"], http_get)
    assert data["labels"][0]["neg"] is True

    rec = hl.label_to_record(data["labels"][0], "account", "2026-08-10T00:00:00Z")
    assert rec["neg"] is True


def test_cts_preserved_verbatim():
    exact_cts = "2026-05-17T03:14:07.123Z"

    def http_get(url):
        return make_response([
            {"src": "did:plc:src1", "uri": "did:plc:subj1", "val": "spam",
             "cts": exact_cts, "neg": False},
        ])

    data = hl.fetch_batch(["did:plc:subj1"], http_get)
    rec = hl.label_to_record(data["labels"][0], "account", "2026-08-10T00:00:00Z")
    assert rec["cts"] == exact_cts


def test_429_with_retry_after_is_retried_not_dropped():
    calls = []
    sleeps = []

    def http_get(url):
        calls.append(url)
        if len(calls) == 1:
            return 429, {"Retry-After": "1.5"}, b""
        return make_response([
            {"src": "did:plc:src1", "uri": "did:plc:subj1", "val": "needs-review",
             "cts": "2026-01-01T00:00:00Z", "neg": False},
        ])

    data = hl.fetch_batch(["did:plc:subj1"], http_get, sleep_fn=sleeps.append)
    assert len(calls) == 2  # retried, not dropped
    assert data["labels"][0]["val"] == "needs-review"
    assert sleeps == [1.5]


def test_retryable_network_error_is_retried_with_backoff():
    calls = []
    sleeps = []

    def http_get(url):
        calls.append(url)
        if len(calls) < 3:
            raise hl.RetryableError("connection reset")
        return make_response([])

    data = hl.fetch_batch(["did:plc:x"], http_get, sleep_fn=sleeps.append)
    assert len(calls) == 3
    assert data["labels"] == []
    assert len(sleeps) == 2


def test_batch_raises_fetch_failed_after_exhausting_retries():
    def http_get(url):
        raise hl.RetryableError("always down")

    with pytest.raises(hl.FetchFailed):
        hl.fetch_batch(["did:plc:x"], http_get, max_retries=2, sleep_fn=lambda s: None)


def test_non_retryable_http_error_raises_fetch_failed():
    def http_get(url):
        return 500, {}, b"internal error"

    with pytest.raises(hl.FetchFailed):
        hl.fetch_batch(["did:plc:x"], http_get, max_retries=0, sleep_fn=lambda s: None)


# --------------------------------------------------------------------------
# harvest(): failure handling, non-zero-exit semantics, resume
# --------------------------------------------------------------------------

def test_a_failed_batch_increments_failure_count_and_does_not_abort_sweep():
    subjects = ["s%d" % i for i in range(80)]  # two batches of 40
    call_count = {"n": 0}

    def http_get(url):
        call_count["n"] += 1
        if call_count["n"] == 1:
            return 500, {}, b"boom"
        return make_response([
            {"src": "did:plc:src", "uri": "s79", "val": "spam", "cts": "c", "neg": False},
        ])

    stats = hl.harvest(subjects, "account", http_get, batch_size=40,
                        sleep_fn=lambda s: None, max_retries=0)

    assert stats["failed_batches"] == 1
    # the sweep kept going and processed the second batch despite the first failing
    assert stats["processed"] == 40
    assert stats["labels_found"] == 1


def test_run_status_partial_when_batch_failed(tmp_path):
    """Mirrors the CLI's completeness check: any failed batch -> partial -> exit 1."""
    subjects = ["s%d" % i for i in range(40)]

    def http_get(url):
        return 500, {}, b"boom"

    stats = hl.harvest(subjects, "account", http_get, batch_size=40,
                        sleep_fn=lambda s: None, max_retries=0)
    complete = (stats["failed_batches"] == 0) and (
        stats["processed"] + stats["skipped_resume"] == stats["requested"]
    )
    assert complete is False
    assert stats["failed_batches"] == 1


def test_resume_skips_already_processed_subjects():
    subjects = ["s0", "s1", "s2", "s3"]
    already_done = {"s0", "s1"}
    seen_batches = []

    def http_get(url):
        seen_batches.append(url)
        return make_response([])

    stats = hl.harvest(subjects, "account", http_get, batch_size=40,
                        sleep_fn=lambda s: None, already_done=already_done)

    assert stats["skipped_resume"] == 2
    assert stats["processed"] == 2
    # only s2/s3 were ever sent over the wire
    (sent_url,) = seen_batches
    assert "s0" not in sent_url and "s1" not in sent_url
    assert "s2" in sent_url and "s3" in sent_url


def test_progress_writer_records_marked_subjects_for_resume(tmp_path):
    progress_path = str(tmp_path / "progress.txt")
    writer = hl.ProgressWriter(progress_path)
    writer.mark(["a", "b"])
    writer.mark(["c"])
    writer.close()

    done = hl.load_progress(progress_path)
    assert done == {"a", "b", "c"}


def test_on_record_callback_fires_for_every_label_with_subject_type():
    records = []

    def http_get(url):
        return make_response([
            {"src": "s1", "uri": "did:plc:a", "val": "intolerant", "cts": "c1", "neg": False},
            {"src": "s2", "uri": "did:plc:b", "val": "spam", "cts": "c2", "neg": False},
        ])

    hl.harvest(["did:plc:a", "did:plc:b"], "post", http_get, batch_size=40,
               sleep_fn=lambda s: None, on_record=records.append)

    assert len(records) == 2
    assert all(r["subject_type"] == "post" for r in records)
    vals = {r["val"] for r in records}
    assert vals == {"intolerant", "spam"}


# --------------------------------------------------------------------------
# URL building
# --------------------------------------------------------------------------

def test_build_url_repeats_uripatterns_and_sets_limit():
    url = hl.build_url(["did:plc:a", "did:plc:b"], limit=250)
    assert url.startswith(hl.LABEL_ENDPOINT + "?")
    assert url.count("uriPatterns=") == 2
    assert "limit=250" in url
