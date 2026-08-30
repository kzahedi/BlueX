# BlueX

## Copyrighted and third-party content

No publisher/third-party material may be available through this (public) GitHub
repository. This includes verbatim captures of platform pages (e.g. a Telegram
`t.me` preview page), real post/message text, real user handles or DIDs, or any
other scraped corpus content. Synthetic/hand-written test fixtures are fine and
belong in git as usual.

Such fixtures live only on the data volume, under
`/Volumes/Eregion/bluex-data/test-fixtures/<area>/` — never in this repo. The
corresponding `.gitignore` entries prevent them from being re-added by accident.

Tests that need a real captured fixture resolve its directory from the
`BLUEX_FIXTURES` environment variable, defaulting to
`/Volumes/Eregion/bluex-data/test-fixtures/telegram` (see
`tools/social/telegram/tests/test_preview.py`). When the fixture is absent, the
affected test class is skipped — never failed, never silently passed — with a
reason naming the missing path. Synthetic-markup tests in the same file that do
not depend on the captured fixture keep running unconditionally.

To run the fixture-backed tests, point `BLUEX_FIXTURES` at a working copy, or
rely on the default path if you already have the data volume mounted:

```bash
BLUEX_FIXTURES=/Volumes/Eregion/bluex-data/test-fixtures/telegram \
  python3 -m unittest discover -s tools/social/telegram/tests -v
```

This mirrors the existing precedent in this repo for
`tools/social/telegram/seed_channels.csv` (a private seed list, git-ignored,
tests skip via `@unittest.skipUnless` when it's absent — see
`tools/social/telegram/tests/test_seeds.py`), and the same policy just applied
to the sibling `zeitgeist` repo for its publisher/broadcaster fixtures.
