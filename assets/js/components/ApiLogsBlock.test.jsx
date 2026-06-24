/**
 * ApiLogsBlock component tests.
 *
 * Covers: null/empty apiLogs, collapsed-by-default, the count
 * label, expand/collapse, the JSON-formatted payload dump, and the
 * "Copy as JSON" button (clicks trigger the right clipboard text
 * and toggle the copy → check icon feedback).
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { ApiLogsBlock } from "./ApiLogsBlock";

describe("ApiLogsBlock", () => {
  let writeText;

  beforeEach(() => {
    // jsdom doesn't ship `navigator.clipboard`; install a mock so
    // the CopyButton's `copyToClipboard` resolves successfully.
    writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText },
      configurable: true,
      writable: true,
    });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("returns null when apiLogs is undefined", () => {
    const { container } = render(<ApiLogsBlock apiLogs={undefined} />);
    expect(container.firstChild).toBeNull();
  });

  it("returns null when apiLogs is empty", () => {
    const { container } = render(<ApiLogsBlock apiLogs={[]} />);
    expect(container.firstChild).toBeNull();
  });

  it("renders the count label and hides payloads by default", () => {
    const apiLogs = [
      {
        id: "log_1",
        timestamp: "2024-01-01T00:00:00Z",
        type: "request",
        payload: { model: "qwen", messages: [] },
      },
    ];

    render(<ApiLogsBlock apiLogs={apiLogs} />);

    expect(screen.getByText("API Logs (1)")).toBeInTheDocument();
    expect(screen.queryByText(/"model"/)).toBeNull();
  });

  it("expands to show the JSON-formatted payload on click", () => {
    const apiLogs = [
      {
        id: "log_1",
        timestamp: "2024-01-01T00:00:00Z",
        type: "request",
        payload: { model: "qwen", messages: ["hi"] },
      },
    ];

    render(<ApiLogsBlock apiLogs={apiLogs} />);

    fireEvent.click(screen.getByRole("button", { name: /toggle api logs/i }));

    expect(screen.getByText(/"model"/)).toBeInTheDocument();
    expect(screen.getByText(/"qwen"/)).toBeInTheDocument();
  });

  it("collapses the payloads on a second click", () => {
    const apiLogs = [
      {
        id: "log_1",
        timestamp: "2024-01-01T00:00:00Z",
        type: "request",
        payload: { model: "qwen" },
      },
    ];

    render(<ApiLogsBlock apiLogs={apiLogs} />);

    const toggleButton = screen.getByRole("button", {
      name: /toggle api logs/i,
    });
    fireEvent.click(toggleButton);
    expect(screen.getByText(/"model"/)).toBeInTheDocument();

    fireEvent.click(toggleButton);
    expect(screen.queryByText(/"model"/)).toBeNull();
  });

  it("renders a 'Copy API logs' button next to the count", () => {
    const apiLogs = [
      {
        id: "log_1",
        timestamp: "2024-01-01T00:00:00Z",
        type: "request",
        payload: { model: "qwen" },
      },
    ];

    render(<ApiLogsBlock apiLogs={apiLogs} />);

    expect(
      screen.getByRole("button", { name: /copy api logs/i }),
    ).toBeInTheDocument();
  });

  it("clicking the copy button writes the JSON dump of every payload to the clipboard", async () => {
    const apiLogs = [
      {
        id: "log_1",
        timestamp: "2024-01-01T00:00:00Z",
        type: "request",
        payload: { model: "qwen", messages: ["hi"] },
      },
      {
        id: "log_2",
        timestamp: "2024-01-01T00:00:01Z",
        type: "response",
        payload: { id: "resp_1", content: "ok" },
      },
    ];

    render(<ApiLogsBlock apiLogs={apiLogs} />);

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /copy api logs/i }));
    });

    expect(writeText).toHaveBeenCalledTimes(1);
    const written = writeText.mock.calls[0][0];
    // Each payload is JSON.stringify(payload, null, 2); the two
    // are joined with a blank line. Verify both payloads appear
    // and the format is the indented dump the user sees in the
    // expanded <pre> blocks.
    expect(written).toContain('"model": "qwen"');
    expect(written).toContain('"id": "resp_1"');
    expect(written.split("\n").length).toBeGreaterThan(2);
  });

  it("the copy button's label flips to 'Copied' after a successful click and reverts after the feedback window", async () => {
    vi.useFakeTimers();
    const apiLogs = [
      {
        id: "log_1",
        timestamp: "2024-01-01T00:00:00Z",
        type: "request",
        payload: { model: "qwen" },
      },
    ];

    render(<ApiLogsBlock apiLogs={apiLogs} />);

    const copyButton = screen.getByRole("button", {
      name: /copy api logs/i,
    });
    await act(async () => {
      fireEvent.click(copyButton);
    });

    expect(screen.getByRole("button", { name: /copied/i })).toBeInTheDocument();

    await act(async () => {
      vi.advanceTimersByTime(2000);
    });
    expect(
      screen.getByRole("button", { name: /copy api logs/i }),
    ).toBeInTheDocument();
  });
});
