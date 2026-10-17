/**
 * The agent's current mode, as the UI sees it.
 *
 * The server's `state.mode` is the source of truth ("sticky mode"): it
 * emits the agent's mode on every `chat:status` push (specifically the one
 * that transitions to `idle` and unlocks the input), which the channel
 * layer writes to `cache.currentMode`. This hook mirrors that into React
 * state so the selector reflects what the server actually has, and pushes a
 * change back as a control-plane event rather than as a field on the next
 * message.
 *
 * The mode is a per-agent runtime property, so a change applies from the
 * agent's next turn and the server announces it in the transcript.
 */

import { useEffect, useState } from "react";
import { setAgentMode } from "../channels";

/**
 * @param {object} options
 * @param {string} options.name the agent whose mode this is
 * @param {string|null} options.currentModeFromCache the mode the server last
 *   reported for this agent, from its cache entry
 * @param {string|null} options.defaultMode the mode a new agent starts in,
 *   from the server (`Nest.Modes` and the blueprint's `default_mode`)
 * @param {(message: string|null) => void} options.onError receives a refusal
 *   message, or `null` before a push
 * @returns {{
 *   currentMode: string|null,
 *   setCurrentMode: (mode: string|null) => void,
 *   handleModeChange: (mode: string) => void,
 * }} the mode to show, a local override for prompt recall, and the push
 */
export function useAgentMode({
  name,
  currentModeFromCache,
  defaultMode,
  onError,
}) {
  const [currentMode, setCurrentMode] = useState(null);

  // On first mount (before any `chat:status` has arrived)
  // `currentModeFromCache` is null and we fall back to `defaultMode`.
  useEffect(() => {
    const next = currentModeFromCache ?? defaultMode;
    if (next) setCurrentMode(next);
  }, [currentModeFromCache, defaultMode]);

  // A control-plane push, not a field on the next message: the mode is
  // persisted, so it applies immediately and from the agent's next turn.
  // The optimistic update lives in the channel function; a refusal comes
  // back through `onError`.
  const handleModeChange = (mode) => {
    onError(null);
    setAgentMode(name, mode, (err) => {
      onError(
        err?.reason || err?.message || "Failed to change the agent's mode",
      );
    });
  };

  return { currentMode, setCurrentMode, handleModeChange };
}
