import { describe, expect, it } from "vitest";
import { agentHeaderMode, stripAgentHeaderMode } from "./agentHeader.js";

describe("agentHeaderMode", () => {
  it("reads the mode out of a peer delivery's header", () => {
    expect(
      agentHeaderMode('[Message from agent "peer" | mode: act]\nbody'),
    ).toBe("act");
    expect(
      agentHeaderMode('[Message from agent "peer" | mode: plan]\nbody'),
    ).toBe("plan");
  });

  it("is null when there is no header, no clause, or no text", () => {
    // A row persisted before the header carried a mode.
    expect(agentHeaderMode('[Message from agent "peer"]\nbody')).toBe(null);
    // A human's own message is labelled differently and has no header.
    expect(
      agentHeaderMode('[mode: act]\n[Message from the user "me"]\nhi'),
    ).toBe(null);
    expect(agentHeaderMode("plain body")).toBe(null);
    expect(agentHeaderMode(null)).toBe(null);
  });

  it("finds the header behind a re-delivery tag", () => {
    // `Inbox.Render` puts the re-delivery marker on the line in front of the
    // body it wraps, so the header is not the first line of the content.
    expect(
      agentHeaderMode(
        '[re-delivery: 3]\n[Message from agent "peer" | mode: plan]\nbody',
      ),
    ).toBe("plan");
  });
});

describe("stripAgentHeaderMode", () => {
  it("removes the clause the mode badge already shows", () => {
    expect(
      stripAgentHeaderMode(
        '[Message from agent "peer" | mode: act]\nbody',
        "act",
      ),
    ).toBe('[Message from agent "peer"]\nbody');
  });

  it("leaves a header that disagrees with the message's mode alone", () => {
    // `mode` is untrusted, so the clause is only removed when it agrees. A
    // disagreement is a bug or an older row; it stays visible.
    expect(
      stripAgentHeaderMode(
        '[Message from agent "peer" | mode: plan]\nbody',
        "act",
      ),
    ).toBe('[Message from agent "peer" | mode: plan]\nbody');
  });

  it("leaves a header with no clause alone", () => {
    expect(
      stripAgentHeaderMode('[Message from agent "peer"]\nbody', "act"),
    ).toBe('[Message from agent "peer"]\nbody');
    expect(stripAgentHeaderMode("[Message from agent]\nbody", "act")).toBe(
      "[Message from agent]\nbody",
    );
  });

  it("strips only the header line, and only the header's own clause", () => {
    const text =
      '[re-delivery: 1]\n[Message from agent "peer" | mode: plan]\n' +
      "the body mentions | mode: plan] as text\n\n" +
      '[Message from agent "other" | mode: plan]\nsecond';

    expect(stripAgentHeaderMode(text, "plan")).toBe(
      '[re-delivery: 1]\n[Message from agent "peer"]\n' +
        "the body mentions | mode: plan] as text\n\n" +
        '[Message from agent "other"]\nsecond',
    );
  });

  it("never strips a human message's own label", () => {
    const text = '[mode: act]\n[Message from the user "me"]\nhello';
    expect(stripAgentHeaderMode(text, "act")).toBe(text);
  });

  it("is a no-op without a mode, and for non-strings", () => {
    const text = '[Message from agent "peer" | mode: act]\nbody';
    expect(stripAgentHeaderMode(text, "")).toBe(text);
    expect(stripAgentHeaderMode(text, null)).toBe(text);
    expect(stripAgentHeaderMode(text, undefined)).toBe(text);
    expect(stripAgentHeaderMode(null, "act")).toBe(null);
  });
});
