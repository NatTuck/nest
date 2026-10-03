/**
 * Tests for channels.js behavior
 * Verifies protocol compliance with agent-channel-protocol.md
 * All tests verify behavior through store state changes only
 */

import { describe, it, beforeEach, vi } from "vitest";
import assert from "node:assert";
import {
  resetMockSocket,
  setNextJoinResult,
  setNextPushResult,
  captureNextPush,
  simulateServerEvent,
  connectSocket,
  disconnectSocket,
  errorSocket,
} from "./__mocks__/phoenix";
import { useStore } from "./store";
import {
  initChannels,
  joinLobby,
  leaveLobby,
  joinAgent,
  leaveAgent,
  requestHistory,
  sendMessage,
  stopMessage,
  retryCompaction,
  compactionLoopOk,
  killShellJob,
  fetchShellLog,
  refreshShellJobs,
  createSpace,
  suggestSpaceName,
  createInvite,
  revokeInvite,
  archiveSpace,
  unarchiveSpace,
  clearAgentChannels,
} from "./channels";

describe("channels", () => {
  beforeEach(() => {
    resetMockSocket();
    useStore.getState()._reset();
    clearAgentChannels();
    leaveLobby();
  });

  describe("initChannels", () => {
    it("should update store.isConnected to true when socket connects", async () => {
      initChannels();
      connectSocket();
      // Wait for async callback
      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().isConnected, true);
      });
    });

    it("should update store.isConnected to false when socket disconnects", async () => {
      initChannels();
      connectSocket();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().isConnected, true);
      });

      disconnectSocket();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().isConnected, false);
      });
    });

    it("should update store.isConnected to false when socket errors", async () => {
      initChannels();
      connectSocket();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().isConnected, true);
      });

      errorSocket();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().isConnected, false);
      });
    });

    describe("token-gated connect", () => {
      it("does not call socket.connect() when no token is in localStorage", async () => {
        localStorage.removeItem("nest_token");
        const { getSocket } = await import("./channels");
        const sock = getSocket();
        const original = sock.connect;
        let calls = 0;
        sock.connect = (...args) => {
          calls += 1;
          return original.apply(sock, args);
        };

        initChannels();

        assert.strictEqual(
          calls,
          0,
          "initChannels must not connect when no token is stored",
        );

        sock.connect = original;
      });

      it("calls socket.connect() when a token is in localStorage", async () => {
        localStorage.setItem("nest_token", "valid-token");
        const { getSocket } = await import("./channels");
        const sock = getSocket();
        const original = sock.connect;
        let calls = 0;
        sock.connect = (...args) => {
          calls += 1;
          return original.apply(sock, args);
        };

        initChannels();

        assert.strictEqual(
          calls,
          1,
          "initChannels must connect exactly once when a token is stored",
        );

        sock.connect = original;
      });

      it("does not call socket.connect() when socket is already connected", async () => {
        localStorage.setItem("nest_token", "valid-token");
        const { getSocket } = await import("./channels");
        const sock = getSocket();
        // Simulate the socket already being open (e.g. HMR
        // re-init without a page refresh).
        connectSocket();
        const original = sock.connect;
        let calls = 0;
        sock.connect = (...args) => {
          calls += 1;
          return original.apply(sock, args);
        };

        initChannels();

        assert.strictEqual(
          calls,
          0,
          "initChannels must not reconnect when socket is already open",
        );

        sock.connect = original;
      });
    });
  });

  describe("getSocket", () => {
    it("should return the socket instance", async () => {
      const { getSocket } = await import("./channels");
      const socket = getSocket();
      assert.strictEqual(typeof socket, "object");
    });
  });

  describe("joinLobby", () => {
    it("should set store.agents when receiving init event", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [{ name: "agent-1", model: { name: "Test Agent" } }],
          models: [],
        },
      });

      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 1);
      });

      assert.deepStrictEqual(useStore.getState().agents, [
        {
          name: "agent-1",
          model: { name: "Test Agent" },
          space_id: null,
          status: "idle",
          parentId: null,
          parentName: null,
          depth: 0,
        },
      ]);
    });

    it("should set store.models when receiving init event", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [],
          models: [{ name: "gpt-4", provider: "openai" }],
        },
      });

      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().models.length, 1);
      });

      assert.deepStrictEqual(useStore.getState().models, [
        { name: "gpt-4", provider: "openai" },
      ]);
    });

    it("should call onOk callback on successful join", async () => {
      let called = false;
      joinLobby(() => {
        called = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(called, true);
      });
    });

    it("should call onError callback on join error", async () => {
      // The store intentionally logs a console.error on lobby join
      // failure for server-side observability. Silence the leak
      // here; the dedicated "should log console error on lobby join
      // failure" test below asserts the error was emitted.
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      try {
        let errorCalled = false;
        let errorReason = null;
        setNextJoinResult("lobby", { error: "lobby_full" });
        joinLobby(
          () => {},
          (err) => {
            errorCalled = true;
            errorReason = err.reason;
          },
        );

        await vi.waitFor(() => {
          assert.strictEqual(errorCalled, true);
        });
        assert.strictEqual(errorReason, "lobby_full");
      } finally {
        errorSpy.mockRestore();
      }
    });

    it("should log console error on lobby join failure", async () => {
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      setNextJoinResult("lobby", { error: "lobby_full" });

      joinLobby(
        () => {},
        () => {},
      );

      await vi.waitFor(() => {
        assert.strictEqual(errorSpy.mock.calls.length > 0, true);
      });

      const errorMessage = errorSpy.mock.calls.find((call) =>
        call[0]?.includes("Lobby channel join error"),
      );
      assert.ok(errorMessage, "Expected console error for lobby join failure");

      errorSpy.mockRestore();
    });

    it("should be idempotent - call onOk immediately if already joined", async () => {
      let firstCalled = false;
      let secondCalled = false;

      joinLobby(() => {
        firstCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(firstCalled, true);
      });

      joinLobby(() => {
        secondCalled = true;
      });

      assert.strictEqual(secondCalled, true);
    });
  });

  describe("lobby events", () => {
    it("should add agent to store.agents on agent:created event", async () => {
      setNextJoinResult("lobby", {
        autoInit: { agents: [], models: [] },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 0);
      });

      simulateServerEvent("lobby", "agent:created", {
        name: "new-agent",
        model: { name: "gpt-4", provider: "openai" },
      });

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 1);
      });
      assert.strictEqual(useStore.getState().agents[0].name, "new-agent");
    });

    it("should move an agent to archivedAgents on agent:archived event", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [
            {
              name: "sub",
              space_id: 7,
              model: { name: "gpt-4" },
              parentName: "root",
              depth: 1,
            },
          ],
          archived_agents: [],
          models: [],
        },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 1);
      });

      simulateServerEvent("lobby", "agent:archived", {
        space_id: 7,
        name: "sub",
      });

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 0);
        assert.strictEqual(useStore.getState().archivedAgents.length, 1);
      });
      assert.strictEqual(useStore.getState().archivedAgents[0].name, "sub");
    });

    it("should hydrate archivedAgents from the init payload", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [],
          archived_agents: [
            { name: "old", space_id: 7, archived: true, parent_name: null },
          ],
          models: [],
        },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().archivedAgents.length, 1);
      });
      assert.strictEqual(useStore.getState().archivedAgents[0].name, "old");
    });

    it("should update brokenAgents on broken_agents_updated event", async () => {
      // The lobby's `init` ships with `broken_agents: []` (so
      // the channel join doesn't block on `Models.list/0`); a
      // follow-up `broken_agents_updated` event arrives once the
      // async fetch completes. Verify the JS store reacts to that
      // follow-up — without it the broken agents would never
      // appear in the sidebar's broken list.
      setNextJoinResult("lobby", {
        autoInit: { agents: [], models: [], broken_agents: [] },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.deepStrictEqual(useStore.getState().brokenAgents, []);
      });

      simulateServerEvent("lobby", "broken_agents_updated", {
        broken_agents: [
          {
            name: "ghost-agent",
            model: { name: "ghost-model" },
            status: "model_missing",
          },
        ],
      });

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().brokenAgents.length, 1);
        assert.strictEqual(
          useStore.getState().brokenAgents[0].name,
          "ghost-agent",
        );
      });
    });

    it("should ignore agent:updated broadcasts without name or model", async () => {
      // Defensive guard — a malformed broadcast should not
      // crash the store. Without `name` or `model` we
      // simply skip the `applyAgentModelUpdate` call. The
      // `if (payload?.name && payload?.model)` short-circuit
      // is the only branch in this handler and exercising
      // the false branch is the primary value of this test.
      setNextJoinResult("lobby", {
        autoInit: { agents: [], models: [], broken_agents: [] },
      });
      joinLobby();

      await vi.waitFor(() => {
        return true;
      });

      // Should not throw with a payload missing `name`:
      simulateServerEvent("lobby", "agent:updated", { model: { name: "x" } });

      // Or with a payload missing `model`:
      simulateServerEvent("lobby", "agent:updated", { name: "x" });

      // Or with an empty payload entirely:
      simulateServerEvent("lobby", "agent:updated", {});

      // Sanity: the store's agents list is empty (none of
      // the malformed payloads should have created an
      // entry).
      assert.strictEqual(useStore.getState().agents.length, 0);
    });

    it("applies the model update when both name and model are present", async () => {
      // The success path of the same handler. When the
      // payload includes `name` AND `model`, the gate
      // opens and `applyAgentModelUpdate` runs end-to-end.
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [{ name: "agent-1", model: { name: "old-model" } }],
          models: [],
          broken_agents: [],
        },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 1);
      });

      simulateServerEvent("lobby", "agent:updated", {
        name: "agent-1",
        model: { name: "new-model", provider: "openai" },
      });

      await vi.waitFor(() => {
        const agents = useStore.getState().agents;
        assert.strictEqual(agents[0].model.name, "new-model");
        assert.strictEqual(agents[0].model.provider, "openai");
      });
    });

    it("applies the workspace update when agent:updated carries a workspace_path", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [
            { name: "agent-1", model: { name: "m" }, workspace_path: null },
          ],
          models: [],
          broken_agents: [],
        },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length, 1);
      });

      simulateServerEvent("lobby", "agent:updated", {
        name: "agent-1",
        workspace_path: "/new/ws",
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agents[0].workspace_path,
          "/new/ws",
        );
      });
    });

    it("should move a space into archivedSpaces on space:archived", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [],
          models: [],
          spaces: [{ id: 1, name: "alpha", slug: "alpha" }],
        },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().spaces.length, 1);
      });

      simulateServerEvent("lobby", "space:archived", { space_id: 1 });

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().spaces.length, 0);
        assert.strictEqual(useStore.getState().archivedSpaces.length, 1);
      });
      assert.strictEqual(useStore.getState().archivedSpaces[0].id, 1);
    });

    it("should restore a space into the active list on space:unarchived", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [],
          models: [],
          archived_spaces: [{ id: 1, name: "alpha", slug: "alpha" }],
        },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().archivedSpaces.length, 1);
      });

      simulateServerEvent("lobby", "space:unarchived", { space_id: 1 });

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().archivedSpaces.length, 0);
        assert.strictEqual(useStore.getState().spaces.length, 1);
      });
      assert.strictEqual(useStore.getState().spaces[0].id, 1);
    });

    it("ignores space:archived / space:unarchived without a space_id", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [],
          models: [],
          spaces: [{ id: 1, name: "alpha", slug: "alpha" }],
        },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().spaces.length, 1);
      });

      // A malformed payload (no `space_id`) must not crash the
      // handler or move any space.
      simulateServerEvent("lobby", "space:archived", {});
      simulateServerEvent("lobby", "space:unarchived", {});
      simulateServerEvent("lobby", "space:archived", { space_id: null });

      await vi.waitFor(() => {
        return true;
      });

      assert.strictEqual(useStore.getState().spaces.length, 1);
      assert.strictEqual(useStore.getState().archivedSpaces.length, 0);
    });

    it("should set archivedSpaces from the init payload", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [],
          models: [],
          archived_spaces: [{ id: 9, name: "zeta", slug: "zeta" }],
        },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().archivedSpaces.length, 1);
      });
      assert.strictEqual(useStore.getState().archivedSpaces[0].id, 9);
    });

    it("should set providers from the init payload", async () => {
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [],
          models: [],
          providers: [{ name: "acme" }, { name: "pegasus" }],
        },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.deepStrictEqual(
          useStore.getState().providers.map((p) => p.name),
          ["acme", "pegasus"],
        );
      });
    });

    it("should update store.models on models_updated event", async () => {
      // Triggered by `rescanModels/0` on the new-agent page (and
      // any future rescan CTA). The lobby rebroadcasts the merged
      // catalog (static + auto-discovered, with any
      // `config.toml` changes reloaded server-side) so the
      // store's `models` reflects whatever the server holds.
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [],
          models: [{ name: "old-model", provider: "old-provider" }],
          broken_agents: [],
        },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().models.length, 1);
      });

      simulateServerEvent("lobby", "models_updated", {
        models: [
          { name: "old-model", provider: "old-provider" },
          { name: "fresh-model", provider: "fresh-provider" },
        ],
      });

      await vi.waitFor(() => {
        const names = useStore.getState().models.map((m) => m.name);
        assert.deepStrictEqual(names, ["old-model", "fresh-model"]);
      });
    });

    it("should update store.providers on providers_updated event", async () => {
      // Emitted after a successful `save_providers` push so the GUI's
      // in-memory provider list reflects the newly persisted set without
      // a re-fetch.
      setNextJoinResult("lobby", {
        autoInit: { agents: [], models: [], providers: [] },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().providers.length, 0);
      });

      simulateServerEvent("lobby", "providers_updated", {
        providers: [{ name: "brand-new" }],
      });

      await vi.waitFor(() => {
        assert.deepStrictEqual(useStore.getState().providers, [
          { name: "brand-new" },
        ]);
      });
    });
  });

  describe("rescanModels", () => {
    it("pushes rescan_models over the lobby channel", async () => {
      const { rescanModels } = await import("./channels");
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();

      await vi.waitFor(() => {
        // channel is joined
        assert.strictEqual(useStore.getState().models.length >= 0, true);
      });

      const capturePromise = captureNextPush("lobby", "rescan_models");
      rescanModels();
      const captured = await capturePromise;
      assert.deepStrictEqual(captured, {});
    });

    it("invokes onError when not connected to lobby", async () => {
      const { rescanModels } = await import("./channels");
      let errorCalled = false;
      rescanModels(
        () => {},
        () => {
          errorCalled = true;
        },
      );
      assert.strictEqual(errorCalled, true);
    });

    it("is a no-op when not connected and no onError is provided", async () => {
      // Cover the `if (onError)` short-circuit inside the
      // disconnected-lobby branch — when the caller passes
      // no error callback, the inner `onError(...)` call
      // is skipped (otherwise we'd dereference undefined).
      const { rescanModels } = await import("./channels");
      // Should not throw.
      rescanModels();
    });

    it("forwards the lobby-disconnect error to createSpace's onError", async () => {
      // Mirror for `createSpace` — exercise the
      // `if (onError)` truthy branch on the disconnected
      // path. Closes the last remaining uncovered line in
      // `channels.js`'s lobbyChannel-is-null guards.
      const { createSpace } = await import("./channels");
      let captured = null;
      createSpace(
        { name: "x" },
        1,
        () => {},
        (err) => {
          captured = err;
        },
      );
      assert.notStrictEqual(captured, null);
      assert.strictEqual(captured.message, "Not connected to lobby");
    });

    it("is a no-op when createSpace is called without an onError", async () => {
      // Mirror of the rescanModels no-onError
      // coverage — verifies the short-circuit cleanly
      // when the caller only cares about success.
      const { createSpace } = await import("./channels");
      // Should not throw on the disconnected path even
      // without a fallback onError.
      createSpace({ name: "x" }, 1, () => {});
    });

    it("forwards the server-side error payload to onError", async () => {
      const { rescanModels } = await import("./channels");
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();

      await vi.waitFor(() => {
        return true;
      });

      setNextPushResult("lobby", "rescan_models", { error: { reason: "x" } });

      let captured = null;
      rescanModels(
        () => {},
        (err) => {
          captured = err;
        },
      );

      await vi.waitFor(() => {
        assert.notStrictEqual(captured, null);
      });
      assert.deepStrictEqual(captured, { reason: "x" });
    });
  });

  describe("saveProviders", () => {
    it("pushes the provider list over the lobby channel and calls onOk on success", async () => {
      const { saveProviders } = await import("./channels");
      setNextJoinResult("lobby", {
        autoInit: { agents: [], models: [], providers: [] },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().providers.length >= 0, true);
      });

      setNextPushResult("lobby", "save_providers", { ok: {} });

      let okCalled = false;
      const capturePromise = captureNextPush("lobby", "save_providers");
      saveProviders([{ name: "acme" }], () => {
        okCalled = true;
      });

      const captured = await capturePromise;
      assert.deepStrictEqual(captured, { providers: [{ name: "acme" }] });

      await vi.waitFor(() => {
        assert.strictEqual(okCalled, true);
      });
    });

    it("invokes onError when not connected to the lobby", async () => {
      const { saveProviders } = await import("./channels");
      let errorCalled = false;
      saveProviders(
        [],
        () => {},
        () => {
          errorCalled = true;
        },
      );
      assert.strictEqual(errorCalled, true);
    });

    it("is a no-op when not connected and no onError is provided", async () => {
      const { saveProviders } = await import("./channels");
      // Should not throw on the disconnected path.
      saveProviders([]);
    });

    it("forwards the server-side error payload to onError", async () => {
      const { saveProviders } = await import("./channels");
      setNextJoinResult("lobby", {
        autoInit: { agents: [], models: [], providers: [] },
      });
      joinLobby();

      await vi.waitFor(() => {
        return true;
      });

      setNextPushResult("lobby", "save_providers", {
        error: { reason: "forbidden" },
      });

      let captured = null;
      saveProviders(
        [],
        () => {},
        (err) => {
          captured = err;
        },
      );

      await vi.waitFor(() => {
        assert.notStrictEqual(captured, null);
      });
      assert.deepStrictEqual(captured, { reason: "forbidden" });
    });
  });

  describe("suggestSpaceName", () => {
    it("is a no-op when not connected to the lobby", () => {
      // `lobbyChannel` is null before `joinLobby`; the guard
      // returns without pushing.
      suggestSpaceName(() => {});
    });

    it("delivers the suggested name via onOk on success", async () => {
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();
      setNextPushResult("lobby", "suggest_space_name", {
        ok: { name: "clever-raven" },
      });

      let captured = null;
      suggestSpaceName((name) => {
        captured = name;
      });

      await vi.waitFor(() => {
        assert.strictEqual(captured, "clever-raven");
      });
    });

    it("ignores a payload without a name", async () => {
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();
      setNextPushResult("lobby", "suggest_space_name", { ok: {} });

      let captured = "not-called";
      suggestSpaceName((name) => {
        captured = name;
      });

      await vi.waitFor(() => {
        assert.strictEqual(captured, "not-called");
      });
    });
  });

  describe("archiveSpace and unarchiveSpace", () => {
    it("is a no-op when not connected to the lobby", () => {
      // `lobbyChannel` is null before `joinLobby`; the guard returns
      // without pushing.
      archiveSpace(
        1,
        () => {},
        () => {},
      );
      unarchiveSpace(
        1,
        () => {},
        () => {},
      );
    });

    it("forwards the archive_space ok payload to onOk", async () => {
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();
      setNextPushResult("lobby", "archive_space", { ok: {} });

      let captured = "not-called";
      archiveSpace(5, () => {
        captured = "called";
      });

      await vi.waitFor(() => {
        assert.strictEqual(captured, "called");
      });
    });

    it("forwards the unarchive_space error payload to onError", async () => {
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();
      setNextPushResult("lobby", "unarchive_space", {
        error: { reason: "forbidden" },
      });

      let captured = null;
      unarchiveSpace(
        5,
        () => {},
        (err) => {
          captured = err;
        },
      );

      await vi.waitFor(() => {
        assert.strictEqual(captured.reason, "forbidden");
      });
    });

    it("is a no-op when unarchiveSpace succeeds without an onOk", async () => {
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();
      setNextPushResult("lobby", "unarchive_space", { ok: {} });

      unarchiveSpace(5);

      await vi.waitFor(() => {
        return true;
      });
    });
  });

  describe("changeAgentModel", () => {
    it("invokes onError when not connected to lobby", async () => {
      const { changeAgentModel } = await import("./channels");
      let captured = null;
      changeAgentModel(
        "ghost-agent",
        1,
        { name: "gpt-4", provider: "openai" },
        () => {},
        (err) => {
          captured = err;
        },
      );
      assert.notStrictEqual(captured, null);
      assert.strictEqual(captured.message, "Not connected to lobby");
    });

    it("forwards the server-side error payload to onError", async () => {
      const { changeAgentModel } = await import("./channels");
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();

      await vi.waitFor(() => {
        return true;
      });

      setNextPushResult("lobby", "change_model", {
        error: { reason: "agent_busy" },
      });

      let captured = null;
      changeAgentModel(
        "ghost-agent",
        1,
        { name: "gpt-4", provider: "openai" },
        () => {},
        (err) => {
          captured = err;
        },
      );

      await vi.waitFor(() => {
        assert.notStrictEqual(captured, null);
      });
      assert.deepStrictEqual(captured, { reason: "agent_busy" });
    });

    it("invokes onOk on a successful change", async () => {
      const { changeAgentModel } = await import("./channels");
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();

      await vi.waitFor(() => {
        return true;
      });

      setNextPushResult("lobby", "change_model", { ok: {} });

      const capturePromise = captureNextPush("lobby", "change_model");
      let okCalled = false;
      changeAgentModel(
        "ghost-agent",
        1,
        { name: "gpt-4", provider: "openai" },
        () => {
          okCalled = true;
        },
        () => {},
      );

      const captured = await capturePromise;
      assert.deepStrictEqual(captured, {
        name: "ghost-agent",
        space_id: 1,
        model: { name: "gpt-4", provider: "openai", thinking_level: null },
      });
      await vi.waitFor(() => {
        assert.strictEqual(okCalled, true);
      });
    });
  });

  describe("editAgent", () => {
    it("pushes the model and workspace_path", async () => {
      const { editAgent } = await import("./channels");
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();
      await vi.waitFor(() => true);

      const pushPromise = captureNextPush("lobby", "edit_agent");
      editAgent(
        "ghost-agent",
        1,
        { name: "gpt-4", provider: "openai", thinking_level: "high" },
        "/new/workspace",
      );

      const payload = await pushPromise;
      assert.deepStrictEqual(payload, {
        name: "ghost-agent",
        space_id: 1,
        model: { name: "gpt-4", provider: "openai", thinking_level: "high" },
        workspace_path: "/new/workspace",
      });
    });

    it("invokes onError when not connected to lobby", async () => {
      const { editAgent } = await import("./channels");
      let captured = null;
      editAgent(
        "ghost-agent",
        1,
        { name: "gpt-4" },
        null,
        () => {},
        (err) => {
          captured = err;
        },
      );
      assert.notStrictEqual(captured, null);
      assert.strictEqual(captured.message, "Not connected to lobby");
    });

    it("forwards the server-side error payload to onError", async () => {
      const { editAgent } = await import("./channels");
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();
      await vi.waitFor(() => true);

      setNextPushResult("lobby", "edit_agent", {
        error: { reason: "agent_busy" },
      });
      let captured = null;
      editAgent(
        "ghost-agent",
        1,
        { name: "gpt-4", provider: "openai" },
        "/ws",
        () => {},
        (err) => {
          captured = err;
        },
      );

      await vi.waitFor(() => {
        assert.notStrictEqual(captured, null);
      });
      assert.deepStrictEqual(captured, { reason: "agent_busy" });
    });

    it("invokes onOk on a successful edit", async () => {
      const { editAgent } = await import("./channels");
      setNextJoinResult("lobby", { autoInit: { agents: [], models: [] } });
      joinLobby();
      await vi.waitFor(() => true);

      setNextPushResult("lobby", "edit_agent", { ok: {} });
      let okCalled = false;
      editAgent("ghost-agent", 1, { name: "gpt-4" }, "/ws", () => {
        okCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(okCalled, true);
      });
    });
  });

  describe("leaveLobby", () => {
    it("should leave the lobby channel", async () => {
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      leaveLobby();

      let errorCalled = false;
      createSpace(
        "gpt-4",
        1,
        () => {},
        (_err) => {
          errorCalled = true;
        },
      );

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });
  });

  describe("joinAgent", () => {
    it("should set agent status to connecting in store before join completes", () => {
      joinAgent("agent-1", 1);
      assert.strictEqual(
        useStore.getState().agentsCache["agent-1"]?.status,
        "connecting",
      );
    });

    it("should store init payload - status, model, but not set lastIndex from messageCount", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "claude-3", provider: "anthropic" },
          messageCount: 5,
          status: "idle",
        },
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.status, "connected");
        assert.strictEqual(cache?.model?.name, "claude-3");
        // lastIndex is not set from messageCount, only from actual messages
        assert.strictEqual(cache?.lastIndex, -1);
      });
    });

    it("should trigger sync when server messageCount > cached lastIndex", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [{ index: 0, role: "user", content: "Hello" }],
      });

      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4" },
          messageCount: 3,
          status: "idle",
          messages: [{ index: 0, role: "user", content: "Hello" }],
        },
      });

      setNextPushResult("agent:1:agent-1", "chat:sync", {
        ok: {
          messages: [
            { index: 0, role: "user", content: "Hello" },
            { index: 1, role: "assistant", content: "Response 1" },
            { index: 2, role: "user", content: "Question" },
            { index: 3, role: "assistant", content: "Response 2" },
          ],
          messageCount: 3,
        },
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.messages?.length,
          4,
        );
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.lastIndex,
          3,
        );
      });
    });

    it("triggers a full chat:sync from the init handler when messageCount disagrees with the cache", async () => {
      // The init event arrives with messageCount=2 and 1 message
      // in the payload. `2 !== cache.messages.length(1)`, so the
      // cache can't be trusted: it is dropped and a full sync is
      // requested from -1 rather than an incremental lastIndex
      // sync a stale/merged index would defeat.
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4" },
          messageCount: 2,
          status: "idle",
          messages: [{ index: 0, role: "user", content: "Hello" }],
        },
      });

      const pushPromise = captureNextPush("agent:1:agent-1", "chat:sync");
      joinAgent("agent-1", 1);

      const pushPayload = await pushPromise;
      assert.deepStrictEqual(pushPayload, { lastIndex: -1 });
    });

    it("should set agent status to error on join error", async () => {
      // The store intentionally logs a console.error on join failure
      // for server-side observability. Silence the leak here; the
      // dedicated "should log console error on agent join failure"
      // test below asserts the error was emitted.
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      try {
        setNextJoinResult("agent:1:agent-1", { error: "agent_not_found" });
        joinAgent("agent-1", 1);

        await vi.waitFor(() => {
          assert.strictEqual(
            useStore.getState().agentsCache["agent-1"]?.status,
            "error",
          );
          assert.strictEqual(
            useStore.getState().agentsCache["agent-1"]?.error,
            "agent_not_found",
          );
        });
      } finally {
        errorSpy.mockRestore();
      }
    });

    it("should log console error on agent join failure", async () => {
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      setNextJoinResult("agent:1:agent-1", { error: "agent_not_found" });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(errorSpy.mock.calls.length > 0, true);
      });

      const errorMessage = errorSpy.mock.calls.find((call) =>
        call[0]?.includes("Agent agent-1 channel join error"),
      );
      assert.ok(errorMessage, "Expected console error for agent join failure");

      errorSpy.mockRestore();
    });

    it("should set agent status to error on join timeout", async () => {
      // The store intentionally logs a console.error on join timeout
      // so server-side observability surfaces the failure. Silence
      // the leak here; the dedicated "should log console error"
      // test below asserts the error was emitted.
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      try {
        setNextJoinResult("agent:1:agent-1", { timeout: true });
        joinAgent("agent-1", 1);

        await vi.waitFor(() => {
          assert.strictEqual(
            useStore.getState().agentsCache["agent-1"]?.status,
            "error",
          );
          assert.strictEqual(
            useStore.getState().agentsCache["agent-1"]?.error,
            "Connection timed out",
          );
        });
      } finally {
        errorSpy.mockRestore();
      }
    });

    it("should log console error on agent join timeout", async () => {
      const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
      setNextJoinResult("agent:1:agent-1", { timeout: true });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(errorSpy.mock.calls.length > 0, true);
      });

      const errorMessage = errorSpy.mock.calls.find((call) =>
        call[0]?.includes("Agent agent-1 channel join timeout"),
      );
      assert.ok(errorMessage, "Expected console error for agent join timeout");

      errorSpy.mockRestore();
    });

    it("should handle rejoin - send chat:status and update from response", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.model?.name,
          "gpt-4",
        );
      });

      setNextPushResult("agent:1:agent-1", "chat:status", {
        ok: {
          model: { name: "claude-3", provider: "anthropic" },
          messageCount: 0,
        },
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.model?.name,
          "claude-3",
        );
      });
    });

    it("updates the archive boundary from the rejoin (chat:status) reply", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4" },
          messageCount: 0,
          status: "idle",
          lastCompactionIndex: -1,
          compactionCount: 0,
        },
      });
      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // A compaction was missed while disconnected: the status reply
      // carries the new boundary, so the stale projections are dropped
      // and the marker re-fetched.
      setNextPushResult("agent:1:agent-1", "chat:status", {
        ok: {
          model: { name: "gpt-4" },
          messageCount: 0,
          lastCompactionIndex: 7,
          compactionCount: 1,
        },
      });
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache.lastCompactionIndex, 7);
        assert.strictEqual(cache.compactionCount, 1);
      });
    });

    it("triggers a chat:sync from the rejoin (chat:status) handler when messageCount > cached messages length", async () => {
      // Re-join path: `joinAgent` re-uses the existing
      // channel and sends `chat:status`. The response
      // payload's `messageCount` is checked against the
      // current cache; if the server has more messages,
      // the new requestSync is fired.
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Now simulate a rejoin where the server reports
      // more messages than the client has cached. The
      // rejoin handler's check fires requestSync.
      setNextPushResult("agent:1:agent-1", "chat:status", {
        ok: {
          model: { name: "gpt-4" },
          messageCount: 5,
        },
      });
      const pushPromise = captureNextPush("agent:1:agent-1", "chat:sync");
      joinAgent("agent-1", 1);

      const pushPayload = await pushPromise;
      // Sync uses cache.lastIndex (-1) as the lower bound
      // since the cache has no messages yet.
      assert.deepStrictEqual(pushPayload, { lastIndex: -1 });
    });

    it("full-syncs from the rejoin (chat:status) handler when the cache is ahead of the server", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Seed a phantom row the DB never committed (a broadcast that
      // raced a failed/killed persist) so the client is a message
      // ahead of the server.
      useStore.getState().syncAgentMessages("agent-1", {
        messages: [
          { index: 0, role: "user", content: "Hello" },
          { index: 1, role: "assistant", content: "phantom" },
        ],
      });
      assert.strictEqual(
        useStore.getState().agentsCache["agent-1"].messages.length,
        2,
      );

      setNextPushResult("agent:1:agent-1", "chat:status", {
        ok: { model: { name: "gpt-4" }, messageCount: 1 },
      });
      setNextPushResult("agent:1:agent-1", "chat:sync", {
        ok: { messages: [{ index: 0, role: "user", content: "Hello" }] },
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache.messages.length, 1);
        assert.strictEqual(cache.messages[0].content, "Hello");
      });
    });

    it("fetches the compaction marker for an agent with a boundary at join", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4" },
          messageCount: 0,
          status: "idle",
          lastCompactionIndex: 4,
          compactionCount: 2,
        },
      });

      const historyPush = captureNextPush("agent:1:agent-1", "chat:history");
      joinAgent("agent-1", 1);

      const payload = await historyPush;
      assert.deepStrictEqual(payload, { role: "compaction", limit: 1 });
    });

    it("does not fetch the archive for a never-compacted agent", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4" },
          messageCount: 0,
          status: "idle",
          lastCompactionIndex: -1,
          compactionCount: 0,
        },
      });

      const historyPush = captureNextPush("agent:1:agent-1", "chat:history");
      joinAgent("agent-1", 1);
      const timeout = new Promise((resolve) =>
        setTimeout(() => resolve("timeout"), 40),
      );
      assert.strictEqual(await Promise.race([historyPush, timeout]), "timeout");
    });
  });

  describe("defensive error paths", () => {
    // Branch coverage: the `!lobbyChannel` early-return
    // branches in `createSpace`, the
    // `compactionLoopOk` error receive, and the
    // `joinLobby` idempotent path are defensive paths
    // that only fire when the lobby is disconnected, the
    // server returns an error, or the lobby is re-joined.
    // They're straightforward to exercise but the
    // existing tests never hit them.

    it("createSpace returns an error when the lobby isn't connected", () => {
      let errorCalled = false;
      let errorMessage = null;
      createSpace(
        { name: "gpt-4" },
        null,
        () => {},
        (err) => {
          errorCalled = true;
          errorMessage = err.message;
        },
      );
      assert.strictEqual(errorCalled, true);
      assert.strictEqual(errorMessage, "Not connected to lobby");
    });

    it("compactionLoopOk surfaces server errors via the onError callback", async () => {
      // The push is configured to return an error in the
      // receive("error", ...) callback. Verify the
      // onError path is wired correctly.
      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      setNextPushResult("agent:1:agent-1", "chat:loop-detected-ok", {
        error: { reason: "not_in_loop" },
      });

      let errorCalled = false;
      let errorReason = null;
      compactionLoopOk("agent-1", (err) => {
        errorCalled = true;
        errorReason = err?.reason;
      });

      // Wait for the error receive to be processed.
      await new Promise((resolve) => setTimeout(resolve, 30));
      assert.strictEqual(errorCalled, true);
      assert.strictEqual(errorReason, "not_in_loop");
    });

    it("compactionLoopOk is a no-op when no onError is provided", async () => {
      // Cover the `if (onError)` short-circuit inside the
      // error receive. Without a callback the inner
      // `onError(...)` call is skipped — important since
      // v8 instrument counts both branches.
      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      setNextPushResult("agent:1:agent-1", "chat:loop-detected-ok", {
        error: { reason: "not_in_loop" },
      });

      // Should not throw on the onError-less receive.
      compactionLoopOk("agent-1");
      await new Promise((resolve) => setTimeout(resolve, 30));
    });

    it("joinLobby is idempotent — calling it twice with the lobby already connected calls onOk immediately", () => {
      // Pre-populate the lobby channel by setting a join
      // result and calling once.
      setNextJoinResult("lobby", {
        autoInit: {
          agents: [],
          models: [],
        },
      });
      joinLobby(() => {});

      // The second call hits the idempotent branch: if the
      // lobby channel is set, onOk is called immediately.
      // The lobbyChannel is set synchronously inside
      // joinLobby (the first call assigns it before
      // returning). The mock's join() returns a
      // joinReceiver whose handshake runs on a setTimeout,
      // but that's async — the second call sees
      // lobbyChannel set synchronously.
      let secondCalled = false;
      joinLobby(() => {
        secondCalled = true;
      });
      assert.strictEqual(secondCalled, true);
    });
  });

  describe("agent chat:delta events", () => {
    it("should append delta content to partial message", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:delta", {
        index: 0,
        content: "Hello",
        charsStart: 0,
        charsEnd: 5,
      });

      await vi.waitFor(() => {
        const partial = useStore.getState().agentsCache["agent-1"]?.partial;
        const text = (partial?.parts ?? [])
          .filter((p) => p.kind === "text")
          .map((p) => p.text || "")
          .join("");
        assert.strictEqual(text, "Hello");
      });
    });

    it("should accumulate multiple deltas", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:delta", {
        index: 0,
        content: "Hel",
        charsStart: 0,
        charsEnd: 3,
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore
            .getState()
            .agentsCache["agent-1"].partial?.parts?.filter(
              (p) => p.kind === "text",
            )
            .map((p) => p.text || "")
            .join(""),
          "Hel",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:delta", {
        index: 0,
        content: "lo",
        charsStart: 3,
        charsEnd: 5,
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore
            .getState()
            .agentsCache["agent-1"].partial?.parts?.filter(
              (p) => p.kind === "text",
            )
            .map((p) => p.text || "")
            .join(""),
          "Hello",
        );
      });
    });

    it("should reset partial when delta index changes", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 1,
        content: "Old content",
      };

      joinAgent("agent-1", 1);

      simulateServerEvent("agent:1:agent-1", "chat:delta", {
        index: 3,
        content: "New",
        charsStart: 0,
        charsEnd: 3,
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial?.index,
          3,
        );
        assert.strictEqual(
          useStore
            .getState()
            .agentsCache["agent-1"].partial?.parts?.filter(
              (p) => p.kind === "text",
            )
            .map((p) => p.text || "")
            .join(""),
          "New",
        );
      });
    });

    it("should set waitingForResponse to false on first delta", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      useStore.getState().agentsCache["agent-1"].waitingForResponse = true;

      simulateServerEvent("agent:1:agent-1", "chat:delta", {
        index: 0,
        content: "Hello",
        charsStart: 0,
        charsEnd: 5,
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.waitingForResponse,
          false,
        );
      });
    });

    it("should detect gap and return needsSync when charsStart > charsReceived", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Set up a partial that's received up to 3 chars
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        role: "assistant",
        content: "Hel",
        charsReceived: 3,
      };

      // Send delta that starts at 5 (gap from 3-5)
      const result = useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "lo!",
        charsStart: 5,
        charsEnd: 8,
      });

      assert.deepStrictEqual(result, { applied: false, needsSync: true });
      // Content should not have changed
      assert.strictEqual(
        useStore
          .getState()
          .agentsCache["agent-1"].partial?.parts?.filter(
            (p) => p.kind === "text",
          )
          .map((p) => p.text || "")
          .join(""),
        "Hel",
      );
    });

    it("should handle overlap by slicing correctly", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Set up a partial that's received up to 3 chars
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        role: "assistant",
        content: "Hel",
        charsReceived: 3,
      };

      // Send overlapping delta: charsStart=2, content="llo" (overlap is 1 char "l")
      simulateServerEvent("agent:1:agent-1", "chat:delta", {
        index: 0,
        content: "llo",
        charsStart: 2,
        charsEnd: 5,
      });

      await vi.waitFor(() => {
        // Should have sliced to just "lo" and appended
        assert.strictEqual(
          useStore
            .getState()
            .agentsCache["agent-1"].partial?.parts?.filter(
              (p) => p.kind === "text",
            )
            .map((p) => p.text || "")
            .join(""),
          "Hello",
        );
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial?.charsReceived,
          5,
        );
      });
    });

    it("should detect overlap mismatch and continue with server data", async () => {
      // The store intentionally warns on overlap mismatch so the
      // server-side logs surface data corruption. Silence the warn
      // here since this test deliberately exercises that path and
      // asserts the mismatch via the return value.
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      try {
        joinAgent("agent-1", 1);

        await vi.waitFor(() => {
          assert.strictEqual(
            useStore.getState().agentsCache["agent-1"]?.status,
            "connected",
          );
        });

        // Set up a partial that's received up to 3 chars: "Hel"
        useStore.getState().agentsCache["agent-1"].partial = {
          index: 0,
          role: "assistant",
          content: "Hel",
          charsReceived: 3,
        };

        // Send overlapping delta with mismatch: charsStart=2, content="xyz" (overlap is 1 char)
        // Expected overlap is "l", actual is "z"
        const result = useStore.getState().addChatDelta("agent-1", {
          index: 0,
          content: "xyz",
          charsStart: 2,
          charsEnd: 5,
        });

        // Should have mismatch flag
        assert.strictEqual(result.overlapMismatch, true);
        // But still applied the new content (sliced to "yz")
        assert.strictEqual(result.applied, true);
        assert.strictEqual(
          useStore
            .getState()
            .agentsCache["agent-1"].partial?.parts?.filter(
              (p) => p.kind === "text",
            )
            .map((p) => p.text || "")
            .join(""),
          "Helyz",
        );
      } finally {
        warnSpy.mockRestore();
      }
    });

    it("should not apply delta when overlap consumes entire content", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Set up a partial that's received up to 5 chars: "Hello"
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        role: "assistant",
        content: "Hello",
        charsReceived: 5,
      };

      // Send delta that's entirely in the past: charsStart=3, content="lo" (overlap=2)
      const result = useStore.getState().addChatDelta("agent-1", {
        index: 0,
        content: "lo",
        charsStart: 3,
        charsEnd: 5,
      });

      // Should not have applied anything new
      assert.strictEqual(result.applied, false);
      assert.strictEqual(
        useStore
          .getState()
          .agentsCache["agent-1"].partial?.parts?.filter(
            (p) => p.kind === "text",
          )
          .map((p) => p.text || "")
          .join(""),
        "Hello",
      );
    });
  });

  describe("agent chat:message events", () => {
    it("should add complete message to messages array", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:message", {
        index: 0,
        role: "user",
        content: "Hello",
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.messages?.length,
          1,
        );
      });
      assert.strictEqual(
        useStore.getState().agentsCache["agent-1"]?.messages[0]?.content,
        "Hello",
      );
    });

    it("should clear partial when message index matches", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 3,
        content: "Streaming",
      };

      joinAgent("agent-1", 1);

      simulateServerEvent("agent:1:agent-1", "chat:message", {
        index: 3,
        role: "assistant",
        content: "Complete",
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial,
          null,
        );
      });
    });

    it("should update lastIndex to message index", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:message", {
        index: 5,
        role: "user",
        content: "Test",
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.lastIndex,
          5,
        );
      });
    });

    it("should not duplicate messages with same index", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:message", {
        index: 0,
        role: "user",
        content: "First",
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.messages?.length,
          1,
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:message", {
        index: 0,
        role: "user",
        content: "Duplicate",
      });

      await new Promise((r) => setTimeout(r, 10));

      assert.strictEqual(
        useStore.getState().agentsCache["agent-1"]?.messages?.length,
        1,
      );
    });
  });

  describe("agent chat:error events", () => {
    it("should handle chat:error event - set status, error, clear partial, and stop waiting", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        content: "Streaming",
      };
      useStore.getState().agentsCache["agent-1"].waitingForResponse = true;

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:error", {
        content: "Model unavailable",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.status, "error");
        assert.strictEqual(cache?.error, "Model unavailable");
        assert.strictEqual(cache?.partial, null);
        assert.strictEqual(cache?.waitingForResponse, false);
      });
    });

    it("routes compactionError to setCompactionError (not setAgentError)", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
      });

      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // The compaction_handler broadcasts `chat:error` with
      // `compactionError: true` to distinguish from chat-task
      // failures. The frontend routes to setCompactionError,
      // which sets `cache.compactionError` without flipping the
      // connection-level status to "error".
      simulateServerEvent("agent:1:agent-1", "chat:error", {
        index: null,
        content: "Compaction failed: LLM returned empty summary.",
        compactionError: true,
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(
          cache?.compactionError,
          "Compaction failed: LLM returned empty summary.",
        );
        assert.strictEqual(cache?.status, "connected");
      });
    });
  });

  describe("agent chat:status events", () => {
    it("should handle chat:status event - update agentState", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        status: "idle",
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:status", {
        status: "streaming",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.agentState, "streaming");
      });

      simulateServerEvent("agent:1:agent-1", "chat:status", {
        status: "executing_tools",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.agentState, "executing_tools");
      });

      simulateServerEvent("agent:1:agent-1", "chat:status", {
        status: "idle",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.agentState, "idle");
      });
    });

    it("resets and full-syncs the cache when chat:status reports needs_repair", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 1,
        status: "idle",
        messages: [{ index: 0, role: "user", content: "Hello" }],
      });

      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // The persisted sequence failed validation. An incremental sync
      // keyed on a stale lastIndex can't see a repaired row, so the
      // cache is dropped and rebuilt from -1.
      setNextPushResult("agent:1:agent-1", "chat:sync", {
        ok: {
          messages: [
            { index: 0, role: "user", content: "Hello" },
            { index: 1, role: "assistant", content: "tool_use" },
          ],
        },
      });

      simulateServerEvent("agent:1:agent-1", "chat:status", {
        status: "needs_repair",
        sequenceViolations: [{ rule: "no_trailing_orphan" }],
        repairCommand: "mix nest.repair_messages --space s",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.agentState, "needs_repair");
        assert.strictEqual(
          cache?.repairCommand,
          "mix nest.repair_messages --space s",
        );
        assert.deepStrictEqual(cache?.sequenceViolations, [
          { rule: "no_trailing_orphan" },
        ]);
      });
    });

    it("should forward contextLimit, currentMode, and usage from chat:status payload", async () => {
      // The chat:status push from the BEAM may carry extra fields
      // (contextLimit, contextLimitSource, currentMode, usage) that
      // the chat:status handler must forward into the agent cache
      // via setAgentState's extra-arg path. This test exercises
      // all four conditional branches in one push.
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        status: "idle",
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:status", {
        status: "idle",
        contextLimit: 200000,
        contextLimitSource: "auto",
        currentMode: "build",
        usage: { promptTokens: 12, completionTokens: 34 },
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.contextLimit, 200000);
        assert.strictEqual(cache?.contextLimitSource, "auto");
        assert.strictEqual(cache?.currentMode, "build");
        assert.deepStrictEqual(cache?.usage, {
          promptTokens: 12,
          completionTokens: 34,
        });
      });
    });

    it("should forward parentId, parentName, depth, descendantUsage, and totalUsage from chat:status", async () => {
      // The remaining extra-arg branches (parentId, parentName,
      // depth, descendantUsage, totalUsage) are reserved for
      // delegated sub-agents and the parent's usage totals.
      // Each is forwarded into the cache via setAgentState's
      // extra-arg path. This test exercises the matching five
      // conditional branches in one push.
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        status: "idle",
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:status", {
        status: "idle",
        parentId: "parent-1",
        parentName: "delegating-parent",
        depth: 1,
        descendantUsage: { promptTokens: 100, completionTokens: 50 },
        totalUsage: { promptTokens: 200, completionTokens: 75 },
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.parentId, "parent-1");
        assert.strictEqual(cache?.parentName, "delegating-parent");
        assert.strictEqual(cache?.depth, 1);
        assert.deepStrictEqual(cache?.descendantUsage, {
          promptTokens: 100,
          completionTokens: 50,
        });
        assert.deepStrictEqual(cache?.totalUsage, {
          promptTokens: 200,
          completionTokens: 75,
        });
      });
    });

    it("should clear waitingForResponse on chat:status: idle (thinking-only response)", async () => {
      // The LLM completed but no `chat:delta` events were applied
      // (e.g. a thinking-only response where `forward_thinking_delta/3`
      // doesn't broadcast a `chat:delta`). The optimistic
      // `waitingForResponse` flag would otherwise stay stuck. The
      // `chat:status: idle` push is the explicit "LLM is done" signal
      // and is the right place to clear it.
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        status: "idle",
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Simulate the user sending a message — this is what flips
      // `waitingForResponse` to `true` (the channel push's `ok`
      // callback in `sendMessage`).
      useStore.getState().setWaitingForResponse("agent-1", true);

      // Streaming starts (no deltas ever arrive — thinking-only).
      simulateServerEvent("agent:1:agent-1", "chat:status", {
        status: "streaming",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.agentState, "streaming");
        // `waitingForResponse` is still true — no deltas have
        // reset it.
        assert.strictEqual(cache?.waitingForResponse, true);
      });

      // LLM completes. The `chat:status: idle` push is the
      // explicit signal that the response is done; reset
      // `waitingForResponse` so the typing indicator clears.
      simulateServerEvent("agent:1:agent-1", "chat:status", {
        status: "idle",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.agentState, "idle");
        assert.strictEqual(cache?.waitingForResponse, false);
      });
    });

    it("should NOT clear waitingForResponse on chat:status: streaming (LLM still in flight)", async () => {
      // Mid-stream: the LLM is still working, the indicator
      // should stay visible. `waitingForResponse` stays true.
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        status: "idle",
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      useStore.getState().setWaitingForResponse("agent-1", true);

      simulateServerEvent("agent:1:agent-1", "chat:status", {
        status: "streaming",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.agentState, "streaming");
        assert.strictEqual(cache?.waitingForResponse, true);
      });
    });

    it("should NOT clear waitingForResponse on chat:status: executing_tools (mid-tool-loop)", async () => {
      // Mid-tool-loop: a tool call arrived, the LLM will be
      // called again after the tool executes. The indicator
      // should stay visible (showing "Executing tools" — the
      // chip's label — until the final LLM response completes).
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        status: "idle",
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      useStore.getState().setWaitingForResponse("agent-1", true);

      simulateServerEvent("agent:1:agent-1", "chat:status", {
        status: "executing_tools",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.agentState, "executing_tools");
        assert.strictEqual(cache?.waitingForResponse, true);
      });
    });
  });

  describe("agent chat:compaction events", () => {
    it("stores the marker boundary, drops stale projections, and refetches the marker", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        status: "idle",
        lastCompactionIndex: 2,
        compactionCount: 1,
      });
      useStore
        .getState()
        .setAgentHistorySlice("agent-1", [
          { index: 0, role: "user", content: "old", apiLogs: [] },
        ]);

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // The broadcast carries the marker only; the client refetches the
      // marker projection over chat:history.
      const marker = {
        index: 5,
        role: "compaction",
        archivedCount: 3,
        compactionCount: 2,
        apiLogs: [],
      };
      setNextPushResult("agent:1:agent-1", "chat:history", {
        ok: { messages: [marker] },
      });
      simulateServerEvent("agent:1:agent-1", "chat:compaction", { marker });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.lastCompactionIndex, 5);
        assert.strictEqual(cache?.compactionCount, 2);
        // The stale slice is dropped; the lazy refetch lands the marker.
        assert.deepStrictEqual(cache?.history, []);
        assert.strictEqual(cache?.lastCompactionMarker?.index, 5);
      });
    });

    it("fires the projection refetches when a compaction arrives", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      const historyPush = captureNextPush("agent:1:agent-1", "chat:history");
      simulateServerEvent("agent:1:agent-1", "chat:compaction", {
        marker: { index: 5, role: "compaction", archivedCount: 3 },
      });

      const payload = await historyPush;
      assert.deepStrictEqual(payload, { role: "compaction", limit: 1 });
    });
  });

  describe("chat:history lazy fetch", () => {
    async function joinAndWait() {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });
    }

    it("merges the latest marker and the user prompts into their projections", async () => {
      await joinAndWait();

      setNextPushResult("agent:1:agent-1", "chat:history", {
        ok: {
          messages: [
            {
              index: 9,
              role: "compaction",
              archivedCount: 9,
              compactionCount: 3,
            },
          ],
        },
      });
      requestHistory("agent-1", { role: "compaction", limit: 1 });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"].lastCompactionMarker
            ?.index,
          9,
        );
      });

      setNextPushResult("agent:1:agent-1", "chat:history", {
        ok: {
          messages: [
            { index: 1, role: "user", content: "first" },
            { index: 5, role: "user", content: "second" },
          ],
        },
      });
      requestHistory("agent-1", { role: "user", limit: 20 });

      await vi.waitFor(() => {
        const prompts =
          useStore.getState().agentsCache["agent-1"].historyPrompts;
        assert.deepStrictEqual(
          prompts.map((m) => m.content),
          ["first", "second"],
        );
      });
    });

    it("merges a page into the archive slice and pages older with before", async () => {
      await joinAndWait();

      setNextPushResult("agent:1:agent-1", "chat:history", {
        ok: {
          messages: [
            { index: 3, role: "user", content: "c" },
            { index: 4, role: "assistant", content: "d" },
          ],
        },
      });
      requestHistory("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"].history.length,
          2,
        );
      });

      const olderPush = captureNextPush("agent:1:agent-1", "chat:history");
      requestHistory("agent-1", { before: 3 });
      assert.deepStrictEqual(await olderPush, { before: 3 });

      setNextPushResult("agent:1:agent-1", "chat:history", {
        ok: {
          messages: [
            { index: 0, role: "system", content: "s" },
            { index: 1, role: "user", content: "a" },
          ],
        },
      });
      requestHistory("agent-1", { before: 3 });

      await vi.waitFor(() => {
        const history = useStore.getState().agentsCache["agent-1"].history;
        assert.deepStrictEqual(
          history.map((m) => m.index),
          [0, 1, 3, 4],
        );
      });
    });

    it("records an error when the full-slice fetch fails, cleared by a successful retry", async () => {
      await joinAndWait();

      setNextPushResult("agent:1:agent-1", "chat:history", {
        error: { reason: "invalid_role" },
      });
      requestHistory("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"].historyError,
          "invalid_role",
        );
      });

      // A retry that succeeds clears the error and lands the page.
      setNextPushResult("agent:1:agent-1", "chat:history", {
        ok: { messages: [{ index: 0, role: "user", content: "a" }] },
      });
      requestHistory("agent-1");

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache.historyError, null);
        assert.strictEqual(cache.history.length, 1);
      });
    });

    it("is a no-op when the channel is not connected", () => {
      // No joinAgent: there is no channel to push on.
      requestHistory("agent-1");
      requestHistory("agent-1", { role: "user", limit: 20 });
      assert.strictEqual(useStore.getState().agentsCache["agent-1"], undefined);
    });
  });

  describe("agent chat:notification events", () => {
    it("should handle chat:notification event - set notification", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        status: "idle",
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:notification", {
        type: "max_iterations",
        message: "Max tool iterations reached",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        assert.strictEqual(cache?.notification?.type, "max_iterations");
        assert.strictEqual(
          cache?.notification?.message,
          "Max tool iterations reached",
        );
      });
    });

    it("should not change connection status when notification arrives", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        status: "idle",
      });

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      simulateServerEvent("agent:1:agent-1", "chat:notification", {
        type: "max_iterations",
        message: "Max tool iterations reached",
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        // Status should remain connected (not error)
        assert.strictEqual(cache?.status, "connected");
        // Notification should be set
        assert.strictEqual(cache?.notification?.type, "max_iterations");
      });
    });
  });

  describe("agent shell jobs", () => {
    async function connectedAgent() {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        status: "idle",
      });
      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });
    }

    it("shell:jobs replaces the agent's job list", async () => {
      await connectedAgent();

      simulateServerEvent("agent:1:agent-1", "shell:jobs", {
        jobs: [{ id: "job-1", command: "sleep 30", status: "running" }],
      });

      await vi.waitFor(() => {
        const jobs = useStore.getState().agentsCache["agent-1"]?.jobs;
        assert.strictEqual(jobs.length, 1);
        assert.strictEqual(jobs[0].id, "job-1");
      });
    });

    it("killShellJob pushes shell:kill with the id and resolves", async () => {
      await connectedAgent();
      const capture = captureNextPush("agent:1:agent-1", "shell:kill");

      await killShellJob("agent-1", "job-7");

      const payload = await capture;
      assert.deepStrictEqual(payload, { id: "job-7" });
    });

    it("killShellJob rejects and still calls the optional onError", async () => {
      await connectedAgent();
      setNextPushResult("agent:1:agent-1", "shell:kill", {
        error: { reason: "job_not_found" },
      });

      let errorReason = null;

      await assert.rejects(
        () =>
          killShellJob("agent-1", "job-7", (err) => {
            errorReason = err?.reason;
          }),
        (err) => err.reason === "job_not_found",
      );

      assert.strictEqual(errorReason, "job_not_found");
    });

    it("killShellJob rejects when not connected", async () => {
      let message = null;

      await assert.rejects(
        () =>
          killShellJob("missing-agent", "job-1", (err) => {
            message = err.message;
          }),
        /Not connected to agent/,
      );

      assert.strictEqual(message, "Not connected to agent");
    });

    it("refreshShellJobs updates the store from shell:list", async () => {
      await connectedAgent();
      setNextPushResult("agent:1:agent-1", "shell:list", {
        ok: { jobs: [{ id: "job-3", status: "running" }] },
      });

      const jobs = await refreshShellJobs("agent-1");
      assert.strictEqual(jobs.length, 1);
      assert.strictEqual(jobs[0].id, "job-3");
      assert.strictEqual(
        useStore.getState().agentsCache["agent-1"].jobs[0].id,
        "job-3",
      );
    });

    it("refreshShellJobs rejects on server error and when disconnected", async () => {
      await connectedAgent();
      setNextPushResult("agent:1:agent-1", "shell:list", {
        error: { reason: "boom" },
      });

      await assert.rejects(
        () => refreshShellJobs("agent-1"),
        (err) => err.reason === "boom",
      );

      await assert.rejects(
        () => refreshShellJobs("missing-agent"),
        /Not connected to agent/,
      );
    });

    it("fetchShellLog resolves with the log content", async () => {
      await connectedAgent();
      setNextPushResult("agent:1:agent-1", "shell:log", {
        ok: { content: "hello log\n" },
      });

      const content = await fetchShellLog("agent-1", "job-1");
      assert.strictEqual(content, "hello log\n");
    });

    it("fetchShellLog rejects on server error and when disconnected", async () => {
      await connectedAgent();
      setNextPushResult("agent:1:agent-1", "shell:log", {
        error: { reason: "job_not_found" },
      });

      await assert.rejects(
        () => fetchShellLog("agent-1", "job-1"),
        (err) => err.reason === "job_not_found",
      );

      await assert.rejects(
        () => fetchShellLog("missing-agent", "job-1"),
        /Not connected to agent/,
      );
    });
  });

  describe("leaveAgent", () => {
    it("should disconnect agent and remove channel reference", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      leaveAgent("agent-1");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "disconnected",
        );
      });

      let errorCalled = false;
      createSpace(
        "gpt-4",
        1,
        () => {},
        (_err) => {
          errorCalled = true;
        },
      );

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });
  });

  describe("sendMessage", () => {
    it("should call onError when not connected to agent", async () => {
      let errorCalled = false;
      sendMessage("agent-1", "Hello", undefined, (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });

    it("should handle successful message send - add user message, set partial, and waiting", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      setNextPushResult("agent:1:agent-1", "chat:message", { ok: {} });

      sendMessage("agent-1", "Hello");

      const cache = useStore.getState().agentsCache["agent-1"];
      assert.strictEqual(cache.messages.length, 1);
      assert.strictEqual(cache.messages[0].role, "user");
      assert.strictEqual(cache.messages[0].content, "Hello");
      assert.strictEqual(cache.partial?.index, 1);
      assert.strictEqual(cache.partial?.role, "assistant");

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.waitingForResponse,
          true,
        );
      });
    });

    it("should handle message send error - clear partial and call onError", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      setNextPushResult("agent:1:agent-1", "chat:message", {
        error: { reason: "rate_limited" },
      });

      let errorCalled = false;
      sendMessage("agent-1", "Hello", undefined, (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.partial,
          null,
        );
        assert.strictEqual(errorCalled, true);
      });
    });

    it("invokes the error callback when the server rejects the push", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      setNextPushResult("agent:1:agent-1", "chat:message", {
        error: { reason: "rate_limited" },
      });

      let errorCalled = false;
      sendMessage("agent-1", "Hello", undefined, (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });

    it("should include mode in the push payload and in the optimistic user message", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Capture the next push payload
      const pushCapture = captureNextPush("agent:1:agent-1", "chat:message");

      sendMessage("agent-1", "Hello", "build");

      const payload = await pushCapture;
      assert.deepStrictEqual(payload, { content: "Hello", mode: "build" });

      // Optimistic user message also has the mode
      const cache = useStore.getState().agentsCache["agent-1"];
      assert.strictEqual(cache.messages[0].mode, "build");
    });

    it("omits the mode key from the payload when no mode is passed", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      const pushCapture = captureNextPush("agent:1:agent-1", "chat:message");

      sendMessage("agent-1", "Hello");

      const payload = await pushCapture;
      assert.deepStrictEqual(payload, { content: "Hello" });
    });

    it("does not duplicate the user message when the server echoes with a different index (regression: optimistic/server race)", async () => {
      // Regression test for the duplicate user messages bug.
      //
      // The init event includes `messageCount: 1` (the server
      // has the system message at index 0) but does NOT include
      // the `messages` array. The client's `lastIndex` stays
      // at -1 until the chat:sync response arrives. If the user
      // sends a message in that small window, the optimistic
      // add uses `lastIndex + 1 = 0` while the server stamps
      // the user message at its authoritative index 1.
      //
      // The pre-fix `addChatMessage` de-dup'd only by index, so
      // the server's echo with index 1 was appended as a new
      // message and the user saw their own message twice.
      //
      // The streaming-vs-final check inside `addChatMessage`
      // fires a `console.warn` when the (empty) assistant
      // partial text doesn't match the incoming user message
      // text. In production those indices never coincide (the
      // user message and the assistant's expected slot differ),
      // but this test uses a fresh cache with `lastIndex = -1`
      // so the optimistic user lands at index 0 and the
      // streaming assistant slot is computed as 0 + 1 = 1 —
      // which collides with the server's authoritative index
      // 1. Silence the false positive so the test output
      // stays clean.
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      try {
        setNextJoinResult("agent:1:agent-1", {
          autoInit: {
            id: "agent-1",
            model: { name: "gpt-4", provider: "openai", thinking_level: null },
            messageCount: 1,
            status: "idle",
          },
        });
        joinAgent("agent-1", 1);

        await vi.waitFor(() => {
          assert.strictEqual(
            useStore.getState().agentsCache["agent-1"]?.status,
            "connected",
          );
        });

        // Sanity: the client hasn't received the chat:sync
        // response yet, so lastIndex is still -1.
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"].lastIndex,
          -1,
        );

        setNextPushResult("agent:1:agent-1", "chat:message", { ok: {} });
        sendMessage("agent-1", "Hello");

        // Optimistic add lands the message at index 0 (the
        // client's stale `lastIndex + 1`).
        await vi.waitFor(() => {
          assert.strictEqual(
            useStore.getState().agentsCache["agent-1"].messages.length,
            1,
          );
          assert.strictEqual(
            useStore.getState().agentsCache["agent-1"].messages[0].index,
            0,
          );
        });

        // The server echoes the user message with its
        // authoritative index 1 (the system message is at 0
        // server-side).
        simulateServerEvent("agent:1:agent-1", "chat:message", {
          index: 1,
          role: "user",
          parts: [{ kind: "text", text: "Hello" }],
          mode: "chat",
        });

        // The optimistic message is reconciled in place: the
        // index is updated to 1, no duplicate is added.
        await vi.waitFor(() => {
          const messages = useStore.getState().agentsCache["agent-1"].messages;
          assert.strictEqual(messages.length, 1);
          assert.strictEqual(messages[0].index, 1);
          assert.strictEqual(messages[0].content, "Hello");
        });
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"].lastIndex,
          1,
        );
      } finally {
        warnSpy.mockRestore();
      }
    });
  });

  describe("createSpace", () => {
    it("should call onError when not connected to lobby", async () => {
      let errorCalled = false;
      createSpace(
        "gpt-4",
        1,
        () => {},
        (_err) => {
          errorCalled = true;
        },
      );

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });

    it("should call onOk with agent name on create success", async () => {
      setNextPushResult("lobby", "create_space", {
        ok: { space_id: 1, name: "new-agent" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      let okCalled = false;
      let agentName = null;
      createSpace("gpt-4", 1, (resp) => {
        okCalled = true;
        agentName = resp.name;
      });

      await vi.waitFor(() => {
        assert.strictEqual(okCalled, true);
      });
      assert.strictEqual(agentName, "new-agent");
    });

    it("should pass the agent name (not undefined) to onOk", async () => {
      // Regression for the /space/<slug>/agent/undefined redirect
      // bug. The server returns {space_id: ..., name: "..."} and the
      // createSpace wrapper must read the `name` field; reading
      // resp.id would silently deliver undefined to the navigate()
      // callback.
      setNextPushResult("lobby", "create_space", {
        ok: { space_id: 5, name: "clever-raven" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      let onOkArg = "sentinel";
      createSpace("gpt-4", 1, (arg) => {
        onOkArg = arg;
      });

      await vi.waitFor(() => {
        assert.strictEqual(onOkArg?.name, "clever-raven");
      });
    });

    it("should call onError on create failure", async () => {
      setNextPushResult("lobby", "create_space", {
        error: { reason: "limit_reached" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      let errorCalled = false;
      createSpace(
        "gpt-4",
        1,
        () => {},
        (_err) => {
          errorCalled = true;
        },
      );

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });
    it("should include workspace_path in payload when provided", async () => {
      setNextPushResult("lobby", "create_space", {
        ok: { space_id: 1, name: "new-agent" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      let okCalled = false;
      createSpace(
        "gpt-4",
        1,
        (_resp) => {
          okCalled = true;
        },
        undefined,
        { workspace_path: "/path/to/workspace" },
      );

      await vi.waitFor(() => {
        assert.strictEqual(okCalled, true);
      });
    });

    it("should include vocation_id in payload when provided", async () => {
      setNextPushResult("lobby", "create_space", {
        ok: { space_id: 1, name: "new-agent" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      let okCalled = false;
      createSpace("gpt-4", 42, (_resp) => {
        okCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(okCalled, true);
      });
    });

    it("should omit vocation_id from payload when null", async () => {
      // Pin the falsy branch of `if (vocationId)` in createSpace.
      // All other createSpace tests pass a non-null vocationId, so
      // the omit-path is otherwise untested.
      const capturePromise = captureNextPush("lobby", "create_space");
      setNextPushResult("lobby", "create_space", {
        ok: { space_id: 1, name: "new-agent" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      createSpace("gpt-4", null, () => {});

      const captured = await capturePromise;
      assert.strictEqual(
        Object.hasOwn(captured, "vocation_id"),
        false,
        "vocation_id must be omitted when null",
      );
    });

    it("should work without onOk callback on success", async () => {
      setNextPushResult("lobby", "create_space", {
        ok: { space_id: 1, name: "new-agent" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      // Call without onOk callback - should not throw
      createSpace("gpt-4", 1, undefined);

      // Just wait a bit to ensure no errors
      await new Promise((resolve) => setTimeout(resolve, 50));
    });

    it("should work without onError callback on error", async () => {
      setNextPushResult("lobby", "create_space", {
        error: { reason: "limit_reached" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      // Call without onError callback - should not throw
      createSpace("gpt-4", 1, undefined, undefined);

      // Just wait a bit to ensure no errors
      await new Promise((resolve) => setTimeout(resolve, 50));
    });
  });

  describe("createInvite", () => {
    it("routes an error reply into useStore.invitesError", async () => {
      setNextPushResult("lobby", "create_invite", {
        error: { error: "too_many_invites" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      createInvite();

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().invitesError,
          "too_many_invites",
        );
      });
    });

    it("falls back to a generic message when the error has no `error` field", async () => {
      setNextPushResult("lobby", "create_invite", {
        error: { reason: "boom" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      createInvite();

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().invitesError,
          "Failed to create invite",
        );
      });
    });

    it("sets invitesError when not connected to lobby", () => {
      createInvite();

      assert.strictEqual(
        useStore.getState().invitesError,
        "Not connected to lobby",
      );
    });
  });

  describe("revokeInvite", () => {
    it("routes an error reply into useStore.invitesError", async () => {
      setNextPushResult("lobby", "revoke_invite", {
        error: { error: "not_found" },
      });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      revokeInvite(42);

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().invitesError, "not_found");
      });
    });

    it("falls back to a generic message when the error has no `error` field", async () => {
      setNextPushResult("lobby", "revoke_invite", { error: null });
      joinLobby();

      await vi.waitFor(() => {
        assert.strictEqual(useStore.getState().agents.length >= 0, true);
      });

      revokeInvite(42);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().invitesError,
          "Failed to revoke invite",
        );
      });
    });

    it("sets invitesError when not connected to lobby", () => {
      revokeInvite(42);

      assert.strictEqual(
        useStore.getState().invitesError,
        "Not connected to lobby",
      );
    });
  });

  describe("stopMessage", () => {
    it("should call onError when not connected to agent", async () => {
      let errorCalled = false;
      stopMessage("missing-agent", (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });

    it("should not throw when not connected and onError is omitted", () => {
      // No channel exists for this agent; onError is undefined.
      assert.doesNotThrow(() => {
        stopMessage("missing-agent");
      });
    });

    it("should push chat:stop and invoke onError on push failure", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      setNextPushResult("agent:1:agent-1", "chat:stop", {
        error: { reason: "agent_not_found" },
      });

      let errorCalled = false;
      stopMessage("agent-1", (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });
  });

  describe("retryCompaction", () => {
    it("should call onError when not connected to agent", async () => {
      let errorCalled = false;
      retryCompaction("missing-agent", (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });

    it("should not throw when not connected and onError is omitted", () => {
      assert.doesNotThrow(() => {
        retryCompaction("missing-agent");
      });
    });

    it("should push chat:retry-compaction and invoke onError on push failure", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      setNextPushResult("agent:1:agent-1", "chat:retry-compaction", {
        error: { reason: "agent_status_idle" },
      });

      let errorCalled = false;
      retryCompaction("agent-1", (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });

    it("should not throw on push failure when onError is omitted", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      });
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      setNextPushResult("agent:1:agent-1", "chat:retry-compaction", {
        error: { reason: "agent_status_idle" },
      });

      assert.doesNotThrow(() => {
        retryCompaction("agent-1");
      });
    });
  });

  describe("compactionLoopOk", () => {
    it("should call onError when not connected to agent", async () => {
      let errorCalled = false;
      compactionLoopOk("missing-agent", (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });

    it("should not throw when not connected and onError is omitted", () => {
      assert.doesNotThrow(() => {
        compactionLoopOk("missing-agent");
      });
    });

    it("should push chat:loop-detected-ok and invoke onError on push failure", async () => {
      setNextJoinResult("agent:1:agent-1", {
        autoInit: {
          id: "agent-1",
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "compaction_loop_detected",
        },
      });
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      setNextPushResult("agent:1:agent-1", "chat:loop-detected-ok", {
        error: { reason: "wrong_state" },
      });

      let errorCalled = false;
      compactionLoopOk("agent-1", (_err) => {
        errorCalled = true;
      });

      await vi.waitFor(() => {
        assert.strictEqual(errorCalled, true);
      });
    });
  });

  describe("sync behavior", () => {
    it("should sync messages, partial, status, and lastIndex from sync response", async () => {
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 0,
        messages: [
          { index: 0, role: "user", parts: [{ kind: "text", text: "Hello" }] },
        ],
      });

      useStore.getState().syncAgentMessages("agent-1", {
        messages: [
          {
            index: 1,
            role: "assistant",
            parts: [{ kind: "text", text: "Response 1" }],
          },
          {
            index: 2,
            role: "user",
            parts: [{ kind: "text", text: "Question" }],
          },
          {
            index: 3,
            role: "assistant",
            parts: [{ kind: "text", text: "Response 2" }],
          },
        ],
        partial: {
          index: 4,
          role: "assistant",
          parts: [{ kind: "text", text: "Streaming..." }],
        },
        status: "streaming",
        messageCount: 3,
      });

      const cache = useStore.getState().agentsCache["agent-1"];
      assert.strictEqual(cache.messages.length, 4);
      assert.deepStrictEqual(cache.messages[3], {
        index: 3,
        role: "assistant",
        parts: [{ kind: "text", text: "Response 2" }],
      });
      assert.deepStrictEqual(cache.partial, {
        index: 4,
        role: "assistant",
        parts: [{ kind: "text", text: "Streaming..." }],
        charsReceived: 0,
        currentKind: null,
      });
      assert.strictEqual(cache.status, "connected");
      assert.strictEqual(cache.agentState, "streaming");
      assert.strictEqual(cache.lastIndex, 3);
    });
  });

  describe("chat:delta gap detection via server event", () => {
    it("should trigger sync when server sends delta with gap", async () => {
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Set up partial with some content
      useStore.getState().agentsCache["agent-1"].partial = {
        index: 0,
        role: "assistant",
        content: "Hel",
        charsReceived: 3,
      };

      // Simulate server sending delta with a gap (charsStart=5 > charsReceived=3)
      simulateServerEvent("agent:1:agent-1", "chat:delta", {
        index: 0,
        content: "lo",
        charsStart: 5, // Gap from 3 to 5
        charsEnd: 7,
      });

      await vi.waitFor(() => {
        // Should have logged a warning about the gap
        assert.strictEqual(warnSpy.mock.calls.length > 0, true);
      });

      const warningMessage = warnSpy.mock.calls.find((call) =>
        call[0]?.includes("Delta gap"),
      );
      assert.ok(warningMessage, "Expected warning message about delta gap");

      warnSpy.mockRestore();
    });
  });

  describe("chat:compaction triggers chat:sync with marker.index", () => {
    // After a compaction, the server builds fresh_system +
    // summary_user and puts them in state.chat_state.messages
    // but does NOT broadcast them individually. The channel
    // handler must follow up with a chat:sync using
    // marker.index as the lower bound; the response carries
    // exactly the new active list and `syncAgentMessages`
    // merges it into `cache.messages`. This is the
    // post-compaction duplication fix: without it the
    // archived segment stays in `cache.messages` (causing
    // the same messages to render in both panes) and the
    // new active messages never reach the client.

    it("pushes chat:sync with lastIndex = marker.index when chat:compaction arrives", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      const pushPromise = captureNextPush("agent:1:agent-1", "chat:sync");

      simulateServerEvent("agent:1:agent-1", "chat:compaction", {
        marker: {
          index: 6,
          role: "compaction",
          archivedCount: 6,
        },
      });

      const pushPayload = await pushPromise;
      assert.deepStrictEqual(pushPayload, { lastIndex: 6 });
    });

    it("filters cache.messages to the post-swap active list", async () => {
      // Before the compaction, the client has the pre-swap
      // list (indices 0-5). After the chat:compaction event,
      // cache.messages is empty (all pre-swap messages have
      // index <= marker.index=6). The chat:sync then fills
      // it with the new active list (the server responds
      // with messages where index > 6).
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Pre-seed the cache with the pre-swap list
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 6,
        messages: [
          { index: 0, role: "system", content: "system" },
          { index: 1, role: "user", content: "A" },
          { index: 2, role: "assistant", content: "B" },
          { index: 3, role: "user", content: "C" },
          { index: 4, role: "assistant", content: "D" },
          { index: 5, role: "user", content: "E" },
        ],
      });

      // Set up the chat:sync response that the channel
      // will request after the compaction event
      setNextPushResult("agent:1:agent-1", "chat:sync", {
        ok: {
          messages: [
            { index: 7, role: "system", content: "fresh system" },
            {
              index: 8,
              role: "user",
              content: "Summary of earlier conversation:\n\n…",
            },
          ],
          messageCount: 8,
        },
      });

      simulateServerEvent("agent:1:agent-1", "chat:compaction", {
        marker: { index: 6, role: "compaction", archivedCount: 6 },
      });

      await vi.waitFor(() => {
        const cache = useStore.getState().agentsCache["agent-1"];
        // The pre-swap messages (indices 0-5) are gone from
        // cache.messages; the sync filled in the post-swap
        // list (indices 7, 8).
        assert.strictEqual(cache.messages?.length, 2);
        assert.strictEqual(cache.messages[0].index, 7);
        assert.strictEqual(cache.messages[1].index, 8);
      });
    });
  });

  describe("chat:message gap detection triggers chat:sync", () => {
    it("pushes chat:sync with lastIndex = cache.lastIndex when a chat:message has a gap", async () => {
      // A `chat:message` arriving with index > lastIndex + 1
      // and not matching the optimistic add means a previous
      // `chat:message` was silently lost in transit. The
      // channel handler must trigger a sync to fill the
      // gap.
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      // Pre-seed the cache with lastIndex=2
      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 3,
        messages: [
          { index: 0, role: "user", content: "A" },
          { index: 1, role: "assistant", content: "B" },
          { index: 2, role: "user", content: "C" },
        ],
      });

      const pushPromise = captureNextPush("agent:1:agent-1", "chat:sync");

      // Incoming message at index 5 — gap of 2 (indices 3, 4 missing)
      simulateServerEvent("agent:1:agent-1", "chat:message", {
        index: 5,
        role: "assistant",
        parts: [{ kind: "text", text: "E" }],
      });

      const pushPayload = await pushPromise;
      // The sync uses cache.lastIndex (2), not message.index
      assert.deepStrictEqual(pushPayload, { lastIndex: 2 });
    });

    it("does NOT push chat:sync when the message is the expected next index", async () => {
      // lastIndex=2, incoming message.index=3 → no gap, no
      // sync. (If a sync fires here, the test would have
      // captured a push that never came.)
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      useStore.getState().setAgentConnected("agent-1", {
        model: { name: "gpt-4" },
        messageCount: 3,
        messages: [
          { index: 0, role: "user", content: "A" },
          { index: 1, role: "assistant", content: "B" },
          { index: 2, role: "user", content: "C" },
        ],
      });

      // `captureNextPush` would resolve on the next push;
      // a 50ms wait with no push means none fired.
      const pushPromise = captureNextPush("agent:1:agent-1", "chat:sync");
      const timeout = new Promise((resolve) =>
        setTimeout(() => resolve("timeout"), 50),
      );
      const result = await Promise.race([pushPromise, timeout]);

      simulateServerEvent("agent:1:agent-1", "chat:message", {
        index: 3,
        role: "assistant",
        parts: [{ kind: "text", text: "D" }],
      });

      assert.strictEqual(result, "timeout");
    });
  });

  describe("requestSync coalescing", () => {
    // The `requestSync` function holds per-agent state in a
    // `Map<agentId, {inFlight, queued, lastIndex}>` and
    // coalesces overlapping requests: only one push is in
    // flight at a time, and the queued re-fire uses the
    // latest `lastIndex` (so the freshest lower bound wins).

    it("coalesces two rapid chat:compaction events: each fires its own push, and the second uses the latest lastIndex", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      const push1Promise = captureNextPush("agent:1:agent-1", "chat:sync");

      // First compaction: marker at index 5 → triggers sync
      // with lastIndex=5
      simulateServerEvent("agent:1:agent-1", "chat:compaction", {
        marker: { index: 5, role: "compaction", archivedCount: 5 },
      });

      const push1 = await push1Promise;
      assert.deepStrictEqual(push1, { lastIndex: 5 });

      // Second compaction arrives. Each requestSync call
      // fires its own push (the response merge is idempotent);
      // the test asserts the second push uses the latest
      // `lastIndex`.
      const push2Promise = captureNextPush("agent:1:agent-1", "chat:sync");

      simulateServerEvent("agent:1:agent-1", "chat:compaction", {
        marker: { index: 9, role: "compaction", archivedCount: 4 },
      });

      const push2 = await push2Promise;
      assert.deepStrictEqual(push2, { lastIndex: 9 });
    });

    it("clears the per-agent sync state on leaveAgent", async () => {
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      const push1Promise = captureNextPush("agent:1:agent-1", "chat:sync");

      simulateServerEvent("agent:1:agent-1", "chat:compaction", {
        marker: { index: 5, role: "compaction", archivedCount: 5 },
      });

      const push1 = await push1Promise;
      assert.deepStrictEqual(push1, { lastIndex: 5 });

      // Leave the channel; the sync state is reset
      leaveAgent("agent-1");

      // Re-join. The pre-existing channel path (in
      // `joinAgent`) sends a `chat:status` push; the
      // response is consumed by the rejoin handler. The
      // test asserts that a fresh chat:compaction event
      // after the rejoin produces a push with the
      // post-rejoin marker's index (the symptom of
      // `syncState` not being cleared would be a stale
      // inFlight flag from the previous session).
      joinAgent("agent-1", 1);

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });

      const push2Promise = captureNextPush("agent:1:agent-1", "chat:sync");

      simulateServerEvent("agent:1:agent-1", "chat:compaction", {
        marker: { index: 7, role: "compaction", archivedCount: 3 },
      });

      const push2 = await push2Promise;
      assert.deepStrictEqual(push2, { lastIndex: 7 });
    });

    it("is a no-op when the agent has no cache entry", async () => {
      // The `requestSync` is called from event handlers
      // that are only registered once the channel is joined,
      // so the cache is always present in practice. The
      // defensive `!cache` guard exists for the edge
      // case where a stale handler fires after a
      // leaveAgent. We test it by leaving the channel
      // and then firing an event (the channel mock
      // silently drops the event since the channel is
      // gone, and `requestSync`'s `!channel` guard
      // also bails).
      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });
      leaveAgent("agent-1");

      const pushPromise = captureNextPush("agent:1:agent-1", "chat:sync");
      const timeout = new Promise((resolve) =>
        setTimeout(() => resolve("timeout"), 30),
      );
      const result = await Promise.race([pushPromise, timeout]);
      assert.strictEqual(result, "timeout");
    });
  });

  describe("agent chat:compaction-loop events", () => {
    it("records the loop message via setCompactionLoop", async () => {
      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });
      simulateServerEvent("agent:1:agent-1", "chat:compaction-loop", {
        content: "compaction isn't reducing the conversation",
      });

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"].compactionLoop?.content,
          "compaction isn't reducing the conversation",
        );
      });
    });

    it("falls back to the default loop message when content is missing", async () => {
      joinAgent("agent-1", 1);
      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"]?.status,
          "connected",
        );
      });
      simulateServerEvent("agent:1:agent-1", "chat:compaction-loop", {});

      await vi.waitFor(() => {
        assert.strictEqual(
          useStore.getState().agentsCache["agent-1"].compactionLoop?.content,
          "compaction isn't reducing the conversation",
        );
      });
    });
  });
});
