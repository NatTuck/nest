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
    lastCompactionIndex: -1,
    lastCompactionMarker: null,
    onLoadHistory: vi.fn(),
    onLoadOlder: vi.fn(),
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

  it("renders the compaction marker from the boundary + marker, not the loaded history", () => {
    const marker = { role: "compaction", index: 5, archivedCount: 3 };
    const { rerender } = render(
      messagesArea({
        messages: [{ index: 0 }],
        lastCompactionIndex: 5,
        lastCompactionMarker: marker,
      }),
    );

    // `hasArchive` is driven by `lastCompactionIndex`, so the card shows
    // even though no page has been loaded yet (`archivedHistory` = []).
    const card = screen.getByTestId("compaction-marker");
    expect(card).toHaveAttribute("data-marker-index", "5");
    expect(card).toHaveAttribute("data-history-count", "6");

    // No boundary → no marker.
    rerender(messagesArea({ messages: [{ index: 0 }] }));
    expect(screen.queryByTestId("compaction-marker")).toBeNull();

    // No active content (empty state) → no marker even with an archive.
    rerender(
      messagesArea({ lastCompactionIndex: 5, lastCompactionMarker: marker }),
    );
    expect(screen.queryByTestId("compaction-marker")).toBeNull();
  });
});
