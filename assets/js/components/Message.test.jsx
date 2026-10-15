/**
 * Tests for the live `Message` bubble's API-logs affordance.
 *
 * The response log is expected on assistant messages; a missing one
 * must render a visible error indicator rather than silently vanishing.
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen, within } from "@testing-library/react";
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

describe("Message copy control placement", () => {
  it("renders the copy button in the bottom actions row, not the header", () => {
    render(
      <MessageBubble agentName="test-agent" message={assistantMessage()} />,
    );

    const actions = screen.getByTestId("message-actions");
    const button = screen.getByRole("button", { name: /copy message/i });
    expect(actions).toContainElement(button);

    // The header row (which carries the role label) must not contain it.
    const header = screen.getByText("test-agent").closest("div");
    expect(
      within(header).queryByRole("button", { name: /copy message/i }),
    ).toBeNull();

    // And the actions row sits below the message body.
    const body = screen.getByText("Hi there");
    expect(
      body.compareDocumentPosition(actions) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).not.toBe(0);
  });
});

describe("Message runtime notice rendering", () => {
  it("hides the `[nest notice]` wire marker the row carries", () => {
    // The raw wire content really carries the marker (that is what the model
    // reads); the rendered bubble must not show it to the operator, on either
    // notice row shape — a user row (`:agent_user` / the drain path) or the
    // fused assistant row (`:user_agent`).
    const userRaw =
      "[mode: chat]\n[nest notice]\nContext at 50%. Do not stop due to context concerns, continue working through compaction.";
    const assistantRaw = "[nest notice]\nContext at 25%. Okay, context noted.";

    expect(userRaw.startsWith("[mode: chat]\n[nest notice]\n")).toBe(true);
    expect(assistantRaw.startsWith("[nest notice]\n")).toBe(true);

    const { unmount } = render(
      <MessageBubble
        agentName="test-agent"
        message={{
          index: 3,
          role: "user",
          mode: "chat",
          parts: [{ kind: "text", text: userRaw }],
          metadata: { mode: "chat" },
        }}
      />,
    );

    expect(screen.getByText(/Context at 50%/)).toBeInTheDocument();
    expect(screen.queryByText(/nest notice/)).toBeNull();
    unmount();

    render(
      <MessageBubble
        agentName="test-agent"
        message={assistantMessage({
          parts: [{ kind: "text", text: assistantRaw }],
        })}
      />,
    );

    expect(screen.getByText(/Okay, context noted\./)).toBeInTheDocument();
    expect(screen.queryByText(/nest notice/)).toBeNull();
  });
});
