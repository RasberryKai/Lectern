# AI interaction diagnostics

Every new AI execution records a local trace, including successful calls, failures,
cancellations, and automatic learning-point extraction. Each retry creates a new
attempt directory. Existing jobs gain traces when executed again; older failures
cannot be reconstructed retroactively.

Default location:

```text
~/Library/Application Support/Lectern/Library/
  Modules/<module ID>/Lectures/<lecture ID>/jobs/<job ID>/
    snapshot.json
    ai-logs/<UTC timestamp>-<attempt UUID>/
      summary.json
      events.jsonl
      request.json
      response.json
      runner-response.json
      cli-invocation.json
      cli-stdin.txt
      cli-stdout.txt
      cli-stderr.txt
      cli-exit.json
      cli-auth-invocation.json
      cli-auth-stdout.txt
      cli-auth-stderr.txt
      cli-auth-exit.json
      codex-invocation.json
      codex-rpc-sent.jsonl
      codex-rpc-received.jsonl
      codex-stderr.txt
      codex-exit.json
      http-01-request.json
      http-01-response.json
      http-01-body.json (or .sse / .error.txt)
```

Each lecture also has `ai-usage.jsonl`, a compact accounting ledger outside the
job directories. Settings → **AI usage** shows totals for all three backends,
with a **Learning points v2** filter for background extraction, Review suggestion
and summary checks, plus a trigger breakdown. Full card generation remains in
**All AI** because its total includes ordinary slide cards as well as chat drafts. The CLI equivalent
is `lectern usage MODULE_ID LECTURE_ID [--v2]` (with `--root` before the command
for another library). These commands read local files and make no AI calls.

The ledger records each execution attempt separately, including retries and
failures: backend/model, job and attempt IDs, start/finish time, status, provider
calls attempted, reported input/output/cache tokens, and small outcome counters.
V2 records also identify the purpose, trigger, module, lecture, chat and parent
job. Skipped checks are separate zero-call records with a reason. Incremental
snapshots of one attempt are coalesced by attempt ID when reading; they are not
additional calls. A damaged or incomplete JSONL line does not hide later records.

Reported usage is captured before response validation, so a truncated or invalid
answer can still contribute tokens. Missing provider usage stays **unknown** and
is excluded from token totals. An HTTP request or CLI invocation counts as one
provider call attempted; CLI providers may perform multiple internal model steps
that Lectern cannot count independently. Input totals already include reported
cache reads/writes. Subscription cost/quota percentages are unavailable, and API
prices remain estimates for supported models. Historical jobs have no complete
attempt or V2 trigger history and cannot be backfilled reliably.

Only files relevant to the execution are present. API chat tool rounds get their
own numbered HTTP files. `--root` uses the same structure in the selected library.
If the requested working directory is missing, preflight diagnostics fall back to
`~/Library/Logs/Lectern/AI/<job ID>/<attempt>/` without creating a missing job directory.

Find traces from the command line:

```sh
swift run lectern job-logs MODULE_ID LECTURE_ID JOB_ID
swift run lectern --root /path/to/library job-logs MODULE_ID LECTURE_ID JOB_ID
```

This read-only command prints all attempt summary paths and their contents. AI
commands also print the job's log directory. Failed jobs retain their trace path
in the job error so it is available from the app or `lectern show`.

## Debugging with Codex

Give Codex the failed job's `summary.json` path (or the job's `ai-logs` directory).
Start with the summary and `events.jsonl`, then inspect the matching transport
files and frozen job snapshot. Compare attempts when a retry behaves differently.

- `summary.json` records job/attempt identity, backend, requested model, app/OS
  version, start/finish time, duration, last phase, original failure phase, final
  status, typed error, and truncated files. Decoding failures include their coding
  path and debug detail.
- `request.json` preserves system/user prompts and chat context; the transport
  request records the effective model and actual invocation/body. Inline PDF
  bytes are represented by size/hash. API base64 attachments are omitted from
  diagnostics; frozen source assets remain in the job directory.
- CLI files preserve the executable and resolved path, arguments, scoped working
  directory, PATH, limits, actual stdin, stdout/stderr, PID, exit status, signal
  versus normal exit, timeout/cancellation flags, and pipe-drain status. The
  optional `cli-stderr-tail.txt` keeps the final error after noisy stderr.
  The subscription-auth check has separate files. Read both stdout and stderr:
  Claude can put the useful error in either, including JSON result envelopes.
  Codex CLI attempts also retain the sanitized JSON-RPC requests and responses,
  so a failed turn can be traced past process startup into the Codex protocol
  exchange. Credential values are excluded from these records.
- API files preserve each request/response body or SSE stream, status, request
  ID, retry-after, selected rate-limit headers, tool calls and results. Request
  headers are allowlisted; authorization headers are never serialized.
- The runner keeps the returned payload before decoding and records validation
  and landing. A successful transport followed by a failed job therefore remains
  distinguishable from a transport failure.

`status: running` with no finish event means the attempt did not finish recording;
check app/process interruption as well as the last phase and available output.
It is not proof that the request is still active. Output is written as complete
lines arrive; an unfinished line is flushed on normal process/interaction finish.
An abrupt app kill can lose the current unterminated line. Logs provide evidence,
not a guarantee that every external failure exposes its cause.

## Storage and privacy

Logs contain study content: full text prompts, model replies, and tool results.
They stay on this Mac. Directories use mode `0700`; files use `0600`. Keys, known
credential environment values, credential fields, bearer tokens, and Anthropic
key patterns are redacted. No whole environment, Keychain contents, or CLI auth
configuration is dumped. Arbitrary secrets embedded in study text cannot be
identified reliably; review files before sharing them.

Artifacts are limited to 16 MiB each and 64 MiB per attempt, excluding the small
summary. Within that budget, up to 1 MiB is reserved for terminal metadata; the
timeline and individual status files have a 128 KiB cap. Truncation is explicit
in `summary.json`; oversized unterminated lines
are dropped. Logging failures emit a warning to stderr and do not change the AI
result. Ordinary terminal job snapshots and their traces expire after seven days during
library cleanup. Snapshots referenced by saved lecture chats are retained for
chat retry, along with their traces. Fallback preflight traces outside the library
are not part of that cleanup. Copy a trace elsewhere if it needs to be retained.
Portable lecture/module backups do not include job-directory diagnostics.
The compact usage ledger survives job cleanup and contains no prompts or replies.
It remains with its lecture until the lecture is deleted; portable backups do not
currently include it. Ledger writes are best effort, use owner-only file access,
and never cause an otherwise successful AI operation to fail.

## Verification (2026-11-08)

The full offline suite passed with `swift test --no-parallel`: 44 XCTest cases
passed, and Swift Testing reported 162 tests with the three live checks disabled.
The 13 diagnostics tests also passed together with the default parallel scheduler.
The offline CLI demo and `job-logs` lookup produced and found real attempt files.
No live AI inference was used for these checks.

An unrestricted full parallel run stalled in this environment and was stopped;
its cause remains unverified. Serial execution completed successfully, including
the explicit job concurrency, cancellation, and retry tests.


## Usage accounting verification (2026-11-15)

Eight ledger/provider tests pass, including failed validation and nonzero CLI
usage, missing versus explicit-zero usage, partial multi-call usage, redaction,
retry aggregation, damaged-line recovery and actual V2 HTTP schemas. The full
serial offline suite passes (48 XCTest cases, 212 Swift Testing checks; live
checks disabled). The read-only `usage --v2` command and native Settings view
both reproduced the scratch fixture's 3 calls and 3,500 input / 270 output tokens.
See `learning-points-v2/VERIFICATION.md` for the repair test matrix and UI checks.
