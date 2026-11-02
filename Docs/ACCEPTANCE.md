# Lectern backend delivery

The supplied design and HTML describe the product. This delivery implements the local Swift backend and supplies a frontend handoff; it does not replace the existing app UI. Legacy apps and their files remain intact.

Final evidence is recorded in [VERIFICATION.md](VERIFICATION.md): 99 automated cases passed, two opt-in live checks skipped, release build and offline end-to-end demo passed. The installed-user migration populated 51 lectures with 680 cards and preserved all 105 original files by checksum.

| Requirement | Implementation / verification |
| --- | --- |
| Modules, lectures, private PDF, slide notes and selection | LibraryStore; persistence and PDF integration tests |
| Module exam date and planned lectures | Date-only ExamDate, atomic narrow settings API, legacy defaults, live import-count validation and tests |
| Overview totals, slots, pace and Next up | Pure DashboardBuilder and atomic store snapshot; deterministic transition/date/identity tests |
| Reversible read-only archives | Store mutation guards, AI preparation/retry guards, running-job refusal, archived export/backup and race tests |
| Safe existing-user imports, including friend's exported folders | LegacyImporter; idempotent provenance, original files untouched, fixture tests and local-data dry run |
| Card review, math, history, undo, stale/split proposals | Domain reducer, ported reviewer parser/math and tests |
| Source coverage, uncovered-only generation, cross-lecture dedupe | Domain coverage and PromptBuilder tests |
| Explicit context and four AI operations | PromptBuilder, immutable snapshots, schema validation, fake provider |
| Claude subscription CLI and API fallback | Official-source research, process/HTTP fixtures; live calls opt in |
| Queue, cancel, retry, restart recovery and atomic landing | JobRunner actor and persisted lifecycle integration tests |
| Per-slide Ask, distillation, editable learning points | Durable threads, job completion, context tests |
| Stable Anki identity, escaped fields and changed-since-export | Anki export tests; actual Anki import remains manual |
| Frontend implementation contract | FRONTEND_HANDOFF.md and runnable CLI workflows |

Source slide numbers in cards, prompts and jobs are **one based**. `SlideState.pageIndex` is **zero based**, matching PDFKit and the legacy app. Conversion occurs only at PDF/slide boundaries.

No cloud database, iPad changes, scheduling, two-way Anki sync, or speculative UI implementation is part of this delivery. API requests incur charges; no live paid requests run by default. Subscription tokens are never extracted or sent by Lectern.
