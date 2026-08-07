import json
import os
import shutil
import sqlite3
import tempfile
import unittest

import extract_deleted

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

# 2026-06-01T12:00:00Z expressed in the Core Data epoch (2001-01-01Z).
CREATED = 1780315200 - extract_deleted.CORE_DATA_EPOCH_OFFSET


def make_store(path, roots, replies, accounts=()):
    """Build a minimal store with the real table/column shapes."""
    conn = sqlite3.connect(path)
    conn.execute(POST_DDL)
    conn.execute(ACCOUNT_DDL)
    for pk, handle in accounts:
        conn.execute(
            "INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZHANDLE) VALUES (?, ?)", (pk, handle)
        )
    for uri, account, status in roots:
        conn.execute(
            "INSERT INTO ZPOST (ZISROOTPOST, ZURI, ZROOTURI, ZACCOUNT, "
            "ZREPLYTREESTATUS, ZDEPTH, ZCREATEDAT) VALUES (1, ?, ?, ?, ?, 0, ?)",
            (uri, uri, account, status, CREATED),
        )
    for uri, root_uri, text in replies:
        conn.execute(
            "INSERT INTO ZPOST (ZISROOTPOST, ZURI, ZROOTURI, ZPARENTURI, ZTEXT, "
            "ZDEPTH, ZCREATEDAT, ZAUTHORHANDLE, ZAUTHORDID, ZLIKECOUNT, "
            "ZREPLYCOUNT, ZREPOSTCOUNT, ZQUOTECOUNT) "
            "VALUES (0, ?, ?, ?, ?, 1, ?, 'a.bsky.social', 'did:plc:a', 1, 0, 0, 0)",
            (uri, root_uri, root_uri, text, CREATED),
        )
    conn.commit()
    conn.close()


class ExtractTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.archive = os.path.join(self.dir, "archive.store")
        self.live = os.path.join(self.dir, "live.store")
        self.out = os.path.join(self.dir, "out")

        accounts = [(1, "tagesschau.bsky.social")]
        # rescraped-root: live holds replies for it -> in scope.
        # stale-root: live holds NO replies for it -> out of scope.
        # partial-root: rescraped but its live tree is still inProgress.
        archive_roots = [
            ("at://rescraped-root", 1, "complete"),
            ("at://stale-root", 1, "complete"),
            ("at://partial-root", 1, "complete"),
        ]
        archive_replies = [
            ("at://gone", "at://rescraped-root", "this vanished"),
            ("at://kept", "at://rescraped-root", "still there"),
            ("at://never-looked", "at://stale-root", "root not rescraped"),
            ("at://gone-partial", "at://partial-root", "vanished, tree partial"),
        ]
        make_store(self.archive, archive_roots, archive_replies, accounts)

        live_roots = [
            ("at://rescraped-root", 1, "complete"),
            ("at://stale-root", 1, "pending"),
            ("at://partial-root", 1, "inProgress"),
        ]
        live_replies = [
            ("at://kept", "at://rescraped-root", "still there"),
            ("at://other", "at://partial-root", "some other reply"),
        ]
        make_store(self.live, live_roots, live_replies, accounts)

        _, _, self.summary = extract_deleted.extract(
            self.archive, self.live, self.out, stamp="2026-08-07"
        )
        path = os.path.join(self.out, "deleted-replies-2026-08-07.jsonl")
        with open(path, encoding="utf-8") as handle:
            self.records = [json.loads(line) for line in handle if line.strip()]
        self.by_uri = {r["uri"]: r for r in self.records}

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_absent_reply_with_rescraped_root_is_included(self):
        self.assertIn("at://gone", self.by_uri)
        self.assertEqual(self.by_uri["at://gone"]["text"], "this vanished")

    def test_absent_reply_whose_root_was_not_rescraped_is_excluded(self):
        # The scoping rule: nothing looked for this reply, so its absence is
        # not evidence of anything.
        self.assertNotIn("at://never-looked", self.by_uri)

    def test_reply_present_in_both_stores_is_excluded(self):
        self.assertNotIn("at://kept", self.by_uri)

    def test_core_data_epoch_conversion(self):
        self.assertEqual(
            extract_deleted.coredata_to_iso(CREATED), "2026-06-01T12:00:00Z"
        )
        self.assertEqual(self.by_uri["at://gone"]["createdAt"], "2026-06-01T12:00:00Z")
        self.assertIsNone(extract_deleted.coredata_to_iso(None))

    def test_root_tree_complete_reflects_live_status(self):
        self.assertTrue(self.by_uri["at://gone"]["rootTreeComplete"])
        self.assertFalse(self.by_uri["at://gone-partial"]["rootTreeComplete"])

    def test_record_carries_provenance_and_account(self):
        rec = self.by_uri["at://gone"]
        self.assertEqual(rec["trackedAccount"], "tagesschau.bsky.social")
        self.assertEqual(rec["archiveStore"], os.path.abspath(self.archive))
        self.assertEqual(rec["liveStore"], os.path.abspath(self.live))
        self.assertTrue(rec["extractedAt"].endswith("Z"))
        self.assertEqual(rec["rootURI"], "at://rescraped-root")
        self.assertEqual(rec["depth"], 1)

    def test_summary_counts(self):
        self.assertEqual(self.summary["totalDeletedReplies"], 2)
        self.assertEqual(self.summary["withNonEmptyText"], 2)
        self.assertEqual(self.summary["rootTreeCompleteInLive"], 1)
        self.assertEqual(self.summary["rootTreeIncompleteInLive"], 1)
        self.assertEqual(
            self.summary["byTrackedAccount"], {"tagesschau.bsky.social": 2}
        )
        self.assertEqual(self.summary["byDepth"], {"1": 2})
        self.assertEqual(
            self.summary["createdAtRange"],
            {"earliest": "2026-06-01T12:00:00Z", "latest": "2026-06-01T12:00:00Z"},
        )

    def test_empty_text_is_counted(self):
        archive = os.path.join(self.dir, "a2.store")
        live = os.path.join(self.dir, "l2.store")
        make_store(archive, [("at://r", 1, "complete")],
                   [("at://x", "at://r", ""), ("at://y", "at://r", "hi")],
                   [(1, "zeit.de")])
        make_store(live, [("at://r", 1, "complete")],
                   [("at://z", "at://r", "keeps root in scope")], [(1, "zeit.de")])
        _, _, summary = extract_deleted.extract(
            archive, live, os.path.join(self.dir, "out2"), stamp="2026-08-07"
        )
        self.assertEqual(summary["totalDeletedReplies"], 2)
        self.assertEqual(summary["withEmptyText"], 1)
        self.assertEqual(summary["withNonEmptyText"], 1)

    def test_reruns_are_idempotent_and_dated(self):
        path = os.path.join(self.out, "deleted-replies-2026-08-07.jsonl")
        before = open(path, encoding="utf-8").read()
        extract_deleted.extract(self.archive, self.live, self.out, stamp="2026-08-07")
        after = open(path, encoding="utf-8").read()
        self.assertEqual(
            [json.loads(l)["uri"] for l in before.splitlines() if l.strip()],
            [json.loads(l)["uri"] for l in after.splitlines() if l.strip()],
        )
        extract_deleted.extract(self.archive, self.live, self.out, stamp="2026-09-01")
        self.assertTrue(
            os.path.exists(os.path.join(self.out, "deleted-replies-2026-09-01.jsonl"))
        )
        self.assertTrue(os.path.exists(path))

    def test_inputs_are_not_modified(self):
        stat_before = [os.stat(p).st_mtime_ns for p in (self.archive, self.live)]
        extract_deleted.extract(self.archive, self.live, self.out, stamp="2026-08-08")
        stat_after = [os.stat(p).st_mtime_ns for p in (self.archive, self.live)]
        self.assertEqual(stat_before, stat_after)


if __name__ == "__main__":
    unittest.main()
