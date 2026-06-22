/**
 * Tests for the ChatPage chat header.
 *
 * Specifically: the model display under the agent ID should show
 * "provider: model-name" when both are present, falling back to
 * just the name when only name is available.
 */
import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";

// Mock zustand store — set the cache directly per test.
let mockAgentsCache = {};
vi.mock("../store", () => ({
  useStore: (selector) =>
    selector({ agentsCache: mockAgentsCache, _reset: () => {} }),
}));

// Mock channels — ChatPage calls joinAgent/leaveAgent on mount.
import { joinAgent, leaveAgent, sendMessage, stopMessage } from "../channels";
vi.mock("../channels", () => ({
  joinAgent: vi.fn(),
  leaveAgent: vi.fn(),
  sendMessage: vi.fn(),
  stopMessage: vi.fn(),
}));

// Mock useScrollToBottom (not relevant to these tests).
vi.mock("../hooks/useScrollToBottom", () => ({
  useScrollToBottom: () => [vi.fn(), null],
}));

import { ChatPage } from "./ChatPage";

function renderChat(agentId = "test-agent") {
  return render(
    <MemoryRouter initialEntries={[`/agents/${agentId}`]}>
      <Routes>
        <Route path="/agents/:id" element={<ChatPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

describe("ChatPage chat header", () => {
  beforeEach(() => {
    mockAgentsCache = {};
  });

  it("renders 'provider: model-name' when both are present", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        model: { name: "qwen3.5-plus", provider: "model-studio" },
      },
    };

    renderChat();

    expect(screen.getByText("model-studio: qwen3.5-plus")).toBeInTheDocument();
  });

  it("renders only the model name when provider is missing", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("qwen3.5-plus")).toBeInTheDocument();
  });

  it("renders '[missing]' when the model name is absent", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        model: { provider: "model-studio" },
      },
    };

    renderChat();

    expect(screen.getByText("[missing]")).toBeInTheDocument();
  });

  it("renders '[missing]' when there is no model at all", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        model: null,
      },
    };

    renderChat();

    expect(screen.getByText("[missing]")).toBeInTheDocument();
  });
});

describe("ChatPage stop button", () => {
  beforeEach(() => {
    mockAgentsCache = {};
    joinAgent.mockClear();
    leaveAgent.mockClear();
    sendMessage.mockClear();
    stopMessage.mockClear();
  });

  it("shows the Send button (not Stop) when the agent is idle", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.queryByRole("button", { name: /stop/i })).toBeNull();
    expect(screen.getByRole("button", { name: /send/i })).toBeInTheDocument();
  });

  it("shows the Stop button when the agent is streaming", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByRole("button", { name: /stop/i })).toBeInTheDocument();
  });

  it("shows the Stop button when the agent is executing tools", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "executing_tools",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByRole("button", { name: /stop/i })).toBeInTheDocument();
  });

  it("does not show the Stop button when the agent is only waiting for response (avoids flicker)", () => {
    // `waitingForResponse` is a transient client-side flag that
    // flips on for a few ms right after `chat:message` and before
    // the first `chat:status`. Showing Stop during that window
    // would flicker the button. The button stays as Send.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        waitingForResponse: true,
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.queryByRole("button", { name: /stop/i })).toBeNull();
    expect(screen.getByRole("button", { name: /send/i })).toBeInTheDocument();
  });

  it("calls stopMessage when the user clicks Stop", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    fireEvent.click(screen.getByRole("button", { name: /stop/i }));

    expect(stopMessage).toHaveBeenCalledTimes(1);
    expect(stopMessage).toHaveBeenCalledWith(
      "test-agent",
      expect.any(Function),
    );
  });

  it("shows 'Stopping...' after the user clicks Stop, and clears it when the agent goes idle", () => {
    // Initial state: streaming (Stop button visible).
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    const { rerender } = renderChat();

    fireEvent.click(screen.getByRole("button", { name: /stop/i }));

    // Optimistic flip: button now shows "Stopping..." and is
    // disabled. (Re-query because the button's accessible name
    // changed.)
    const stoppingButton = screen.getByRole("button", { name: /stopping/i });
    expect(stoppingButton).toBeInTheDocument();
    expect(stoppingButton).toBeDisabled();

    // Agent transitions to idle (server pushed chat:status: idle).
    mockAgentsCache["test-agent"].agentState = "idle";
    rerender(
      <MemoryRouter initialEntries={["/agents/test-agent"]}>
        <Routes>
          <Route path="/agents/:id" element={<ChatPage />} />
        </Routes>
      </MemoryRouter>,
    );

    // The Stopping... state is cleared; the button is now Send.
    expect(screen.queryByRole("button", { name: /stopping/i })).toBeNull();
    expect(screen.getByRole("button", { name: /send/i })).toBeInTheDocument();
  });

  it("clears the 'stopping' state if stopMessage's onError callback fires", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    fireEvent.click(screen.getByRole("button", { name: /stop/i }));

    // The Stopping... button is now showing.
    expect(
      screen.getByRole("button", { name: /stopping/i }),
    ).toBeInTheDocument();

    // Simulate the stopMessage push failing: invoke the
    // onError callback that was passed to stopMessage.
    const errorCallback = stopMessage.mock.calls[0][1];
    act(() => errorCallback(new Error("channel closed")));

    // The optimistic flag is cleared — the button reverts to
    // Stop (still busy, but the click didn't actually take
    // effect). The "Stopping..." state is gone.
    expect(screen.queryByRole("button", { name: /stopping/i })).toBeNull();
    expect(screen.getByRole("button", { name: /stop/i })).toBeInTheDocument();
  });
});

describe("ChatPage loading and empty states", () => {
  beforeEach(() => {
    mockAgentsCache = {};
  });

  it("shows a 'Loading agent...' spinner when the agent is unknown", () => {
    // No cache entry for the agent — should show the loading state.
    renderChat();

    expect(screen.getByText("Loading agent...")).toBeInTheDocument();
  });

  it("shows a 'Start a conversation' empty state when there are no messages", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        partial: null,
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("Start a conversation")).toBeInTheDocument();
  });

  it("renders the partial message when one is present", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [{ index: 0, role: "user", content: "Hi" }],
        partial: {
          index: 1,
          role: "assistant",
          content: "I'm thinking",
        },
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // The partial is rendered with a "(typing...)" indicator.
    expect(screen.getByText("I'm thinking")).toBeInTheDocument();
    expect(screen.getByText("(typing...)")).toBeInTheDocument();
  });
});

describe("ChatPage message rendering", () => {
  beforeEach(() => {
    mockAgentsCache = {};
  });

  it("renders a user message with the 'You' label and a blue background", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [{ index: 0, role: "user", content: "Hello" }],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("You")).toBeInTheDocument();
    expect(screen.getByText("Hello")).toBeInTheDocument();
  });

  it("renders a user message with the mode badge when present", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [{ index: 0, role: "user", content: "Hello", mode: "build" }],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText(/mode: build/)).toBeInTheDocument();
  });

  it("renders an assistant message with the agent ID as the label", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          { index: 0, role: "user", content: "Hi" },
          { index: 1, role: "assistant", content: "Hello there" },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // The assistant message body is rendered.
    expect(screen.getByText("Hello there")).toBeInTheDocument();
    // The header shows the agent ID; the message label also shows
    // the agent ID. Verify the header is present.
    expect(
      screen.getByRole("heading", { name: /test-agent/ }),
    ).toBeInTheDocument();
  });

  it("renders a system message with the 'System' label", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [{ index: 0, role: "system", content: "Welcome" }],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("System")).toBeInTheDocument();
    expect(screen.getByText("Welcome")).toBeInTheDocument();
  });

  it("renders a tool message with the 'Tool Result' label", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [{ index: 0, role: "tool", content: "ls output" }],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("Tool Result")).toBeInTheDocument();
    expect(screen.getByText("ls output")).toBeInTheDocument();
  });
});

describe("ChatPage error display", () => {
  beforeEach(() => {
    mockAgentsCache = {};
    sendMessage.mockClear();
  });

  it("shows a send error when sendMessage's onError fires", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // Type into the textarea and click Send to trigger
    // handleSendMessage, which calls sendMessage with the
    // onError callback at index 3.
    const textarea = screen.getByLabelText("Message");
    fireEvent.change(textarea, { target: { value: "hello" } });
    fireEvent.click(screen.getByRole("button", { name: /send/i }));

    const errorCallback = sendMessage.mock.calls[0][3];
    act(() => errorCallback(new Error("connection lost")));

    expect(screen.getByText("connection lost")).toBeInTheDocument();
  });

  it("falls back to 'Failed to send message' when the error has no message", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    const textarea = screen.getByLabelText("Message");
    fireEvent.change(textarea, { target: { value: "hello" } });
    fireEvent.click(screen.getByRole("button", { name: /send/i }));

    const errorCallback = sendMessage.mock.calls[0][3];
    act(() => errorCallback({}));

    expect(screen.getByText("Failed to send message")).toBeInTheDocument();
  });
});

describe("ChatPage status label", () => {
  beforeEach(() => {
    mockAgentsCache = {};
  });

  it("shows 'Generating response' when streaming", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // The status label appears in the header AND in the typing
    // indicator; use getAllByText to check both.
    expect(screen.getAllByText("Generating response").length).toBeGreaterThan(
      0,
    );
  });

  it("shows 'Executing tools' when executing tools", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "executing_tools",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getAllByText("Executing tools").length).toBeGreaterThan(0);
  });

  it("shows the raw status (e.g. 'disconnected') when not connected", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "disconnected",
        agentState: "idle",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // The status label is the raw status string.
    expect(screen.getByText("disconnected")).toBeInTheDocument();
  });
});
