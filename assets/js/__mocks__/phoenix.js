/**
 * Mock Phoenix Socket for testing
 * Implements the full Socket and Channel API surface
 * No vitest dependencies - just plain functions with state tracking
 */

// Private state
const mockState = {
  connected: false,
  channels: new Map(), // topic -> Channel
  socketCallbacks: {
    onOpen: [],
    onClose: [],
    onError: [],
  },
};

/**
 * Reset all mock state
 * Call this in beforeEach to get fresh state
 */
export function resetMockSocket() {
  mockState.connected = false;
  mockState.channels.clear();
  mockState.socketCallbacks.onOpen = [];
  mockState.socketCallbacks.onClose = [];
  mockState.socketCallbacks.onError = [];
}

/**
 * Create a mock channel
 * @param {string} topic - Channel topic (e.g., "agent:123" or "lobby")
 * @returns {Object} Mock channel object
 */
function createMockChannel(topic) {
  const channelState = {
    joined: false,
    eventHandlers: new Map(),
    closeHandlers: [],
    pushCallbacks: new Map(), // event -> { ok: fn, error: fn, timeout: fn }
    pushCalls: [], // Array of { event, payload }
  };

  const channel = {
    topic,

    on(event, handler) {
      channelState.eventHandlers.set(event, handler);
    },

    onClose(handler) {
      channelState.closeHandlers.push(handler);
    },

    join() {
      const joinReceiver = {
        receive(status, callback) {
          if (status === "ok") {
            channelState.joined = true;
            setTimeout(() => {
              callback();
              // Auto-trigger init event for agent channels
              if (topic.startsWith("agent:")) {
                const initHandler = channelState.eventHandlers.get("init");
                if (initHandler) {
                  initHandler({
                    id: topic.replace("agent:", ""),
                    model: { name: "gpt-4", provider: "openai" },
                    lastCompleteIndex: -1,
                    status: "idle",
                  });
                }
              }
            }, 0);
          } else if (status === "error") {
            setTimeout(() => callback({ reason: "agent not found" }), 0);
          } else if (status === "timeout") {
            setTimeout(() => callback(), 0);
          }
          return joinReceiver;
        },
      };
      return joinReceiver;
    },

    push(event, payload) {
      channelState.pushCalls.push({ event, payload });

      const pushReceiver = {
        receive(status, callback) {
          if (!channelState.pushCallbacks.has(event)) {
            channelState.pushCallbacks.set(event, {});
          }
          channelState.pushCallbacks.get(event)[status] = callback;
          return pushReceiver;
        },
      };
      return pushReceiver;
    },

    leave() {
      channelState.joined = false;
      channelState.closeHandlers.forEach((handler) => handler());
    },

    // Test helpers

    _triggerEvent(event, payload) {
      const handler = channelState.eventHandlers.get(event);
      if (handler) {
        handler(payload);
      }
    },

    _triggerPushResponse(event, status, payload) {
      const callbacks = channelState.pushCallbacks.get(event);
      if (callbacks?.[status]) {
        callbacks[status](payload);
      }
    },

    _isJoined() {
      return channelState.joined;
    },

    _getPushCalls() {
      return channelState.pushCalls;
    },

    _clearPushCalls() {
      channelState.pushCalls = [];
    },
  };

  return channel;
}

/**
 * Mock Socket class
 * Implements the Phoenix Socket API
 */
export class Socket {
  constructor() {
    // Return the mock socket instance
    return socket;
  }
}

/**
 * Mock socket instance
 */
const socket = {
  isConnected() {
    return mockState.connected;
  },

  isMock() {
    return true;
  },

  onOpen(callback) {
    mockState.socketCallbacks.onOpen.push(callback);
  },

  onClose(callback) {
    mockState.socketCallbacks.onClose.push(callback);
  },

  onError(callback) {
    mockState.socketCallbacks.onError.push(callback);
  },

  channel(topic) {
    if (!mockState.channels.has(topic)) {
      mockState.channels.set(topic, createMockChannel(topic));
    }
    return mockState.channels.get(topic);
  },

  // Test helpers

  _connect() {
    mockState.connected = true;
    mockState.socketCallbacks.onOpen.forEach((cb) => cb());
  },

  _disconnect() {
    mockState.connected = false;
    mockState.socketCallbacks.onClose.forEach((cb) => cb());
  },

  _error() {
    mockState.connected = false;
    mockState.socketCallbacks.onError.forEach((cb) => cb());
  },

  _getChannel(topic) {
    return mockState.channels.get(topic);
  },

  _hasChannel(topic) {
    return mockState.channels.has(topic);
  },

  _getChannelTopics() {
    return Array.from(mockState.channels.keys());
  },

  _clearChannels() {
    mockState.channels.clear();
  },
};

/**
 * Legacy export for backward compatibility
 */
socket._createdChannels = {
  get(topic) {
    return mockState.channels.get(topic);
  },
  has(topic) {
    return mockState.channels.has(topic);
  },
  clear() {
    mockState.channels.clear();
  },
};
