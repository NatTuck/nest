/**
 * Tests for the live `Message` bubble.
 *
 * Covers the API-logs affordance (a missing response log must render a visible
 * error indicator rather than silently vanishing), the `[nest notice]` marker's
 * render-time removal, that an attached image renders exactly once
 * (issue #115), and that a backgrounded command's output is rendered as command
 * output rather than as markdown (issue #139).
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

describe("Message backgrounded command output", () => {
  it("renders the command's output as command output, not as markdown", () => {
    // Issue #139: a backgrounded command's result is one user row whose parts
    // are the announcing prose plus the command's own output, which
    // `commandOutputParts` marks. The live list must render that part as
    // command output — markdown would turn the command's `# ` and `**…**` into
    // formatting.
    const { container } = render(
      <MessageBubble
        agentName="test-agent"
        message={{
          index: 4,
          role: "user",
          mode: "act",
          parts: [
            {
              kind: "text",
              text: "[From nest runtime | mode: act]\nYour backgrounded command (shell-cmd) finished. Its result:\n\n",
            },
            { kind: "text", text: "# a shell comment\n\n**not bold**" },
          ],
          commandOutputParts: [1],
        }}
      />,
    );

    expect(container.querySelector("pre").textContent).toBe(
      "# a shell comment\n\n**not bold**",
    );
    expect(container.querySelector("h1")).toBeNull();
    expect(container.querySelector("strong")).toBeNull();
    expect(
      screen.getByText(/Your backgrounded command \(shell-cmd\) finished\./),
    ).toBeInTheDocument();
    expect(screen.queryByText(/\[From nest runtime/)).toBeNull();
  });
});

describe("Message sender affordances", () => {
  // The header states three facts — sender, reply-required, mode — and the
  // mode already has the badge. The sender and the reply marker get their own
  // home here, because deleting the whole line on the ground that "the sender
  // is the row's own author" is false for a batch, a peer's note, a runtime
  // notice and a spawn kickoff — every one of which used to be drawn as the
  // human's own "You".

  const userRow = (overrides = {}) => ({
    index: 1,
    role: "user",
    mode: "act",
    metadata: { mode: "act" },
    ...overrides,
  });

  it("shows both senders of a two-body batch, and deletes neither header", () => {
    const { container } = render(
      <MessageBubble
        agentName="test-agent"
        message={userRow({
          parts: [
            { kind: "text", text: "[From agent a | mode: act]\nfirst body" },
            {
              kind: "text",
              text: "[From agent b, agents-send reply required | mode: act]\nsecond body",
            },
          ],
        })}
      />,
    );

    // Both senders are visible — as per-body captions, since the row holds two
    // bodies with different senders.
    expect(screen.getByText("a")).toBeInTheDocument();
    expect(screen.getByText("b")).toBeInTheDocument();

    // The reply marker survived as an affordance.
    expect(screen.getByText("reply required")).toBeInTheDocument();

    // Neither header line is rendered...
    expect(container.textContent).not.toContain("[From agent a");
    expect(container.textContent).not.toContain("[From agent b");

    // ...the row label does not claim the human wrote it, and neither does the
    // bubble's tint.
    expect(screen.queryByText("You")).toBeNull();
    expect(screen.getByText("2 notes")).toBeInTheDocument();
    expect(container.querySelector(".bg-blue-50")).toBeNull();
    // Several senders get the neutral "N notes" tint, not the human's blue.
    expect(container.querySelector(".bg-gray-50")).not.toBeNull();
  });

  it("labels a runtime notice row with the runtime, not the human", () => {
    render(
      <MessageBubble
        agentName="test-agent"
        message={userRow({
          parts: [
            {
              kind: "text",
              text: "[From nest runtime | mode: act]\nContext at 50%.",
            },
          ],
        })}
      />,
    );

    expect(screen.getByText("nest runtime")).toBeInTheDocument();
    expect(screen.queryByText("You")).toBeNull();
  });

  it("labels a spawn kickoff with the spawning agent, not the human", () => {
    // A spawn kickoff is a `kind: :user` entry nobody typed: no `origin`
    // metadata, and the header says which agent it came from.
    render(
      <MessageBubble
        agentName="test-agent"
        message={userRow({
          parts: [{ kind: "text", text: "[From agent x | mode: act]\nDo it." }],
        })}
      />,
    );

    expect(screen.getByText("x")).toBeInTheDocument();
    expect(screen.queryByText("You")).toBeNull();
  });

  it("keeps the human's own row as 'You', with one body and no caption", () => {
    const { container } = render(
      <MessageBubble
        agentName="test-agent"
        message={userRow({
          origin: "human",
          parts: [
            { kind: "text", text: "[From user @nat | mode: act]\nHello" },
          ],
        })}
      />,
    );

    expect(screen.getByText("You")).toBeInTheDocument();
    // The human's blue bubble is unchanged.
    expect(container.querySelector(".bg-blue-50")).not.toBeNull();
    // One body states its sender in the row label, so there is no caption and
    // nothing is shown twice.
    expect(screen.queryByText("@nat")).toBeNull();
    expect(container.textContent).not.toContain("[From user");
  });

  it("says 'unknown sender' rather than 'You' when the row names nobody", () => {
    render(
      <MessageBubble
        agentName="test-agent"
        message={userRow({ parts: [{ kind: "text", text: "no framing" }] })}
      />,
    );

    expect(screen.getByText("unknown sender")).toBeInTheDocument();
    expect(screen.queryByText("You")).toBeNull();
  });
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

  it("drops the current header and shows the mode once, as the badge", () => {
    // Every user-role row states its sender and the recipient's mode in a
    // header now. The bubble shows the sender as the row's own role/author and
    // the mode as the badge, so the header is wire framing — and the badge's
    // value is what the header's clause has to agree with.
    render(
      <MessageBubble
        agentName="test-agent"
        message={peerMessage({
          parts: [
            { kind: "text", text: "[From agent peer | mode: act]\nmay I ask?" },
          ],
        })}
      />,
    );

    expect(screen.getByText("mode: act")).toBeInTheDocument();
    expect(screen.getByText(/may I ask\?/)).toBeInTheDocument();
    expect(screen.queryByText(/\[From agent peer/)).toBeNull();
  });

  it("shows the mode once — as the badge — and not a second time in the header", () => {
    // A row recorded before the `[From … | mode: …]` header states the
    // recipient's mode in the old `[Message from agent "peer" | mode: act]`
    // label, which is how an agent whose inbox is all peer traffic learned its
    // own mode. The bubble already renders the same value as the mode badge, so
    // the label's copy is dropped from the display (exactly as `splitFraming`
    // drops the header the badge also shows).
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
