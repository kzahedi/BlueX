#!/usr/bin/env python3
"""Tests for train_doc2vec.py. Uses a tiny synthetic sqlite fixture (a few
hundred short bilingual docs) so training runs in seconds -- see
build_fixture_store() below. No real BlueX store is touched.
"""
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import train_doc2vec as td


EN_SENTENCES = [
    "I really love this new coffee shop downtown",
    "The weather today is absolutely terrible and cold",
    "Check out this link https://example.com/article it is great",
    "Great game last night, our team played so well",
    "I disagree with this take but respect your opinion",
    "This is the best pizza place in the whole city",
    "Traffic on the highway was insane this morning",
    "Just finished reading a fantastic book about history",
]

DE_SENTENCES = [
    "Ich liebe dieses neue Cafe in der Innenstadt wirklich",
    "Das Wetter heute ist wirklich schlecht und kalt",
    "Schau dir diesen Link an https://example.com/artikel er ist toll",
    "Tolles Spiel letzte Nacht, unser Team hat gut gespielt",
    "Ich bin anderer Meinung aber respektiere deine Ansicht",
    "Das ist die beste Pizza der ganzen Stadt",
    "Der Verkehr auf der Autobahn war heute Morgen wahnsinnig",
    "Ich habe gerade ein tolles Buch ueber Geschichte gelesen",
]


def build_fixture_store(path, n_docs=300):
    """Create a tiny sqlite file shaped like the real ZPOST table
    (only the columns train_doc2vec.py actually reads), with n_docs rows
    mixing English/German short replies, some with URLs/hashtags/@mentions.
    """
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE ZPOST ("
        "Z_PK INTEGER PRIMARY KEY, ZISROOTPOST INTEGER, ZURI VARCHAR, ZTEXT VARCHAR)"
    )
    pool = EN_SENTENCES + DE_SENTENCES
    rows = []
    for i in range(n_docs):
        base = pool[i % len(pool)]
        extra = ""
        if i % 5 == 0:
            extra = " #bluesky"
        if i % 7 == 0:
            extra += " @someuser"
        text = "%s%s (%d)" % (base, extra, i)
        uri = "at://did:plc:fixture/app.bsky.feed.post/%05d" % i
        is_root = 1 if i % 11 == 0 else 0  # a few root posts to exclude
        rows.append((i, is_root, uri, text))
    conn.executemany(
        "INSERT INTO ZPOST (Z_PK, ZISROOTPOST, ZURI, ZTEXT) VALUES (?, ?, ?, ?)",
        rows,
    )
    conn.commit()
    conn.close()
    n_replies = sum(1 for _, is_root, _, _ in rows if is_root == 0)
    return n_replies


class TokenizeTests(unittest.TestCase):
    def test_url_becomes_url_token(self):
        toks = td.tokenize("check this out https://example.com/x?y=1 nice")
        self.assertIn("<url>", toks)
        self.assertNotIn("https://example.com/x?y=1", toks)

    def test_hashtag_kept(self):
        toks = td.tokenize("great day #bluesky today")
        self.assertIn("#bluesky", toks)

    def test_mention_kept(self):
        toks = td.tokenize("hello @someuser how are you")
        self.assertIn("@someuser", toks)

    def test_case_folded(self):
        toks = td.tokenize("HELLO World")
        self.assertIn("hello", toks)
        self.assertIn("world", toks)
        self.assertNotIn("HELLO", toks)

    def test_bilingual_sample_intact(self):
        toks = td.tokenize("Ich liebe dieses Cafe wirklich, es ist schoen!")
        self.assertIn("ich", toks)
        self.assertIn("liebe", toks)
        self.assertIn("schoen", toks)


class CorpusIteratorTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.store_path = os.path.join(self.tmpdir, "fixture.store")
        self.n_replies = build_fixture_store(self.store_path, n_docs=300)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_reiterable_same_count_twice(self):
        corpus = td.StreamingCorpus(self.store_path)
        first = sum(1 for _ in corpus)
        second = sum(1 for _ in corpus)
        self.assertEqual(first, self.n_replies)
        self.assertEqual(first, second)

    def test_yields_tagged_documents(self):
        corpus = td.StreamingCorpus(self.store_path, limit=5)
        docs = list(corpus)
        self.assertEqual(len(docs), 5)
        for doc in docs:
            self.assertTrue(hasattr(doc, "words"))
            self.assertTrue(hasattr(doc, "tags"))
            self.assertIsInstance(doc.words, list)
            self.assertIsInstance(doc.tags, list)

    def test_row_count_matches_fixture(self):
        self.assertEqual(td.fetch_row_count(self.store_path), self.n_replies)


class TrainEndToEndTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.store_path = os.path.join(self.tmpdir, "fixture.store")
        self.out_dir = os.path.join(self.tmpdir, "out")
        self.n_replies = build_fixture_store(self.store_path, n_docs=250)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_train_writes_model_and_metadata(self):
        result = td.run_train(
            store_path=self.store_path,
            out_dir=self.out_dir,
            epochs=2,
            vector_size=16,
            window=3,
            min_count=1,
            workers=1,
            seed=42,
            cool_seconds=0,
        )
        self.assertTrue(os.path.exists(result["final_model_path"]))
        self.assertTrue(os.path.exists(result["metadata_path"]))

        with open(result["metadata_path"]) as fh:
            meta = json.load(fh)

        self.assertEqual(meta["corpus_row_count"], self.n_replies)
        self.assertIn("vocabulary_size", meta)
        self.assertGreater(meta["vocabulary_size"], 0)
        self.assertEqual(meta["hyperparameters"]["vector_size"], 16)
        self.assertEqual(meta["hyperparameters"]["epochs"], 2)
        self.assertEqual(meta["seed"], 42)
        self.assertEqual(meta["workers"], 1)
        self.assertIn("gensim_version", meta)
        self.assertIn("started_at", meta)
        self.assertIn("ended_at", meta)
        self.assertIn("wall_time_seconds", meta)
        self.assertIn("unsupervised", meta["notes"].lower())

    def test_resume_continues_rather_than_restarts(self):
        first = td.run_train(
            store_path=self.store_path,
            out_dir=self.out_dir,
            epochs=1,
            vector_size=16,
            window=3,
            min_count=1,
            workers=1,
            seed=42,
            cool_seconds=0,
        )
        self.assertEqual(first["epochs_trained_this_run"], 1)

        second = td.run_train(
            store_path=self.store_path,
            out_dir=self.out_dir,
            epochs=3,
            vector_size=16,
            window=3,
            min_count=1,
            workers=1,
            seed=42,
            cool_seconds=0,
            resume=True,
        )
        # Resume should pick up at epoch 2 and train epochs 2 and 3 only --
        # i.e. 2 more epochs, not 3 (which would mean it restarted from 0).
        self.assertEqual(second["epochs_trained_this_run"], 2)
        self.assertEqual(second["start_epoch"], 2)


class CooldownTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.store_path = os.path.join(self.tmpdir, "fixture.store")
        self.out_dir = os.path.join(self.tmpdir, "out")
        build_fixture_store(self.store_path, n_docs=100)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_cooldown_pause_happens(self):
        sleeps = []

        def fake_sleep(seconds):
            sleeps.append(seconds)

        td.run_train(
            store_path=self.store_path,
            out_dir=self.out_dir,
            epochs=3,
            vector_size=8,
            window=2,
            min_count=1,
            workers=1,
            seed=1,
            work_seconds=0,   # force the duty cycle to fire every epoch
            cool_seconds=1,
            sleep_fn=fake_sleep,
        )
        self.assertTrue(len(sleeps) > 0)
        self.assertTrue(all(s >= 1 for s in sleeps))


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.store_path = os.path.join(self.tmpdir, "fixture.store")
        self.out_dir = os.path.join(self.tmpdir, "out")
        build_fixture_store(self.store_path, n_docs=300)
        result = td.run_train(
            store_path=self.store_path,
            out_dir=self.out_dir,
            epochs=2,
            vector_size=16,
            window=3,
            min_count=1,
            workers=1,
            seed=42,
            cool_seconds=0,
        )
        self.model_path = result["final_model_path"]

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_probe_in_vocab_word_returns_neighbours(self):
        model = td.load_model(self.model_path)
        result = td.probe_words(model, ["coffee"])
        self.assertIn("coffee", result)
        self.assertNotIn("error", result["coffee"])
        self.assertIsInstance(result["coffee"]["neighbours"], list)
        self.assertGreater(len(result["coffee"]["neighbours"]), 0)

    def test_probe_oov_word_fails_cleanly(self):
        model = td.load_model(self.model_path)
        result = td.probe_words(model, ["zzzznotarealword"])
        self.assertIn("zzzznotarealword", result)
        self.assertIn("error", result["zzzznotarealword"])

    def test_probe_pairs_similarity(self):
        model = td.load_model(self.model_path)
        pairs = [
            {"a": "I love this coffee shop", "b": "I love this coffee shop downtown"},
            {"a": "I love this coffee shop", "b": "xyz totally unrelated qux quux"},
        ]
        results = td.probe_pairs(model, pairs)
        self.assertEqual(len(results), 2)
        for r in results:
            self.assertIn("cosine_similarity", r)
            self.assertGreaterEqual(r["cosine_similarity"], -1.0001)
            self.assertLessEqual(r["cosine_similarity"], 1.0001)


if __name__ == "__main__":
    unittest.main()
