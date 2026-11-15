# Verification

## Automated

```bash
swift build --disable-sandbox
swift test --disable-sandbox --no-parallel
```

The original feature had 190 Swift Testing tests. Audit regressions now cover extraction lifecycle, generation integrity, schema transport, and durable usage accounting. See the audit repair verification below for the current run.

| Test | Proves |
|---|---|
| `ChatDistillationTests.pointsWaitUntilTheStudentReactsAndKeepOnlyVerifiedOnes` | The first exchange alone saves no point, and the cursor starts at 0. After a confirmed restatement, exactly one point is kept: `ownWords`, a pending draft, with its end message set and the cursor at 4. These are rejected: an invented quote, a point over 30 words, and a point citing an unread slide. The points prompt and schema are the ones used |
| `…reviewChatNeverMakesPointsButSuggestsACardAfterTheExplanationLanded` | Review makes no learning points. A first question triggers no pass. After the student's confirming follow-up, a pending edit suggestion is attached and the card is unchanged until Apply. Apply updates the card and sets it back to unreviewed. A second Apply throws |
| `…clickingAnAnswerEndsItsDiscussion` | Clicked sets the flag and runs a pass that names the clicked answer. A clicked answer can stand in as evidence |
| `…draftsBecomeCardsAndGenerateKeepsThem` | Accepting a draft adds a linked card. Accepting a replacing draft revises the existing card. `chatCardDrafts` behaves correctly with and without replacement. Draft points are not repeated as plain learning points. Skip removes a point from Generate |
| `…generateLinksDraftCardsAndAddsAnyTheModelDropped` | Generate links the card the model returns for a draft and appends the draft the model dropped. No points stay pending |
| `…quotesMustAppearInTheMessage` | Quote matching: case, `**`, "…" gaps, rejection of text that isn't there, minimum length |
| `LectureChatV2Tests.learningPointsAreLimitedToSlideConversations` (updated) | Only slide conversations in Prepare keep points. Card-context and Review chats don't. A summary-only pass still works |
| `PromptTests.generateGoldenAndPrecedence` (updated) | The new precedence text, the `point` field in the generate schema, and the golden prompt (`Fixtures/prompt-generate.txt`, regenerated) |
| `JobDiagnosticsTests.backgroundLectureChatDistilFailureHasItsOwnTraceAndParentLink` | A summary-only pass fails loudly on invalid JSON, with its own trace and a warning on the parent answer |

## Things a reviewer should check in the code

1. **Prepare and Review stay separate.** `ChatDistillationRules.isPrepare` and `isReview` (`ChatDistillation.swift`) decide which path runs. Review must never write `learningPoints`.
2. **No point without evidence from the student.** In `validatedPoints`, the `fromStudentOrClick` check plus `quote(_:appearsIn:)`.
3. **No slide-text points.** The prompt says so. In code, the only enforcement is that pages must come from the read slides and that quotes come from chat messages. The text itself isn't compared with the slide. Judge whether that is enough.
4. **Generate can't drop drafts.** `JobRunner.land`, case `.generate`: the `expected` and `linked` logic.
5. **Cursor monotonicity.** `apply(_:to:chatID:)` only moves `pointCursor` forward.
6. **Backwards compatibility.** Every new field decodes when missing. `LearningPoint.kind` uses `try?`, so an unknown future value doesn't break loading.
7. **Undo.** The three new reducer actions are excluded from `LectureController`'s undo stack. Check that this is acceptable.

## Original manual QA checklist

The initial implementation had no native UI run. The audit repair run below uses an isolated scratch library and a local fake CLI; real model judgement remains unverified.

1. **Prepare.** Ask a specific question about a slide, reply "I still don't get it", get a second answer, then reply "So it means X, right?".
   - Expect: no drawer after the first answer.
   - Expect: once the AI confirms and you move to another topic (or press Clicked), a thin line appears ("In your words · 1 card draft") and the drawer shows one draft with "Took 2 tries".
2. **Broad request.** Ask "Explain this slide simply" and move on. Expect: no draft.
3. **Clicked.** Hover an answer. Copy, Clicked and Retry appear in the old lean style, and Make a card is gone. Click Clicked: it stays visible in green, and a draft may appear shortly.
4. **Drawer.** Use Edit, then Add: a card appears in Review with "From your chat", and clicking that opens the chat at the discussion. Use Skip: the draft disappears and doesn't show up in Generate. For a draft marked "improves Card N", use "Update Card N": the card is revised, and its revision history shows "From your chat".
5. **Generate.** With a pending draft, open the Generate sheet. "From your chats · N cards" lists it. After generating, the drafted card exists exactly once, linked, with no near-duplicate slide card on the same concept.
6. **Review.** Discuss a card, get an explanation, and reply in a way that shows it clicked (or press Clicked). A "Suggested change to Card N" block appears with a diff, and Apply updates the card. A formatting request ("make it shorter") gives no suggestion; it's handled directly, as before.
7. **New chat / idle.** End a Prepare chat mid-concept with New chat. Its last discussion is judged. Reopen a lecture whose chat has been idle for more than 15 minutes: the same happens.

## Known limitations and open questions

- **Closing the window** doesn't end a discussion. It's only picked up when the lecture is reopened after 15 minutes, or on New chat or a chat switch.
- **The per-slide cap counts every included point, including ones that already have cards.** A slide with 3 points that have cards blocks new points there, and merging only works into points without cards. One option is to count only points without cards.
- **Effort.** The distil call keeps `low` reasoning effort and a 2,048-token cap on the Messages API. Judging reactions is subtle, so consider `medium`.
- **Window.** Every unjudged message through the captured boundary is included; no older unjudged prefix is silently dropped. A long unresolved discussion can therefore increase input tokens. Assistant text remains cut at 2,400 characters; evidence is checked against the full text.
- **Cost.** The first Prepare answer without a student reaction skips extraction unless summary maintenance needs a call. Clicked, New chat, switching chats and idle can add checks, with no-op reasons logged separately. The durable V2 usage filter supports measured comparison on future sessions; offline tests cannot establish real provider token deltas or judgement quality.
- **Review suggestion scope.** Only cards in the recent messages' context count as "discussed". There is one suggestion per answer; a newer pass replaces a pending one, never an applied one.
- **Old data.** Points from before v2 have no `kind`, draft or evidence. They still feed Generate as plain learning points, and the drawer shows them with Keep / Drop.
- **Legacy path.** The v1 per-slide-thread distil path (`JobRunner.land`, case `.distil`, and the `.distil` text in `PromptBuilder`) is unchanged and unused by the lecture chat.

- **Semantic duplicates.** Repeated explicit draft IDs and exact text copies
  (ignoring case/whitespace) are deduplicated. A model that paraphrases a draft
  while incorrectly returning `point: null` can still create a semantic duplicate;
  the app does not guess provenance using unsafe fuzzy matching. The prompt
  requires the explicit draft ID and forbids another card testing its concept.


## Audit repair verification — 2026-11-15

The final serial offline run passed: **48 XCTest cases** and **212 Swift Testing
checks across 30 suites**, with the three opt-in live checks disabled. Command:

```bash
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lectern-review-module-cache \
CLANG_MODULE_CACHE_PATH=/tmp/lectern-review-clang-cache \
swift test --disable-sandbox --cache-path /tmp/lectern-review-spm-cache --no-parallel
```

New regression coverage:

| Suite | Cases covered |
|---|---|
| `ChatDistillationRegressionTests` (7) | Cursor persisted before inference; exit queued behind a held first summary; abandoned question rejected; old nil-cursor history skipped; historical click idempotence; retracted queued click skipped; all 40 unjudged messages retained through a captured boundary; later messages excluded; latest-state caps, merge page unions and normalized deduplication; unsuccessful jobs excluded |
| `LearningPointGenerationRegressionTests` (7) | Repeated explicit IDs; normalized null-label duplicates; split descendants/provenance; obsolete Review suggestions; pending draft changed during inference; linked card text changed during inference; current and in-flight source mappings |
| `AIUsageLogTests` (8) | Failed validation usage; skips versus unknown calls; per-round totals; incomplete multi-call accounting; explicit zero; credential redaction; damaged JSONL line recovery; retries counted once; nonzero CLI exit usage; actual Prepare/Review HTTP schema bodies and truncated-response usage |

Existing scope and Codex routing fixtures now wait for a reaction/click rather
than requiring an unnecessary initial extraction call. The app builds in Debug;
the final Release build and ad-hoc bundle signature verification also passed.

Native UI QA ran against `/tmp/lectern-v2-ui-qa` in an isolated app bundle using
`/tmp/lectern-v2-qa-claude`, a local fake provider. No live AI inference or real
library mutation was used. Verified:

- Settings All AI/V2 filters, backend and trigger breakdowns, Refresh, scrolling,
  and seeded totals (3 V2 calls, 3,500 input / 270 output tokens).
- Deleted source chat renders a noninteractive label; obsolete/missing-target
  suggestions disable Apply without a Card 0 label; valid Apply updates the card.
- Mixed drawer says Add drafts + keep; adding the draft creates one card and
  changes the legacy-only bulk label to Keep all.
- Generate preview counts one mirrored legacy point once and lists both current
  linked drafts. Fake generation dismisses the sheet and preserves exactly two
  linked cards, including the edited text.
- Source-chat navigation scrolls to its discussion; New chat archives it and
  Earlier chats restores it. Replacement makes old suggestions unavailable.

Independent static review identified accounting and source-preservation edge
cases; each concrete finding was fixed and covered. Unbounded unresolved-window
input growth and semantic duplicates from incorrectly null-labeled paraphrases
remain the explicit limitations above. These offline checks establish contracts
and persistence, not real model extraction quality or a measured provider token
comparison.
