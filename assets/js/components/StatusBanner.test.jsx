/**
 * StatusBanner component tests.
 *
 * Covers: the four statuses (connecting, error, disconnected,
 * connected/other) and the Retry / Reconnect button callbacks.
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { StatusBanner } from "./StatusBanner";

describe("StatusBanner", () => {
  it("renders a connecting spinner", () => {
    render(<StatusBanner status="connecting" onRetry={() => {}} />);

    expect(screen.getByText("Connecting to agent...")).toBeInTheDocument();
  });

  it("renders the error message and a Retry button that calls onRetry", () => {
    const onRetry = vi.fn();

    render(
      <StatusBanner
        status="error"
        error="Connection refused"
        onRetry={onRetry}
      />,
    );

    expect(screen.getByText("Connection failed")).toBeInTheDocument();
    expect(screen.getByText("Connection refused")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /retry/i }));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it("falls back to 'Unknown error' when error is not provided", () => {
    render(<StatusBanner status="error" onRetry={() => {}} />);

    expect(screen.getByText("Unknown error")).toBeInTheDocument();
  });

  it("renders a disconnected banner with a Reconnect button", () => {
    const onRetry = vi.fn();

    render(<StatusBanner status="disconnected" onRetry={onRetry} />);

    expect(
      screen.getByText("Disconnected. Connection lost."),
    ).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /reconnect/i }));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });

  it("renders nothing for the connected status", () => {
    const { container } = render(
      <StatusBanner status="connected" onRetry={() => {}} />,
    );

    expect(container.firstChild).toBeNull();
  });

  it("renders nothing for :compacting (compaction attempt is visible in the chat pane itself)", () => {
    const onRetryCompaction = vi.fn();

    const { container } = render(
      <StatusBanner
        status="compacting"
        onRetry={() => {}}
        onRetryCompaction={onRetryCompaction}
      />,
    );

    // No banner during compaction. The agent records the
    // suffix + a synthetic assistant message in the message
    // list, and the user can watch the chat pane while the
    // LLM call runs.
    expect(container.firstChild).toBeNull();
  });

  it("renders a compaction_failed banner with a Retry-compaction button", () => {
    const onRetryCompaction = vi.fn();

    render(
      <StatusBanner
        status="compaction_failed"
        compactionError="LLM returned empty summary"
        onRetry={() => {}}
        onRetryCompaction={onRetryCompaction}
      />,
    );

    expect(screen.getByText("Compaction failed")).toBeInTheDocument();
    expect(screen.getByText("LLM returned empty summary")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /retry compaction/i }));
    expect(onRetryCompaction).toHaveBeenCalledTimes(1);
  });

  it("falls back to the default compaction_failed message when error is not provided", () => {
    render(
      <StatusBanner
        status="compaction_failed"
        onRetry={() => {}}
        onRetryCompaction={() => {}}
      />,
    );

    expect(screen.getByText("Click Retry to try again.")).toBeInTheDocument();
  });

  it("renders a context_overflow banner with the actual numbers and NO Retry button", () => {
    // Context overflow is a fundamentally-different failure mode
    // from compaction_failed: retrying will not help (the model
    // is too small for the system prompt). The banner must show
    // the actual numbers so the user can see why and instruct
    // them to switch models — but it must NOT render a Retry
    // button (which would be misleading).
    const onRetryCompaction = vi.fn();

    const overflowMessage =
      "Cannot start a conversation: model context limit (10000) cannot fit the system prompt (~8400 tokens) + reserved response budget (8192 tokens). Use a model with a larger context window, or clear conversation history.";

    const { container } = render(
      <StatusBanner
        status="context_overflow"
        error={overflowMessage}
        onRetry={() => {}}
        onRetryCompaction={onRetryCompaction}
      />,
    );

    expect(screen.getByText("Context too small")).toBeInTheDocument();
    expect(screen.getByText(overflowMessage)).toBeInTheDocument();

    // No Retry button — switching models is the only way forward.
    expect(container.querySelector("button")).toBeNull();
  });

  it("falls back to a default message for context_overflow when error is not provided", () => {
    render(
      <StatusBanner
        status="context_overflow"
        onRetry={() => {}}
        onRetryCompaction={() => {}}
      />,
    );

    expect(
      screen.getByText(/context window cannot fit even the system prompt/i),
    ).toBeInTheDocument();
  });

  it("renders a compaction_loop_detected banner with an OK button (no Retry)", () => {
    // The loop state is distinct from compaction_failed: the user
    // got the OK button instead of Retry because the loop-breaker
    // tripped (consecutive compactions without progress). Clicking
    // OK clears the loop state; the user then sends a new message.
    const onRetryCompaction = vi.fn();
    const onCompactionLoopOk = vi.fn();

    const { container } = render(
      <StatusBanner
        status="compaction_loop_detected"
        compactionLoop="compaction isn't reducing the conversation — start a new session, change model, or clear history"
        onRetry={() => {}}
        onRetryCompaction={onRetryCompaction}
        onCompactionLoopOk={onCompactionLoopOk}
      />,
    );

    expect(
      screen.getByText("Compaction isn't reducing context"),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/compaction isn't reducing the conversation/i),
    ).toBeInTheDocument();

    // OK button calls onCompactionLoopOk, not onRetryCompaction.
    const okButton = screen.getByRole("button", { name: /^ok$/i });
    expect(okButton).toBeInTheDocument();
    fireEvent.click(okButton);
    expect(onCompactionLoopOk).toHaveBeenCalledTimes(1);
    expect(onRetryCompaction).not.toHaveBeenCalled();

    // Only the OK button — no Retry / Reconnect.
    expect(container.querySelectorAll("button")).toHaveLength(1);
  });

  it("falls back to a default message for compaction_loop_detected when compactionLoop is not provided", () => {
    render(
      <StatusBanner
        status="compaction_loop_detected"
        onRetry={() => {}}
        onRetryCompaction={() => {}}
        onCompactionLoopOk={() => {}}
      />,
    );

    expect(
      screen.getByText(/Compaction is no longer reducing the conversation/i),
    ).toBeInTheDocument();
  });
});
