/**
 * Catalog/sidebar setters for the zustand store: agents, spaces, models,
 * vocations, blueprints, broken agents. Split from `store/index.js`.
 */

export function catalogSetters(set) {
  return {
    setAgents: (agents) => {
      set({ agents: agents || [] });
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
      set((state) => ({
        agents: [
          ...state.agents,
          {
            name: agent.name,
            space_id: agent.space_id ?? agent.spaceId ?? null,
            model: agent.model,
            status: agent.status || "idle",
            parentId: agent.parentId ?? null,
            parentName: agent.parentName ?? null,
            depth: agent.depth ?? 0,
          },
        ],
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
