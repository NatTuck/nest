/**
 * Splits a string on `<think>` / `</think>` markers and
 * returns the segments in original order. Each segment is
 * `{kind: "text" | "thinking", text: string}`.
 *
 * `<think>...</think>` blocks become `{kind: "thinking", text}`.
 * Everything else is `{kind: "text", text}`.
 *
 * Behavior:
 *
 *   - No markers: returns a single text segment.
 *   - One block: returns `[text-before, thinking, text-after]`.
 *   - Multiple blocks: returns the interleaved sequence.
 *   - Nested `<think>` inside a think block: the inner
 *     `<think>` is treated as text inside the think block
 *     (no recursion into a new thinking segment), but its
 *     matching `</think>` is consumed to keep the outer
 *     block from closing early.
 *   - Empty think blocks (`<think></think>`): emitted as a
 *     thinking segment with `text: ""` and then collapsed to
 *     "no thinking" downstream if needed.
 *   - Orphan `</think>` (no matching `<think>`): the orphan
 *     is treated as a thinking marker — everything from the
 *     orphan to the end of the string (or the next
 *     `<think>`) is routed to the thinking channel. This
 *     matches the "with any `<think>` blocks intact"
 *     principle: stray `</think>` text in the response is
 *     model reasoning, not user-visible content.
 *   - Orphan `<think>` (no matching `</think>`): everything
 *     from the orphan to the end of the string is routed to
 *     the thinking channel (incomplete think block).
 */
export function splitThinkTags(text) {
  if (typeof text !== "string" || text.length === 0) return [];
  return splitThinkTagsInner(text);
}

const OPEN = "<think>";
const CLOSE = "</think>";
const OPEN_LEN = OPEN.length;
const CLOSE_LEN = CLOSE.length;

function splitThinkTagsInner(text) {
  const segments = [];
  let buffer = "";
  let inThinking = false;
  let depth = 0;
  let i = 0;

  const flush = () => {
    // Always emit, even an empty segment — an empty think
    // block (`<think></think>`) is a real thinking segment
    // and gets dropped downstream by the caller. Empty text
    // segments (zero-length runs of text) are dropped here.
    if (buffer.length === 0 && !inThinking) return;
    segments.push({ kind: inThinking ? "thinking" : "text", text: buffer });
    buffer = "";
  };

  while (i < text.length) {
    if (inThinking) {
      // Walk through the text, tracking nested depth.
      let openIdx = text.indexOf(OPEN, i);
      let closeIdx = text.indexOf(CLOSE, i);
      while (i < text.length) {
        if (openIdx === -1 && closeIdx === -1) {
          buffer += text.slice(i);
          i = text.length;
          break;
        }
        if (openIdx !== -1 && (closeIdx === -1 || openIdx <= closeIdx)) {
          buffer += text.slice(i, openIdx + OPEN_LEN);
          depth += 1;
          i = openIdx + OPEN_LEN;
          openIdx = text.indexOf(OPEN, i);
        } else {
          // closeIdx comes first
          if (depth === 1) {
            buffer += text.slice(i, closeIdx);
            flush();
            i = closeIdx + CLOSE_LEN;
            inThinking = false;
            depth = 0;
            break;
          }
          buffer += text.slice(i, closeIdx + CLOSE_LEN);
          depth -= 1;
          i = closeIdx + CLOSE_LEN;
          closeIdx = text.indexOf(CLOSE, i);
        }
      }
      continue;
    }

    // text channel: find the next opening `<think>` or an
    // orphan `</think>`. Whichever comes first wins.
    const openIdx = text.indexOf(OPEN, i);
    const orphanCloseIdx = text.indexOf(CLOSE, i);
    let nextIdx = -1;
    let nextKind = null;

    if (openIdx !== -1 && orphanCloseIdx !== -1) {
      if (openIdx <= orphanCloseIdx) {
        nextIdx = openIdx;
        nextKind = "open";
      } else {
        nextIdx = orphanCloseIdx;
        nextKind = "orphan_close";
      }
    } else if (openIdx !== -1) {
      nextIdx = openIdx;
      nextKind = "open";
    } else if (orphanCloseIdx !== -1) {
      nextIdx = orphanCloseIdx;
      nextKind = "orphan_close";
    }

    if (nextIdx === -1) {
      buffer += text.slice(i);
      i = text.length;
    } else {
      buffer += text.slice(i, nextIdx);
      flush();
      if (nextKind === "open") {
        i = nextIdx + OPEN_LEN;
        inThinking = true;
        depth = 1;
      } else {
        i = nextIdx + CLOSE_LEN;
        inThinking = true;
        depth = 1;
      }
    }
  }

  flush();
  return segments;
}

/**
 * Walks a message's `parts` array. For each `Part.Text`, splits
 * the text on `<think>` / `</think>` markers, collects the
 * thinking content into a single string, and returns the
 * remaining text segments as separate `Part.Text` entries
 * (preserving the original `text` field for any non-`<think>`
 * content). `Part.Thinking` passes through — its content
 * accumulates into the same `thinking` string. Other part
 * types pass through unchanged in their original position.
 *
 * Returns:
 *   {
 *     thinking: string | null,    // concatenated thinking, or null if empty
 *     textParts: Part[],          // parts list with <think> blocks split out
 *   }
 *
 * Used by the history pane and the active message list to
 * render `` content as a collapsed ThinkingBlock above
 * the visible reply.
 */
export function splitThinkFromParts(parts) {
  if (!Array.isArray(parts)) return { thinking: null, textParts: [] };

  const textParts = [];
  let thinking = null;

  for (const p of parts) {
    if (!p) continue;

    if (p.kind === "thinking") {
      const t = p.thinking || "";
      if (t) {
        thinking = (thinking || "") + (thinking ? "\n\n" : "") + t;
      }
      continue;
    }

    if (p.kind === "text") {
      const segments = splitThinkTags(p.text || "");
      for (const seg of segments) {
        if (seg.kind === "thinking") {
          thinking = (thinking || "") + (thinking ? "\n\n" : "") + seg.text;
        } else {
          textParts.push({ ...p, text: seg.text });
        }
      }
      continue;
    }

    textParts.push(p);
  }

  return { thinking, textParts };
}
