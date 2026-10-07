/**
 * InboxPanel tests: the queued-message count and the expandable contents
 * viewer, covering both sources (`agents-send` and a human's mid-turn
 * send).
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

  it("renders nothing when the inbox is empty", () => {
    seed({ inbox: [], pendingMessageCount: 0 });

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
    });

    render(<InboxPanel name={NAME} />);

    expect(
      screen.getByText("1 message waiting to be delivered"),
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
    });

    render(<InboxPanel name={NAME} onFetch={onFetch} />);
    expect(onFetch).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button"));
    expect(onFetch).toHaveBeenCalledTimes(1);
  });
});
