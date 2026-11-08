# Lectern v2: Prepare, Review and Ask Claude

As of 2026-11-07 · Kai

Prototype: https://claude.ai/artifact/NGZpWLW8sJ32KhhfCTGekT (HTML: `lectern-v2-prototype.html` in this folder) · Doc version: https://claude.ai/artifact/VbVx2VFrMtL23coFBijn7Z

The AI chat stops asking the user to configure context. It sees what's on screen, takes more with `@`, and looks up the rest of the lecture by itself. Around it, both views lose the header strip and the bottom bar, gain resizable side panes, and put Slide/Cards and Chat in tabs on the right.

## What changed

| Your point | v2 |
| --- | --- |
| Header text ("Card 2 from slide 1 Good", "Slide 2 Selected No cards yet") | Removed. The verdict shows on the verdict buttons, the source slides as chips inside the card, "use for cards" as a checkbox under the slide. |
| Review bottom bar takes space | Merged into the card's footer: pager on the left, Bad / Needs work / Good on the right, with their keys. |
| Source and Ask stacked | Tabs in the right pane. Review: Slide · Ask Claude. Prepare: Cards (from this slide) · Ask Claude. `A` opens chat, `S` opens the slide. |
| Panes not resizable | Left and right panes drag in both views (see Layout rules). |
| Chat feels like a terminal, small text box | Real chat (see How answers render): Markdown with tables, lists and quotes, slide citations with hover preview, a 3-line composer that grows to 45 % of the pane, Enter sends, Shift+Enter new line, Stop while streaming. |
| 2x2 context dropdowns | Gone. See next section. |

## How Ask Claude decides what it sees

**Rule: Claude sees what you see, and can look up everything else in the lecture.** The user never picks a scope; they only ever add or remove.

1. **Focus chip (automatic).** The composer always carries one chip for what's on screen: `Card 2 + slide 1` in Review, `Slide 2` in Prepare. It follows navigation live (blue dot). Remove it with × to ask without it; typing @ and picking "What I'm looking at" brings it back.
2. **Pinned chips (explicit).** Type `@` to attach a specific slide, a card, All slides or All cards. Pins stay until removed, so "All cards" survives several messages of bulk work.
3. **Lookup (automatic).** Every message also gets a compact index of the whole lecture. When the question needs more ("how does this relate to the takeover card?"), Claude opens those slides or cards itself. The answer shows what it read in one grey line ("Read card 2, slide 1 · searched the lecture, found card 14").

A novice never touches any of this and gets the right answer. A power user has `@` for precision. The trace line keeps it honest without settings.

| Old setting | v2 equivalent |
| --- | --- |
| Slides: Current slide | Default (focus chip) |
| Slides: All slides | Lookup does it automatically; `@All slides` forces it |
| Slides: No slide | × on the focus chip |
| Flashcards: This flashcard | Default in Review (focus chip) |
| Flashcards: All flashcards | `@All cards`, or just say "all cards" in the message |
| Flashcards: No flashcards | × on the focus chip |

## What Claude receives per message

| Part | Content | Cost |
| --- | --- | --- |
| Focus | Rendered PNG of the focus slide(s), their extracted text, the focus card (front, back, verdict, sources), the slide's note | Full |
| Pins | Same as focus for each pinned slide/card; All cards = the card list as JSON; All slides = extracted text of every slide | Full |
| Lecture index | One line per slide (number, title, first 120 chars of text), one line per card (id, front) | ~2–4k tokens, cached |
| Tools | `read_slides(pages)` returns PNG + text, `get_cards(ids)` returns full cards, `edit_cards(edits)` proposes edits | On demand |
| History | Last ~10 turns of this lecture's chat, plus learning points | Cached |

With the Claude CLI backend the tools are files in the job folder (`slides/007.png`, `slides/007.txt`, `cards.json`) and the prompt tells Claude to Read only the ones it needs. With the Messages API they are real tool definitions. Either way, the whole PDF is never attached to a chat message.

## Edits, feedback and learning points

- **Chat can change cards** (matches your local chat-edit work). Up to 3 cards: applied at once, shown as a diff block with Undo, and each changed card drops back to To review. More than 3 cards: shown as "Suggested changes to N cards" with Apply all / Dismiss. Nothing bulk happens without a click.
- **Needs work (3) stays the fast path.** It opens a feedback box inside the card; Enter sends it (Shift+Enter for a new line) and moves you to the next card. The revision runs in the background and lands on the card as a proposal (Accept ↩, Accept and mark Good, Discard). The exchange is also logged in the chat, so there is one history.
- **Flags** from Claude sit at the top of the card with "Fix it with Claude", which sends the fix request to chat.
- **Learning points** shrink from a blue panel to one line under the answer ("Noted for your cards: …") with × to drop it. Still distilled after each answer and still fed to the next Generate.
- **Answer actions** on hover: Copy, Make a card (new card prefilled from the answer), Retry.
- **No suggested follow-ups.** Answers don't end with clickable prompt chips ("Rewrite cards 8 and 13", "Quiz me"). They add noise under every answer; if a next step matters, Claude says it in one sentence and you type it. Only an empty chat shows a few starter prompts.

## Chat history

- **One chat per lecture**, shared by Prepare and Review. v1 had one thread per slide. That made the history disappear every time you pressed →, and it had nowhere to put lecture-level questions like the first one in your screenshot.
- **Every message remembers its context.** Your message is stamped with what was attached ("on Card 2 · Slide 1"). Claude's answer stores what it actually read, which is shown as the grey trace line.
- **Thumbnails show a chat mark** on slides that were discussed. Clicking the mark scrolls the chat to the first message about that slide.
- **New chat** (pencil icon) moves the current chat to Earlier chats and starts empty. Pins are cleared and the screen chip comes back. Learning points from the old chat stay, because they belong to slides, not to a chat.
- **Earlier chats** (clock icon) lists this lecture's past chats, newest first. Each has a title generated from its first question (at most 6 words), a date and a message count. Opening one makes it the current chat again, so you can continue it. Delete asks for confirmation inside the list. Nothing expires; it's small local JSON.
- **What Claude sees of the history:** the last 10 turns word for word, plus a 3-line summary of anything older. The summary is written by the existing Distil call, which already runs after each answer. Earlier chats are never sent.
- **Feedback and edits live in the chat too.** "Needs work" feedback shows up as a message pair. Chat edits keep their Undo until the card is changed again.

## Answer style (system prompt)

- Lead with the answer; 1–3 short paragraphs before any list.
- Use Markdown: bold key terms, tables for comparisons, numbered steps, `>` for a memory hook or example sentence.
- Cite slides as `[S4]` and cards as `[C12]`; the app turns them into chips.
- For a quiz, fill the `quiz` field instead of writing questions into the text.
- Never paste a whole card back; when changing cards, call `edit_cards` and say in one sentence what changed.
- If slides could not be read, say nothing about it in prose; the app shows the error (see the bug below).

## How answers render

- **Two shapes of message.** Your messages sit right-aligned in a bubble, with the context stamp above ("on Card 2 · Slide 1"). Claude's answers are full-width text with no box, so they read like a document rather than a terminal log. Body text is 13.5 pt with 1.55 line height.
- **Order inside an answer:** trace line ("Read card 2, slide 1 · …"), then the text, then the edit block if cards changed, then the learning-point line. Copy, Make a card and Retry appear on hover.
- **Markdown rendered:** paragraphs; bold and italic; small section headings (h4 size; larger headings are scaled down); bullet and numbered lists, one level of nesting; tables with a tinted header row in a rounded box that scrolls sideways when wide; block quotes with a left rule for memory hooks and example sentences; inline code and code blocks; links, which open in the browser; and LaTeX (`$…$`, `$$…$$`) through the MathJax renderer the card preview already uses.
- **Not rendered:** images and raw HTML, which are shown as plain text.
- **Citations become chips.** `[S4]` becomes a slide chip: hover shows the thumbnail, a click enlarges it in Review or jumps to it in Prepare. `[C12]` becomes a card chip that opens the card. A range like `[S4–6]` becomes one chip per slide.
- **Quizzes are structured, not Markdown.** When you ask to be quizzed, the reply carries `quiz: [{question, answer}]` next to `message` and `edits`. The app shows each question with its answer hidden until you click it.
- **Edit blocks** show a word-level diff (removed text struck through, added text highlighted). When fewer than about 45 % of the words survive, they show the old text struck through above the new one, because a word diff of a full rewrite is unreadable.
- **Streaming** shows "Reading slide 2…" until the first text arrives. After that, text renders one finished block (paragraph, list or table) at a time, so tables never flicker half-built.
- **Copy** copies the Markdown source.
- **SwiftUI note:** `AttributedString(markdown:)` handles inline styles only. Block rendering (lists, tables, quotes) needs a parser such as Apple's swift-markdown, mapped to SwiftUI views, with `Grid` for tables.

## Layout rules

- Three panes: list · stage · side panel. Left 150–420 px, right 300–680 px, stage takes the rest (min 360 px).
- Drag a divider to resize; drag past ~55 % of the minimum to hide the pane; double-click resets; arrow keys resize when the divider has focus. Toolbar buttons show/hide each pane.
- Widths are remembered per view (Prepare and Review differ: thumbnails want narrow, the card list wider).
- The right pane remembers its tab per view. Clicking a slide citation enlarges it in Review and navigates to it in Prepare, so chat stays open.
- Prepare's filter moved from the top bar to the top of the thumbnail list, which is what it filters, and shrank to All / Selected. "No cards" is dropped; the card count on each thumbnail covers it.

## Message behaviour

- **One answer at a time per lecture.** While Claude streams, the send button becomes Stop and you can already type the next message. Stop keeps the partial answer and marks it "Stopped".
- **Retry** sends the same question again with the context it had at the time, and replaces the answer.
- **Moving around while Claude answers** doesn't change that answer's context. The screen chip moves on and applies to your next message.
- **Background revisions** from "Needs work" run alongside the chat and never block the composer.
- **Errors are UI, not prose.** Unreadable slides, rate limits (shown with a retry time) and a logged-out Claude CLI (with an Open Settings button) appear as an error card with Try again. They never come back as an assistant answer.
- **Edit conflicts:** if you edit a card while Claude is changing it, Claude's edit is not applied. The edit block says "Card 8 changed meanwhile, not applied" and offers Apply anyway. This uses the base revision ID that chat edits already carry.
- **Drafts:** unsent text in the composer is kept per lecture when you switch views or lectures.

## Keyboard shortcuts

| Where | Key | Action |
| --- | --- | --- |
| Anywhere | A | Open Ask Claude and focus the text box |
| Anywhere | Esc | Leave the text field; close the menu or the enlarged slide |
| Review | ← → (or J K) | Previous / next card |
| Review | 1 / 2 / 3 | Good / Bad / Needs work (3 opens the feedback box) |
| Review | S | Slide tab; pressed again it cycles through the card's source slides |
| Review | U | Undo the last verdict or edit |
| Review | ↩ | Accept the proposal shown on the card |
| Prepare | ↑ ↓ (or ← →) | Previous / next slide |
| Prepare | Space | Toggle Selected |
| Chat and feedback box | ↩ / ⇧↩ | Send / new line |
| Chat | @ | Attach a slide, card, all slides or all cards (↑ ↓ ↩ in the menu) |
| Focused pane divider | ← → | Resize by 16 px |

## What stays the same

Generate sheet, Export to Anki, Library and Overview, module rules, the revision proposal model, Distil and learning points, and both AI backends (Claude CLI by default, Messages API as fallback) work as in v1. This redesign changes only the Prepare and Review windows and the chat inside them.

## Bug: "PDF-to-image tool isn't installed"

Not a design issue. The CLI backend asks Claude to Read `input.pdf`; Claude Code's PDF reading shells out to `pdftoppm` (poppler). Lectern launched from Finder or Spotlight doesn't have Homebrew on its PATH, and on a Mac without poppler it fails entirely. Claude then apologises in prose and answers generically, which is the worst outcome.

- Your local branch already adds `/opt/homebrew/bin` to PATH. That fixes Macs with poppler installed, not Macs without it.
- **Proper fix:** render the needed slides to PNG inside Lectern with PDFKit (you already render thumbnails) and extract their text, then hand Claude images + text instead of a PDF. No external dependency, fewer tokens, and it is what the lookup tools above need anyway.
- If slide rendering still fails, the job fails with a typed error that the chat shows as an error card with Try again, not as an assistant message.

## Data model changes

- `SlideThread` per page → `LectureChat` per lecture: `title`, `messages`, `summary`, `draft`, `archivedChats` (each a `LectureChat`). Learning points move to the lecture, keyed by slide, so they survive New chat.
- `ChatMessage` gains `context: [ContextRef]` (what was attached) and `read: [ContextRef]` (what Claude actually opened, for the trace line).
- `ThreadContext` and `FlashcardContext` are replaced by `ChatContext { followsScreen: Bool, pins: [ContextRef] }`, kept in window state, not persisted per thread.
- `ContextRef = .slide(Int) | .card(UUID) | .allSlides | .allCards`.
- Migration: merge each lecture's per-slide threads into one chat ordered by time; stamp each old message with `.slide(anchorPage)`.

## Open questions

- One chat per lecture instead of per slide: fine with you? It changes the model above.
- Decided (Kai, 7 Nov): Enter sends everywhere, in chat and in the card's feedback box; Shift+Enter adds a new line.
