/**
 * DelegatedTaskBlock test — focused coverage on:
 *   1. Status rendering for "running" (no result yet), "awaiting
 *      reply" (the spawn is confirmed and a `query` was given, so
 *      the child's answer arrives later as a message), "delegated"
 *      (a bare spawn with nothing to wait for), and "error"
 *      (is_error flag).
 *   2. Showing the spawn confirmation as a confirmation — never as
 *      the child's response, which the runtime delivers as a
 *      separate message.
 *   3. Accepting either atom (`name`) or camelCase
 *      (`tool_call_id`) keys from `toolResults`/`toolCalls`,
 *      which both shapes exist in the cache depending on
 *      which message batch populated it.
 *   4. The child's name links to the space-scoped chat route
 *      (`/space/:spaceSlug/agent/:name`, resolved via
 *      `useParams` from the surrounding route), and shows an
 *      explicit indicator rather than a dead link when no
 *      space slug is in scope.
 *
 * `DelegatedTask` (singular) is the per-message wrapper that
 * lives inside `MessageBubble`. It self-subscribes to
 * `cache.messages` for result-pairing lookups. The tests
 * below seed the store with a synthetic `agentsCache` for
 * a fixed agent name and verify the rendered output; the
 * cache is reset between tests so they don't leak state.
 */

import { afterEach, beforeEach, describe, it, expect } from "vitest";
import { render, screen, act } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";

import { useStore } from "../store";
import { DelegatedTaskBlock, DelegatedTask } from "./DelegatedTaskBlock";

const AGENT_NAME = "test-agent";
const SPACE_SLUG = "demo";

/**
 * Render `ui` inside the real chat route
 * (`/space/:spaceSlug/agent/:name`) so `useParams` resolves the
 * space slug exactly the way it does in the app. Any test that
 * asserts the child's chat link must use this helper: a bare
 * `MemoryRouter` matches no route, leaves the slug undefined,
 * and the card then (correctly) renders its "link unavailable"
 * indicator instead of a link.
 */
function renderInSpaceRoute(ui) {
  return render(
    <MemoryRouter initialEntries={[`/space/${SPACE_SLUG}/agent/coordinator`]}>
      <Routes>
        <Route path="/space/:spaceSlug/agent/:name" element={ui} />
      </Routes>
    </MemoryRouter>,
  );
}

function seedCache({ messages = [] } = {}) {
  act(() => {
    useStore.setState((state) => ({
      agentsCache: {
        ...state.agentsCache,
        [AGENT_NAME]: {
          ...(state.agentsCache[AGENT_NAME] ?? {}),
          messages,
        },
      },
    }));
  });
}

function clearCache() {
  act(() => {
    useStore.setState((state) => {
      const next = { ...state.agentsCache };
      delete next[AGENT_NAME];
      return { agentsCache: next };
    });
  });
}

describe("DelegatedTaskBlock", () => {
  it("renders instruction and status while the spawn call is still in flight", () => {
    render(
      <MemoryRouter>
        <DelegatedTaskBlock
          toolCallId="call-1"
          instruction="count the primes in foo.txt"
          childName={null}
          response={null}
          hasQuery
        />
      </MemoryRouter>,
    );

    expect(screen.getByText("Delegated task")).toBeInTheDocument();
    expect(screen.getByText("Running")).toBeInTheDocument();
    expect(screen.getByTestId("delegated-task-instruction")).toHaveTextContent(
      "count the primes in foo.txt",
    );
  });

  it("renders 'Awaiting reply' with the confirmation once the spawn is confirmed", () => {
    render(
      <MemoryRouter>
        <DelegatedTaskBlock
          toolCallId="call-1"
          instruction="count the primes"
          childName="worker-1"
          response="Spawned agent worker-1. Its answer will arrive as a message in your inbox."
          hasQuery
        />
      </MemoryRouter>,
    );

    expect(screen.getByText("Awaiting reply")).toBeInTheDocument();
    // The paired result is the spawn confirmation, never the child's
    // answer.
    expect(screen.getByTestId("delegated-task-confirmation")).toHaveTextContent(
      "Spawned agent worker-1",
    );
    expect(screen.queryByText("Child response")).toBeNull();
    expect(screen.queryByTestId("delegated-task-response")).toBeNull();
    expect(screen.queryByText("Completed")).toBeNull();
  });

  it("renders 'Delegated' for a bare spawn, which has nothing to wait for", () => {
    render(
      <MemoryRouter>
        <DelegatedTaskBlock
          toolCallId="call-1"
          instruction=""
          childName="worker-1"
          response="Created agent worker-1."
        />
      </MemoryRouter>,
    );

    expect(screen.getByText("Delegated")).toBeInTheDocument();
    expect(screen.getByTestId("delegated-task-confirmation")).toHaveTextContent(
      "Created agent worker-1",
    );
    // No query, so no answer is coming and there is no note promising one.
    expect(screen.queryByTestId("delegated-task-awaiting-note")).toBeNull();
  });

  it("renders 'Failed' when is_error is true", () => {
    render(
      <MemoryRouter>
        <DelegatedTaskBlock
          toolCallId="call-1"
          instruction="do something risky"
          childName={null}
          response="Child agent reached max depth"
          isError
          hasQuery
        />
      </MemoryRouter>,
    );

    expect(screen.getByText("Failed")).toBeInTheDocument();
    expect(screen.getByText("Error")).toBeInTheDocument();
    expect(screen.getByTestId("delegated-task-response")).toHaveTextContent(
      "Child agent reached max depth",
    );
    expect(screen.queryByTestId("delegated-task-confirmation")).toBeNull();
  });

  it("states that the answer arrives as a message and that the card cannot follow it", () => {
    render(
      <MemoryRouter>
        <DelegatedTaskBlock
          toolCallId="call-1"
          instruction="do X in the background"
          childName="worker-1"
          response="Spawned agent worker-1."
          hasQuery
        />
      </MemoryRouter>,
    );

    expect(screen.getByText("Awaiting reply")).toBeInTheDocument();
    expect(
      screen.getByTestId("delegated-task-awaiting-note"),
    ).toHaveTextContent(
      "The child's answer arrives later as a message in your inbox — or, if the child fails, is stopped or produces nothing, a runtime notice naming the reason. This card records the delegation, not the answer: neither message carries a tool-call id, so the card cannot be updated when it lands.",
    );
    expect(screen.getByTestId("delegated-task-instruction")).toHaveTextContent(
      "do X in the background",
    );
  });

  it("links the child's name to its space-scoped chat page", () => {
    renderInSpaceRoute(
      <DelegatedTaskBlock
        toolCallId="call-1"
        instruction="count the primes"
        childName="worker-1"
        response={null}
      />,
    );

    expect(screen.getByRole("link", { name: "worker-1" })).toHaveAttribute(
      "href",
      `/space/${SPACE_SLUG}/agent/worker-1`,
    );
    expect(screen.queryByTestId("delegated-task-child-missing")).toBeNull();
    expect(screen.queryByTestId("delegated-task-space-missing")).toBeNull();
  });

  it("shows an explicit 'link unavailable' indicator when no space slug is in scope", () => {
    // The card is only ever mounted under
    // `/space/:spaceSlug/agent/:name`. Anywhere else `spaceSlug`
    // is undefined and `/agent/worker-1` alone matches no route,
    // i.e. a blank page — so the missing data is surfaced
    // explicitly instead of rendering a dead link.
    render(
      <MemoryRouter>
        <DelegatedTaskBlock
          toolCallId="call-1"
          instruction="count the primes"
          childName="worker-1"
          response={null}
        />
      </MemoryRouter>,
    );

    expect(
      screen.getByTestId("delegated-task-space-missing"),
    ).toHaveTextContent(
      "worker-1 — chat link unavailable: no space in the route",
    );
    expect(screen.queryByRole("link")).toBeNull();
  });

  it("shows an explicit missing indicator when the child name is absent", () => {
    render(
      <MemoryRouter>
        <DelegatedTaskBlock
          toolCallId="call-1"
          instruction="count the primes"
          childName={null}
          response={null}
        />
      </MemoryRouter>,
    );

    expect(
      screen.getByTestId("delegated-task-child-missing"),
    ).toHaveTextContent("child name unavailable");
    expect(screen.queryByRole("link")).toBeNull();
  });
});

describe("DelegatedTask", () => {
  beforeEach(() => {
    clearCache();
  });

  afterEach(() => {
    clearCache();
  });

  it("renders nothing when the message has no agents-spawn calls", () => {
    seedCache({ messages: [] });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [{ id: "x", name: "shell-cmd", arguments: { command: "ls" } }],
    };

    const { container } = render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(container.firstChild).toBeNull();
  });

  it("renders a card per agents-spawn call paired with its confirmation", () => {
    seedCache({
      messages: [
        {
          index: 2,
          role: "tool",
          toolResults: [
            {
              tool_call_id: "call-1",
              name: "agents-spawn",
              content:
                "Spawned agent worker-1. Its answer will arrive as a message.",
              is_error: false,
            },
          ],
        },
      ],
    });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [
        {
          id: "call-1",
          name: "agents-spawn",
          arguments: { name: "worker-1", query: "do X" },
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(screen.getAllByTestId("delegated-task-block")).toHaveLength(1);
    expect(screen.getByTestId("delegated-task-confirmation")).toHaveTextContent(
      "Spawned agent worker-1",
    );
    expect(screen.getByText("Awaiting reply")).toBeInTheDocument();
  });

  it("reads a query from object, parsed-JSON, and partial-buffer arguments", () => {
    seedCache({
      messages: [
        {
          index: 2,
          role: "tool",
          toolResults: [
            {
              tool_call_id: "call-query",
              name: "agents-spawn",
              content: "Spawned agent worker-1.",
              is_error: false,
            },
          ],
        },
      ],
    });

    const argumentShapes = [
      { name: "worker-1", query: "do X" },
      '{"name":"worker-1","query":"do X"}',
      '{"name":"worker-1","query":"do X',
    ];

    for (const args of argumentShapes) {
      const message = {
        index: 1,
        role: "assistant",
        toolCalls: [
          { id: "call-query", name: "agents-spawn", arguments: args },
        ],
      };

      const { unmount, getByText, getByTestId } = render(
        <MemoryRouter>
          <DelegatedTask message={message} agentName={AGENT_NAME} />
        </MemoryRouter>,
      );

      expect(getByTestId("delegated-task-instruction")).toHaveTextContent(
        "do X",
      );
      expect(getByText("Awaiting reply")).toBeInTheDocument();
      unmount();
    }
  });

  it("reads a bare spawn (no query) as having nothing to wait for", () => {
    seedCache({
      messages: [
        {
          index: 2,
          role: "tool",
          toolResults: [
            {
              tool_call_id: "call-bare",
              name: "agents-spawn",
              content: "Created agent worker-1.",
              is_error: false,
            },
          ],
        },
      ],
    });

    const argumentShapes = [
      { name: "worker-1" },
      '{"name":"worker-1"}',
      '{"name":"worker-1"',
    ];

    for (const args of argumentShapes) {
      const message = {
        index: 1,
        role: "assistant",
        toolCalls: [{ id: "call-bare", name: "agents-spawn", arguments: args }],
      };

      const { unmount, getByText, queryByTestId } = render(
        <MemoryRouter>
          <DelegatedTask message={message} agentName={AGENT_NAME} />
        </MemoryRouter>,
      );

      expect(getByText("Delegated")).toBeInTheDocument();
      expect(queryByTestId("delegated-task-awaiting-note")).toBeNull();
      unmount();
    }
  });

  it("reads the child's name from the call arguments and links to its chat page", () => {
    seedCache({ messages: [] });

    const argumentShapes = [
      [{ name: "worker-obj", query: "do X" }, "worker-obj"],
      ['{"name":"worker-json","query":"do X"}', "worker-json"],
      ['{"name":"worker-partial","query":"do X', "worker-partial"],
    ];

    for (const [args, expectedName] of argumentShapes) {
      const message = {
        index: 1,
        role: "assistant",
        toolCalls: [{ id: "call-name", name: "agents-spawn", arguments: args }],
      };

      const { unmount, getByRole } = renderInSpaceRoute(
        <DelegatedTask message={message} agentName={AGENT_NAME} />,
      );

      expect(getByRole("link", { name: expectedName })).toHaveAttribute(
        "href",
        `/space/${SPACE_SLUG}/agent/${expectedName}`,
      );
      unmount();
    }
  });

  it("accepts both `toolCalls`/`toolResults` and the camelCase aliases", () => {
    seedCache({
      messages: [
        {
          index: 2,
          role: "tool",
          tool_results: [
            {
              toolCallId: "call-2",
              name: "agents-spawn",
              content: "Spawned agent worker-2.",
              isError: false,
            },
          ],
        },
      ],
    });

    const message = {
      index: 1,
      role: "assistant",
      tool_calls: [
        {
          id: "call-2",
          name: "agents-spawn",
          arguments: { query: "do Y" },
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(screen.getAllByTestId("delegated-task-block")).toHaveLength(1);
    expect(screen.getByTestId("delegated-task-confirmation")).toHaveTextContent(
      "Spawned agent worker-2",
    );
  });

  it("renders 'Running' when the result has not landed yet", () => {
    // The parent LLM is still streaming; the call lives in the
    // bubble's message but the tool-result message hasn't been
    // committed yet. We want the card to render immediately so
    // users see the in-flight delegation.
    seedCache({ messages: [] });

    const message = {
      index: 4,
      role: "assistant",
      toolCalls: [
        {
          id: "call-3",
          name: "agents-spawn",
          arguments: { query: "do Z" },
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(screen.getAllByTestId("delegated-task-block")).toHaveLength(1);
    expect(screen.getByText("Running")).toBeInTheDocument();
    expect(screen.getByTestId("delegated-task-instruction")).toHaveTextContent(
      "do Z",
    );
  });

  it("falls back to the `input` key when `arguments` is missing the instruction", () => {
    seedCache({ messages: [] });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [
        {
          id: "call-4",
          name: "agents-spawn",
          input: { query: "do W via input" },
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(screen.getByTestId("delegated-task-instruction")).toHaveTextContent(
      "do W via input",
    );
  });

  it("surfaces the partial `instruction` from a streaming JSON buffer", () => {
    // The agents-spawn tool call is mid-stream: the buffer
    // is `'{"query":"do X'` (not yet self-balanced).
    // The user should see "do X" — not a blank card.
    seedCache({ messages: [] });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [
        {
          id: "call-stream",
          name: "agents-spawn",
          arguments: '{"query":"do X',
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(screen.getByTestId("delegated-task-instruction")).toHaveTextContent(
      "do X",
    );
  });

  it("shows a placeholder when the streaming buffer is too small to contain instruction text", () => {
    // Very early in the stream — the buffer is `'{"inst'` so
    // neither `JSON.parse` nor the regex can pull anything
    // out. We render a placeholder so the card isn't blank.
    seedCache({ messages: [] });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [
        {
          id: "call-early",
          name: "agents-spawn",
          arguments: '{"inst',
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(screen.getByTestId("delegated-task-instruction")).toHaveTextContent(
      "(receiving instruction…)",
    );
  });

  it("reads instruction from finalized object-form `arguments` (post-stream)", () => {
    // Once the BEAM commits the assistant message,
    // `arguments` is a parsed object — `extractCloneInstruction`
    // short-circuits through `args.instruction`. Verify the
    // round trip works even when the streaming buffer has
    // cleared and a different message shape is in the cache.
    seedCache({ messages: [] });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [
        {
          id: "call-obj",
          name: "agents-spawn",
          arguments: { query: "do V via object" },
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(screen.getByTestId("delegated-task-instruction")).toHaveTextContent(
      "do V via object",
    );
  });

  it("parses fully-formed streaming JSON and reads the parsed instruction", () => {
    // When the buffer parses cleanly via `JSON.parse` (the
    // buffer happens to be a balanced JSON object), the
    // helper returns `parsed.instruction` directly without
    // falling through to the regex fallback. Covering this
    // branch is separate from the partial-buffer case above.
    seedCache({ messages: [] });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [
        {
          id: "call-full-json",
          name: "agents-spawn",
          arguments: '{"query":"do Q via parse"}',
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(screen.getByTestId("delegated-task-instruction")).toHaveTextContent(
      "do Q via parse",
    );
  });

  it("renders nothing for the instruction block when an object form is missing the field", () => {
    // `args.instruction ?? null` short-circuits to `null`
    // when the object form omits the `instruction` field.
    // The renderer then falls through to the streaming
    // placeholder (since `typeof rawArgs === "object"`,
    // not "string"). The instruction block is suppressed.
    seedCache({ messages: [] });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [
        {
          id: "call-no-instr",
          name: "agents-spawn",
          arguments: { path: "/tmp/x" },
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    // No instruction block — the placeholder string is
    // shown without being rendered (the component gates on
    // `instruction` being truthy).
    expect(screen.queryByTestId("delegated-task-instruction")).toBeNull();
  });

  it("handles a numeric / non-string non-object `arguments` value defensively", () => {
    // The BEAM should always send strings or objects, but a
    // mid-stream corruption or a buggy custom worker could
    // emit a primitive. The renderer must not crash and
    // should suppress the instruction block.
    seedCache({ messages: [] });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [
        {
          id: "call-numeric",
          name: "agents-spawn",
          arguments: 42,
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(screen.queryByTestId("delegated-task-instruction")).toBeNull();
  });

  it("handles null `arguments` defensively", () => {
    // Same defensive path — `args == null` short-circuits.
    seedCache({ messages: [] });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [
        {
          id: "call-null",
          name: "agents-spawn",
          arguments: null,
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(screen.queryByTestId("delegated-task-instruction")).toBeNull();
  });
});
