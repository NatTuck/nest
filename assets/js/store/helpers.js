/**
 * Pure helper functions + the initial state factory for the zustand store.
 * Split from `store/index.js` to keep that file under the source-line cap.
 */

/**
 * Initial state factory for store reset
 */
export const initialState = {
  isConnected: false,
  agents: [],
  spaces: [],
  archivedSpaces: [],
  blueprints: [],
  models: [],
  vocations: [],
  providers: [],
  suggestedName: null,
  agentsCache: {},
  currentUser: null,
  invites: [],
  invitesError: null,
  archivedCollapsed: true,
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
