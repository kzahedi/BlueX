"""Tests for base_rate.py. No network. All store access goes through a
fixture SQLite database built in-test that mimics the Core Data Z-schema
minimally: Z_PK/ZSTAGE/ZSPEECHCLASS/ZBATCHID/ZPASSNUMBER on ZANNOTATION,
ZID/ZFRAMEJSON/ZPASSNUMBER on ZLABELBATCH.
"""
import json
import os
import sqlite3
import sys
import uuid

import pytest

sys.path.insert(0, os.path.dirname(__file__))

import base_rate as br


# --------------------------------------------------------------------------
# Wilson CI -- hand-worked values from the spec
# --------------------------------------------------------------------------

def test_wilson_ci_k3_n300():
    lo, hi = br.wilson_ci(3, 300)
    assert lo == pytest.approx(0.0034, abs=0.001)
    assert hi == pytest.approx(0.0290, abs=0.001)


def test_wilson_ci_zero_successes_lower_bound_is_zero():
    lo, hi = br.wilson_ci(0, 100)
    assert lo == 0.0
    assert hi > 0.0


def test_wilson_ci_all_successes_upper_bound_below_one():
    lo, hi = br.wilson_ci(100, 100)
    assert hi <= 1.0
    assert lo > 0.5


def test_wilson_ci_empty_sample():
    assert br.wilson_ci(0, 0) == (0.0, 0.0)


# --------------------------------------------------------------------------
# FP/TP decision-rule formula
# --------------------------------------------------------------------------

def test_fp_per_tp_hand_worked():
    # p=0.01 -> 0.05*0.99 / (0.88*0.01) = 0.0495 / 0.0088 = 5.625
    assert br.fp_per_tp(0.01) == pytest.approx(5.625, abs=0.001)


def test_fp_per_tp_zero_prevalence_is_undefined():
    assert br.fp_per_tp(0.0) is None


def test_fp_per_tp_none_prevalence_is_undefined():
    assert br.fp_per_tp(None) is None


# --------------------------------------------------------------------------
# UUID normalization -- both BLOB and TEXT encodings must join correctly
# --------------------------------------------------------------------------

def test_normalize_uuid_from_blob():
    u = uuid.uuid4()
    assert br.normalize_uuid(u.bytes) == str(u)


def test_normalize_uuid_from_text_dashed():
    u = uuid.uuid4()
    assert br.normalize_uuid(str(u)) == str(u)


def test_normalize_uuid_from_text_bare_hex():
    u = uuid.uuid4()
    assert br.normalize_uuid(u.hex) == str(u)


def test_normalize_uuid_garbage_returns_none():
    assert br.normalize_uuid("not-a-uuid") is None
    assert br.normalize_uuid(b"short") is None
    assert br.normalize_uuid(None) is None


# --------------------------------------------------------------------------
# Fixture store builder
# --------------------------------------------------------------------------

def make_store(tmp_path, batches, annotations, uuid_encoding="text"):
    """batches: list of dicts {id: uuid.UUID, kind: str, pass_number: int}.
    annotations: list of dicts {speech_class: str, batch_id: uuid.UUID|None,
    pass_number: int|None (annotation-level, informational only)}.
    uuid_encoding: "text" (dashed string) or "blob" (raw 16 bytes) -- exercises
    both possible SwiftData storage forms for ZID/ZBATCHID.
    """
    path = str(tmp_path / "fixture.store")
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE ZANNOTATION (Z_PK INTEGER PRIMARY KEY, ZSTAGE VARCHAR, "
        "ZSPEECHCLASS VARCHAR, ZBATCHID BLOB, ZPASSNUMBER INTEGER)"
    )
    conn.execute(
        "CREATE TABLE ZLABELBATCH (Z_PK INTEGER PRIMARY KEY, ZID BLOB, "
        "ZFRAMEJSON VARCHAR, ZPASSNUMBER INTEGER)"
    )

    def encode(u):
        if u is None:
            return None
        return u.bytes if uuid_encoding == "blob" else str(u)

    for b in batches:
        frame_json = json.dumps({"kind": b["kind"]})
        conn.execute(
            "INSERT INTO ZLABELBATCH (ZID, ZFRAMEJSON, ZPASSNUMBER) VALUES (?, ?, ?)",
            (encode(b["id"]), frame_json, b["pass_number"]),
        )

    for a in annotations:
        conn.execute(
            "INSERT INTO ZANNOTATION (ZSTAGE, ZSPEECHCLASS, ZBATCHID, ZPASSNUMBER) "
            "VALUES ('human', ?, ?, ?)",
            (a["speech_class"], encode(a.get("batch_id")), a.get("pass_number")),
        )

    conn.commit()
    conn.close()
    return path


# --------------------------------------------------------------------------
# End-to-end classification via compute_report
# --------------------------------------------------------------------------

def test_uniform_pass1_labels_are_included(tmp_path):
    batch_id = uuid.uuid4()
    store = make_store(
        tmp_path,
        batches=[{"id": batch_id, "kind": "uniformRandom", "pass_number": 1}],
        annotations=[
            {"speech_class": "hate", "batch_id": batch_id, "pass_number": 1},
            {"speech_class": "neutral", "batch_id": batch_id, "pass_number": 1},
            {"speech_class": "neutral", "batch_id": batch_id, "pass_number": 1},
        ],
    )
    report = br.compute_report(store)
    assert report["run_status"] == "ok"
    assert report["n_included"] == 3
    assert report["included_by_class"]["hate"] == 1
    assert report["included_by_class"]["neutral"] == 2
    assert report["n_excluded"] == 0


def test_non_uniform_frame_is_excluded_and_reported(tmp_path):
    filtered_batch = uuid.uuid4()
    uniform_batch = uuid.uuid4()
    store = make_store(
        tmp_path,
        batches=[
            {"id": filtered_batch, "kind": "filtered", "pass_number": 1},
            {"id": uniform_batch, "kind": "uniformRandom", "pass_number": 1},
        ],
        annotations=[
            {"speech_class": "hate", "batch_id": filtered_batch, "pass_number": 1},
            {"speech_class": "neutral", "batch_id": uniform_batch, "pass_number": 1},
        ],
    )
    report = br.compute_report(store)
    assert report["n_included"] == 1
    assert report["included_by_class"]["neutral"] == 1
    assert report["n_excluded"] == 1
    assert report["excluded_by_reason"].get("non_uniform_frame:filtered") == 1


def test_pass_2_label_is_excluded_and_reported(tmp_path):
    batch1 = uuid.uuid4()
    batch2 = uuid.uuid4()
    store = make_store(
        tmp_path,
        batches=[
            {"id": batch1, "kind": "uniformRandom", "pass_number": 1},
            {"id": batch2, "kind": "uniformRandom", "pass_number": 2},
        ],
        annotations=[
            {"speech_class": "hate", "batch_id": batch1, "pass_number": 1},
            {"speech_class": "hate", "batch_id": batch2, "pass_number": 2},
        ],
    )
    report = br.compute_report(store)
    assert report["n_included"] == 1
    assert report["n_excluded"] == 1
    assert report["excluded_by_reason"].get("pass_2") == 1


def test_orphan_label_no_matching_batch_is_excluded_and_reported(tmp_path):
    real_batch = uuid.uuid4()
    orphan_batch_id = uuid.uuid4()  # never inserted into ZLABELBATCH
    store = make_store(
        tmp_path,
        batches=[{"id": real_batch, "kind": "uniformRandom", "pass_number": 1}],
        annotations=[
            {"speech_class": "neutral", "batch_id": real_batch, "pass_number": 1},
            {"speech_class": "hate", "batch_id": orphan_batch_id, "pass_number": 1},
        ],
    )
    report = br.compute_report(store)
    assert report["n_included"] == 1
    assert report["n_excluded"] == 1
    assert report["excluded_by_reason"].get("orphan_no_matching_batch") == 1


def test_no_batch_id_on_annotation_is_excluded_and_reported(tmp_path):
    batch = uuid.uuid4()
    store = make_store(
        tmp_path,
        batches=[{"id": batch, "kind": "uniformRandom", "pass_number": 1}],
        annotations=[
            {"speech_class": "neutral", "batch_id": None, "pass_number": None},
        ],
    )
    report = br.compute_report(store)
    assert report["n_included"] == 0
    assert report["n_excluded"] == 1
    assert report["excluded_by_reason"].get("no_batch_id") == 1
    assert report["run_status"] == "no_data"


def test_uuid_join_works_with_blob_encoding(tmp_path):
    batch_id = uuid.uuid4()
    store = make_store(
        tmp_path,
        batches=[{"id": batch_id, "kind": "uniformRandom", "pass_number": 1}],
        annotations=[{"speech_class": "hate", "batch_id": batch_id, "pass_number": 1}],
        uuid_encoding="blob",
    )
    report = br.compute_report(store)
    assert report["n_included"] == 1
    assert report["n_excluded"] == 0


def test_uuid_join_works_with_text_encoding(tmp_path):
    batch_id = uuid.uuid4()
    store = make_store(
        tmp_path,
        batches=[{"id": batch_id, "kind": "uniformRandom", "pass_number": 1}],
        annotations=[{"speech_class": "hate", "batch_id": batch_id, "pass_number": 1}],
        uuid_encoding="text",
    )
    report = br.compute_report(store)
    assert report["n_included"] == 1
    assert report["n_excluded"] == 0


# --------------------------------------------------------------------------
# Empty store / zero eligible labels -> clear message, non-zero exit
# --------------------------------------------------------------------------

def test_empty_store_zero_labels_reports_no_data(tmp_path):
    store = make_store(tmp_path, batches=[], annotations=[])
    report = br.compute_report(store)
    assert report["run_status"] == "no_data"
    assert report["n_included"] == 0
    assert "message" in report


def test_main_exits_nonzero_on_zero_eligible_labels(tmp_path, capsys):
    store = make_store(tmp_path, batches=[], annotations=[])
    out_dir = str(tmp_path / "out")
    rc = br.main(["--store", store, "--out", out_dir])
    assert rc != 0


def test_missing_label_batch_table_is_handled_not_crashed(tmp_path):
    # ZANNOTATION exists with human rows but ZLABELBATCH table absent entirely
    # (mirrors the real store as found on 2026-08-15).
    path = str(tmp_path / "fixture.store")
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE ZANNOTATION (Z_PK INTEGER PRIMARY KEY, ZSTAGE VARCHAR, "
        "ZSPEECHCLASS VARCHAR)"
    )
    conn.execute(
        "INSERT INTO ZANNOTATION (ZSTAGE, ZSPEECHCLASS) VALUES ('human', 'neutral')"
    )
    conn.commit()
    conn.close()

    report = br.compute_report(path)
    assert report["run_status"] == "no_data"
    assert report["n_excluded"] == 1
    assert report["excluded_by_reason"].get("no_label_batch_table") == 1
    assert any("batchID column" in note for note in report["schema_notes"])
    assert any("ZLABELBATCH does not exist" in note for note in report["schema_notes"])
    assert any("launch the BlueX app" in note for note in report["schema_notes"])


def test_label_batch_table_present_but_missing_columns_names_them(tmp_path):
    # ZLABELBATCH exists (so this is NOT "store not migrated yet") but is
    # missing ZPASSNUMBER -- e.g. a typo'd column name in this tool, or
    # genuine schema drift. Must be reported distinctly from the
    # table-absent case, naming both the missing and the found columns.
    path = str(tmp_path / "fixture.store")
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE ZANNOTATION (Z_PK INTEGER PRIMARY KEY, ZSTAGE VARCHAR, "
        "ZSPEECHCLASS VARCHAR, ZBATCHID BLOB, ZPASSNUMBER INTEGER)"
    )
    conn.execute(
        "CREATE TABLE ZLABELBATCH (Z_PK INTEGER PRIMARY KEY, ZID BLOB, ZFRAMEJSON VARCHAR)"
    )
    batch_id = uuid.uuid4()
    conn.execute(
        "INSERT INTO ZLABELBATCH (ZID, ZFRAMEJSON) VALUES (?, ?)",
        (str(batch_id), json.dumps({"kind": "uniformRandom"})),
    )
    conn.execute(
        "INSERT INTO ZANNOTATION (ZSTAGE, ZSPEECHCLASS, ZBATCHID, ZPASSNUMBER) "
        "VALUES ('human', 'neutral', ?, 1)",
        (str(batch_id),),
    )
    conn.commit()
    conn.close()

    batches, meta = br.fetch_batches(sqlite3.connect(path))
    assert meta["status"] == "missing_columns"
    assert meta["missing"] == ["ZPASSNUMBER"]
    assert set(meta["found"]) == {"Z_PK", "ZID", "ZFRAMEJSON"}

    report = br.compute_report(path)
    assert report["run_status"] == "no_data"
    assert report["excluded_by_reason"].get("no_label_batch_table") == 1
    notes = " ".join(report["schema_notes"])
    assert "missing expected column(s)" in notes
    assert "ZPASSNUMBER" in notes
    assert "ZID" in notes and "ZFRAMEJSON" in notes  # the columns actually found
    assert "schema drift" in notes
    assert "does not exist" not in notes  # must not be confused with the absent-table case


def test_malformed_frame_json_is_reported_as_undecodable(tmp_path):
    batch_id = uuid.uuid4()
    path = str(tmp_path / "fixture.store")
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE ZANNOTATION (Z_PK INTEGER PRIMARY KEY, ZSTAGE VARCHAR, "
        "ZSPEECHCLASS VARCHAR, ZBATCHID BLOB, ZPASSNUMBER INTEGER)"
    )
    conn.execute(
        "CREATE TABLE ZLABELBATCH (Z_PK INTEGER PRIMARY KEY, ZID BLOB, "
        "ZFRAMEJSON VARCHAR, ZPASSNUMBER INTEGER)"
    )
    conn.execute(
        "INSERT INTO ZLABELBATCH (ZID, ZFRAMEJSON, ZPASSNUMBER) VALUES (?, ?, ?)",
        (str(batch_id), "{not valid json", 1),
    )
    conn.execute(
        "INSERT INTO ZANNOTATION (ZSTAGE, ZSPEECHCLASS, ZBATCHID, ZPASSNUMBER) "
        "VALUES ('human', 'hate', ?, 1)",
        (str(batch_id),),
    )
    conn.commit()
    conn.close()

    report = br.compute_report(path)
    assert report["n_included"] == 0
    assert report["n_excluded"] == 1
    assert report["excluded_by_reason"].get("non_uniform_frame:undecodable") == 1


def test_all_neutral_sample_gives_zero_hate_prevalence(tmp_path):
    # n>0, k=0: pin that an all-neutral eligible sample is a valid "ok"
    # result (0% prevalence with a real CI), not treated as no_data.
    batch_id = uuid.uuid4()
    store = make_store(
        tmp_path,
        batches=[{"id": batch_id, "kind": "uniformRandom", "pass_number": 1}],
        annotations=[{"speech_class": "neutral", "batch_id": batch_id, "pass_number": 1}] * 50,
    )
    report = br.compute_report(store)
    assert report["run_status"] == "ok"
    assert report["n_included"] == 50
    assert report["hate_count"] == 0
    assert report["hate_prevalence"] == 0.0
    lo, hi = report["wilson_ci"]
    assert lo == 0.0
    assert hi > 0.0
    assert report["fp_per_tp_point"] is None  # p=0 -> undefined, not a crash


def test_pass_unknown_label_when_batch_pass_number_is_null(tmp_path):
    batch_id = uuid.uuid4()
    store = make_store(
        tmp_path,
        batches=[{"id": batch_id, "kind": "uniformRandom", "pass_number": None}],
        annotations=[{"speech_class": "hate", "batch_id": batch_id, "pass_number": 1}],
    )
    report = br.compute_report(store)
    assert report["excluded_by_reason"].get("pass_unknown") == 1


def test_main_succeeds_and_writes_files_on_real_data(tmp_path):
    batch_id = uuid.uuid4()
    annotations = (
        [{"speech_class": "hate", "batch_id": batch_id, "pass_number": 1}] * 3
        + [{"speech_class": "neutral", "batch_id": batch_id, "pass_number": 1}] * 297
    )
    store = make_store(
        tmp_path,
        batches=[{"id": batch_id, "kind": "uniformRandom", "pass_number": 1}],
        annotations=annotations,
    )
    out_dir = str(tmp_path / "out")
    rc = br.main(["--store", store, "--out", out_dir])
    assert rc == 0
    files = os.listdir(out_dir)
    assert any(f.startswith("base-rate-") and f.endswith(".json") for f in files)
    assert "README.md" in files
