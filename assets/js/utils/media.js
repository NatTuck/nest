/**
 * Shared presentation helpers for media parts (issue #40).
 *
 * A `media` part carries base64 in `data` with no `data:` prefix, the
 * DECODED byte count in `bytes`, the MIME type in `mediaType`, and the
 * sandbox path the agent asked for in `path` (omitted from the wire when
 * there is none, so it arrives as `undefined`).
 *
 * Both the message panel and the clipboard serialiser describe the same
 * attachment, so the vocabulary lives here rather than in either caller —
 * and the clipboard then says exactly what the panel showed.
 */

export const MODALITY_LABELS = {
  image: "Image",
  audio: "Audio",
  video: "Video",
};

/**
 * Human-readable size for a decoded byte count. Returns `null` when the
 * count is missing or not a number, so a caller renders its own explicit
 * "size not reported" indicator rather than an empty string.
 */
export function formatBytes(bytes) {
  if (typeof bytes !== "number" || !Number.isFinite(bytes) || bytes < 0) {
    return null;
  }
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`;
  if (bytes >= 1_000) return `${(bytes / 1_000).toFixed(1)} KB`;
  return `${bytes} bytes`;
}

/**
 * A `data:` URI for an `img`/`audio`/`video` element. Returns `null` when
 * the type or the payload is missing, so the caller can say so explicitly
 * instead of rendering a broken element with no explanation.
 */
export function mediaDataUri(media) {
  if (!media) return null;
  if (typeof media.mediaType !== "string" || media.mediaType === "") {
    return null;
  }
  if (typeof media.data !== "string" || media.data === "") return null;
  return `data:${media.mediaType};base64,${media.data}`;
}

/**
 * The one-line summary of a media part: type, decoded size, and the path
 * the agent asked for, with any missing field left out rather than
 * rendered as a blank. Used by the panel header and by the clipboard
 * serialiser.
 */
export function mediaSummary(media) {
  const type = media?.mediaType || "type not reported";
  return [type, formatBytes(media?.bytes), media?.path]
    .filter(Boolean)
    .join(" · ");
}
