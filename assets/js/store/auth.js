/**
 * Auth store — small zustand slice for the current user
 * and authentication actions.
 *
 * Kept separate from `useStore` (the main app store) so this
 * module can be imported by login/register pages without
 * pulling in the entire store surface. The header reads
 * `currentUser` to render "logged in as X"; the lobby's
 * `init` payload is the source of truth for the user object
 * (and overwrites whatever `login`/`register` set locally).
 */

import { create } from "zustand";

export const useAuthStore = create((set) => ({
  currentUser: null,

  /**
   * Set the current user. Called by:
   *   - `auth.js login/register` on success
   *   - the lobby's `init` push when a fresh socket connects
   *   - the `logout` action
   */
  setCurrentUser: (user) => set({ currentUser: user }),

  /**
   * Clear the local user state. The store-side `logout`
   * action only handles the in-memory side; the network
   * call lives in `api/auth.js`.
   */
  logout: () => set({ currentUser: null }),
}));
