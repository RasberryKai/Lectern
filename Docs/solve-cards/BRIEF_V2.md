# Lectern Solve Cards Brief V2

Solve cards let you practice applying a skill in Lectern. You get a checkable exercise, see how your answer compares with the worked solution, then choose **Got it** or **Missed**. The card returns through the existing Study scheduler with a fresh case.

## Release scope

Generate solve-card drafts from lecture slides and notes. Approve them in Review and study them alongside flip cards in the existing queue. Mock exams, exam feedback, and exercise-sheet inputs are separate features. Library cleanup is undecided and can be evaluated on specific examples after the pilot.

## What becomes a solve card

A solve card tests a skill you can apply to different cases. Use one when the facts, inputs, or context can change meaningfully and Lectern can check the answer locally. A definition or formula can stay a flip card alongside a solve card that asks you to apply it.

Keep each exercise to one task or a few related steps. For example, a variance card gives a probability table and asks for E(X), E(X²), and Var(X). Each new table should test the same skill at a comparable difficulty. Give each draft a source slide, a one-line reason it belongs in Solve, and a short description of what can vary. In Study, show the case and answer fields before revealing any topic label that would give away the method.

## Generate and approve

1. **Draft one worked case.** Generate proposes the skill, source, answer fields, and one sample with its key and explanation. Review lets you try the sample, approve it, reject it, or request a change before spending on more cases.

2. **Make variants after approval.** Approval accepts the exercise design and the sample you saw, then triggers background preparation of the remaining cases. Each later case needs valid inputs and a trustworthy answer key. For calculation families like variance, have Lectern compute the result directly. A second AI solve is optional.

3. **Refill verified cases ahead of Study.** Generate and validate cases outside the session. Keep them available locally. Remove an individual bad case without resetting the card’s review history. If the exercise changes to test a different skill, send the revised draft through Review.

Type changes should be proposed in Review. If an existing flip card teaches a useful rule, keep it and its history when adding a solve card for applying the rule. The new card starts its own schedule. A general conversion workflow can follow once the pilot establishes what it needs to handle.

## Check and rate in Study

1. **Answer and check.** Lectern checks the response locally, indicates which fields matched, and shows the worked solution. If an input can’t be read, identify the field and let the learner fix it. Explain a specific mistake when the submitted answer supports the diagnosis. Make the source slide and Ask AI available from the result.

2. **Choose Got it or Missed.** Both buttons are available after feedback. For example, you can choose Got it after an arithmetic slip if you knew the method. The choice records the Study grade. The check result is feedback.

3. **See a new case when the card returns.** Follow the implemented scheduler and session settings for due dates, intervals, and retries. Keep one schedule per card across all its cases. On an existing session retry, use another unseen case. If no verified unseen case is available, defer the card and keep its due date.

## Answer fields

A solve card can ask for a single answer or several related answers. Each case supplies the prompts, expected answers, and a worked explanation. **Check** reports results per field. The learner’s Got it or Missed choice is the Study grade.

### Number

Enter a quantity, signed amount, or date. The field declares the unit, accepted formats, and any rounding or tolerance. For a probability, `5/36`, `0.139`, and `13.9%` can all pass within the stated tolerance. For a signed amount, the sign is part of the answer. Accept decimal and grouping separators according to the displayed format. Compare dates as exact calendar dates and reject impossible dates as invalid input.

### Grid

Fill a table with typed fields. For a booking, each row can have Account, Debit, and Credit. State whether row order matters. When it is flexible, compare complete rows and count repeated rows separately. Mark individual cells or missing rows in the feedback.

For matching, each title has its own dropdown drawn from a shared list. An option can be used for multiple titles, and the list can include distractors. **Optional shuffle** changes the option order between attempts. Keep that order stable through Check and compare each title with the selected option, regardless of display position.

### Choice

Pick one answer or select all that apply. True or false is a two-option pick-one case. For select-all, keep the number of correct options hidden and check the exact selected set. If offered, **None of these** is exclusive and is correct when the answer set is empty. Highlight selected distractors and correct options the learner omitted, and give a short reason per option. Use plausible distractors and vary which choices are correct across cases where the skill allows it.

### Order

Arrange the supplied items in a sequence, such as the steps of a check. Compare the submitted order with the expected sequence. If a task has more than one valid sequence, include those sequences in the case key. Show the correct order after Check.

### Term

Type a short answer into a fresh context, such as a sentence with a blank. The case key lists accepted words or aliases for that context. Apply language-appropriate rules for case, articles, and spelling. A one-character typo can pass when it unambiguously matches an accepted word. For a Chinese vocabulary card, the key can accept Hanzi and pinyin and specify whether tones matter.

## Live testing and open decisions

Implement the end-to-end feature and use the regular **Generate → Review → Study** workflow for the first test. Start with a real lecture that produces a clear calculation card, then use lectures that exercise matching and the other field types. Generate drafts, approve them, wait for background variants, and study the generated cards in the mixed queue.

Use those sessions to tune the variant pool size, refill threshold, and answer-key validation for different exercise families. Evaluate library cleanup separately when specific duplicates or look-alike cards are worth consolidating. [Live test plan](PILOT_PLAN.md)
