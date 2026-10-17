import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";

import { EditAgentDialog } from "./EditAgentDialog";

let storeModels;

vi.mock("../store", () => ({
  useStore: () => storeModels,
}));

beforeEach(() => {
  storeModels = [
    {
      name: "gpt-4o",
      provider: "openai",
      thinking_levels: ["off", "low", "medium", "high"],
    },
    { name: "claude-3-opus", provider: "anthropic-provider" },
  ];
});

const current = {
  name: "gpt-4o",
  provider: "openai",
  thinking_level: "high",
};

function setup(overrides = {}) {
  const onSave = vi.fn();
  const onClose = vi.fn();
  render(
    <EditAgentDialog
      open
      onClose={onClose}
      onSave={onSave}
      current={current}
      {...overrides}
    />,
  );
  return { onSave, onClose };
}

describe("EditAgentDialog", () => {
  it("has no working-directory field", () => {
    // A workspace is a *space* property (`spaces.workspace_path`), so the agent
    // dialog neither shows nor sends one.
    setup();
    expect(screen.queryByLabelText("Working Directory")).toBeNull();
  });

  it("initializes from the current values", () => {
    setup();
    expect(screen.getByLabelText("Thinking Level").value).toBe("high");
    expect(screen.getByLabelText("Model").value).toBe("gpt-4o");
  });

  it("Reset reverts the form to the current values", () => {
    setup();
    fireEvent.change(screen.getByLabelText("Thinking Level"), {
      target: { value: "low" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Reset" }));
    expect(screen.getByLabelText("Thinking Level").value).toBe("high");
  });

  it("Save emits the model", () => {
    const { onSave } = setup();
    fireEvent.change(screen.getByLabelText("Thinking Level"), {
      target: { value: "low" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(onSave).toHaveBeenCalledWith({
      model: { name: "gpt-4o", provider: "openai", thinking_level: "low" },
    });
  });

  it("blocks Save when no model is selected", () => {
    setup({ current: { ...current, name: "", provider: null } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(screen.getByRole("alert")).toHaveTextContent(/select a model/i);
  });

  it("resets the thinking level when the model changes", () => {
    setup();
    fireEvent.change(screen.getByLabelText("Model"), {
      target: { value: "claude-3-opus" },
    });
    expect(screen.getByLabelText("Thinking Level").value).toBe("medium");
  });

  it("falls back to the default thinking levels when the model has none", () => {
    setup();
    fireEvent.change(screen.getByLabelText("Model"), {
      target: { value: "claude-3-opus" },
    });
    // "claude-3-opus" has no thinking_levels → DEFAULT_THINKING_LEVELS
    expect(screen.getByLabelText("Thinking Level").value).toBe("medium");
    expect(screen.getAllByRole("option").some((o) => o.value === "xhigh")).toBe(
      true,
    );
  });

  it("renders nothing when closed", () => {
    setup({ open: false });
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("closes via the close button", () => {
    const { onClose } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Close" }));
    expect(onClose).toHaveBeenCalled();
  });

  it("closes via the Escape key", () => {
    const { onClose } = setup();
    fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });
    expect(onClose).toHaveBeenCalled();
  });

  it("closes via a backdrop click", () => {
    const { onClose } = setup();
    const dialog = screen.getByRole("dialog");
    fireEvent.click(dialog, { target: dialog });
    expect(onClose).toHaveBeenCalled();
  });
});
