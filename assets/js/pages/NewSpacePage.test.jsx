/**
 * Tests for the NewSpacePage form.
 *
 * Covers the pure `validateNewSpaceForm` helper plus the form's
 * render + submit flow: validation gating, blueprint/model option
 * rendering, `createSpace` payload construction, loading state, and
 * success/error navigation + messaging.
 *
 * The store is mocked with a selector-based `useStore` (the page
 * subscribes via `useStore((s) => s.models)` etc.), and `createSpace`
 * is mocked so tests can drive the success/error callbacks directly.
 */
import { describe, it, expect, beforeEach, vi } from "vitest";
import { render, screen, fireEvent, act } from "@testing-library/react";
import { MemoryRouter, Routes, Route, useParams } from "react-router-dom";

let mockState = { models: [], blueprints: [], vocations: [] };

vi.mock("../store", () => ({
  useStore: (selector) => selector(mockState),
}));

const mocks = vi.hoisted(() => ({
  createSpace: vi.fn(),
  suggestSpaceName: vi.fn(),
  rescanModels: vi.fn(),
}));

// Spread the real module and override only the three pushes this file
// spies on. Hand-enumerating the exports means a page that gains a new
// module-scope channel import fails to load with a confusing "No export
// is defined on the mock" error.
vi.mock("../channels", async () => {
  const actual = await vi.importActual("../channels");
  return {
    ...actual,
    createSpace: mocks.createSpace,
    suggestSpaceName: mocks.suggestSpaceName,
    rescanModels: mocks.rescanModels,
  };
});

import { NewSpacePage, validateNewSpaceForm } from "./NewSpacePage";
import {
  DEFAULT_SANDBOX_BACKEND,
  SANDBOX_BACKENDS,
  sandboxBackendHelp,
} from "../utils/newSpaceForm";

function SpaceRoute() {
  const { spaceSlug } = useParams();
  return <div>Space {spaceSlug}</div>;
}

function renderPage() {
  return render(
    <MemoryRouter initialEntries={["/spaces/new"]}>
      <Routes>
        <Route path="/spaces/new" element={<NewSpacePage />} />
        <Route path="/spaces" element={<div>Spaces Landing</div>} />
        <Route path="/space/:spaceSlug" element={<SpaceRoute />} />
      </Routes>
    </MemoryRouter>,
  );
}

const sampleBlueprints = [
  {
    id: 1,
    name: "Chat",
    description: "A conversational space.",
    root_vocation: "chat",
    // The seeded Chat blueprint is the one whose agents are offline by default.
    default_net: false,
  },
  {
    id: 2,
    name: "Grading",
    description: "A grading space.",
    root_vocation: "grading-coordinator",
    default_net: true,
  },
];

const sampleVocations = [
  { id: 10, name: "Chat", slug: "chat" },
  // No `modes`: the modes are universal code constants now, so a vocation no
  // longer carries any — nothing in the form reads one.
  { id: 20, name: "Grading Coordinator", slug: "grading-coordinator" },
];

const sampleModels = [
  { name: "qwen3.5-plus", provider: "model-studio" },
  { name: "gpt-4o", provider: "openai" },
];

describe("validateNewSpaceForm", () => {
  it("requires a space name", () => {
    expect(
      validateNewSpaceForm({
        name: "  ",
        selectedBlueprint: "1",
        selectedModel: "gpt-4o",
      }),
    ).toBe("Please enter a space name");
  });

  it("requires a blueprint selection", () => {
    expect(
      validateNewSpaceForm({
        name: "My Space",
        selectedBlueprint: "",
        selectedModel: "gpt-4o",
      }),
    ).toBe("Please select a blueprint");
  });

  it("requires a model selection", () => {
    expect(
      validateNewSpaceForm({
        name: "My Space",
        selectedBlueprint: "1",
        selectedModel: "",
      }),
    ).toBe("Please select a model");
  });

  it("returns null when all fields are valid", () => {
    for (const sandboxBackend of SANDBOX_BACKENDS) {
      expect(
        validateNewSpaceForm({
          name: "My Space",
          selectedBlueprint: "1",
          selectedModel: "gpt-4o",
          sandboxBackend,
          requiresWorkspace: true,
          workspacePath: "/home/nat/proj",
        }),
      ).toBeNull();
    }
  });

  it("requires a workspace path when the vocation needs one", () => {
    expect(
      validateNewSpaceForm({
        name: "My Space",
        selectedBlueprint: "2",
        selectedModel: "gpt-4o",
        sandboxBackend: "bwrap",
        requiresWorkspace: true,
        workspacePath: "",
      }),
    ).toBe("Please specify a workspace path");
  });

  it("passes when a required workspace path is supplied", () => {
    expect(
      validateNewSpaceForm({
        name: "My Space",
        selectedBlueprint: "2",
        selectedModel: "gpt-4o",
        sandboxBackend: "bwrap",
        requiresWorkspace: true,
        workspacePath: "/home/nat/proj",
      }),
    ).toBeNull();
  });

  it("rejects a sandbox backend that isn't one of the three", () => {
    const base = {
      name: "My Space",
      selectedBlueprint: "1",
      selectedModel: "gpt-4o",
    };
    expect(
      validateNewSpaceForm({ ...base, sandboxBackend: "kubernetes" }),
    ).toBe("Please select a sandbox backend");
    expect(validateNewSpaceForm(base)).toBe("Please select a sandbox backend");
  });
});

describe("sandbox backends", () => {
  it("defaults to bwrap and offers it first", () => {
    expect(SANDBOX_BACKENDS).toEqual(["bwrap", "docker", "none"]);
    expect(DEFAULT_SANDBOX_BACKEND).toBe("bwrap");
  });

  it("describes each backend and says none can't enforce the caps", () => {
    for (const backend of SANDBOX_BACKENDS) {
      expect(sandboxBackendHelp(backend)).toBeTruthy();
    }
    expect(sandboxBackendHelp("docker")).toMatch(/docker/i);
    expect(sandboxBackendHelp("none")).toMatch(/cannot be enforced/i);
  });

  it("renders an obvious error rather than nothing for an unknown backend", () => {
    expect(sandboxBackendHelp("kubernetes")).toMatch(
      /unknown sandbox backend/i,
    );
    expect(sandboxBackendHelp(undefined)).toMatch(/unknown sandbox backend/i);
  });
});

describe("NewSpacePage", () => {
  beforeEach(() => {
    // The host the server injects into `window.NEST_CONFIG`, plus the
    // shell's default title: a page test proves the page *replaces* it.
    window.NEST_CONFIG = { host: "vampire" };
    document.title = "Nest · Phoenix Framework";

    mockState = {
      models: sampleModels,
      blueprints: sampleBlueprints,
      vocations: sampleVocations,
      suggestedName: "clever-raven",
    };
    mocks.createSpace.mockReset();
    mocks.suggestSpaceName.mockReset();
    mocks.rescanModels.mockReset();
  });

  it("pre-fills the name with the backend-suggested name", () => {
    renderPage();

    expect(screen.getByLabelText("Space Name")).toHaveValue("clever-raven");
  });

  it("does not overwrite a name the user has already typed", () => {
    renderPage();
    fireEvent.change(screen.getByLabelText("Space Name"), {
      target: { value: "My Project" },
    });

    expect(screen.getByLabelText("Space Name")).toHaveValue("My Project");
  });

  it("renders the form with blueprint and model options", () => {
    renderPage();

    expect(
      screen.getByRole("heading", { name: "Create New Space" }),
    ).toBeInTheDocument();

    expect(screen.getByLabelText("Space Name")).toBeInTheDocument();

    expect(screen.getByRole("option", { name: "Chat" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "Grading" })).toBeInTheDocument();

    expect(
      screen.getByRole("option", { name: "qwen3.5-plus (model-studio)" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("option", { name: "gpt-4o (openai)" }),
    ).toBeInTheDocument();

    expect(document.title).toBe("vampire · New space");
  });

  it("offers the three sandbox backends with bwrap selected by default", () => {
    renderPage();

    const select = screen.getByLabelText("Sandbox");
    expect(select).toHaveValue(DEFAULT_SANDBOX_BACKEND);
    for (const backend of SANDBOX_BACKENDS) {
      expect(screen.getByRole("option", { name: backend })).toBeInTheDocument();
    }
    expect(screen.getByText(sandboxBackendHelp("bwrap"))).toBeInTheDocument();
  });

  it("shows the selected backend's help text, including that none can't enforce caps", () => {
    renderPage();

    fireEvent.change(screen.getByLabelText("Sandbox"), {
      target: { value: "none" },
    });

    expect(screen.getByText(/cannot be enforced/i)).toBeInTheDocument();
    expect(screen.queryByText(sandboxBackendHelp("bwrap"))).toBeNull();
  });

  it("shows the selected blueprint's root agent vocation", () => {
    renderPage();

    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "2" },
    });

    expect(
      screen.getByText((content) => content.includes("Grading Coordinator")),
    ).toBeInTheDocument();
    expect(
      screen.getByText((content) => content.includes("Root agent vocation")),
    ).toBeInTheDocument();
  });

  it("renders a model without a provider as just its name", () => {
    mockState = {
      models: [{ name: "gpt-4o" }],
      blueprints: sampleBlueprints,
    };

    renderPage();

    expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument();
  });

  it("always shows the workspace path input, whichever blueprint is selected", () => {
    // Every space has a workspace now: `vocationRequiresWorkspace` is a constant
    // (`true`), because the modes are universal code constants — `act` writes the
    // workspace, and every agent can be in `act`. There is no vocation left for
    // the form to hide the input for.
    renderPage();

    for (const blueprint of ["1", "2"]) {
      fireEvent.change(screen.getByLabelText("Select Blueprint"), {
        target: { value: blueprint },
      });

      expect(screen.getByLabelText("Workspace Path")).toBeInTheDocument();
    }
  });

  it("blocks submission when a required workspace path is missing", () => {
    renderPage();

    fireEvent.change(screen.getByLabelText("Space Name"), {
      target: { value: "My Project" },
    });
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "2" },
    });
    fireEvent.change(screen.getByLabelText("Select Model"), {
      target: { value: "gpt-4o" },
    });

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    expect(
      screen.getByText("Please specify a workspace path"),
    ).toBeInTheDocument();
    expect(mocks.createSpace).not.toHaveBeenCalled();
  });

  it("shows a validation error and does not create on empty submit", () => {
    mockState = { ...mockState, suggestedName: null };

    renderPage();

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    expect(screen.getByText("Please enter a space name")).toBeInTheDocument();
    expect(mocks.createSpace).not.toHaveBeenCalled();
  });

  it("shows the selected blueprint's description", () => {
    renderPage();

    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "2" },
    });

    expect(screen.getByText("A grading space.")).toBeInTheDocument();
  });

  it("calls createSpace with the space name, blueprint_id, workspace_path, and sandbox_backend on valid submit", () => {
    renderPage();

    fireEvent.change(screen.getByLabelText("Space Name"), {
      target: { value: "My Project" },
    });
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "2" },
    });
    fireEvent.change(screen.getByLabelText("Select Model"), {
      target: { value: "gpt-4o" },
    });
    fireEvent.change(screen.getByLabelText("Workspace Path"), {
      target: { value: "/home/nat/proj" },
    });
    fireEvent.change(screen.getByLabelText("Sandbox"), {
      target: { value: "docker" },
    });

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    expect(mocks.createSpace).toHaveBeenCalledTimes(1);
    const [model, vocationId, onOk, onError, opts] =
      mocks.createSpace.mock.calls[0];
    expect(model).toEqual({
      name: "gpt-4o",
      provider: "openai",
      thinking_level: "medium",
    });
    expect(vocationId).toBeNull();
    expect(typeof onOk).toBe("function");
    expect(typeof onError).toBe("function");
    expect(opts).toEqual({
      name: "My Project",
      blueprint_id: 2,
      workspace_path: "/home/nat/proj",
      sandbox_backend: "docker",
      // Network access is a space property, chosen here and editable later; the
      // toggle defaults to on.
      network_access: true,
    });
  });

  it("sends network access off when the toggle is cleared", () => {
    renderPage();

    fireEvent.change(screen.getByLabelText("Space Name"), {
      target: { value: "Closed Project" },
    });
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "2" },
    });
    fireEvent.change(screen.getByLabelText("Select Model"), {
      target: { value: "gpt-4o" },
    });
    fireEvent.change(screen.getByLabelText("Workspace Path"), {
      target: { value: "/home/nat/proj" },
    });

    fireEvent.click(screen.getByLabelText("Network access"));
    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    const opts = mocks.createSpace.mock.calls[0][4];
    expect(opts.network_access).toBe(false);
  });

  it("pre-fills network access from the selected blueprint, and follows a change", () => {
    renderPage();

    // Nothing selected yet: the toggle keeps the value a space got before
    // blueprints had a `default_net`.
    expect(screen.getByLabelText("Network access")).toBeChecked();

    // Chat's default is off...
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "1" },
    });
    expect(screen.getByLabelText("Network access")).not.toBeChecked();

    // ...and Grading's is on.
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "2" },
    });
    expect(screen.getByLabelText("Network access")).toBeChecked();
  });

  it("keeps the user's own choice when the blueprint changes", () => {
    renderPage();

    // Chat's default is off; the user turns it on anyway.
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "1" },
    });
    fireEvent.click(screen.getByLabelText("Network access"));
    expect(screen.getByLabelText("Network access")).toBeChecked();

    // Going to Grading and *back to Chat* must not resurrect Chat's default: a
    // blueprint's value is a default, and the user's choice is the choice.
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "2" },
    });
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "1" },
    });
    expect(screen.getByLabelText("Network access")).toBeChecked();
  });

  it("sends the blueprint's default when the user leaves the toggle alone", () => {
    renderPage();

    fireEvent.change(screen.getByLabelText("Space Name"), {
      target: { value: "My Project" },
    });
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "1" },
    });
    fireEvent.change(screen.getByLabelText("Select Model"), {
      target: { value: "gpt-4o" },
    });
    fireEvent.change(screen.getByLabelText("Workspace Path"), {
      target: { value: "/home/nat/proj" },
    });

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    expect(mocks.createSpace.mock.calls[0][4].network_access).toBe(false);
  });

  it("navigates to the new space's page on success", () => {
    renderPage();

    fireEvent.change(screen.getByLabelText("Space Name"), {
      target: { value: "My Project" },
    });
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "1" },
    });
    fireEvent.change(screen.getByLabelText("Select Model"), {
      target: { value: "gpt-4o" },
    });
    fireEvent.change(screen.getByLabelText("Workspace Path"), {
      target: { value: "/home/nat/proj" },
    });

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    const onOk = mocks.createSpace.mock.calls[0][2];
    act(() => onOk({ space_id: 5, name: "my-project", slug: "my-project" }));

    expect(screen.getByText("Space my-project")).toBeInTheDocument();
    expect(mocks.suggestSpaceName).toHaveBeenCalledTimes(1);
  });

  it("falls back to a name-only model object when the model is unknown", () => {
    mockState = {
      models: [],
      blueprints: sampleBlueprints,
      vocations: sampleVocations,
    };

    renderPage();

    fireEvent.change(screen.getByLabelText("Space Name"), {
      target: { value: "My Project" },
    });
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "1" },
    });
    fireEvent.change(screen.getByLabelText("Select Model"), {
      target: { value: "gpt-4" },
    });
    fireEvent.change(screen.getByLabelText("Workspace Path"), {
      target: { value: "/home/nat/proj" },
    });

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    const [model] = mocks.createSpace.mock.calls[0];
    expect(model).toEqual({ name: "gpt-4", thinking_level: "medium" });
  });

  it("shows the server's reason, or a generic message when it sent none", () => {
    renderPage();

    fireEvent.change(screen.getByLabelText("Space Name"), {
      target: { value: "My Project" },
    });
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "1" },
    });
    fireEvent.change(screen.getByLabelText("Select Model"), {
      target: { value: "gpt-4o" },
    });
    fireEvent.change(screen.getByLabelText("Workspace Path"), {
      target: { value: "/home/nat/proj" },
    });

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    const onError = mocks.createSpace.mock.calls[0][3];

    // The channel replies `{reason: <code>}`, so reading `err.message` here
    // would silently drop the only explanation the server sent.
    act(() => onError({ reason: "workspace_under_tmp" }));
    expect(screen.getByText(/can't be under \/tmp/i)).toBeInTheDocument();

    act(() => onError({}));
    expect(screen.getByText("Failed to create space.")).toBeInTheDocument();
  });

  it("shows the error and re-enables the button on failure", () => {
    renderPage();

    fireEvent.change(screen.getByLabelText("Space Name"), {
      target: { value: "My Project" },
    });
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "1" },
    });
    fireEvent.change(screen.getByLabelText("Select Model"), {
      target: { value: "gpt-4o" },
    });
    fireEvent.change(screen.getByLabelText("Workspace Path"), {
      target: { value: "/home/nat/proj" },
    });

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    const onError = mocks.createSpace.mock.calls[0][3];
    act(() => onError({ message: "boom" }));

    expect(screen.getByText("boom")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Create Space" })).toBeEnabled();
  });

  it("shows a loading state while the push is pending", () => {
    mocks.createSpace.mockImplementation(() => {});

    renderPage();

    fireEvent.change(screen.getByLabelText("Space Name"), {
      target: { value: "My Project" },
    });
    fireEvent.change(screen.getByLabelText("Select Blueprint"), {
      target: { value: "1" },
    });
    fireEvent.change(screen.getByLabelText("Select Model"), {
      target: { value: "gpt-4o" },
    });
    fireEvent.change(screen.getByLabelText("Workspace Path"), {
      target: { value: "/home/nat/proj" },
    });

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    expect(
      screen.getByRole("button", { name: "Creating Space..." }),
    ).toBeDisabled();
    expect(screen.getByLabelText("Space Name")).toBeDisabled();
    expect(screen.getByLabelText("Sandbox")).toBeDisabled();
  });

  it("renders a fallback model option when models is empty", () => {
    mockState = { models: [], blueprints: sampleBlueprints };

    renderPage();

    expect(
      screen.getByRole("option", { name: "gpt-4 (fallback)" }),
    ).toBeInTheDocument();
  });

  it("renders without error when blueprints is undefined", () => {
    mockState = { models: sampleModels, blueprints: undefined };

    renderPage();

    expect(
      screen.getByRole("option", { name: "Choose a blueprint..." }),
    ).toBeInTheDocument();
  });

  // ─────────────────────────────────────────────────────────────────
  // RESCAN COMPLETION CONTRACT — DO NOT WEAKEN WITHOUT AN EXPLICIT
  // USER INSTRUCTION.
  //
  // The "Rescan providers" button must stay disabled until the server
  // says the scan is actually done. The server streams a
  // `models_updated` event per provider as a *partial*; those are NOT
  // completion. Completion is the `rescanModels` success (`onOk`)
  // callback, which the server fires exactly once, after every
  // auto-provider has answered (or the scan's deadline fired). A
  // regression here is precisely the bug where a fast first provider
  // re-enabled the button mid-scan and the rescan looked like a no-op.
  // ─────────────────────────────────────────────────────────────────
  it("calls rescanModels when the Rescan providers button is clicked", () => {
    renderPage();

    fireEvent.click(screen.getByRole("button", { name: "Rescan providers" }));

    expect(mocks.rescanModels).toHaveBeenCalledTimes(1);
  });

  it("stays disabled across models_updated partials and clears only on scan completion", () => {
    const { rerender } = renderPage();

    let onOk;
    mocks.rescanModels.mockImplementation((ok) => {
      onOk = ok;
    });

    fireEvent.click(screen.getByRole("button", { name: "Rescan providers" }));

    const button = screen.getByRole("button", { name: "Rescan providers" });
    expect(button).toBeDisabled();
    expect(button).toHaveTextContent(/rescanning/i);

    // A `models_updated` partial replaces the store's `models` array
    // with a fresh identity. It must NOT clear the spinner.
    mockState = {
      ...mockState,
      models: [...sampleModels, { name: "partial-1" }],
    };
    act(() => {
      rerender(
        <MemoryRouter initialEntries={["/spaces/new"]}>
          <Routes>
            <Route path="/spaces/new" element={<NewSpacePage />} />
            <Route path="/spaces" element={<div>Spaces Landing</div>} />
            <Route path="/space/:spaceSlug" element={<SpaceRoute />} />
          </Routes>
        </MemoryRouter>,
      );
    });

    expect(
      screen.getByRole("button", { name: "Rescan providers" }),
    ).toHaveTextContent(/rescanning/i);

    // A second partial must not clear it either.
    mockState = {
      ...mockState,
      models: [...sampleModels, { name: "partial-2" }],
    };
    act(() => {
      rerender(
        <MemoryRouter initialEntries={["/spaces/new"]}>
          <Routes>
            <Route path="/spaces/new" element={<NewSpacePage />} />
            <Route path="/spaces" element={<div>Spaces Landing</div>} />
            <Route path="/space/:spaceSlug" element={<SpaceRoute />} />
          </Routes>
        </MemoryRouter>,
      );
    });
    expect(
      screen.getByRole("button", { name: "Rescan providers" }),
    ).toBeDisabled();

    // Only the server's completion callback re-enables it.
    act(() => {
      onOk();
    });

    const reenabled = screen.getByRole("button", { name: "Rescan providers" });
    expect(reenabled).not.toBeDisabled();
    expect(reenabled).toHaveTextContent("Rescan providers");
  });

  it("clears the spinner and shows an error when the rescan push fails", () => {
    renderPage();
    mocks.rescanModels.mockImplementation((_onOk, onError) => {
      onError(new Error("nope"));
    });

    fireEvent.click(screen.getByRole("button", { name: "Rescan providers" }));

    expect(
      screen.getByRole("button", { name: "Rescan providers" }),
    ).not.toBeDisabled();
    expect(screen.getByText("nope")).toBeInTheDocument();
  });
});
