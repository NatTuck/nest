import { useState } from "react";
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

/**
 * Collapsible thinking section component
 */
function ThinkingSection({ content, isPartial }) {
  // Start uncollapsed, then collapse after receiving complete message
  const [isCollapsed, setIsCollapsed] = useState(false);

  const toggleCollapse = () => {
    setIsCollapsed(!isCollapsed);
  };

  return (
    <div className="my-2 border border-gray-200 rounded-lg bg-gray-50">
      <button
        type="button"
        onClick={toggleCollapse}
        className="w-full flex items-center justify-between px-3 py-2 text-sm font-medium text-gray-600 hover:bg-gray-100 rounded-t-lg transition-colors"
      >
        <div className="flex items-center gap-2">
          <svg
            className="w-4 h-4 text-gray-400"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
            aria-label="Thinking icon"
            role="img"
          >
            <title>Thinking</title>
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m12.728 0l-.707.707M12 21a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          <span>Thinking</span>
        </div>
        <svg
          className={`w-4 h-4 text-gray-400 transition-transform ${
            isCollapsed ? "rotate-180" : ""
          }`}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          aria-label={isCollapsed ? "Expand" : "Collapse"}
          role="img"
        >
          <title>{isCollapsed ? "Expand" : "Collapse"}</title>
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth={2}
            d="M5 15l7-7 7 7"
          />
        </svg>
      </button>
      {!isCollapsed && (
        <div className="px-3 py-2 text-sm text-gray-500 whitespace-pre-wrap">
          {content}
          {isPartial && (
            <span className="inline-flex gap-1 ml-1">
              <span
                className="w-1.5 h-1.5 bg-gray-400 rounded-full animate-bounce"
                style={{ animationDelay: "0ms" }}
              />
              <span
                className="w-1.5 h-1.5 bg-gray-400 rounded-full animate-bounce"
                style={{ animationDelay: "150ms" }}
              />
              <span
                className="w-1.5 h-1.5 bg-gray-400 rounded-full animate-bounce"
                style={{ animationDelay: "300ms" }}
              />
            </span>
          )}
        </div>
      )}
    </div>
  );
}

/**
 * Placeholder for unsupported content types
 */
function UnsupportedPlaceholder({ content }) {
  return (
    <span className="inline-block px-2 py-1 text-sm text-gray-500 bg-gray-100 rounded">
      {content}
    </span>
  );
}

// Counter for generating unique keys
let segmentKeyCounter = 0;

/**
 * Render a single segment based on its type
 */
function SegmentContent({ segment, isPartial, className = "" }) {
  switch (segment.type) {
    case "thinking":
      return (
        <ThinkingSection content={segment.content} isPartial={isPartial} />
      );

    case "unsupported":
      return <UnsupportedPlaceholder content={segment.content} />;

    default: {
      const { completed, incomplete } = parseBlocks(segment.content);

      if (isPartial) {
        if (completed.length === 0 && incomplete) {
          return (
            <p className={`${className} whitespace-pre-wrap`}>{incomplete}</p>
          );
        }

        return (
          <div className={className}>
            {completed.map((block) => (
              <Markdown key={block.slice(0, 50)} content={block} />
            ))}
            {incomplete && <p className="whitespace-pre-wrap">{incomplete}</p>}
          </div>
        );
      }

      return <Markdown content={segment.content} className={className} />;
    }
  }
}

/**
 * Message content component that handles segments (thinking, text, unsupported)
 */
export function MessageContent({
  content,
  segments,
  isPartial,
  className = "",
}) {
  if (!content) return null;

  // If no segments provided, treat entire content as a single text segment
  const segmentsToRender =
    segments && segments.length > 0 ? segments : [{ type: "text", content }];

  // Reset counter on each render to ensure consistency
  segmentKeyCounter = 0;

  return (
    <div className="space-y-2 [&_pre]:whitespace-pre-wrap [&_pre]:break-words [&_pre]:overflow-x-hidden [&_p]:[overflow-wrap:anywhere] [&_li]:[overflow-wrap:anywhere] [&_.prose]:max-w-none">
      {segmentsToRender.map((segment) => {
        segmentKeyCounter += 1;
        return (
          <SegmentContent
            key={`${segment.type}-${segmentKeyCounter}`}
            segment={segment}
            isPartial={isPartial}
            className={className}
          />
        );
      })}
    </div>
  );
}
