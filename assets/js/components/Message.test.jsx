/**
 * Tests for the live `Message` bubble's API-logs affordance.
 *
 * The response log is expected on assistant messages; a missing one
 * must render a visible error indicator rather than silently vanishing.
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { MessageBubble } from "./Message";

vi.mock("../channels/state", () => ({
  agentChannels: new Map(),
}));

const assistantMessage = (overrides = {}) => ({
  index: 2,
  role: "assistant",
  parts: [{ kind: "text", text: "Hi there" }],
  metadata: null,
  ...overrides,
});

describe("Message API logs affordance", () => {
  it("renders the API Logs block for an assistant message with a response log", () => {
    render(
      <MessageBubble
        agentName="test-agent"
        message={assistantMessage({
          apiLogs: [
            {
              id: "002.000",
              type: "response",
              timestamp: "2024-01-01T00:00:00Z",
              payload: { content: "Hi there" },
            },
          ],
        })}
      />,
    );

    expect(screen.getByText("API Logs (1)")).toBeInTheDocument();
  });

  it("renders a visible error indicator (not nothing) when an assistant response log is missing", () => {
    render(
      <MessageBubble
        agentName="test-agent"
        message={assistantMessage({ apiLogs: [] })}
      />,
    );

    expect(
      screen.getByText(/API response log missing — not recorded/i),
    ).toBeInTheDocument();
  });

  it("renders nothing for an assistant error message with no response (no log expected)", () => {
    render(
      <MessageBubble
        agentName="test-agent"
        message={assistantMessage({
          apiLogs: [],
          metadata: { error: true },
        })}
      />,
    );

    expect(screen.queryByText(/API response log missing/i)).toBeNull();
    expect(screen.queryByText(/API Logs \(/)).toBeNull();
  });
});
