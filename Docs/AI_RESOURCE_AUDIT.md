# Lectern AI resource audit — 2026-11-07

Read-only review of runtime code and 38 saved jobs, with official Anthropic documentation checked online. No Claude requests were made. Recommendations retain the current model/effort choices and automatic learning-point extraction.

## What the latest edit actually did

The saved request “Number 21–23 should be different, please switch front and back” used the new compact context format, so this was not an old prompt running before the previous optimization.

| Measurement | Observed value |
| --- | --- |
| Chat job | `3999ECEF-CB76-40FB-9A36-3C377838F9F4` |
| Model / result | Opus / three proposed edits |
| Prompt | 9,366 characters; 7,581 were the lecture index |
| Input across the CLI run | 11,909 tokens: 4 ordinary + 4,974 cache creation + 6,931 cache reads |
| Output | 1,189 tokens |
| Following extraction | Sonnet; 1,693 input and 77 output tokens |
| Local preparation | All 47 slide PNGs rendered; about 11.2 MB |

The slides were prepared locally but not read by this edit. Rendering them costs local time/disk, not model tokens. The main optimization is to avoid inference for this mechanical operation and avoid broad context for focused AI edits. These records do not establish an exact percentage of the subscription allowance.

## Recommended changes, in order

### 1. Give edits a focused path

**Mechanical edits:** add an explicit multi-card Swap front/back action. Apply it locally through the existing revision/proposal machinery, preserving conflict checks, review and undo. This can require zero model calls. Do not silently interpret every ambiguous natural-language instruction as a native operation.

**Semantic edits:** when the user explicitly selects or references cards, supply their current content and frozen revision mapping first. Supply source material when the requested change needs it, with lookup available for broader questions. Avoid the complete lecture index for a narrow operation unless it serves the task. Keep explicitly attached broad context authoritative.

Return compact operations where appropriate instead of making the model reproduce unchanged text. Resolve display numbers to immutable IDs inside the app and validate against the frozen snapshot; never weaken stale-edit protection.

Evidence: `Sources/LecternCore/AI/LectureChatRunner.swift:107`, `Sources/LecternCore/AI/LectureChatRunner.swift:156`, `Sources/LecternCore/Domain/LectureReducer.swift:123`.

### 2. Batch learning-point-driven revisions

`proposeUpdates` starts a separate Revise job for each eligible card on a slide. Each job repeats the same rules, learning points and often the same source PDF. The three saved cancelled revision requests were each about 17,300 prompt characters, about 14,600 of which were shared card rules. Their missing usage records prevent a reliable total-token estimate.

Group compatible target cards into a bounded batch, supply shared sources once, and return separately reviewable results keyed to frozen card revisions. Keep existing exclusions for bad/superseded cards, active revisions and unresolved proposals. Preserve partial failure handling and avoid letting one oversized batch exhaust output capacity.

A content-addressed PDF/render cache also reduces preparation work, but sharing a file on disk alone does not eliminate repeated model input.

Evidence: `Sources/LecternCore/AI/JobRunner.swift:96`, `Sources/LecternCore/AI/JobRunner.swift:155`, `Sources/LecternCore/AI/JobRunner.swift:216`.

### 3. Remove duplicated evidence and unnecessary source reads

- API chat repeats pinned card JSON and All slides text already included in the prompt. The earlier All cards fix covers only the full deck.
- CLI pinned-card requests require another card-file read plus all source slide PNG/text reads, even when a text-only transformation needs only the already supplied card. Extend verified-inline-content handling to individual cards and text, while preserving actual image reads when visual evidence is needed.
- Generate, Revise and legacy Ask/Distil include notes in prompt text and again in the exported PDF. Use a model-source PDF mode with slide visuals and source labels but without repeated note overlays. Keep notes in the text prompt.
- Split provider instructions: CLI currently sees names of API tools it cannot invoke.

Evidence: `Sources/LecternCore/AI/ChatProviderContext.swift:108`, `Sources/LecternCore/AI/ClaudeCLIProvider.swift:149`, `Sources/LecternCore/AI/PromptBuilder.swift:29`, `Sources/LecternCore/PDF/PDFExporter.swift:124`.

### 4. Use lean conversation and extraction payloads

Current lecture chat bounds history to 20 messages and summarizes older messages, which is good. However, it serializes complete persisted `ChatMessage` objects: IDs, timestamps, attachment metadata, read/context bookkeeping and pending edits accompany the conversational text. Large edit proposals can therefore inflate future turns.

Use a dedicated model-facing history representation containing text and only the quiz/proposal/reference information needed to interpret follow-ups. Retain complete persistence records locally. Existing learning points can likewise omit persistence-only identifiers and `usedBy` lists; retain their text, grounding and inclusion/exclusion state.

Automatic extraction should continue, but consume lean latest-exchange/source payloads and deterministically ordered JSON. Its current prompt places the changing exchange before reusable context. Legacy Ask/Distil also serialize the whole slide thread; bound or summarize that history without losing reference resolution.

Evidence: `Sources/LecternCore/AI/LectureChatRunner.swift:148`, `Sources/LecternCore/AI/LectureChatRunner.swift:178`, `Sources/LecternCore/AI/PromptBuilder.swift:58`, `Sources/LecternCore/Domain/Models.swift:142`.

### 5. Fix API chat caching end to end

`makeURLRequest` can put `cache_control` on prompt blocks. `executeChat` then replaces those messages with `initialContent`, discarding the cache configuration. No equivalent cache setting is added to the replacement messages, system or tools. Additionally, the string splitter expects two newlines before `INCLUDED LEARNING POINTS`; current lecture-chat prompts use one.

Represent stable and dynamic content as explicit blocks instead of discovering boundaries with string markers, and preserve their cache settings in the final outgoing body. Check actual outgoing bodies with offline transport tests. Keep tool definitions stable across related calls: changing tools can invalidate cached prefixes.

This is an API-backend issue. The latest CLI edit already reported cache reads; fixing API caching will not directly reduce that CLI subscription run.

Evidence: `Sources/LecternCore/AI/MessagesAPIProvider.swift:106`, `Sources/LecternCore/AI/MessagesAPIProvider.swift:250`, `Sources/LecternCore/AI/MessagesAPIProvider.swift:339`.

### 6. Optimize generation without weakening card quality

Generation already scopes to selected uncovered slides unless regeneration is explicit. Preserve that. Its large shared rule set is another candidate for carefully reviewed simplification, but deleting rules blindly trades savings for worse cards.

Module-wide existing card fronts provide cross-lecture duplicate protection. Deduplicate identical fronts safely; do not replace them with an arbitrary shortlist without checking duplicate recall. Stable rules and module context should remain cacheable; the current builder already places rules before module instructions, after the task label.

Evidence: `Sources/LecternCore/AI/JobRunner.swift:152`, `Sources/LecternCore/AI/JobRunner.swift:181`, `Sources/LecternCore/AI/PromptBuilder.swift:35`.

### 7. Make coverage checking a reusable result

The saved coverage check was followed by “Give me only the ones that are not included,” causing another inference and another extraction job. Return structured covered/partial/missing results with evidence references, then offer local filters and card creation from the stored result.

Cache image text extraction by content hash when useful. Keep the original image available for diagrams, layouts and ambiguous text; OCR is not a universal substitute for vision.

### 8. Cache local preparation and close one context parity gap

Every lecture-chat request renders every slide, writes card files and hashes the assets; previous uploaded images are copied into new job directories. Reuse immutable content-addressed assets while retaining per-job snapshot provenance and integrity checks. Avoid eager slide rendering when a request will only edit cards.

The CLI slide `.txt` file currently contains PDF text without the slide note. API slide lookup returns both. Include notes in the frozen text lookup format so unpinned CLI lookups have equivalent study context.

Evidence: `Sources/LecternCore/AI/LectureChatRunner.swift:28`, `Sources/LecternCore/AI/LectureChatRunner.swift:70`, `Sources/LecternCore/AI/ChatProviderContext.swift:53`.

## Already efficient or worth preserving

- Manual typing, Make a card, quiz answer reveals, proposal approval, undo and exports run locally. No extra AI is needed there.
- Current compact deck snapshots omit card revision history, and All cards no longer duplicates the question index or requires another full-deck read.
- CLI isolation, restricted reads, frozen asset hashes and revision conflict checks should remain.
- Output limits are ceilings, not tokens automatically consumed. Cutting them indiscriminately can truncate valid output.
- Keep structured validation. Claude Code's structured-output machinery may retry invalid output; removing validation would make edits less reliable. Smaller task-specific contracts and measured retry counts are better targets.

## Verification and measurement

This audit changed documentation only. No runtime code, model settings or extraction behavior changed; no live inference was used. Findings combine source inspection and saved jobs, not a benchmark of the proposed design.

For a later implementation, verify outgoing payloads offline, then use an explicitly authorized live sample to compare fresh input, cache creation/read, output, tool rounds and validation retries. Existing failed/cancelled jobs lack enough usage detail for exact attribution. CLI USD estimates are not subscription invoices and cannot be converted reliably into allowance percentages. Broader telemetry remains optional because it was previously deferred.

## Official sources checked

- [Anthropic prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching): API caching requires `cache_control`; cache reuse depends on matching prefixes and tool/system/message ordering.
- [Claude Code cost guidance](https://code.claude.com/docs/en/costs): conversation and tool loops expand repeated context; reduce unnecessary work before tuning model settings.
- [Agent SDK structured output](https://code.claude.com/docs/en/agent-sdk/structured-outputs): structured validation can re-prompt on mismatch. A CLI-to-SDK rewrite alone does not establish lower inference cost.
