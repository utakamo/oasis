# Durable tool history (issue #64)

Chat JSON now uses `format_version: 2`. Ordinary conversation text remains in
`messages`; `turns` stores the tools offered to the AI, its calls, and their
results. All three entry points (CLI, streaming WebUI, and RPC) use the same
recorder and storage implementation.

## Format and associations

```json
{
  "format_version": 2,
  "revision": 5,
  "last_operation_id": "save-token",
  "messages": [{"role": "user", "content": "Inspect the router"}],
  "turns": [{
    "id": "turn-token",
    "user_message": 1,
    "status": "incomplete",
    "requests": [{
      "id": "request-token",
      "provider": "OpenAI",
      "model": "selected-model",
      "status": "incomplete",
      "assistant_text": "Checking now",
      "tools": {
        "state": "provided",
        "definitions_json": "[{\"type\":\"function\",\"function\":{\"name\":\"inspect\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}]",
        "selection_json": "\"auto\""
      },
      "calls": [{
        "id": "call-token",
        "provider_id": "provider-call-id",
        "name": "inspect",
        "arguments_json": "{}",
        "status": "completed",
        "result": {
          "status": "success",
          "original_json": "{\"status\":\"OK\",\"user_only\":\"private detail\"}",
          "ai_json": "{\"status\":\"OK\"}"
        }
      }]
    }]
  }]
}
```

`user_message` is a one-based index into `messages`. The order of `turns`,
`requests`, and `calls` is significant. Each has its own persistence ID;
`provider_id` is optional and never invented when the provider omits it.
Each request retains accompanying assistant text, including tool-only responses
that do not create an ordinary assistant bubble.

Tool definitions and selection settings are extracted from the serialized
outgoing request, before transport. JSON strings preserve empty objects versus
arrays in schemas and original arguments where supplied as raw JSON. No tools
is an explicit `tools.state: "none"`; absence of a record means no recorded
request. Changes during Tool Search create a separate snapshot for each request.

Turn/request status is `incomplete`, `completed`, or `failed`. Calls start as
`pending`, become `running` before execution, and become `completed` or `failed`
when a result is saved. Result status is `success`, `error`, or `unknown`:
returning a value without an explicit outcome does not establish success.
Exceptions carry `result.error`; a missing result never implies success.
`cached: true` identifies reuse of an existing result within the live sequence.

## AI context and model switching

Resumed turns send ordinary conversation text only. Saved definitions, tool
requests, and results are review data and are not replayed into provider input.
Switching providers or models remains supported. Old provider call IDs are not
passed to the newly selected provider.

During the current turn, live calls and sanitized results still participate in
follow-up requests. Definitions always come from the current configuration and
tool state. Provider serializers project an explicit input structure; saved
metadata cannot become a message or be merged into current definitions. The
existing sanitizer removes `user_only` and UI actions from AI-facing results.
Original results remain in the conversation file for review.

## Checkpoints and failures

The recorder saves before the first request, before sending each request,
before dispatching a batch, before executing each call, after each available
result, and after the final answer. A new conversation is registered before any
tool executes. A later network error retains its conversation ID and all earlier
checkpoints, even without a final answer.

Storage serializes saves with a process lock, checks the expected revision,
writes a private temporary file in the same directory, flushes it, and replaces
the original with an atomic rename. Interrupted temporary files are cleaned up
on the next save or delete. The same operation ID and snapshot can be retried
without duplicating data. A stale revision or a token reused with different data
is rejected. Saving never calls an AI or executes a tool.

Each serialized conversation is limited to 4 MiB. Validation also bounds array
sizes and JSON nesting, including nested JSON strings. Insufficient space and
validation/write errors are returned to the caller. Execution stops before the
next tool. If a tool completed externally but its result could not be saved,
the previous checkpoint remains `running` with no result: the external outcome
is uncertain. There is no automatic replay, rollback, or exactly-once guarantee
for external effects. Reload the saved conversation before starting a new turn.

The existing 512 KiB WebUI import limit is retained and enforced on the server.
Exports larger than that limit cannot be re-imported through the WebUI. Aligning
storage/export capacity with the import limit remains outside this issue.

## Compatibility and access

Legacy `{ "messages": [...] }` documents remain loadable and are upgraded when
appended or imported. Missing historical information is not reconstructed.
Text export continues to use `messages` only. LuCI also restores accompanying
assistant text and tool activity from `turns` for display.
JSON export/import preserves all review information and associations; imports
receive fresh storage revision/operation tokens.

`oasis.chat create` and `append` retain their existing role/content arguments.
Structured calls accept a `data` string containing the complete document:

- `create`: supply `id`, `operation_id`, and `data` (initial revision zero).
- `append`: supply `id`, a fresh `operation_id`, and `data` with the revision
  returned by the previous save or load.
- Retrying the latest identical operation returns `duplicate: true` and the
  already committed revision. Legacy append callers can opt in with
  `operation_id`; callers without a token retain ordinary append semantics.

The RPC method names and existing access controls are unchanged. New files use
mode 0600. No authentication headers or service connection credentials are
added to history. Tool results can themselves contain configuration data and
must be treated as sensitive conversation content. Deleting a conversation
removes its text, review data, and interrupted temporary files together.

LuCI restores saved calls inside the corresponding assistant reply using the
same Tool Activity cards as live responses. Accompanying text and cards follow
request/call order; the final answer from `messages` is shown once. Failed or
interrupted turns without a final answer receive their own assistant bubble,
before the next user turn. Pending calls display "Not executed"; calls recorded
as running without a saved result display "Result unconfirmed". Requests that
only offered tool definitions do not create activity cards.

Only tool names, management targets, outcome badges, and explicit `user_only`
notices appear in cards. Raw definitions, arguments, and results remain available
in JSON exports. The original document is never modified by rendering.
Saved calls use a display-only entry point, without dispatching Wi-Fi, reboot,
shutdown, or service-restart actions. Notices use the shared HTML sanitizer,
which parses in an inert template before removing disallowed tags/attributes;
discarded images cannot load or execute handlers while being sanitized.

The LuCI Lua/ucode HTTP bridge can serialize empty lists as `{}`, even when
storage and ubus returned `[]`. The renderer treats non-array review collections
as empty when reading `turns`, `requests`, and `calls`. This normalization is
display-only: it does not modify the loaded document or change export/storage
formats. An empty final call list must not prevent the assistant reply from
being appended to the conversation.

## Validation

Changed packages: `oasis` 3.2.6-r25, `luci-app-oasis` 3.2.6-r36,
`oasis-mod-test` 1.0.0-r16, and `luci-i18n-oasis-ja` 1.0.0-r14.
The Tool Activity follow-up changes only LuCI and Japanese translations; the
storage format, backend, and tool execution paths are unchanged.

Run the assertion suites with `oasis_test --suite portable,unit,provider`.
The history unit fixtures use actual OpenWrt Lua, JSON, locking, and temporary
files, with UCI registration, tool execution, and AI transport mocked. They do
not alter live configuration or send prompts to external AI services. Coverage
includes all five calling adapters and all six provider serializers, legacy and
structured RPCs, atomic failures, duplicates, import round trips, original versus
sanitized results, partial batches, and all three output modes with changing
definitions and failed follow-ups. Use `--suite unit --filter history` to focus
on these cases.

Run browser tests with Playwright available in Node's module path:

```sh
node --test dev_tools/tests/test_chat_history.cjs
node --test dev_tools/tests/test_chat_tools.cjs dev_tools/tests/test_chat_uci_consent.cjs
node dev_tools/check_i18n.cjs
```

The history test exercises desktop and mobile layouts, inert rendering, model
switching, new/legacy imports, JSON/text exports within 512 KiB, and interrupted
calls without final answers. Dependency-free tool tests also cover interleaved
saved requests, repeated provider IDs, final-text deduplication, checkpoint
recovery, and one-based associations across failed and later turns. Set
`OASIS_TEST_SCREENSHOTS_DIR` to retain desktop and mobile screenshots. Browser
HTTP is mocked using repository assets; these checks do not replace an end-to-end
test with a live AI provider.

### Recorded results

Validation on 2026-10-21:

- OpenWrt target (24.10.0), isolated fixture files: **194 tests, 2,951 assertions,
  zero failures**, including process exit during execution and fresh/continued
  turns in CLI, WebUI-output, and RPC-output modes.
- Host portable suite: **34 tests, 512 assertions, zero failures**.
- Browser history, tool display, and UCI consent suites: **42 tests, zero
  failures**. Desktop (1200x900) and mobile (390x844) screenshots were inspected.
- Lua 5.1 / JavaScript syntax checks and `git diff --check`: passed. Translation
  check: **347 source messages matched 347 Japanese translations**.
- All four changed packages built successfully as **IPK** using an isolated copy
  of the configured OpenWrt `mipsel_24kc` buildroot. New runtime modules and tests
  were checked inside the generated archives against the source files.

Packages were built, but not installed over the router's existing installation.
On-device validation ran the changed source in a temporary fixture environment;
AI transport, tool operations, and UCI writes were mocked. APK builds and live
AI-provider end-to-end tests were not performed. The existing feed reports
unrelated missing-dependency warnings (including `po2lmo/host`); the available
LuCI host converter successfully compiled the Japanese LMO package.

Tool Activity UI follow-up validation on 2026-10-22:

- Tool/turn DOM fixtures and browser history/UCI consent suites: **50 tests,
  zero failures**. History screenshots cover desktop and mobile, including
  failed/interrupted calls without a final answer. History cases were rerun
  after disabling screenshot animations.
- JavaScript syntax checks, `git diff --check`, and translation checks passed:
  **349 source messages matched 349 Japanese translations**.
- `luci-app-oasis` 3.2.6-r35 and `luci-i18n-oasis-ja` 1.0.0-r14 built as **IPK**
  with the configured OpenWrt package makefiles and existing host tools. A
  temporary workspace held only package sources, metadata, and build outputs;
  the full buildroot was not copied. All 27 packaged payload files matched the
  source or freshly compiled LMO, and the old history renderer was absent.
- No packages were installed on the router; browser HTTP/AI responses were
  mocked. Backend suites were not rerun for this UI-only follow-up. Temporary
  Playwright/headless-browser files and the package workspace were removed
  after retaining packages, logs, and screenshots.

History reload correction (LuCI 3.2.6-r36), validated on 2026-10-22:

- The installed r35 reproduced the failure with the device's real HTTP response:
  `request.calls.forEach is not a function`, zero assistant bubbles, and zero
  tool cards. Saved text was present. Storage and ubus represented the final
  empty call list as `[]`; the LuCI HTTP response represented it as `{}`.
- Loading the corrected `chat-turn.js` in the test browser, while retaining
  the device's actual page and HTTP responses, restored one assistant bubble,
  both recorded tool calls, and the saved final text. The router's installed
  files were not replaced during this comparison; no AI/tool/configuration
  operations were requested. Results retain counts/booleans only, not chat text.
- Three new regression tests failed before the fix and passed afterward.
  All **53** DOM/browser regression tests passed. Desktop and mobile history
  tests now emulate LuCI's empty-object responses, including exports/imports,
  absent tool history, and interruptions before any AI request.
- JavaScript syntax, translation audit (349 messages), and whitespace checks
  passed. The LuCI IPK built successfully; all **26** payload files matched
  the workspace. Translation and backend packages did not change in this fix.
- The connected OpenWrt router was then upgraded from LuCI r35 to r36 using
  the generated IPK. All 25 installed runtime files matched the old package
  before upgrading and the new package afterward. Saved chat files and Oasis
  configuration fingerprints were unchanged; the temporary IPK was removed.
- A fresh browser load using only the installed router files restored the same
  one assistant reply, two tool calls, and matching final text without errors.
  The served template references the r36 asset versions. Temporary host browser
  dependencies and the minimal build workspace were removed after validation.
