# Lectern backend verification

2 November 2026. This records backend evidence; the SwiftUI frontend is the next implementation stage.

## Automated checks

| Check | Result |
| --- | --- |
| Swift 6 debug build and tests | Passed; 43 XCTest cases and 56 Swift Testing cases, zero failures. Two additional live-provider checks intentionally skipped. |
| Optimized release build | Passed without compiler warnings. |
| Offline end-to-end executable | Passed: PDF import → Generate → Revise → accept/approve → Ask → automatic Distil → Anki text export → portable backup/restore. |
| Independent implementation review | Completed. Findings were fixed and regression checks added; final focused review reported no concrete remaining cancellation or batch-update bug. |
| Repository hygiene | Legacy app edits preserved; build artifacts ignored; no migrated library, credentials, or personal source PDFs copied into the deliverable. |

Tests use temporary real files, an injected fixture provider, fake CLI child processes, and mocked HTTP/SSE. They cover the ported parser/math behavior, prompts, validation, history, proposals/splits, undo, serialization/recovery, module and lecture backups, scoped provenance, export journals, save/close behavior, cancellation during PDF preparation and auth, retry snapshots, queue limits, and partial batch updates.

## Module planning, Overview, and archive extension

The updated PNG designs are copied to `Design/overview.png` and `Design/module-settings.png`; `MODULE_PROGRESS_SPEC.md` records the implemented backend interpretation. This extension adds 23 regression cases covering settings/legacy JSON, date-only validation and time-zone/DST boundaries, ordered slots and totals, pace/deadline states, review/export/coverage transitions, archive enforcement/unarchive/export/backup, and archive racing PDF preparation without an inference call.

An isolated executable workflow also passed: save a 12-lecture plan and 14 December exam → verify 11 empty slots after one import → archive and verify Overview exclusion → reject a content edit → export Anki text and module backup while archived → unarchive with the original plan preserved. It used a temporary fixture library; existing installed-user data was not changed by this extension.

A fresh **GPT-6.1 Sol, medium reasoning** agent independently reviewed this extension as requested. It reproduced one P2: a failed archived single-lecture restore published an empty archived module and blocked retry. The fix validates the PDF before writing and stages the entire new module before a single rename. A missing/corrupt PDF → intact retry regression passes; the reviewer repeated its original CLI reproduction successfully and reported no new actionable findings on focused re-review. No live UI checks were substituted for backend tests.

Commands, from the standalone Lectern repository root:

```sh
swift test
swift build -c release
swift run -c release lectern demo
```

The final test and release runs used normal macOS service access. A restricted automation run stalled inside Apple's PDFKit → AppKit → TCC service initialization, as shown by a process sample. The same suite then passed outside that outer sandbox. `--disable-sandbox` disables SwiftPM's sandbox; it does not remove an automation host's sandbox.

## Installed-user migration

The new library is populated at `~/Library/Application Support/Lectern/Library`:

- 27 PDF lectures imported from the saved Slide Learning shared Projects folder.
- 24 Reviewer sessions imported as lectures without a PDF, containing 680 cards.
- Total: 2 modules, 51 lectures, 680 cards.
- SHA-256 checks matched all 105 original legacy JSON/backup/PDF files before and after migration.
- A repeated import of the same source paths in the rehearsal library skipped all 27 + 24 records with zero failures.
- Each lecture's provenance contains only that imported record, preventing unrelated Reviewer sessions from appearing in a single-lecture backup.

A friend's separate files were not identified or imported. Both copied Projects folders and Reviewer backup/session files have explicit import APIs and CLI commands. Source path namespaces prevent accidental cross-user identity collisions; keep copied imports at a stable path to preserve repeat-import detection.

Actual managed directories use `Modules/<module UUID>/Lectures/<lecture UUID>/`. Use `LibraryStore.sourceURL` and `jobDirectory` rather than constructing paths from the original design's illustrative lowercase layout.

## Findings fixed during review

- Preserve manual revisions and asynchronous results during saves/undo; flush pending edits on close.
- Avoid reusing old math decisions after text edits, original restoration, or changed proposals.
- Keep legacy sourceless split cards reviewable while requiring valid citations for PDF-generated cards.
- Keep module order and private PDFs intact during portable backup/restore.
- Scope raw import provenance to the current lecture.
- Cancel during auth/PDF preparation before inference can start; reap CLI processes and clear abandoned snapshots.
- Reset transient stream text on retry; preserve the immutable request/model/system prompt.
- Report per-card failures/skips for partially started update batches.
- Record exact exported revisions and recover interrupted multi-lecture export marking.
- Discover native CLI installations outside Finder's limited PATH; reject unverifiable subscription billing profiles.

## Remaining live checks

The installed Claude Code v2.1.205 was logged out. No login change, real inference call, API charge, or subscription-token extraction occurred. The logged-in `auth status` tier fields and strict gate need verification with the user's account; fixtures cannot prove compatibility. A real one-page and 11+ page PDF must also exercise the exact CLI permission rule and output envelope. An account may enable extra-usage billing even when subscription login is used.

Real Keychain UI, native window interactions, model quality, CLI PDF permissions, and Anki import/update/rendering/scheduling remain manual checks. Anki requires a one-time Lectern note type with `LecternID` as its first regular field. See `FRONTEND_HANDOFF.md` for APIs and the full frontend acceptance flow, and `INTEGRATION_RESEARCH.md` for official-source findings and distribution constraints.
