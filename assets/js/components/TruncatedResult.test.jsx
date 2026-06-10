/**
 * TruncatedResult Component Tests
 *
 * Covers:
 * - Short content (≤ 20 lines) renders in full, no controls
 * - Long content (> 20 lines) shows preview + expand button
 * - Clicking expand shows full content (no duplication of preview)
 * - Clicking "Show less" collapses back to preview
 * - Boundary: exactly 20 lines is NOT collapsed; 21 lines IS
 * - className is applied to the <pre> for color/styling
 */

import { describe, it, expect } from "vitest";
import { render, screen, fireEvent, cleanup } from "@testing-library/react";
import { TruncatedResult } from "./TruncatedResult";

function buildLines(n) {
  return Array.from({ length: n }, (_, i) => `line ${i + 1}`).join("\n");
}

describe("TruncatedResult", () => {
  describe("short content", () => {
    it("renders the full content in a single <pre> when ≤ 20 lines", () => {
      const content = buildLines(5);
      render(<TruncatedResult content={content} />);

      const pre = document.querySelector("pre");
      expect(pre).toBeInTheDocument();
      expect(pre.textContent).toBe(content);
      expect(
        screen.queryByRole("button", { name: /show all/i }),
      ).not.toBeInTheDocument();
      expect(
        screen.queryByRole("button", { name: /show less/i }),
      ).not.toBeInTheDocument();
    });

    it("does not collapse at exactly 20 lines", () => {
      const content = buildLines(20);
      render(<TruncatedResult content={content} />);

      const pre = document.querySelector("pre");
      expect(pre.textContent).toBe(content);
      expect(
        screen.queryByRole("button", { name: /show all/i }),
      ).not.toBeInTheDocument();
    });

    it("renders nothing for empty content (no <pre>, no button)", () => {
      const { container } = render(<TruncatedResult content="" />);
      expect(container.querySelector("pre")).toBeNull();
      expect(
        screen.queryByRole("button", { name: /show all/i }),
      ).not.toBeInTheDocument();
    });

    it("applies className to the <pre>", () => {
      render(<TruncatedResult content="hello" className="text-red-600" />);
      const pre = document.querySelector("pre");
      expect(pre.className).toContain("text-red-600");
    });
  });

  describe("long content (> 20 lines)", () => {
    it("renders the first 10 lines as a preview by default", () => {
      const content = buildLines(25);
      render(<TruncatedResult content={content} />);

      const pre = document.querySelector("pre");
      expect(pre).toBeInTheDocument();
      // The preview should contain the first 10 lines
      expect(pre.textContent).toContain("line 1");
      expect(pre.textContent).toContain("line 10");
      // The preview should NOT contain lines beyond 10
      expect(pre.textContent).not.toContain("line 11");
      expect(pre.textContent).not.toContain("line 25");
    });

    it("shows a 'Show all N lines' button with the total line count", () => {
      const content = buildLines(42);
      render(<TruncatedResult content={content} />);

      const button = screen.getByRole("button", { name: /show all/i });
      expect(button).toBeInTheDocument();
      expect(button.textContent).toContain("42");
      expect(button).toHaveAttribute("aria-expanded", "false");
    });

    it("expands to the full content when the button is clicked (no duplication of preview)", () => {
      const content = buildLines(25);
      render(<TruncatedResult content={content} />);

      fireEvent.click(screen.getByRole("button", { name: /show all/i }));

      // After expanding, the full content should be visible
      const pre = document.querySelector("pre");
      expect(pre.textContent).toBe(content);
      // And the button text should toggle to "Show less"
      expect(
        screen.getByRole("button", { name: /show less/i }),
      ).toBeInTheDocument();
      expect(
        screen.queryByRole("button", { name: /show all/i }),
      ).not.toBeInTheDocument();
    });

    it("collapses back to the preview when 'Show less' is clicked", () => {
      const content = buildLines(25);
      render(<TruncatedResult content={content} />);

      fireEvent.click(screen.getByRole("button", { name: /show all/i }));
      expect(
        screen.getByRole("button", { name: /show less/i }),
      ).toBeInTheDocument();

      fireEvent.click(screen.getByRole("button", { name: /show less/i }));

      // After collapsing, the preview is back
      const pre = document.querySelector("pre");
      expect(pre.textContent).toContain("line 1");
      expect(pre.textContent).toContain("line 10");
      expect(pre.textContent).not.toContain("line 11");
      // And the button toggles back to "Show all"
      expect(
        screen.getByRole("button", { name: /show all/i }),
      ).toBeInTheDocument();
    });

    it("does not duplicate the first 10 lines when expanded", () => {
      const content = buildLines(30);
      const { container } = render(<TruncatedResult content={content} />);

      // Count <pre> blocks before expanding: should be 1 (just the preview)
      expect(container.querySelectorAll("pre").length).toBe(1);

      fireEvent.click(screen.getByRole("button", { name: /show all/i }));

      // After expanding: still exactly 1 <pre> (the full content replaces
      // the preview, not appended below).
      const pres = container.querySelectorAll("pre");
      expect(pres.length).toBe(1);
      expect(pres[0].textContent).toBe(content);
    });

    it("collapses at 21 lines (boundary)", () => {
      const content = buildLines(21);
      render(<TruncatedResult content={content} />);

      expect(
        screen.getByRole("button", { name: /show all/i }),
      ).toBeInTheDocument();
      // The preview shows only the first 10 lines
      const pre = document.querySelector("pre");
      expect(pre.textContent).not.toContain("line 21");
    });

    it("applies className to both preview and expanded <pre>", () => {
      const content = buildLines(25);
      const { container } = render(
        <TruncatedResult content={content} className="text-green-600" />,
      );

      let pre = container.querySelector("pre");
      expect(pre.className).toContain("text-green-600");

      fireEvent.click(screen.getByRole("button", { name: /show all/i }));
      pre = container.querySelector("pre");
      expect(pre.className).toContain("text-green-600");
    });
  });

  describe("single-line long content (char-collapse)", () => {
    it("collapses a single long line with a 'Show all N chars' button", () => {
      // Regression: previously, content with no newlines reported 1 line
      // and bypassed the 20-line threshold, even if it was visually long.
      const longLine = "x".repeat(2001);
      render(<TruncatedResult content={longLine} />);

      const button = screen.getByRole("button", { name: /show all/i });
      expect(button).toBeInTheDocument();
      expect(button.textContent).toContain("2001");
      expect(button.textContent).toContain("chars");
    });

    it("does not collapse at exactly 2000 chars (boundary)", () => {
      const content = "x".repeat(2000);
      render(<TruncatedResult content={content} />);

      const pre = document.querySelector("pre");
      expect(pre.textContent).toBe(content);
      expect(
        screen.queryByRole("button", { name: /show all/i }),
      ).not.toBeInTheDocument();
    });

    it("collapses at 2001 chars (boundary)", () => {
      const content = "x".repeat(2001);
      render(<TruncatedResult content={content} />);

      expect(
        screen.getByRole("button", { name: /show all/i }),
      ).toBeInTheDocument();
    });

    it("preview shows the first 1000 chars (with … when truncated)", () => {
      const longLine = "x".repeat(5000);
      render(<TruncatedResult content={longLine} />);

      const pre = document.querySelector("pre");
      // The preview is exactly previewMaxChars (1000), with the trailing
      // "…" indicating truncation.
      expect(pre.textContent.length).toBe(1000);
      expect(pre.textContent.endsWith("…")).toBe(true);
    });

    it("expands to the full content when the button is clicked", () => {
      const longLine = "x".repeat(5000);
      render(<TruncatedResult content={longLine} />);

      fireEvent.click(screen.getByRole("button", { name: /show all/i }));

      const pre = document.querySelector("pre");
      expect(pre.textContent).toBe(longLine);
      expect(
        screen.getByRole("button", { name: /show less/i }),
      ).toBeInTheDocument();
    });

    it("multi-line content under 2000 chars but over 20 lines still uses 'lines' button text", () => {
      // 25 lines, each 50 chars = 1250 chars total. Under 2000, so the
      // char threshold doesn't trigger; only the line threshold does.
      const lines = Array.from({ length: 25 }, () => "a".repeat(50));
      const content = lines.join("\n");
      expect(content.length).toBeLessThan(2000);
      expect(content.split("\n").length).toBe(25);

      render(<TruncatedResult content={content} />);

      const button = screen.getByRole("button", { name: /show all/i });
      expect(button.textContent).toContain("lines");
      expect(button.textContent).toContain("25");
    });
  });

  describe("configurable maxLines and previewLines", () => {
    it("respects a custom maxLines (collapse at 4 lines, not 21)", () => {
      // 3 lines: NOT collapsed
      render(<TruncatedResult content={"a\nb\nc"} maxLines={3} />);
      expect(
        screen.queryByRole("button", { name: /show all/i }),
      ).not.toBeInTheDocument();

      // The component's container is appended to document.body; clear it
      // before the second render to keep screen queries clean.
      cleanup();

      // 4 lines: collapsed
      render(<TruncatedResult content={"a\nb\nc\nd"} maxLines={3} />);
      expect(
        screen.getByRole("button", { name: /show all/i }),
      ).toBeInTheDocument();
    });

    it("respects a custom previewLines (preview shows only the first N lines)", () => {
      // 10 lines, maxLines=3, previewLines=2 -> preview shows first 2 lines
      const content = buildLines(10);
      render(
        <TruncatedResult content={content} maxLines={3} previewLines={2} />,
      );

      const pre = document.querySelector("pre");
      expect(pre.textContent).toContain("line 1");
      expect(pre.textContent).toContain("line 2");
      expect(pre.textContent).not.toContain("line 3");
    });
  });

  describe("previewMaxChars cap with … indicator", () => {
    it("truncates the preview at previewMaxChars and appends … when lines would exceed the cap", () => {
      // 3 lines, each 200 chars = 600 chars. previewMaxChars=300 should
      // truncate the joined preview and add a "…" indicator.
      const line = "a".repeat(200);
      const content = [line, line, line].join("\n");
      expect(content.length).toBe(602);

      render(
        <TruncatedResult
          content={content}
          maxLines={2}
          previewLines={3}
          previewMaxChars={300}
        />,
      );

      const pre = document.querySelector("pre");
      // The preview length is exactly previewMaxChars
      expect(pre.textContent.length).toBe(300);
      // And it ends with the ellipsis
      expect(pre.textContent.endsWith("…")).toBe(true);
    });

    it("does not append … when the preview fits within previewMaxChars", () => {
      // 3 short lines, previewMaxChars=300 -- the joined preview is well
      // under the cap, so no truncation.
      const content = "line 1\nline 2\nline 3";
      expect(content.length).toBeLessThan(300);

      render(
        <TruncatedResult
          content={content}
          maxLines={2}
          previewLines={3}
          previewMaxChars={300}
        />,
      );

      const pre = document.querySelector("pre");
      expect(pre.textContent).toBe(content);
      expect(pre.textContent).not.toContain("…");
    });

    it("truncates char-collapsed content at previewMaxChars with …", () => {
      // A 5000-char single line triggers char-collapse and shows the
      // first previewMaxChars chars with a "…" indicator.
      const longLine = "x".repeat(5000);
      render(<TruncatedResult content={longLine} previewMaxChars={300} />);

      const pre = document.querySelector("pre");
      expect(pre.textContent.length).toBe(300);
      expect(pre.textContent.endsWith("…")).toBe(true);
    });
  });

  describe("tool call args use case (3 lines / 300 chars)", () => {
    it("collapses a JSON-stringified args object to 3 lines with a button", () => {
      // Realistic tool call args: a command + a path + a flag.
      // JSON.stringify with 2-space indent produces 6 lines:
      //   {                       line 1
      //     "command": "...",     line 2
      //     "path": "...",        line 3
      //     "recursive": true     line 4
      //   }                       line 5
      // (6 lines if the input ends with a newline)
      const args = {
        command: "find /home/nat -name '*.md' -type f",
        path: "/home/nat/Code/nest",
        recursive: true,
      };
      const content = JSON.stringify(args, null, 2);
      // Sanity: more than 3 lines
      expect(content.split("\n").length).toBeGreaterThan(3);

      render(
        <TruncatedResult
          content={content}
          className="text-purple-600"
          maxLines={3}
          previewLines={3}
          previewMaxChars={300}
        />,
      );

      const pre = document.querySelector("pre");
      // Preview shows the first 3 lines: opening brace + 2 args
      expect(pre.textContent).toContain('"command"');
      expect(pre.textContent).toContain('"path"');
      // The third arg "recursive" is on line 4, NOT in the preview
      expect(pre.textContent).not.toContain('"recursive"');

      const button = screen.getByRole("button", { name: /show all/i });
      expect(button.textContent).toContain("lines");
    });

    it("does not collapse tool call args that fit within 3 lines", () => {
      // A single-field args object produces 3 lines (open + value + close).
      // That's exactly the maxLines, so NOT collapsed.
      const args = { command: "ls" };
      const content = JSON.stringify(args, null, 2);
      expect(content.split("\n").length).toBe(3);

      render(
        <TruncatedResult
          content={content}
          maxLines={3}
          previewLines={3}
          previewMaxChars={300}
        />,
      );

      const pre = document.querySelector("pre");
      expect(pre.textContent).toBe(content);
      expect(
        screen.queryByRole("button", { name: /show all/i }),
      ).not.toBeInTheDocument();
    });

    it("truncates a tool call with a very long single-line arg with …", () => {
      // A long command string + a flag = 4 lines but the command line
      // itself is huge, so the 3-line preview is truncated at 300 chars.
      const longCommand = `find ${"/very/long/path/".repeat(50)} -name foo`;
      const args = { command: longCommand, verbose: true };
      const content = JSON.stringify(args, null, 2);

      render(
        <TruncatedResult
          content={content}
          maxLines={3}
          previewLines={3}
          previewMaxChars={300}
        />,
      );

      const pre = document.querySelector("pre");
      expect(pre.textContent.length).toBe(300);
      expect(pre.textContent.endsWith("…")).toBe(true);
    });
  });
});
