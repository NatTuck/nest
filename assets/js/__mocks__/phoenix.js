/**
 * Mock Phoenix Socket for testing
 * Implements the full Socket and Channel API surface
 * All network responses are scheduled via setTimeout(..., 1)
 */

// Monotonic refs for the socket lifecycle registrations. The real
// `Socket.onOpen/onClose/onError` return a ref and store a
// `[ref, callback]` pair, so a caller can hand the refs back to
// `off/1`; the mock has to do the same or `initChannels`'s
// off-then-register is untestable.
let nextRef = 0;

function makeRef() {
  nextRef += 1;
  return `ref-${nextRef}`;
}

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
  pushCaptures: new Map(), // "topic:event" -> { resolve: fn }
  eventHandlers: new Map(), // "topic:event" -> handler function
};

/**
 * The reply a real server gives a push the test did not configure.
 *
 * Almost every event is answered with an empty map, which is enough for a
 * helper that reads one key out of a reply. `pane:sync` (#119 / #120) is not:
 * its reply is the space's whole pane state, so an empty map is a *contract
 * violation* the store refuses (loudly) rather than "nothing to report". The
 * fake therefore answers it the way a server with an empty queue does, so a
 * test that joins a channel and does not care about the pane stays quiet.
 */
function defaultPushBehavior(topic, event) {
  if (event === "pane:sync") {
    const spaceId = Number(String(topic).split(":")[1]);
    if (Number.isInteger(spaceId)) {
      return { ok: { spaceId, decisions: [], todos: {}, seq: 0 } };
    }
  }
  return { ok: {} };
}

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
  mockState.pushCaptures.clear();
}

/**
 * Configure the next join result for a channel
 * @param {string} topic - Channel topic
 * @param {Object} config - Configuration object
 * @param {Object} [config.autoInit] - Successful join with init payload (triggers init event)
 * @param {string|Object} [config.error] - Join error: a bare reason string,
 *   or the whole `{reason, path?, type?}` reply payload
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
 * Capture the next push payload sent to a topic+event. Returns a
 * promise that resolves with the captured payload.
 */
export function captureNextPush(topic, event) {
  return new Promise((resolve) => {
    const key = `${topic}:${event}`;
    mockState.pushCaptures.set(key, { resolve });
  });
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
    for (const [, cb] of mockState.socketCallbacks.onOpen) {
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
    for (const [, cb] of mockState.socketCallbacks.onClose) {
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
    for (const [, cb] of mockState.socketCallbacks.onError) {
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
              // A join refusal is a payload, not just a reason: the server
              // can answer with `{reason, path, type}` (a workspace it cannot
              // protect), so an object is passed through verbatim and a bare
              // string keeps its old `{reason}` shape.
              callback(
                typeof behavior.error === "object"
                  ? behavior.error
                  : { reason: behavior.error },
              );
            } else if (status === "timeout" && behavior.timeout) {
              callback();
            }
          }, 1);
          return joinReceiver;
        },
      };
      return joinReceiver;
    },

    push(event, payload) {
      const key = `${topic}:${event}`;
      const behavior =
        mockState.pushBehaviors.get(key) || defaultPushBehavior(topic, event);

      mockState.pushBehaviors.delete(key);

      // If a capture is registered, resolve it with the
      // payload so the test can assert on the push args. The
      // regular receive flow also runs (when the channel
      // calls `.receive("ok", cb)` on the returned receiver)
      // so configured responses from `setNextPushResult` are
      // still applied — a test that only captures a push must
      // not change whether the channel's own reply callbacks
      // run.
      const capture = mockState.pushCaptures.get(key);
      if (capture) {
        mockState.pushCaptures.delete(key);
        setTimeout(() => capture.resolve(payload), 1);
      }

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
function createSocketInstance(_endpoint, opts) {
  return {
    onOpen(callback) {
      const ref = makeRef();
      mockState.socketCallbacks.onOpen.push([ref, callback]);
      return ref;
    },

    onClose(callback) {
      const ref = makeRef();
      mockState.socketCallbacks.onClose.push([ref, callback]);
      return ref;
    },

    onError(callback) {
      const ref = makeRef();
      mockState.socketCallbacks.onError.push([ref, callback]);
      return ref;
    },

    // Mirrors the real `Socket.off/1`: filter every lifecycle list by ref.
    // Called with refs that are no longer registered — for instance ones taken
    // before a `resetMockSocket()` — this is a no-op, exactly as in Phoenix.
    off(refs) {
      for (const key of Object.keys(mockState.socketCallbacks)) {
        mockState.socketCallbacks[key] = mockState.socketCallbacks[key].filter(
          ([ref]) => !refs.includes(ref),
        );
      }
    },

    isConnected() {
      return mockState.connected;
    },

    params() {
      // The real Phoenix Socket wraps the constructor's
      // `params` option in a closure so it's callable as a
      // function. The mock mirrors that so test code can
      // assert on `socket.params()` shape.
      const provided = opts?.params;
      if (typeof provided === "function") {
        return provided();
      }
      return provided || {};
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
