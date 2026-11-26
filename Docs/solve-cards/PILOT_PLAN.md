# Lectern Solve Cards Pilot Plan

Test solve cards through the regular **Generate → Review → Study** workflow after the feature is wired end to end. Start with slides and notes from real lectures, then study the approved cards in the existing mixed queue.

## First release

Solve cards are the feature. Mock exams, exam-driven scheduling, and exercise-sheet inputs are separate features. Library cleanup is open. For the pilot, add solve cards beside the existing formula cards and assess cleanup against specific examples later.

## Checking an answer and scheduling a card

**Check** tells you what matched the answer key. A check can mark individual fields, accept equivalent values such as `5/36`, `0.139`, and `13.9%` within the stated tolerance, and show a worked solution. If Lectern can’t read what you typed, it should tell you which field to fix.

**Got it** and **Missed** have the same job as on a flip card. If you used the right method and made a small arithmetic slip, you can choose Got it. If you squared the mean where you needed the expected squared value, you might choose Missed. Both buttons are available after Check. Your click records the Study grade.

**Repetition** means the same skill returns with a fresh case. A variance card might show a different probability table on the next attempt. Its schedule belongs to the card across all tables. The implemented scheduler and session settings govern due dates, intervals, and retries. When the existing retry flow brings the card back, give it an unseen case. If the pool is empty, defer the card with its due date intact.

## What approval covers

**Generate** creates one draft for Review with a skill, a source slide, an answer format, and one worked case. You can try that case and decide whether the exercise is worth studying. Approving the draft accepts those four things together. Generate the remaining cases in the background after approval, so rejected drafts and cards you switch back to flip never trigger a full batch.

Every new case still needs a trustworthy key. For the variance pilot, generate a valid probability table and calculate the expected values and variance locally. That makes a second AI solve unnecessary for this case family. A bad case can be taken out of rotation on its own. If a later proposal changes the skill itself, review the revised card before it returns to Study.

Example of a type switch. If a flip card teaches the variance formula and you add a solve card that asks you to apply it, keep the formula card and its history. The new exercise gets its own schedule. A full conversion workflow can wait until the pilot shows where it’s needed.

## Live workflow test

1. **Generate from a real lecture.** Choose one with a clear calculation skill, such as variance. Check whether Generate proposes a useful solve card with one worked sample and a source slide. Try the sample in Review. Approve one draft and reject or revise another to check that only approved drafts trigger variant generation.

2. **Study the approved cards.** Let the background cases arrive, then take the cards through Check and both ratings in the real queue. Try a correct response, a small slip you still rate Got it, and a mistake you rate Missed. Check that a retry uses a fresh case and that a card with an empty case pool keeps its due date.

3. **Exercise the other fields with real lecture material.** For a matching Grid, turn shuffle on across attempts and check that the displayed selections stay stable through feedback. Try the equivalent answers and edge cases defined in the brief for Number, Choice, Order, and Term. Track wrong keys, unclear feedback, cases that feel too similar, refill delays, and AI cost per approved card with usable cases.

4. **Keep a rollback point.** Use a separate branch or build and take a backup or test with a copy of the module. A code revert restores the app code. The module backup restores cards and review history written during the test. [Lectern Solve Cards Brief V2](BRIEF_V2.md)
