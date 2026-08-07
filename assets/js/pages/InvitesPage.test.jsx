/**
 * Tests for InvitesPage.
 *
 * Covers:
 *  - Bounces to /login when the WS isn't connected.
 *  - Renders the empty state when the store has no invites.
 *  - Renders the populated table (status badges, formatted
 *    dates, token column with copy button, revoke button on
 *    active rows).
 *  - Clicking "Create new invite" pushes `create_invite`
 *    via the channel.
 *  - Clicking "Revoke" pushes `revoke_invite` with the id.
 *  - Server-reported errors surface inline via the store's
 *    `invitesError` slice.
 *
 * The component is a pure renderer over `useStore.invites`.
 * The store is populated by the lobby's `init` payload; in
 * tests we seed `invites` / `invitesError` directly via
 * `useStore.setState`. Channel calls are mocked so the
 * component's click handlers exercise the wire shape
 * without touching the Phoenix client.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { screen, fireEvent, act } from "@testing-library/react";

import { InvitesPage } from "./InvitesPage";
import { useStore } from "../store";
import { renderWithRouter } from "../test/render_with_router";

vi.mock("../channels", async () => {
  const actual = await vi.importActual("../channels");
  return {
    ...actual,
    createInvite: vi.fn(),
    revokeInvite: vi.fn(),
  };
});

import { createInvite, revokeInvite } from "../channels";

async function renderPage() {
  return renderWithRouter(<InvitesPage />, {
    route: "/invites",
    routes: [
      { path: "/invites", element: <InvitesPage /> },
      { path: "/login", element: <div>Sign in</div> },
    ],
  });
}

function setStore(patch) {
  // Wrap in `act` so any Zustand subscriber re-renders
  // land inside an act boundary. The setStore calls in
  // beforeEach happen before render so no components
  // are subscribed yet, but the afterEach `_reset()` can
  // fire while the previous test's components are
  // still tearing down — wrapping both sides keeps the
  // warning-free path consistent.
  act(() => {
    useStore.setState(patch);
  });
}

describe("InvitesPage", () => {
  beforeEach(() => {
    createInvite.mockReset();
    revokeInvite.mockReset();
    setStore({
      isConnected: true,
      invites: [],
      invitesError: null,
    });
  });

  afterEach(() => {
    act(() => {
      useStore.getState()._reset();
    });
    vi.clearAllMocks();
  });

  it("bounces to /login when the WS is not connected", async () => {
    setStore({ isConnected: false });

    await renderPage();

    expect(screen.getByText(/sign in/i)).toBeInTheDocument();
  });

  it("renders the empty state when there are no invites", async () => {
    await renderPage();

    expect(screen.getByText(/no invites yet/i)).toBeInTheDocument();
  });

  it("renders the populated table with status badges and formatted dates", async () => {
    setStore({
      invites: [
        {
          id: 1,
          token: "tok-active",
          inserted_at: "2026-08-01T00:00:00Z",
          expires_at: "2026-09-01T00:00:00Z",
          used_at: null,
          revoked_at: null,
        },
        {
          id: 2,
          token: "tok-revoked",
          inserted_at: "2026-08-02T00:00:00Z",
          expires_at: "2026-09-02T00:00:00Z",
          used_at: null,
          revoked_at: "2026-08-03T00:00:00Z",
        },
        {
          id: 3,
          token: "tok-used",
          inserted_at: "2026-08-04T00:00:00Z",
          expires_at: "2026-09-04T00:00:00Z",
          used_at: "2026-08-05T00:00:00Z",
          revoked_at: null,
        },
        {
          id: 4,
          token: "tok-expired",
          inserted_at: "2026-08-06T00:00:00Z",
          expires_at: "2020-01-01T00:00:00Z",
          used_at: null,
          revoked_at: null,
        },
      ],
    });

    await renderPage();

    expect(screen.getByText("active")).toBeInTheDocument();
    expect(screen.getByText("revoked")).toBeInTheDocument();
    expect(screen.getByText("used")).toBeInTheDocument();
    expect(screen.getByText("expired")).toBeInTheDocument();
  });

  it("renders the token column for every invite", async () => {
    setStore({
      invites: [
        {
          id: 1,
          token: "first-token-abc",
          inserted_at: "2026-08-01T00:00:00Z",
          expires_at: "2026-09-01T00:00:00Z",
          used_at: null,
          revoked_at: null,
        },
        {
          id: 2,
          token: "second-token-xyz",
          inserted_at: "2026-08-02T00:00:00Z",
          expires_at: "2026-09-02T00:00:00Z",
          used_at: null,
          revoked_at: null,
        },
      ],
    });

    await renderPage();

    expect(screen.getByText("first-token-abc")).toBeInTheDocument();
    expect(screen.getByText("second-token-xyz")).toBeInTheDocument();
    // Each row also gets a copy button. The aria-label is
    // "Copy invite token" before any copy happens.
    expect(
      screen.getAllByRole("button", { name: /copy invite token/i }),
    ).toHaveLength(2);
  });

  it("calls createInvite when the create button is clicked", async () => {
    await renderPage();

    fireEvent.click(screen.getByRole("button", { name: /create new invite/i }));

    expect(createInvite).toHaveBeenCalledTimes(1);
  });

  it("clears a prior invitesError when create is clicked", async () => {
    setStore({ invitesError: "old error" });

    await renderPage();

    expect(screen.getByText(/old error/i)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /create new invite/i }));

    expect(screen.queryByText(/old error/i)).toBeNull();
    expect(createInvite).toHaveBeenCalledTimes(1);
  });

  it("calls revokeInvite with the invite id when Revoke is clicked", async () => {
    setStore({
      invites: [
        {
          id: 42,
          token: "tok-42",
          inserted_at: "2026-08-01T00:00:00Z",
          expires_at: "2026-09-01T00:00:00Z",
          used_at: null,
          revoked_at: null,
        },
      ],
    });

    await renderPage();

    fireEvent.click(screen.getByRole("button", { name: /revoke/i }));

    expect(revokeInvite).toHaveBeenCalledWith(42);
  });

  it("does not show Revoke on used or revoked rows", async () => {
    setStore({
      invites: [
        {
          id: 1,
          token: "tok-active",
          inserted_at: "2026-08-01T00:00:00Z",
          expires_at: "2026-09-01T00:00:00Z",
          used_at: null,
          revoked_at: null,
        },
        {
          id: 2,
          token: "tok-used",
          inserted_at: "2026-08-02T00:00:00Z",
          expires_at: "2026-09-02T00:00:00Z",
          used_at: "2026-08-03T00:00:00Z",
          revoked_at: null,
        },
        {
          id: 3,
          token: "tok-revoked",
          inserted_at: "2026-08-04T00:00:00Z",
          expires_at: "2026-09-04T00:00:00Z",
          used_at: null,
          revoked_at: "2026-08-05T00:00:00Z",
        },
      ],
    });

    await renderPage();

    // Exactly one Revoke button — only on the active row.
    expect(screen.getAllByRole("button", { name: /revoke/i })).toHaveLength(1);
  });

  it("surfaces a 'too_many_invites' error from the store", async () => {
    setStore({ invitesError: "too_many_invites" });

    await renderPage();

    expect(screen.getByText(/too_many_invites/i)).toBeInTheDocument();
  });
});
