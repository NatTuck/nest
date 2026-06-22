/**
 * ApiLogsBlock component tests.
 *
 * Covers: null/empty apiLogs, collapsed-by-default, the count
 * label, expand/collapse, and the JSON-formatted payload dump.
 */
import { describe, it, expect } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ApiLogsBlock } from "./ApiLogsBlock";

describe("ApiLogsBlock", () => {
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

    fireEvent.click(screen.getByRole("button", { name: /api logs/i }));

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

    const toggleButton = screen.getByRole("button", { name: /api logs/i });
    fireEvent.click(toggleButton);
    expect(screen.getByText(/"model"/)).toBeInTheDocument();

    fireEvent.click(toggleButton);
    expect(screen.queryByText(/"model"/)).toBeNull();
  });
});
