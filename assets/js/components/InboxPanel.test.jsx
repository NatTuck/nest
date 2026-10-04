/**
 * InboxPanel tests: the queued async agent-to-agent message count and
 * the expandable contents viewer.
 */

import { describe, it, beforeEach, expect, vi } from "vitest";
import { render, screen, fireEvent, cleanup } from "@testing-library/react";
import { InboxPanel } from "./InboxPanel";
import { useStore } from "../store";

const NAME = "agent-1";

function seed(cache) {
  useStore.setState({ agentsCache: { [NAME]: cache } });
}

describe("InboxPanel", () => {
  beforeEach(() => {
    cleanup();
    useStore.setState({ agentsCache: {} });
  });

  it("renders nothing when the inbox is empty", () => {
    seed({ inbox: [], pendingMessageCount: 0 });

    const { container } = render(<InboxPanel name={NAME} />);

    expect(container.firstChild).toBeNull();
  });

  it("shows the count and reveals the queued senders and contents on demand", () => {
    seed({
      inbox: [
        { from: "alice", content: "first message", timestamp: "t1" },
        { from: "bob", content: "second message", timestamp: "t2" },
      ],
      pendingMessageCount: 2,
    });

    render(<InboxPanel name={NAME} />);

    expect(
      screen.getByText("2 messages waiting from other agents"),
    ).toBeInTheDocument();
    // Contents are hidden until expanded.
    expect(screen.queryByText("first message")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button"));

    expect(screen.getByText("From alice")).toBeInTheDocument();
    expect(screen.getByText("first message")).toBeInTheDocument();
    expect(screen.getByText("From bob")).toBeInTheDocument();
    expect(screen.getByText("second message")).toBeInTheDocument();
  });

  it("uses a singular label for one message", () => {
    seed({
      inbox: [{ from: "alice", content: "hi", timestamp: "t1" }],
      pendingMessageCount: 1,
    });

    render(<InboxPanel name={NAME} />);

    expect(
      screen.getByText("1 message waiting from other agents"),
    ).toBeInTheDocument();
  });

  it("fetches the list when expanded", () => {
    const onFetch = vi.fn();
    seed({
      inbox: [{ from: "alice", content: "hi", timestamp: "t1" }],
      pendingMessageCount: 2,
    });

    render(<InboxPanel name={NAME} onFetch={onFetch} />);
    expect(onFetch).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button"));
    expect(onFetch).toHaveBeenCalledTimes(1);
  });
});
