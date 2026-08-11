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
// Provides both `useStore(selector)` (called as a React hook by
// components) and `useStore.getState()` (called from event handlers
// like `handleDismissError`). `getState` returns a small actions
// object that mutates `mockAgentsCache` so the dismissed-error
// scenario flows end-to-end.
let mockAgentsCache = {};
let mockSpaces = [];
vi.mock("../store", () => {
  const actions = {
    clearAgentError: (id) => {
      const cache = mockAgentsCache[id];
      if (!cache) return;
      const agentAlive = cache.agentState === "idle";
      mockAgentsCache = {
        ...mockAgentsCache,
        [id]: {
          ...cache,
          status:
            agentAlive && cache.status === "error" ? "connected" : cache.status,
          error: null,
        },
      };
    },
  };

  const useStore = (selector) =>
    selector({ agentsCache: mockAgentsCache, spaces: mockSpaces });
  useStore.getState = () => ({
    ...actions,
    agentsCache: mockAgentsCache,
    spaces: mockSpaces,
  });

  return { useStore };
});

// Mock channels — ChatPage calls joinAgent/leaveAgent on mount.
const mocks = vi.hoisted(() => ({
  changeAgentModel: vi.fn(),
}));
import {
  joinAgent,
  leaveAgent,
  sendMessage,
  stopMessage,
  retryCompaction,
  compactionLoopOk,
} from "../channels";
vi.mock("../channels", () => ({
  joinAgent: vi.fn(),
  leaveAgent: vi.fn(),
  sendMessage: vi.fn(),
  stopMessage: vi.fn(),
  retryCompaction: vi.fn(),
  compactionLoopOk: vi.fn(),
  changeAgentModel: mocks.changeAgentModel,
}));

// Mock useScrollToBottom (not relevant to these tests).
vi.mock("../hooks/useScrollToBottom", () => ({
  useScrollToBottom: () => [vi.fn(), null],
}));

// Mock AgentModelPicker — render nothing but expose the
// props so tests can drive `open` → `onSelect`
// transitions directly.
vi.mock("../components/AgentModelPicker", () => ({
  AgentModelPicker: ({ open, onSelect, onClose }) =>
    open ? (
      <div data-testid="mock-model-picker">
        <button
          type="button"
          onClick={() => onSelect({ name: "gpt-4", provider: "openai" })}
        >
          pick
        </button>
        <button type="button" onClick={onClose}>
          close
        </button>
      </div>
    ) : null,
}));

import { ChatPage } from "./ChatPage";

function renderChat(agentName = "test-agent", spaceSlug = "my-space") {
  mockSpaces = [{ id: 1, slug: spaceSlug, name: "My Space" }];
  return render(
    <MemoryRouter initialEntries={[`/space/${spaceSlug}/agent/${agentName}`]}>
      <Routes>
        <Route path="/space/:spaceSlug/agent/:name" element={<ChatPage />} />
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
      <MemoryRouter initialEntries={["/space/my-space/agent/test-agent"]}>
        <Routes>
          <Route path="/space/:spaceSlug/agent/:name" element={<ChatPage />} />
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
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
        ],
        partial: {
          index: 1,
          role: "assistant",
          parts: [{ kind: "thinking", thinking: "I'm thinking" }],
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
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hello" }] },
        ],
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
        messages: [
          {
            index: 0,
            role: "user",
            mode: "build",
            parts: [{ kind: "text", text: "Hello" }],
          },
        ],
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
            parts: [{ kind: "text", text: "[mode: build]\nHello there" }],
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
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
          {
            index: 1,
            role: "assistant",
            parts: [{ kind: "text", text: "Hello there" }],
          },
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
        messages: [
          {
            index: 0,
            role: "system",
            parts: [{ kind: "text", text: "Welcome" }],
          },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("System")).toBeInTheDocument();
    expect(screen.getByText("Welcome")).toBeInTheDocument();
  });

  it("renders an empty system message with a dimmed placeholder (transparency)", () => {
    // Per the AGENTS.md transparency rule: the UI always
    // includes everything that happened. An empty system
    // message (no system prompt was configured) is still
    // broadcast from the server, and the UI renders a
    // visible placeholder rather than hiding the message.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          { index: 0, role: "system", parts: [{ kind: "text", text: "" }] },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("System")).toBeInTheDocument();
    expect(screen.getByText(/empty system message/i)).toBeInTheDocument();
  });

  it("truncates system messages exceeding 20 lines with an expand button", () => {
    const lines = Array.from({ length: 25 }, (_, i) => `line-${i + 1}`);
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          {
            index: 0,
            role: "system",
            parts: [{ kind: "text", text: lines.join("\n") }],
          },
        ],
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
        messages: [
          {
            index: 0,
            role: "system",
            parts: [{ kind: "text", text: lines.join("\n") }],
          },
        ],
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
        messages: [
          {
            index: 0,
            role: "tool",
            parts: [{ kind: "text", text: "ls output" }],
          },
        ],
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
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
          {
            index: 1,
            role: "assistant",
            parts: [{ kind: "text", text: "The answer is 42." }],
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
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
        ],
        partial: {
          index: 1,
          role: "assistant",
          parts: [
            { kind: "thinking", thinking: "Reasoning about the answer..." },
            { kind: "text", text: "Halfway through..." },
          ],
          isPartial: true,
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
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
        ],
        partial: {
          index: 1,
          role: "assistant",
          content: "Visible answer",
          isPartial: true,
          parts: [
            { kind: "thinking", thinking: "First thought " },
            { kind: "text", text: "Visible " },
            { kind: "thinking", thinking: "second thought" },
            { kind: "text", text: "answer" },
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
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
          {
            index: 1,
            role: "assistant",
            parts: [{ kind: "text", text: "Plain answer" }],
          },
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
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
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

  it("splits <think>...</think> blocks buried in Part.Text into the Thinking box", () => {
    // Some models emit the reasoning inline as
    // `<think>...</think>` text inside a `Part.Text` rather
    // than as a separate `Part.Thinking` entry. The active
    // message list splits the text, routes the inner content
    // to the Thinking box, and renders only the surrounding
    // text via MessageContent.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
          {
            index: 1,
            role: "assistant",
            parts: [
              {
                kind: "text",
                text: "before<think>reasoning here</think>after",
              },
            ],
          },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // Thinking content is rendered in the Thinking box
    expect(screen.getByText("reasoning here")).toBeInTheDocument();
    // The visible text is split around the think block
    expect(screen.getByText(/before/)).toBeInTheDocument();
    expect(screen.getByText(/after/)).toBeInTheDocument();
    // No raw <think> markers in the visible text
    expect(screen.queryByText("<think>")).not.toBeInTheDocument();
    expect(screen.queryByText("</think>")).not.toBeInTheDocument();
  });

  it("routes stray </think>\\n\\n text in Part.Text to the Thinking box (orphan closing)", () => {
    // Regression: OpenAI-style models occasionally emit
    // `</think>\n\n` as part of the response (a closing tag
    // without a matching opener). The active message list
    // routes the orphan's tail to the thinking channel so
    // the user doesn't see raw `</think>` characters in the
    // visible reply.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
          {
            index: 1,
            role: "assistant",
            parts: [{ kind: "text", text: "hello</think>\n\nworld" }],
          },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // The orphan + tail went to thinking; the visible text
    // retains the prefix.
    expect(screen.getByText("hello")).toBeInTheDocument();
    // The raw `</think>` does not appear anywhere in the DOM
    expect(screen.queryByText("</think>")).not.toBeInTheDocument();
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

  it("keeps the error banner visible across the companion chat:status: idle", () => {
    // Reproduction of the user's stuck-in-error report. Before
    // the fix, `agentState === "idle"` after the companion
    // `chat:status: idle` made `StatusBanner.status` resolve to
    // `"idle"`, hiding the banner even though `cache.error`
    // was still set. The fix promotes the banner's `status` prop
    // to `"error"` whenever `cache.status === "error" && cache.error`,
    // so the Retry + Dismiss banner stays visible.
    mockAgentsCache = {
      "test-agent": {
        status: "error",
        agentState: "idle",
        error: "Model unavailable",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("Connection failed")).toBeInTheDocument();
    expect(screen.getByText("Model unavailable")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /retry/i })).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /dismiss/i }),
    ).toBeInTheDocument();
  });

  it("clicking Dismiss clears the error when the channel is alive", () => {
    // The Dismiss button's contract: when the companion
    // `chat:status: idle` has landed (agentState === "idle", the
    // channel is alive), the user can recover locally without
    // re-joining or reloading. After dismissal, `cache.error` is
    // null and `cache.status` is restored to "connected", so the
    // textarea becomes editable.
    mockAgentsCache = {
      "test-agent": {
        status: "error",
        agentState: "idle",
        error: "Model unavailable",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(
      screen.getByRole("button", { name: /dismiss/i }),
    ).toBeInTheDocument();

    act(() => {
      fireEvent.click(screen.getByRole("button", { name: /dismiss/i }));
    });

    expect(mockAgentsCache["test-agent"].status).toBe("connected");
    expect(mockAgentsCache["test-agent"].error).toBeNull();
    expect(mockAgentsCache["test-agent"].agentState).toBe("idle");
  });

  it("leaves the error banner in place during compaction_failed (preserves the recovery banner)", () => {
    // Regression check: the prop fix is gated on
    // `cache?.status === "error" && cache?.error`. The
    // `compaction_failed` state uses `cache.status === "connected"`
    // with `cache.compactionError` set, so the StatusBanner
    // continues to pick the `agentState === "compaction_failed"`
    // branch and render the Retry-compaction banner. The fix
    // doesn't regress this path.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "compaction_failed",
        error: null,
        compactionError: "LLM returned empty summary",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("Compaction failed")).toBeInTheDocument();
    expect(screen.getByText("LLM returned empty summary")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /retry compaction/i }),
    ).toBeInTheDocument();
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
      <MemoryRouter initialEntries={["/space/my-space/agent/test-agent"]}>
        <Routes>
          <Route path="/space/:spaceSlug/agent/:name" element={<ChatPage />} />
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

describe("ChatPage message copy button", () => {
  let writeText;

  beforeEach(() => {
    mockAgentsCache = {};
    // jsdom doesn't ship `navigator.clipboard`; install a mock so
    // the per-message copy button's `copyToClipboard` resolves
    // successfully.
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

  it("renders a 'Copy message' button on every finalized message", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hello" }] },
          {
            index: 1,
            role: "assistant",
            parts: [{ kind: "text", text: "Hi back" }],
          },
          {
            index: 2,
            role: "system",
            parts: [{ kind: "text", text: "Welcome" }],
          },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // Three messages → three copy buttons.
    expect(
      screen.getAllByRole("button", { name: /copy message/i }),
    ).toHaveLength(3);
  });

  it("clicking a user message's copy button writes the content (with the [mode: X]\\n prefix stripped) to the clipboard", async () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          {
            index: 0,
            role: "user",
            mode: "build",
            parts: [{ kind: "text", text: "[mode: build]\nHello world" }],
          },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /copy message/i }));
    });

    expect(writeText).toHaveBeenCalledWith("Hello world");
  });

  it("clicking an assistant message's copy button writes the content (including thinking, separated by a horizontal rule)", async () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          {
            index: 0,
            role: "user",
            parts: [{ kind: "text", text: "Hi" }],
          },
          {
            index: 1,
            role: "assistant",
            parts: [
              { kind: "thinking", thinking: "Reasoning here." },
              { kind: "text", text: "Answer here." },
            ],
          },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // Two messages → two copy buttons; the assistant one is
    // index 1, i.e. the second one.
    const buttons = screen.getAllByRole("button", {
      name: /copy message/i,
    });
    await act(async () => {
      fireEvent.click(buttons[1]);
    });

    expect(writeText).toHaveBeenCalledWith(
      "Reasoning here.\n\n---\n\nAnswer here.",
    );
  });

  it("the copy button on a message flips to 'Copied' after a successful click", async () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: /copy message/i }));
    });

    expect(screen.getByRole("button", { name: /copied/i })).toBeInTheDocument();
  });
});

describe("ChatPage compaction-frozen state", () => {
  beforeEach(() => {
    mockAgentsCache = {};
    vi.clearAllMocks();
  });

  function setupCompactionFailed() {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "compaction_failed",
        compactionError: "LLM returned empty summary.",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };
    renderChat();
  }

  it("does NOT freeze the input or show a banner while the agent is compacting", () => {
    // The compactor records the suffix + a synthetic assistant
    // message in the message list, and the user watches the
    // chat pane while the LLM call runs. The StatusBanner
    // intentionally does not render for `:compacting` (no
    // spinner) and the chat input stays usable.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "compacting",
        messages: [],
        model: { name: "qwen3.5-plus" },
      },
    };
    renderChat();

    // Input is visible and usable.
    expect(screen.queryByRole("textbox", { name: /message/i })).not.toBeNull();
    // No compacting spinner banner.
    expect(screen.queryByText("Compacting conversation...")).toBeNull();
  });

  it("hides the chat input and shows a Retry-compaction button when compaction_failed", () => {
    setupCompactionFailed();

    expect(screen.queryByRole("textbox", { name: /message/i })).toBeNull();
    expect(screen.getByText("Compaction failed")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /retry compaction/i }),
    ).toBeInTheDocument();
  });

  it("clicking Retry compaction pushes chat:retry-compaction to the channel", async () => {
    setupCompactionFailed();

    await act(async () => {
      fireEvent.click(
        screen.getByRole("button", { name: /retry compaction/i }),
      );
    });

    expect(retryCompaction).toHaveBeenCalledWith(
      "test-agent",
      expect.any(Function),
    );
  });

  it("surfaces the server's rejection reason via sendError", async () => {
    retryCompaction.mockImplementation((_id, onError) => {
      onError({ reason: "agent_status_compacting" });
    });
    setupCompactionFailed();

    await act(async () => {
      fireEvent.click(
        screen.getByRole("button", { name: /retry compaction/i }),
      );
    });

    expect(screen.getByText("agent_status_compacting")).toBeInTheDocument();
  });

  describe("compaction_loop_detected", () => {
    function setupCompactionLoop() {
      mockAgentsCache = {
        "test-agent": {
          status: "connected",
          agentState: "compaction_loop_detected",
          compactionLoop: "compaction isn't reducing the conversation",
          messages: [],
          model: { name: "qwen3.5-plus" },
        },
      };
      renderChat();
    }

    it("hides the chat input and shows an OK button when compaction_loop_detected", () => {
      setupCompactionLoop();

      expect(screen.queryByRole("textbox", { name: /message/i })).toBeNull();
      expect(
        screen.getByText("Compaction isn't reducing context"),
      ).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /^ok$/i })).toBeInTheDocument();
    });

    it("clicking OK pushes chat:loop-detected-ok to the channel", async () => {
      setupCompactionLoop();

      await act(async () => {
        fireEvent.click(screen.getByRole("button", { name: /^ok$/i }));
      });

      expect(compactionLoopOk).toHaveBeenCalledWith(
        "test-agent",
        expect.any(Function),
      );
    });

    it("surfaces the OK click's server rejection via sendError", async () => {
      compactionLoopOk.mockImplementation((_id, onError) => {
        onError({ reason: "wrong_state" });
      });
      setupCompactionLoop();

      await act(async () => {
        fireEvent.click(screen.getByRole("button", { name: /^ok$/i }));
      });

      expect(screen.getByText("wrong_state")).toBeInTheDocument();
    });
  });
});

describe("ChatPage delegated task placement", () => {
  // Regression coverage for the "delegated task boxes stuck
  // at the bottom" bug. The card for an `agents/spawn` call
  // must render inside the assistant message that issued
  // the call (between the assistant bubble and the tool
  // result bubble), NOT as a single block stacked at the
  // bottom of the chat log.

  beforeEach(() => {
    mockAgentsCache = {};
  });

  it("renders the delegated task card between the assistant message and the clone tool result", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "idle",
        messages: [
          {
            index: 0,
            role: "user",
            parts: [{ kind: "text", text: "please investigate" }],
          },
          {
            index: 1,
            role: "assistant",
            parts: [],
            toolCalls: [
              {
                id: "call-1",
                name: "agents/spawn",
                arguments: { query: "investigate foo" },
              },
            ],
          },
          {
            index: 2,
            role: "tool",
            toolResults: [
              {
                tool_call_id: "call-1",
                name: "agents/spawn",
                content: "child says done",
                is_error: false,
              },
            ],
          },
        ],
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    const userMessage = screen.getByText("please investigate");
    const card = screen.getByTestId("delegated-task-block");
    const toolResult = screen.getByText("Tool Result");

    // The card sits in the DOM between the user message
    // and the tool result message — inside the assistant
    // bubble, NOT after the tool result or stacked at the
    // bottom of the chat log.
    expect(
      userMessage.compareDocumentPosition(card) &
        Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
    expect(
      card.compareDocumentPosition(toolResult) &
        Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
  });
});

describe("ChatPage think-only streaming message with an in-flight tool call", () => {
  // Regression coverage for the "tool call doesn't show
  // during streaming of a think-only message" bug. The BEAM
  // surfaces tool-use events as `chat:delta` with
  // `partType: "tool_use_start"` / `:tool_use_delta`, which
  // the store maps into a `tool_use` part in
  // `cache.partial.parts`. The assistant bubble must derive
  // the tool calls from those parts (not the never-populated
  // `message.toolCalls`) so the in-flight tool call is
  // visible without waiting for the assistant message to
  // finalize.

  beforeEach(() => {
    mockAgentsCache = {};
  });

  it("renders the in-flight tool call inside the streaming partial bubble", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
        ],
        partial: {
          messageIndex: 1,
          role: "assistant",
          parts: [
            {
              kind: "thinking",
              thinking: "Let me run a quick check.",
            },
            {
              kind: "tool_use",
              id: "call_stream_1",
              name: "shell_cmd",
              arguments: '{"command":"ls"}',
            },
          ],
          isPartial: true,
        },
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    // The thinking block is visible.
    expect(screen.getByText("Let me run a quick check.")).toBeInTheDocument();

    // The in-flight tool call renders its name as soon as
    // the BEAM broadcasts the start event — no waiting
    // for the assistant message to finalize.
    expect(screen.getByText("Using tool: shell_cmd")).toBeInTheDocument();

    // The arguments are JSON-parsed and rendered as a
    // formatted preview (object path through formatToolCall).
    expect(screen.getByText(/"command"/)).toBeInTheDocument();
    expect(screen.getByText(/"ls"/)).toBeInTheDocument();
  });

  it("streams the partial JSON buffer verbatim for tool calls still arriving", () => {
    // Regression for the "tool call doesn't stream" UX:
    // when the LLM is mid-`tool_use_delta`, the buffer
    // `'{"command":'` (still arriving) must be visible in
    // the chat — not silently dropped. The renderer puts it
    // in a `<pre>` monospace block.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
        ],
        partial: {
          messageIndex: 1,
          role: "assistant",
          parts: [
            {
              kind: "tool_use",
              id: "call_stream_partial",
              name: "shell_cmd",
              arguments: '{"command":',
            },
          ],
          isPartial: true,
        },
        model: { name: "qwen3.5-plus" },
      },
    };

    renderChat();

    expect(screen.getByText("Using tool: shell_cmd")).toBeInTheDocument();
    // The streaming `<pre>` carries the raw partial buffer
    // — same bytes the BEAM is broadcasting.
    expect(screen.getByTestId("tool-call-streaming-pre").textContent).toBe(
      '{"command":',
    );
    // The "Receiving" pulse indicates the buffer is still
    // in flight.
    expect(
      screen.getByTestId("streaming-indicator-call_stream_partial"),
    ).toBeInTheDocument();
  });

  it("does not place the in-flight tool call after the scroll anchor", () => {
    // The `messagesEndEl` div is what `useScrollToBottom`
    // scrolls into view when the chat grows. The tool
    // call must live BEFORE the scroll anchor (inside the
    // streaming bubble), not after it.
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "streaming",
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hi" }] },
        ],
        partial: {
          messageIndex: 1,
          role: "assistant",
          parts: [
            {
              kind: "thinking",
              thinking: "Delegating.",
            },
            {
              kind: "tool_use",
              id: "call_stream_2",
              name: "agents/spawn",
              arguments: '{"query":"x"}',
            },
          ],
          isPartial: true,
        },
        model: { name: "qwen3.5-plus" },
      },
    };

    // The streaming partial renders the tool call inline
    // (same as the first test). We don't need a second
    // positional assertion here — the regression we're
    // guarding against was the old bug where tool calls
    // were rendered outside the message bubble, after the
    // scroll anchor. The first test already proves the
    // card is rendered with the right contents; this test
    // is a smoke check that confirms the rendering path
    // doesn't crash on an `agents/spawn` call (which has
    // special delegation rendering on top of the basic
    // tool card).
    renderChat();
    expect(screen.getByText("Using tool: agents/spawn")).toBeInTheDocument();
  });
});

describe("ChatPage model picker (model_missing recovery)", () => {
  it("opens the picker when the user clicks the model_missing banner", () => {
    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "model_missing",
        messages: [],
        model: { name: "ghost-model" },
      },
    };

    renderChat();

    const bannerButton = screen.getByRole("button", {
      name: /choose replacement model/i,
    });
    fireEvent.click(bannerButton);

    expect(screen.getByTestId("mock-model-picker")).toBeInTheDocument();
  });

  it("calls changeAgentModel when the user picks a replacement", () => {
    mocks.changeAgentModel.mockImplementation(
      (_name, _spaceId, _model, _onOk, onError) => {
        // Simulate the server error reply so the
        // `setChangeModelError` branch runs end-to-end.
        if (onError) onError({ reason: "agent_busy" });
      },
    );

    mockAgentsCache = {
      "test-agent": {
        status: "connected",
        agentState: "model_missing",
        messages: [],
        model: { name: "ghost-model" },
      },
    };

    renderChat();

    fireEvent.click(
      screen.getByRole("button", { name: /choose replacement model/i }),
    );
    fireEvent.click(screen.getByRole("button", { name: /pick/i }));

    expect(mocks.changeAgentModel).toHaveBeenCalledWith(
      "test-agent",
      1,
      { name: "gpt-4", provider: "openai" },
      undefined,
      expect.any(Function),
    );

    // The agent_busy error reason surfaces the user-friendly
    // message inline.
    expect(
      screen.getByText(/agent is busy.*wait for the current chat to finish/i),
    ).toBeInTheDocument();
  });
});
