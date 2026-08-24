"""Tests for build_dashboard.py.

Synthetic temp stores/files only -- no real data, no network. Covers:
renders with all sources present; renders with each source missing (honest
panel, no crash); Wilson CI matches base_rate.py; no per-post
scores/labels leak into the HTML; accepted-condition rendering (heartbeat
"skipped": "locked", and documented 5xx pass failures); deterministic
output for identical inputs; no http(s):// external references anywhere
in the rendered HTML (self-containment).
"""
import json
import os
import shutil
import sqlite3
import tempfile
import unittest

import build_dashboard as bd
import base_rate

CORE_DATA_EPOCH_OFFSET = bd.CORE_DATA_EPOCH_OFFSET


def unix_to_coredata(unix_ts):
    return unix_ts - CORE_DATA_EPOCH_OFFSET


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

ACCOUNT_DDL = """
CREATE TABLE ZTRACKEDACCOUNT (
    Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
    ZISACTIVE INTEGER, ZSTARTAT TIMESTAMP, ZAVATARURL VARCHAR,
    ZDID VARCHAR, ZDISPLAYNAME VARCHAR, ZHANDLE VARCHAR
)
"""

ANNOTATION_DDL = """
CREATE TABLE ZANNOTATION (
    Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
    ZPOST INTEGER, ZCONFIDENCE FLOAT, ZCREATEDAT TIMESTAMP,
    ZSENTIMENTSCORE FLOAT, ZDETECTEDLANGUAGE VARCHAR, ZMODELNAME VARCHAR,
    ZMODELVERSION VARCHAR, ZPROMPTHASH VARCHAR, ZRAWRESPONSE VARCHAR,
    ZREASONING VARCHAR, ZSEVERITY VARCHAR, ZSPEECHCLASS VARCHAR,
    ZSTAGE VARCHAR, ZANNOTATORID VARCHAR, ZBATCHID BLOB,
    ZTIMETODECIDESECONDS FLOAT, ZPASSNUMBER INTEGER
)
"""

LABELBATCH_DDL = """
CREATE TABLE ZLABELBATCH (
    Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
    ZPASSNUMBER INTEGER, ZPOOLSIZEATDRAW INTEGER, ZSEEDBITPATTERN INTEGER,
    ZCOMPLETEDAT TIMESTAMP, ZCREATEDAT TIMESTAMP, ZFRAMEJSON VARCHAR,
    ZID BLOB, ZSOURCEBATCHID BLOB, ZDRAWNURIS BLOB, ZLABELLEDURIS BLOB
)
"""


def make_store(path, accounts=(), roots=(), replies=(), annotations=(), batches=()):
    """accounts: [(pk, handle), ...]
    roots: [(uri, account_pk, unix_created_at), ...]
    replies: [(uri, root_uri, unix_created_at), ...]
    annotations: [(post_pk, speech_class, stage, batch_id_text, pass_number), ...]
    batches: [(zid_text, pass_number, frame_json, drawn_json, labelled_json), ...]
    """
    conn = sqlite3.connect(path)
    conn.execute(POST_DDL)
    conn.execute(ACCOUNT_DDL)
    conn.execute(ANNOTATION_DDL)
    conn.execute(LABELBATCH_DDL)
    for pk, handle in accounts:
        conn.execute("INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZHANDLE) VALUES (?, ?)", (pk, handle))
    pk_counter = [1000]
    uri_to_pk = {}
    for uri, account_pk, created in roots:
        pk_counter[0] += 1
        pk = pk_counter[0]
        uri_to_pk[uri] = pk
        conn.execute(
            "INSERT INTO ZPOST (Z_PK, ZISROOTPOST, ZACCOUNT, ZURI, ZROOTURI, ZCREATEDAT) "
            "VALUES (?, 1, ?, ?, ?, ?)",
            (pk, account_pk, uri, uri, unix_to_coredata(created)),
        )
    for uri, root_uri, created in replies:
        pk_counter[0] += 1
        pk = pk_counter[0]
        uri_to_pk[uri] = pk
        conn.execute(
            "INSERT INTO ZPOST (Z_PK, ZISROOTPOST, ZURI, ZROOTURI, ZCREATEDAT) "
            "VALUES (?, 0, ?, ?, ?)",
            (pk, uri, root_uri, unix_to_coredata(created)),
        )
    for post_pk, speech_class, stage, batch_id_text, pass_number in annotations:
        conn.execute(
            "INSERT INTO ZANNOTATION (ZPOST, ZSPEECHCLASS, ZSTAGE, ZBATCHID, ZPASSNUMBER) "
            "VALUES (?, ?, ?, ?, ?)",
            (post_pk, speech_class, stage, batch_id_text, pass_number),
        )
    for zid_text, pass_number, frame_json, drawn_json, labelled_json in batches:
        conn.execute(
            "INSERT INTO ZLABELBATCH (ZID, ZPASSNUMBER, ZFRAMEJSON, ZDRAWNURIS, ZLABELLEDURIS) "
            "VALUES (?, ?, ?, ?, ?)",
            (zid_text, pass_number, frame_json, drawn_json, labelled_json),
        )
    conn.commit()
    conn.close()


def make_telegram_db(path, channels=(), messages=(), candidates=()):
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE channels (username TEXT PRIMARY KEY, title TEXT, source_list TEXT, "
        "inclusion_criterion TEXT, status TEXT, added_at TEXT, decided_by_user_at TEXT, "
        "backfill_complete_at TEXT)"
    )
    conn.execute(
        "CREATE TABLE messages (channel TEXT, msg_id INTEGER, date TEXT, text TEXT, "
        "views INTEGER, fwd_from_channel TEXT, fwd_from_msg_id INTEGER, "
        "reply_to_msg_id INTEGER, media_type TEXT, media_ref TEXT, source_route TEXT, "
        "fetched_at TEXT, PRIMARY KEY (channel, msg_id))"
    )
    conn.execute(
        "CREATE TABLE candidates (username TEXT PRIMARY KEY, forward_evidence_count INTEGER, "
        "distinct_forwarders INTEGER, first_seen TEXT, status TEXT, decided_at TEXT)"
    )
    for username, status, backfill_complete_at in channels:
        conn.execute(
            "INSERT INTO channels (username, status, backfill_complete_at) VALUES (?, ?, ?)",
            (username, status, backfill_complete_at),
        )
    for channel, msg_id, fwd_from_channel in messages:
        conn.execute(
            "INSERT INTO messages (channel, msg_id, fwd_from_channel) VALUES (?, ?, ?)",
            (channel, msg_id, fwd_from_channel),
        )
    for username, forward_evidence_count, status in candidates:
        conn.execute(
            "INSERT INTO candidates (username, forward_evidence_count, status) VALUES (?, ?, ?)",
            (username, forward_evidence_count, status),
        )
    conn.commit()
    conn.close()


def make_committee_db(path, rows=()):
    """rows: [(uri, tox, tox_pct, tfidf_pct, d2v_pct, n_members, mean_pct), ...]"""
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE scores (uri TEXT PRIMARY KEY, tox REAL, tox_pct REAL, "
        "tfidf REAL, tfidf_pct REAL, d2v REAL, d2v_pct REAL, n_members INTEGER, "
        "mean_pct REAL, spread_pct REAL)"
    )
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
    for uri, tox, tox_pct, tfidf_pct, d2v_pct, n_members, mean_pct in rows:
        conn.execute(
            "INSERT INTO scores (uri, tox, tox_pct, tfidf_pct, d2v_pct, n_members, mean_pct) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (uri, tox, tox_pct, tfidf_pct, d2v_pct, n_members, mean_pct),
        )
    conn.commit()
    conn.close()


class TempDirMixin:
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bluex-dashboard-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def path(self, name):
        return os.path.join(self.tmp, name)


# --------------------------------------------------------------------------
# Bluesky acquisition
# --------------------------------------------------------------------------

class TestBlueskyAcquisition(TempDirMixin, unittest.TestCase):
    def test_counts_and_per_outlet(self):
        store = self.path("default.store")
        make_store(
            store,
            accounts=[(1, "outlet-a.bsky.social"), (2, "outlet-b.bsky.social")],
            roots=[("at://root1", 1, 1750000000), ("at://root2", 2, 1750000000)],
            replies=[("at://r1", "at://root1", 1750000000), ("at://r2", "at://root1", 1750000000)],
        )
        result = bd.read_bluesky_acquisition(store)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["total_posts"], 4)
        self.assertEqual(result["root_posts"], 2)
        self.assertEqual(result["reply_posts"], 2)
        by_handle = {r["handle"]: r for r in result["per_outlet"]}
        self.assertEqual(by_handle["outlet-a.bsky.social"]["own_posts"], 1)
        self.assertEqual(by_handle["outlet-a.bsky.social"]["replies_received"], 2)
        self.assertEqual(by_handle["outlet-b.bsky.social"]["own_posts"], 1)
        self.assertEqual(by_handle["outlet-b.bsky.social"]["replies_received"], 0)

    def test_missing_store_is_unavailable_not_crash(self):
        result = bd.read_bluesky_acquisition(self.path("does-not-exist.store"))
        self.assertEqual(result["status"], "unavailable")
        self.assertIn("reason", result)


# --------------------------------------------------------------------------
# Telegram acquisition
# --------------------------------------------------------------------------

class TestTelegramAcquisition(TempDirMixin, unittest.TestCase):
    def test_counts(self):
        db = self.path("telegram.db")
        make_telegram_db(
            db,
            channels=[("chan_a", "approved", "2026-08-01T00:00:00Z"), ("chan_b", "approved", None)],
            messages=[("chan_a", 1, None), ("chan_a", 2, "chan_c"), ("chan_a", 3, "chan_c")],
            candidates=[("cand1", 5, "pending"), ("cand2", 1, "pending")],
        )
        result = bd.read_telegram_acquisition(db)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["n_messages"], 3)
        self.assertEqual(result["n_channels"], 2)
        self.assertEqual(result["n_backfill_complete"], 1)
        self.assertEqual(result["n_empty_channels"], 1)  # chan_b has no messages
        self.assertEqual(result["n_forward_edges"], 2)
        self.assertEqual(result["n_forward_sources"], 1)
        self.assertEqual(result["n_pending_candidates"], 2)
        self.assertEqual(result["n_pending_over_threshold"], 1)  # only cand1 >= 3

    def test_missing_db_is_unavailable(self):
        result = bd.read_telegram_acquisition(self.path("nope.db"))
        self.assertEqual(result["status"], "unavailable")


# --------------------------------------------------------------------------
# Collection health / accepted conditions
# --------------------------------------------------------------------------

class TestCollectionHealth(TempDirMixin, unittest.TestCase):
    def test_continuous_log_counts_and_accepted_5xx(self):
        path = self.path("continuous.log")
        with open(path, "w") as f:
            f.write(
                "Mon Aug 24 05:28:03 CEST 2026: pass ok\n"
                "Mon Aug 24 06:00:00 CEST 2026: pass FAILED — HTTP 5xx from exit IP\n"
                "Mon Aug 24 07:00:00 CEST 2026: pass FAILED — disk full\n"
            )
        result = bd.read_continuous_log(path)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["n_pass_ok"], 1)
        self.assertEqual(result["n_pass_failed_accepted"], 1)
        self.assertEqual(result["n_pass_failed"], 1)

    def test_missing_continuous_log_unavailable(self):
        result = bd.read_continuous_log(self.path("nope.log"))
        self.assertEqual(result["status"], "unavailable")

    def test_telegram_heartbeat_locked_is_accepted_not_error(self):
        path = self.path("telegram-heartbeat.json")
        with open(path, "w") as f:
            json.dump({"ts": "2026-08-24T00:00:00Z", "skipped": "locked"}, f)
        result = bd.read_telegram_heartbeat(path)
        self.assertEqual(result["status"], "ok")
        self.assertTrue(result["accepted_skip"])

    def test_telegram_heartbeat_no_vpn_is_accepted(self):
        path = self.path("telegram-heartbeat.json")
        with open(path, "w") as f:
            json.dump({"skipped": "no-vpn"}, f)
        result = bd.read_telegram_heartbeat(path)
        self.assertTrue(result["accepted_skip"])

    def test_telegram_heartbeat_real_failure_not_marked_accepted(self):
        path = self.path("telegram-heartbeat.json")
        with open(path, "w") as f:
            json.dump({"exit": 1, "ok_channels": 0, "failed_channels": 30}, f)
        result = bd.read_telegram_heartbeat(path)
        self.assertFalse(result["accepted_skip"])

    def test_missing_heartbeat_is_unavailable_not_zero(self):
        result = bd.read_telegram_heartbeat(self.path("nope.json"))
        self.assertEqual(result["status"], "unavailable")


# --------------------------------------------------------------------------
# Wilson CI parity with base_rate.py
# --------------------------------------------------------------------------

class TestWilsonCIParity(unittest.TestCase):
    def test_matches_base_rate_module(self):
        for k, n in [(5, 76), (0, 10), (10, 10), (1, 3)]:
            self.assertEqual(bd.base_rate.wilson_ci(k, n), base_rate.wilson_ci(k, n))


# --------------------------------------------------------------------------
# Labelling
# --------------------------------------------------------------------------

class TestLabelling(TempDirMixin, unittest.TestCase):
    def test_human_labels_by_class_and_base_rate(self):
        store = self.path("default.store")
        batch_id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        frame = json.dumps({"kind": "uniformRandom"})
        make_store(
            store,
            annotations=[
                (1, "hate", "human", batch_id, 1),
                (2, "neutral", "human", batch_id, 1),
                (3, "neutral", "human", batch_id, 1),
                (4, "hate", "llm", None, None),  # model label, excluded from human counts
            ],
            batches=[(batch_id, 1, frame, None, None)],
        )
        result = bd.read_labelling(store)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["human_labels_by_class"]["hate"], 1)
        self.assertEqual(result["human_labels_by_class"]["neutral"], 2)
        self.assertEqual(result["total_human_labels"], 3)
        self.assertEqual(result["base_rate"]["run_status"], "ok")
        self.assertEqual(result["base_rate"]["n_included"], 3)

    def test_missing_store_unavailable(self):
        result = bd.read_labelling(self.path("nope.store"))
        self.assertEqual(result["status"], "unavailable")


# --------------------------------------------------------------------------
# Committee
# --------------------------------------------------------------------------

class TestCommittee(TempDirMixin, unittest.TestCase):
    def test_band_sizes_and_missing_member_skew(self):
        db = self.path("committee.db")
        rows = []
        # 100 posts; posts 90-99 (top 10%) are missing tox on purpose to
        # create a measurable skew; use fractions large enough for a
        # 100-row population (top_1_pct/top_0.1_pct both round up to >=1).
        for i in range(100):
            tox = None if i >= 90 else 0.5
            rows.append(("at://p%d" % i, tox, float(i), float(i), float(i), 3, float(i)))
        make_committee_db(db, rows)
        result = bd.read_committee(db)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["total_rows"], 100)
        self.assertIn("top_1_pct", result["band_sizes"])
        self.assertGreaterEqual(result["band_sizes"]["top_1_pct"], 1)
        # top mean_pct band (highest i values) should be entirely tox-missing
        self.assertEqual(
            result["missing_member_skew"]["top_1_pct"]["share_missing_in_band"], 1.0
        )

    def test_spearman_verdicts(self):
        db = self.path("committee.db")
        rows = []
        for i in range(20):
            rows.append(("at://p%d" % i, 0.1, float(i), float(i), float(19 - i), 3, float(i)))
        make_committee_db(db, rows)
        result = bd.read_committee(db)
        by_pair = {(s["a"], s["b"]): s for s in result["spearman"]}
        tfidf_d2v = by_pair[("tfidf_lr", "doc2vec_lr")]
        self.assertAlmostEqual(tfidf_d2v["rho"], -1.0, places=6)
        self.assertEqual(tfidf_d2v["verdict"], "redundant")

    def test_missing_db_unavailable(self):
        result = bd.read_committee(self.path("nope.db"))
        self.assertEqual(result["status"], "unavailable")


# --------------------------------------------------------------------------
# Blindness rule: no per-post score or label leaks into rendered HTML
# --------------------------------------------------------------------------

class TestBlindnessRule(TempDirMixin, unittest.TestCase):
    def _build_full_sections(self):
        store = self.path("default.store")
        make_store(
            store,
            accounts=[(1, "outlet-a.bsky.social")],
            roots=[("at://SECRET-ROOT-URI", 1, 1750000000)],
            replies=[("at://SECRET-REPLY-URI-999", "at://SECRET-ROOT-URI", 1750000000)],
            annotations=[(2, "hate", "human", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", 1)],
            batches=[("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", 1,
                      json.dumps({"kind": "uniformRandom"}), None, None)],
        )
        committee_db = self.path("committee.db")
        make_committee_db(committee_db, [("at://SECRET-REPLY-URI-999", 0.987654, 99.0, 99.0, 99.0, 3, 99.0)])
        telegram_db = self.path("telegram.db")
        make_telegram_db(telegram_db, channels=[("secret_channel", "approved", None)],
                          messages=[("secret_channel", 1, None)])
        sections = bd.build_sections(
            store, telegram_db, committee_db, self.tmp,
            self.tmp, self.path("no-heartbeat.json"), self.path("no-lastrun.json"),
            self.path("no-doc2vec.json"), self.tmp,
        )
        return sections

    def test_no_post_uri_or_raw_score_in_html(self):
        sections = self._build_full_sections()
        page = bd.render_html(sections, "2026-01-01T00:00:00Z")
        self.assertNotIn("SECRET-ROOT-URI", page)
        self.assertNotIn("SECRET-REPLY-URI", page)
        self.assertNotIn("0.987654", page)
        # the exact per-post mean_pct value (99.0) must not appear tagged to
        # a uri; band SIZES (counts) are fine, raw per-row scores are not.
        self.assertNotIn("at://", page)


# --------------------------------------------------------------------------
# Full-page rendering / degradation / determinism / self-containment
# --------------------------------------------------------------------------

class TestFullPage(TempDirMixin, unittest.TestCase):
    def _all_paths(self):
        return dict(
            store=self.path("default.store"),
            telegram_db=self.path("telegram.db"),
            committee_db=self.path("committee.db"),
            committee_dir=self.tmp,
            log_dir=self.tmp,
            telegram_heartbeat=self.path("telegram-heartbeat.json"),
            last_run_json=self.path("last-run.json"),
            doc2vec_meta=self.path("doc2vec-final.meta.json"),
            prereg_dir=self.tmp,
        )

    def _populate_all(self, paths):
        make_store(
            paths["store"],
            accounts=[(1, "outlet-a.bsky.social")],
            roots=[("at://root1", 1, 1750000000)],
            replies=[("at://r1", "at://root1", 1750000000)],
        )
        make_telegram_db(paths["telegram_db"], channels=[("chan_a", "approved", None)],
                          messages=[("chan_a", 1, None)])
        make_committee_db(paths["committee_db"], [("at://r1", 0.1, 50.0, 50.0, 50.0, 3, 50.0)])
        with open(paths["telegram_heartbeat"], "w") as f:
            json.dump({"skipped": "locked"}, f)
        with open(paths["last_run_json"], "w") as f:
            json.dump({"finishedAt": "2026-08-24T09:01:11Z", "scrapeExit": 0}, f)
        with open(os.path.join(paths["log_dir"], "continuous.log"), "w") as f:
            f.write("Mon Aug 24 05:28:03 CEST 2026: pass ok\n")
        with open(os.path.join(paths["log_dir"], "watchdog.log"), "w") as f:
            f.write("Mon Aug 24 06:56:05 CEST 2026: fresh.\n")
        with open(os.path.join(paths["log_dir"], "telegram.log"), "w") as f:
            f.write("Mon Aug 24 06:26:35 CEST 2026: telegram incremental exit=0\n")
        with open(paths["doc2vec_meta"], "w") as f:
            json.dump({"corpus_row_count": 100, "vocabulary_size": 10, "wall_time_seconds": 1.0}, f)

    def test_renders_with_everything_present(self):
        paths = self._all_paths()
        self._populate_all(paths)
        sections = bd.build_sections(**paths)
        page = bd.render_html(sections, "2026-01-01T00:00:00Z")
        self.assertIn("<html", page)
        self.assertIn("BlueX programme status", page)
        for key in ("bluesky", "telegram", "health", "labelling", "committee", "doc2vec", "sealed"):
            self.assertIn(key, sections)

    def test_renders_with_everything_missing_no_crash(self):
        paths = self._all_paths()
        # do NOT populate -- everything is missing
        sections = bd.build_sections(**paths)
        page = bd.render_html(sections, "2026-01-01T00:00:00Z")
        self.assertIn("<html", page)
        self.assertIn("unavailable", page)
        self.assertEqual(sections["bluesky"]["status"], "unavailable")
        self.assertEqual(sections["telegram"]["status"], "unavailable")
        self.assertEqual(sections["committee"]["status"], "unavailable")

    def test_deterministic_output(self):
        paths = self._all_paths()
        self._populate_all(paths)
        sections1 = bd.build_sections(**paths)
        sections2 = bd.build_sections(**paths)
        page1 = bd.render_html(sections1, "2026-01-01T00:00:00Z")
        page2 = bd.render_html(sections2, "2026-01-01T00:00:00Z")
        self.assertEqual(page1, page2)

    def test_no_external_resource_references(self):
        paths = self._all_paths()
        self._populate_all(paths)
        sections = bd.build_sections(**paths)
        page = bd.render_html(sections, "2026-01-01T00:00:00Z")
        # The inline SVG's xmlns is an XML namespace identifier, never fetched
        # by a browser -- strip it before checking for actual external
        # resource references (href/src/@import/CDN links etc.).
        scrubbed = page.replace('xmlns="http://www.w3.org/2000/svg"', "")
        self.assertNotIn("http://", scrubbed)
        self.assertNotIn("https://", scrubbed)

    def test_accepted_condition_not_rendered_as_error(self):
        paths = self._all_paths()
        self._populate_all(paths)
        sections = bd.build_sections(**paths)
        page = bd.render_html(sections, "2026-01-01T00:00:00Z")
        self.assertIn("accepted", page.lower())
        # the heartbeat "skipped": "locked" case must not be flagged unavailable
        self.assertEqual(sections["health"]["telegram_heartbeat"]["status"], "ok")
        self.assertTrue(sections["health"]["telegram_heartbeat"]["accepted_skip"])


if __name__ == "__main__":
    unittest.main()
