/**
 * Sidebar switch feedback (#52).
 *
 * A click on a tree row can read as "nothing happened" for two reasons this
 * file pins down: the sidebar re-rendering — and so rebuilding every space's
 * agent tree — on store writes that have nothing to do with it, of which a
 * cold agent's cache produces hundreds (one per `chat:sync` batch, one per
 * streamed delta); and the clicked row giving no sign that it is the row being
 * joined, while the server has not yet said anything about it.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { render, screen, act } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";

import { Sidebar } from "./Sidebar";
import { useStore } from "../store";
import { buildAgentTree } from "../utils/agentTree";
import { joinLobby } from "../channels";
import {
  resetMockSocket,
  setNextJoinResult,
  connectSocket,
} from "../__mocks__/phoenix";

// Count the tree rebuilds without changing what the builder does: the thing
// under test is how often the sidebar re-renders, and `buildAgentTree` runs
// once per `SpaceRow` per render.
vi.mock("../utils/agentTree", async () => {
  const actual = await vi.importActual("../utils/agentTree");
  return { ...actual, buildAgentTree: vi.fn(actual.buildAgentTree) };
});

const AGENT = "alpha";
const OTHER = "bravo";

function agentRow(name) {
  return {
    name,
    parentId: null,
    parentName: null,
    depth: 0,
    space_id: 1,
    status: "idle",
  };
}

function seedStore() {
  useStore.setState({
    agents: [agentRow(AGENT), agentRow(OTHER)],
    archivedAgents: [],
    spaces: [{ id: 1, slug: "my-space", name: "My Space" }],
    expandedTreeNodes: {},
  });
}

function renderSidebar(route = "/space/my-space") {
  return render(
    <MemoryRouter initialEntries={[route]}>
      <Sidebar />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  resetMockSocket();
  // Mirror `Sidebar.test.jsx`: the channel module is the real one, so the
  // socket has to be connected through the mock before the tree renders.
  connectSocket();
  setNextJoinResult("lobby", {});
  joinLobby();
  seedStore();
});

afterEach(() => {
  resetMockSocket();
});

describe("Sidebar re-renders", () => {
  it("leaves the tree alone for writes that do not touch its data", () => {
    renderSidebar();

    const built = buildAgentTree.mock.calls.length;
    expect(built).toBeGreaterThan(0);

    // The cache writes a cold switch performs in bulk. Each replaces the
    // agent's cache entry; none of them changes the agent list, the space
    // list, or the tree's disclosure.
    act(() => {
      useStore.getState().setAgentConnecting(AGENT);
    });
    expect(buildAgentTree.mock.calls.length).toBe(built);

    let delta;
    act(() => {
      delta = useStore.getState().addChatDelta(AGENT, {
        index: 5,
        content: "hi",
        charsStart: 0,
        charsEnd: 2,
      });
    });
    // The write landed, so the assertions below are about the sidebar rather
    // than about a write that quietly did nothing.
    expect(delta.applied).toBe(true);
    expect(buildAgentTree.mock.calls.length).toBe(built);

    act(() => {
      useStore.getState().syncAgentMessages(AGENT, {
        messages: [
          { index: 0, role: "system", parts: [{ kind: "text", text: "sys" }] },
        ],
        status: "idle",
      });
    });
    expect(useStore.getState().agentsCache[AGENT].messages).toHaveLength(1);
    expect(buildAgentTree.mock.calls.length).toBe(built);

    act(() => {
      useStore.getState().addChatMessage(AGENT, {
        index: 1,
        role: "user",
        parts: [{ kind: "text", text: "hello" }],
      });
    });
    expect(useStore.getState().agentsCache[AGENT].messages).toHaveLength(2);
    expect(buildAgentTree.mock.calls.length).toBe(built);

    act(() => {
      useStore.setState({ invites: [] });
    });
    expect(buildAgentTree.mock.calls.length).toBe(built);

    // Control: a write the sidebar does depend on has to rebuild the tree, or
    // every assertion above would also hold for a counter that never moves.
    act(() => {
      useStore.setState({ agents: [agentRow(AGENT)] });
    });
    expect(buildAgentTree.mock.calls.length).toBeGreaterThan(built);
  });
});

describe("Sidebar click feedback", () => {
  it("shows the join in flight on every row that is joining, and only those", () => {
    act(() => {
      // Both agents are mid-join — what a user who clicks through two rows
      // quickly leaves behind.
      useStore.getState().setAgentConnecting(AGENT);
      useStore.getState().setAgentConnecting(OTHER);
    });

    renderSidebar(`/space/my-space/agent/${AGENT}`);

    // Both rows really are joining, so both say so, whichever one the route is
    // on: the state belongs to the row's channel, not to the selection.
    expect(screen.getAllByLabelText("Connecting")).toHaveLength(2);
    expect(screen.queryAllByLabelText("Idle")).toHaveLength(0);

    // The first join lands: that row goes back to reporting the agent's
    // status, and the other one keeps saying it is still joining.
    act(() => {
      useStore.getState().setAgentConnected(AGENT, {
        status: "idle",
        messages: [],
        lastCompactionIndex: -1,
        compactionCount: 0,
      });
    });

    expect(screen.getAllByLabelText("Connecting")).toHaveLength(1);
    expect(screen.getAllByLabelText("Idle")).toHaveLength(1);

    act(() => {
      useStore.getState().setAgentConnected(OTHER, {
        status: "idle",
        messages: [],
        lastCompactionIndex: -1,
        compactionCount: 0,
      });
    });

    expect(screen.queryAllByLabelText("Connecting")).toHaveLength(0);
    expect(screen.getAllByLabelText("Idle")).toHaveLength(2);

    // With no cache entry at all, only the row the route selects is joining:
    // the other was never asked for, so it keeps the status the list reports.
    // (Before the join effect has run, even the selected row has no entry.)
    act(() => {
      useStore.setState({ agentsCache: {} });
    });

    expect(screen.getAllByLabelText("Connecting")).toHaveLength(1);
    expect(screen.getAllByLabelText("Idle")).toHaveLength(1);
  });
});
