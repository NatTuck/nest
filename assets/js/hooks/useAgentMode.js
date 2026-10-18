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
 *
 * A draft belongs to **one agent**. The route component is reused across
 * `/space/:slug/agent/:name`, so switching agents is a re-render, not a
 * remount: without the `name` reset below, a selection left unsent on agent A
 * would be the mode agent B's next message asks for — and the "only when the
 * server's value moves" rule would not even notice, because both agents can
 * report the same mode.
 */

import { useEffect, useRef, useState } from "react";

/**
 * @param {object} options
 * @param {string|null} options.name the agent the draft belongs to; a change
 *   starts a fresh draft, because the previous one was about another agent
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
export function useAgentMode({ name, currentModeFromCache, defaultMode }) {
  const [currentMode, setCurrentMode] = useState(null);

  // The server value the draft was last seeded from. `undefined` means "never
  // seeded" — distinct from `null`, which is what the cache holds before the
  // first `chat:status` arrives and must still fall through to `defaultMode`.
  const seededFrom = useRef(undefined);

  // The agent the draft (and `seededFrom`) belong to.
  const agent = useRef(name);

  useEffect(() => {
    if (agent.current !== name) {
      agent.current = name;
      // A different agent: nothing is known about its draft yet, and the
      // seeding below must run even if the two agents share a mode.
      seededFrom.current = undefined;
      setCurrentMode(null);
    }

    const serverMode = currentModeFromCache ?? defaultMode;
    if (!serverMode || seededFrom.current === serverMode) return;
    seededFrom.current = serverMode;
    setCurrentMode(serverMode);
  }, [name, currentModeFromCache, defaultMode]);

  return {
    currentMode,
    setCurrentMode,
    handleModeChange: setCurrentMode,
  };
}
