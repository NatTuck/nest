/**
 * ToolCalls component tests.
 *
 * Covers: empty/missing toolCalls, rendering each tool call's
 * name, finalized-JSON preview, and the streaming-aware
 * rendering for partial-JSON args (short buffer / long
 * content / write_file-style long field).
 */
import { describe, it, expect } from "vitest";
import { render, screen, within } from "@testing-library/react";
import { ToolCalls } from "./ToolCalls";

describe("ToolCalls", () => {
  it("returns null when toolCalls is undefined", () => {
    const { container } = render(<ToolCalls toolCalls={undefined} />);
    expect(container.firstChild).toBeNull();
  });

  it("returns null when toolCalls is empty", () => {
    const { container } = render(<ToolCalls toolCalls={[]} />);
    expect(container.firstChild).toBeNull();
  });

  it("renders the tool name for each call", () => {
    const toolCalls = [
      { id: "1", name: "shell_cmd", arguments: { command: "ls" } },
      { id: "2", name: "read_file", arguments: { path: "/tmp/x" } },
    ];

    render(<ToolCalls toolCalls={toolCalls} />);

    expect(screen.getByText("Using tool: shell_cmd")).toBeInTheDocument();
    expect(screen.getByText("Using tool: read_file")).toBeInTheDocument();
  });

  it("renders the arguments preview as JSON for finalized (object) args", () => {
    const toolCalls = [
      { id: "1", name: "shell_cmd", arguments: { command: "ls -la" } },
    ];

    render(<ToolCalls toolCalls={toolCalls} />);

    // The arguments are JSON-stringified in a TruncatedResult.
    expect(screen.getByText(/"command"/)).toBeInTheDocument();
    expect(screen.getByText(/"ls -la"/)).toBeInTheDocument();
  });

  it("skips the arguments preview when arguments is empty", () => {
    const toolCalls = [{ id: "1", name: "shell_cmd", arguments: {} }];

    render(<ToolCalls toolCalls={toolCalls} />);

    expect(screen.getByText("Using tool: shell_cmd")).toBeInTheDocument();
  });

  it("skips the arguments preview when arguments is missing", () => {
    const toolCalls = [{ id: "1", name: "shell_cmd" }];

    render(<ToolCalls toolCalls={toolCalls} />);

    expect(screen.getByText("Using tool: shell_cmd")).toBeInTheDocument();
  });

  it("renders the partial JSON buffer verbatim when arguments is a short streaming string", () => {
    // Regression for the "tool calls don't stream" bug:
    // the partial buffer `'{"command":'` (still arriving)
    // must be visible to the user, not silently dropped.
    // The renderer puts it in a `<pre>` monospace block.
    const toolCalls = [
      { id: "1", name: "shell_cmd", arguments: '{"command":' },
    ];

    render(<ToolCalls toolCalls={toolCalls} />);

    expect(screen.getByText("Using tool: shell_cmd")).toBeInTheDocument();
    const pre = screen.getByTestId("tool-call-streaming-pre");
    expect(pre).toBeInTheDocument();
    expect(pre.textContent).toBe('{"command":');
    // The "Receiving" indicator pill is on the same row.
    expect(screen.getByTestId("streaming-indicator-1")).toBeInTheDocument();
  });

  it("renders newlines as real line breaks in short streaming buffers", () => {
    // Partial JSON that fails to parse (because the closing
    // quote is missing) drops into the `stream-short` path.
    // The buffer contains `\n` *characters* (BEAM stream
    // preserves them literally), so `whitespace-pre-wrap`
    // renders them as visible line breaks in the rendered
    // DOM. The test asserts the buffer passes through
    // verbatim — escaping happens at the JSON layer, not
    // the renderer.
    const toolCalls = [
      {
        id: "1",
        name: "write_file",
        arguments: '{"path":"/tmp/x","content":"line1\\nline2',
      },
    ];

    render(<ToolCalls toolCalls={toolCalls} />);

    const pre = screen.getByTestId("tool-call-streaming-pre");
    expect(pre).toBeInTheDocument();
    // Buffer passed through verbatim — same string the
    // BEAM is streaming. The visible line breaks come from
    // `whitespace-pre-wrap`.
    expect(pre.textContent).toBe('{"path":"/tmp/x","content":"line1\\nline2');
  });

  it("renders long-content tool calls in the cleaner plaintext path", () => {
    // The `write_file` test scenario: the `content` field
    // crosses the long-field threshold, so the renderer
    // switches to the cleaner plaintext path. The header row
    // shows the `path` field, and the content renders with
    // real newlines inside the long-content `<pre>`.
    //
    // The content is crafted to be long enough (>300 chars) to
    // trigger `stream-long` AND short enough that the 80-char
    // peek truncates and shows the trailing ellipsis — this
    // covers the `preview.length > 80 ? "…" : ""` branch.
    const _truncatedPeek = "x".repeat(80 - "/tmp/foo.txt".length - 1);
    const longContent = `line1\nline2\nline3\n${"x".repeat(600)}`;
    const toolCalls = [
      {
        id: "1",
        name: "write_file",
        arguments: JSON.stringify({
          path: "/tmp/foo.txt",
          content: longContent,
          mode: "0644",
        }),
      },
    ];

    render(<ToolCalls toolCalls={toolCalls} />);

    // The cleaner-path container is rendered.
    const longBlock = screen.getByTestId("tool-call-streaming-long");
    expect(longBlock).toBeInTheDocument();
    // The path appears in the header row (peek).
    expect(within(longBlock).getByText("/tmp/foo.txt")).toBeInTheDocument();
    // The preview is truncated to 80 chars when the content
    // is longer — covering the ellipsis branch. The peek is
    // "line1\nline2\nline3\nxxx…" (a 76-char slice followed by
    // the ellipsis suffix); we don't pin the exact substring
    // here because whitespace splitting in jsdom is fuzzy.
    expect(within(longBlock).getByText(/\u2026/)).toBeInTheDocument();
    // The full content with `\n` characters is in the body
    // block (preserved verbatim — the `<pre>` style renders
    // them as real line breaks in a real browser).
    const contentNodes = longBlock.querySelectorAll("pre");
    expect(contentNodes.length).toBeGreaterThan(0);
    expect(contentNodes[contentNodes.length - 1].textContent).toBe(longContent);
    // The tool name is still on the row.
    expect(screen.getByText("Using tool: write_file")).toBeInTheDocument();
    // The non-preview fields (e.g. `mode`) appear in the
    // metadata line below the body.
    expect(within(longBlock).getByText("mode:")).toBeInTheDocument();
    expect(within(longBlock).getByText("0644")).toBeInTheDocument();
  });

  it("renders the streaming indicator only when args are still arriving", () => {
    // Finalized (object) args have no buffer — no `Receiving`
    // pill. The pill is a streaming-only affordance.
    const finalized = render(
      <ToolCalls
        toolCalls={[
          { id: "a", name: "shell_cmd", arguments: { command: "ls" } },
        ]}
      />,
    );
    expect(
      finalized.queryByTestId("streaming-indicator-a"),
    ).not.toBeInTheDocument();

    // Empty-args also lack a buffer (we render the name
    // only — args arrive in the next delta).
    finalized.rerender(
      <ToolCalls toolCalls={[{ id: "a", name: "shell_cmd", arguments: "" }]} />,
    );
    expect(
      finalized.queryByTestId("streaming-indicator-a"),
    ).not.toBeInTheDocument();

    // Streaming string args → the pill shows.
    finalized.rerender(
      <ToolCalls
        toolCalls={[{ id: "a", name: "shell_cmd", arguments: '{"command":' }]}
      />,
    );
    expect(
      finalized.queryByTestId("streaming-indicator-a"),
    ).toBeInTheDocument();
  });
});
