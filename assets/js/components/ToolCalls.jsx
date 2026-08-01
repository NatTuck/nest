/**
 * ToolCalls component — displays the tool calls in an assistant
 * message. Each tool call shows its name and a preview of its
 * arguments:
 *   - finalized (object): `<TruncatedResult>` formatted JSON.
 *   - short streaming (partial JSON that parses to a small
 *     object, or a buffer that hasn't parsed yet): a small
 *     monospace `<pre>` so the user can see arguments streaming
 *     character-by-character.
 *   - long streaming (`write_file` / long-shell-command): a
 *     path/header row plus a plain-text body block where the
 *     embedded `\n` characters render as real line breaks
 *     (`whitespace-pre-wrap`), so the file body or long command
 *     reads naturally without escape sequences.
 *
 * The streaming-aware rendering decision lives in
 * `formatToolCall` in `messageParts.js`. We don't decide here
 * — we just branch on its discriminated-union output.
 */
import { TruncatedResult } from "./TruncatedResult";
import { sortArgumentsForDisplay } from "../utils/argumentDisplay";
import { formatToolCall } from "../utils/messageParts";

export function ToolCalls({ toolCalls }) {
  if (!toolCalls || toolCalls.length === 0) return null;

  return (
    <div className="mt-3 space-y-2">
      {toolCalls.map((call) => {
        const formatted = formatToolCall(call);
        return (
          <div
            key={call.id}
            className="bg-purple-50 border border-purple-200 rounded-lg p-3"
          >
            <div className="flex items-center gap-2 text-purple-700 font-medium text-sm">
              <svg
                className="w-4 h-4"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                aria-label="Success checkmark icon"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
                />
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                />
              </svg>
              <span>Using tool: {call.name}</span>
              {/* Show a "Receiving" pill whenever a buffer
                  is in flight — partial or streaming. Empty
                  (no deltas at all) renders the name only so
                  the pill doesn't flicker on every tool_use_start. */}
              {(formatted.kind === "stream-short" ||
                formatted.kind === "stream-long") && (
                <span
                  data-testid={`streaming-indicator-${call.id}`}
                  className="ml-auto text-xs text-purple-500 inline-flex items-center gap-1"
                  title="Receiving tool arguments"
                >
                  <span className="w-1.5 h-1.5 rounded-full bg-purple-500 animate-pulse" />
                  Receiving
                </span>
              )}
            </div>
            {renderArguments(formatted)}
          </div>
        );
      })}
    </div>
  );
}

// Render the arguments preview block. Branch on the
// discriminated union from `formatToolCall`:
//
//   `object`        — formatted JSON in a `<TruncatedResult>`
//   `stream-short`  — partial JSON in a `<pre>` monospace block
//                     with real newlines preserved (`whitespace-
//                     pre-wrap`).
//   `stream-long`   — `write_file` style: a path/header row +
//                     the long string field rendered with real
//                     line breaks, plus any other fields as a
//                     compact metadata line below.
//   `empty`         — caller gates on `kind !== "empty"` to
//                     suppress rendering.
function renderArguments(formatted) {
  if (formatted.kind === "empty") return null;

  if (formatted.kind === "object") {
    return (
      <TruncatedResult
        content={JSON.stringify(
          sortArgumentsForDisplay(formatted.value),
          null,
          2,
        )}
        className="text-purple-600"
        maxLines={3}
        previewLines={3}
        previewMaxChars={300}
      />
    );
  }

  if (formatted.kind === "stream-short") {
    // Short streaming buffer — render verbatim in a tiny
    // monospace block. Embedded `\n` characters become real
    // line breaks thanks to `whitespace-pre-wrap`, so a
    // `write_file` body that's small enough to fit the
    // short-path heuristic reads naturally without the
    // viewer having to mentally unescape the JSON framing.
    return (
      <pre
        data-testid="tool-call-streaming-pre"
        className="mt-2 text-xs font-mono whitespace-pre-wrap break-words bg-white border border-purple-100 rounded p-2 text-purple-800 max-h-48 overflow-y-auto"
      >
        {formatted.raw}
      </pre>
    );
  }

  // `stream-long` — the user is writing a file or running
  // a long command. Show a compact path/header line so the
  // identifying info is up front, plus the long content
  // field as a plain text block where `\n` renders as actual
  // line breaks. Any remaining fields (e.g. `mode`,
  // `encoding`) appear as a compact metadata line below.
  const otherFields = {};
  for (const [k, v] of Object.entries(formatted.value || {})) {
    if (k !== formatted.previewField) otherFields[k] = v;
  }

  return (
    <div data-testid="tool-call-streaming-long" className="mt-2 space-y-2">
      {formatted.previewField && (
        <div className="text-xs text-purple-700 font-mono break-words">
          <span className="text-purple-500">{formatted.previewField}:</span>{" "}
          <span className="bg-white border border-purple-100 rounded px-1">
            {/* The header is a compact one-line peek at the
                field name + a small slice of content, so the
                user can see "path: /tmp/foo.txt" up front
                while the long body renders below. */}
            {formatted.preview.slice(0, 80)}
            {formatted.preview.length > 80 ? "…" : ""}
          </span>
        </div>
      )}
      {formatted.previewField && (
        <pre className="text-xs font-mono whitespace-pre-wrap break-words bg-white border border-purple-100 rounded p-2 text-purple-800 max-h-48 overflow-y-auto">
          {formatted.preview}
        </pre>
      )}
      {Object.keys(otherFields).length > 0 && (
        <div className="text-xs text-purple-700 font-mono break-words">
          {Object.entries(otherFields).map(([k, v]) => (
            <span key={k} className="mr-3">
              <span className="text-purple-500">{k}:</span>{" "}
              <span>{typeof v === "string" ? v : JSON.stringify(v)}</span>
            </span>
          ))}
        </div>
      )}
    </div>
  );
}
