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
import { MemoryRouter, Routes, Route } from "react-router-dom";

let mockState = { models: [], blueprints: [] };

vi.mock("../store", () => ({
  useStore: (selector) => selector(mockState),
}));

const mocks = vi.hoisted(() => ({
  createSpace: vi.fn(),
}));

vi.mock("../channels", () => ({
  createSpace: mocks.createSpace,
}));

import { NewSpacePage, validateNewSpaceForm } from "./NewSpacePage";

function renderPage() {
  return render(
    <MemoryRouter initialEntries={["/spaces/new"]}>
      <Routes>
        <Route path="/spaces/new" element={<NewSpacePage />} />
        <Route path="/spaces" element={<div>Spaces Landing</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

const sampleBlueprints = [
  { id: 1, name: "Agent", description: "A single-agent space." },
  { id: 2, name: "Code Review", description: "A reviewer space." },
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
    expect(
      validateNewSpaceForm({
        name: "My Space",
        selectedBlueprint: "1",
        selectedModel: "gpt-4o",
      }),
    ).toBeNull();
  });
});

describe("NewSpacePage", () => {
  beforeEach(() => {
    mockState = { models: sampleModels, blueprints: sampleBlueprints };
    mocks.createSpace.mockReset();
  });

  it("renders the form with blueprint and model options", () => {
    renderPage();

    expect(
      screen.getByRole("heading", { name: "Create New Space" }),
    ).toBeInTheDocument();

    expect(screen.getByLabelText("Space Name")).toBeInTheDocument();

    expect(screen.getByRole("option", { name: "Agent" })).toBeInTheDocument();
    expect(
      screen.getByRole("option", { name: "Code Review" }),
    ).toBeInTheDocument();

    expect(
      screen.getByRole("option", { name: "qwen3.5-plus (model-studio)" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("option", { name: "gpt-4o (openai)" }),
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

  it("shows a validation error and does not create on empty submit", () => {
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

    expect(screen.getByText("A reviewer space.")).toBeInTheDocument();
  });

  it("calls createSpace with the space name and blueprint_id on valid submit", () => {
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

    expect(mocks.createSpace).toHaveBeenCalledTimes(1);
    const [model, vocationId, onOk, onError, opts] =
      mocks.createSpace.mock.calls[0];
    expect(model).toEqual({ name: "gpt-4o", provider: "openai" });
    expect(vocationId).toBeNull();
    expect(typeof onOk).toBe("function");
    expect(typeof onError).toBe("function");
    expect(opts).toEqual({ name: "My Project", blueprint_id: 2 });
  });

  it("navigates to /spaces on success", () => {
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

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    const onOk = mocks.createSpace.mock.calls[0][2];
    act(() => onOk({ space_id: 5, name: "my-project" }));

    expect(screen.getByText("Spaces Landing")).toBeInTheDocument();
  });

  it("falls back to a name-only model object when the model is unknown", () => {
    mockState = { models: [], blueprints: sampleBlueprints };

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

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    const [model] = mocks.createSpace.mock.calls[0];
    expect(model).toEqual({ name: "gpt-4" });
  });

  it("falls back to a generic message when the error has no message", () => {
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

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    const onError = mocks.createSpace.mock.calls[0][3];
    act(() => onError({}));

    expect(screen.getByText("Failed to create space")).toBeInTheDocument();
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

    fireEvent.click(screen.getByRole("button", { name: "Create Space" }));

    expect(
      screen.getByRole("button", { name: "Creating Space..." }),
    ).toBeDisabled();
    expect(screen.getByLabelText("Space Name")).toBeDisabled();
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
});
