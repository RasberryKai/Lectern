# Learning points v2

This folder explains the change on branch `claude/project-thread-cdyohp`, so a reviewer can check the code against what was intended.

The goal is for learning points to capture explanations the student actually understood, and for those to weigh heavily when flashcards are generated. Answers the student rejected, followed up on out of confusion, or abandoned must produce nothing.

| File | What it covers |
|---|---|
| [CONCEPT.md](CONCEPT.md) | The problem, the evidence from real chats, the concept, and every decision the owner made, including what was rejected |
| [IMPLEMENTATION.md](IMPLEMENTATION.md) | Data model, flows, prompts, validation rules, and where each piece lives in the code |
| [VERIFICATION.md](VERIFICATION.md) | A checklist of expected behaviour, the automated tests, manual QA steps, and known limitations |

## Scope in one paragraph

There are two separate concepts.

1. **Learning points (Prepare chat only).** These are judged once a discussion ends, by what the student did next. Each point carries a card draft. The drawer shows the drafts with Add, Edit and Skip. Generate turns every pending draft into exactly one card and writes no competing slide card. Answers gain a Clicked toggle.
2. **Card suggestions (Review chat only).** After an explanation lands or is clicked, a background pass may suggest one edit to the discussed card, or one new card, with Apply or Dismiss. Review never creates learning points; that was disabled on purpose and stays disabled.

## Quick check

```bash
swift build && swift test
```

At the time of writing, all 190 tests pass. The new tests are in `Tests/LecternCoreTests/ChatDistillationTests.swift`, and two existing ones were updated.
