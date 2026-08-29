/**
 * Tests for ProvidersPage (admin-only provider/model editor).
 *
 * Covers:
 *  - Redirects non-admins to /spaces.
 *  - Renders the empty state when no providers are configured.
 *  - Renders configured providers from the store.
 *  - "Add provider" appends an editor card.
 *  - Editing a field updates the local draft.
 *  - Save pushes the draft through `saveProviders` and clears
 *    the saving flag on success.
 *  - A save failure surfaces the error inline.
 *  - Re-seeds the draft when the store's provider list changes
 *    (e.g. after a `providers_updated` broadcast).
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { screen, fireEvent, act, waitFor } from "@testing-library/react";

import { ProvidersPage } from "./ProvidersPage";
import { useStore } from "../store";
import { renderWithRouter } from "../test/render_with_router";

vi.mock("../channels", async () => {
  const actual = await vi.importActual("../channels");
  return {
    ...actual,
    saveProviders: vi.fn(),
  };
});

import { saveProviders } from "../channels";

function setStore(patch) {
  act(() => {
    useStore.setState(patch);
  });
}

async function renderPage() {
  return renderWithRouter(<ProvidersPage />, {
    route: "/providers",
    routes: [
      { path: "/providers", element: <ProvidersPage /> },
      { path: "/spaces", element: <div>Spaces index</div> },
    ],
  });
}

function adminUser() {
  return { id: 1, username: "admin", is_admin: true };
}

const sampleProvider = {
  name: "acme",
  base_url: "https://acme.example/v1",
  api_key: "secret",
  protocol: "openai",
  auto_models: false,
  tags: [],
  timeout_seconds: 300,
  default_context_limit: null,
  default_thinking_effort: null,
  probe_base_url: null,
  auto_probe: true,
  models: [
    {
      name: "acme-1",
      context_limit: 128000,
      thinking_effort: null,
      multi_modal: null,
    },
  ],
};

describe("ProvidersPage", () => {
  beforeEach(() => {
    saveProviders.mockReset();
    setStore({
      isConnected: true,
      providers: [],
      currentUser: adminUser(),
    });
  });

  afterEach(() => {
    act(() => {
      useStore.getState()._reset();
    });
    vi.clearAllMocks();
  });

  it("redirects non-admins to /spaces", async () => {
    setStore({ currentUser: { id: 2, username: "bob", is_admin: false } });

    await renderPage();

    expect(screen.getByText(/spaces index/i)).toBeInTheDocument();
  });

  it("redirects to /spaces when currentUser is unset", async () => {
    setStore({ currentUser: null });

    await renderPage();

    expect(screen.getByText(/spaces index/i)).toBeInTheDocument();
  });

  it("renders the empty state when there are no providers", async () => {
    await renderPage();

    expect(screen.getByText(/no providers configured/i)).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /add provider/i }),
    ).toBeInTheDocument();
  });

  it("renders configured providers from the store", async () => {
    setStore({ providers: [sampleProvider] });

    await renderPage();

    expect(screen.getByLabelText(/provider name/i)).toHaveValue("acme");
    expect(screen.getByLabelText("Base URL")).toHaveValue(
      "https://acme.example/v1",
    );
    expect(screen.getByLabelText(/model name/i)).toHaveValue("acme-1");
  });

  it("adds an empty provider editor when Add provider is clicked", async () => {
    await renderPage();

    fireEvent.click(screen.getByRole("button", { name: /add provider/i }));

    expect(screen.getAllByLabelText(/provider name/i)).toHaveLength(1);
  });

  it("updates the local draft when a field is edited", async () => {
    setStore({ providers: [sampleProvider] });

    await renderPage();

    const name = screen.getByLabelText(/provider name/i);
    fireEvent.change(name, { target: { value: "renamed" } });

    expect(name).toHaveValue("renamed");
  });

  it("updates only the matching provider when editing a list", async () => {
    const second = { ...sampleProvider, name: "other" };
    setStore({ providers: [sampleProvider, second] });

    await renderPage();

    // Edit the first provider's name; the second must be untouched.
    const names = screen.getAllByLabelText(/provider name/i);
    fireEvent.change(names[0], { target: { value: "renamed" } });

    expect(names[0]).toHaveValue("renamed");
    expect(names[1]).toHaveValue("other");
  });

  it("saves the draft through saveProviders on Save and clears the saving flag", async () => {
    setStore({ providers: [sampleProvider] });

    saveProviders.mockImplementation((_providers, onOk, _onError) => onOk());

    await renderPage();

    fireEvent.click(screen.getByRole("button", { name: /^save$/i }));

    await waitFor(() => expect(saveProviders).toHaveBeenCalledTimes(1));

    const [providers, onOk] = saveProviders.mock.calls[0];
    expect(providers).toEqual([sampleProvider]);
    expect(typeof onOk).toBe("function");

    // The saving flag clears once onOk fires.
    await waitFor(() =>
      expect(screen.getByRole("button", { name: /^save$/i })).toBeEnabled(),
    );
  });

  it("surfaces a server-provided reason on save failure", async () => {
    setStore({ providers: [sampleProvider] });

    saveProviders.mockImplementation((_providers, _onOk, onError) =>
      onError({ reason: "forbidden" }),
    );

    await renderPage();

    fireEvent.click(screen.getByRole("button", { name: /^save$/i }));

    await waitFor(() =>
      expect(screen.getByText(/forbidden/i)).toBeInTheDocument(),
    );
  });

  it("shows Saving... while a save is in flight", async () => {
    setStore({ providers: [sampleProvider] });

    let resolveOk;
    saveProviders.mockImplementation((_providers, onOk) => {
      resolveOk = onOk;
    });

    await renderPage();

    fireEvent.click(screen.getByRole("button", { name: /^save$/i }));

    await waitFor(() =>
      expect(screen.getByText(/saving\.\.\./i)).toBeInTheDocument(),
    );

    act(() => resolveOk());

    await waitFor(() =>
      expect(screen.getByRole("button", { name: /^save$/i })).toBeEnabled(),
    );
  });

  it("surfaces a save failure inline", async () => {
    setStore({ providers: [sampleProvider] });

    saveProviders.mockImplementation((_providers, _onOk, onError) =>
      onError({}),
    );

    await renderPage();

    fireEvent.click(screen.getByRole("button", { name: /^save$/i }));

    await waitFor(() =>
      expect(
        screen.getByText(/failed to save provider config/i),
      ).toBeInTheDocument(),
    );
  });

  it("re-seeds the draft when the store provider list changes", async () => {
    setStore({ providers: [sampleProvider] });

    const { unmount } = await renderPage();

    setStore({ providers: [{ ...sampleProvider, name: "brand-new" }] });

    expect(screen.getByLabelText(/provider name/i)).toHaveValue("brand-new");

    unmount();
  });
});
