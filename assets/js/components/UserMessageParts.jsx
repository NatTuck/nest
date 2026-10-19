/**
 * UserMessageParts — the body of a user-role row.
 *
 * A user row is not uniformly prose. Its `parts` can hold several `text`
 * parts, and a part's text is not always something to render as markdown:
 *
 *   - A backgrounded shell command's result is the prose that announces it
 *     ("Your backgrounded command (shell-cmd) finished. Its result:") followed
 *     by the command's own output (issue #139). The output is command output,
 *     so it goes through `TruncatedResult` — fixed font, collapsed when long —
 *     exactly like every other long tool result in this app. Rendering it
 *     through `<Markdown>` mangled it: `#`, `*`, `_`, backticks and indented
 *     lines are all markdown there.
 *   - A drained batch is one row holding one body per entry, each with its own
 *     header, so the row has several prose segments too.
 *
 * The blocks are therefore rendered **one at a time** rather than joined: they
 * are differently rendered segments. `userPartsFor` (which owns the ordering
 * and the header stripping) marks which are which; the output block is not
 * necessarily last, so nothing here may assume a position.
 *
 * `"output"` is a **render-time** kind this component synthesises. It is never
 * on the wire and never appears in `message.parts` — the wire says which parts
 * are output with the top-level `commandOutputParts` index list, and
 * `userPartsFor` turns that into these blocks.
 *
 * The row's attachments render once, after the blocks, from the `media` parts
 * of `message.parts` — `ToolMedia` renders nothing for `null`, so a row with
 * no attachment needs no guard here.
 */
import { MessageContent } from "./MessageContent.jsx";
import { ToolMedia } from "./ToolMedia.jsx";
import { TruncatedResult } from "./TruncatedResult.jsx";
import { mediaFromParts, userPartsFor } from "../utils/messageParts.js";

export function UserMessageParts({ message, className = "" }) {
  const blocks = userPartsFor(message);

  return (
    <>
      {/* Keyed on the block's own part index: the blocks are a projection of
          the row's parts, so that index is the one identity that is both unique
          and stable — a content key would collide, since two bodies of a
          drained batch can be byte-identical once the header is stripped. */}
      {blocks.map((block, index) => (
        <Block
          key={block.index}
          block={block}
          className={className}
          spaced={index > 0}
        />
      ))}
      <ToolMedia media={mediaFromParts(message?.parts)} />
    </>
  );
}

function Block({ block, className, spaced }) {
  if (block.kind === "output") {
    return <TruncatedResult content={block.text} />;
  }

  const content = (
    <MessageContent
      parts={[{ kind: "text", text: block.text }]}
      isPartial={false}
      className={className}
    />
  );

  // The blank line between two bodies of a batch sits at the *end* of the
  // preceding segment (the wire puts the separator there), where markdown drops
  // it, so the gap between two bodies has to come from the block that follows —
  // otherwise they run together. `TruncatedResult` already brings its own
  // `mt-2`, so only a text block needs the wrapper.
  return spaced ? <div className="mt-2">{content}</div> : content;
}
