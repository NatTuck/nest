/**
 * Tests for `EditSpaceDialog` — the one form that edits a space's environment.
 *
 * It pins the three fields (a save sends all of them, because they are one
 * decision), the consequence sentence (a backend change releases the container,
 * which is not something the user can discover afterwards), the per-backend help
 * text it borrows from the New Space form, and a refused save: the server's
 * reason has to reach the user with the dialog still open.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";

import { EDIT_SPACE_CONSEQUENCE, EditSpaceDialog } from "./EditSpaceDialog";
import { sandboxBackendHelp } from "../utils/newSpaceForm";

const mocks = vi.hoisted(() => ({ editSpace: vi.fn() }));

vi.mock("../channels", () => ({
  editSpace: mocks.editSpace,
}));

const space = {
  id: 7,
  name: "My Space",
  workspace_path: "/home/nat/ws",
  network_access: true,
  sandbox_backend: "bwrap",
};

function setup(overrides = {}) {
  const onClose = vi.fn();
  const utils = render(
    <EditSpaceDialog open onClose={onClose} space={space} {...overrides} />,
  );
  return { onClose, ...utils };
}

beforeEach(() => {
  mocks.editSpace.mockReset();
});

describe("EditSpaceDialog", () => {
  it("initializes all three fields from the space", () => {
    setup();

    expect(screen.getByLabelText("Workspace Path").value).toBe("/home/nat/ws");
    expect(screen.getByLabelText("Network access").checked).toBe(true);
    expect(screen.getByLabelText("Sandbox").value).toBe("bwrap");
  });

  it("saves all three fields in one push and closes on success", () => {
    mocks.editSpace.mockImplementation((_id, _values, onOk) => onOk({}));
    const { onClose } = setup();

    fireEvent.change(screen.getByLabelText("Workspace Path"), {
      target: { value: "/home/nat/other" },
    });
    fireEvent.click(screen.getByLabelText("Network access"));
    fireEvent.change(screen.getByLabelText("Sandbox"), {
      target: { value: "docker" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    expect(mocks.editSpace).toHaveBeenCalledWith(
      7,
      {
        workspace_path: "/home/nat/other",
        network_access: false,
        sandbox_backend: "docker",
      },
      expect.any(Function),
      expect.any(Function),
    );
    expect(onClose).toHaveBeenCalled();
  });

  it("states what a save does, including what a backend change costs", () => {
    setup();

    expect(screen.getByText(EDIT_SPACE_CONSEQUENCE)).toBeInTheDocument();
    // The two facts the user cannot discover afterwards.
    expect(EDIT_SPACE_CONSEQUENCE).toMatch(/every agent here is told/);
    expect(EDIT_SPACE_CONSEQUENCE).toMatch(
      /releases this space's container.*\/tmp offloads, background-job logs and any running background job are lost/,
    );
  });

  it("reuses the New Space form's per-backend help text", () => {
    setup();

    expect(screen.getByText(sandboxBackendHelp("bwrap"))).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("Sandbox"), {
      target: { value: "none" },
    });

    expect(screen.getByText(sandboxBackendHelp("none"))).toBeInTheDocument();
    expect(sandboxBackendHelp("none")).toMatch(/cannot be enforced/);
  });

  it("shows the reason a save was refused, and stays open", () => {
    mocks.editSpace.mockImplementation((_id, _values, _onOk, onError) =>
      onError({ reason: "workspace_missing" }),
    );
    const { onClose } = setup();

    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    expect(screen.getByRole("alert").textContent).toMatch(
      /working directory doesn't exist on the server/,
    );
    expect(onClose).not.toHaveBeenCalled();
  });

  it("blocks a save with no workspace path", () => {
    setup();

    fireEvent.change(screen.getByLabelText("Workspace Path"), {
      target: { value: "   " },
    });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    expect(mocks.editSpace).not.toHaveBeenCalled();
    expect(screen.getByRole("alert").textContent).toMatch(
      /Please enter a workspace path/,
    );
  });

  it("closes via the Escape key", () => {
    const { onClose } = setup();

    fireEvent.keyDown(screen.getByRole("dialog", { name: "Edit space" }), {
      key: "Escape",
    });

    expect(onClose).toHaveBeenCalled();
  });

  it("closes via a click on the backdrop, but not inside the panel", () => {
    const { onClose } = setup();
    const dialog = screen.getByRole("dialog", { name: "Edit space" });

    fireEvent.click(screen.getByLabelText("Workspace Path"));
    expect(onClose).not.toHaveBeenCalled();

    fireEvent.click(dialog);
    expect(onClose).toHaveBeenCalled();
  });

  it("renders nothing when closed", () => {
    const { container } = render(
      <EditSpaceDialog open={false} onClose={vi.fn()} space={space} />,
    );

    expect(container).toBeEmptyDOMElement();
  });

  it("says so, loudly, when it is opened without a space", () => {
    // The page only opens this for a space it found, so a missing one is a bug
    // in the caller — and an empty form would look like a real space with an
    // empty workspace, which a save would then write.
    setup({ space: null });

    expect(screen.getByRole("alert").textContent).toMatch(
      /opened without a space.*bug in the page/,
    );
    expect(screen.queryByLabelText("Workspace Path")).not.toBeInTheDocument();
  });
});
