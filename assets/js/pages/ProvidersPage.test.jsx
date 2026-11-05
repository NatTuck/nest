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
 *  - Renders the probe-cache panel above the provider list, requests
 *    its stats, and rescans the catalog from it (refreshing the stats
 *    a completed scan has invalidated).
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
    clearProbeCache: vi.fn(),
    requestProbeCacheStats: vi.fn(),
    rescanModels: vi.fn(),
    saveProviders: vi.fn(),
  };
});

import {
  clearProbeCache,
  requestProbeCacheStats,
  rescanModels,
  saveProviders,
} from "../channels";

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
  // The key itself never reaches the browser (#202): the payload says whether
  // one is configured.
  has_api_key: true,
  protocol: "openai",
  auto_models: false,
  tags: [],
  first_byte_timeout_seconds: 900,
  stream_idle_timeout_seconds: 120,
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
    // The host the server injects into `window.NEST_CONFIG`, plus the
    // shell's default title: a page test proves the page *replaces* it.
    window.NEST_CONFIG = { host: "vampire" };
    document.title = "Nest · Phoenix Framework";

    saveProviders.mockReset();
    clearProbeCache.mockReset();
    requestProbeCacheStats.mockReset();
    rescanModels.mockReset();
    setStore({
      isConnected: true,
      providers: [],
      currentUser: adminUser(),
      probeCacheStats: null,
      deletedProviders: [],
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
    expect(document.title).toBe("vampire · Providers");
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

  it("names the providers that were removed here but are still in config.toml", async () => {
    // A save from a stale tab records as deleted every provider its payload did
    // not carry, including one added to `config.toml` afterwards. Without this
    // line the provider is simply not there, and nothing says why.
    setStore({
      providers: [sampleProvider],
      deletedProviders: ["anthropic-provider", "model-studio"],
    });

    await renderPage();

    expect(
      screen.getByText(/removed here .*anthropic-provider, model-studio/i),
    ).toBeInTheDocument();
    expect(screen.getByText(/still in/i)).toBeInTheDocument();
  });

  it("renders an explicit unknown when the server did not report the removals", async () => {
    // `null` is "not told", which is not "nothing was deleted": the second
    // reads as an answer, and this one is the absence of one.
    setStore({ providers: [sampleProvider], deletedProviders: null });

    await renderPage();

    expect(
      screen.getByText(/did not report which providers are removed/i),
    ).toBeInTheDocument();
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
    // The draft minus the client-only `id` and the server-owned `has_api_key` —
    // and with no `api_key` key at all, because nothing was typed: an omitted
    // key means "keep what is stored", which is the only way a save can say it
    // when the browser never receives the value (#202).
    const { has_api_key: _hasApiKey, ...expected } = sampleProvider;
    expect(providers).toEqual([expected]);
    expect(providers[0]).not.toHaveProperty("api_key");
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

  it("prefers the server's message over its bare reason", async () => {
    // A refused config value replies `{reason: "invalid_payload", message: …}`
    // where the message names the field and the offending value. The bare enum
    // says nothing an operator can act on, so `errorText` prefers the message —
    // and this pins that the page shows it rather than the enum.
    setStore({ providers: [sampleProvider] });

    saveProviders.mockImplementation((_providers, _onOk, onError) =>
      onError({
        reason: "invalid_payload",
        message:
          'Provider acme: invalid probe-base-url "": must be a non-empty string',
      }),
    );

    await renderPage();

    fireEvent.click(screen.getByRole("button", { name: /^save$/i }));

    await waitFor(() =>
      expect(screen.getByText(/invalid probe-base-url/i)).toBeInTheDocument(),
    );

    expect(screen.queryByText(/^invalid_payload$/)).not.toBeInTheDocument();
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

  it("sends a typed key and leaves every untouched provider's key alone", async () => {
    const second = { ...sampleProvider, name: "other", has_api_key: false };
    setStore({ providers: [sampleProvider, second] });

    saveProviders.mockImplementation((_providers, onOk, _onError) => onOk());

    await renderPage();

    fireEvent.change(screen.getAllByLabelText(/api key/i)[0], {
      target: { value: "sk-typed" },
    });

    fireEvent.click(screen.getByRole("button", { name: /^save$/i }));

    await waitFor(() => expect(saveProviders).toHaveBeenCalledTimes(1));

    const [providers] = saveProviders.mock.calls[0];
    expect(providers[0].api_key).toBe("sk-typed");
    // The other provider was not touched, so it says nothing about its key and
    // the server keeps what is on disk.
    expect(providers[1]).not.toHaveProperty("api_key");
    expect(providers[1]).not.toHaveProperty("clear_api_key");
  });

  it("sends clear_api_key when the operator clears a key", async () => {
    setStore({ providers: [sampleProvider] });

    saveProviders.mockImplementation((_providers, onOk, _onError) => onOk());

    await renderPage();

    fireEvent.click(screen.getByRole("button", { name: /^clear$/i }));

    // On screen before the save, because a pending removal is not an empty
    // field: the operator has to be able to tell them apart.
    expect(screen.getByText(/removed when you save/i)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /^save$/i }));

    await waitFor(() => expect(saveProviders).toHaveBeenCalledTimes(1));

    const [providers] = saveProviders.mock.calls[0];
    expect(providers[0].clear_api_key).toBe(true);
    // Never both: the server refuses a payload that sets and clears at once.
    expect(providers[0]).not.toHaveProperty("api_key");
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

  it("renders the probe cache panel above the provider list and requests its stats", async () => {
    setStore({
      probeCacheStats: {
        entries: 12,
        oldest_age_s: 259200,
        path: "/tmp/probe-cache.json",
      },
    });

    await renderPage();

    expect(requestProbeCacheStats).toHaveBeenCalledTimes(1);
    expect(
      screen.getByRole("button", {
        name: "Clear probe cache (12 entries, oldest 3 days)",
      }),
    ).toBeInTheDocument();

    // The panel belongs above the list it reports on, not beside Save.
    const heading = screen.getByText(/multimodal probe cache/i);
    const addProvider = screen.getByRole("button", { name: /add provider/i });
    expect(
      heading.compareDocumentPosition(addProvider) &
        Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy();
  });

  it("rescans the catalog from the panel and refreshes the cache stats", async () => {
    let finishRescan;
    rescanModels.mockImplementation((onOk) => {
      finishRescan = onOk;
    });

    await renderPage();

    expect(requestProbeCacheStats).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole("button", { name: "Rescan providers" }));

    await waitFor(() => expect(rescanModels).toHaveBeenCalledTimes(1));
    expect(
      screen.getByRole("button", { name: "Rescan providers" }),
    ).toBeDisabled();

    // A completed scan has probed whatever it had no verdict for, so
    // the panel's numbers are stale from that moment on.
    act(() => finishRescan());

    await waitFor(() =>
      expect(requestProbeCacheStats).toHaveBeenCalledTimes(2),
    );
    expect(
      screen.getByRole("button", { name: "Rescan providers" }),
    ).toBeEnabled();
  });

  it("surfaces a rescan failure inline", async () => {
    rescanModels.mockImplementation((_onOk, onError) =>
      onError({ reason: "scan failed" }),
    );

    await renderPage();

    fireEvent.click(screen.getByRole("button", { name: "Rescan providers" }));

    await waitFor(() =>
      expect(screen.getByText("scan failed")).toBeInTheDocument(),
    );
    expect(
      screen.getByRole("button", { name: "Rescan providers" }),
    ).toBeEnabled();
  });
});
