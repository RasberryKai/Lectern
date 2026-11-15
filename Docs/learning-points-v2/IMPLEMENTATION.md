# Implementation

All changes are in one commit on `claude/project-thread-cdyohp` (on top of `main` at `6bb44b2`), plus these docs.

## Data model (`Sources/LecternCore/Domain/Models.swift`, `LectureChat.swift`)

All new fields are optional, or have defaults, and decode with `decodeIfPresent`, so older lecture files still load.

| Type | New field | Meaning |
|---|---|---|
| `LearningPoint` | `kind: LearningPointKind?` | `ownWords`, `misconception` or `understood`; nil on old points |
| | `difficulty: Int?` | Confused follow-ups before it landed, 0–3 |
| | `evidence: [LearningPointEvidence]?` | `messageID` plus a verbatim quote |
| | `draft: LearningPointDraft?` | `front`, `back`, and `replacesCardID` when it improves an existing card |
| | `cardIDs: [UUID]?` | Cards made from it, through the drawer or Generate |
| | `episodeEndMessageID: UUID?` | The last message of its discussion; the chat draws the end-of-concept line there |
| | `isPendingDraft` (computed) | `included && !reviewed && draft != nil && cardIDs is empty` |
| | `maximumWords = 30`, `maximumActivePerSlide = 3` | Limits |
| `ChatMessage` | `clicked: Bool` | The student marked this answer as the explanation that worked |
| | `suggestion: CardSuggestion?` | A Review recommendation attached to this answer |
| `CardSuggestion` (new) | `reason, cardID?, baseRevisionID?, front, back, sourcePages, state, createdCardID?` | An edit when `cardID` is set, otherwise a new card. `state` is `pending`, `applied` or `dismissed` |
| `Card` | `learningPointID: UUID?` | Where the card came from; Review shows "From your chat" |
| `CardDraft` | `learningPointID: UUID?` | Carries that link through `landGeneration` |
| `Job` | `allowsCardCreation: Bool?` | True for Review chat jobs; used to tell Review from Prepare |
| `LectureChat` | `pointCursor: Int?` | Messages before this index have been judged. Nil on old chats, so their history is never re-extracted |

## Background distillation (`Sources/LecternCore/AI/ChatDistillation.swift`)

This replaces the old `distilLectureChat` in `LectureChatRunner.swift`, which has been removed.

### Triggers (`ChatDistillationTrigger`)

- `.answer(jobID)`: after every successful lecture-chat answer. `JobRunner.run` calls `enqueueChatDistillation`. This pass also maintains the 3-line summary of older turns, as before.
- `.clicked(messageID)`: from `JobRunner.setChatAnswerClicked` when an answer is marked. Unmarking only clears the flag.
- `.chatEnded`: from `JobRunner.endChatDiscussions`, which is called by:
  - `LectureSession.newChat` and `openChat`, for the chat being left;
  - `LectureSession.endIdleChatDiscussions` (with `idleFor: 15 min`), which runs when a lecture window loads (`LectureWindow.load`).

  It does nothing when `pointCursor` is nil, or when no Prepare student message follows the cursor.

Passes for one chat are **serialised** through `JobRunner.distilChains`, so two triggers can't save the same point twice. Each pass is registered in `active`, so `waitUntilIdle` waits for it.

### Choosing what to do (`runChatDistillation`)

The **anchor** is the clicked message, or the last assistant message of the exchange.

- **Review anchor** (`isReview`: the job has `allowsCardCreation == true`) → `suggestionPlan`. It is skipped when:
  - the exchange already changed or added cards, unless the answer was clicked;
  - the anchor already has an applied suggestion;
  - the last 8 Review messages contain fewer than 2 student messages and nothing was clicked, because a first question can't show a reaction yet.
- **Prepare anchor** (`isPrepare`: a chat job, not Review, and no `.card` or `.allCards` in the message context), or `.chatEnded` → points plan:
  - the window is the messages from the cursor to the end (at most the last 30), filtered to Prepare messages;
  - it needs at least one student message, and slides that were read.

  When `pointCursor` is nil, it starts at the first message of the current exchange (or the student message before a clicked answer), and that start is saved.
- Card-context chats in Prepare ("Fix this flag…") get neither points nor suggestions, as before.
- If there's no plan but older messages need summarising, it makes a summary-only call. That prompt still says "Learning-point extraction is disabled for this exchange."

The pass makes one AI call, of `JobKind.distil`, on the same models as before (`AISettings.learningPointCLIModel` / `learningPointAPIModel`, or the chat's model on Codex). A new `AIRequest.outputSchemaOverride` selects the contract:

- `AIOutputSchema.chatDistillation`: `summary`, `closedThroughMessageID`, and `learningPoints[]` with `text, pages, kind, difficulty, evidence[], front, back, replacesCardID, mergesPointID, endMessageID`.
- `AIOutputSchema.reviewDistillation`: `summary`, plus `suggestion`, which is null or `{reason, cardID, baseRevisionID, front, back, sourceSlides}`.

The prompt rules are `ChatDistillationRules.pointInstructions` and `suggestionInstructions`. They encode the reaction table and the confused-versus-curious rule in CONCEPT.md.

The model sees:

- **Points:** chat lines (id, role, text, clicked; assistant text cut at 2,400 characters), a discussion state line, existing points on the read slides (including excluded ones), existing cards on those slides, and the read slides' text and notes, taken from the PDF with PDFKit.
- **Suggestions:** the target message, whether the exchange already changed cards, the chat lines, the discussed cards (with IDs and revisions), all card fronts, and the slide text.

### Validation in Swift (`validatedPoints`, `validatedSuggestion`)

**Points.** Each one is checked on its own; an invalid point is dropped and counted in the trace (`learning_points_rejected`), and the pass doesn't fail.

- `kind` must be a known value.
- `text` must be non-empty and **at most 30 words**.
- `front` and `back` must be non-empty.
- `pages` must be non-empty and **a subset of the slides read**.
- `endMessageID` must be in the window and at or before the closed-through message.
- **Evidence:**
  - every quoted `messageID` must be in the window, at or before the closed-through message, and its quote must appear in that message (`ChatDistillationRules.quote`);
  - at least one quote must come from a **student message or a clicked answer**.

  Matching ignores case, whitespace, `**`/`__` and curly quotes. "…" may skip text, but the parts must appear in order. The quote must be at least 4 characters.
- `replacesCardID` is kept only if it names an active card.
- `mergesPointID` is honoured only for an included point that has no cards yet, or for a point added in the same pass. A merge rewrites that point and makes it pending again.
- A non-merge point is dropped when:
  - its normalised text duplicates an existing point; or
  - any of its pages already has 3 included points.
- At most 4 points per pass.
- **Cursor:**
  - with `closeAll` (chat ended), it moves to the end;
  - otherwise it moves to just after `closedThroughMessageID`;
  - if neither applies and the cursor was nil, it is set to where judging started.

  It never moves backwards.

**Suggestions.**

- `front`, `back` and `reason` must be non-empty.
- An **edit** must name a discussed card, and its `baseRevisionID` must equal that card's current revision. The text must differ from the card, and its sources must be within the read slides plus the card's own sources.
- A **new card** must cite only read slides, and its normalised front must not duplicate an existing card's front.
- An applied suggestion is never overwritten.

## Reducer actions (`Sources/LecternCore/Domain/LectureReducer.swift`)

- `.acceptLearningPointDraft(pointID, front, back)`:
  - with `replacesCardID`, it applies a new revision (author `.ai`, reason "From your chat"), merges the point's pages into the card's sources, sets the card back to unreviewed, and links it;
  - otherwise it appends a new card with `learningPointID`.

  Either way it sets `point.cardIDs = [card]` and `reviewed = true`.
- `.skipLearningPoint(pointID)`: sets `included = false` and `reviewed = true`. The point then no longer feeds Generate.
- `.resolveCardSuggestion(chatID, messageID, apply)`:
  - **Apply, edit:** checks that the card's revision still matches, then applies a revision (reason "Suggested in Review chat") and sets the card back to unreviewed;
  - **Apply, new card:** appends the card;
  - **Dismiss:** marks the suggestion dismissed.
- `.landGeneration`:
  - sets `learningPointID` on generated cards and links the points;
  - when the generation replaces existing cards, it first clears point→card links and makes included drafts pending again, so cards the generation doesn't re-create go back to the drawer.

These three new actions are kept out of `LectureController`'s undo stack, because undo only reverts card text and can't remove an added card.

## Generate (`PromptBuilder.swift`, `JobRunner.land`)

- `PromptBuilder.chatCardDrafts(lecture:pages:replacesExistingCards:)` lists the drafts Generate must realise:
  - every included point on these slides that is still a pending draft;
  - when replacing, also pending drafts that improve an existing card, and points that already have a card, sent with that card's current text so they survive the replacement.

  The app always generates with `replaceExistingCards: true` (`LectureWindowModel.generate`).
- The prompt gains a `CHAT CARD DRAFTS` section, plus this instruction: return each draft as one card with `point` set to its id, tighten the wording if needed, write no other card on the same concept, and set `point` to null on every other card.
- The generated-card schema gains a required `point: string|null` field (`AIOutputSchema.generatedCard`). Revise keeps the old card schema.
- `INCLUDED LEARNING POINTS` now contains only points that are not drafts, each with its `kind`. Its label tells the model to write from the explanation rather than the slide's wording: a contrast card for misconceptions, and the student's phrasing for `ownWords`.
- The system prompt's precedence becomes `global rules < module instructions < slide text < chat card drafts and included learning points < explicit slide notes`.
- When generated cards land, valid `point` ids are linked, at most one card per draft. **Any expected draft the model dropped is appended as a card anyway.**

## App (`Sources/LecternApp`)

- `ChatMessageView`:
  - **Copy** and **Retry** stay in the existing lean hover style;
  - **Clicked** is added (it shows only on hover until it's on, then stays visible in green);
  - **Make a card** and `makeCard(from:)` are removed;
  - `CardSuggestionBlock` renders a Review suggestion: a word diff for an edit, front and back for a new card, with Apply / Add card and Dismiss.
- `AskPanel`: `ConceptEndLine` after a message that ends one or more points' discussions. It reads "Misconception cleared up", "In your words", "Clicked", or "Clicked after N tries", followed by "· N card draft(s)".
- `LearningPointDrawer`: rewritten for drafts.
  - Each draft shows chips (Misconception, Your words, "Took N tries"), slide chips, "improves Card N" when it replaces a card, and front and back.
  - Buttons: Skip, Edit (inline front/back fields) and Add (or "Update Card N"). The header has "Add all".
  - Points without a draft from before v2 keep the Keep / Drop row.
- `LectureChatModel`:
  - new `addChatCardDraft`, `addAllChatCardDrafts`, `toggleClicked`, `resolveSuggestion`, `showChat(for:)` and `pointsEnding(at:)`;
  - `newChatLearningPoints` now excludes points that already have cards;
  - `removeChatLearningPoint` dispatches `.skipLearningPoint`.
- `GenerateSheet` (`JobBar.swift`):
  - a new "From your chats · N cards" list (up to 5 rows, each with a kind chip) and a short note;
  - the old bullet that counted points from v1 slide threads now counts the remaining v2 points.
- `ReviewView`: the sources bar shows "From your chat" for a card with `learningPointID`; clicking it opens the chat at that discussion. Other cards still show "Edited" / "As generated".
