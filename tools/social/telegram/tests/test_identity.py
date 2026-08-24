import unittest


class TestCanonicalChannel(unittest.TestCase):
    def test_lowercases(self):
        from tools.social.telegram.identity import canonical_channel
        self.assertEqual(canonical_channel("FrankKraemer"), "frankkraemer")
        self.assertEqual(canonical_channel("QUERDENKEN_711"), "querdenken_711")

    def test_strips_leading_at(self):
        from tools.social.telegram.identity import canonical_channel
        self.assertEqual(canonical_channel("@FrankKraemer"), "frankkraemer")

    def test_strips_surrounding_whitespace(self):
        from tools.social.telegram.identity import canonical_channel
        self.assertEqual(canonical_channel("  FrankKraemer  "), "frankkraemer")
        self.assertEqual(canonical_channel(" @FrankKraemer "), "frankkraemer")

    def test_idempotent(self):
        from tools.social.telegram.identity import canonical_channel
        for raw in ("FrankKraemer", "@FrankKraemer", "  QUERDENKEN_711  ",
                    "already_canonical"):
            once = canonical_channel(raw)
            twice = canonical_channel(once)
            self.assertEqual(once, twice)
            self.assertEqual(once, once.lower())


if __name__ == "__main__":
    unittest.main()
