/**
 * Mock Phoenix Socket for testing
 * Implements the full Socket and Channel API surface
 * All network responses are scheduled via setTimeout(..., 1)
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
  // Behavior configuration queues
  joinBehaviors: new Map(), // topic -> { type: 'ok' | 'error' | 'timeout', payload?: any }
  pushBehaviors: new Map(), // "topic:event" -> { type: 'ok' | 'error' | 'timeout', payload?: any }
  pendingPushes: new Map(), // "topic:event" -> { ok: fn, error: fn, timeout: fn }
  eventHandlers: new Map(), // "topic:event" -> handler function
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
  mockState.joinBehaviors.clear();
  mockState.pushBehaviors.clear();
  mockState.pendingPushes.clear();
  mockState.eventHandlers.clear();
}

/**
 * Configure the next join result for a channel
 * @param {string} topic - Channel topic
 * @param {Object} config - Configuration object
 * @param {Object} [config.autoInit] - Successful join with init payload (triggers init event)
 * @param {string} [config.error] - Join error with reason
 * @param {boolean} [config.timeout] - Join timeout
 */
export function setNextJoinResult(topic, config) {
  mockState.joinBehaviors.set(topic, config);
}

/**
 * Configure the next push response for a channel event
 * @param {string} topic - Channel topic
 * @param {string} event - Event name
 * @param {Object} config - Configuration object
 * @param {any} [config.ok] - Success response payload
 * @param {any} [config.error] - Error response payload
 * @param {boolean} [config.timeout] - Push timeout
 */
export function setNextPushResult(topic, event, config) {
  const key = `${topic}:${event}`;
  mockState.pushBehaviors.set(key, config);
}

/**
 * Simulate a server-initiated event (broadcast)
 * Schedules the event via setTimeout(..., 1)
 * @param {string} topic - Channel topic
 * @param {string} event - Event name
 * @param {any} payload - Event payload
 */
export function simulateServerEvent(topic, event, payload) {
  setTimeout(() => {
    const channel = mockState.channels.get(topic);
    if (channel) {
      channel._deliverEvent(event, payload);
    }
  }, 1);
}

/**
 * Connect the socket
 * Triggers onOpen callbacks via setTimeout(..., 1)
 */
export function connectSocket() {
  mockState.connected = true;
  setTimeout(() => {
    for (const cb of mockState.socketCallbacks.onOpen) {
      cb();
    }
  }, 1);
}

/**
 * Disconnect the socket
 * Triggers onClose callbacks via setTimeout(..., 1)
 */
export function disconnectSocket() {
  mockState.connected = false;
  setTimeout(() => {
    for (const cb of mockState.socketCallbacks.onClose) {
      cb();
    }
  }, 1);
}

/**
 * Trigger socket error
 * Triggers onError callbacks via setTimeout(..., 1)
 */
export function errorSocket() {
  mockState.connected = false;
  setTimeout(() => {
    for (const cb of mockState.socketCallbacks.onError) {
      cb();
    }
  }, 1);
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
  };

  const channel = {
    topic,

    on(event, handler) {
      channelState.eventHandlers.set(event, handler);
      // Track handler globally for server events
      mockState.eventHandlers.set(`${topic}:${event}`, handler);
    },

    onClose(handler) {
      channelState.closeHandlers.push(handler);
    },

    join() {
      const behavior = mockState.joinBehaviors.get(topic) || {
        autoInit: {
          id: topic.replace("agent:", ""),
          model: { name: "gpt-4", provider: "openai" },
          messageCount: 0,
          status: "idle",
        },
      };

      const joinReceiver = {
        receive(status, callback) {
          setTimeout(() => {
            if (status === "ok" && behavior.autoInit) {
              channelState.joined = true;
              callback();
              // Trigger init event after ok callback
              const initHandler = channelState.eventHandlers.get("init");
              if (initHandler) {
                initHandler(behavior.autoInit);
              }
            } else if (status === "error" && behavior.error !== undefined) {
              callback({ reason: behavior.error });
            } else if (status === "timeout" && behavior.timeout) {
              callback();
            }
          }, 1);
          return joinReceiver;
        },
      };
      return joinReceiver;
    },

    push(event, _payload) {
      const key = `${topic}:${event}`;
      const behavior = mockState.pushBehaviors.get(key) || { ok: {} };

      mockState.pushBehaviors.delete(key);

      const pushReceiver = {
        receive(status, callback) {
          setTimeout(() => {
            if (status === "ok" && behavior.ok !== undefined) {
              callback(behavior.ok);
            } else if (status === "error" && behavior.error !== undefined) {
              callback(behavior.error);
            } else if (status === "timeout" && behavior.timeout) {
              callback();
            }
          }, 1);

          return pushReceiver;
        },
      };

      return pushReceiver;
    },

    leave() {
      channelState.joined = false;
      // Clear join behavior when leaving
      mockState.joinBehaviors.delete(topic);
      // Clear event handlers for this channel
      for (const [key] of mockState.eventHandlers) {
        if (key.startsWith(`${topic}:`)) {
          mockState.eventHandlers.delete(key);
        }
      }
      // Trigger close handlers asynchronously
      setTimeout(() => {
        for (const handler of channelState.closeHandlers) {
          handler();
        }
      }, 1);
    },

    // Internal: deliver an event to this channel (called by simulateServerEvent)
    _deliverEvent(event, payload) {
      const handler = channelState.eventHandlers.get(event);
      if (handler) {
        handler(payload);
      }
    },
  };

  return channel;
}

/**
 * Creates a socket instance with Phoenix API
 * @param {string} _endpoint - Socket endpoint (ignored in mock)
 * @param {Object} _opts - Socket options (ignored in mock)
 * @returns {Object} Socket instance
 */
function createSocketInstance(_endpoint, _opts) {
  return {
    onOpen(callback) {
      mockState.socketCallbacks.onOpen.push(callback);
    },

    onClose(callback) {
      mockState.socketCallbacks.onClose.push(callback);
    },

    onError(callback) {
      mockState.socketCallbacks.onError.push(callback);
    },

    connect() {
      // Connect is called but callbacks are triggered via connectSocket()
    },

    channel(topic) {
      if (!mockState.channels.has(topic)) {
        mockState.channels.set(topic, createMockChannel(topic));
      }
      return mockState.channels.get(topic);
    },
  };
}

/**
 * Mock Socket class
 * Implements the Phoenix Socket API
 */
export class Socket {
  constructor(endpoint, opts) {
    const instance = createSocketInstance(endpoint, opts);
    Object.assign(this, instance);
  }
}
