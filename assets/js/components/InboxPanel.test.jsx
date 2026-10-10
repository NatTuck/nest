/**
 * InboxPanel tests: the queued-message count and the expandable contents
 * viewer (covering all four entry kinds), plus the reply debt the agent
 * owes and the explicit marker a missing `owedReplies` must render.
 */

import { describe, it, beforeEach, expect, vi } from "vitest";
import { render, screen, fireEvent, cleanup } from "@testing-library/react";
import { InboxPanel } from "./InboxPanel";
import { useStore } from "../store";

const NAME = "agent-1";
// The signed-in user, used to tell "you" from another human.
const ME = "bob";

function seed(cache) {
  useStore.setState({ agentsCache: { [NAME]: cache } });
}

describe("InboxPanel", () => {
  beforeEach(() => {
    cleanup();
    useStore.setState({ agentsCache: {}, currentUser: { username: ME } });
  });

  it("renders nothing before the agent has a cache entry", () => {
    // The join happens in an effect after the first commit, so on a first
    // visit there is no cache entry at all. That is not a payload that
    // omitted the debt, and it must not flash the missing-value marker.
    expect(useStore.getState().agentsCache[NAME]).toBeUndefined();

    const { container } = render(<InboxPanel name={NAME} />);

    expect(container.firstChild).toBeNull();
    expect(screen.queryByTestId("inbox-owed-replies-missing")).toBeNull();
    expect(screen.queryByTestId("inbox-owed-replies")).toBeNull();
  });

  it("renders nothing when the inbox is empty and nothing is owed", () => {
    seed({ inbox: [], pendingMessageCount: 0, owedReplies: [] });

    const { container } = render(<InboxPanel name={NAME} />);

    expect(container.firstChild).toBeNull();
  });

  it("shows the count and reveals each queued message with its source on demand", () => {
    seed({
      inbox: [
        {
          from: "alice",
          content: "first message",
          timestamp: "t1",
          kind: "agent",
          mode: null,
        },
        {
          from: "bob",
          content: "second message",
          timestamp: "t2",
          kind: "user",
          mode: "build",
        },
      ],
      pendingMessageCount: 2,
      owedReplies: [],
    });

    render(<InboxPanel name={NAME} />);

    expect(
      screen.getByText("2 messages waiting to be delivered"),
    ).toBeInTheDocument();
    // Contents are hidden until expanded.
    expect(screen.queryByText("first message")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button"));

    expect(screen.getByText("From agent alice")).toBeInTheDocument();
    expect(screen.getByText("first message")).toBeInTheDocument();
    // The human entry's `from` is the signed-in user (ME), so it reads
    // as yours and carries the mode it will be delivered with.
    expect(screen.getByText("From you")).toBeInTheDocument();
    expect(screen.getByText("Mode: build")).toBeInTheDocument();
    expect(screen.getByText("second message")).toBeInTheDocument();
  });

  it("labels a queued human entry by sender instead of assuming it is yours", () => {
    seed({
      inbox: [
        {
          from: "carol",
          content: "from carol",
          timestamp: "t1",
          kind: "user",
          mode: "plan",
        },
        {
          from: "",
          content: "empty sender",
          timestamp: "t2",
          kind: "user",
          mode: "build",
        },
        {
          content: "missing sender",
          timestamp: "t3",
          kind: "user",
          mode: "build",
        },
      ],
      pendingMessageCount: 3,
      owedReplies: [],
    });

    const { unmount } = render(<InboxPanel name={NAME} />);
    fireEvent.click(screen.getByRole("button"));

    expect(screen.getByText("From carol the user")).toBeInTheDocument();
    // An empty `from` and a missing one both say so explicitly; neither
    // may be shown as "From you".
    expect(screen.getAllByText("From an unidentified user")).toHaveLength(2);
    expect(screen.queryByText("From you")).toBeNull();
    unmount();

    // With nobody signed in there is no username to match against, so
    // the sender is still named rather than guessed at.
    useStore.setState({ currentUser: null });
    render(<InboxPanel name={NAME} />);
    fireEvent.click(screen.getByRole("button"));

    expect(screen.getByText("From carol the user")).toBeInTheDocument();
  });

  it("shows an explicit marker when a queued human message has no mode", () => {
    seed({
      inbox: [
        {
          from: "bob",
          content: "no mode here",
          timestamp: "t1",
          kind: "user",
          mode: null,
        },
      ],
      pendingMessageCount: 1,
      owedReplies: [],
    });

    render(<InboxPanel name={NAME} />);
    fireEvent.click(screen.getByRole("button"));

    // Never silently imply a default: say the data is missing.
    expect(screen.getByText("Mode: (missing)")).toBeInTheDocument();
  });

  it("calls out entries the server did not fully identify", () => {
    seed({
      inbox: [
        {
          from: "carol",
          content: "mystery",
          timestamp: "t1",
          kind: "ghost",
          mode: null,
        },
        {
          content: "no sender at all",
          timestamp: "t2",
          kind: "ghost",
          mode: null,
        },
        {
          from: null,
          content: "nil agent sender",
          timestamp: "t3",
          kind: "agent",
          mode: null,
        },
      ],
      pendingMessageCount: 3,
      owedReplies: [],
    });

    render(<InboxPanel name={NAME} />);
    fireEvent.click(screen.getByRole("button"));

    // Never silently claim provenance the server did not state, and
    // never render a literal `null`/`undefined` as a name.
    expect(
      screen.getByText("From carol (unknown kind: ghost)"),
    ).toBeInTheDocument();
    expect(
      screen.getByText("From an unidentified sender (unknown kind: ghost)"),
    ).toBeInTheDocument();
    expect(screen.getByText("From an unidentified agent")).toBeInTheDocument();
  });

  it("labels a peer query and never frames a runtime notice as a peer's words", () => {
    seed({
      inbox: [
        {
          from: "alice",
          content: "review my diff",
          timestamp: "t1",
          kind: "query",
          mode: null,
        },
        {
          from: "",
          content: "unnamed query",
          timestamp: "t2",
          kind: "query",
          mode: null,
        },
        {
          from: "dave",
          content: "agent dave never replied to your query",
          timestamp: "t3",
          kind: "notice",
          mode: null,
        },
        {
          content: "a notice with no peer named",
          timestamp: "t4",
          kind: "notice",
          mode: null,
        },
      ],
      pendingMessageCount: 4,
      owedReplies: [],
    });

    render(<InboxPanel name={NAME} />);
    fireEvent.click(screen.getByRole("button"));

    expect(screen.getByText("Query from agent alice")).toBeInTheDocument();
    expect(
      screen.getByText("Query from an unidentified agent"),
    ).toBeInTheDocument();
    // A *queued* query has not been delivered, so no debt exists yet: the
    // label must not claim one. The debt row (empty here) is the only
    // place the obligation is stated.
    expect(screen.queryByText(/reply owed/)).toBeNull();
    expect(screen.queryByTestId("inbox-owed-replies")).toBeNull();
    // The runtime generated the notice, so `dave` is named as the
    // subject and never as the speaker.
    expect(
      screen.getByText("Runtime notice (about agent dave)"),
    ).toBeInTheDocument();
    expect(screen.getByText("Runtime notice")).toBeInTheDocument();
    expect(screen.queryByText("From agent dave")).toBeNull();
  });

  it("reads a child's completion as the child's words and its notice as the runtime's", () => {
    seed({
      inbox: [
        {
          from: "worker-1",
          content: "done: 17 primes",
          timestamp: "t1",
          kind: "agent",
          mode: null,
        },
        {
          from: "worker-2",
          content:
            "Child agent worker-2 was stopped before it answered: :stopped",
          timestamp: "t2",
          kind: "notice",
          mode: null,
        },
      ],
      pendingMessageCount: 2,
      owedReplies: [],
    });

    render(<InboxPanel name={NAME} />);
    fireEvent.click(screen.getByRole("button"));

    // A completed child delivers its own words, so it is named as a peer.
    expect(screen.getByText("From agent worker-1")).toBeInTheDocument();
    // A stopped child is a runtime notice *about* that child: the child
    // never said it, so it must not be framed as the child speaking.
    expect(
      screen.getByText("Runtime notice (about agent worker-2)"),
    ).toBeInTheDocument();
    expect(screen.queryByText("From agent worker-2")).toBeNull();
  });

  it("uses a singular label for one message", () => {
    seed({
      inbox: [
        {
          from: "alice",
          content: "hi",
          timestamp: "t1",
          kind: "agent",
          mode: null,
        },
      ],
      pendingMessageCount: 1,
      owedReplies: [],
    });

    render(<InboxPanel name={NAME} />);

    expect(
      screen.getByText("1 message waiting to be delivered"),
    ).toBeInTheDocument();
  });

  it("shows the reply debt without expanding the queue", () => {
    seed({
      inbox: [
        {
          from: "alice",
          content: "first message",
          timestamp: "t1",
          kind: "agent",
          mode: null,
        },
      ],
      pendingMessageCount: 1,
      owedReplies: ["alice", "carol"],
    });

    render(<InboxPanel name={NAME} />);

    // A debt is why the agent has not gone idle, so it must be visible
    // without a click.
    expect(screen.getByTestId("inbox-owed-replies")).toHaveTextContent(
      "Owes a reply to alice, carol",
    );
    expect(screen.queryByText("first message")).not.toBeInTheDocument();
  });

  it("shows the reply debt even when nothing is queued", () => {
    seed({ inbox: [], pendingMessageCount: 0, owedReplies: ["alice"] });

    render(<InboxPanel name={NAME} />);

    expect(screen.getByTestId("inbox-owed-replies")).toHaveTextContent(
      "Owes a reply to alice",
    );
    // Nothing to expand, so there is no toggle.
    expect(screen.queryByRole("button")).toBeNull();
  });

  it("renders an explicit marker when the payload omits owedReplies", () => {
    seed({ inbox: [], pendingMessageCount: 0 });

    render(<InboxPanel name={NAME} />);

    // The wire contract always carries the list, so an absent value is a
    // contract violation: say so rather than rendering "nothing owed".
    expect(screen.getByTestId("inbox-owed-replies-missing")).toHaveTextContent(
      "Owes a reply to: (missing from the status payload)",
    );
    expect(screen.queryByTestId("inbox-owed-replies")).toBeNull();
  });

  it("renders the same missing marker for a non-list owedReplies", () => {
    seed({ inbox: [], pendingMessageCount: 0, owedReplies: "alice" });

    render(<InboxPanel name={NAME} />);

    expect(
      screen.getByTestId("inbox-owed-replies-missing"),
    ).toBeInTheDocument();
  });

  it("fetches the list when expanded", () => {
    const onFetch = vi.fn();
    seed({
      inbox: [
        {
          from: "alice",
          content: "hi",
          timestamp: "t1",
          kind: "agent",
          mode: null,
        },
      ],
      pendingMessageCount: 2,
      owedReplies: [],
    });

    render(<InboxPanel name={NAME} onFetch={onFetch} />);
    expect(onFetch).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button"));
    expect(onFetch).toHaveBeenCalledTimes(1);
  });
});
