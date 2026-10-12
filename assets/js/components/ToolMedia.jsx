/**
 * ToolMedia — the media a tool attached (issue #40).
 *
 * A `file-read` that attached an image puts a `media` part beside its
 * `tool_result`; this renders it. Every field the part carries is shown —
 * the type, the decoded size, and the path the agent asked for — so the
 * panel says what happened without the user having to open the raw
 * payload.
 *
 * Nothing is dropped silently. A modality this build does not know, a
 * missing MIME type, a missing size, and a payload that cannot build a
 * data URI each get their own explicit indicator, because a row written
 * by a newer build must not render as a message with no attachment at
 * all.
 */
import {
  MODALITY_LABELS,
  formatBytes,
  mediaDataUri,
  mediaSummary,
} from "../utils/media.js";

export function ToolMedia({ media }) {
  if (!Array.isArray(media) || media.length === 0) return null;

  return (
    <div className="mt-2 space-y-2" data-testid="tool-media">
      {media.map((item) => (
        // Keyed on the part's own identity rather than its position, so a
        // re-render cannot re-associate an element with different media. Two
        // media parts in one message always answer different tool calls or
        // came from different paths.
        <MediaItem
          key={`${item.tool_call_id ?? "media"}:${item.path ?? ""}`}
          media={item}
        />
      ))}
    </div>
  );
}

function MediaItem({ media }) {
  const label = MODALITY_LABELS[media.modality];
  const size = formatBytes(media.bytes);
  const uri = mediaDataUri(media);

  return (
    <div
      className="rounded-lg border border-gray-200 bg-gray-50 p-2"
      data-testid="tool-media-item"
    >
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-gray-500">
        <span className="font-medium text-gray-700">
          {label ?? `Unknown media modality (${String(media.modality)})`}
        </span>
        <span aria-hidden="true">·</span>
        <span className="font-mono">
          {media.mediaType || "type not reported"}
        </span>
        <span aria-hidden="true">·</span>
        <span className={size ? undefined : "text-amber-700"}>
          {size ?? "size not reported"}
        </span>
        {media.path && (
          <>
            <span aria-hidden="true">·</span>
            <span className="font-mono break-all">{media.path}</span>
          </>
        )}
      </div>
      <div className="mt-2">{renderPreview(media, uri)}</div>
    </div>
  );
}

function renderPreview(media, uri) {
  if (!uri) {
    return (
      <p
        className="text-xs text-amber-700"
        data-testid="tool-media-unavailable"
      >
        Payload unavailable ({mediaSummary(media)}), so there is nothing to
        preview.
      </p>
    );
  }

  switch (media.modality) {
    case "image":
      return (
        <img
          src={uri}
          alt={media.path ? `Attached image ${media.path}` : "Attached image"}
          className="max-h-96 w-auto rounded border border-gray-200"
          data-testid="tool-media-image"
        />
      );
    case "audio":
      return (
        // biome-ignore lint/a11y/useMediaCaption: tool output has no track
        <audio controls src={uri} data-testid="tool-media-audio" />
      );
    case "video":
      return (
        // biome-ignore lint/a11y/useMediaCaption: tool output has no track
        <video
          controls
          src={uri}
          className="max-h-96"
          data-testid="tool-media-video"
        />
      );
    default:
      // A modality from a newer build. Say so rather than showing nothing.
      return (
        <p className="text-xs text-gray-500" data-testid="tool-media-unknown">
          No preview is available for modality {String(media.modality)} in this
          build.
        </p>
      );
  }
}
