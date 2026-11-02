# Lectern frontend

`Sources/LecternApp` implements the v1 screens on top of `LecternCore`, following [FRONTEND_HANDOFF.md](FRONTEND_HANDOFF.md). The backend is used as-is; the app adds no domain logic, validator or persistence of its own.

## Structure

| Area | Files | Notes |
| --- | --- | --- |
| App and library state | `App/AppModel.swift`, `App/LecternApp.swift` | One `LibraryStore`, one `JobRunner`, one `LibraryService`. Bootstrap runs once before any lecture window opens; its migration report is shown when something was imported, failed or interrupted. Dashboard reloads on job events, app activation, day change and time-zone change. |
| Providers | `App/Providers.swift` | The runner is created once with two `ConfigurableProvider`s that build `ClaudeCLIProvider` / `MessagesAPIProvider` per call from the current settings. Changing the CLI path, API version or output limit therefore applies to new jobs without discarding the runner; running jobs keep their provider. |
| Design | `Design/Theme.swift`, `Design/Format.swift` | Tokens from the screens (ivory, charcoal, green, AI blue, amber, red, stage colours, diff colours), light and dark. All date/number/status wording lives in `Format`. |
| Library window | `Library/*` | Sidebar (done/planned per module, New module, Archived, backend status, Settings), Overview (four totals, slot strips, pace badge, typed Next up routing), module library (lecture table, planned slots, PDF drop, instructions, global rules), Module settings sheet (draft, planned stepper with live minimum, optional date-only exam, separate Archive/Unarchive), Export to Anki. |
| Lecture window | `Lecture/*` | One `LectureSession` per window. Prepare: ported thumbnail renderer, coverage/Q/Note badges, All/Selected/No cards, focus separate from selection, notes buffer, Ask panel with context chips, learning points (edited inside a store mutation), Propose update, Generate sheet, job bar, landing banner. |
| Review | `Review/*` | Filters with counts, card list, front/back editors via `stageCardEdit`, ported MathJax preview, ambiguous-math choices, issues, feedback with ⌘↩ revise and Make module rule, proposal word diff with Accept and approve / Accept / Edit first / Discard, split proposals, source pane, shared Ask thread, verdict bar. |
| Settings | `Settings/SettingsView.swift` | Backend and models, CLI path, API key (Keychain only), rules editor with content-hash version, API cost summary, importing a friend's legacy folder or sessions file. |

## Decisions worth knowing

- **Presentation names and context.** Rename from a lecture row’s context menu or click the open presentation’s title for inline editing. Return or focus loss saves; Escape cancels; navigating away flushes the title. The header omits the module name. The far-right sidebar button and ⌘⌥B toggle Ask in Prepare and Source/Ask in Review. Ask offers Current slide and Whole lecture; older neighbouring-slide scopes fall back to Current slide.

- **Single-window navigation.** Open/Review replaces the library content in the main window. Back returns to the previous library selection after saving notes, card edits and view state; a failed save keeps the lecture visible. Export and ⌘0 Overview use the same guarded navigation. Prepare/Review/source links stay inside the workspace.

- **View state is window-local.** Mode, focused slide, filters and the selected card live in `LectureWindowModel` and are written once with `.setViewPreferences` when the window closes. Arrow-key browsing doesn't write to disk per keystroke or fill the 50-step undo stack, and archived lectures stay navigable without a write.
- **Saves.** Card text uses `stageCardEdit` (the backend's 500 ms coalescing); notes use the same pattern in the window model. Both flush on focus loss, navigation, before jobs and on close. A lecture window only closes after `closeAndFlush()` succeeds (`WindowCloseGuard` answers `windowShouldClose`); quitting uses `.terminateLater` until every open lecture has saved.
- **Archived modules** show a read-only banner; edits, imports, AI and retry are disabled, export and backup stay available. Archiving flushes open windows first and, if jobs are running, asks before cancelling them.
- **Keys.** Prepare: arrows move focus, Space toggles selection, typing opens the note with the first character kept, ⌘J notes, ⌘B thumbnails, ⇧⌘A Ask, ⌘G Generate. Review: 1/2/3 verdicts, ←/→ cards, ↩ accept, ⇧↩ accept and approve, X discard, S cycle source, Space enlarge, A ask, G open in Prepare, E edit, U undo, ⌘↩ send feedback. ⌘1/⌘2 switch mode. Esc leaves any editor.
- **CLI status** in the sidebar says whether the `claude` executable exists. Whether it is logged in is only known when a job runs; the job's error says so.
- **App target** is a SwiftPM executable (like Flashcard Reviewer) instead of a hand-maintained `.xcodeproj`: it builds with `swift build`, and `scripts/package-app.sh` wraps it into `Lectern.app` with the icon in `Assets/Brand`. The bundle is unsigned (local use); SwiftPM's resource bundles go in `Contents/Resources`, where `Bundle.module` finds them (at the `.app` root it crashes at launch).

## Verification and remaining checks

The app builds on macOS, the full offline test suite passes, and the native smoke checks are recorded in [QA-2026-11-02.md](QA-2026-11-02.md). They cover import, edit persistence, single-window navigation, presentation rename, planning/archive controls, and the right sidebar/context UI.

Remaining acceptance checks:

1. Run the handoff’s full gate with a real deck and live provider: import → curate/note → Generate → review with sources → revise while continuing → diff/accept → export → Anki import → edit/re-export.
2. Quit during a live job; archive while generation is running and verify cancellation/unarchive.
3. Compare the screens with `Docs/Design/*.png` and `learning-app-v1-screens.html` in both light and dark appearance.
