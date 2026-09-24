/**
 * ApiLogsBlock component tests.
 *
 * Covers: null/empty apiLogs, collapsed-by-default, the count
 * label, expand/collapse, the JSON-formatted payload dump, and the
 * "Copy as JSON" button (clicks trigger the right clipboard text
 * and toggle the copy → check icon feedback).
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import {
  render,
  screen,
  fireEvent,
  act,
  waitFor,
} from "@testing-library/react";
import { ApiLogsBlock } from "./ApiLogsBlock";

const { mockAgentChannels } = vi.hoisted(() => ({
  mockAgentChannels: new Map(),
}));

vi.mock("../channels/state", () => ({
  agentChannels: mockAgentChannels,
}));

// A minimal Phoenix channel stub whose `push` and `receive` both
// return the channel itself, so the `.receive("ok", …).receive("error", …)`
// chain wires up correctly. `handlers` maps a status to the callback body.
function stubChannel(handlers) {
  const channel = {
    push: vi.fn(() => channel),
    receive: vi.fn((status, cb) => {
      handlers[status]?.(cb);
      return channel;
    }),
  };
  return channel;
}

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

  it("returns null when apiLogs is undefined and no agentName", () => {
    const { container } = render(<ApiLogsBlock apiLogs={undefined} />);
    expect(container.firstChild).toBeNull();
  });

  it("returns null when apiLogs is empty and no agentName", () => {
    const { container } = render(<ApiLogsBlock apiLogs={[]} />);
    expect(container.firstChild).toBeNull();
  });

  it("shows an error indicator (not null) for an assistant message with no response log", () => {
    render(
      <ApiLogsBlock
        apiLogs={[]}
        agentName="test-agent"
        index={5}
        messageRole="assistant"
      />,
    );

    expect(
      screen.getByText(/API response log missing — not recorded/i),
    ).toBeInTheDocument();
  });

  it("returns null for a system message with no logs (logs never expected by design)", () => {
    const { container } = render(
      <ApiLogsBlock apiLogs={[]} messageRole="system" />,
    );

    expect(container.firstChild).toBeNull();
  });

  it("shows an error indicator for a user message whose request log can't be fetched (archive)", () => {
    render(<ApiLogsBlock apiLogs={[]} messageRole="user" />);

    expect(
      screen.getByText(/API request log unavailable/i),
    ).toBeInTheDocument();
  });

  it("shows a load button for a user message with no apiLogs", () => {
    render(
      <ApiLogsBlock
        apiLogs={[]}
        agentName="test-agent"
        index={1}
        messageRole="user"
      />,
    );

    expect(
      screen.getByRole("button", { name: /load api logs/i }),
    ).toBeInTheDocument();
  });

  it("shows loading indicator and fetches api logs on click", async () => {
    const channel = stubChannel({
      ok: (cb) =>
        cb({
          apiLogs: [
            {
              id: "001.000",
              type: "request",
              payload: { model: "test" },
              timestamp: "2024-01-01T00:00:00Z",
            },
          ],
        }),
    });

    mockAgentChannels.clear();
    mockAgentChannels.set("test-agent", channel);

    render(
      <ApiLogsBlock
        apiLogs={null}
        agentName="test-agent"
        index={1}
        messageRole="user"
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /load api logs/i }));

    expect(channel.push).toHaveBeenCalledWith("chat:api-logs", { index: 1 });
    // After fetch completes, the button text updates with the log count
    await waitFor(() => {
      expect(screen.getByText("API Logs (1)")).toBeInTheDocument();
    });
  });

  it("shows an error indicator with Retry when the request-log fetch errors", async () => {
    const channel = stubChannel({
      error: (cb) => cb({ reason: "no_logs" }),
    });

    mockAgentChannels.clear();
    mockAgentChannels.set("test-agent", channel);

    render(
      <ApiLogsBlock
        apiLogs={null}
        agentName="test-agent"
        index={1}
        messageRole="user"
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /load api logs/i }));

    await screen.findByText(/API logs unavailable \(no_logs\)/i);
    expect(screen.getByRole("button", { name: /retry/i })).toBeInTheDocument();
  });

  it("shows an error indicator when the request-log fetch returns no logs", async () => {
    const channel = stubChannel({
      ok: (cb) => cb({ apiLogs: [] }),
    });

    mockAgentChannels.clear();
    mockAgentChannels.set("test-agent", channel);

    render(
      <ApiLogsBlock
        apiLogs={null}
        agentName="test-agent"
        index={1}
        messageRole="user"
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /load api logs/i }));

    await screen.findByText(/API request log unavailable/i);
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
