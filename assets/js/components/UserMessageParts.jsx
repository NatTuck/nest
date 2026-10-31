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
 * ## Who spoke
 *
 * A block also carries the `[From … | mode: …]` header that was removed from it
 * (`utils/header.js`), and a row with **more than one block** captions each
 * block with its sender — the senders differ, so the row label cannot state
 * them. A single-body row shows no caption: the row label names the one sender,
 * and nothing is shown twice. The reply marker follows the same rule (it is
 * row-level for a single body, per caption here).
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
import { SenderCaption } from "./SenderCaption.jsx";
import { ToolMedia } from "./ToolMedia.jsx";
import { TruncatedResult } from "./TruncatedResult.jsx";
import { mediaFromParts, userPartsFor } from "../utils/messageParts.js";
import { rowSenders } from "../utils/header.js";

export function UserMessageParts({ message, className = "" }) {
  const blocks = userPartsFor(message);
  // One body needs no caption: the row label already names its sender. Several
  // do, because they can have different senders. The count is the label's own
  // (`rowAppearance` reads `rowSenders` too), not the block count: blocks
  // include a command's output, so a single backgrounded notice — one prose
  // body plus its output part — would otherwise grow a caption that merely
  // repeats the row label.
  const caption = rowSenders(message).length > 1;

  return (
    <>
      {/* Keyed on the block's own `key`: the blocks are a projection of the
          row's parts, so that is the one identity that is both unique and
          stable — a content key would collide, since two bodies of a drained
          batch can be byte-identical once the header is stripped, and a bare
          part index collides once one part holds several bodies. */}
      {blocks.map((block, index) => (
        <Block
          key={block.key}
          block={block}
          className={className}
          spaced={index > 0}
          caption={caption}
        />
      ))}
      <ToolMedia media={mediaFromParts(message?.parts)} />
    </>
  );
}

function Block({ block, className, spaced, caption }) {
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
  const body = (
    <>
      {caption && block.header && <SenderCaption header={block.header} />}
      {content}
    </>
  );

  return spaced ? <div className="mt-2">{body}</div> : body;
}
