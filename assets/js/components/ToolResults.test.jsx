/**
 * ToolResults component tests.
 *
 * Covers: empty/missing toolResults, success vs. error rendering,
 * the arguments preview, and the content body.
 */
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { ToolResults } from "./ToolResults";

describe("ToolResults", () => {
  it("returns null when toolResults is undefined", () => {
    const { container } = render(<ToolResults toolResults={undefined} />);
    expect(container.firstChild).toBeNull();
  });

  it("returns null when toolResults is empty", () => {
    const { container } = render(<ToolResults toolResults={[]} />);
    expect(container.firstChild).toBeNull();
  });

  it("renders 'Success: <name>' for non-error results", () => {
    const toolResults = [
      {
        tool_call_id: "1",
        name: "shell_cmd",
        content: "total 4\ndrwxrwxr-x 1 user user 18 May 29 10:49 .",
        is_error: false,
      },
    ];

    render(<ToolResults toolResults={toolResults} />);

    expect(screen.getByText(/Success: shell_cmd/)).toBeInTheDocument();
  });

  it("renders 'Error: <name>' for error results", () => {
    const toolResults = [
      {
        tool_call_id: "1",
        name: "shell_cmd",
        content: "command not found",
        is_error: true,
      },
    ];

    render(<ToolResults toolResults={toolResults} />);

    expect(screen.getByText(/Error: shell_cmd/)).toBeInTheDocument();
  });

  it("renders the content body for each result", () => {
    const toolResults = [
      {
        tool_call_id: "1",
        name: "shell_cmd",
        content: "total 4",
        is_error: false,
      },
    ];

    render(<ToolResults toolResults={toolResults} />);

    expect(screen.getByText("total 4")).toBeInTheDocument();
  });

  it("renders the arguments preview when present", () => {
    const toolResults = [
      {
        tool_call_id: "1",
        name: "shell_cmd",
        arguments: { command: "ls" },
        content: "x",
        is_error: false,
      },
    ];

    render(<ToolResults toolResults={toolResults} />);

    expect(screen.getByText(/"command"/)).toBeInTheDocument();
    expect(screen.getByText(/"ls"/)).toBeInTheDocument();
  });

  it("does not render content body when content is empty", () => {
    const toolResults = [
      {
        tool_call_id: "1",
        name: "shell_cmd",
        content: "",
        is_error: false,
      },
    ];

    const { container } = render(<ToolResults toolResults={toolResults} />);

    // The tool name is rendered, but the empty content is not.
    expect(screen.getByText(/Success: shell_cmd/)).toBeInTheDocument();
    expect(container.querySelector("pre")).toBeNull();
  });
});
