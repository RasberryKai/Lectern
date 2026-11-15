# Concept: learning points from what clicked

## The problem

The owner's own description of the problem:

- Everything gets extracted. Points can be longer than the answer, examples end up as points, and long slides cause learning-point inflation.
- Learning points should be the way flashcard generation draws on AI explanations, corrections and new insights. When a slide isn't enough and an explanation works, cards should be built from that explanation, not from the slide.
- The good signals are an explanation the student restates in their own words, or an AI answer they liked. The bad signals are an answer they rejected, follow-up questions asked because they didn't get it, or leaving for a new chat. The hard case is follow-up questions asked out of curiosity after an answer that was actually good.

## How it worked before

These findings come from an earlier audit and a read of the code at the time:

- A background Sonnet call ran **right after each answer**. It received the latest question and answer plus the **full text of every slide that was read**, and was asked to "extract at most 3 NEW grounded learning points".
- The prompt had no selection criteria. The older, stronger distil prompt in `PromptBuilder` was bypassed.
- Code checks were limited to: at most 3 points, non-empty text, pages within the slides read, and no exact-text duplicate. There was no length limit, no exclusion of examples, no relevance threshold, and no semantic deduplication.
- New points started as `included = true` and fed Generate before the student had seen them. Keep only marked a point as reviewed.
- Extraction was disabled for Review chat and card-context chat. That is intended and stays.

The structural flaw: an answer was judged before the student reacted to it, so the extractor couldn't know whether it worked.

## Evidence from real chats

This came from the owner's local library on 2026-11-15: 5 lectures with chats, about 165 messages, 71 saved points, 28 of them dropped. Points have no timestamps, so they were matched to chats by slide and content.

- **23 of the 28 drops** came from broad requests ("gist of everything", "explain this slide simply", "put each one into simpler wording", "explain these three"), from an answer the student said they already understood, or from talk about how to design flashcards.
- Kept points cluster on specific confusions, such as the commercial letter of confirmation, §354 fees, variance, and the expectation operator.
- **Only 3 of 43 kept points ever reached a Generate.** The owner generates first and chats afterwards. The points that fed Generate most often were study-method points that the student later dropped.
- The best material was already in the chats:
  - restatements the AI confirmed ("So the variance is the squared deviations on average?" → "Yes");
  - restatements the AI corrected ("the lower the curve, the higher the variance" → "not always");
  - the student correcting a card ("Scalability doesn't mean loss of efficiency").

## The concept

### Judge an answer by what the student does next

Extraction runs over a **discussion** (consecutive turns about one concept), and only once that discussion has **ended**. A discussion ends when:

- a later student message moves on to a different concept;
- the student marks an answer **Clicked**;
- the student starts a New chat or switches to another chat;
- the lecture is reopened and the chat's last message is at least 15 minutes old.

### Reading the student's next message

| Reaction | Verdict on the previous answer | Point |
|---|---|---|
| Lost: "don't get", "??", "simpler", "again", "like what is…", the same claim asked again | Failed | None from it; difficulty +1 |
| Restates it ("so X, right?") and the AI agrees | Understood, in the student's words | `ownWords` |
| Restates it and the AI corrects part of it | Misconception | `misconception`, stated as "Not X: Y" |
| Corrects the AI or a card, and the AI agrees | The student's own understanding | `ownWords` |
| Asks about something the answer introduced: a new term, an application, an edge case, a why | Landed | `understood` |
| "I got that part, the only thing…" | Not a struggle | None from that answer |
| Formatting, card or study-method talk | No signal | Never |
| Clicked | Landed | `understood` (or stronger) |
| A broad request with no specific follow-up | Unknown | None |

**The rule for confused versus curious:** is the follow-up about what the answer just explained, or about something the answer brought up? A "…right?" check is judged by the AI's reply: "yes" means understood, "not quite" means misconception.

### Stopping the inflation

- Zero points is the default. A discussion normally gives at most one point, and two only when it holds both a corrected misconception and a separate insight. A single pass returns at most 4.
- A point is written from the chat, never from slide text. The slide is used only to check facts and choose pages.
- A point is at most 30 words. Worked examples and example numbers are not allowed.
- The quote a point is based on must appear word for word in one of the student's messages, or in a clicked answer. Otherwise the point is rejected.
- A point that covers the same idea as an existing one is merged into it instead of being added.
- Each slide holds at most 3 active points.

### Points become cards

Each point carries a **card draft**: either a new card, or an improved version of an existing card. The drawer shows drafts, not points, with Add, Edit and Skip. Generate turns every pending draft into exactly one card and writes no competing slide card on the same concept. An explanation that clicked outranks the slide's wording; the student's own slide notes still win.

### Review chat is a separate concept

Review never creates learning points. Instead, after an explanation lands or the student clicks it, a background pass may recommend one edit to the card being discussed, or one new card. The student sees it with Apply or Dismiss.

## The owner's decisions (2026-11-15)

- **Keep the two concepts separate.** Learning points belong to Prepare chat; card edit and new-card recommendations belong to Review chat. Extraction in Review stays disabled.
- **Card drafts: yes.** They must be included in flashcard generation, so Generate knows that topic already has a card and doesn't write a competing one from the slides.
- **Gaps: no.** An unresolved concept never comes back as a quiz, now or later. Don't add extra functionality.
- **Buttons under an answer:**
  - keep **Clicked** ("this explanation is good, use it for a card");
  - remove **Make a card**;
  - keep **Copy** and **Retry** in the existing lean hover style, not the boxed buttons from the mockup.
- Everything else in the proposed redesign was approved.

## What was proposed but not built

- Coverage badges ("explained" / "gap") on slide thumbnails. Gaps were rejected, and "explained" wasn't built, to keep the scope tight.
- Backfilling existing chats. Old chats are not re-extracted, and old points without a draft still show Keep and Drop.
