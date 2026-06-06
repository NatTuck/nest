import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MessageContent, parseBlocks } from "./MessageContent";

const mockMarkdown = vi.fn();
vi.mock("@llamaindex/chat-ui/widgets", () => ({
  Markdown: (...args) => mockMarkdown(...args),
}));

beforeEach(() => {
  mockMarkdown.mockReset();
  mockMarkdown.mockImplementation(({ content }) => (
    <div data-testid="markdown-rendered" data-content={content}>
      {content}
    </div>
  ));
});

describe("MessageContent", () => {
  describe("segments support", () => {
    it("renders text segments with Markdown", () => {
      const segments = [{ type: "text", content: "Hello world" }];
      render(
        <MessageContent
          content="Hello world"
          segments={segments}
          isPartial={false}
        />,
      );

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
      expect(screen.getByTestId("markdown-rendered")).toHaveAttribute(
        "data-content",
        "Hello world",
      );
    });

    it("renders thinking segments with collapsible section", () => {
      const segments = [{ type: "thinking", content: "I am thinking..." }];
      render(
        <MessageContent
          content="I am thinking..."
          segments={segments}
          isPartial={false}
        />,
      );

      expect(
        screen.getByRole("button", { name: /thinking/i }),
      ).toBeInTheDocument();
      expect(screen.getByText("I am thinking...")).toBeInTheDocument();
    });

    it("renders thinking section with typing indicator when partial", () => {
      const segments = [{ type: "thinking", content: "Thinking..." }];
      render(
        <MessageContent
          content="Thinking..."
          segments={segments}
          isPartial={true}
        />,
      );

      expect(
        screen.getByRole("button", { name: /thinking/i }),
      ).toBeInTheDocument();
      // Check for typing indicator (animate-bounce elements)
      const typingIndicators = document.querySelectorAll(".animate-bounce");
      expect(typingIndicators.length).toBeGreaterThan(0);
    });

    it("collapses and expands thinking section on click", () => {
      const segments = [{ type: "thinking", content: "Secret thoughts" }];
      render(
        <MessageContent
          content="Secret thoughts"
          segments={segments}
          isPartial={false}
        />,
      );

      // Initially expanded
      expect(screen.getByText("Secret thoughts")).toBeInTheDocument();

      // Click to collapse
      fireEvent.click(screen.getByRole("button", { name: /thinking/i }));
      expect(screen.queryByText("Secret thoughts")).not.toBeInTheDocument();

      // Click to expand
      fireEvent.click(screen.getByRole("button", { name: /thinking/i }));
      expect(screen.getByText("Secret thoughts")).toBeInTheDocument();
    });

    it("renders unsupported segments with placeholder", () => {
      const segments = [
        { type: "unsupported", content: "[redacted thinking]" },
      ];
      render(
        <MessageContent
          content="[redacted thinking]"
          segments={segments}
          isPartial={false}
        />,
      );

      expect(screen.getByText("[redacted thinking]")).toBeInTheDocument();
      expect(screen.getByText("[redacted thinking]").className).toContain(
        "bg-gray-100",
      );
    });

    it("renders multiple segments in order", () => {
      const segments = [
        { type: "thinking", content: "First thought" },
        { type: "text", content: "Then response" },
        { type: "unsupported", content: "[image]" },
      ];
      render(
        <MessageContent
          content="First thought Then response [image]"
          segments={segments}
          isPartial={false}
        />,
      );

      expect(
        screen.getByRole("button", { name: /thinking/i }),
      ).toBeInTheDocument();
      expect(screen.getByText("First thought")).toBeInTheDocument();
      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
      expect(screen.getByText("[image]")).toBeInTheDocument();
    });

    it("falls back to content when segments is empty", () => {
      render(
        <MessageContent
          content="Fallback content"
          segments={[]}
          isPartial={false}
        />,
      );

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
      expect(screen.getByTestId("markdown-rendered")).toHaveAttribute(
        "data-content",
        "Fallback content",
      );
    });

    it("falls back to content when segments is undefined", () => {
      render(
        <MessageContent
          content="Fallback content"
          segments={undefined}
          isPartial={false}
        />,
      );

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
      expect(screen.getByTestId("markdown-rendered")).toHaveAttribute(
        "data-content",
        "Fallback content",
      );
    });
  });

  describe("partial/streaming messages", () => {
    it("renders plain text when isPartial is true", () => {
      render(<MessageContent content="Hello world" isPartial={true} />);

      const element = screen.getByText("Hello world");
      expect(element.tagName).toBe("P");
      expect(element.className).toContain("whitespace-pre-wrap");
    });

    it("preserves whitespace in partial messages", () => {
      const content = "Line 1\nLine 2\n\nLine 4";
      render(<MessageContent content={content} isPartial={true} />);

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
      expect(screen.getByText(/Line 4/)).toBeInTheDocument();
    });

    it("renders empty content gracefully when partial", () => {
      render(<MessageContent content="" isPartial={true} />);

      expect(screen.queryByTestId("markdown-rendered")).not.toBeInTheDocument();
    });

    it("applies custom className to partial messages", () => {
      render(
        <MessageContent
          content="Test content"
          isPartial={true}
          className="custom-class"
        />,
      );

      const element = screen.getByText("Test content");
      expect(element.className).toContain("custom-class");
      expect(element.className).toContain("whitespace-pre-wrap");
    });
  });

  describe("complete messages", () => {
    it("renders with Markdown component when isPartial is false", () => {
      render(<MessageContent content="Hello world" isPartial={false} />);

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
      expect(screen.getByTestId("markdown-rendered")).toHaveAttribute(
        "data-content",
        "Hello world",
      );
    });

    it("renders markdown headings", () => {
      const content = "# Heading 1\n## Heading 2";
      render(<MessageContent content={content} isPartial={false} />);

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
    });

    it("renders code blocks", () => {
      const codeContent = "```javascript\nconst x = 1;\n```";
      render(<MessageContent content={codeContent} isPartial={false} />);

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
      expect(screen.getByTestId("markdown-rendered")).toHaveAttribute(
        "data-content",
        codeContent,
      );
    });

    it("renders inline code", () => {
      render(
        <MessageContent
          content="Use `npm install` to install"
          isPartial={false}
        />,
      );

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
    });

    it("renders lists", () => {
      const content = "- Item 1\n- Item 2\n- Item 3";
      render(<MessageContent content={content} isPartial={false} />);

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
    });

    it("renders links", () => {
      render(
        <MessageContent
          content="[Click here](https://example.com)"
          isPartial={false}
        />,
      );

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
    });

    it("renders LaTeX inline math", () => {
      render(
        <MessageContent
          content="The formula is $E = mc^2$"
          isPartial={false}
        />,
      );

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
      expect(screen.getByTestId("markdown-rendered")).toHaveAttribute(
        "data-content",
        "The formula is $E = mc^2$",
      );
    });

    it("renders LaTeX block math", () => {
      const latexContent =
        "$$Area = \\frac{1}{2} \\times base \\times height$$";
      render(<MessageContent content={latexContent} isPartial={false} />);

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
      expect(screen.getByTestId("markdown-rendered")).toHaveAttribute(
        "data-content",
        latexContent,
      );
    });

    it("renders empty content gracefully when complete", () => {
      render(<MessageContent content="" isPartial={false} />);

      expect(screen.queryByTestId("markdown-rendered")).not.toBeInTheDocument();
    });

    it("renders null content gracefully", () => {
      render(<MessageContent content={null} isPartial={false} />);

      expect(screen.queryByTestId("markdown-rendered")).not.toBeInTheDocument();
    });
  });

  describe("transition from partial to complete", () => {
    it("switches from plain text to markdown when isPartial changes", () => {
      const { rerender } = render(
        <MessageContent content="Hello world" isPartial={true} />,
      );

      expect(screen.getByText("Hello world").tagName).toBe("P");
      expect(screen.queryByTestId("markdown-rendered")).not.toBeInTheDocument();

      rerender(<MessageContent content="Hello world" isPartial={false} />);

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
      expect(screen.getByTestId("markdown-rendered").textContent).toBe(
        "Hello world",
      );
    });

    it("re-renders markdown when content updates while complete", () => {
      const { rerender } = render(
        <MessageContent content="Initial content" isPartial={false} />,
      );

      expect(screen.getByTestId("markdown-rendered")).toHaveAttribute(
        "data-content",
        "Initial content",
      );

      rerender(<MessageContent content="Updated content" isPartial={false} />);

      expect(screen.getByTestId("markdown-rendered")).toHaveAttribute(
        "data-content",
        "Updated content",
      );
    });

    it("re-renders plain text when content updates while partial", () => {
      const { rerender } = render(
        <MessageContent content="Initial" isPartial={true} />,
      );

      expect(screen.getByText("Initial")).toBeInTheDocument();

      rerender(<MessageContent content="Initial + more" isPartial={true} />);

      expect(screen.getByText("Initial + more")).toBeInTheDocument();
    });
  });

  describe("parseBlocks", () => {
    it("parses paragraph with blank line separator", () => {
      const result = parseBlocks("Complete paragraph.\n\nIncomplete text");
      expect(result.completed).toEqual(["Complete paragraph."]);
      expect(result.incomplete).toBe("Incomplete text");
    });

    it("parses closed code block with following content", () => {
      const content = "```javascript\nconst x = 1;\n```\nStreaming...";
      const result = parseBlocks(content);
      expect(result.completed).toEqual(["```javascript\nconst x = 1;\n```"]);
      expect(result.incomplete).toBe("Streaming...");
    });

    it("treats unclosed code block as incomplete", () => {
      const result = parseBlocks("```javascript\nconst x = 1;");
      expect(result.completed).toEqual([]);
      expect(result.incomplete).toBe("```javascript\nconst x = 1;");
    });

    it("parses heading followed by blank line", () => {
      const result = parseBlocks("# Heading\n\nParagraph done.");
      expect(result.completed).toEqual(["# Heading"]);
      expect(result.incomplete).toBe("Paragraph done.");
    });

    it("parses list items followed by blank line", () => {
      const result = parseBlocks("- Item 1\n- Item 2\n\nStreaming...");
      expect(result.completed).toEqual(["- Item 1\n- Item 2"]);
      expect(result.incomplete).toBe("Streaming...");
    });

    it("returns empty for null content", () => {
      const result = parseBlocks(null);
      expect(result.completed).toEqual([]);
      expect(result.incomplete).toBe("");
    });

    it("returns empty for empty content", () => {
      const result = parseBlocks("");
      expect(result.completed).toEqual([]);
      expect(result.incomplete).toBe("");
    });

    it("returns single incomplete block for content without blank lines", () => {
      const result = parseBlocks("Hello world");
      expect(result.completed).toEqual([]);
      expect(result.incomplete).toBe("Hello world");
    });

    it("handles multi-block code block with middle blocks", () => {
      const content = "```python\n\nprint('hello')\n\n```";
      const result = parseBlocks(content);
      expect(result.completed).toEqual(["```python\n\nprint('hello')\n\n```"]);
      expect(result.incomplete).toBe("");
    });

    it("handles unclosed multi-block code block", () => {
      const content = "```python\n\nprint('hello')";
      const result = parseBlocks(content);
      expect(result.completed).toEqual([]);
      expect(result.incomplete).toBe("```python\n\nprint('hello')");
    });
  });

  describe("progressive block formatting", () => {
    it("renders completed paragraph with markdown when ends with blank line", () => {
      const content = "Complete paragraph.\n\nIncomplete text";
      render(<MessageContent content={content} isPartial={true} />);

      expect(mockMarkdown).toHaveBeenCalled();
      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
      expect(screen.getByText(/Incomplete text/)).toBeInTheDocument();
    });

    it("renders completed code block with markdown when closed", () => {
      const content = "```javascript\nconst x = 1;\n```\nStreaming...";
      render(<MessageContent content={content} isPartial={true} />);

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
    });

    it("treats unclosed code block as partial", () => {
      const content = "```javascript\nconst x = 1;";
      render(<MessageContent content={content} isPartial={true} />);

      expect(screen.queryByTestId("markdown-rendered")).not.toBeInTheDocument();
      expect(screen.getByText(/```javascript/)).toBeInTheDocument();
    });

    it("handles mixed completed and incomplete blocks", () => {
      const content = "# Heading\n\nParagraph done.\n\n**Incomplete";
      render(<MessageContent content={content} isPartial={true} />);

      expect(screen.getAllByTestId("markdown-rendered").length).toBe(2);
      expect(screen.getByText(/Incomplete/)).toBeInTheDocument();
    });

    it("handles list items followed by blank line as complete", () => {
      const content = "- Item 1\n- Item 2\n\nStreaming...";
      render(<MessageContent content={content} isPartial={true} />);

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
    });

    it("handles multi-block code block with middle blocks", () => {
      const content = "```python\n\nprint('hello')\n\n```";
      render(<MessageContent content={content} isPartial={true} />);

      expect(screen.getByTestId("markdown-rendered")).toBeInTheDocument();
    });

    it("handles unclosed multi-block code block as partial", () => {
      const content = "```python\n\nprint('hello')";
      render(<MessageContent content={content} isPartial={true} />);

      expect(screen.queryByTestId("markdown-rendered")).not.toBeInTheDocument();
    });
  });
});
