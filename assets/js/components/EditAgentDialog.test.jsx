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
  workspace_path: "/current/workspace",
  requires_workspace: true,
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
  it("shows the workspace field only for a workspace-requiring agent", () => {
    setup();
    expect(screen.getByLabelText("Working Directory")).toBeInTheDocument();
  });

  it("hides the workspace field for an agent with neither a workspace nor a requirement", () => {
    setup({
      current: { ...current, requires_workspace: false, workspace_path: "" },
    });
    expect(screen.queryByLabelText("Working Directory")).toBeNull();
  });

  it("shows the workspace field when the agent already has a workspace", () => {
    setup({
      current: {
        ...current,
        requires_workspace: false,
        workspace_path: "/existing",
      },
    });
    expect(screen.getByLabelText("Working Directory")).toBeInTheDocument();
    expect(screen.getByLabelText("Working Directory").value).toBe("/existing");
  });

  it("initializes from the current values", () => {
    setup();
    expect(screen.getByLabelText("Working Directory").value).toBe(
      "/current/workspace",
    );
    expect(screen.getByLabelText("Thinking Level").value).toBe("high");
    expect(screen.getByLabelText("Model").value).toBe("gpt-4o");
  });

  it("Reset reverts the form to the current values", () => {
    setup();
    fireEvent.change(screen.getByLabelText("Working Directory"), {
      target: { value: "/edited" },
    });
    fireEvent.change(screen.getByLabelText("Thinking Level"), {
      target: { value: "low" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Reset" }));
    expect(screen.getByLabelText("Working Directory").value).toBe(
      "/current/workspace",
    );
    expect(screen.getByLabelText("Thinking Level").value).toBe("high");
  });

  it("Save emits the model + workspace for a workspace agent", () => {
    const { onSave } = setup();
    fireEvent.change(screen.getByLabelText("Working Directory"), {
      target: { value: "/edited" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(onSave).toHaveBeenCalledWith({
      model: { name: "gpt-4o", provider: "openai", thinking_level: "high" },
      workspace_path: "/edited",
    });
  });

  it("Save emits a null workspace for a non-workspace agent", () => {
    const { onSave } = setup({
      current: { ...current, requires_workspace: false, workspace_path: "" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(onSave).toHaveBeenCalledWith({
      model: { name: "gpt-4o", provider: "openai", thinking_level: "high" },
      workspace_path: null,
    });
  });

  it("blocks Save when a workspace is required but empty", () => {
    setup({ current: { ...current, workspace_path: "" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(screen.getByRole("alert")).toHaveTextContent(/working directory/i);
    expect(screen.getByRole("button", { name: "Save" })).toBeInTheDocument();
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
