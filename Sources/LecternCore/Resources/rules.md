# Lectern card rules v1

Adapted from Flashcards-v9: content rules retained; clipboard syntax is replaced by the structured JSON contract. Examples using `==` illustrate front and back only. Return JSON, never clipboard lines or Markdown code fences. Use Anki \(…\) and \[...\] math delimiters. Slide notes override these rules.

## Answer phrasing: sentence first, label last

Write the answer as a plain sentence saying what happens or what the rule does. Put the technical term and/or the § in parentheses **at the end**, never at the start:

- Good: `The debtor renders the owed performance (fulfilment, § 362 I BGB)`
- Bad: `Fulfilment: the owed performance is rendered (§ 362 I BGB)`

Use one consistent pair of party terms throughout a deck (e.g. debtor/creditor, not mixed with obligor/obligee).

## The 30-second rule (overrides everything below, except explicit slide notes)

Kai runs through decks quickly: **read, answer, check, next — max 30 seconds per card.** Every card must pass that. Short is still the goal, but never at the cost of meaning.

- **One idea per card.** The answer carries one core point. A short qualifier or reason that makes the point understandable is allowed; a second independent fact is not. The only exception is a shortlist card (see below) for a short closed set that belongs together.
- **Answer: one short sentence at most.** Aim for under ~20 words. A word or phrase is fine when it is self-explanatory.
- **Question: as short as possible while still having exactly one right answer.** Aim for under ~20 words. Include the context needed to make the answer determinate.
- **No elaboration chains.** No "because…, which means…, therefore…" sequences, no examples tacked on, no caveats. The card tests the core point, not the full explanation.
- **One question per card.** Never "What is X, and why…?" — that's two cards.
- **Don't go deep on every concept.** Cover the key point of each concept, not every nuance. Fewer sharp cards beat many detailed ones. Skip minor details entirely.

### No buzzword answers

An answer must be meaningful on its own. A bare abstract label ("Legal certainty", "Efficiency", "Fairness") fails if someone seeing the card cold couldn't tell what it means or why it answers the question. Then state the concrete mechanism in a short clause instead.

Bad:

```
Why are declarations of intent voidable only in limited cases? == Legal certainty
```

Good:

```
Default rule if a declaration doesn't match the declarant's real will? == It stays binding unless the declarant can avoid it for mistake, misrepresentation or deceit/threat (§§ 119, 120, 123 BGB)
```

### No over-compression

Short must never mean cryptic. If the point only makes sense in a situation, put that situation in the question.

Bad (abstract, unclear what it means):

```
Can a single clause in an otherwise negotiated contract be AGB? == Yes, AGB control applies clause by clause
```

Good (scenario in the question, consequence in the answer):

```
Contract mostly negotiated, but one clause copied unchanged from the user's template: what applies to that clause? == It alone counts as AGB and faces full fairness control (§§ 305 ff. BGB)
```

### Make the scope explicit

If the answer covers only a subset of a broader question (e.g. the presumption cases, not all cases), the question must say so. Otherwise the card teaches a false 'these are the only ones'.

Bad: `When is an AGB clause presumed unfair? == ...` (reads as an exhaustive list of unfairness grounds)

Good: `Two situations in which an AGB clause is presumed unfair, though other clauses can still fail the general test? == ...`

Self-check every card: could Kai read and answer it in under 30 seconds? Does the answer carry exactly one idea (or one short closed set)? Would the answer still make sense to someone seeing it cold? If not, cut, split or sharpen.

Bad (too long, two independent facts):

```
When a firm finances an acquisition entirely with new debt, what does it cost in the short run, and why can the trade-off still pay off? == Higher interest burden and default risk reduce flexibility short-term; but the tax shield and disciplining effect of debt can raise firm value long-term
```

Good (split, short, still meaningful):

```
Main short-run cost of debt-financing an acquisition? == Higher default risk from the interest burden
Why can heavy debt financing still raise firm value? == Interest is tax-deductible (tax shield)
```

## Shortlist cards

Some content is a closed set that is learned and applied together: the requirements of a norm, the elements of a Prüfungsschema, the steps of a short procedure, the alternatives of a rule. Splitting such a set into single cards produces exclusion cues ("Requirement besides A and B?") that are hard to read cold and teach nothing about the set as a whole. For these, use one shortlist card.

Use a shortlist card only when all of these hold:

- **Closed set:** a fixed, complete list (statutory requirements, schema elements, named alternatives), not an open collection of arguments, examples or criticisms.
- **Belongs together:** in an exam you check or apply the items together.
- **Short:** 2–4 items, each a few words. If a set has more than 4 items, chunk it into sub-groups or card only the decisive items.
- **Still passes the 30-second rule.**

Format:

- The question names the set and states the count, so Kai knows when he's done: `Three requirements for valid representation? == ...`
- The answer numbers the items `1.`, `2.`, `3.`, each on its own line inside the JSON back string
- Items are one short clause each (§ at the end of the item or the card), no explanations. If an item is non-obvious, give it its own understanding card (what it means, why it matters, what happens without it) instead of explaining it inside the shortlist.
- Never write exclusion cues like `Third condition for X, beyond A and B? == C`.

Bad (exclusion cue, unreadable cold):

```
Agency requirement besides acting in the principal's name and declaring an own will? == Power of representation (authority)
```

Good (shortlist plus one understanding card for the item that needs it):

```
What does a valid representation require? == 1. The agent makes his own declaration of intent
2. He acts in the principal's name
3. He has power of representation (§ 164 I BGB)
What gives an agent power of representation? == The principal's actual permission to act on his behalf (Vollmacht)
```

Shortlist cards stay a minority of the deck. The default is still the single-idea 30-second card. Never use shortlists for arguments, objections, criticisms, examples or characteristics — split those into understanding cards or drop them.

## Core principle: transferable knowledge, not the material's examples

Slides, scripts and problem sets teach through concrete instances: a worked exercise, specific numbers, a sample company, a particular fact pattern. **Those instances are the vehicle, not the content.** Kai wants what he can apply to *any* new task of that type — in an exam, with different numbers, a different fact pattern, a different company.

So before writing cards, ask for each section of the source: *What general method, rule, principle or decision criterion is this example demonstrating?* Card that — and drop the example.

What to extract, in any subject:

- **Methods / procedures** — how to approach a type of task. Math: how to find local extrema of a composite function. Law: how to examine whether a claim exists (Prüfungsschema). Finance: how to value a project. Accounting: how to book a type of transaction.
- **Decision rules** — which tool, approach, norm or model applies in which situation type.
- **Conditions and triggers** — when a rule applies, when it fails, what must be checked first.
- **Principles and causal links** — why something works, what follows from what.
- **Typical pitfalls** — the mistake people characteristically make on this task type.

What to drop:

- Specific numbers, results and intermediate values of worked examples.
- The particular task, company, person, date or scenario used to illustrate a point.
- Step-by-step reproductions of one specific solution.

**The one exception: examples that carry new information.** Keep an example only if it teaches something the general rule alone does not convey — an edge case, a counterintuitive result, a pitfall, a case where the standard method fails. Even then, card the *lesson* of the example, not its numbers or details.

Bad (anchored to the example):

```
Where does f(x) = e^(x²−4x) have its local minimum? == x = 2
What did Company X's WACC come out to? == 8.4 %
What did Company X do in 2019? == ...
```

Good (transferable):

```
First step for local extrema of a composite function? == Derivative via chain rule, set to zero
Why can the outer function of e^(g(x)) be ignored when finding extrema? == e^u is strictly increasing, so it preserves extrema
How do you confirm a critical point is a minimum? == Second derivative positive
Which capital-structure weights belong in the WACC? == Market values, not book values
```

### Methods vs. the 30-second rule

A full procedure rarely fits on one card. Options:

- A shortlist card for the step sequence, if it has at most 4 short steps (see Shortlist cards).
- A card for the decisive move only — the step that is non-obvious or where people go wrong.
- A card for the selection decision: `Method for extrema under an equality constraint? == Lagrange multiplier`
- Cue-based step cards (`Step after finding critical points in a curve sketch? == Check second derivative`) only when the sequence is too long for a shortlist.

Skip trivial steps that any competent student does automatically.

## What a card must be

**Self-contained and general.** Decks get shared. Every card must be answerable by someone who never saw the source — a classmate who missed the lecture, a month from now, with nothing at hand.

*Never point at the source.* Never "the chapter", "the text", "the author", "this model", "the case above", "the exercise". Name the thing instead: not "What does the author criticize about the model?" but "Which Modigliani-Miller assumption do real markets violate most?"

Test every question: could someone who never saw this material answer it from the concepts alone — and would the answer still be useful on a different task of the same type? If not, rewrite it.

**Generalizing is not vaguening.** Strip examples and slide-dependence, but keep the parameter that makes the answer determinate. "What can happen when companies take risks?" is useless. "How do you find extrema?" is too broad; "First step for extrema of a composite function?" is right. Precise and short are not in conflict — cut words, not specificity.

*Exception:* when the specific case **is** the content (a landmark ruling, a named experiment, a canonical example the exam expects by name), keep it specific but name it in the question: `In BGHZ ..., what ...?` — never "the case from the lecture".

**Understanding over recall — in short form.** Prefer questions that fail if he only memorized wording, but keep them one-step so the answer stays short:

- How do you approach task type T? → the first / decisive step
- Which method/rule for situation S? → the method name
- Why does X follow from Y? → the one causal link, stated concretely
- What breaks if assumption Z is dropped? → the one thing that breaks
- Typical mistake when doing T? → the one pitfall
- What distinguishes X from Y (where easy to confuse)? → the single key difference
- Main cost of choosing X? → one cost (the benefit is a separate card)

Avoid list questions for open collections: "Name the three arguments...", "What are the characteristics of...". He does not want objections, criticisms, or argument lists memorized as lists. Closed sets like statutory requirements go on a shortlist card instead.

## Slide notes

When the source is slides, some slides carry **notes** at the bottom that explain the slide in more detail and often say what is particularly important and what is less important. These notes are critical input and must be read and respected:

- Use them to understand what the slide actually means — a slide's real content is often only in the notes.
- Let them set priority: cards for what the notes mark as important; few or none for what they mark as peripheral.
- Prefer the notes' explanation over the slide's compressed wording — but still compress it into the short card format.
- Notes often state the general takeaway of a worked example explicitly — card that takeaway, not the example.
- **Explicit card requests in notes win over the 30-second rule and the shortlist limits.** If a note asks for a specific card (e.g. one list card with front X and a short sentence plus § per item), build exactly that card, even if it has more than 4 items. Never split it.

## Law cards

Kai wants to understand what the law says, not memorize paragraph numbers. He can always look the § up.

- **Ask about the concept, situation or consequence, never about the paragraph.** No `What does § X say?`, no § in the question at all.
- **The § goes at the end of the answer**, in parentheses, as a reference.
- **Test what the rule does, not its wording.** A card that just restates the statute text fails. Ask what the rule changes in practice: what extra duty it creates, what happens to the clause, who bears the risk.

Bad (restates the statute, § in the question):

```
Standard for how a debtor must perform? == In good faith, taking customary practice into account (§ 242 BGB)
What does § 306 BGB say? == The contract stays valid if an AGB clause is invalid
```

Good:

```
Does a debtor only owe what the contract literally says? == No, good faith can add duties like informing, warning or taking care (§ 242 BGB)
What happens to a contract when one AGB clause is invalid? == The contract survives and statutory law replaces the clause (§ 306 BGB)
```

If the source contains a legal error (e.g. a slide's model answer contradicts the statute), card the correct law and flag the error in one line after the cards.

## The definition exception

Terms that must be known verbatim — accounting and legal terms above all (`equity`, `asset`, `liability`, `Verzug`, ...) — get the memorization form, still as short as possible:

```
Equity == Assets minus liabilities
```

This is the minority of cards. If more than roughly a quarter of a deck is `term == definition`, the deck is too shallow — rework it.

