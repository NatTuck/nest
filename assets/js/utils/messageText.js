/**
 * Canonical text extraction for chat messages and streaming
 * accumulators.
 *
 * Two flavors:
 *
 *   - `messageText(message)`  — read finalized messages from
 *     `cache.messages[i]`. Their shape has been `parts`-only
 *     since the content→parts cleanup; we pass through to
 *     `textFromParts`.
 *
 *   - `streamingText(streaming)` — read the in-flight
 *     streaming accumulator (`cache.streaming` / `cache.partial`).
 *     `partial`-shaped accumulators (legacy code path) may
 *     carry a flat `content` string — we check that first as
 *     a back-compat shim, then fall through to `parts`.
 *
 * `textFromParts` is also exported so legacy call sites that
 * already imported it from `MessageContent` keep working.
 */

export function textFromParts(parts) {
  if (!Array.isArray(parts)) return "";
  return parts
    .filter((p) => p && p.kind === "text")
    .map((p) => p.text || "")
    .join("");
}

export function messageText(message) {
  if (!message) return "";
  if (Array.isArray(message.parts)) {
    const fromParts = textFromParts(message.parts);
    if (fromParts) return fromParts;
  }
  return typeof message.content === "string" ? message.content : "";
}

export function streamingText(streaming) {
  if (!streaming) return "";
  if (Array.isArray(streaming.parts)) {
    const fromParts = textFromParts(streaming.parts);
    if (fromParts) return fromParts;
  }
  return typeof streaming.content === "string" ? streaming.content : "";
}
