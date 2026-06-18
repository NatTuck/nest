/**
 * Tests for the ChatPage chat header.
 *
 * Specifically: the model display under the agent ID should show
 * "provider: model-name" when both are present, falling back to
 * just the name when only name is available.
 */
import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";

// Mock zustand store — set the cache directly per test.
let mockAgentsCache = {};
vi.mock("../store", () => ({
  useStore: (selector) =>
    selector({ agentsCache: mockAgentsCache, _reset: () => {} }),
}));

// Mock channels — ChatPage calls joinAgent/leaveAgent on mount.
vi.mock("../channels", () => ({
  joinAgent: vi.fn(),
  leaveAgent: vi.fn(),
  sendMessage: vi.fn(),
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
