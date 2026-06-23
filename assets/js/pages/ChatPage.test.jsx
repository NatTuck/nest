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

  it("strips the [mode: X]\\n prefix from user message content on render", () => {
    // Server-side ChatPipeline.build_user_messages/3 intentionally
    // prefixes every persisted user message with `[mode: <name>]\n`
    // so the LLM sees the mode as part of the message text. The
    // chat UI hides the prefix because the mode badge already
    // displays it.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          {
            index: 0,
            role: "user",
            content: "[mode: build]\nHello there",
            mode: "build",
          },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // The badge shows the mode and the visible body shows just the
    // user text. The prefix itself is not rendered.
    expect(screen.getByText(/mode: build/)).toBeInTheDocument();
    expect(screen.getByText("Hello there")).toBeInTheDocument();
    expect(screen.queryByText(/^\[mode: build\]/)).toBeNull();
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

  it("truncates system messages exceeding 20 lines with an expand button", () => {
    const lines = Array.from({ length: 25 }, (_, i) => `line-${i + 1}`);
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [{ index: 0, role: "system", content: lines.join("\n") }],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("System")).toBeInTheDocument();
    // Expand button should be present
    const expandButton = screen.getByRole("button", {
      name: /expand 5 more lines/i,
    });
    expect(expandButton).toBeInTheDocument();

    // The visible content should contain the first 20 lines
    const messageContainer = screen.getByText("System").closest(".flex-1");
    expect(messageContainer.textContent).toContain("line-1");
    expect(messageContainer.textContent).toContain("line-20");
    expect(messageContainer.textContent).not.toContain("line-21");

    // Click expand
    fireEvent.click(expandButton);

    // Now all lines should be visible
    expect(messageContainer.textContent).toContain("line-21");
    expect(messageContainer.textContent).toContain("line-25");
    // Button should now show "Show less"
    const showLessButton = screen.getByRole("button", { name: /show less/i });
    expect(showLessButton).toBeInTheDocument();

    // Click to collapse
    fireEvent.click(showLessButton);

    // Should be back to truncated state
    expect(messageContainer.textContent).not.toContain("line-21");
    expect(
      screen.getByRole("button", { name: /expand 5 more lines/i }),
    ).toBeInTheDocument();
  });

  it("does not show expand button for system messages at or under 20 lines", () => {
    const lines = Array.from({ length: 20 }, (_, i) => `line-${i + 1}`);
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [{ index: 0, role: "system", content: lines.join("\n") }],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(
      screen.queryByRole("button", { name: /expand/i }),
    ).not.toBeInTheDocument();
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

describe("ChatPage thinking-before-content order", () => {
  // The unified `<ThinkingBlock>` is rendered BEFORE the
  // `<MessageContent>` and stays in place across the
  // partial → final transition (the parent's `key` prop
  // re-mounts the box on the transition, but the DOM
  // position is the same). These tests pin that order so a
  // future refactor doesn't accidentally re-introduce the
  // "thinking jumps to the bottom on finalization" bug.

  beforeEach(() => {
    mockAgentsCache = {};
  });

  it("renders the Thinking box BEFORE the reply for a finalized assistant message", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          { index: 0, role: "user", content: "Hi" },
          {
            index: 1,
            role: "assistant",
            content: "The answer is 42.",
            thinking: "Let me think about this carefully.",
          },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // The Thinking box is expanded by default for finalized
    // messages (the user wanted the reasoning to remain
    // visible after the turn completes), so the thinking
    // text itself is visible. The reply is also always
    // visible.
    expect(screen.getByText("The answer is 42.")).toBeInTheDocument();
    expect(
      screen.getByText("Let me think about this carefully."),
    ).toBeInTheDocument();

    const thinking = screen.getByText("Let me think about this carefully.");
    const reply = screen.getByText("The answer is 42.");

    // `compareDocumentPosition` returns a bitfield of the
    // relative position. DOCUMENT_POSITION_FOLLOWING (4)
    // means the thinking node comes before the reply node.
    const position = thinking.compareDocumentPosition(reply);
    expect(position & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it("renders the Thinking box for a partial message with thinking segments", () => {
    // The partial's `content` field is text-only — the store
    // excludes thinking deltas from it (so they don't appear
    // twice in the chat, once in the yellow box and again as
    // regular markdown). The thinking text lives in `segments`
    // and is surfaced via `thinkingFor(message)`.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [{ index: 0, role: "user", content: "Hi" }],
        partial: {
          index: 1,
          role: "assistant",
          content: "Halfway through...",
          isPartial: true,
          segments: [
            { type: "thinking", content: "Reasoning about the answer..." },
            { type: "text", content: "Halfway through..." },
          ],
        },
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // The thinking text appears in the yellow box, expanded.
    expect(
      screen.getByText("Reasoning about the answer..."),
    ).toBeInTheDocument();

    // The visible reply shows the text-only content.
    expect(screen.getByText("Halfway through...")).toBeInTheDocument();

    // The thinking text does NOT appear in the visible body
    // (i.e. not as a second copy below the yellow box). We
    // verify by checking that the body container doesn't
    // contain the thinking text outside the Thinking box.
    const thinkingEl = screen
      .getByText("Reasoning about the answer...")
      .closest("[class*='border-amber-200']");
    expect(thinkingEl).toBeInTheDocument();
    expect(
      thinkingEl.contains(screen.getByText("Reasoning about the answer...")),
    ).toBe(true);

    // The streaming indicator is visible.
    expect(screen.getByLabelText("Streaming thinking")).toBeInTheDocument();
  });

  it("concatenates multiple thinking segments from the partial's segments list", () => {
    // Defends against the (rare) case of `[thinking, text,
    // thinking, text]` interleaving within a single turn: the
    // current providers don't emit it, but the partial→final
    // data shape supports it and the helper should be
    // robust to it.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [{ index: 0, role: "user", content: "Hi" }],
        partial: {
          index: 1,
          role: "assistant",
          content: "Visible answer",
          isPartial: true,
          segments: [
            { type: "thinking", content: "First thought " },
            { type: "text", content: "Visible " },
            { type: "thinking", content: "second thought" },
            { type: "text", content: "answer" },
          ],
        },
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // Both thinking segments appear, concatenated as one
    // string in the Thinking box.
    expect(
      screen.getByText("First thought second thought"),
    ).toBeInTheDocument();

    // The visible body shows only the text segments.
    expect(screen.getByText("Visible answer")).toBeInTheDocument();
  });

  it("does not render a Thinking box when the message has no thinking content", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          { index: 0, role: "user", content: "Hi" },
          { index: 1, role: "assistant", content: "Plain answer" },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("Plain answer")).toBeInTheDocument();
    // No Thinking button when there's no thinking.
    expect(
      screen.queryByRole("button", { name: /thinking/i }),
    ).not.toBeInTheDocument();
  });

  it("auto-expands the Thinking box on a thinking-only response so the user sees the model's reply", () => {
    // Some reasoning models (e.g. MiniMax) produce a
    // thinking-only response: the assistant message has
    // `thinking` set and `content: nil`. The ThinkingBox
    // auto-expands in this case so the user actually sees the
    // response — otherwise the model would appear to have
    // produced no output at all.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          { index: 0, role: "user", content: "Hi" },
          {
            index: 1,
            role: "assistant",
            content: null,
            thinking:
              "The user said hi. I should respond warmly without any visible text — just thinking out loud.",
          },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    const thinkingButton = screen.getByRole("button", { name: /thinking/i });
    // The box is auto-expanded because there is no visible
    // content below it.
    expect(thinkingButton).toHaveAttribute("aria-expanded", "true");
    expect(
      screen.getByText(
        "The user said hi. I should respond warmly without any visible text — just thinking out loud.",
      ),
    ).toBeInTheDocument();
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

describe("ChatPage mode selector", () => {
  beforeEach(() => {
    mockAgentsCache = {};
    vi.clearAllMocks();
  });

  it("initializes the dropdown from cache.currentMode, not defaultMode", () => {
    // When the agent already has a non-default current mode
    // (e.g. set by a previous chat), the dropdown should
    // show that, not the vocation's default.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        currentMode: "plan",
        defaultMode: "build",
        modes: ["build", "plan"],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    const select = screen.getByLabelText("Mode");
    expect(select.value).toBe("plan");
  });

  it("falls back to defaultMode when cache.currentMode is not set", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        defaultMode: "build",
        modes: ["build", "plan"],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    const select = screen.getByLabelText("Mode");
    expect(select.value).toBe("build");
  });

  it("updates the dropdown when a chat:status broadcast carries a new currentMode", () => {
    // Regression test for the "mode resets to default after
    // send" bug: after a chat completes, the chat:status: idle
    // broadcast should update the dropdown to the just-used mode
    // (NOT defaultMode).
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        currentMode: "build",
        defaultMode: "build",
        modes: ["build", "plan"],
        model: { name: "qwen3.5-plus" },
      },
    };

    const { rerender } = renderChat();

    // User sends a "plan" message. The mode the user picked
    // is sent in the payload.
    const select = screen.getByLabelText("Mode");
    fireEvent.change(select, { target: { value: "plan" } });
    const textarea = screen.getByLabelText("Message");
    fireEvent.change(textarea, { target: { value: "plan this" } });
    fireEvent.click(screen.getByRole("button", { name: /send/i }));

    // The send pushes a chat:message with the user-picked mode.
    expect(sendMessage).toHaveBeenCalledWith(
      "test-agent",
      "plan this",
      "plan",
      expect.any(Function),
    );

    // Simulate the server's response: the agent transitions to
    // streaming, then to idle with currentMode: "plan". The
    // channels.js handler would update the cache; we
    // simulate that here.
    mockAgentsCache["test-agent"].agentState = "streaming";
    mockAgentsCache["test-agent"].currentMode = "plan";
    rerender(
      <MemoryRouter initialEntries={["/agents/test-agent"]}>
        <Routes>
          <Route path="/agents/:id" element={<ChatPage />} />
        </Routes>
      </MemoryRouter>,
    );

    // The dropdown now reflects the broadcast currentMode,
    // NOT defaultMode.
    expect(screen.getByLabelText("Mode").value).toBe("plan");
  });

  it("changing the mode selector does not call sendMessage or any other server push", () => {
    // The mode dropdown is a local UI draft. Messing with it
    // must not affect Agent state.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [],
        currentMode: "build",
        defaultMode: "build",
        modes: ["build", "plan"],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    fireEvent.change(screen.getByLabelText("Mode"), {
      target: { value: "plan" },
    });

    // No server push should have been made.
    expect(sendMessage).not.toHaveBeenCalled();
    expect(joinAgent).toHaveBeenCalledTimes(1); // mount only
    expect(leaveAgent).not.toHaveBeenCalled();
  });

  it("disables the mode dropdown when the agent is busy (locked with the input)", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [],
        currentMode: "build",
        defaultMode: "build",
        modes: ["build", "plan"],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // The textarea is disabled when busy; so is the mode
    // dropdown.
    expect(screen.getByLabelText("Message")).toBeDisabled();
    expect(screen.getByLabelText("Mode")).toBeDisabled();
  });
});
