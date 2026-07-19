/**
 * DelegatedTaskBlock test — focused coverage on:
 *   1. Status rendering for "running" (no result yet), "completed"
 *      (result is non-null), and "error" (is_error flag).
 *   2. Linking the response text only when we have one.
 *   3. Accepting either atom (`name`) or camelCase
 *      (`tool_call_id`) keys from `toolResults`/`toolCalls`,
 *      which both shapes exist in the cache depending on
 *      which message batch populated it.
 */

import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";

import { DelegatedTaskBlock, DelegatedTasks } from "./DelegatedTaskBlock";

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

describe("DelegatedTasks", () => {
  it("renders nothing when no clone_agent calls are present", () => {
    const messages = [
      {
        index: 1,
        role: "assistant",
        toolCalls: [
          { id: "x", name: "shell_cmd", arguments: { command: "ls" } },
        ],
      },
    ];

    const { container } = render(
      <MemoryRouter>
        <DelegatedTasks messages={messages} partial={null} />
      </MemoryRouter>,
    );

    expect(container.firstChild).toBeNull();
  });

  it("renders a card per clone_agent call paired with its result", () => {
    const messages = [
      {
        index: 1,
        role: "assistant",
        toolCalls: [
          {
            id: "call-1",
            name: "clone_agent",
            arguments: { instruction: "do X" },
          },
        ],
      },
      {
        index: 2,
        role: "tool",
        toolResults: [
          {
            tool_call_id: "call-1",
            name: "clone_agent",
            content: "child says X is done",
            is_error: false,
          },
        ],
      },
    ];

    render(
      <MemoryRouter>
        <DelegatedTasks messages={messages} partial={null} />
      </MemoryRouter>,
    );

    expect(screen.getAllByTestId("delegated-task-block")).toHaveLength(1);
    expect(screen.getByTestId("delegated-task-response")).toHaveTextContent(
      "child says X is done",
    );
    expect(screen.getByText("Completed")).toBeInTheDocument();
  });

  it("accepts both `toolCalls`/`toolResults` and the camelCase aliases", () => {
    const messages = [
      {
        index: 1,
        role: "assistant",
        tool_calls: [
          {
            id: "call-2",
            name: "clone_agent",
            arguments: { instruction: "do Y" },
          },
        ],
      },
      {
        index: 2,
        role: "tool",
        tool_results: [
          {
            toolCallId: "call-2",
            name: "clone_agent",
            content: "child says Y is done",
            isError: false,
          },
        ],
      },
    ];

    render(
      <MemoryRouter>
        <DelegatedTasks messages={messages} partial={null} />
      </MemoryRouter>,
    );

    expect(screen.getAllByTestId("delegated-task-block")).toHaveLength(1);
    expect(screen.getByTestId("delegated-task-response")).toHaveTextContent(
      "child says Y is done",
    );
  });

  it("also picks up clone_agent calls from the streaming partial", () => {
    // While the parent LLM is still streaming, the call set
    // lives in `partial.toolCalls`. We want a DelegatedTasks
    // block to render with "Running" status immediately —
    // before the tool-result message lands — so users see
    // the in-flight delegation.
    const messages = [];
    const partial = {
      index: 4,
      role: "assistant",
      toolCalls: [
        {
          id: "call-3",
          name: "clone_agent",
          arguments: { instruction: "do Z" },
        },
      ],
    };

    render(
      <MemoryRouter>
        <DelegatedTasks messages={messages} partial={partial} />
      </MemoryRouter>,
    );

    expect(screen.getAllByTestId("delegated-task-block")).toHaveLength(1);
    expect(screen.getByText("Running")).toBeInTheDocument();
    expect(screen.getByTestId("delegated-task-instruction")).toHaveTextContent(
      "do Z",
    );
  });
});
