# Lectern

Standalone repository: [RasberryKai/Lectern](https://github.com/RasberryKai/Lectern). Local checkout: `/Users/kaikuppers/Documents/Projects/lectern`.

Native macOS 26 / Swift 6 learning app: the `LecternCore` backend and the `LecternApp` SwiftUI frontend that consumes it. No third-party dependencies. The existing Slide Learning and Flashcard Reviewer applications are unchanged.

## Run the app

```sh
swift run LecternApp                # debug build, runs from the package
scripts/package-app.sh              # release build at .build/Lectern.app
open .build/Lectern.app
```

Or open `Package.swift` in Xcode 26 and run the `LecternApp` scheme. `LECTERN_LIBRARY_ROOT=/tmp/lectern-test` runs against an isolated library; `LECTERN_SKIP_LEGACY_IMPORT=1` skips the first-launch import of Slide Learning / Flashcard Reviewer data. The app target uses Swift 6.2's default MainActor isolation, so the package now needs tools version 6.2 (Xcode 26). See [the frontend notes](Docs/FRONTEND.md) for structure and what still needs live checks.

Start with [the frontend handoff](Docs/FRONTEND_HANDOFF.md). The original design's instruction to use Slide Learning as the host repository is superseded by this standalone checkout. The supplied [design](Docs/learning-app-v1-design.md) and [screen mockups](Docs/learning-app-v1-screens.html) are copied here for a self-contained handoff. [Verification](Docs/VERIFICATION.md) records tests, migration, review, and outstanding checks. [Integration research](Docs/INTEGRATION_RESEARCH.md) distinguishes verified Claude/Anki support from remaining live checks.

The updated [Overview](Docs/Design/overview.png) and [Module settings](Docs/Design/module-settings.png) are included. The backend now supports planned lecture slots, date-only exam settings, derived progress/pace/Next up actions, and reversible read-only archives. The frontend handoff documents the new APIs and refresh/archiving rules.

## Build and exercise

```sh
cd /Users/kaikuppers/Documents/Projects/lectern
swift build
swift test
swift run lectern demo
swift run lectern help
swift run lectern overview
```

The demo uses fixtures, makes a new temporary library, and exercises PDF import → Generate → Revise → accept/approve → Ask → Distil → Anki text → backup/restore. It makes no model requests. If running under the Codex filesystem sandbox, use:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/lectern-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/lectern-module-cache \
swift test --disable-sandbox
```

PDFKit also needs normal access to macOS services. If a restricted automation environment stalls inside PDFKit/TCC initialization, rerun these checks outside that environment; disabling SwiftPM's build sandbox does not remove an outer process sandbox.

For live checks, explicitly opt in to `LECTERN_LIVE_CLI=1` or `LECTERN_LIVE_API=1` when running `--filter LiveSmokeTests`. The former consumes your shared subscription allowance; the latter incurs API charges. These connection checks do not replace testing a real lecture PDF or Anki import.

## Legacy data

```sh
swift run lectern migrate-default
swift run lectern migrate-slides '/path/to/Slide Learning'
swift run lectern migrate-reviewer '/path/to/sessions.json'
```

Default migration uses Slide Learning's saved shared folder when readable, otherwise its retained local Projects folder with a warning, plus the Reviewer's `sessions.json`. A friend's copied Projects folder or Reviewer backup can be imported using the explicit commands. Sources remain untouched. Repeating the same source path skips imported records; distinct source paths deliberately form separate import namespaces. Keep a copied legacy library at a stable path to avoid importing it twice.

The new library defaults to `~/Library/Application Support/Lectern/Library`. `--root PATH` selects an isolated library for tests or rehearsal. Backup JSON includes the source PDF and original legacy provenance. It does not include transient AI snapshot directories.

## Claude and Anki

The CLI backend launches the installed, unmodified `claude`, keeps its own authentication, disables personal customizations with safe mode, and restricts built-in tools to reading the job PDF. Lectern never extracts subscription credentials. Run `claude auth login` yourself to sign in with an ordinary Pro/Max/Ultra/Team/Enterprise Claude profile. Console OAuth and unverifiable setup-token profiles are rejected; account-enabled extra-usage credits can still incur charges beyond included limits. The installed CLI was logged out, so the logged-in status/tier compatibility and real inference remain unverified. This path is for personal local use; use the API-key backend for distribution unless Anthropic confirms the subscription-wrapper policy.

The API fallback uses Keychain, direct Messages requests, structured output, PDF blocks, and SSE for Ask. Provider/model settings are available through `AISettingsStore`. Model IDs and published pricing are configurable/dated; cost summaries distinguish reported cost from token-based estimates and unpriced jobs.

Anki export uses a stable **first regular field** `LecternID`, not a fabricated Anki GUID. Run `lectern anki-setup` for the required one-time note type setup. The generated header selects an existing note type; it cannot create one. Scheduling remains in Anki. Real import/update/rendering requires a manual Anki check.

## Layout

- `Sources/LecternCore/Domain`: models, review reducer, 50-action undo, history/proposals, legacy parser/math, word diff, Anki serialization.
- `Sources/LecternCore/Persistence`: locked atomic library, recovery, portable backups, read-only legacy migration, export journals.
- `Sources/LecternCore/PDF`: ported vector-preserving Slide Learning exporter with source numbers and searchable notes.
- `Sources/LecternCore/AI`: pure prompts, immutable requests, queue/cancellation/retry, CLI/API providers, Keychain and cost summaries.
- `Sources/LecternCore/Application`: observable lecture session and library service for SwiftUI.
- `Sources/LecternApp`: the macOS app (library window, Overview, module, lecture window with Prepare/Review, Export, Settings).
- `Sources/LecternTool`: runnable workflows and offline demo.
- `Tests/LecternCoreTests`: legacy regression, storage/migration, prompt golden, concurrency, process/HTTP, lifecycle, and opt-in live checks.

No SwiftUI app target or new screen implementation is delivered in this backend stage. Do not claim live Claude PDF generation or Anki import passed based on fixture tests.
