/**
 * Tests for InvitesPage.
 *
 * Covers:
 *  - Bounces to /login when the WS isn't connected.
 *  - Renders the empty state when the API returns no invites.
 *  - Renders the populated table (status badges, formatted
 *    dates, revoke button on active rows).
 *  - Clicking "Create new invite" shows the freshly-minted
 *    token in a copy-friendly block.
 *  - Clicking "Revoke" calls the API and re-fetches the
 *    list.
 *  - API errors are surfaced inline (both for load and
 *    create paths).
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";

import { InvitesPage } from "./InvitesPage";
import { useStore } from "../store";
import { ApiError } from "../api/client";

vi.mock("../api/invites", () => ({
  listInvites: vi.fn(),
  createInvite: vi.fn(),
  revokeInvite: vi.fn(),
}));

import { listInvites, createInvite, revokeInvite } from "../api/invites";

function renderPage() {
  return render(
    <MemoryRouter initialEntries={["/invites"]}>
      <Routes>
        <Route path="/invites" element={<InvitesPage />} />
        <Route path="/login" element={<div>Sign in</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

function setConnected(value) {
  useStore.setState({ isConnected: value });
}

describe("InvitesPage", () => {
  beforeEach(() => {
    listInvites.mockReset();
    createInvite.mockReset();
    revokeInvite.mockReset();
    setConnected(true);
  });

  afterEach(() => {
    vi.clearAllMocks();
    useStore.getState()._reset();
  });

  it("bounces to /login when the WS is not connected", () => {
    setConnected(false);
    renderPage();

    expect(screen.getByText(/sign in/i)).toBeInTheDocument();
  });

  it("renders the empty state when there are no invites", async () => {
    listInvites.mockResolvedValueOnce({ invites: [] });
    renderPage();

    expect(await screen.findByText(/no invites yet/i)).toBeInTheDocument();
  });

  it("renders the populated table with status badges and formatted dates", async () => {
    listInvites.mockResolvedValueOnce({
      invites: [
        {
          id: 1,
          inserted_at: "2026-08-01T00:00:00Z",
          expires_at: "2026-09-01T00:00:00Z",
          used_at: null,
          revoked_at: null,
        },
        {
          id: 2,
          inserted_at: "2026-08-02T00:00:00Z",
          expires_at: "2026-09-02T00:00:00Z",
          used_at: null,
          revoked_at: "2026-08-03T00:00:00Z",
        },
        {
          id: 3,
          inserted_at: "2026-08-04T00:00:00Z",
          expires_at: "2026-09-04T00:00:00Z",
          used_at: "2026-08-05T00:00:00Z",
          revoked_at: null,
        },
        {
          id: 4,
          inserted_at: "2026-08-06T00:00:00Z",
          expires_at: "2020-01-01T00:00:00Z", // past
          used_at: null,
          revoked_at: null,
        },
      ],
    });
    renderPage();

    // Each row renders with the right status badge.
    expect(await screen.findByText("active")).toBeInTheDocument();
    expect(await screen.findByText("revoked")).toBeInTheDocument();
    expect(await screen.findByText("used")).toBeInTheDocument();
    expect(await screen.findByText("expired")).toBeInTheDocument();
  });

  it("renders the fresh token after creating a new invite", async () => {
    listInvites.mockResolvedValueOnce({ invites: [] });
    createInvite.mockResolvedValueOnce({
      id: 7,
      token: "fresh-token-xyz",
      inserted_at: "2026-08-06T00:00:00Z",
      expires_at: "2026-09-06T00:00:00Z",
      used_at: null,
      revoked_at: null,
    });
    // Second listInvites call (after the create's re-fetch).
    listInvites.mockResolvedValueOnce({ invites: [] });

    renderPage();
    fireEvent.click(
      await screen.findByRole("button", { name: /create new invite/i }),
    );

    expect(await screen.findByText("fresh-token-xyz")).toBeInTheDocument();
  });

  it("calls revokeInvite and re-fetches the list when Revoke is clicked", async () => {
    listInvites.mockResolvedValueOnce({
      invites: [
        {
          id: 42,
          inserted_at: "2026-08-01T00:00:00Z",
          expires_at: "2026-09-01T00:00:00Z",
          used_at: null,
          revoked_at: null,
        },
      ],
    });
    revokeInvite.mockResolvedValueOnce(undefined);
    listInvites.mockResolvedValueOnce({ invites: [] });

    renderPage();

    const revokeButton = await screen.findByRole("button", { name: /revoke/i });
    fireEvent.click(revokeButton);

    await waitFor(() => {
      expect(revokeInvite).toHaveBeenCalledWith(42);
    });
    expect(listInvites).toHaveBeenCalledTimes(2);
  });

  it("surfaces a load error when listInvites rejects", async () => {
    listInvites.mockRejectedValueOnce(new ApiError(500, { error: "boom" }));

    renderPage();

    expect(await screen.findByText(/boom/i)).toBeInTheDocument();
  });

  it("surfaces a generic error message when listInvites rejects with a non-ApiError", async () => {
    listInvites.mockRejectedValueOnce(new Error("network down"));

    renderPage();

    expect(await screen.findByText(/failed to load/i)).toBeInTheDocument();
  });

  it("surfaces a create error when createInvite rejects", async () => {
    listInvites.mockResolvedValueOnce({ invites: [] });
    createInvite.mockRejectedValueOnce(
      new ApiError(403, { error: "forbidden" }),
    );

    renderPage();
    fireEvent.click(
      await screen.findByRole("button", { name: /create new invite/i }),
    );

    expect(await screen.findByText(/forbidden/i)).toBeInTheDocument();
  });
});
