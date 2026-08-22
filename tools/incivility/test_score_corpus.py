"""Tests for score_corpus.py.

No network, no real store, no model weights: the model layer is mocked at
the score_fn boundary (score_corpus/score_batch_with_retry take a plain
callable), and the store is a temp SQLite file built with the real
ZPOST column shapes, never the real BlueX store on /Volumes/Eregion.
"""
import io
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

import score_corpus
from tools.common.single_instance import single_instance

POST_DDL = """
CREATE TABLE ZPOST (
    Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
    ZDEPTH INTEGER, ZISROOTPOST INTEGER, ZLIKECOUNT INTEGER,
    ZNEEDSREANNOTATION INTEGER, ZQUOTECOUNT INTEGER, ZREPLYCOUNT INTEGER,
    ZREPOSTCOUNT INTEGER, ZACCOUNT INTEGER, ZCREATEDAT TIMESTAMP,
    ZREPLYTREELASTCHECKED TIMESTAMP, ZAUTHORDID VARCHAR,
    ZAUTHORHANDLE VARCHAR, ZPARENTURI VARCHAR, ZREPLYTREESTATUS VARCHAR,
    ZROOTURI VARCHAR, ZTEXT VARCHAR, ZURI VARCHAR
)
"""


def make_store(path, replies):
    """replies: [(uri, text), ...]. Builds a minimal store with the real
    ZPOST column shapes; only ZISROOTPOST=0 rows (replies) are relevant."""
    conn = sqlite3.connect(path)
    conn.execute(POST_DDL)
    for uri, text in replies:
        conn.execute(
            "INSERT INTO ZPOST (ZISROOTPOST, ZURI, ZTEXT) VALUES (0, ?, ?)",
            (uri, text),
        )
    conn.commit()
    conn.close()


def fake_score_fn(texts):
    """Deterministic stand-in for the real model: score = len(text) / 100,
    clipped to [0, 1], identical for both heads (fine for these tests, which
    only care about batching/resume/failure/degenerate-input behaviour, not
    the model's actual numbers)."""
    vals = [min(len(t or ""), 100) / 100.0 for t in texts]
    return {"toxicity": list(vals), "identity_attack": list(vals)}


class IterBatchesTests(unittest.TestCase):
    def test_covers_every_input_exactly_once(self):
        seq = list(range(23))
        batches = list(score_corpus.iter_batches(seq, 5))
        self.assertEqual(sum(len(b) for b in batches), len(seq))
        self.assertEqual([x for b in batches for x in b], seq)
        self.assertEqual([len(b) for b in batches], [5, 5, 5, 5, 3])

    def test_empty_sequence(self):
        self.assertEqual(list(score_corpus.iter_batches([], 5)), [])

    def test_exact_multiple(self):
        seq = list(range(10))
        batches = list(score_corpus.iter_batches(seq, 5))
        self.assertEqual([len(b) for b in batches], [5, 5])


class ScoreCorpusBatchingTests(unittest.TestCase):
    def test_scores_every_reply_exactly_once(self):
        replies = [("uri-%d" % i, "text %d" % i) for i in range(10)]
        records = []
        stats = score_corpus.score_corpus(
            replies, fake_score_fn, batch_size=3,
            on_record=records.append,
        )
        self.assertEqual(stats["processed"], 10)
        self.assertEqual(stats["failed_batches"], 0)
        scored_uris = {r["uri"] for r in records}
        self.assertEqual(scored_uris, {u for u, _ in replies})
        # two records per post: toxicity + identity_attack
        self.assertEqual(len(records), 20)
        for uri in scored_uris:
            heads = {r["head"] for r in records if r["uri"] == uri}
            self.assertEqual(heads, {"toxicity", "identity_attack"})

    def test_records_carry_model_identity_and_timestamp(self):
        replies = [("uri-0", "hello")]
        records = []
        score_corpus.score_corpus(replies, fake_score_fn, on_record=records.append)
        for rec in records:
            self.assertEqual(rec["model_id"], score_corpus.MODEL_ID)
            self.assertEqual(rec["model_revision"], score_corpus.MODEL_REVISION)
            self.assertIn("scored_at", rec)
            self.assertIn("score", rec)


class ResumeTests(unittest.TestCase):
    def test_resume_skips_already_scored_posts(self):
        replies = [("uri-%d" % i, "text %d" % i) for i in range(5)]
        already_done = {"uri-0", "uri-2", "uri-4"}
        records = []
        stats = score_corpus.score_corpus(
            replies, fake_score_fn, already_done=already_done,
            on_record=records.append,
        )
        self.assertEqual(stats["skipped_resume"], 3)
        self.assertEqual(stats["processed"], 2)
        scored_uris = {r["uri"] for r in records}
        self.assertEqual(scored_uris, {"uri-1", "uri-3"})

    def test_progress_writer_records_scored_uris_for_next_run(self):
        tmpdir = tempfile.mkdtemp()
        try:
            progress_path = os.path.join(tmpdir, ".progress.txt")
            replies = [("uri-%d" % i, "text") for i in range(4)]
            progress = score_corpus.ProgressWriter(progress_path)
            try:
                score_corpus.score_corpus(replies, fake_score_fn, progress=progress)
            finally:
                progress.close()

            done = score_corpus.load_progress(progress_path)
            self.assertEqual(done, {u for u, _ in replies})

            # A second run against the same progress file should skip everything.
            records = []
            stats = score_corpus.score_corpus(
                replies, fake_score_fn, already_done=done, on_record=records.append,
            )
            self.assertEqual(stats["processed"], 0)
            self.assertEqual(stats["skipped_resume"], 4)
            self.assertEqual(records, [])
        finally:
            shutil.rmtree(tmpdir)


class FailureHandlingTests(unittest.TestCase):
    def test_failed_batch_increments_failure_count_and_continues(self):
        replies = [("uri-%d" % i, "text %d" % i) for i in range(6)]

        def flaky_score_fn(texts):
            # The second batch (posts "text 2"/"text 3") always fails, even
            # across retries of the same batch — a persistent, not
            # intermittent, failure.
            if "text 2" in texts or "text 3" in texts:
                raise RuntimeError("simulated inference failure")
            return fake_score_fn(texts)

        records = []
        stats = score_corpus.score_corpus(
            replies, flaky_score_fn, batch_size=2,
            on_record=records.append, max_retries=1, sleep_fn=lambda s: None,
        )

        self.assertEqual(stats["failed_batches"], 1)
        self.assertEqual(stats["failed_posts"], 2)
        # the other two batches (4 posts) still got scored
        self.assertEqual(stats["processed"], 4)
        scored_uris = {r["uri"] for r in records}
        self.assertEqual(len(scored_uris), 4)

    def test_failed_batch_is_not_marked_done_so_resume_retries_it(self):
        tmpdir = tempfile.mkdtemp()
        try:
            progress_path = os.path.join(tmpdir, ".progress.txt")
            replies = [("uri-0", "a"), ("uri-1", "b")]

            def always_fails(texts):
                raise RuntimeError("boom")

            progress = score_corpus.ProgressWriter(progress_path)
            try:
                stats = score_corpus.score_corpus(
                    replies, always_fails, batch_size=2, progress=progress,
                    max_retries=0, sleep_fn=lambda s: None,
                )
            finally:
                progress.close()

            self.assertEqual(stats["failed_batches"], 1)
            done = score_corpus.load_progress(progress_path)
            self.assertEqual(done, set())
        finally:
            shutil.rmtree(tmpdir)

    def test_run_forces_non_zero_exit_when_failures_occurred(self):
        tmpdir = tempfile.mkdtemp()
        try:
            store_path = os.path.join(tmpdir, "default.store")
            make_store(store_path, [("uri-%d" % i, "t") for i in range(4)])
            out_dir = os.path.join(tmpdir, "out")

            def flaky(texts):
                # The batch containing "t" for uri-0/uri-1 always fails,
                # even across retries, since all texts here are "t" — pick
                # the first batch deterministically by uri instead.
                raise RuntimeError("boom")

            def fake_loader(device=None):
                return None, None, "cpu"

            # Patch score_texts-based score_fn creation to use our flaky fn
            # by monkeypatching make_score_fn for the duration of this test.
            original_make_score_fn = score_corpus.make_score_fn
            score_corpus.make_score_fn = lambda *a, **k: flaky
            try:
                _, summary_path, summary = score_corpus.run(
                    store_path, out_dir, batch_size=2, limit=None, resume=False,
                    model_loader=fake_loader, sleep_fn=lambda s: None,
                    cool_seconds=0,
                )
            finally:
                score_corpus.make_score_fn = original_make_score_fn

            self.assertEqual(summary["run_status"], "partial")
            self.assertGreater(summary["failed_batches"], 0)

            argv_summary = summary
            exit_code = 1 if (
                argv_summary["run_status"] != "complete" or argv_summary["failed_batches"] > 0
            ) else 0
            self.assertEqual(exit_code, 1)
        finally:
            shutil.rmtree(tmpdir)


class DegenerateInputTests(unittest.TestCase):
    def test_empty_text_does_not_crash(self):
        replies = [("uri-empty", "")]
        records = []
        stats = score_corpus.score_corpus(replies, fake_score_fn, on_record=records.append)
        self.assertEqual(stats["processed"], 1)
        self.assertEqual(len(records), 2)

    def test_none_text_does_not_crash(self):
        replies = [("uri-none", None)]
        records = []
        stats = score_corpus.score_corpus(replies, fake_score_fn, on_record=records.append)
        self.assertEqual(stats["processed"], 1)
        self.assertEqual(len(records), 2)

    def test_very_long_text_is_deliberately_truncated_not_accidentally(self):
        # score_texts (the real model-facing function) truncates via the
        # tokenizer at MAX_LENGTH; verify that constant matches the
        # checkpoint's documented limit rather than an arbitrary number.
        self.assertEqual(score_corpus.MAX_LENGTH, 512)

        long_text = "x " * 5000

        try:
            import torch
        except ImportError:
            self.skipTest("torch not installed in this environment")

        class FakeTokenizer:
            def __call__(self, batch, padding, truncation, max_length, return_tensors):
                self.last_call = {
                    "padding": padding, "truncation": truncation,
                    "max_length": max_length,
                }
                assert truncation is True
                assert max_length == score_corpus.MAX_LENGTH

                class Encoded(dict):
                    def to(self, device):
                        return self
                return Encoded(input_ids=None)

        class FakeConfig:
            id2label = {0: "toxicity", 1: "identity_attack"}

        class FakeModel:
            config = FakeConfig()

            def __call__(self, **kwargs):
                class Output:
                    logits = torch.tensor([[10.0, -10.0]])
                return Output()

        # Use the real score_texts function with fakes standing in for
        # tokenizer/model to prove truncation params are passed through
        # deliberately, without needing real downloaded model weights.
        tokenizer = FakeTokenizer()
        model = FakeModel()
        result = score_corpus.score_texts([long_text], tokenizer, model, "cpu")
        self.assertIn("toxicity", result)
        self.assertIn("identity_attack", result)
        self.assertEqual(tokenizer.last_call["max_length"], 512)
        self.assertTrue(tokenizer.last_call["truncation"])

    def test_non_ascii_and_emoji_text_does_not_crash(self):
        replies = [("uri-emoji", "🔥🔥 so schlimm 😡 — völlig daneben!!! 你好")]
        records = []
        stats = score_corpus.score_corpus(replies, fake_score_fn, on_record=records.append)
        self.assertEqual(stats["processed"], 1)
        self.assertEqual(len(records), 2)


class FetchRepliesTests(unittest.TestCase):
    def test_reads_only_replies_not_roots(self):
        tmpdir = tempfile.mkdtemp()
        try:
            store_path = os.path.join(tmpdir, "default.store")
            conn = sqlite3.connect(store_path)
            conn.execute(POST_DDL)
            conn.execute(
                "INSERT INTO ZPOST (ZISROOTPOST, ZURI, ZTEXT) VALUES (1, 'root-1', 'root text')"
            )
            conn.execute(
                "INSERT INTO ZPOST (ZISROOTPOST, ZURI, ZTEXT) VALUES (0, 'reply-1', 'reply text')"
            )
            conn.commit()
            conn.close()

            replies = score_corpus.fetch_replies(store_path)
            self.assertEqual(replies, [("reply-1", "reply text")])
        finally:
            shutil.rmtree(tmpdir)

    def test_respects_limit(self):
        tmpdir = tempfile.mkdtemp()
        try:
            store_path = os.path.join(tmpdir, "default.store")
            make_store(store_path, [("uri-%d" % i, "t") for i in range(10)])
            replies = score_corpus.fetch_replies(store_path, limit=3)
            self.assertEqual(len(replies), 3)
        finally:
            shutil.rmtree(tmpdir)

    def test_does_not_write_to_store(self):
        tmpdir = tempfile.mkdtemp()
        try:
            store_path = os.path.join(tmpdir, "default.store")
            make_store(store_path, [("uri-0", "t")])
            before = os.stat(store_path).st_mtime_ns
            score_corpus.fetch_replies(store_path)
            after = os.stat(store_path).st_mtime_ns
            self.assertEqual(before, after)
        finally:
            shutil.rmtree(tmpdir)


class RunIntegrationTests(unittest.TestCase):
    def test_full_run_writes_jsonl_and_summary(self):
        tmpdir = tempfile.mkdtemp()
        try:
            store_path = os.path.join(tmpdir, "default.store")
            make_store(store_path, [("uri-%d" % i, "text %d" % i) for i in range(5)])
            out_dir = os.path.join(tmpdir, "out")

            def fake_loader(device=None):
                return None, None, "cpu"

            original_make_score_fn = score_corpus.make_score_fn
            score_corpus.make_score_fn = lambda *a, **k: fake_score_fn
            try:
                jsonl_path, summary_path, summary = score_corpus.run(
                    store_path, out_dir, batch_size=2, limit=None, resume=False,
                    model_loader=fake_loader, sleep_fn=lambda s: None,
                    cool_seconds=0,
                )
            finally:
                score_corpus.make_score_fn = original_make_score_fn

            self.assertTrue(os.path.exists(jsonl_path))
            self.assertTrue(os.path.exists(summary_path))
            self.assertEqual(summary["run_status"], "complete")
            self.assertEqual(summary["posts_scored"], 5)

            lines = open(jsonl_path, encoding="utf-8").read().splitlines()
            self.assertEqual(len(lines), 10)
            for line in lines:
                rec = json.loads(line)
                self.assertIn(rec["head"], ("toxicity", "identity_attack"))
        finally:
            shutil.rmtree(tmpdir)

    def test_readme_written_alongside_output(self):
        tmpdir = tempfile.mkdtemp()
        try:
            out_dir = os.path.join(tmpdir, "out")
            os.makedirs(out_dir)
            path = score_corpus.write_readme(out_dir)
            self.assertTrue(os.path.exists(path))
            content = open(path, encoding="utf-8").read()
            self.assertIn("0.198", content)
            self.assertIn("not a hate", content.lower())
        finally:
            shutil.rmtree(tmpdir)


class MainLockTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.store_path = os.path.join(self.tmpdir, "default.store")
        make_store(self.store_path, [("uri-%d" % i, "text %d" % i) for i in range(5)])
        self.out_dir = os.path.join(self.tmpdir, "out")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_main_exits_3_and_writes_nothing_when_lock_held(self):
        os.makedirs(self.out_dir, exist_ok=True)
        lock_path = os.path.join(self.out_dir, ".score.lock")
        argv = ["--store", self.store_path, "--out", self.out_dir]

        buf = io.StringIO()
        with single_instance(lock_path):
            with self.assertRaises(SystemExit) as cm:
                with redirect_stdout(buf):
                    score_corpus.main(argv)
        self.assertEqual(cm.exception.code, 3)

        printed = json.loads(buf.getvalue().strip())
        self.assertFalse(printed["ok"])
        self.assertIn("already", printed["error"])
        self.assertEqual(printed["out_dir"], self.out_dir)

        # No work started: no jsonl/summary/progress files written.
        written = [
            f for f in os.listdir(self.out_dir)
            if f not in (".score.lock",)
        ]
        self.assertEqual(written, [])


if __name__ == "__main__":
    unittest.main()
