# BlueX

## GOLDEN RULE — no scraped data in GitHub

**Nothing obtained by scraping or API collection is ever committed to a git
repository.** Not as a test fixture, not reduced, not in a private repo.
Scraped material lives on the NAS or the data volume only.

Covers: platform/page captures (Telegram `t.me` pages, publisher HTML),
real post or message text, real account identifiers (DIDs, handles), corpus
rows, benchmark/label sets built from real posts, and seed lists naming
monitored channels.

Does **not** cover, and may be committed: our own code, docs and specs;
synthetic or hand-written test data; *amtliche Werke* (e.g. Bundestag plenary
protocols, §5 UrhG); metadata-only artefacts such as sealed pre-registration
manifests (hashes and counts, never content).

Collecting for research is lawful (§60d UrhG text-and-data-mining exemption,
given lawful access). *Republishing* verbatim is not — press publishers also
hold the ancillary right (§87f–h UrhG / Art. 15 DSM), and real accounts paired
with speech labels raises privacy questions beyond copyright.

**How to comply:** fixtures resolve from `BLUEX_FIXTURES` (default
`/Volumes/Eregion/bluex-data/test-fixtures/`), tests **skip with the missing
path named** when it is absent — never fail, never silently pass. Add a
`.gitignore` entry for every such path and verify it with `git check-ignore`.
When a leak is found: purge **every ref** (force-pushing `main` alone leaves
stale branches carrying it — measured 2026-08-30), then verify by cloning
fresh from the remote rather than trusting the local checkout.

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
