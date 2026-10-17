/**
 * A cold agent page must not spin React's store subscription.
 *
 * `ChatPage` derives its header bundle with `useShallow`, and zustand v5 hands
 * the selector straight to React as `useSyncExternalStore`'s `getSnapshot`.
 * React calls it repeatedly and compares with `Object.is`, so any fallback
 * allocated inside the selector (a fresh `[]` for an agent whose cache has no
 * `modes` yet) makes the snapshot look changed every call and drives an
 * infinite re-render loop (React error #185). The other `ChatPage.test.jsx`
 * file mocks `useStore` itself, so it cannot observe that; this one uses the
 * real store.
 */

import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";

vi.mock("../channels", async () => {
  const actual = await vi.importActual("../channels");
  return {
    ...actual,
    joinAgent: vi.fn(),
    leaveAgent: vi.fn(),
  };
});

// The loading view has no scroll container, and the real hook's layout
// effects make state updates that would need an `act` wrapper here. This test
// is about the store subscription, so use the same stable stub as
// `ChatPage.test.jsx`.
vi.mock("../hooks/useScrollToBottom", () => ({
  useScrollToBottom: () => ({
    isAtBottom: true,
    hasNewContent: false,
    jumpToBottom: vi.fn(),
  }),
}));

import { ChatPage } from "./ChatPage";
import { useStore } from "../store";
import { joinAgent, leaveAgent } from "../channels";

function renderColdAgent(name = "cold-agent") {
  return render(
    <MemoryRouter initialEntries={[`/space/my-space/agent/${name}`]}>
      <Routes>
        <Route path="/space/:spaceSlug/agent/:name" element={<ChatPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  useStore.getState()._reset();
  useStore.setState({
    spaces: [{ id: 1, slug: "my-space", name: "My Space" }],
  });
  window.NEST_CONFIG = { host: "vampire" };
  joinAgent.mockClear();
  leaveAgent.mockClear();
});

describe("ChatPage with a cold agent cache", () => {
  it("renders the loading view without looping on the store snapshot", () => {
    renderColdAgent();

    expect(screen.getByLabelText("Loading cold-agent")).toBeInTheDocument();
    expect(joinAgent).toHaveBeenCalledWith("cold-agent", 1);
  });
});
