/**
 * The mode the *next message* will ask for — a draft, not a server setting.
 *
 * A mode is a per-agent runtime property, and every message already states the
 * recipient's mode: a human's chat message carries it as a `[mode: X]\n`
 * prefix, a peer's in its header. So there is nothing to push. This hook holds
 * the selection the composer sends with the next message (`sendMessage`'s
 * `mode` argument), and the server learns it when that message arrives.
 *
 * `chat:status` carries the agent's *current* mode on every frame, which is
 * what the next message inherits if the user does not choose. Re-seeding on
 * every frame would overwrite a selection still in progress, so the draft
 * follows the server only when the server's value actually moves.
 */

import { useEffect, useRef, useState } from "react";

/**
 * @param {object} options
 * @param {string|null} options.currentModeFromCache the mode the server last
 *   reported for this agent, from its cache entry
 * @param {string|null} options.defaultMode the mode a new agent starts in,
 *   from the server (`Nest.Modes` and the blueprint's `default_mode`)
 * @returns {{
 *   currentMode: string|null,
 *   setCurrentMode: (mode: string|null) => void,
 *   handleModeChange: (mode: string) => void,
 * }} the draft, a setter for the history walk to restore a selection with, and
 *   the selector's change handler (also just a local set)
 */
export function useAgentMode({ currentModeFromCache, defaultMode }) {
  const [currentMode, setCurrentMode] = useState(null);

  // The server value the draft was last seeded from. `undefined` means "never
  // seeded" — distinct from `null`, which is what the cache holds before the
  // first `chat:status` arrives and must still fall through to `defaultMode`.
  const seededFrom = useRef(undefined);

  useEffect(() => {
    const serverMode = currentModeFromCache ?? defaultMode;
    if (!serverMode || seededFrom.current === serverMode) return;
    seededFrom.current = serverMode;
    setCurrentMode(serverMode);
  }, [currentModeFromCache, defaultMode]);

  return {
    currentMode,
    setCurrentMode,
    handleModeChange: setCurrentMode,
  };
}
