/**
 * The `[From … | mode: …]` header's grammar, and the affordances that make its
 * three facts visible.
 *
 * ## Why the header is framing at all
 *
 * The server writes one of these at the head of **every** body
 * (`Nest.Messages.Header`), and it states exactly three facts:
 *
 *     [From user @nat, agents-send reply required | mode: act]
 *      └──── sender ────┘ └─── reply required ───┘ └── mode ──┘
 *
 * A marker is wire framing only when the fact it carries has a home elsewhere
 * in the row. The mode has one (the row's badge). The sender and the reply
 * marker did **not** — the old UI deleted the whole line on the stated ground
 * that "the sender is the row's own author", which is false for a drained batch
 * (one user row, one body per entry, each with its own sender), for a peer's
 * note, for a runtime notice and for an `agents-send` kickoff — and it drew
 * every one of them as the human's own "You". So this module gives the sender
 * and the reply marker their own home: `rowSenders`/`rowAppearance` for the
 * row, and `splitFraming` (`utils/stripHeader.js`) removes a header line only
 * after this module has parsed it.
 *
 * ## The grammar
 *
 * `Nest.Messages.Header.line/3` writes these seven shapes, and they are all
 * this parser accepts:
 *
 *     [From user | mode: act]
 *     [From user @nat | mode: act]
 *     [From user @nat, agents-send reply required | mode: act]
 *     [From agent crazy-dolphin | mode: plan]
 *     [From agent crazy-dolphin, agents-send reply required | mode: plan]
 *     [From nest runtime | mode: act]
 *     [From nest runtime | mode: compact]
 *
 * A `who` clause this build does not write (a sender class it does not know)
 * is not a header: it parses to `null` and its line stays visible, because
 * hiding a line we cannot explain is exactly what the rule forbids.
 *
 * ## Rows recorded before the header
 *
 * The header replaced three markers, and an old transcript still carries them.
 * `rowSenders` reads two of them so an archived row keeps its sender: the
 * `[Message from agent "name"]` label, and the `[nest notice]` marker (the
 * runtime's own words).
 */

import { commandOutputIndexes } from "./commandOutput.js";

// The header's opening. The server's copy of the format lives in
// `Nest.Messages.Header`; the duplication is deliberate — the browser bundle
// cannot read Elixir — and the two are kept in step by the header tests on each
// side.
const HEADER_OPEN = "[From ";

// The old agent label's opening. Kept here, with the rest of the wire strings,
// and re-exported by `stripHeader.js` for `agentHeader.js`'s legacy clause
// stripper.
export const AGENT_LABEL_OPEN = "[Message from agent";

// The retired notice marker, without the trailing newline. Only rows recorded
// before the header carry it.
export const NOTICE_TAG = "[nest notice]";

// The reply marker's clause, as `Nest.Messages.Header.line/3` writes it.
const REPLY_CLAUSE = ", agents-send reply required";

const HEADER_RE =
  /^\[From (.+?)(, agents-send reply required)? \| mode: (.+)\]$/;
const LEGACY_LABEL_RE = /^\[Message from agent\s+"([^"]*)"/;

// The sender kinds, and the appearance each one is drawn with. A sender must
// look the same in the row label, the per-body caption and the avatar, so the
// classes live in one place rather than in each renderer.
const APPEARANCE = {
  human: {
    bubble: "bg-blue-50 border-blue-200",
    avatar: "bg-blue-600 text-white",
  },
  agent: {
    bubble: "bg-indigo-50 border-indigo-200",
    avatar: "bg-indigo-600 text-white",
  },
  runtime: {
    bubble: "bg-gray-100 border-gray-200",
    avatar: "bg-gray-600 text-white",
  },
  multi: {
    bubble: "bg-gray-50 border-gray-300",
    avatar: "bg-gray-600 text-white",
  },
  unknown: {
    bubble: "bg-red-50 border-red-200",
    avatar: "bg-red-600 text-white",
  },
};

/**
 * Parse one line as a header.
 *
 * Returns `null` when the line is not one of the shapes
 * `Nest.Messages.Header.line/3` writes, and otherwise
 * `{sender, replyRequired, mode}` where `sender` is
 * `{kind: "human" | "agent" | "runtime", name}` — `name` is `null` when the
 * header names nobody (`[From user …]`, `[From agent …]`).
 */
export function parseHeaderLine(line) {
  if (typeof line !== "string" || !line.startsWith(HEADER_OPEN)) return null;

  const match = line.match(HEADER_RE);
  if (!match) return null;

  const sender = parseWho(match[1]);
  if (!sender) return null;

  return {
    sender,
    replyRequired: match[2] === REPLY_CLAUSE,
    mode: match[3],
  };
}

function parseWho(who) {
  if (who === "nest runtime") return { kind: "runtime", name: null };
  if (who === "user") return { kind: "human", name: null };
  if (who === "agent") return { kind: "agent", name: null };

  const human = who.match(/^user @(.+)$/);
  if (human) return { kind: "human", name: human[1] };

  const agent = who.match(/^agent (.+)$/);
  if (agent) return { kind: "agent", name: agent[1] };

  return null;
}

/**
 * What a sender is called on screen.
 *
 * A human is shown by the address a reply goes to (`@nat`), not as "You": the
 * row label decides "You" from `origin: "human"`, which is the server saying
 * these are the reader's own words. Everywhere else the sender is a name.
 */
export function senderLabel(sender) {
  switch (sender?.kind) {
    case "human":
      return sender.name ? `@${sender.name}` : "user";
    case "agent":
      return sender.name || "agent";
    case "runtime":
      return "nest runtime";
    default:
      return "unknown sender";
  }
}

/**
 * The classes a sender is drawn with: the row's tint (`bubble`, colour only —
 * each list adds its own layout) and its solid identity badge (`avatar`).
 *
 * `multi` (a row with several senders) and `unknown` (a row with none) are not
 * sender kinds but row shapes; they are in the same table so the row label, the
 * per-body caption and the avatar all draw from one place.
 */
export function senderClass(sender) {
  return APPEARANCE[sender?.kind] ?? APPEARANCE.unknown;
}

/**
 * Every body's sender in a user row, in order, as
 * `{sender, replyRequired, mode}`.
 *
 * A drained batch is one user row holding one body per entry, so the senders
 * are per body, not per row.
 *
 * **Only a recognised head line delimits a body**: a `[From …]` header, a
 * `[Message from agent "…"]` label, or the `[nest notice]` marker. The wire
 * joins two bodies with a blank line, but a body *contains* blank lines too
 * (markdown paragraphs), so from the text alone the two are indistinguishable —
 * counting every line after a blank line would turn one three-paragraph note
 * into "3 notes". A recognised head must also sit at a body head (the first
 * line, or after a blank line), so a header quoted mid-paragraph is content.
 *
 * A row with **no** recognised head has no sender: it reports exactly one
 * `unknown` entry — the row must say so rather than defaulting to "You"
 * (AGENTS.md, UI Transparency), and one entry per paragraph would invent
 * senders that are not there.
 *
 * A `commandOutputParts` part is skipped: it is a body's *tail*, so its first
 * line is bytes the command printed, and reading a sender out of it would
 * invent one.
 */
export function rowSenders(message) {
  const parts = Array.isArray(message?.parts) ? message.parts : [];
  const outputIndexes = commandOutputIndexes(message, parts);

  const heads = [];
  for (const [index, part] of parts.entries()) {
    if (!part || part.kind !== "text" || outputIndexes.has(index)) continue;
    heads.push(...recognisedHeads(part.text));
  }

  // A row persisted before the parts model is one body in `content`.
  if (heads.length === 0 && typeof message?.content === "string") {
    heads.push(...recognisedHeads(message.content));
  }

  if (heads.length === 0) return [unknownSender];

  return heads;
}

// The entry for a row (or a body head) this build cannot attribute. One shape,
// so `rowAppearance` and the captions agree on what "no sender" looks like.
const unknownSender = { sender: null, replyRequired: false, mode: null };

/**
 * The row's label, tint and avatar, and whether the row-level reply chip is
 * needed.
 *
 * `origin: "human"` is the server saying these are the reader's own words, so
 * the row says "You" — but only when every recognised sender is the human too:
 * the marker is stamped from the row's *first* entry, so a mixed batch carries
 * it. Otherwise one sender names the row, several say how many notes it holds
 * (each body's caption carries its own sender), and a row with no sender at all
 * says so explicitly.
 *
 * `replyRequired` is true only for a single-body row: with several bodies the
 * per-body captions carry it, so the row must not repeat it.
 */
export function rowAppearance(message) {
  const senders = rowSenders(message);

  // "You" needs the server's marker **and** every recognised sender to be the
  // human: `MessageList.origin_metadata/1` tags a row from its *first* entry, so
  // a drain batch holding the human's message and a peer's note carries
  // `origin: "human"` — and the shortcut would draw the peer's words as the
  // human's, which is the bug this module exists to fix.
  if (message?.origin === "human" && senders.every(isHumanOrUnknown)) {
    return {
      label: "You",
      ...senderClass({ kind: "human" }),
      avatarLabel: "U",
      replyRequired: false,
    };
  }

  if (senders.length === 1) {
    const { sender, replyRequired } = senders[0];
    return {
      label: senderLabel(sender),
      ...senderClass(sender),
      avatarLabel: avatarLetter(sender),
      replyRequired,
    };
  }

  if (senders.length > 1) {
    return {
      label: `${senders.length} notes`,
      ...senderClass({ kind: "multi" }),
      avatarLabel: String(senders.length),
      replyRequired: false,
    };
  }

  return {
    label: senderLabel(null),
    ...senderClass(null),
    avatarLabel: "?",
    replyRequired: false,
  };
}

function avatarLetter(sender) {
  switch (sender?.kind) {
    case "human":
      return "U";
    case "runtime":
      return "R";
    case "agent":
      return sender.name ? sender.name.slice(0, 1).toUpperCase() : "A";
    default:
      return "?";
  }
}

function isHumanOrUnknown(entry) {
  return entry.sender === null || entry.sender.kind === "human";
}

// The recognised body heads of one text part, in order. Anything else — a
// paragraph, a blank line, a line that merely looks like framing mid-body — is
// body content and delimits nothing.
function recognisedHeads(text) {
  if (typeof text !== "string" || text === "") return [];

  const heads = [];
  let atBodyHead = true;
  for (const line of text.split("\n")) {
    if (line === "") {
      atBodyHead = true;
      continue;
    }

    const head = headOfLine(line);
    if (head && atBodyHead) heads.push(head);
    // The line after a head is that body's content, and so is every line after
    // ordinary text: neither is a body head.
    atBodyHead = false;
  }
  return heads;
}

// One line as a body head, or `null` when it is content. The three recognised
// shapes are the current header and the two markers it replaced.
function headOfLine(line) {
  const header = parseHeaderLine(line);
  if (header) return header;

  const legacy = line.match(LEGACY_LABEL_RE);
  if (legacy) {
    return {
      sender: { kind: "agent", name: legacy[1] || null },
      replyRequired: false,
      mode: null,
    };
  }

  if (line === NOTICE_TAG) {
    return {
      sender: { kind: "runtime", name: null },
      replyRequired: false,
      mode: null,
    };
  }

  return null;
}
