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

    setConnectionFailed: (failed) => {
      set({ connectionFailed: failed });
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

    /**
     * Whether the lobby channel is joined, which is when the server starts
     * answering lobby pushes. A page whose first read is a lobby push (the
     * space feed's `space_feed`) waits for this rather than for `isConnected`:
     * the socket is up before the lobby is joined, so a push sent on
     * `isConnected` alone would be refused and show as a failed read.
     */
    setLobbyJoined: (lobbyJoined) => {
      set({ lobbyJoined });
    },

    logout: () => {
      set(initialState);
    },

    _reset: () => {
      set(initialState);
    },
  };
}
