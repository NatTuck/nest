/**
 * Tests for `js/components/ChatMessages.jsx`.
 *
 * The message area renders the compaction marker, the empty state, or the
 * `MessagesList` + `StreamingMessage` pair. Child components are mocked so
 * these tests focus on the branching here.
 */

import { describe, expect, it, vi, beforeEach } from "vitest";
import { render, screen, cleanup } from "@testing-library/react";
import { ChatMessages } from "./ChatMessages";

vi.mock("./CompactionMarker", () => ({
  CompactionMarker: ({ marker, history, historyCount }) => (
    <div
      data-testid="compaction-marker"
      data-marker-index={marker?.index}
      data-history-count={historyCount}
    >
      {history?.length}
    </div>
  ),
}));

vi.mock("./MessagesList", () => ({
  MessagesList: ({ agentName }) => (
    <div data-testid="messages-list">{agentName}</div>
  ),
}));

vi.mock("./StreamingMessage", () => ({
  StreamingMessage: ({ agentName }) => (
    <div data-testid="streaming-message">{agentName}</div>
  ),
}));

function messagesArea(overrides = {}) {
  const props = {
    messages: [],
    partial: null,
    archivedHistory: [],
    name: "alpha",
    setScrollContainerEl: vi.fn(),
    setMessagesEndEl: vi.fn(),
    ...overrides,
  };
  return <ChatMessages {...props} />;
}

describe("ChatMessages", () => {
  beforeEach(cleanup);

  it("shows the empty state when there are no messages and no partial", () => {
    render(messagesArea());

    expect(screen.getByText("Start a conversation")).toBeInTheDocument();
    expect(screen.queryByTestId("messages-list")).toBeNull();
    expect(screen.queryByTestId("streaming-message")).toBeNull();
  });

  it("renders the message list and streaming bubble whenever there is active content", () => {
    const { rerender } = render(messagesArea({ messages: [{ index: 0 }] }));

    expect(screen.getByTestId("messages-list")).toHaveTextContent("alpha");
    expect(screen.getByTestId("streaming-message")).toHaveTextContent("alpha");
    expect(screen.queryByText("Start a conversation")).toBeNull();

    rerender(messagesArea({ partial: { index: 0 } }));

    expect(screen.queryByText("Start a conversation")).toBeNull();
    expect(screen.getByTestId("streaming-message")).toBeInTheDocument();
  });

  it("renders the compaction marker only when there is active content and archived history", () => {
    const archived = [
      { role: "compaction", index: 5 },
      { role: "user", index: 6 },
    ];
    const { rerender } = render(
      messagesArea({ messages: [{ index: 0 }], archivedHistory: archived }),
    );

    const marker = screen.getByTestId("compaction-marker");
    expect(marker).toHaveAttribute("data-marker-index", "5");
    expect(marker).toHaveAttribute("data-history-count", "2");

    // No archived history → no marker.
    rerender(messagesArea({ messages: [{ index: 0 }], archivedHistory: [] }));
    expect(screen.queryByTestId("compaction-marker")).toBeNull();

    // No active content (empty state) → no marker even with history.
    rerender(messagesArea({ archivedHistory: archived }));
    expect(screen.queryByTestId("compaction-marker")).toBeNull();
  });

  it("falls back to reversing the history when Array.prototype.findLast is unavailable", () => {
    // Shadow the prototype method with an own `undefined` property so the
    // component takes its compatibility fallback without mutating the
    // shared Array prototype.
    const archived = [
      { role: "user", index: 6 },
      { role: "compaction", index: 5 },
    ];
    archived.findLast = undefined;

    render(
      messagesArea({ messages: [{ index: 0 }], archivedHistory: archived }),
    );

    expect(screen.getByTestId("compaction-marker")).toHaveAttribute(
      "data-marker-index",
      "5",
    );
  });
});
