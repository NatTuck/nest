/**
 * DelegatedTaskBlock test — focused coverage on:
 *   1. Status rendering for "running" (no result yet), "completed"
 *      (result is non-null), and "error" (is_error flag).
 *   2. Linking the response text only when we have one.
 *   3. Accepting either atom (`name`) or camelCase
 *      (`tool_call_id`) keys from `toolResults`/`toolCalls`,
 *      which both shapes exist in the cache depending on
 *      which message batch populated it.
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
import { MemoryRouter } from "react-router-dom";

import { useStore } from "../store";
import { DelegatedTaskBlock, DelegatedTask } from "./DelegatedTaskBlock";

const AGENT_NAME = "test-agent";

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
  it("renders instruction and status while the worker is still blocked", () => {
    render(
      <MemoryRouter>
        <DelegatedTaskBlock
          toolCallId="call-1"
          instruction="count the primes in foo.txt"
          childName={null}
          response={null}
        />
      </MemoryRouter>,
    );

    expect(screen.getByText("Delegated task")).toBeInTheDocument();
    expect(screen.getByText("Running")).toBeInTheDocument();
    expect(screen.getByTestId("delegated-task-instruction")).toHaveTextContent(
      "count the primes in foo.txt",
    );
  });

  it("renders the response with a 'Completed' badge once result lands", () => {
    render(
      <MemoryRouter>
        <DelegatedTaskBlock
          toolCallId="call-1"
          instruction="count the primes"
          childName={null}
          response="there are 17 primes"
        />
      </MemoryRouter>,
    );

    expect(screen.getByText("Completed")).toBeInTheDocument();
    expect(screen.getByTestId("delegated-task-response")).toHaveTextContent(
      "there are 17 primes",
    );
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
        />
      </MemoryRouter>,
    );

    expect(screen.getByText("Failed")).toBeInTheDocument();
    expect(screen.getByText("Error")).toBeInTheDocument();
    expect(screen.getByTestId("delegated-task-response")).toHaveTextContent(
      "Child agent reached max depth",
    );
  });
});

describe("DelegatedTask", () => {
  beforeEach(() => {
    clearCache();
  });

  afterEach(() => {
    clearCache();
  });

  it("renders nothing when the message has no agents/spawn calls", () => {
    seedCache({ messages: [] });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [{ id: "x", name: "shell_cmd", arguments: { command: "ls" } }],
    };

    const { container } = render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(container.firstChild).toBeNull();
  });

  it("renders a card per agents/spawn call paired with its result", () => {
    seedCache({
      messages: [
        {
          index: 2,
          role: "tool",
          toolResults: [
            {
              tool_call_id: "call-1",
              name: "agents/spawn",
              content: "child says X is done",
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
          name: "agents/spawn",
          arguments: { query: "do X" },
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTask message={message} agentName={AGENT_NAME} />
      </MemoryRouter>,
    );

    expect(screen.getAllByTestId("delegated-task-block")).toHaveLength(1);
    expect(screen.getByTestId("delegated-task-response")).toHaveTextContent(
      "child says X is done",
    );
    expect(screen.getByText("Completed")).toBeInTheDocument();
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
              name: "agents/spawn",
              content: "child says Y is done",
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
          name: "agents/spawn",
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
    expect(screen.getByTestId("delegated-task-response")).toHaveTextContent(
      "child says Y is done",
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
          name: "agents/spawn",
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
          name: "agents/spawn",
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
    // The agents/spawn tool call is mid-stream: the buffer
    // is `'{"query":"do X'` (not yet self-balanced).
    // The user should see "do X" — not a blank card.
    seedCache({ messages: [] });

    const message = {
      index: 1,
      role: "assistant",
      toolCalls: [
        {
          id: "call-stream",
          name: "agents/spawn",
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
          name: "agents/spawn",
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
          name: "agents/spawn",
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
          name: "agents/spawn",
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
          name: "agents/spawn",
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
          name: "agents/spawn",
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
          name: "agents/spawn",
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
