import { Markdown } from "@llamaindex/chat-ui/widgets";

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

export function MessageContent({ content, isPartial, className = "" }) {
  if (!content) return null;

  if (isPartial) {
    const { completed, incomplete } = parseBlocks(content);

    if (completed.length === 0 && incomplete) {
      return <p className={`${className} whitespace-pre-wrap`}>{incomplete}</p>;
    }

    return (
      <div className={className}>
        {completed.map((block) => (
          <Markdown key={block.slice(0, 50)} content={block} />
        ))}
        {incomplete && <p className={`whitespace-pre-wrap`}>{incomplete}</p>}
      </div>
    );
  }

  return <Markdown content={content} className={className} />;
}
