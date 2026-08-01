/**
 * Tests for the NewAgentPage component.
 *
 * Covers the Rescan providers button introduced to re-discover
 * the model catalog without restarting the app:
 *   - Renders the button next to the model select
 *   - Disabled while a creation is in flight
 *   - Click → calls rescanModels() over the lobby channel
 *   - isRescanning state clears when the catalog lands via
 *     the follow-up `models_updated` broadcast
 */
import { describe, it, expect, beforeEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  waitFor,
  act,
} from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { NewAgentPage, validateNewAgentForm } from "./NewAgentPage";
import { useStore } from "../store";
import {
  captureNextPush,
  setNextJoinResult,
  setNextPushResult,
} from "../__mocks__/phoenix";
import { joinLobby, leaveLobby, clearAgentChannels } from "../channels";

function renderPage() {
  return render(
    <MemoryRouter>
      <NewAgentPage />
    </MemoryRouter>,
  );
}

async function joinTestLobby() {
  setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
  joinLobby();
  // `joinLobby`'s success callback is async via the mock
  // socket — give it a tick to register the listeners before
  // the click handler runs.
  await new Promise((resolve) => setTimeout(resolve, 5));
}

describe("NewAgentPage", () => {
  beforeEach(() => {
    useStore.getState()._reset();
    leaveLobby();
    clearAgentChannels();
  });

  describe("validateNewAgentForm", () => {
    // Pure-function helper extracted from `handleCreateAgent`.
    // Exercising each branch directly (without spinning up
    // React) is the cleanest way to cover the validation
    // paths — the live component path is gated on the
    // button's `disabled` flag, which is hard to bypass in
    // jsdom (React's virtual DOM keeps `disabled=true` even
    // after a `removeAttribute`).
    it("returns the missing-model error when no model is selected", () => {
      expect(
        validateNewAgentForm({
          selectedModel: "",
          selectedVocation: "1",
          requiresWorkspace: false,
          workspacePath: "",
        }),
      ).toBe("Please select a model");
    });

    it("returns the missing-vocation error when no vocation is selected", () => {
      expect(
        validateNewAgentForm({
          selectedModel: "qwen",
          selectedVocation: "",
          requiresWorkspace: false,
          workspacePath: "",
        }),
      ).toBe("Please select a vocation");
    });

    it("returns the missing-workspace error for Programmer without a path", () => {
      expect(
        validateNewAgentForm({
          selectedModel: "qwen",
          selectedVocation: "2",
          requiresWorkspace: true,
          workspacePath: "",
        }),
      ).toBe("Please specify a workspace path for the Programmer vocation");
    });

    it("passes when the workspace is supplied for Programmer", () => {
      expect(
        validateNewAgentForm({
          selectedModel: "qwen",
          selectedVocation: "2",
          requiresWorkspace: true,
          workspacePath: "/tmp/proj",
        }),
      ).toBeNull();
    });

    it("passes for non-Programmer vocations without a workspace path", () => {
      expect(
        validateNewAgentForm({
          selectedModel: "qwen",
          selectedVocation: "1",
          requiresWorkspace: false,
          workspacePath: "",
        }),
      ).toBeNull();
    });
  });

  describe("render with edge-case data", () => {
    it("renders the fallback option when models is empty", () => {
      // The empty-models branch — exercises the false
      // arm of `models.length > 0`. Scope the assertion
      // to the model `<select>` (the page also has a
      // vocation select whose options would otherwise
      // pollute the count).
      useStore.setState({
        models: [],
        vocations: [{ id: 1, name: "Chat Buddy" }],
      });

      renderPage();

      const modelOptions = Array.from(
        screen.getByLabelText(/select model/i).querySelectorAll("option"),
      );
      expect(modelOptions).toHaveLength(2);
      expect(modelOptions[0]).toHaveValue("");
      expect(modelOptions[1]).toHaveValue("gpt-4");
    });

    it("renders vocation descriptions only when a vocation is selected", () => {
      // The `selectedVocationData && (...)` truthy branch —
      // must exercise both sides of the conditional.
      useStore.setState({
        models: [{ name: "qwen", provider: "test" }],
        vocations: [{ id: 1, name: "Chat Buddy", description: "A test" }],
      });

      renderPage();

      // No description before any selection:
      expect(screen.queryByText(/A test/)).toBeNull();

      fireEvent.change(screen.getByLabelText(/select vocation/i), {
        target: { value: "1" },
      });

      expect(screen.getByText(/A test/)).toBeInTheDocument();
    });

    it("omits the model provider from the option label when missing", () => {
      // The `model.provider ? "(...)" : ""` false branch —
      // when a model entry has no provider we want the
      // option to render just the name.
      useStore.setState({
        models: [{ name: "no-provider-model" }],
        vocations: [{ id: 1, name: "Chat Buddy" }],
      });

      renderPage();

      const options = screen.getAllByRole("option");
      const noProviderOption = options.find(
        (opt) => opt.value === "no-provider-model",
      );
      expect(noProviderOption).toBeDefined();
      // The label should be the bare name with no parenthesized provider.
      expect(noProviderOption.textContent).toBe("no-provider-model");
    });
  });

  describe("Rescan providers button", () => {
    it("renders the rescan button next to the model select", () => {
      renderPage();

      const button = screen.getByRole("button", { name: /rescan providers/i });
      expect(button).toBeInTheDocument();
      expect(button).toHaveAttribute("type", "button");
    });

    it("is enabled when no rescan is in flight", () => {
      renderPage();

      const button = screen.getByRole("button", { name: /rescan providers/i });
      expect(button).not.toBeDisabled();
    });

    it("calls rescanModels over the lobby channel on click", async () => {
      await joinTestLobby();
      renderPage();

      // Click → rescanModels → lobbyChannel.push(...) via the
      // mock. Capture the payload and the configured ok reply
      // resolves the push.
      setNextPushResult("lobby", "rescan_models", { ok: {} });

      const capturePromise = captureNextPush("lobby", "rescan_models");
      const button = screen.getByRole("button", { name: /rescan providers/i });
      fireEvent.click(button);

      const captured = await capturePromise;
      expect(captured).toEqual({});

      // The button label transitions to "Rescanning…" while
      // the merged catalog is in flight.
      await waitFor(() => {
        expect(button).toHaveTextContent(/rescanning/i);
      });
    });

    it("clears the rescanning spinner once the merged catalog arrives via models_updated", async () => {
      await joinTestLobby();
      // Pre-populate the store with one model.
      useStore.setState({
        models: [{ name: "before-rescan-model", provider: "test-provider" }],
      });

      renderPage();

      setNextPushResult("lobby", "rescan_models", { ok: {} });
      const button = screen.getByRole("button", { name: /rescan providers/i });
      fireEvent.click(button);

      await waitFor(() => {
        expect(button).toHaveTextContent(/rescanning/i);
      });

      // Mutate the store directly with a new array reference
      // — that's the same mutation `setModels` does in
      // `channels.js` on the `models_updated` broadcast.
      // The post-render `setState` fires a React update, so it
      // must be wrapped in `act(...)` per React 19's testing
      // contract; without the wrapper, React logs "An update to
      // NewAgentPage inside a test was not wrapped in act(...)".
      act(() => {
        useStore.setState({
          models: [
            { name: "before-rescan-model", provider: "test-provider" },
            { name: "after-rescan-model", provider: "new-provider" },
          ],
        });
      });

      await waitFor(() => {
        expect(button).toHaveTextContent(/rescan providers/i);
      });
      expect(button).not.toBeDisabled();
    });
  });

  describe("form validation", () => {
    it("requires a workspace path when the Programmer vocation is selected", async () => {
      useStore.setState({
        models: [{ name: "qwen", provider: "test" }],
        vocations: [{ id: 2, name: "Programmer" }],
      });

      renderPage();

      fireEvent.change(screen.getByLabelText(/select model/i), {
        target: { value: "qwen" },
      });
      fireEvent.change(screen.getByLabelText(/select vocation/i), {
        target: { value: "2" },
      });

      // The workspace path input is rendered once Programmer
      // is selected.
      expect(screen.getByLabelText(/workspace path/i)).toBeInTheDocument();

      const createButton = screen.getByRole("button", {
        name: /create agent/i,
      });
      createButton.removeAttribute("disabled");
      fireEvent.click(createButton);

      expect(
        await screen.findByText(/please specify a workspace path/i),
      ).toBeInTheDocument();
    });

    it("submits and clears the error on a valid Programmer form", async () => {
      await joinTestLobby();
      useStore.setState({
        models: [{ name: "qwen", provider: "test" }],
        vocations: [{ id: 2, name: "Programmer" }],
      });
      setNextPushResult("lobby", "create_agent", {
        ok: { name: "new-coder" },
      });

      renderPage();

      fireEvent.change(screen.getByLabelText(/select model/i), {
        target: { value: "qwen" },
      });
      fireEvent.change(screen.getByLabelText(/select vocation/i), {
        target: { value: "2" },
      });
      fireEvent.change(screen.getByLabelText(/workspace path/i), {
        target: { value: "/home/me/proj" },
      });

      const createButton = screen.getByRole("button", {
        name: /create agent/i,
      });
      fireEvent.click(createButton);

      await waitFor(() => {
        expect(createButton).toHaveTextContent(/creating agent/i);
      });
    });

    it("surfaces a server error message when createAgent's onError fires", async () => {
      // Don't join the lobby — `createAgent` is a no-op
      // when `lobbyChannel === null` and immediately calls
      // onError. This exercises the error path without a
      // server round-trip.
      useStore.setState({
        models: [{ name: "qwen", provider: "test" }],
        vocations: [{ id: 1, name: "Chat Buddy" }],
      });

      renderPage();

      fireEvent.change(screen.getByLabelText(/select model/i), {
        target: { value: "qwen" },
      });
      fireEvent.change(screen.getByLabelText(/select vocation/i), {
        target: { value: "1" },
      });

      const createButton = screen.getByRole("button", {
        name: /create agent/i,
      });
      fireEvent.click(createButton);

      expect(
        await screen.findByText(/not connected to lobby/i),
      ).toBeInTheDocument();
    });

    it("surfaces a server error message when rescanModels fails", async () => {
      // Drive the error branch of `rescanModels`. After
      // the click, the button flips to "Rescanning…", then
      // the server reply (an error reply) flips it back
      // and surfaces the error message inline.
      await joinTestLobby();
      useStore.setState({
        models: [{ name: "qwen", provider: "test" }],
      });
      renderPage();

      setNextPushResult("lobby", "rescan_models", {
        error: { reason: "x" },
      });

      const button = screen.getByRole("button", { name: /rescan providers/i });
      fireEvent.click(button);

      await waitFor(() => {
        expect(button).toHaveTextContent(/rescanning/i);
      });

      await waitFor(() => {
        expect(button).toHaveTextContent(/rescan providers/i);
      });
      expect(
        screen.getByText(/failed to rescan providers/i),
      ).toBeInTheDocument();
    });
  });
});
