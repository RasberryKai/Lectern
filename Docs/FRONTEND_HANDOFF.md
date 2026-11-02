# Lectern frontend handoff

## Outcome and boundaries

Implement the macOS SwiftUI interface from `learning-app-v1-screens.html`, using the completed `LecternCore` backend in this repository’s `Sources` directory. `learning-app-v1-design.md` is the original product brief. This handoff documents the actual APIs and the corrections made during backend implementation.

**Repository:** [RasberryKai/Lectern](https://github.com/RasberryKai/Lectern), checked out at `/Users/kaikuppers/Documents/Projects/lectern`. This standalone repository supersedes the original design’s host-repository instruction. Open the root `Package.swift` in Xcode; create the new frontend app target here.

**Updated designs:** [Overview](Design/overview.png) and [Module settings](Design/module-settings.png) supersede the old HTML wherever module planning, progress, or archiving differ. The backend contract is detailed in `MODULE_PROGRESS_SPEC.md`.

The backend is a local Swift package with an executable developer tool, not a cloud service. Keep the app unsandboxed for personal CLI execution, macOS 26+, Swift 6, AppKit/PDFKit, and no third-party dependencies. Create a new **Lectern** macOS app target in this repository and add the repository root as its local package dependency. The legacy iPad target and iCloud synchronization code remain in the separate Slide Learning repository. Legacy sources contain unrelated user edits; preserve them when porting UI. LecternCore builds independently of either legacy repository.

Destinations now include Overview, Library/module, a Lecture window with Prepare/Review modes, and Export. AI is a sheet, a job bar, badges, and a side panel. No extra chat application or study scheduler.

## Start the app

Create one `LibraryStore`, one `JobRunner`, and one `LibraryService` per library. The runner owns global concurrency; creating a runner for each window defeats that limit.

```swift
import LecternCore

let store = LibraryStore()
let settingsStore = AISettingsStore()
let settings = await settingsStore.load()
let runner = JobRunner(store: store, providers: [
    ClaudeCLIProvider(settings: settings),
    MessagesAPIProvider(settings: settings)
])
let library = LibraryService(store: store, runner: runner)
let report = try await library.bootstrap(importLegacy: true)
let modules = try await store.modules()
```

Run bootstrap once before opening lecture windows. It replays pending export journals, marks crashed jobs Interrupted, seeds rules, imports existing legacy libraries, and removes terminal job snapshots older than seven days. Present migration failures/warnings with their source paths; do not turn a partly failed import into an empty-success screen. Repeating bootstrap has safe import identities but must not run while this runner has active jobs.

`AISettings` contains backend, CLI/API model, CLI path, API version, and output limit. `settings.selectedModel` is the model to pass to job methods. Save preferences with `AISettingsStore.save`. Store only API keys with `KeychainStore.saveAPIKey`, never UserDefaults or JSON. CLI login is owned by Claude Code; use instructions to run `claude auth login`. Do not build a Claude.ai OAuth client or read its tokens. v1 accepts ordinary `claude.ai` sign-in with a verified Pro/Max/Ultra/Team/Enterprise profile; it rejects Console OAuth, ambiguous `oauth_token`/setup-token profiles, and unverifiable tiers to avoid API billing through the subscription path. Account-enabled usage credits may still incur charges after included subscription limits. After changing provider configuration, recreate providers at a safe idle point; do not discard an active runner.

## Library

| UI operation | API |
| --- | --- |
| List modules | `try await store.modules()` |
| Add module | `createModule(name:instructions:)` |
| Edit/reorder module | `updateModule(_:)`; `lectureIDs` is the saved order |
| Load current module settings | `loadModule(moduleID:)` |
| Save name, plan and exam date | `updateModuleSettings(moduleID:name:plannedLectureCount:examDate:)` |
| Archive / unarchive | `setModuleArchived(moduleID:archived:)` |
| Overview and sidebar progress | `dashboard(now:timeZone:)` |
| Append feedback as module rule | `library.makeModuleRule(moduleID:feedback:)` |
| List lectures | `store.lectures(in:)`, in module order |
| Import a dropped/picked PDF | `store.importPDF(from:moduleID:)` |
| Import several PDFs as one lecture (merged in the given order) | `store.importPDFs(_:name:moduleID:)`; sheet helpers in `PDFMerge` (`pageCount(of:)`, `naturalOrder(_:)`, `suggestedName(for:)`) |
| Open lecture | `store.loadLecture(moduleID:lectureID:)` |
| Edit global card rules | `loadRules()` / `saveRules(_:)`; version is the content hash |
| Import friend's old files | `LegacyImporter(store:).importProjects(from:)` / `.importReviewer(from:)` |
| Portable lecture backup/restore | `exportBackup(moduleID:lectureID:to:)` / `restoreBackup(from:)` |

Source PDFs are private copies; the app works after the original is moved. PDF import selects every slide. Existing legacy projects retain selections, notes, focus, thumbnail size (`compact`, `regular`, `large`), and visibility. Reviewer sessions become sourceless lectures in Review mode. Original text, current text, feedback, math decisions, and raw source provenance survive migration. Old Good cards that fail Lectern's stricter validation become Unreviewed with a flag; the original verdict remains in provenance.

Default migration prefers the saved Slide Learning shared-folder bookmark, with read-only local fallback and a warning if inaccessible. Explicit folder pickers should keep security-scoped access alive while import runs. First-party source paths are not rewritten. IDs are namespaced by canonical input path: importing an unchanged source twice skips it; importing a copy at a different path intentionally creates a separate namespace. Do not silently merge a friend's records into your own or overwrite later Lectern edits with legacy data.

Backups include the source PDF and legacy provenance. They exclude job snapshots; historic interrupted jobs restored from a backup may require a new request. Restore refuses an existing lecture identity. Use `exportModuleBackup(moduleID:to:)` for the mockup’s single module backup file and `restoreModuleBackup(from:)` to restore it. Module restore validates all lecture identities and PDFs before publishing the directory, and refuses an existing module identity.

## Module settings and archiving

`Module` adds `plannedLectureCount`, optional `examDate: ExamDate`, and optional `archivedAt`; `isArchived` is derived. Old JSON decodes as active with its imported count as its plan. No exam date or future lecture count is guessed for legacy users. Import fills the next ordered slot and automatically grows the plan if all slots were already occupied.

Keep settings in a local draft. Cancel writes nothing; Save calls the narrow settings API, which loads the latest module and preserves its instructions, lecture order, and archive state. `updateModule(_:)` remains the compatibility API for name/instructions/order and preserves the current planning fields; do not use it to save the settings sheet. Planned count is a whole number from the latest imported count through `Module.maximumPlannedLectureCount` (10,000). The store checks again on Save, so a simultaneous import cannot make the plan smaller than the lecture count. On rejection, reload and show the new minimum.

Store an exam as calendar components, not a midnight timestamp:

```swift
let exam = try ExamDate(date: pickerDate, timeZone: .current)
let updated = try await store.updateModuleSettings(
    moduleID: moduleID, name: draftName,
    plannedLectureCount: draftCount,
    examDate: hasExamDate ? exam : nil
)
```

`ExamDate(year:month:day:)` validates Gregorian dates. `date(in:)` bridges back to DatePicker; `nil` clears the optional date. The selected calendar day survives time-zone changes. Do not serialize the picker Date directly.

Before archiving, flush pending edits in every open session for that module. Require running/queued jobs to finish, or explicitly cancel them and await `runner.waitUntilIdle()`. Archive refuses live durable jobs rather than silently discarding work. Call `setModuleArchived(moduleID:archived:true)` and refresh the sidebar/Overview/open windows. Archive is an immediate separate action, independent of an unsaved settings draft. Closing/cancelling the sheet after Archive does not unarchive.

Archived modules appear only under Archived, remain readable, and can be unarchived with the same API passing `false`. Disable settings/content edits, imports, review/undo, learning-point changes, and all AI/retry controls. Keep navigation/selection for reading in local view state rather than dispatching persisted view preferences. Store transactions enforce this even if a window is stale. PDFs, cards, history, chats, sources, and existing exports stay in place. Anki/PDF/backup export remains enabled; recording successful export marks is the intentional write exception. Restoring into an existing archived module is blocked; restoring an archived backup into a new library preserves the archived state. Do not automatically unarchive or mark modules archived when exams pass.

## Overview and progress

```swift
let overview = try await store.dashboard(now: Date(), timeZone: .current)
```

This reads a consistent library snapshot under one lock. `overview.modules` contains active modules in library order; `archivedModules` contains archived metadata. `overview.totals` supplies the four top tiles and their subtitles:

| Screen value | Field |
| --- | --- |
| Lectures done / planned | `doneLectureCount` / `plannedLectureCount` |
| Cards to review | `reviewCardCount` |
| In N lectures; proposals waiting | `reviewLectureCount`; `proposalCount` |
| Ready to export | `readyExportCount` |
| Previously exported cards now changed | `changedExportCount` (subset of ready) |
| Lectures not imported | `notImportedCount` |

Each `ModuleProgress` has `module`, ordered `lectures`, `slots`, `statusCounts`, `totals`, `nextUp`, and `pace`. Use `totals.doneLectureCount/plannedLectureCount` in the sidebar. Draw one segment per slot with status `.done` (dark green), `.toExport` (light green), `.toReview` (blue), `.preparing` (ochre), or `.notImported` (empty). Slots are presentation records, not empty `Lecture`s. Their ID contains module UUID and one-based index; `lectureID` is nil for empty slots. Imported order is `Module.lectureIDs`; empty slots trail it.

Status is derived, never manually saved:

- Superseded originals do not count. Review work counts each card once if Unreviewed, Needs adjustment, carrying a proposal, or Good with validation issues. A Bad card without a proposal is a resolved rejection; an AI flag alone does not undo approval.
- Done requires every selected source slide to have non-Bad/non-superseded coverage, all cards resolved, approved cards exported at their current revisions, and no running jobs. Zero selected slides in a PDF lecture or an empty sourceless lecture is Preparing, avoiding an empty lecture showing Done. Reviewed sourceless legacy cards can complete.
- To review takes precedence over Preparing blockers; Preparing takes precedence over To export; Done is the remaining complete state. Export readiness still counts eligible Good cards in a lecture with other work. Existing Anki eligibility remains authoritative.

`nextUp` is a maximum of three typed actions, ordered Review → module Export → Prepare → Import when applicable. Review opens the first lecture needing review; Export carries all eligible lecture IDs/counts; Prepare carries `.selectSlides`, `.generateMissingCoverage(pages:)`, `.waitingForJobs(jobIDs:)`, or `.addCards`; Import carries the module and first empty slot ID. Route with IDs, not labels or inferred lecture numbers. Import appends the new lecture; it does not create intermediate placeholders. Resolve lecture names from the module progress when building the displayed action label.

`pace` is `.noExam`, `.future(daysRemaining:lecturesPerWeek:)`, `.dueToday`, `.overdue(daysOverdue:)`, or `.complete`. Remaining lectures are `planned - done`. Future rate is `remaining * 7 / calendarDaysUntilExam`; use the exact value and format to one decimal for the badge. UI formats dates/weeks and handles today/overdue/no date explicitly—never display an infinite or negative pace. Refresh on app activation, local day/time-zone changes, module settings/import/archive, and after review/export/job completion. Backend progress has no timer and makes no model calls. Archived modules contribute to none of the Overview totals.

## Open a lecture window

On the MainActor:

```swift
let lecture = try await store.loadLecture(moduleID: moduleID, lectureID: lectureID)
let session = LectureSession(lecture: lecture, store: store, runner: runner)
session.startObserving()
```

Observe `session.lecture`, `session.jobs`, `session.canUndo`, and `session.lastError`. Dispatch semantic `LectureAction`s through `session.dispatch`, rather than replacing a whole cached lecture with `store.updateLecture`. The session merges the latest durable state inside a store transaction, so background results survive manual edits. The store is actor-isolated and additionally locks across processes.

`session.refresh()` merges a new snapshot without dropping undo. `session.undo()` persists undo and reveals the All review filter. The controller retains 50 actions and preserves asynchronous job results and append-only history.

For text editing, keep a local editor buffer. Call `stageCardEdit(cardID:front:back:sourcePages:)` as it changes; it coalesces until 500 ms of inactivity. Call `flushEdits()` on focus loss and before navigation. Job wrapper methods flush automatically. **On window close and application termination, await `closeAndFlush()` and keep the window open if saving fails.** With AppKit, return false from `windowShouldClose` while the flush is pending, then close after success; use delayed application termination to await all open sessions. The debounce task also retains the session until its pending save finishes, but explicit close handling is the error-reporting contract.

Editing is saved per typing pause, not per keystroke. Do not add another autosave implementation that races this one. The current JSON date codec has second precision; controller refresh compares at that precision while checking append-only revision identities.

## Prepare

`SlideState.pageIndex` is **zero based**. All card sources, thread anchors, job pages, and prompt citations are **one based original source slide numbers**. Convert only at the PDF boundary. Never use a filtered thumbnail offset as a slide identity.

- Keep focus separate from selection. Use `.setViewPreferences` for focus/filter/notes/sidebar/mode, `.setSlideSelection(pageIndex:Bool)` for selection, and `.updateNote(pageIndex:String)` for notes. Non-whitespace notes on a previously empty note select that slide; clearing never deselects it.
- Keep normal typing, spaces, and arrow keys in editors. Preserve the first typed character when opening notes. Escape releases the editor; ⌘J toggles notes.
- `lecture.coverage(page:)` is the non-Bad, non-superseded card count. `lecture.uncoveredSelectedPages` drives the default Generate scope. Bad/superseded cards do not count as coverage.
- The ported `PDFExporter` takes zero-based `PDFExportPlan.selectedPageIndices`. It preserves source operators, labels original slide numbers, and puts searchable notes beneath/after slides. Reuse the legacy thumbnail provider for rendering, not AI input.
- Render via `store.sourceURL(moduleID:lectureID:)`. PDF workers should run off the MainActor.

Use ⌘1 / ⌘2 to set mode. Generation landing must never change mode or selection.

## Generate and job bar

```swift
let jobID = try await session.generate(
    backend: settings.backend,
    model: settings.selectedModel,
    regenerateAll: false
)
```

The Generate sheet previews `uncoveredSelectedPages`, active rules/module instructions, included learning points, and the backend. Regenerate All requires an explicit UI confirmation and passes `true`. More than 100 source slides is an error; do not silently chunk or truncate. The API's separate PDF/request limits are enforced by its provider.

Every job freezes the prompt, replacement system prompt, model, selected PDF with notes, and included learning-point IDs. Rules versions and input hashes are stored. Editing remains enabled while it runs. At most three provider calls run globally, one Generate per lecture, one revision per card, and one conversation operation per thread. Queued jobs remain durable `running` records with a transient Queued stage.

`session.jobs[jobID]` contains stages, streamed Ask text, and warnings. `runner.events()` is an AsyncStream if a library-wide job monitor is needed. Avoid showing raw provider internals as product UI. Terminal events trigger session refresh; job/error/usage records remain in `lecture.jobs` after restart.

Cancel with `runner.cancel(moduleID:lectureID:jobID:)`. Cancellation is saved before signalling the provider, so a late response cannot land. Retry with `runner.retry(...)`; it reuses the same job ID and exact snapshot. Successful jobs cannot retry; expired snapshots explain that a new request is needed. Expose Interrupted / Failed / Cancelled distinctly. No automatic paid retries or backend fallback.

On landing, show card count and skipped reasons. A zero-card batch or more than three cards per slide on average is a warning. Unaccounted-for input slides receive an explicit missing-output skip reason. Invalid card text/citations/math stay visible for repair, rather than being dropped.

## Review and proposals

Use `lecture.visibleCards` and `lecture.viewPreferences.reviewFilter`: All, AI flagged, Proposals, Unreviewed, Good, Bad, Needs adjustment. Superseded originals are hidden; flagged cards sort first. Count and indicate validation via `lecture.issues(for:)`; source-less legacy cards are valid, generated cards need sources. Approval goes through the reducer and fails if issues remain.

| Interaction | Action/API |
| --- | --- |
| 1 / 2 / 3 | `.setVerdict(cardID: .good/.bad/.needsAdjustment)` |
| Feedback edit / Esc | `.setFeedback`; Esc keeps the note and sends nothing |
| ⌘Return in feedback | `session.revise(cardID:feedback:backend:model:)`; keep reviewing immediately |
| Manual card edit | editor buffer + `stageCardEdit`, then flush |
| Restore original | `.restoreOriginal(cardID:)` |
| Fix import syntax issue | edit text, then `.resolveIssue` when user has resolved it |
| Ambiguous math | `.setMathInterpretation(cardID:span:choice)` using the ported math analyzer |
| Accept proposal / Return | `.acceptProposal(cardID:approve:false)` |
| Accept and approve / Shift-Return | same with `true`; a split still creates Unreviewed children |
| Discard / X | `.discardProposal(cardID:)` |
| Undo / U | `session.undo()`; suppress letter shortcuts while typing |

Show proposals against the **current** text using `WordDiff.compare(before,after)`. `card.proposalIsStale` identifies proposals based on older text. Accepting preserves manual revisions in history. A split supersedes the original and creates new child identities. Never approve on generation, plain Accept, Ask, or Distil. Single-card Shift-Return still validates before approval.

S cycles `sourcePages`, Space enlarges the source, A opens Ask, and G sets Prepare focus to the linked page. Handle sourceless legacy cards with an explicit no-source state and disable G/S/source Ask. Keep the bottom verdict bar stable.

## Ask and learning points

`session.ask(anchorPage:context:question:cardID:backend:model:)` accepts `.slide`, `.neighbours(1)` (default), or `.lecture`. Passing a card opens the thread for its first linked source slide; Prepare and Review share it. Threads are durable in `lecture.threads`, keyed by unique `anchorPage`.

Display `JobProgress.streamedText` while running, then the persisted assistant message. Messages cite `[slide N]`; `ChatMessage.citedPages` contains validated clickable references. Preserve the original answer text; do not present unsupported references as clickable source links.

A successful Ask automatically queues Distil. Failure to distil leaves the answer intact and exposes a warning. Learning points are included/excluded/editable by the user, with `usedBy` job IDs for traceability. For a point edit/toggle, load the latest thread **inside** a store mutation and change only that point, or add a narrow application action. Do not send a stale whole thread over one that may have received an answer.

Use `runner.proposeUpdates(moduleID:lectureID:page:backend:model:)` to revise existing cards from included learning points. It creates proposals, not duplicate cards. Its result contains `jobIDs`, `skippedCardIDs` (existing proposals/jobs), and per-card `failures`; display partial results instead of treating a partly started batch as wholly failed. “Use as feedback” can fill the existing feedback editor. “Make module rule” uses the library service method. Raw Ask transcripts never feed Generate; included learning points and slide notes do.

## Export

Use `AnkiExporter.export` for a deterministic preview. Use `library.exportAnki(moduleID:lectureID:to:changedOnly:)` for the actual Save action: it writes the file before marking captured revisions and journals multi-lecture marking for crash recovery. `lectureID:nil` means the whole module. Default changed-only includes approved new and edited cards; All includes every eligible approved card. Superseded/Bad/Unreviewed/Needs-adjustment are excluded.

**Correction to the mockup:** the file has regular columns `LecternID`, `Front`, `Back`, `Tags`. A LecternID combines lecture and card identity, avoiding collisions across imported sessions. It is not Anki's internal GUID. Follow `AnkiExporter.setupInstructions` for one-time creation of the Lectern note type, field order, and front/back templates. The header cannot create this note type. Default Anki duplicate handling must be Update with note-type matching. A genuine Anki import/update/scheduling check is still manual.

Show the ID as metadata, not on the card face. Tags encode `Module::Lecture`. Text is escaped as HTML and math is normalized with explicit ambiguous-span decisions. Never mark exported from a preview or cancelled Save panel. `ExportEntry` captures revision IDs, so a later edit remains Changed since export even if the write finishes afterward.

Global cost UI can collect module lecture jobs and call `APIPricing.summarize`. Label estimated amounts, show unpriced-job count, and do not mix subscription-equivalent CLI cost into API spend. Published pricing is dated and must be updated when models change; the summary is not an invoice. Failed/cancelled requests can incur charges without final usage metadata.

## UI sources to port

- Prepare: `/Users/kaikuppers/Documents/Projects/slide-learning/SlideLearning/Views/ProjectWorkspaceView.swift`, its sibling `WorkspaceKeyMonitor.swift` and `SlideCellView.swift`, and `/Users/kaikuppers/Documents/Projects/slide-learning/SlideLearning/PDF/PDFThumbnailProvider.swift`. Adapt project access to `LectureSession`; preserve focus, typing, source identity, and selection behavior.
- Review: `/Users/kaikuppers/Documents/Projects/flashcard-evaluator/Sources/FlashcardEvaluatorApp/ReviewView.swift`, `MathPreviewView.swift`, and existing bundled MathJax assets. `FlashcardDomain` is already ported into LecternCore; do not fork a second validator/parser.
- Merge design tokens once. Respect the supplied ivory/charcoal/muted-green/verdict palette and light/dark appearance. Implement screens rather than gluing two legacy root views together.

## Acceptance and outstanding live checks

Run `swift test` and `swift run lectern demo` before UI work. The backend test suite covers actual temporary-file persistence, malformed/recovered JSON, read-only migration, prompt golden output, scopes, revision histories, racing retries, cancellation, queue limits, fake CLI processes, mock HTTP/SSE, closing saves, and export recovery.

The frontend gate is a real deck: import → curate/note → Generate → review with sources → revise while continuing → diff/accept → export → import into Anki → edit/re-export → confirm update without duplicate notes or scheduling loss. Also test an 11+ page CLI PDF, logged-out/rate-limit states, cancelling jobs, restarting during a job, old user migration, text shortcuts/focus, and window/application close during a pending edit. Compare rendered screens with the supplied HTML. Backend builds are not proof that these UI interactions work.

For the updated screens, also exercise settings Save/Cancel/clear-date, minimum count after concurrent import, empty slots, progress moving backward after edits/rejections, local-day/DST pace updates, archive with pending saves/jobs, read-only windows, export while archived, and unarchive. Compare Overview and Module settings with the newer PNGs above. The backend has no new screen implementation or live visual QA in this delivery.

The installed CLI was logged out during backend work; no logged-in status/tier compatibility, real Claude response, subscription PDF permission rule, API billing, Keychain prompt, or Anki import was tested. The strict subscription gate may need a version-specific compatibility adjustment after checking a real account's status. Live connection tests are opt-in under `LiveSmokeTests`; quota/billing is involved. Do not claim subscription reuse is approved for distribution: the integration research documents the personal-local scope and API alternative.

See `VERIFICATION.md` for the delivered build, automated-test, migration, and independent-review evidence. The module extension passed a fresh GPT-6.1 Sol medium review after fixing and rechecking its archived-restore finding; the full backend has 99 passing automated cases and two opt-in live checks skipped. In restricted automation environments, PDFKit may stall waiting on macOS TCC services; run PDF checks with normal macOS service access.
