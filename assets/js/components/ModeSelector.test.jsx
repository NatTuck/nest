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
      <ModeSelector modes={undefined} value="chat" onChange={() => {}} />,
    );
    expect(container.firstChild).toBeNull();
  });

  it("renders nothing when modes is empty", () => {
    const { container } = render(
      <ModeSelector modes={[]} value="chat" onChange={() => {}} />,
    );
    expect(container.firstChild).toBeNull();
  });

  it("renders nothing when modes has only one entry", () => {
    const { container } = render(
      <ModeSelector modes={["chat"]} value="chat" onChange={() => {}} />,
    );
    expect(container.firstChild).toBeNull();
  });

  it("renders a select with one option per mode", () => {
    render(
      <ModeSelector
        modes={["chat", "build", "plan"]}
        value="chat"
        onChange={() => {}}
      />,
    );
    const select = screen.getByLabelText("Mode");
    expect(select).toBeInTheDocument();
    expect(select.tagName).toBe("SELECT");

    const options = screen.getAllByRole("option");
    expect(options).toHaveLength(3);
    expect(options[0]).toHaveTextContent("chat");
    expect(options[1]).toHaveTextContent("build");
    expect(options[2]).toHaveTextContent("plan");
  });

  it("marks the matching option as selected", () => {
    render(
      <ModeSelector
        modes={["chat", "build"]}
        value="build"
        onChange={() => {}}
      />,
    );
    const buildOption = screen.getByRole("option", { name: "build" });
    expect(buildOption.selected).toBe(true);

    const chatOption = screen.getByRole("option", { name: "chat" });
    expect(chatOption.selected).toBe(false);
  });

  it("calls onChange when the user picks a different option", () => {
    const onChange = vi.fn();
    render(
      <ModeSelector
        modes={["chat", "build"]}
        value="chat"
        onChange={onChange}
      />,
    );

    fireEvent.change(screen.getByLabelText("Mode"), {
      target: { value: "build" },
    });
    expect(onChange).toHaveBeenCalledWith("build");
  });

  it("renders as disabled when the disabled prop is set", () => {
    render(
      <ModeSelector
        modes={["chat", "build"]}
        value="chat"
        onChange={() => {}}
        disabled={true}
      />,
    );
    expect(screen.getByLabelText("Mode")).toBeDisabled();
  });
});
