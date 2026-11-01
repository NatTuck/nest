/**
 * Tests for the ModeSelector component.
 *
 * Covers:
 * - Renders nothing when modes is undefined or empty
 * - Renders nothing when modes has 0 or 1 entries
 * - Renders a <select> with one <option> per mode
 * - value/onChange wiring
 * - disabled prop
 * - The phone's segmented toggle: the same two modes, one tap, and only one of
 *   the two controls visible on either side of `lg`
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ModeSelector } from "./ModeSelector";

describe("ModeSelector", () => {
  it("renders nothing when modes is undefined", () => {
    const { container } = render(
      <ModeSelector modes={undefined} value="plan" onChange={() => {}} />,
    );
    expect(container.firstChild).toBeNull();
  });

  it("renders nothing when modes is empty", () => {
    const { container } = render(
      <ModeSelector modes={[]} value="plan" onChange={() => {}} />,
    );
    expect(container.firstChild).toBeNull();
  });

  it("renders nothing when modes has only one entry", () => {
    const { container } = render(
      <ModeSelector modes={["plan"]} value="plan" onChange={() => {}} />,
    );
    expect(container.firstChild).toBeNull();
  });

  it("renders a select with one option per mode", () => {
    render(
      <ModeSelector modes={["plan", "act"]} value="plan" onChange={() => {}} />,
    );
    const select = screen.getByLabelText("Mode");
    expect(select).toBeInTheDocument();
    expect(select.tagName).toBe("SELECT");

    const options = screen.getAllByRole("option");
    expect(options).toHaveLength(2);
    expect(options[0]).toHaveTextContent("plan");
    expect(options[1]).toHaveTextContent("act");
  });

  it("marks the matching option as selected", () => {
    render(
      <ModeSelector modes={["plan", "act"]} value="act" onChange={() => {}} />,
    );
    const buildOption = screen.getByRole("option", { name: "act" });
    expect(buildOption.selected).toBe(true);

    const chatOption = screen.getByRole("option", { name: "plan" });
    expect(chatOption.selected).toBe(false);
  });

  it("calls onChange when the user picks a different option", () => {
    const onChange = vi.fn();
    render(
      <ModeSelector modes={["plan", "act"]} value="plan" onChange={onChange} />,
    );

    fireEvent.change(screen.getByLabelText("Mode"), {
      target: { value: "act" },
    });
    expect(onChange).toHaveBeenCalledWith("act");
  });

  it("offers a two-button toggle below lg and keeps the select from lg up", () => {
    // `Nest.Modes` is a two-value catalogue, so a phone gets a segmented toggle:
    // a `<select>` there is a full-screen wheel picker for one bit of choice, and
    // it costs the composer row ~75px. Both controls are in the DOM and a
    // breakpoint decides which one is on screen, the same way the pane's tab and
    // its toggle are.
    const onChange = vi.fn();
    render(
      <ModeSelector modes={["plan", "act"]} value="act" onChange={onChange} />,
    );

    const group = screen.getByRole("group", { name: "Agent mode" });
    expect(group.className).toContain("lg:hidden");
    expect(screen.getByLabelText("Mode").className).toContain("max-lg:hidden");

    // The current mode is the pressed one; the other is a live button.
    const plan = screen.getByRole("button", { name: "plan" });
    const act = screen.getByRole("button", { name: "act" });
    expect(act).toHaveAttribute("aria-pressed", "true");
    expect(plan).toHaveAttribute("aria-pressed", "false");

    // One tap switches; the button is 44px tall like every other phone control.
    fireEvent.click(plan);
    expect(onChange).toHaveBeenCalledWith("plan");
    expect(plan.className).toContain("py-3");
  });

  it("renders as disabled when the disabled prop is set", () => {
    render(
      <ModeSelector
        modes={["plan", "act"]}
        value="plan"
        onChange={() => {}}
        disabled={true}
      />,
    );
    expect(screen.getByLabelText("Mode")).toBeDisabled();
  });

  it("shows an obvious indicator when the server has not said which mode the agent is in", () => {
    // The value is the server's (`currentMode`), so before the agent's `init`
    // there is nothing to show. AGENTS.md's transparency rule asks for an obvious
    // indicator rather than nothing — and a `<select>` would display its first
    // option as selected, a mode the agent is not in.
    const { container } = render(
      <ModeSelector modes={["plan", "act"]} value={null} onChange={() => {}} />,
    );

    expect(container.querySelector("select")).not.toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("mode: (missing)");
  });

  it("shows an obvious indicator for a value the server's list does not contain", () => {
    // A mode the server does not have cannot be displayed as the current one,
    // must not be silently replaced by the first option, and must not be hidden.
    const { container } = render(
      <ModeSelector modes={["plan", "act"]} value="chat" onChange={() => {}} />,
    );

    expect(container.querySelector("select")).not.toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("mode: unknown (chat)");
  });

  it("still renders nothing for a single-mode agent, which is not a missing value", () => {
    const { container } = render(
      <ModeSelector modes={["act"]} value="act" onChange={() => {}} />,
    );

    expect(container.querySelector("select")).not.toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });
});
