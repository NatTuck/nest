# Copy-as-markdown / copy-as-json buttons

## Goal

Add small, always-visible copy buttons next to chat messages (copy as markdown)
and inside the API Logs block (copy as JSON). Pure client-side work; no server
or wire-format changes.

## Why

When the LLM produces a useful reply (a long explanation, a code block, a
file content dump), the user currently has to manually select the text in the
chat bubble. A copy button is the standard UX for chat clients and is
expected. The same applies to API logs when debugging a tool call: rather
than scroll-and-select the JSON, click once and paste into a ticket.

## Design choices

- **Always visible** (not `opacity-0 group-hover:opacity-100` like the
  Sidebar delete button) because the chat is the primary read view and the
  user shouldn't have to discover the button by hovering.
- **Click feedback** — show a check icon for 2s after a successful copy, then
  revert to the regular copy icon. Uses a `useCopyToClipboard(timeout)` hook
  so the button state is per-instance and the timer doesn't leak across
  re-renders.
- **Per-message "copy as markdown"** for chat messages. Strips the
  `[mode: X]\n` prefix (via the existing `stripModePrefix` util) for user
  messages so what gets pasted is what the user typed. Thinking + content
  for assistant messages are concatenated with a `---` separator.
- **Per-block "copy as JSON"** for API logs. Mirrors exactly what the block
  renders inside its `<pre>`. Format is `JSON.stringify(payload, null, 2)`.
- **`navigator.clipboard.writeText`** with a `document.execCommand("copy")`
  fallback for environments where the modern API is missing (some
  iframe-embedded contexts, older test runners). The hook also surfaces
  failure by logging to `console.error` with a `[NEST REGRESSION]` prefix
  — the click handler still completes; we don't throw, because there's
  nothing the user can do in the UI about a clipboard failure.

## Files to add

- `assets/js/utils/clipboard.js` — `copyToClipboard(text)` + `useCopyToClipboard(timeout)`
- `assets/js/utils/formatMessage.js` — `messageToMarkdown(message)` + `formatApiLogsAsJson(apiLogs)`
- `assets/js/components/CopyButton.jsx` — reusable icon button

## Files to modify

- `assets/js/pages/ChatPage.jsx` — render `<CopyButton>` in the message header
  with the per-message markdown
- `assets/js/components/ApiLogsBlock.jsx` — render `<CopyButton>` in the block
  header with the JSON dump

## Tests

- `assets/js/utils/clipboard.test.js` — `copyToClipboard` resolves; modern API
  is preferred; `execCommand` fallback works when `navigator.clipboard` is
  missing; `useCopyToClipboard` flips `copied` true→false after the timeout
- `assets/js/utils/formatMessage.test.js` — user messages strip mode prefix;
  assistant messages concat thinking + content; tool messages use `content`;
  system messages use `content`; `null`/missing `content` handled; api
  logs JSON is `JSON.stringify(..., null, 2)`
- `assets/js/components/CopyButton.test.jsx` — renders copy icon by default;
  click triggers `copyToClipboard` with the right text; shows check icon
  after click; reverts to copy icon after the timeout
- `assets/js/pages/ChatPage.test.jsx` — message has a copy button that copies
  the message's markdown when clicked (mock `navigator.clipboard.writeText`)
- `assets/js/components/ApiLogsBlock.test.jsx` — API Logs block has a copy
  button that copies the JSON dump when clicked

## Out of scope

- Per-tool-call / per-tool-result copy buttons (separate task; the user
  asked specifically for chat messages and API logs).
- "Copy entire conversation" — would need a separate component sitting
  above the message list.
