import { Markdown } from "@llamaindex/chat-ui/widgets";

import { ToolMedia } from "./ToolMedia.jsx";
import { mediaFromParts } from "../utils/messageParts.js";
import { textFromParts } from "../utils/messageText.js";

// Tailwind classes that tame the @llamaindex/chat-ui `<Markdown>`
// component's HTML output: code blocks wrap rather than overflow,
// prose paragraphs/lists break on any character, the typography
// plugin's 65ch max-width is removed, and a table (which a model writes
// as freely as it writes prose) scrolls inside its own box instead of
// widening the column under it — `display: block` is what gives a table
// a scroll container of its own while its rows keep laying out as rows.
//
// A list level indents by three things at once — the typography plugin's
// `1.625em` padding, the markdown styles' `20px` margin, and the `li`'s own
// `.375em` — so a second-level item on a 390px screen started ~90px into a
// ~330px bubble. Below `sm` the margin goes and the padding becomes 1.25rem, so
// each level costs ~26px instead of ~52: still visibly nested, and the text
// keeps its width. The marker is drawn in the padding, so it still has room.
//
// The margin is the one rule here that needs `!important`, and the reason is
// specificity rather than order: `@llamaindex/chat-ui`'s
// `.custom-markdown ul:not(.custom-renderer *)` is 0,2,1 — the `:not()` argument
// counts — while `max-sm:[&_ul]:ml-0` compiles to 0,1,1, so no selector this
// variant can build wins on merit. `!` is scoped to this one property, at this
// one breakpoint, against a vendor stylesheet; reordering the imports would not
// help.
const MARKDOWN_CONTAINER_CLASS =
  "space-y-2 [&_pre]:whitespace-pre-wrap [&_pre]:break-words [&_pre]:overflow-x-hidden [&_p]:[overflow-wrap:anywhere] [&_li]:[overflow-wrap:anywhere] [&_table]:block [&_table]:overflow-x-auto [&_.prose]:max-w-none max-sm:[&_ol]:ml-0! max-sm:[&_ol]:pl-5 max-sm:[&_ul]:ml-0! max-sm:[&_ul]:pl-5";

export function parseBlocks(content) {
  if (!content) return { completed: [], incomplete: "" };

  const lines = content.split("\n");
  const completedBlocks = [];
  let currentBlock = [];
  let inCodeBlock = false;
  let codeBlockDelimiter = "";

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const nextLine = lines[i + 1];
    const hasNextLine = i < lines.length - 1;

    if (inCodeBlock) {
      currentBlock.push(line);
      const isCodeBlockEnd =
        line === codeBlockDelimiter || line.startsWith(codeBlockDelimiter);
      if (isCodeBlockEnd) {
        inCodeBlock = false;
        codeBlockDelimiter = "";
        completedBlocks.push(currentBlock.join("\n"));
        currentBlock = [];
      }
      continue;
    }

    const isCodeBlockStart = line.match(/^(`{3,}|~{3,})/);
    if (isCodeBlockStart) {
      if (currentBlock.length > 0) {
        const blockContent = currentBlock.join("\n").trim();
        if (blockContent) {
          completedBlocks.push(blockContent);
        }
        currentBlock = [];
      }
      currentBlock.push(line);
      inCodeBlock = true;
      codeBlockDelimiter = isCodeBlockStart[1];
      continue;
    }

    currentBlock.push(line);

    if (hasNextLine && nextLine === "" && currentBlock.length > 0) {
      completedBlocks.push(currentBlock.join("\n"));
      currentBlock = [];
    }
  }

  const incompleteContent = currentBlock.join("\n");

  return {
    completed: completedBlocks.filter((b) => b.trim().length > 0),
    incomplete: incompleteContent.trim(),
  };
}

/**
 * Renders the visible (markdown) content of a chat message.
 *
 * Accepts `parts` (the canonical wire format from the backend;
 * only `text` parts contribute to the visible content). The
 * component flattens `parts` to a string before rendering so
 * the markdown layout, progressive block formatting, and
 * code-fence handling all work unchanged.
 *
 * For partial / streaming messages, completed paragraphs (those
 * terminated by a blank line or a closed code fence) are
 * rendered through `<Markdown>` so headings, code, and lists
 * format correctly as they stream in. The trailing
 * unterminated block is rendered as plain text so the cursor
 * stays at the end without prematurely closing a code fence or
 * list.
 */
export function MessageContent({ parts, isPartial, className = "" }) {
  const text = textFromParts(parts);
  const media = mediaFromParts(parts);

  if (!text && !media) return null;

  const body = text ? renderText(text, isPartial, className) : null;

  // A message with no media renders exactly what it did before — one
  // element, not a fragment — so nothing about the existing output changes.
  // Media is a sibling of the text rather than part of it: a `media` part
  // has no text, and a message can carry one with no text at all.
  if (!media) return body;

  return (
    <>
      {body}
      <ToolMedia media={media} />
    </>
  );
}

function renderText(text, isPartial, className) {
  // The wrapper applies `&_*` descendant selectors that tame the
  // @llamaindex/chat-ui `<Markdown>` component's HTML output —
  // code blocks (`<pre>`) wrap rather than overflow, prose
  // paragraphs/lists break on any character, and the typography
  // plugin's 65ch max-width is removed. These are inherited by
  // every rendered Markdown block, partial or complete.
  if (isPartial) {
    const { completed, incomplete } = parseBlocks(text);

    if (completed.length === 0 && incomplete) {
      return <p className={`${className} whitespace-pre-wrap`}>{incomplete}</p>;
    }

    return (
      <div className={`${MARKDOWN_CONTAINER_CLASS} ${className}`}>
        {completed.map((block) => (
          <Markdown key={block.slice(0, 50)} content={block} />
        ))}
        {incomplete && <p className="whitespace-pre-wrap">{incomplete}</p>}
      </div>
    );
  }

  return (
    <div className={MARKDOWN_CONTAINER_CLASS}>
      <Markdown content={text} className={className} />
    </div>
  );
}
