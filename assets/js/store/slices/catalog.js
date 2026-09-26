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
