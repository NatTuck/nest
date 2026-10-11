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
        name: "shell-cmd",
        content: "total 4\ndrwxrwxr-x 1 user user 18 May 29 10:49 .",
        is_error: false,
      },
    ];

    render(<ToolResults toolResults={toolResults} />);

    expect(screen.getByText(/Success: shell-cmd/)).toBeInTheDocument();
  });

  it("renders 'Backgrounded: <name>' for a result whose call is still running", () => {
    // The machine's synthetic answer to a call it moved to the background has
    // `is_error: false` and no result yet. Badging it "Success" would assert
    // something the data does not support, so the result's own state wins.
    const toolResults = [
      {
        tool_call_id: "1",
        name: "shell-cmd",
        content: "The shell-cmd call was moved to the background.",
        is_error: false,
        state: "backgrounded",
      },
    ];

    render(<ToolResults toolResults={toolResults} />);

    expect(screen.getByText(/Backgrounded: shell-cmd/)).toBeInTheDocument();
    expect(screen.queryByText(/Success: shell-cmd/)).toBeNull();
    expect(screen.queryByText(/Error: shell-cmd/)).toBeNull();
  });

  it("renders an unknown state verbatim rather than a verdict", () => {
    // A state this build cannot interpret is data, not an absent field: it must
    // be shown as unknown instead of quietly reading as a success or a failure.
    const toolResults = [
      {
        tool_call_id: "1",
        name: "shell-cmd",
        content: "x",
        is_error: false,
        state: "something-new",
      },
    ];

    render(<ToolResults toolResults={toolResults} />);

    expect(
      screen.getByText(/Unknown state \(something-new\): shell-cmd/),
    ).toBeInTheDocument();
    expect(screen.queryByText(/Success: shell-cmd/)).toBeNull();
  });

  it("renders 'Error: <name>' for error results", () => {
    const toolResults = [
      {
        tool_call_id: "1",
        name: "shell-cmd",
        content: "command not found",
        is_error: true,
      },
    ];

    render(<ToolResults toolResults={toolResults} />);

    expect(screen.getByText(/Error: shell-cmd/)).toBeInTheDocument();
  });

  it("renders the content body for each result", () => {
    const toolResults = [
      {
        tool_call_id: "1",
        name: "shell-cmd",
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
        name: "shell-cmd",
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
        name: "shell-cmd",
        content: "",
        is_error: false,
      },
    ];

    const { container } = render(<ToolResults toolResults={toolResults} />);

    // The tool name is rendered, but the empty content is not.
    expect(screen.getByText(/Success: shell-cmd/)).toBeInTheDocument();
    expect(container.querySelector("pre")).toBeNull();
  });
});
