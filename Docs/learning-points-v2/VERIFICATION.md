# Verification

## Automated

```bash
swift build && swift test
```

The expected result is 190 tests in 27 suites, all passing.

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

## Manual QA (not done yet)

The app was **not** run during development, because opening a lecture would start AI calls against the owner's real library. Use a scratch library, or accept that real calls will be made.

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
- **Window.** At most the last 30 messages after the cursor are judged. Assistant text is cut at 2,400 characters in the prompt; evidence is still checked against the full text.
- **Cost.** Each Prepare answer still causes one Sonnet call (as before), and Clicked, New chat and idle each add one.
- **Review suggestion scope.** Only cards in the recent messages' context count as "discussed". There is one suggestion per answer; a newer pass replaces a pending one, never an applied one.
- **Old data.** Points from before v2 have no `kind`, draft or evidence. They still feed Generate as plain learning points, and the drawer shows them with Keep / Drop.
- **Legacy path.** The v1 per-slide-thread distil path (`JobRunner.land`, case `.distil`, and the `.distil` text in `PromptBuilder`) is unchanged and unused by the lecture chat.
