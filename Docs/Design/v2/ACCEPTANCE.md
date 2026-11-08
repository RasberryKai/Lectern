# Lectern v2 acceptance map

The supplied `lectern-v2-design.md`, HTML prototype and screenshots are the reference. User confirmed Lectern as the target and one active chat per lecture with multiple saved chats, New Chat, history and reopening. Library, Overview, Generate sheet, export and module rules retain their workflows.

| Requirement | Implementation seam | Verification |
| --- | --- | --- |
| Three panes, separate widths and tabs per mode; drag, collapse, reset, keyboard resize | LecturePanes + LecturePaneState | Build + native UI exercise |
| Prepare filter over thumbnails; slide stage, selection and note underneath; related cards tab | PrepareView | Native Prepare exercise |
| Review search/chip filters, dots, editable front/back, sources, footer pager/verdicts | ReviewView | Native Review exercise |
| Flags and feedback proposal actions; word diff with full rewrite fallback | ReviewView + LectureWindowModel + existing reducer | Core tests + native exercise |
| Shared active lecture chat and history/New Chat/resume/delete; migration; lecture learning points | Core lecture chat model/session/store + AskPanel | Migration/lifecycle tests + native history exercise |
| Focus and pinned context; mention picker; frozen context per sent message | Window model + AskPanel + chat snapshot | Context tests + native navigation/mention exercise |
| PNG/text + compact index + lookup, both providers; no whole PDF chat dependency | Core snapshot and AI providers | Provider fake tests + isolated PDF rendering |
| Markdown, tables/quotes/code, citations/hover, math, quizzes, hover actions | ChatMarkdownView + AskPanel | Native content fixture exercise |
| Direct small edits/undo, gated bulk edits, stale conflicts/apply anyway | Core chat landing + AskPanel | Core concurrent-edit tests |
| Enter/Shift+Enter, growing draft, Stop/partial, retry snapshot, one answer per lecture | Composer + session/runner | Core lifecycle tests + native keyboard exercise |
| Feedback runs independently and logs chat; learning points survive/reset context on New Chat | Core revision/chat pipeline | Core tests + native exercise |

Status is tracked in the final verification report; this matrix is not a claim that checks passed.

## Chat images and mention-picker follow-up

| Requirement | Implementation seam | Verification |
| --- | --- | --- |
| Add images by picker, paste, and drop; preview/remove; image-only send | ChatImageAttachments + composer + chat model | Native attachment exercise; offline provider fixture |
| Image drafts, history, backups, frozen retries remain intact | Attachment metadata + LibraryStore + session/snapshot | Storage/backward-decoding/backup and snapshot tests |
| Current images reach both Claude backends; prior images remain available for follow-up | CLI Read validation + API image blocks/lookup | Offline CLI/API fixtures; no live inference required |
| Up/Down highlights and scrolls @ results; Enter/keypad Enter selects; Escape dismisses | Stable composer/native first-responder callbacks + picker | Native keyboard exercise, including zero matches |
| All slides replaces specific slide pins; All cards replaces specific card pins | ChatContext.pin + visible automatic context | Three context-selection tests + native chip exercise |

Images are normalized to PNG/JPEG with a maximum dimension of 2048 pixels. There is no image-count limit per message; images are limited to 5 MiB each and 10 MiB total. No image is sent before the user sends the message.

## Inline-deck context and pane-wide image drop correction

| Requirement | Implementation seam | Verification |
| --- | --- | --- |
| All cards plus uploaded images must not fail when the exact frozen deck was already supplied inline | ChatProviderContext.hasVerifiedInlineDeck + CLI context validation | Five regressions, including old frozen Retry format, missing/tampered data and failed image reads |
| Whole right pane accepts image drops, including transcript, header and Cards/Source | LectureSidePanel native drop overlay + shared pasteboard image import | Native external-file drag exercise |
| Compact drag cue appears on entry and disappears on exit/drop; normal text dragging remains available | Pane overlay + composer text-only drag registration | Native UI exercise + release build |
