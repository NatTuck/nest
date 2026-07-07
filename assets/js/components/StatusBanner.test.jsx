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

  it("renders a compacting spinner with no Retry button", () => {
    const onRetryCompaction = vi.fn();

    const { container } = render(
      <StatusBanner
        status="compacting"
        onRetry={() => {}}
        onRetryCompaction={onRetryCompaction}
      />,
    );

    expect(screen.getByText("Compacting conversation...")).toBeInTheDocument();
    // The compacting banner is informational — no button.
    expect(container.querySelector("button")).toBeNull();
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
});
