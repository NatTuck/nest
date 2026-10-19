/**
 * Pure helper functions + the initial state factory for the zustand store.
 * Split from `store/index.js` to keep that file under the source-line cap.
 */

/**
 * Initial state factory for store reset
 */
export const initialState = {
  isConnected: false,
  // True once a socket dial has closed or errored without connecting. Distinct
  // from `isConnected === false`, which is also the state before the handshake
  // lands; the gate at `/` uses this to stop rendering a spinner forever
  // (issue #95). It cannot distinguish a rejected token from an unreachable
  // server — see `initChannels` in `channels.js`.
  connectionFailed: false,
  // True once the lobby channel has joined (its join's `ok` reply). Distinct
  // from `isConnected`, which is only the socket handshake — a lobby push sent
  // between the two is refused.
  lobbyJoined: false,
  agents: [],
  archivedAgents: [],
  spaces: [],
  archivedSpaces: [],
  // Spaces whose work is held by the space edit's latch (`Nest.Agents.SpaceGate`),
  // by id. The banner is the only reader.
  pausedSpaces: [],
  blueprints: [],
  models: [],
  vocations: [],
  providers: [],
  // Stats for the persisted multimodal probe cache (`{entries,
  // oldest_age_s, path}`), as last reported by the lobby. `null` until
  // the server has answered — the providers page renders that as an
  // explicit "state unknown", never as an empty cache.
  probeCacheStats: null,
  suggestedName: null,
  // The space feed's cache, by space id: the notes at `/space/:slug`, the modes
  // the server says exist, and the mode a message from there asks for by
  // default. An entry exists only once the feed has been opened (see
  // `slices/spaceFeed.js`), so this is empty until then rather than one entry
  // per space.
  spaceFeeds: {},
  // The right-hand pane's state, by space id: the space's questions for the
  // user (#119) and the TODO lists (#120), plus the pane's browser-owned state
  // (collapsed, the open accordion row, the drafts and the save/drop marks). An
  // entry exists only once the first `pane:state` frame has arrived for that
  // space, so this is empty until then rather than one entry per space.
  panes: {},
  agentsCache: {},
  currentUser: null,
  invites: [],
  invitesError: null,
  archivedCollapsed: true,
  // Sidebar tree disclosure, keyed by the node keys built in
  // `assets/js/utils/agentTree.js` (`agentNodeKey` for a row,
  // `archivedGroupKey` for an `Archived (N)` group). Absent means collapsed, so
  // the default needs no entry. It lives here rather than in each row's
  // `useState` because collapsing an ancestor unmounts its subtree: a row's own
  // state would be lost on the way back. Entries are never pruned — the map
  // only holds the nodes the user actually opened, and keeping them is the
  // point: a node that leaves the tree and returns (an agent restored from the
  // archive, say) opens the way the user left it.
  expandedTreeNodes: {},
};

export const normalizeStreaming = (streaming) => {
  if (!streaming) return null;
  const { lastDeltaIndex, ...rest } = streaming;
  const { parts, currentKind } = legacyToParts(rest);
  return {
    ...rest,
    parts,
    currentKind,
    nextDeltaIndex: (lastDeltaIndex ?? -1) + 1,
  };
};

export const normalizePartial = (partial) => {
  if (!partial) return null;
  const { charsEnd, ...rest } = partial;
  const { parts, currentKind } = legacyToParts(rest);
  return {
    ...rest,
    parts,
    currentKind,
    charsReceived: charsEnd ?? 0,
  };
};

export const accumulatePart = (parts, _currentKind, content, partType) => {
  const kind = partType || "text";

  if (!Array.isArray(parts) || parts.length === 0) {
    return { parts: [newPart(kind, content)], currentKind: kind };
  }

  const last = parts[parts.length - 1];
  if (last.kind === kind) {
    const updated = [...parts];
    updated[updated.length - 1] = appendPart(last, content);
    return { parts: updated, currentKind: kind };
  }

  return { parts: [...parts, newPart(kind, content)], currentKind: kind };
};

export const newPart = (kind, content) => {
  if (kind === "thinking") {
    return { kind: "thinking", thinking: content };
  }
  if (kind === "refusal") {
    return { kind: "refusal", refusal: content };
  }
  if (kind === "tool_use") {
    return {
      kind: "tool_use",
      id: null,
      name: null,
      arguments: null,
      text: content,
    };
  }
  if (kind === "tool_result") {
    return {
      kind: "tool_result",
      toolCallId: null,
      name: null,
      content,
      isError: false,
      text: content,
    };
  }
  if (kind === "tool_arguments") {
    return { kind: "tool_arguments", text: content };
  }
  if (kind === "text") {
    return { kind: "text", text: content };
  }

  return { kind: "text", text: content };
};

export const appendPart = (last, content) => {
  if (last.kind === "thinking") {
    return { ...last, thinking: (last.thinking || "") + content };
  }
  if (last.kind === "refusal") {
    return { ...last, refusal: (last.refusal || "") + content };
  }
  return { ...last, text: (last.text || "") + content };
};

export const partialPartsToText = (parts) =>
  parts
    .filter((p) => p && p.kind === "text")
    .map((p) => p.text || "")
    .join("");

export const applyToolUseStart = (parts, { id, name }) => {
  if (parts.some((p) => p && p.kind === "tool_use" && p.id === id)) {
    return parts;
  }
  return [...parts, { kind: "tool_use", id, name, arguments: "" }];
};

export const applyPartDelta = (parts, partType, payload) => {
  if (partType === "tool_use_start") {
    return applyToolUseStart(parts, {
      id: payload.toolCallId,
      name: payload.toolCallName,
    });
  }
  if (partType === "tool_use_delta") {
    return applyToolUseDelta(parts, {
      id: payload.toolCallId,
      argumentsDelta: payload.content || "",
    });
  }
  return parts;
};

export const applyToolUseDelta = (parts, { id, argumentsDelta }) => {
  let found = false;
  const next = parts.map((p) => {
    if (p && p.kind === "tool_use" && p.id === id) {
      found = true;
      return { ...p, arguments: (p.arguments || "") + argumentsDelta };
    }
    return p;
  });
  return found ? next : parts;
};

export const legacyToParts = (acc) => {
  if (!acc) return { parts: [], currentKind: null };

  if (Array.isArray(acc.parts)) {
    return { parts: acc.parts, currentKind: acc.currentKind ?? null };
  }

  if (Array.isArray(acc.segments) || Array.isArray(acc.toolCalls)) {
    const toolCallById = new Map(
      (acc.toolCalls ?? []).map((tc) => [tc.id, tc]),
    );
    const parts = (acc.segments ?? []).map((seg) => {
      if (seg?.type === "thinking") {
        return { kind: "thinking", thinking: seg.content || "" };
      }
      if (seg?.type === "tool_use") {
        const tc = toolCallById.get(seg.id);
        return {
          kind: "tool_use",
          id: seg.id,
          name: tc?.name ?? "",
          arguments: tc?.arguments ?? "",
        };
      }
      return { kind: "text", text: seg.content || "" };
    });
    const seenIds = new Set(
      parts.filter((p) => p.kind === "tool_use").map((p) => p.id),
    );
    for (const tc of acc.toolCalls ?? []) {
      if (!seenIds.has(tc.id)) {
        parts.push({
          kind: "tool_use",
          id: tc.id,
          name: tc.name ?? "",
          arguments: tc.arguments ?? "",
        });
      }
    }
    const currentKind = Array.isArray(acc.currentType)
      ? (acc.currentType[0] ?? null)
      : (acc.currentType ?? null);
    return { parts, currentKind };
  }

  if (typeof acc.content === "string" && acc.content.length > 0) {
    return {
      parts: [{ kind: "text", text: acc.content }],
      currentKind: acc.currentType ?? "text",
    };
  }

  return { parts: [], currentKind: null };
};
