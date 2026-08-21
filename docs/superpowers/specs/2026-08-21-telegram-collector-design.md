# Telegram public-channel collector — design

**Date:** 2026-08-21
**Status:** approved in discussion, awaiting spec review
**Home:** BlueX, as the first component of the multi-platform social arm
(`tools/social/`). The user's stated intent: BlueX expands to more social media
platforms over time; Telegram is the template.

## 1. Purpose

Collect the public Telegram channels of the German far-right milieu — text, metadata
and forward provenance — to serve two BlueX goals:

1. **Training material** for the hate/incivility committee (milieu text at volume,
   including the cleanly-worded intolerance register).
2. **Propagation infrastructure**: forward edges between channels are the network
   signal for how content (later: AfD speeches, via the Zeitgeist corpus) moves
   through the milieu.

Corpus first; any use as training data goes through BlueX's existing
sampling-frame/provenance discipline. Human gold labels remain held-out and are never
drawn from this corpus without their own recorded sampling frame.

## 2. Decisions made (with rationale)

| Decision | Choice | Rationale |
|---|---|---|
| Channel scope | **Broader far-right milieu**, not only AfD-adjacent | Richer training data; user decision |
| List growth | **Seed + snowball with human review** | Published-list seeds keep criteria defensible; forward-graph candidates capture the shifting network; nothing collected without explicit approval |
| Content | **Text + metadata + media references**, no media files | Forwards/text carry the signal; media at milieu scale is TBs of mostly memes |
| Home | **BlueX**, `tools/social/telegram/` | User wants BlueX to grow into the multi-platform collector |
| Access | **`t.me/s/` web preview first**, MTProto only on demonstrated need | No account, no phone number, nothing to ban; the fallback (dedicated prepaid eSIM account) is decided on prototype evidence |

## 3. Access routes

**Route 1 (default): public web preview.** Every public channel serves
`https://t.me/s/<username>` — server-rendered HTML, no auth, paginated backwards via
`?before=<msg_id>`. Carries message text, date, view counts, forward attribution
("Forwarded from …"), reply links, and media type/thumbnail references. The prototype
task measures: completeness against a known channel, rate tolerance, and forward
metadata fidelity.

**Route 2 (fallback, only if route 1 measurably fails):** MTProto API via Telethon on
a dedicated research account (prepaid eSIM, number hidden by privacy settings; or a
Fragment +888 number). Requires a new decision from the user before setup — the spec
does not authorize it.

Never: the Bot API (cannot read channels it isn't in), free VoIP numbers (blocked),
the user's private phone number.

## 4. Channel list management

### Seed list

Compiled from published research: CeMAS reports, ISD Germany studies, Amadeu Antonio
Stiftung monitoring, plus the AfD-politician channels discoverable from the
abgeordnetenwatch roster (shared with Zeitgeist). Every seed channel records
`source_list` (which publication named it) and `inclusion_criterion` (verbatim, e.g.
"listed in CeMAS 2022 Telegram report, category Q-adjacent"). **The user reviews the
seed list before collection starts** — it is a deliverable, not a side effect.

### Snowball with review

The collector records the forward source of every forwarded message. Channels that
appear as forward sources accumulate evidence in `candidates`. When a candidate
crosses the proposal threshold (default: forwarded-from by ≥3 distinct tracked
channels or ≥20 total forwards), it appears in the review queue. A CLI report
(`python3 tools/social/telegram/candidates.py`) shows the queue with evidence;
the user approves or rejects; both outcomes are recorded with timestamps. No message
is ever collected from a channel that is not `status=approved`.

## 5. Storage

`/Volumes/Eregion/bluex-data/social/telegram.db` (SQLite). Consumers open read-only
(`?mode=ro`). Nothing under `/Volumes` enters git.

```sql
channels(username PRIMARY KEY, title, source_list, inclusion_criterion,
         status,           -- seed_approved | snowball_approved | rejected | retired
         added_at, decided_by_user_at)
messages(channel, msg_id, date, text, views,
         fwd_from_channel, fwd_from_msg_id,      -- forward provenance
         reply_to_msg_id, media_type, media_ref, -- reference only, never the file
         source_route,                           -- web_preview | mtproto
         fetched_at,
         PRIMARY KEY (channel, msg_id))
candidates(username PRIMARY KEY, forward_evidence_count, distinct_forwarders,
           first_seen, status, decided_at)       -- pending | approved | rejected
coverage(channel, day, message_count, min_msg_id, max_msg_id, gap_ids_json)
```

### Reconciliation

Telegram message IDs are sequential per channel. Gaps inside a collected range are
recorded per day in `coverage.gap_ids_json` as deleted/unavailable — never silently
skipped. A channel whose collection aborts mid-history keeps an explicit resume
cursor; a pass reports success only if every approved channel either completed or
recorded its failure reason (the BlueX zero-yield lesson applies: silence is the
failure mode being designed out).

## 6. Operations

- **Backfill** (full history per approved channel) runs as a supervised batch.
- **Incremental**: a daily launchd job fetches new messages for approved channels,
  using the established BlueX job pattern — heartbeat JSON, watchdog integration,
  EPERM-treated-as-retry-state, no crash-looping under KeepAlive.
- **Politeness:** per-host rate limit with jitter tuned during the prototype;
  descriptive User-Agent; back-off on HTTP 429/5xx. Staying polite is what keeps
  route 1 viable.

## 7. Ethics and legal basis

- **Public channels only.** Private or invite-only groups are permanently out of
  scope — different legal and ethical territory, not merely deferred.
- Collection is for scientific research into hate speech and its propagation
  (GDPR Art. 89 research context; documented lawful basis: legitimate
  interest/research exemption for publicly broadcast statements, many by public
  figures). Raw content is never redistributed; publications use aggregates and
  paraphrase/short quotation.
- Media files are not downloaded, which also avoids archiving illegal imagery.

## 8. Testing

- Golden-file test for the web-preview parser: one saved `t.me/s/` HTML page
  committed as fixture → exact expected messages (text, dates, forward attribution).
- Reconciliation test: a synthetic channel range with a known gap → gap recorded in
  `coverage`, run still reports the gap explicitly.
- Snowball test: synthetic forwards crossing the threshold → candidate proposed,
  not collected; approval → collected.
- Watch every new test fail before trusting it.

## 9. Out of scope (v1)

- Comment threads under channel posts (route-1 support is partial; revisit with
  evidence).
- Media downloads, clip/meme analysis.
- Other platforms — `tools/social/` anticipates them structurally; nothing is built.
- Classifier integration; any training use goes through sampling-frame discipline.
- MTProto setup (requires a separate user decision, §3).

## 10. Risks stated in advance

- **Route 1 may be rate-limited or degraded by Telegram at any time.** The
  `source_route` column and the resume cursors make a mid-corpus switch to route 2
  clean if it comes to that.
- **Seed-list bias:** the corpus's claim is only as good as the published lists'
  criteria; recording `source_list`/`inclusion_criterion` per channel makes the
  provenance auditable rather than pretending neutrality.
- **Channel churn:** milieu channels get banned/renamed frequently; `retired` status
  and the coverage ledger keep disappearance visible as data (when a channel died)
  rather than as a silent hole.
- **German-language legal exposure** (§86a StGB symbols etc.) is why media files are
  excluded and raw text is never redistributed.
