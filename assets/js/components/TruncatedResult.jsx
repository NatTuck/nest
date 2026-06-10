/**
 * Truncated tool result renderer.
 *
 * Renders a string (typically multi-line tool output) in a <pre> block.
 * The content is collapsed by default if it exceeds EITHER a line-count
 * threshold OR a character-count threshold:
 *
 * - Line threshold: > maxLines (default 20) lines (counted by \n separators).
 *   Catches multi-line outputs (find, cat, git log, etc.).
 * - Char threshold: > maxChars (default 2000) characters.
 *   Catches single-line long outputs (JSON dumps, base64, long error
 *   messages) that have no newlines but are visually long.
 *
 * When collapsed, the preview is computed as:
 * - Line-collapse: the first previewLines (default 10) lines, but if the
 *   joined length exceeds previewMaxChars (default 1000), the preview is
 *   truncated to that cap and a "…" indicator is appended.
 * - Char-collapse: the first previewMaxChars characters, with "…" if cut.
 *
 * When expanded, the full content replaces the preview (no duplication of
 * the preview). Clicking again collapses back to the preview.
 *
 * - Short content (neither threshold exceeded): full content, no controls.
 * - Empty content: renders nothing.
 */

import { useState } from "react";

const ELLIPSIS = "…";

function countLines(content) {
  if (!content) return 0;
  return content.split("\n").length;
}

function ChevronDown({ rotated = false }) {
  return (
    <svg
      className={`w-3 h-3 transition-transform ${rotated ? "rotate-180" : ""}`}
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth={2}
        d="M19 9l-7 7-7-7"
      />
    </svg>
  );
}

export function TruncatedResult({
  content,
  className = "",
  maxLines = 20,
  maxChars = 2000,
  previewLines = 10,
  previewMaxChars = 1000,
}) {
  const [isExpanded, setIsExpanded] = useState(false);
  const totalLines = countLines(content);
  const totalChars = content?.length ?? 0;
  const tooManyLines = totalLines > maxLines;
  const tooManyChars = totalChars > maxChars;
  const shouldCollapse = tooManyLines || tooManyChars;

  // Empty content: render nothing.
  if (!content) {
    return null;
  }

  // Short content: render in full, no controls.
  if (!shouldCollapse) {
    return (
      <pre
        className={`mt-2 text-xs whitespace-pre-wrap break-words overflow-x-hidden ${className}`}
      >
        {content}
      </pre>
    );
  }

  let preview;
  if (tooManyLines) {
    const joined = content.split("\n").slice(0, previewLines).join("\n");
    preview =
      joined.length > previewMaxChars
        ? joined.slice(0, previewMaxChars - ELLIPSIS.length) + ELLIPSIS
        : joined;
  } else {
    preview =
      content.length > previewMaxChars
        ? content.slice(0, previewMaxChars - ELLIPSIS.length) + ELLIPSIS
        : content;
  }

  const buttonLabel = tooManyLines
    ? `Show all ${totalLines} lines`
    : `Show all ${totalChars} chars`;

  return (
    <div className="mt-2">
      {isExpanded ? (
        <pre
          className={`text-xs whitespace-pre-wrap break-words overflow-x-hidden ${className}`}
        >
          {content}
        </pre>
      ) : (
        <pre
          className={`text-xs whitespace-pre-wrap break-words overflow-x-hidden ${className}`}
        >
          {preview}
        </pre>
      )}

      {isExpanded ? (
        <button
          type="button"
          onClick={() => setIsExpanded(false)}
          aria-expanded="true"
          className="mt-1 text-xs font-medium text-indigo-600 hover:text-indigo-700 flex items-center gap-1"
        >
          <ChevronDown rotated />
          Show less
        </button>
      ) : (
        <button
          type="button"
          onClick={() => setIsExpanded(true)}
          aria-expanded="false"
          className="mt-1 text-xs font-medium text-indigo-600 hover:text-indigo-700 flex items-center gap-1"
        >
          <ChevronDown />
          {buttonLabel}
        </button>
      )}
    </div>
  );
}
