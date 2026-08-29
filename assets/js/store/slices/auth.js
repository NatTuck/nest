/**
 * Connection + user/account setters for the zustand store: connection
 * status, current user, invites, archived-collapse flag, and resets.
 * Split from `store/index.js`.
 */

import { initialState } from "../helpers";

export function authSetters(set) {
  return {
    setIsConnected: (connected) => {
      set({ isConnected: connected });
    },

    setCurrentUser: (user) => {
      set({ currentUser: user });
    },

    setInvites: (invites) => {
      set({ invites: invites || [] });
    },

    setInvitesError: (error) => {
      set({ invitesError: error });
    },

    setArchivedCollapsed: (archivedCollapsed) => {
      set({ archivedCollapsed });
    },

    logout: () => {
      set(initialState);
    },

    _reset: () => {
      set(initialState);
    },
  };
}
