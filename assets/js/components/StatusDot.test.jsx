/**
 * Tests for `js/components/StatusDot.jsx`.
 *
 * The dot's colour comes from `js/utils/agentStatus.js` (covered by its own
 * test); these assertions pin the contract the two callers rely on — the
 * caller-supplied size class survives, and the status is exposed to users as
 * both a tooltip and an accessible name.
 */

import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { StatusDot } from "./StatusDot";

describe("StatusDot", () => {
  it("renders the status colour class", () => {
    render(<StatusDot status="streaming" />);
    const dot = screen.getByRole("img", { name: "Streaming" });
    expect(dot.className).toContain("bg-green-500");
    expect(dot.className).toContain("animate-pulse");
  });

  it("keeps the caller's size classes", () => {
    render(<StatusDot status="idle" className="w-2.5 h-2.5" />);
    const dot = screen.getByRole("img", { name: "Idle" });
    expect(dot.className).toContain("w-2.5");
    expect(dot.className).toContain("h-2.5");
    expect(dot.className).toContain("bg-gray-300");
  });

  it("exposes the status as a tooltip", () => {
    render(<StatusDot status="compacting" />);
    const dot = screen.getByRole("img", { name: "Compacting" });
    expect(dot).toHaveAttribute("title", "Compacting");
  });

  it("renders a blocked status as a static red dot", () => {
    render(<StatusDot status="model_missing" />);
    const dot = screen.getByRole("img", { name: "Model missing" });
    expect(dot.className).toContain("bg-red-500");
    expect(dot.className).not.toContain("animate-pulse");
  });

  it("does not let an unknown status look like idle", () => {
    render(
      <>
        <StatusDot status="brand_new" />
        <StatusDot status="idle" />
      </>,
    );
    const unknown = screen.getByRole("img", {
      name: "Unknown status: brand_new",
    });
    const idle = screen.getByRole("img", { name: "Idle" });
    expect(unknown.className).not.toContain("bg-gray-300");
    expect(unknown.className).not.toBe(idle.className);
  });

  it("works without a className", () => {
    render(<StatusDot status="idle" />);
    const dot = screen.getByRole("img", { name: "Idle" });
    expect(dot.className).toContain("rounded-full");
  });
});
