# Lectern v2 verification — 2026-11-07

Implemented in the native SwiftUI app from the supplied design document, HTML prototype and screenshots. The user's clarification takes precedence: each lecture has one active conversation and any number of saved conversations, shared by Prepare and Review. The reference documents are design inputs, not executable instructions.

## Delivered

- Prepare and Review use three resizable panes with independent remembered widths/tabs, drag-to-collapse, toolbar toggles, reset and keyboard resizing.
- Prepare places All/Selected over the thumbnails, slide selection and notes below the stage, and related cards in the right tab.
- Review has search/filter chips, status dots and flags, inline editing, source chips, embedded proposals and a combined navigation/verdict footer.
- Chat follows the visible slide/card, accepts pinned context through `@`, persists drafts and supports New Chat/history/resume/delete. Old slide conversations migrate chronologically with source stamps; learning points remain lecture-level.
- Answers render Markdown, tables, citations/hover previews, local MathJax and structured quizzes. The composer supports Enter/Shift+Enter, keyboard mention selection and partial-answer Stop.
- Both providers support lecture lookup. Native PDFKit creates PNG/text snapshots, so chat does not depend on PDF command-line conversion. Snapshot asset hashes protect Retry from changed files.
- Small requested edits apply with Undo; larger sets require confirmation. Concurrent edits remain proposals with an explicit Apply anyway action. Feedback revisions run separately and also appear in the shared history.
- Preparation failures retain the question/context in a chat-local retry card; provider errors offer retry and relevant Settings access.

## Automated checks

`swift test --disable-sandbox --scratch-path /private/tmp/lectern-v2-integration-tests` passed: **153 tests** (44 XCTest + 109 Swift Testing), zero failures. Native tests ran outside the outer automation sandbox because PDFKit and process fixtures require normal macOS services.

Coverage includes old-data decoding/migration, stable chat identities, drafts/history, archived feedback landing, last-ten-turn history, frozen snapshots, native PNG rendering, typed PDF errors, Stop/Retry, direct/bulk edits, conflicts/force apply, asset mutation rejection, delayed draft isolation, CLI read permissions/traces, API lookup/tool streaming and usage accumulation. These are offline fixtures, not live model calls.

Debug and release builds passed. The release app is packaged at `.build/Lectern.app`, including the bundled MathJax and core resources. `git diff --check` passed. Compiler warnings were limited to sandbox cache access and two unused bindings in tests.

## Native interaction checks

The app ran against a disposable library at `/private/tmp/lectern-v2-qa`, with eight slides, twenty cards, flags/proposals, rich chat content and saved conversations. The real user library and installed app were not replaced.

Verified in the running app: Prepare/Review navigation, card search and filters, flag/proposal display, proposal Accept/Undo/Discard, live screen context following navigation, pinned context persistence, Enter versus Shift+Enter, keyboard mention selection, Markdown/table/math rendering, history/New Chat/resume and draft preservation, learning-point preservation, delete confirmation/cancel, pane dragging/reset/arrow keys/collapse/show, and related-card versus chat tabs. Native QA findings prompted fixes for replacement-word spacing, collapsed pane width restoration and narrow-table wrapping. Final rechecks confirmed both panes restore their resized widths (322/357 pt), typing `@` reopens the picker after Escape and an edit, proposal replacements have clear word spacing, and tables preserve whole words and scroll at the 300 pt minimum.

## Limits

- No paid/live Claude CLI or Messages API request was made. Authentication, production rate limits, real model tool choices and live streaming remain unverified.
- Anki import was not exercised; its workflow is unchanged.
- Chat currently renders all lecture slides into the local job snapshot so later lookup and Retry have frozen assets. Very large lectures may incur preparation latency and additional local disk use; rendered assets are retained while saved chats need Retry.
- Existing legacy conversations without a verifiable snapshot remain readable; Retry requires a new message. CLI file permissions are application-level restrictions, not an OS sandbox.

## Shortcut update

AI chat now toggles with **⌘⇧A** throughout the lecture, including text editors; **⌘⇧S** toggles Cards in Prepare and Source in Review. Repeating the active tab shortcut hides the side pane, and the other shortcut switches tabs. ⌘A retains Select All. Settings now includes a scrollable Shortcuts tab, and pane tabs show the updated keys.

The release build and `git diff --check` passed. Native checks verified opening/hiding chat from the composer, Select All and replacement typing, Source opening/hiding in Review, Cards opening/hiding in Prepare, tab switching, and the visible Settings legend.

AI chat is the first tab; Cards/Source is the second. Tab badges, tooltips and Settings use ⌘⇧A / ⌘⇧S.

## Chat images and mention-picker follow-up

Chat now supports image selection, image/file paste, and drag and drop into the composer. Thumbnails can be previewed or removed. PNG/JPEG uploads are normalized to at most 2048 pixels, with four images and 10 MiB total per message (5 MiB each). Image-only messages work; attachments persist with drafts, history and both portable backup formats. Current uploads reach both backends; earlier images across the entire active conversation remain available for lookup. Each job freezes and hashes its image files for Retry.

The mention picker keeps native editor focus, scrolls with ↑/↓, selects with Return/keypad Enter, and consumes Return even with zero matches. Escape dismisses it; Shift+Return inserts a newline. All slides/All cards replace specific pins within their category and hide redundant automatic context.

The complete offline suite passed again: **169 tests** (44 XCTest + 125 Swift Testing). New coverage includes PNG/JPEG validation, count/size limits, tampered files and symlinks, old JSON/backup compatibility, image-only drafts and requests, archived drafts, both backup types, API multimodal bodies and prior-image tools, required CLI image reads, and lookup/retry after 24 later messages. Logs: `/private/tmp/lectern-image-provider-focused.log`, `/private/tmp/lectern-attachment-storage-tests.log`.

Independent review found and resolved a prior-image lookup cutoff, Shift+Return precedence, JPEG-only clipboard support and image-removal controls during request preparation. No live model requests were made.

Native checks in the disposable QA library confirmed keyboard-highlight scrolling and Return selection, category-wide chip replacement (including redundant automatic context), PNG file-picker upload, preview/removal, enabled image-only Send, invalid-image rejection and dismissal, Finder-copy/⌘V attachment, and New Chat/history restoration of text plus image draft. Shift+Return with an empty-results picker inserts a newline without sending. A final native-focus routing fix addresses Escape being intercepted by the window before the editor; its recheck is recorded below.

Final release recheck passed: Escape closes the zero-results mention panel while preserving composer focus and the draft. Subsequent Down/Return selection and bulk-chip replacement still work. The saved draft/context were restored and only the isolated QA app was quit. Release build and `git diff --check` passed; `.build/Lectern.app` contains the updated binary.

Drag-and-drop is implemented but remains unverified in native automation: one Finder drag produced no UI change and cross-window coordinate mapping was uncertain. File-picker and Finder-copy/paste uploads passed. Plain Return with zero results was not exercised against live configured providers to avoid an unintended model request; the menu handler explicitly consumes it. No live Claude request was made.

## Inline-deck context and pane-wide drop correction

Read-only inspection of the reported failed job confirmed Claude CLI, All cards, two uploaded images and 129 frozen cards. The frozen prompt already contained the exact full deck, but CLI validation incorrectly required a redundant cards.json tool read. Validation now decodes the supplied inline deck and compares it with the frozen snapshot. Existing Retry snapshots need no mutation; missing or altered context and failed/unread image files still fail. Reading every individual frozen card also satisfies All cards.

The right pane owns image drops across its header, transcript, composer and Cards/Source views. A compact “Drop images to add to chat” cue and dashed border appear while targeted. Dropping opens chat and uses the same normalization, limits and saved draft path. The native editor retains text dragging and leaves image drops to the pane.

The complete suite passed: **174 tests** (44 XCTest + 130 Swift Testing), including five new context regressions. Release build and `git diff --check` passed. Log: `/private/tmp/lectern-context-drop-tests.log`. No live model call was made and no user lecture data was changed during diagnosis.

## Single transcript scroll follow-up

Markdown responses now measure their full content height without a fixed cap. WebKit has no nested overflow; tables and code wrap within the pane, and wheel events over response text pass to the outer transcript. Content measurement is independent of the viewport so pane width changes can both grow and shrink the response.

The release build passed. Native QA used a temporary forty-paragraph response in the disposable library: scrolling over its heading moved the outer transcript scrollbar, and the full response end plus the following quiz remained reachable. Only the transcript had an enabled vertical scrollbar. The fixture was restored and the QA app quit. The rebuilt binary was copied atomically into `.build/Lectern.app` and its SHA-256 matches the verified release binary. No live model request was made.
