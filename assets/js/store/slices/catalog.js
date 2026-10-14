/**
 * Catalog/sidebar setters for the zustand store: agents, spaces, models,
 * vocations, blueprints, broken agents. Split from `store/index.js`.
 */

export function catalogSetters(set) {
  return {
    setAgents: (agents) => {
      set({ agents: (agents || []).map(normalizeAgent) });
    },

    setModels: (models) => {
      set({ models });
    },

    setBrokenAgents: (brokenAgents) => {
      set({ brokenAgents: brokenAgents || [] });
    },

    setVocations: (vocations) => {
      set({ vocations });
    },

    setProviders: (providers) => {
      set({ providers: providers || [] });
    },

    /**
     * Replace the multimodal probe cache's stats — the lobby's
     * `probe_cache_stats` frame and the reply to `clear_probe_cache`
     * both carry them. `null` means "the server has not told us", which
     * the panel renders as an explicit unknown rather than as an empty
     * cache: "nothing is cached" and "we don't know" call for different
     * actions from the user.
     */
    setProbeCacheStats: (probeCacheStats) => {
      set({ probeCacheStats: probeCacheStats ?? null });
    },

    setSuggestedName: (suggestedName) => {
      set({ suggestedName: suggestedName || null });
    },

    setSpaces: (spaces) => {
      set({ spaces: spaces || [] });
    },

    setBlueprints: (blueprints) => {
      set({ blueprints: blueprints || [] });
    },

    addSpace: (space) => {
      set((state) => ({ spaces: [...state.spaces, space] }));
    },

    // Flip one tree node's disclosure. The key is the node's store key (see
    // `expandedTreeNodes` in `helpers.js` and the key builders in
    // `assets/js/utils/agentTree.js`); an unset key is collapsed. Keys are
    // never removed — see the note on `expandedTreeNodes`.
    toggleTreeNode: (key) => {
      set((state) => ({
        expandedTreeNodes: {
          ...state.expandedTreeNodes,
          [key]: !state.expandedTreeNodes[key],
        },
      }));
    },

    setArchivedSpaces: (archivedSpaces) => {
      set({ archivedSpaces: archivedSpaces || [] });
    },

    setArchivedAgents: (archivedAgents) => {
      set({ archivedAgents: (archivedAgents || []).map(normalizeAgent) });
    },

    archiveSpace: (spaceId) => {
      set((state) => {
        const space = state.spaces.find((s) => s.id === spaceId);
        if (!space) return state;
        return {
          spaces: state.spaces.filter((s) => s.id !== spaceId),
          archivedSpaces: [...state.archivedSpaces, space],
        };
      });
    },

    unarchiveSpace: (spaceId) => {
      set((state) => {
        const space = state.archivedSpaces.find((s) => s.id === spaceId);
        if (!space) return state;
        return {
          spaces: [...state.spaces, space],
          archivedSpaces: state.archivedSpaces.filter((s) => s.id !== spaceId),
        };
      });
    },

    addAgent: (agent) => {
      const normalized = normalizeAgent(agent);
      set((state) => ({
        agents: [
          ...state.agents.filter(
            (a) =>
              !(
                a.name === normalized.name && a.space_id === normalized.space_id
              ),
          ),
          normalized,
        ],
        archivedAgents: state.archivedAgents.filter(
          (a) =>
            !(a.name === normalized.name && a.space_id === normalized.space_id),
        ),
      }));
    },

    archiveAgent: ({ space_id, name }) => {
      set((state) => {
        const match = (a) => a.name === name && a.space_id === space_id;
        const agent = state.agents.find(match);
        const alreadyArchived = state.archivedAgents.some(match);
        const archivedAgents =
          agent && !alreadyArchived
            ? [...state.archivedAgents, { ...agent, archived: true }]
            : state.archivedAgents;
        return {
          agents: state.agents.filter((a) => !match(a)),
          archivedAgents,
        };
      });
    },

    unarchiveAgent: ({ space_id, name }) => {
      set((state) => {
        const match = (a) => a.name === name && a.space_id === space_id;
        const agent = state.archivedAgents.find(match);
        if (!agent) return state;
        const alreadyActive = state.agents.some(match);
        const agents = alreadyActive
          ? state.agents
          : [...state.agents, { ...agent, archived: false, status: "idle" }];
        return {
          agents,
          archivedAgents: state.archivedAgents.filter((a) => !match(a)),
        };
      });
    },

    /**
     * Apply a live status change from the lobby's `agent:status` frame
     * (#53). The sidebar dot reads `status` off the flat list; only the
     * matching `{space_id, name}` agent is replaced (with a new object, so
     * the tree re-renders), and a frame for an agent this client cannot
     * see is a no-op.
     */
    applyAgentStatus: ({ space_id, name, status }) => {
      set((state) => ({
        agents: state.agents.map((a) =>
          a.name === name && a.space_id === space_id ? { ...a, status } : a,
        ),
      }));
    },

    /**
     * Mark an agent stopped (#73).
     *
     * The server emits `agent:stopped` from the agent's own `terminate/2`, so
     * the row is marked only once the process is really gone. Without it a
     * stopped agent keeps the neutral `idle` that `normalizeAgent` gives a row
     * with no live process — the same lie `applyAgentStatuses` documents for
     * `model_missing`: a row with no process is not idle, and rendering it as
     * idle tells the user the opposite of the truth.
     *
     * A row that is not in `agents` is deliberately left alone. An archived
     * agent is also stopped, so its stop frame is redundant rather than
     * contradictory, and it arrives after `archiveAgent` has already moved the
     * row into `archivedAgents`; matching against the active list is what stops
     * that late frame from pulling the row back.
     */
    markAgentStopped: ({ space_id, name }) => {
      set((state) => ({
        agents: state.agents.map((a) =>
          a.name === name && a.space_id === space_id
            ? { ...a, status: "stopped" }
            : a,
        ),
      }));
    },

    /**
     * Stamp the lobby's `broken_agents` statuses onto the flat agent list
     * (#53).
     *
     * A persisted agent whose model no longer resolves has no live
     * process, so nothing ever broadcasts a status for it. The visibility
     * query still lists its row — deliberately, so the user can click
     * through and repair it — but with the placeholder `status: :idle` a
     * row with no live process gets. Rendered as-is that is a neutral
     * "Idle" dot, which tells the user the opposite of the truth: the
     * agent cannot start at all. The server already names the reason on
     * each broken entry (`status: :model_missing`), so stamp it onto the
     * matching `{space_id, name}` row and let the dot render it.
     *
     * `brokenAgents` is kept alongside the stamp: it is still the list of
     * rows that need repair, and `applyAgentModelUpdate` drops the agent
     * it just repaired from it.
     *
     * Note the stamp is only as fresh as the payload. The lobby fetches
     * `broken_agents` once per join (and again only when the client
     * itself repairs an agent), so an agent that stops being broken
     * without this client acting on it keeps the stamped status until the
     * next join. That is the same freshness the "Needs Repair" group had
     * before it was removed — no worse, but not self-clearing.
     */
    applyAgentStatuses: (brokenAgents) => {
      const list = brokenAgents || [];
      const stamped = new Map(
        list.map((broken) => [agentKey(broken), broken.status]),
      );

      set((state) => ({
        agents: state.agents.map((a) => {
          const status = stamped.get(agentKey(a));
          return status && status !== a.status ? { ...a, status } : a;
        }),
      }));
    },

    applyAgentModelUpdate: (name, model) => {
      set((state) => {
        const newAgents = state.agents.map((a) =>
          a.name === name ? { ...a, model, status: "idle" } : a,
        );
        const newCache = state.agentsCache[name]
          ? {
              ...state.agentsCache,
              [name]: { ...state.agentsCache[name], model },
            }
          : state.agentsCache;
        const newBroken = state.brokenAgents.filter((a) => a.name !== name);
        return {
          agents: newAgents,
          agentsCache: newCache,
          brokenAgents: newBroken,
        };
      });
    },

    applyAgentWorkspaceUpdate: (name, workspace_path) => {
      set((state) => {
        const newAgents = state.agents.map((a) =>
          a.name === name ? { ...a, workspace_path } : a,
        );
        const newCache = state.agentsCache[name]
          ? {
              ...state.agentsCache,
              [name]: { ...state.agentsCache[name], workspace_path },
            }
          : state.agentsCache;
        return { agents: newAgents, agentsCache: newCache };
      });
    },
  };
}

/**
 * Normalize an agent payload to the shape the sidebar tree reads.
 * Lobby `init` agents arrive with snake_case keys (`space_id`,
 * `parent_id`, `parent_name`) while `agent:created` /
 * `chat:status` payloads are camelCase; the tree needs
 * `parentName` either way.
 */
function normalizeAgent(agent) {
  return {
    ...agent,
    space_id: agent.space_id ?? agent.spaceId ?? null,
    status: agent.status || "idle",
    parentId: agent.parentId ?? agent.parent_id ?? null,
    parentName: agent.parentName ?? agent.parent_name ?? null,
    depth: agent.depth ?? 0,
  };
}

/**
 * The identity of an agent row within this slice: `{space_id, name}` is unique
 * across the whole lobby, since a space owns its agent names. Used to match a
 * broken-agent entry against its flat-list row without comparing whole
 * objects.
 *
 * Deliberately NOT `agentNodeKey` from `utils/agentTree.js`, even though the
 * two spellings are the same shape. They are different identities and must
 * never be compared: this one keys a *data* map local to
 * `applyAgentStatuses`, whose only two participants are agent rows
 * (`broken_agents` entries and `state.agents` entries), so no row of another
 * kind can ever meet it. `agentNodeKey` keys *UI disclosure* state, where
 * three row kinds share one map — that is the namespace collision #70 fixed
 * with its `a:` / `g:` / `space:` prefixes, and the reason an agent row, an
 * archived group and a space row can no longer spell out each other's keys.
 * Importing that prefix here would put a UI node key in a data slice; if this
 * identity ever does have to meet a tree key, route it through
 * `agentNodeKey` rather than open-coding the spelling.
 */
function agentKey({ space_id, name }) {
  return `${space_id}:${name}`;
}
