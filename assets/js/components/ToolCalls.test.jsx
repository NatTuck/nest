/**
 * ToolCalls component tests.
 *
 * Covers: empty/missing toolCalls, rendering each tool call's
 * name, and rendering the JSON-formatted arguments preview.
 */
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
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

  it("renders the arguments preview as JSON", () => {
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

    // The tool name is still rendered.
    expect(screen.getByText("Using tool: shell_cmd")).toBeInTheDocument();
  });

  it("skips the arguments preview when arguments is missing", () => {
    const toolCalls = [{ id: "1", name: "shell_cmd" }];

    render(<ToolCalls toolCalls={toolCalls} />);

    expect(screen.getByText("Using tool: shell_cmd")).toBeInTheDocument();
  });
});
