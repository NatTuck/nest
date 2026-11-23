/**
 * The space-wide shell-job cache (#225): every agent's jobs in one space, one
 * entry per space id.
 *
 * The per-agent job list lives in `agentsCache` (the agent channel's
 * `shell:jobs` frames). This is the space's own view, fed by the lobby: the
 * `init` payload carries one entry per visible space, and a `space:jobs` frame
 * replaces a space's list whenever any job in it changes — a start, an exit, a
 * kill, or the namespace-lost marking when the space's holder dies (#224).
 *
 * An entry is a plain list because the list is the whole state the server
 * reports: an empty list is a *known* empty space, and an absent entry is "no
 * read has landed yet" — which the panel renders as an explicit indicator,
 * never as "no jobs". The panel's own read failure is its local state, not a
 * property of the space's jobs.
 */

export function spaceJobsSetters(set) {
  return {
    /**
     * Replace one space's job list — from a `space:jobs` frame, the `init`
     * payload's per-space entries, or a `space_jobs` refresh reply. All three
     * carry the manager's whole list for the space, so a replace (not a merge)
     * is what keeps the cache the server's picture.
     */
    setSpaceJobs: (spaceId, jobs) => {
      set((state) => ({
        spaceJobs: { ...state.spaceJobs, [spaceId]: jobs ?? [] },
      }));
    },
  };
}
