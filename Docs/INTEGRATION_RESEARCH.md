# Claude and Anki integration research

Verified 2 November 2026. Read-only research: no model calls, API spend, login changes, or credential-file reads were performed.

## Provider contract

- Keep the subscription backend as a local, private-user option only. Launch the unmodified Claude Code binary as a one-shot process with a fresh job directory, no resumed session, no persisted transcript, the app's replacement system prompt, and a tightly scoped Read tool. Do not use `--bare`: it skips OAuth and keychain authentication.
- Use `--safe-mode` to suppress personal CLAUDE.md, auto-memory, skills, plugins, hooks, MCP servers, custom commands, agents, and other customizations while preserving the CLI's normal authentication. `--system-prompt` replaces Claude Code's default system prompt; `--append-system-prompt` does not isolate it.
- Use the CLI's JSON envelope for schema jobs, extracting the payload from `structured_output`; it is not the top-level JSON object. Stream Ask as newline-delimited JSON events. Send SIGINT to cancel a live CLI turn.
- For API calls, use the current Messages API version `2026-10-21`, an API key belonging to the user, `claude-opus-5-5`, `output_config.format`, and `output_config.effort`. Send PDFs as user-message document blocks. Cache only stable prompt prefixes.
- The current Anki manual confirms update-on-reimport for an unchanged Anki GUID. It recommends that apps keep their own IDs in the first note field instead of inventing values for Anki's GUID field.

## Installed CLI and safe invocation

Local inspection of `/opt/homebrew/bin/claude` returned version `2.1.205`; `claude auth status` returned `loggedIn: false`, `authMethod: none`, `apiProvider: firstParty`. This environment has no active CLI login, so subscription auth, model availability, and a real PDF run were not smoke-tested. `pdftoppm` is installed at `/opt/homebrew/bin/pdftoppm`.

The installed `claude --help` confirms `-p`, `--safe-mode`, `--no-session-persistence`, `--system-prompt`, `--tools`, `--allowedTools`, `--disallowedTools`, `--permission-mode`, `--output-format`, `--json-schema`, `--model`, and `--effort`. Its help says `--bare` reads neither OAuth credentials nor the system keychain and instead requires `ANTHROPIC_API_KEY` or an API-key helper. The current [headless CLI docs](https://code.claude.com/docs/en/headless) confirm that non-bare `-p` runs otherwise discover hooks, skills, MCP, auto-memory, and CLAUDE.md from the working directory and `~/.claude`; they skip the workspace trust dialog and per-server approval prompt.

Recommended `Process` argument shape for Generate/Revise/Distil; pass each array element as a separate process argument, set the child working directory to the fresh job folder, and write the job prompt/context to stdin (then close stdin). Replace the example path with the canonical absolute `input.pdf` path:

~~~swift
[
  "-p",
  "--safe-mode",
  "--no-session-persistence",
  "--system-prompt", fixedApplicationSystemPrompt,
  "--model", "opus",
  "--effort", "high",
  "--output-format", "json",
  "--json-schema", schemaJSONString,
  "--tools", "Read",
  "--allowedTools", "Read(//private/tmp/lectern-job-UUID/input.pdf)",
  "--disallowedTools", "mcp__*",
  "--permission-mode", "dontAsk"
]
~~~

The stdin prompt should name the same PDF path and ask Claude to read it. Keep variable module instructions, feedback, and slide metadata in stdin, not in the process argument list. Do not pass `--continue`, `--resume`, `--add-dir`, a plugin, or an MCP config. The absolute-path allow rule uses Claude Code's documented `Read(path)` permission syntax; `dontAsk` denies other unapproved tool requests. `--tools Read` limits built-in tools, while `--disallowedTools mcp__*` explicitly denies MCP tools because `--tools` by itself does not filter MCP.

The recommended per-file allow rule is documented by the [permission reference](https://code.claude.com/docs/en/permissions), but its behavior has not been exercised with the locally installed v2.1.205 binary. The stronger `permissions.blockReadsOutsideWorkingDirectories` setting is documented, but it requires Claude Code v2.1.257 or later. Version-gate that setting, and smoke-test the current binary's path-scoped allow rule before relying on it. CLI permission checks are not an OS sandbox; do not describe a job folder alone as a filesystem boundary.

`--safe-mode` is the important isolation switch. `--disable-slash-commands` only disables skills and commands and is not an equivalent replacement. Safe mode still respects managed/organization policy; a user's admin policy cannot be suppressed by the app. Because `--system-prompt` removes Claude Code's default tool and safety guidance, provide the complete task/output instructions required by this non-coding job in the app prompt.

### CLI payload and streaming

For `--output-format json`, the documented envelope has a top-level `result` and request/session metadata. When `--json-schema` is supplied, the parsed schema object is in top-level `structured_output`; it is absent when the run has no valid structured result, including a refusal. Check process exit status and require `structured_output` before landing generated data. Do not decode the envelope itself as the card schema. The CLI docs also say a runtime failure can be printed to stdout as the result, so a syntactically valid response alone is not success. See [structured CLI output](https://code.claude.com/docs/en/headless#structured-output).

For streamed Ask text, use `-p --output-format stream-json --verbose --include-partial-messages`; consume newline-delimited event objects, forward text deltas, and treat the final `result` event as completion. Structured jobs can use one JSON envelope rather than streaming model fragments. For cancellation, send SIGINT to the child process and await exit. The official docs say SIGTERM leaves the turn unfinished and exits with code 143; Swift `Process.terminate()` sends SIGTERM, so it is not the graceful cancel. See [CLI stream and stop behavior](https://code.claude.com/docs/en/headless#stop-a-run-with-sigterm).

The CLI Read tool reads short PDFs whole. For PDFs longer than 10 pages it reads page ranges, at most 20 pages per call, rendered with `pdftoppm`; therefore a 100-slide CLI job depends on the local renderer and the model reading several ranges. This is distinct from the API's per-request PDF limits. See [Claude Code Read behavior](https://code.claude.com/docs/en/tools-reference#read-tool-behavior).

## Subscription policy and limits

Claude Code supports subscription sign-in, but Anthropic's [legal and compliance policy](https://code.claude.com/docs/en/legal-and-compliance) says developers building products/services that use Claude should use API-key authentication. It forbids offering Claude.ai login inside a third-party application or routing requests through Free/Pro/Max/Ultra plan credentials on users' behalf. Separately, it permits users to sign in to the unmodified Claude Code binary themselves, including on a platform hosting that binary under the applicable Commercial Terms. These provisions do not establish that Lectern's non-coding subscription wrapper is approved for distribution. Keep that path personal/local; confirm the specific use case with Anthropic before distribution. Never extract, collect, store, or proxy the user's CLI OAuth/session token.

Anthropic says Pro and Max limits are shared across Claude and Claude Code, and usage depends on prompt length, conversation length, attachments, and model. Usage credits can charge after included limits if the account has enabled them. The local app should expose that the CLI uses the user's shared plan quota and that an account with overage credits may incur spend. See [subscription access and rate limits](https://support.anthropic.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan) and [paid-plan usage credits](https://support.claude.com/en/articles/12429409-manage-usage-credits-for-paid-claude-plans). Exact model availability is account-dependent; `opus` is the CLI alias, while the signed-in CLI's `/model` is the account-level source of truth. No login was present here to verify it.

## Messages API fallback

The direct endpoint is `POST https://api.anthropic.com/v1/messages`. For a no-SDK Swift implementation, send `Authorization: Bearer <user API key>`, `anthropic-version: 2026-10-21`, and `content-type: application/json`; the API key belongs in Keychain and usage is billed to its owner. The current version is required for direct HTTP calls and Anthropic recommends using the latest version. See [API overview and headers](https://platform.claude.com/docs/en/api/overview) and [versioning](https://platform.claude.com/docs/en/api/versioning).

Current mainline API model IDs are `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`, and `claude-fable-5-1`. Opus 5.5 is the recommended design default and is active; it has a 1M-token context window, 128K maximum output, default `medium` effort, and list price $4/M input tokens and $20/M output tokens. The Opus estimate of roughly $0.50 for 40 slides is plausible but remains unmeasured; slide PDF tokenization, prompt size, output size, and selected effort determine actual cost. Check `GET /v1/models` for current API/account availability rather than hard-coding a list forever. Sources: [models overview](https://platform.claude.com/docs/en/models/overview), [Opus 5.5 specs and pricing](https://platform.claude.com/docs/en/models/opus-5-5/overview), [Models API](https://platform.claude.com/docs/en/api/models/list).

For JSON jobs, send `output_config.format = {"type":"json_schema","schema":...}`. API responses put the JSON text in a text content block. Set `output_config.effort` to `low`, `medium`, `high`, `xhigh`, or `max`; Opus 5.5 uses adaptive thinking, which cannot be turned off. Keep object schemas closed with `additionalProperties: false`, minimize optional/union fields, and validate the response before landing it. Structured outputs are supported on active models, but do not enforce every JSON Schema keyword: `format` is not enforced, numerical constraints are unsupported, and enum/const string capitalization can differ. Sources: [structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [effort](https://platform.claude.com/docs/en/build-with-claude/effort).

Send the lecture PDF as a user-message `document` block with a base64 source and `media_type: application/pdf`. Current first-party Messages API limits are 128 MB for the entire request and 600 PDF pages when the model context window is 1M tokens (100 pages under 1M); Opus 5.5 is a 1M model. The design's 32 MB limit is outdated as an Anthropic API limit, though 100 selected pages still fits current API page limits. Sources: [PDF support](https://platform.claude.com/docs/en/build-with-claude/pdf-support), [Opus 5.5 specs](https://platform.claude.com/docs/en/models/opus-5-5/overview).

API Ask streaming uses `stream: true` and SSE. Consume `message_start`, content block events and `text_delta`, then `message_delta`/`message_stop`; ignore ping and handle unknown event types. Cancel the Swift URLSession task when the user cancels. See [Messages streaming](https://platform.claude.com/docs/en/build-with-claude/streaming).

For prompt caching, put stable global rules and stable module instructions at the start of `system` or an early prompt block and mark the block with `cache_control: {"type":"ephemeral"}`. Opus 5.5's minimum cacheable prompt is 512 tokens; the default TTL is five minutes. A one-hour TTL is available, but its cache-write rate is higher. Current Opus 5.5 rates: normal input $4/M, 5-minute cache write $5/M, one-hour write $8/M, cache read $0.20/M. Cache reuse is beneficial only for identical prefixes reused within TTL; do not claim savings for first-call or changed prefixes. Sources: [prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching), [Opus 5.5 pricing](https://platform.claude.com/docs/en/models/opus-5-5/overview).

## Anki text export

The current [Anki text import manual](https://docs.ankiweb.net/manual/importing/text-files) resolves the old design question: importing a duplicate with the same first field and same note type updates other fields by default, and the import dialog can instead ignore or add duplicates. Existing notes stay in their current decks when updated, and their card scheduling is preserved. A GUID column/header is supported (Anki 2.1.54+); unchanged known Anki GUIDs update that note on re-import.

Important design correction: Anki says GUIDs are intended to be created by Anki. For app-created IDs (such as Lectern's UUID), its manual recommends putting the ID in the first field instead of treating it as Anki's internal GUID. Therefore the proposed “card UUID as GUID” is not supported by the manual as written. Resolve this with an Anki import spike before locking the format: either use a Lectern note type with a stable ID as the first regular field, or import/export Anki-created GUIDs and store those back into Lectern. Preserve same note type and “Update” duplicate handling. Headers including `separator`, `html`, `columns`, `tags column`, and `guid column` are supported; use UTF-8 tab-delimited output and test multiline/math escaping.

## Design claims and remaining smoke checks

| Design claim | Result |
| --- | --- |
| `claude -p --json-schema` exists | Verified by installed CLI help and current official CLI docs. |
| `--bare` must be avoided for subscription auth | Verified; it excludes OAuth and keychain. |
| `--safe-mode` can isolate personal memory, MCP, and skills without breaking auth | Verified in local help and official CLI docs; account authentication itself is currently absent. |
| API model ID `claude-opus-5-5` is valid | Verified as the current active Opus model ID. |
| 32 MB / 600 pages are the current API PDF limits | Incorrect as a combined claim: first-party API docs now say 128 MB and 600 pages for 1M-context models; smaller-context models have 100-page limit. |
| An unchanged GUID can update a text-imported note | Verified for Anki-created GUIDs; own UUID-as-GUID remains unsupported by the manual's recommendation. |
| Local CLI backend is ready for a real smoke test | Not verified: current auth status is logged out; no login or model call was allowed. |

Before provider completion, smoke-check: subscription login and available models in the user's CLI; a 1-page and an 11+ page PDF using the exact permission rule; schema success/refusal/exit envelope; SIGINT cancellation; and real Anki update behavior using the chosen first-field/GUID mapping. For distribution beyond one user's local app, obtain Anthropic policy confirmation or use API-key billing per user.

## Final review corrections

The subscription provider fails closed on Console OAuth and ambiguous `oauth_token` profiles. Current [authentication documentation](https://code.claude.com/docs/en/authentication#sign-in-without-an-api-key) describes a keyless Console OAuth route that is billed by API usage. Consequently, OAuth alone does not establish subscription billing. Lectern v1 requires ordinary `claude.ai` auth, first-party provider, and a known Pro/Max/Ultra/Team/Enterprise `subscriptionType` from `auth status`. This intentionally excludes setup-token profiles whose tier cannot be established from status. **The logged-in status shape and tier field have not been verified against a real account.** Fixtures exercise this strict gate, but a logged-in CLI may require a compatibility adjustment before it passes. No credential files were read. Subscription overage credits remain an account-controlled billing risk.

Native CLI discovery probes `~/.local/bin/claude` as well as Homebrew/configured/PATH locations; a Finder-launched app commonly has a minimal PATH. See [official installation docs](https://code.claude.com/docs/en/installation).
