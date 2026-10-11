/**
 * Tests for `js/utils/agentStatus.js`.
 *
 * The mapping is table-driven over every status the server's
 * `Machine.status_for/1` can produce, so a status added there without a dot
 * here fails loudly instead of silently rendering the neutral fallback.
 */

import { describe, it } from "vitest";
import assert from "node:assert";
import { AGENT_STATUSES, agentStatusDot } from "./agentStatus";

/** The statuses `Nest.Agents.Agent.Machine.status_for/1` can return. */
const SERVER_STATUSES = [
  "idle",
  "streaming",
  "executing_tools",
  "compacting",
  "needs_repair",
  "model_missing",
  "context_overflow",
  "compaction_failed",
  "compaction_loop_detected",
];

/** The five blocked phases, which render a static red dot. */
const BLOCKED_STATUSES = [
  "needs_repair",
  "model_missing",
  "context_overflow",
  "compaction_failed",
  "compaction_loop_detected",
];

describe("agentStatusDot", () => {
  it("knows every status the server can report", () => {
    for (const status of SERVER_STATUSES) {
      assert.ok(
        AGENT_STATUSES.includes(status),
        `missing dot mapping for server status ${status}`,
      );
    }
  });

  it("maps each working status to its dot and label", () => {
    const expected = {
      idle: { className: "bg-gray-300", label: "Idle" },
      streaming: {
        className: "bg-green-500 animate-pulse",
        label: "Streaming",
      },
      executing_tools: {
        className: "bg-amber-500 animate-pulse",
        label: "Executing tools",
      },
      compacting: {
        className: "bg-blue-500 animate-pulse",
        label: "Compacting",
      },
    };

    for (const [status, dot] of Object.entries(expected)) {
      assert.deepStrictEqual(agentStatusDot(status), dot, status);
    }
  });

  it("renders every blocked status as a static red dot", () => {
    for (const status of BLOCKED_STATUSES) {
      const dot = agentStatusDot(status);
      assert.strictEqual(dot.className, "bg-red-500", status);
      assert.ok(!dot.className.includes("animate-pulse"), status);
      assert.ok(dot.label.length > 0, status);
    }
  });

  it("labels each blocked status distinctly", () => {
    const labels = BLOCKED_STATUSES.map((s) => agentStatusDot(s).label);
    assert.strictEqual(new Set(labels).size, BLOCKED_STATUSES.length);
  });

  it("gives every known status a non-empty label", () => {
    for (const status of AGENT_STATUSES) {
      assert.ok(agentStatusDot(status).label.length > 0, status);
    }
  });

  it("falls back to the neutral dot for an unknown status", () => {
    assert.deepStrictEqual(agentStatusDot("something_new"), {
      className: "bg-gray-300",
      label: "Unknown status: something_new",
    });
  });

  it("falls back to the neutral dot for a missing status", () => {
    for (const missing of [undefined, null, ""]) {
      const dot = agentStatusDot(missing);
      assert.strictEqual(dot.className, "bg-gray-300");
      assert.strictEqual(dot.label, "Unknown status");
    }
  });

  it("does not treat Object.prototype keys as known statuses", () => {
    assert.deepStrictEqual(agentStatusDot("toString"), {
      className: "bg-gray-300",
      label: "Unknown status: toString",
    });
  });
});
