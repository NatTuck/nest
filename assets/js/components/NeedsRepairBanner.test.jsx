/**
 * NeedsRepairBanner tests: the `:needs_repair` recovery banner shown
 * when the persisted sequence fails validation at load.
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { NeedsRepairBanner } from "./NeedsRepairBanner";

describe("NeedsRepairBanner", () => {
  it("renders the heading, problem count, and repair command", () => {
    render(
      <NeedsRepairBanner
        violations={[{ rule: "tool_pairing" }, { rule: "alternation" }]}
        repairCommand="mix nest.repair_messages --space clever-raven"
        onReload={() => {}}
      />,
    );

    expect(
      screen.getByText("This conversation needs repair before it can continue"),
    ).toBeInTheDocument();
    expect(screen.getByText(/2 problems/)).toBeInTheDocument();
    expect(
      screen.getByText("mix nest.repair_messages --space clever-raven"),
    ).toBeInTheDocument();
  });

  it("calls onReload when the reload button is clicked", () => {
    const onReload = vi.fn();
    render(<NeedsRepairBanner violations={[]} onReload={onReload} />);

    fireEvent.click(screen.getByRole("button", { name: "Reload agent" }));
    expect(onReload).toHaveBeenCalledTimes(1);
  });

  it("renders the reload error when one is supplied", () => {
    render(
      <NeedsRepairBanner
        violations={[]}
        onReload={() => {}}
        error="Failed to reload agent"
      />,
    );

    expect(screen.getByText("Failed to reload agent")).toBeInTheDocument();
  });
});
