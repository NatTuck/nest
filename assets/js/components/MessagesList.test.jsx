/**
 * Tests for `js/components/MessagesList.jsx`.
 *
 * Covers both branches of the `?? EMPTY_MESSAGES` selector: when
 * the agent has cached messages and when it doesn't.
 */

import { describe, it, beforeEach, vi } from "vitest";
import assert from "node:assert";
import { render, cleanup, screen } from "@testing-library/react";
import { MessagesList } from "./MessagesList";
import { useStore } from "../store";

vi.mock("./Message", () => ({
  MessageBubble: ({ message }) => (
    <div data-testid="message-bubble">{message.text ?? message.index}</div>
  ),
}));

describe("MessagesList", () => {
  beforeEach(() => {
    cleanup();
    useStore.setState({ agentsCache: {} });
  });

  it("renders nothing when the agent has no cached messages", () => {
    useStore.setState({
      agentsCache: {
        "agent-1": { messages: undefined },
      },
    });

    const { container } = render(<MessagesList agentName="agent-1" />);
    assert.strictEqual(container.firstChild, null);
  });

  it("renders a MessageBubble per cached message", () => {
    useStore.setState({
      agentsCache: {
        "agent-1": {
          messages: [
            { index: 0, text: "hello" },
            { index: 1, text: "world" },
          ],
        },
      },
    });

    render(<MessagesList agentName="agent-1" />);
    const bubbles = screen.getAllByTestId("message-bubble");
    assert.strictEqual(bubbles.length, 2);
  });
});
