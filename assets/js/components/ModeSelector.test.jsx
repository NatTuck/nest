/**
 * Tests for the ModeSelector component.
 *
 * Covers:
 * - Renders nothing when modes is undefined or empty
 * - Renders nothing when modes has 0 or 1 entries
 * - Renders a <select> with one <option> per mode
 * - value/onChange wiring
 * - disabled prop
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

  it("renders nothing until the server has said which mode the agent is in", () => {
    // The value is the server's (`currentMode`), so before the agent's `init`
    // there is nothing to show. Rendering anyway would display the first option
    // as selected — a mode the agent is not in.
    const { container } = render(
      <ModeSelector modes={["plan", "act"]} value={null} onChange={() => {}} />,
    );
    expect(container.querySelector("select")).not.toBeInTheDocument();
  });

  it("renders nothing for a value the server's list does not contain", () => {
    // A mode the server does not have cannot be displayed as the current one,
    // and must not be silently replaced by the first option either.
    const { container } = render(
      <ModeSelector modes={["plan", "act"]} value="chat" onChange={() => {}} />,
    );
    expect(container.querySelector("select")).not.toBeInTheDocument();
  });
});
