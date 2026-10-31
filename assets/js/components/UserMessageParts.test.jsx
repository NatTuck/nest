/**
 * Tests for `UserMessageParts` — the body of a user-role row.
 *
 * Issue #139: a backgrounded command's result arrives as ONE user row whose
 * parts are the prose that announces it plus the command's own output. The
 * output must render as command output — a `<pre>`, collapsed when long — and
 * not through `<Markdown>`, which turns `# `, `**…**`, `_…_`, backticks and
 * indented lines into formatting and so mangles what the command printed.
 *
 * Also covered here: the framing (`[From … | mode: …]`) is stripped from every
 * body of a multi-body row, a row persisted before the parts model still
 * renders, the row's attachments render exactly once, and a `commandOutputParts`
 * that names a non-text part is reported rather than ignored.
 */
import { describe, it, expect } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { UserMessageParts } from "./UserMessageParts";

const PROSE =
  "[From nest runtime | mode: act]\nYour backgrounded command (shell-cmd) finished. Its result:\n\n";

// What markdown would mangle: a heading, bold, italics, a backtick and an
// indented line. The output is literal text.
const OUTPUT =
  "# not a heading\n\n**not bold** and _not italic_\n\n    indented";

const prosePart = (text = PROSE) => ({ kind: "text", text });

const outputRow = (overrides = {}) => ({
  role: "user",
  mode: "act",
  parts: [prosePart(), { kind: "text", text: OUTPUT }],
  commandOutputParts: [1],
  ...overrides,
});

const PNG =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==";

describe("UserMessageParts", () => {
  it("renders a prose-only row as markdown, with the header stripped", () => {
    // The pre-#139 shape, unchanged: one text part, rendered through the same
    // markdown path, with the wire header removed.
    render(
      <UserMessageParts
        message={{
          role: "user",
          mode: "act",
          parts: [
            { kind: "text", text: "[From user | mode: act]\nHello there" },
          ],
        }}
        className="text-gray-800"
      />,
    );

    expect(screen.getByText("Hello there")).toBeInTheDocument();
    expect(screen.queryByText(/\[From user/)).toBeNull();
    expect(document.querySelector("pre")).toBeNull();
  });

  it("renders a command's output as command output, not as markdown", () => {
    const { container } = render(<UserMessageParts message={outputRow()} />);

    const pre = container.querySelector("pre");
    expect(pre).not.toBeNull();
    expect(pre.textContent).toBe(OUTPUT);

    // Markdown would have produced an <h1> and a <strong> here; the command's
    // output is literal text.
    expect(container.querySelector("h1")).toBeNull();
    expect(container.querySelector("strong")).toBeNull();
    expect(container.querySelector("em")).toBeNull();

    // The prose above it still renders, and without its header.
    expect(
      screen.getByText(/Your backgrounded command \(shell-cmd\) finished\./),
    ).toBeInTheDocument();
    expect(screen.queryByText(/\[From nest runtime/)).toBeNull();
  });

  it("leaves an output part's own bytes alone, framing-shaped lines included", () => {
    // Issue #139, the defect this pins: an `:output` part is the *tail* of a
    // body, not a head — the header is on the part before it. Stripping framing
    // from it would delete a first line the command actually printed, and this
    // is the one place the operator is meant to see the command's own bytes.
    const OUTPUT_BYTES = "[nest notice]\n[From nest runtime | mode: act]\nok";

    render(
      <UserMessageParts
        message={{
          role: "user",
          mode: "act",
          parts: [prosePart(), { kind: "text", text: OUTPUT_BYTES }],
          commandOutputParts: [1],
        }}
      />,
    );

    // Both framing-shaped lines survive, verbatim, inside the <pre>.
    expect(document.querySelector("pre").textContent).toBe(OUTPUT_BYTES);

    // The prose part above it is a body head, so its header is still stripped.
    const prose = screen.getByText(
      /Your backgrounded command \(shell-cmd\) finished\./,
    );
    expect(prose.textContent).not.toContain("[From");
  });

  it("collapses long output behind TruncatedResult's toggle and leaves short output alone", () => {
    const lines = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`);

    const { unmount } = render(
      <UserMessageParts
        message={outputRow({
          parts: [prosePart(), { kind: "text", text: lines.join("\n") }],
        })}
      />,
    );

    // Collapsed by default: the first 10 lines, with the toggle naming the
    // total.
    expect(document.querySelector("pre").textContent).toContain("line 10");
    expect(document.querySelector("pre").textContent).not.toContain("line 30");
    fireEvent.click(screen.getByRole("button", { name: /show all 30 lines/i }));
    expect(document.querySelector("pre").textContent).toContain("line 30");

    unmount();

    // Short output: no toggle at all.
    render(<UserMessageParts message={outputRow()} />);
    expect(screen.queryByRole("button", { name: /show all/i })).toBeNull();
  });

  it("strips the header from every body of a multi-body row", () => {
    // The real wire shape: the blank line between two bodies rides the end of
    // the preceding part (`Render.parts/2`), so each body's header heads its
    // own part.
    render(
      <UserMessageParts
        message={{
          role: "user",
          mode: "act",
          parts: [
            {
              kind: "text",
              text: "[From agent peer | mode: act]\nfirst body\n\n",
            },
            {
              kind: "text",
              text: "[From agent other | mode: act]\nsecond body",
            },
          ],
        }}
      />,
    );

    expect(screen.getByText("first body")).toBeInTheDocument();
    expect(screen.getByText("second body")).toBeInTheDocument();
    expect(screen.queryByText(/\[From agent/)).toBeNull();
  });

  it("renders a drained batch's output as output even when it is not the last part", () => {
    // The payload `Nest.Agents.Agent.Inbox.Render.build_drained_message/3`
    // produces for a batch of a peer note and a backgrounded notice: three
    // text parts, and the command's output at index 2 — which is also why
    // nothing may assume "the last part is the output".
    render(
      <UserMessageParts
        message={{
          role: "user",
          mode: "act",
          commandOutputParts: [2],
          parts: [
            {
              kind: "text",
              text: "[From agent peer | mode: act]\nhello from a peer\n\n",
            },
            {
              kind: "text",
              text:
                "[From nest runtime | mode: act]\n" +
                "Your backgrounded command (shell-cmd) finished. Its result:\n\n",
            },
            { kind: "text", text: OUTPUT },
          ],
        }}
      />,
    );

    // Both bodies are prose, with their headers stripped...
    expect(screen.getByText("hello from a peer")).toBeInTheDocument();
    expect(
      screen.getByText(/Your backgrounded command \(shell-cmd\) finished\./),
    ).toBeInTheDocument();
    expect(screen.queryByText(/\[From /)).toBeNull();

    // ...and the marked part is the only one rendered as command output.
    const pres = document.querySelectorAll("pre");
    expect(pres).toHaveLength(1);
    expect(pres[0].textContent).toBe(OUTPUT);
  });

  it("captions each body of a multi-body row with its sender and reply marker", () => {
    // A drained batch holds one body per entry and the senders differ, so the
    // row label cannot state them: each body carries its own caption. This is
    // the same removal as before — the header line is gone — but the facts it
    // carried are now on screen.
    render(
      <UserMessageParts
        message={{
          role: "user",
          mode: "act",
          parts: [
            { kind: "text", text: "[From agent a | mode: act]\nfirst body" },
            {
              kind: "text",
              text: "[From agent b, agents-send reply required | mode: act]\nsecond body",
            },
          ],
        }}
      />,
    );

    expect(screen.getByText("a")).toBeInTheDocument();
    expect(screen.getByText("b")).toBeInTheDocument();
    expect(screen.getByText("reply required")).toBeInTheDocument();
    expect(screen.queryByText(/\[From /)).toBeNull();
  });

  it("shows no caption for a single-body row", () => {
    // The row label names the one sender; a caption here would show it twice.
    render(
      <UserMessageParts
        message={{
          role: "user",
          mode: "act",
          parts: [
            {
              kind: "text",
              text: "[From agent peer, agents-send reply required | mode: act]\nonly body",
            },
          ],
        }}
      />,
    );

    expect(screen.getByText("only body")).toBeInTheDocument();
    expect(screen.queryByText("peer")).toBeNull();
    expect(screen.queryByText("reply required")).toBeNull();
  });

  it("grows no caption for a single backgrounded notice with its output", () => {
    // The caption count is the row label's own (`rowSenders`), not the block
    // count: this row has two blocks (prose + command output) but one sender,
    // so a caption here would only repeat the row label.
    render(<UserMessageParts message={outputRow()} />);

    expect(
      screen.getByText(/Your backgrounded command \(shell-cmd\) finished\./),
    ).toBeInTheDocument();
    expect(screen.queryByText("nest runtime")).toBeNull();
    expect(screen.queryByText("reply required")).toBeNull();
  });

  it("renders a row persisted before the parts model (content only)", () => {
    render(
      <UserMessageParts
        message={{
          role: "user",
          mode: "act",
          content: "[From user | mode: act]\nlegacy body",
        }}
      />,
    );

    expect(screen.getByText("legacy body")).toBeInTheDocument();
  });

  it("renders the row's attachments exactly once", () => {
    render(
      <UserMessageParts
        message={outputRow({
          parts: [
            prosePart(),
            {
              kind: "media",
              toolCallId: "c1",
              modality: "image",
              mediaType: "image/png",
              bytes: 68,
              data: PNG,
              path: "shot.png",
            },
            { kind: "text", text: OUTPUT },
          ],
          commandOutputParts: [2],
        })}
      />,
    );

    expect(screen.getAllByTestId("tool-media-image")).toHaveLength(1);
    // The media part sits between the two text parts; the output's index is
    // still its own index in `parts`.
    expect(document.querySelector("pre").textContent).toBe(OUTPUT);
  });

  it("throws when commandOutputParts names a part that is not text", () => {
    // The render itself throws: a wrong `commandOutputParts` is a server bug
    // and the row must not fall back to rendering the command's output as
    // prose.
    expect(() =>
      render(
        <UserMessageParts
          message={{
            role: "user",
            parts: [
              { kind: "text", text: "prose" },
              {
                kind: "media",
                toolCallId: "c1",
                modality: "image",
                data: PNG,
              },
            ],
            commandOutputParts: [1],
          }}
        />,
      ),
    ).toThrow(/commandOutputParts names parts\[1\], which is not a text part/);
  });
});
