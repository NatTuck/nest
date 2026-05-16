/**
 * Zustand store for global application state.
 *
 * Manages:
 * - Socket connection state
 * - Agent list and current agent
 * - Channel references
 * - Chat messages
 */

import { create } from "zustand";
import { devtools } from "zustand/middleware";
import { getSocket, joinChannel, leaveChannel } from "../socket";

/**
 * Create a Zustand store with devtools in development
 */
export const useStore = create(
  devtools(
    (set, get) => ({
      // Connection state
      socket: null,
      isConnected: false,
      connectionError: null,

      // Agents state
      agents: [],
      models: [],
      currentAgentId: null,

      // Channels
      lobbyChannel: null,
      agentChannel: null,

      // Chat state
      messages: [],
      isStreaming: false,

      // Actions

      /**
       * Initialize socket connection
       */
      connectSocket: () => {
        const socket = getSocket();

        socket.onOpen(() => {
          set({ isConnected: true, connectionError: null });
        });

        socket.onClose(() => {
          set({ isConnected: false });
        });

        socket.onError((error) => {
          set({ connectionError: error, isConnected: false });
        });

        set({ socket });
      },

      /**
       * Join the lobby channel and set up listeners
       */
      joinLobby: () => {
        const channel = joinChannel("lobby");

        // Listen for initial state
        channel.on("init", (payload) => {
          set({
            agents: payload.agents || [],
            models: payload.models || [],
          });
        });

        // Listen for agent creation
        channel.on("agent:created", (payload) => {
          const { agents } = get();
          set({
            agents: [
              ...agents,
              { id: payload.id, model: payload.model, status: "idle" },
            ],
          });
        });

        // Listen for agent deletion
        channel.on("agent:deleted", (payload) => {
          const { agents, currentAgentId } = get();
          set({
            agents: agents.filter((a) => a.id !== payload.id),
            currentAgentId:
              currentAgentId === payload.id ? null : currentAgentId,
          });
        });

        set({ lobbyChannel: channel });

        return channel;
      },

      /**
       * Leave the lobby channel
       */
      leaveLobby: () => {
        const { lobbyChannel } = get();
        if (lobbyChannel) {
          leaveChannel(lobbyChannel);
          set({ lobbyChannel: null });
        }
      },

      /**
       * Create a new agent
       */
      createAgent: async (model) => {
        const { lobbyChannel } = get();
        if (!lobbyChannel) {
          throw new Error("Not connected to lobby");
        }

        return new Promise((resolve, reject) => {
          lobbyChannel
            .push("create_agent", { model })
            .receive("ok", (resp) => {
              resolve(resp.id);
            })
            .receive("error", (resp) => {
              reject(new Error(resp.reason || "Failed to create agent"));
            });
        });
      },

      /**
       * Delete an agent
       */
      deleteAgent: async (id) => {
        const { lobbyChannel } = get();
        if (!lobbyChannel) {
          throw new Error("Not connected to lobby");
        }

        return new Promise((resolve, reject) => {
          lobbyChannel
            .push("delete_agent", { id })
            .receive("ok", () => {
              resolve();
            })
            .receive("error", (resp) => {
              reject(new Error(resp.reason || "Failed to delete agent"));
            });
        });
      },

      /**
       * Join an agent channel for chatting
       */
      joinAgent: (id) => {
        // Leave current agent channel if any
        const { agentChannel } = get();
        if (agentChannel) {
          leaveChannel(agentChannel);
        }

        const channel = joinChannel(`agent:${id}`);

        // Listen for initial state
        channel.on("init", (payload) => {
          set({
            currentAgentId: payload.id,
            messages: payload.messages || [],
            isStreaming: payload.status === "streaming",
          });
        });

        // Listen for streaming deltas (future implementation)
        channel.on("chat:delta", (payload) => {
          const { messages } = get();
          // Append delta to last assistant message or create new one
          const lastMessage = messages[messages.length - 1];
          if (lastMessage && lastMessage.role === "assistant") {
            const updatedMessages = [...messages];
            updatedMessages[messages.length - 1] = {
              ...lastMessage,
              content: lastMessage.content + payload.content,
            };
            set({ messages: updatedMessages });
          }
        });

        // Listen for complete messages
        channel.on("chat:message", (payload) => {
          const { messages } = get();
          set({
            messages: [...messages, payload],
            isStreaming: false,
          });
        });

        // Listen for errors
        channel.on("chat:error", (payload) => {
          console.error("Chat error:", payload);
          set({ isStreaming: false });
        });

        set({ agentChannel: channel });

        return channel;
      },

      /**
       * Leave the current agent channel
       */
      leaveAgent: () => {
        const { agentChannel } = get();
        if (agentChannel) {
          leaveChannel(agentChannel);
          set({
            agentChannel: null,
            currentAgentId: null,
            messages: [],
          });
        }
      },

      /**
       * Send a chat message
       */
      sendMessage: async (content) => {
        const { agentChannel, messages } = get();
        if (!agentChannel) {
          throw new Error("Not connected to agent");
        }

        // Add user message locally
        const userMessage = { role: "user", content };
        set({
          messages: [...messages, userMessage],
          isStreaming: true,
        });

        return new Promise((resolve, reject) => {
          agentChannel
            .push("chat:message", { content })
            .receive("ok", () => {
              resolve();
            })
            .receive("error", (resp) => {
              set({ isStreaming: false });
              reject(new Error(resp.reason || "Failed to send message"));
            });
        });
      },

      /**
       * Clear messages
       */
      clearMessages: () => {
        set({ messages: [] });
      },
    }),
    { name: "nest-store" },
  ),
);
