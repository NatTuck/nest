/**
 * Tests for the live `Message` bubble.
 *
 * Covers the API-logs affordance (a missing response log must render a visible
 * error indicator rather than silently vanishing), the `[nest notice]` marker's
 * render-time removal, and that an attached image renders exactly once
 * (issue #115).
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
    // reads); the rendered bubble must not show it to the operator, on any
    // notice row shape — a user row (`:agent_user` / the drain path), the
    // fused assistant row (`:user_agent`), or a notice batched behind a peer's
    // entry (where the marker heads the second body, not the message).
    const cases = [
      {
        label: "a user notice row",
        text: "[mode: chat]\n[nest notice]\nContext at 50%. Do not stop due to context concerns, continue working through compaction.",
        shown: /Context at 50%/,
        role: "user",
      },
      {
        label: "the fused assistant notice row",
        text: "[nest notice]\nContext at 25%. Okay, context noted.",
        shown: /Okay, context noted\./,
        role: "assistant",
      },
      {
        label: "a notice batched behind a peer's entry",
        text: '[mode: chat]\n[Message from agent "peer"]\nmay I ask?\n\n[nest notice]\nContext at 50%.',
        shown: /may I ask\?/,
        role: "user",
      },
    ];

    for (const { label, text, shown, role } of cases) {
      expect(text.includes("[nest notice]"), label).toBe(true);

      const message =
        role === "user"
          ? {
              index: 3,
              role: "user",
              mode: "chat",
              parts: [{ kind: "text", text }],
              metadata: { mode: "chat" },
            }
          : assistantMessage({ parts: [{ kind: "text", text }] });

      const { unmount } = render(
        <MessageBubble agentName="test-agent" message={message} />,
      );

      expect(screen.getByText(shown), label).toBeInTheDocument();
      expect(screen.queryByText(/nest notice/), label).toBeNull();
      unmount();
    }
  });
});

describe("attached media renders exactly once", () => {
  // Issue #115. Two components can render media: `MessageContent`, whose parts
  // still carry the media part because `textPartsFor` passes every non-text
  // part through, and the explicit `ToolMedia` beside it for a non-user role.
  // Both fired, so the operator saw the attachment twice.
  const PNG =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==";

  // The wire part, camelCase; the store-derived `media` field, snake_case.
  const mediaPart = {
    kind: "media",
    toolCallId: "call_1",
    modality: "image",
    mediaType: "image/png",
    bytes: 68,
    data: PNG,
    path: "shot.png",
  };

  const derivedMedia = {
    tool_call_id: "call_1",
    modality: "image",
    mediaType: "image/png",
    bytes: 68,
    data: PNG,
    path: "shot.png",
  };

  const toolResultPart = {
    kind: "tool_result",
    toolCallId: "call_1",
    name: "file-read",
    content: "Read 68 B image/png from shot.png; attached below.",
    isError: false,
    state: null,
  };

  // Deliberately no default `media` field: `overrides` is where a case says
  // which of the two copies of the attachment the message carries.
  const toolMessage = (parts, overrides = {}) => ({
    index: 5,
    role: "tool",
    parts,
    toolResults: [
      {
        tool_call_id: "call_1",
        name: "file-read",
        content: "Read 68 B image/png from shot.png; attached below.",
        is_error: false,
        state: null,
      },
    ],
    metadata: null,
    ...overrides,
  });

  const cases = [
    {
      label: "a freshly appended tool result (no message-level media field)",
      // The shape `addChatMessage` builds for a new row: the wire message is
      // spread verbatim and only `toolCalls` / `toolResults` are derived, so
      // the sole copy of the attachment is the `media` part in `parts` — the
      // wire has no message-level `media` key (`Part.to_json`). `buildMerged`
      // is the only store path that derives one, so this is the shape the
      // reported bug arrived in, and the `mediaFromParts(message.parts)`
      // fallback is what renders it.
      message: toolMessage([toolResultPart, mediaPart]),
    },
    {
      label: "a re-merged tool result whose derived media field carries it",
      message: toolMessage([toolResultPart, mediaPart], {
        media: [derivedMedia],
      }),
    },
    {
      label: "an empty derived media field beside a media part in parts",
      // `[]` is not nullish, so `message.media ?? mediaFromParts(...)` keeps
      // the empty array; with the media part also filtered out of
      // `MessageContent` that renders nothing at all — a silent drop.
      message: toolMessage([toolResultPart, mediaPart], { media: [] }),
    },
    {
      label: "a derived media field with no media part in parts",
      // Why the explicit render stays rather than being deleted: this media
      // `MessageContent` cannot see, and dropping the explicit render would
      // lose it silently — which the project forbids.
      message: toolMessage([toolResultPart], { media: [derivedMedia] }),
    },
  ];

  for (const { label, message } of cases) {
    it(`renders the attached image once for ${label}`, () => {
      render(<MessageBubble agentName="test-agent" message={message} />);

      expect(screen.getAllByTestId("tool-media-image")).toHaveLength(1);
    });
  }
});

describe("Message peer deliveries", () => {
  const peerMessage = (overrides = {}) => ({
    index: 1,
    role: "user",
    parts: [
      {
        kind: "text",
        text: '[Message from agent "peer" | mode: act]\nmay I ask?',
      },
    ],
    // `Message.jsx` renders the badge from the message's own `mode`, and the
    // wire shape carries it in `metadata` too; a fixture needs both.
    mode: "act",
    metadata: { mode: "act" },
    ...overrides,
  });

  it("shows the mode once — as the badge — and not a second time in the header", () => {
    // The server states the recipient's mode in the header of a peer delivery,
    // which is how an agent whose inbox is all peer traffic learns its own mode.
    // The bubble already renders the same value as the mode badge, so the
    // header's copy is dropped from the display (exactly as `stripModePrefix`
    // drops the `[mode: X]` prefix the badge also shows).
    render(<MessageBubble agentName="test-agent" message={peerMessage()} />);

    expect(screen.getByText("mode: act")).toBeInTheDocument();
    expect(
      screen.getByText(/\[Message from agent "peer"\]/),
    ).toBeInTheDocument();
    expect(screen.getByText(/may I ask\?/)).toBeInTheDocument();
  });

  it("keeps a header whose mode disagrees with the message's own", () => {
    // Nothing is hidden: a disagreement is a bug or an older row, and it stays
    // on screen rather than being silently resolved either way.
    render(
      <MessageBubble
        agentName="test-agent"
        message={peerMessage({
          parts: [
            {
              kind: "text",
              text: '[Message from agent "peer" | mode: plan]\nhi',
            },
          ],
        })}
      />,
    );

    expect(screen.getByText(/\| mode: plan\]/)).toBeInTheDocument();
  });
});
