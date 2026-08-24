# Labelling definitions — v1

**Status:** canonical. This file is the single source of truth for what the
labels mean. It is shown in the labelling interface, embedded in every LLM
prompt, and recorded per annotation as `definitionVersion: 1`.

**Provenance:** taken from Garland, Ghazi-Zahedi, Young, Hébert-Dufresne and
Galesic, *Countering hate on social media: large scale classification of hate
and counter speech* (arXiv:2006.01974), §2.1, so that BlueX results remain
comparable with that work. Quotations below are verbatim from that paper.

---

## hate  (key: 1)

> "insults, discrimination, or intimidation of individuals or groups on the
> Internet, on the grounds of their supposed race, ethnic origin, gender,
> religion, or political beliefs"

extended, in the same section, to:

> "speech that aims to spread fearful, negative, and harmful stereotypes, call
> for exclusion or segregation, incite hatred, and encourage violence against a
> particular group … be it using words, symbols, images, or other media."

**Therefore, to count as hate a post needs a target group or a member of one,
attacked *as* such.** The attack may be polite: the definition covers
stereotypes, calls for exclusion and incitement, none of which require profanity.

**Not hate under this definition:**
- Insults with no protected-group basis ("you fucking idiot", "grifting piece of
  shit") — these are *incivility*, and the corpus has a separate measure for it.
- Anger at an institution, outlet, party or politician *as an actor* rather than
  as a member of a group.
- **Discussing** hate, quoting it, or reporting on it ("racism in Japan is
  subtle…", a news summary about femicide).
- Harsh criticism, contempt or ridicule that does not invoke a protected
  attribute.

## counter  (key: 2)

> "a citizen generated response to online hate in order to stop and prevent the
> spread of hate speech, and if possible change perpetrators' attitudes about
> their victims."

**Counter speech is relational: it requires hate to be countering.** Judge it
against the parent and root shown in the interface. If the thing being replied
to is not hate, the reply is not counter speech, however admirable.

**Not counter under this definition:**
- Disagreeing with the article, the outlet, or a politician.
- Arguing against a factual claim.
- General pro-social or pro-tolerance sentiment posted into a thread that
  contains no hate.
- Attacking someone who is being obnoxious but not hateful.

## neutral  (key: 3)

Everything else — including uncivil, rude, sarcastic, aggressive or unpleasant
posts that meet neither definition above. **Neutral is not "polite".** Most of
the corpus is neutral.

## skip  (key: 0)

Genuinely undecidable *for you, on this text* — missing context, unclear
referent, unfamiliar language. A skip is recorded and revisitable. Prefer a skip
over a coin-flip: a guessed label silently corrupts the prevalence estimate,
whereas a skip is visible in the reporting.

---

## Notes on applying these

- **Judge the reply, using the parent and root only as context.** The question is
  what *this* post does, not what the thread is about.
- **The target test for hate:** can you name the group being attacked, and is it
  attacked *because of* the protected attribute? If not, it is very likely
  neutral (or incivility).
- **The hate test for counter:** can you point at the hate it responds to? If
  not, it is not counter speech.
- Consistency matters more than any individual judgment. When you change how you
  read a case, note it — a definition that drifts mid-pass is worse than one that
  is imperfect but stable.

## Version history and comparability

- **v0 (implicit, 2026-08-24, labels 1–91).** Labelled before this file existed,
  under a broader reading of both classes — the annotator's own assessment. The
  uniform-random base rate computed from those labels (hate 6.6%, counter 21.1%)
  is therefore a **v0 measurement** and is not directly comparable with anything
  labelled under v1. Counter speech in particular is expected to fall sharply,
  since v1 requires a hateful parent.
- **v1 (this file).** In force from the moment `definitionVersion: 1` starts
  being recorded.

Analyses must group by `definitionVersion` and must never pool versions silently.
If the v0 uniform labels are re-done under v1, keep both: the difference between
them is itself a measurement of how much the definition moves the prevalence.
