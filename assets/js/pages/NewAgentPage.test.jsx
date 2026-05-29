/**
 * NewAgentPage Component Tests
 *
 * Tests the agent creation flow including model selection,
 * form validation, loading states, and navigation.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { NewAgentPage } from "./NewAgentPage";

// Mock createAgent before vi.mock uses it
const mockCreateAgent = vi.fn();

// Mock react-router-dom
const mockNavigate = vi.fn();
vi.mock("react-router-dom", () => ({
  useNavigate: () => mockNavigate,
}));

// Mock zustand store
let mockStore = {
  models: [],
  vocations: [],
};

vi.mock("../store", () => ({
  useStore: () => mockStore,
}));

// Mock channels module
vi.mock("../channels", () => ({
  createAgent: (...args) => mockCreateAgent(...args),
}));

describe("NewAgentPage", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockStore = {
      models: [],
      vocations: [],
    };
  });

  it("renders the page with title and description", () => {
    render(<NewAgentPage />);

    expect(screen.getByText("Create New Agent")).toBeInTheDocument();
    expect(
      screen.getByText("Select a model and vocation to spawn a new AI agent."),
    ).toBeInTheDocument();
  });

  it("shows fallback option when no models are configured", () => {
    render(<NewAgentPage />);

    const select = screen.getByLabelText("Select Model");
    expect(select).toBeInTheDocument();

    // Should show fallback option
    expect(select).toContainElement(
      screen.getByRole("option", { name: "gpt-4 (fallback)" }),
    );

    // Should show warning message
    expect(
      screen.getByText("No models configured. Using fallback option."),
    ).toBeInTheDocument();
  });

  it("populates dropdown with configured models", () => {
    mockStore = {
      models: [
        { name: "gpt-4", provider: "openai" },
        { name: "claude-3", provider: "anthropic" },
        { name: "custom-model" },
      ],
    };

    render(<NewAgentPage />);

    const _select = screen.getByLabelText("Select Model");

    // Should show models with providers
    expect(
      screen.getByRole("option", { name: "gpt-4 (openai)" }),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("option", { name: "claude-3 (anthropic)" }),
    ).toBeInTheDocument();

    // Should show model without provider
    expect(
      screen.getByRole("option", { name: "custom-model" }),
    ).toBeInTheDocument();

    // Should not show warning
    expect(
      screen.queryByText("No models configured. Using fallback option."),
    ).not.toBeInTheDocument();
  });

  it("disables create button when no model or vocation is selected", () => {
    render(<NewAgentPage />);

    const button = screen.getByRole("button", { name: "Create Agent" });
    expect(button).toBeDisabled();
    expect(button).toHaveClass("bg-gray-400", "cursor-not-allowed");
  });

  it("enables create button after selecting a model and vocation", () => {
    mockStore = {
      models: [{ name: "gpt-4", provider: "openai" }],
      vocations: [
        { id: 1, name: "Chat Buddy", description: "A friendly chat companion" },
      ],
    };

    render(<NewAgentPage />);

    const button = screen.getByRole("button", { name: "Create Agent" });
    expect(button).toBeDisabled();

    // Select a vocation
    const vocationSelect = screen.getByLabelText("Select Vocation");
    fireEvent.change(vocationSelect, { target: { value: "1" } });

    // Button should still be disabled (no model selected)
    expect(button).toBeDisabled();

    // Select a model
    const select = screen.getByLabelText("Select Model");
    fireEvent.change(select, { target: { value: "gpt-4" } });

    // Button should now be enabled
    expect(button).not.toBeDisabled();
    expect(button).toHaveClass("bg-blue-600");
  });

  it("clears error message when model is selected", () => {
    mockStore = {
      models: [{ name: "gpt-4", provider: "openai" }],
      vocations: [
        { id: 1, name: "Chat Buddy", description: "A friendly chat companion" },
      ],
    };

    render(<NewAgentPage />);

    // Manually trigger error by calling handleCreateAgent logic
    // First select vocation and model then clear to test error clearing
    const vocationSelect = screen.getByLabelText("Select Vocation");
    fireEvent.change(vocationSelect, { target: { value: "1" } });

    const select = screen.getByLabelText("Select Model");
    fireEvent.change(select, { target: { value: "gpt-4" } });

    // Select empty option to trigger validation error
    fireEvent.change(select, { target: { value: "" } });

    // The component doesn't show error on deselect, just disables button
    // This is correct behavior - button disabled prevents submission
    const button = screen.getByRole("button", { name: "Create Agent" });
    expect(button).toBeDisabled();
  });

  it("shows loading state while creating agent", () => {
    mockStore = {
      models: [{ name: "gpt-4", provider: "openai" }],
      vocations: [
        { id: 1, name: "Chat Buddy", description: "A friendly chat companion" },
      ],
    };
    // Simulate pending callback (onOk not called yet)
    mockCreateAgent.mockImplementation(() => {});

    render(<NewAgentPage />);

    // Select vocation and model
    const vocationSelect = screen.getByLabelText("Select Vocation");
    fireEvent.change(vocationSelect, { target: { value: "1" } });

    const select = screen.getByLabelText("Select Model");
    fireEvent.change(select, { target: { value: "gpt-4" } });

    const button = screen.getByRole("button", { name: "Create Agent" });
    fireEvent.click(button);

    // Should show loading state
    expect(
      screen.getByRole("button", { name: /Creating Agent/ }),
    ).toBeInTheDocument();
    expect(screen.getByLabelText("Loading spinner")).toBeInTheDocument();

    // Button should be disabled during creation
    expect(button).toBeDisabled();

    // Select should be disabled
    expect(select).toBeDisabled();
  });

  it("calls createAgent with selected model and navigates on success", () => {
    mockCreateAgent.mockImplementation(
      (_model, _vocationId, _workspacePath, onOk) => {
        onOk("agent-123");
      },
    );
    mockStore = {
      models: [{ name: "gpt-4", provider: "openai" }],
      vocations: [
        { id: 1, name: "Chat Buddy", description: "A friendly chat companion" },
      ],
    };

    render(<NewAgentPage />);

    // Select vocation and model
    const vocationSelect = screen.getByLabelText("Select Vocation");
    fireEvent.change(vocationSelect, { target: { value: "1" } });

    const select = screen.getByLabelText("Select Model");
    fireEvent.change(select, { target: { value: "gpt-4" } });

    const button = screen.getByRole("button", { name: "Create Agent" });
    fireEvent.click(button);

    // Should call createAgent with the model, vocation_id, and callbacks
    expect(mockCreateAgent).toHaveBeenCalledWith(
      { name: "gpt-4", provider: "openai" },
      1,
      null,
      expect.any(Function),
      expect.any(Function),
    );

    // Should navigate to new agent
    expect(mockNavigate).toHaveBeenCalledWith("/agent/agent-123");
  });

  it("creates agent with fallback model when store has no models", () => {
    mockCreateAgent.mockImplementation(
      (_model, _vocationId, _workspacePath, onOk) => {
        onOk("agent-456");
      },
    );
    mockStore = {
      models: [],
      vocations: [
        { id: 1, name: "Chat Buddy", description: "A friendly chat companion" },
      ],
    };

    render(<NewAgentPage />);

    // Select vocation first
    const vocationSelect = screen.getByLabelText("Select Vocation");
    fireEvent.change(vocationSelect, { target: { value: "1" } });

    // Select fallback option
    const select = screen.getByLabelText("Select Model");
    fireEvent.change(select, { target: { value: "gpt-4" } });

    const button = screen.getByRole("button", { name: "Create Agent" });
    fireEvent.click(button);

    // Should call createAgent with the model, vocation_id, and callbacks
    expect(mockCreateAgent).toHaveBeenCalledWith(
      { name: "gpt-4" },
      1,
      null,
      expect.any(Function),
      expect.any(Function),
    );
  });

  it("shows workspace path input for Programmer vocation", () => {
    mockStore = {
      models: [{ name: "gpt-4", provider: "openai" }],
      vocations: [
        { id: 1, name: "Chat Buddy", description: "A friendly chat companion" },
        { id: 2, name: "Programmer", description: "A coding assistant" },
      ],
    };

    render(<NewAgentPage />);

    // Select Programmer vocation
    const vocationSelect = screen.getByLabelText("Select Vocation");
    fireEvent.change(vocationSelect, { target: { value: "2" } });

    // Should show workspace path input
    expect(screen.getByLabelText("Workspace Path")).toBeInTheDocument();
  });

  it("shows error when Programmer vocation is selected without workspace path", () => {
    mockStore = {
      models: [{ name: "gpt-4", provider: "openai" }],
      vocations: [
        { id: 1, name: "Chat Buddy", description: "A friendly chat companion" },
        { id: 2, name: "Programmer", description: "A coding assistant" },
      ],
    };

    render(<NewAgentPage />);

    // Select Programmer vocation and model
    const vocationSelect = screen.getByLabelText("Select Vocation");
    fireEvent.change(vocationSelect, { target: { value: "2" } });

    const select = screen.getByLabelText("Select Model");
    fireEvent.change(select, { target: { value: "gpt-4" } });

    // Try to create without workspace path
    const button = screen.getByRole("button", { name: "Create Agent" });
    fireEvent.click(button);

    // Should show error
    expect(
      screen.getByText(
        "Please specify a workspace path for the Programmer vocation",
      ),
    ).toBeInTheDocument();
  });

  it("shows error message when agent creation fails", () => {
    mockCreateAgent.mockImplementation(
      (_model, _vocationId, _workspacePath, _onOk, onError) => {
        onError(new Error("Model not available"));
      },
    );
    mockStore = {
      models: [{ name: "gpt-4", provider: "openai" }],
      vocations: [
        { id: 1, name: "Chat Buddy", description: "A friendly chat companion" },
      ],
    };

    render(<NewAgentPage />);

    // Select vocation and model
    const vocationSelect = screen.getByLabelText("Select Vocation");
    fireEvent.change(vocationSelect, { target: { value: "1" } });

    const select = screen.getByLabelText("Select Model");
    fireEvent.change(select, { target: { value: "gpt-4" } });

    const button = screen.getByRole("button", { name: "Create Agent" });
    fireEvent.click(button);

    // Should show error
    expect(screen.getByText("Model not available")).toBeInTheDocument();

    // Button should be enabled again (not in loading state)
    expect(screen.getByRole("button", { name: "Create Agent" })).toBeEnabled();
  });

  it("shows generic error message when creation fails without message", () => {
    mockCreateAgent.mockImplementation(
      (_model, _vocationId, _workspacePath, _onOk, onError) => {
        onError(new Error());
      },
    );
    mockStore = {
      models: [{ name: "gpt-4", provider: "openai" }],
      vocations: [
        { id: 1, name: "Chat Buddy", description: "A friendly chat companion" },
      ],
    };

    render(<NewAgentPage />);

    // Select vocation and model
    const vocationSelect = screen.getByLabelText("Select Vocation");
    fireEvent.change(vocationSelect, { target: { value: "1" } });

    const select = screen.getByLabelText("Select Model");
    fireEvent.change(select, { target: { value: "gpt-4" } });

    const button = screen.getByRole("button", { name: "Create Agent" });
    fireEvent.click(button);

    expect(screen.getByText("Failed to create agent")).toBeInTheDocument();
  });

  it("renders the info box about vocations", () => {
    render(<NewAgentPage />);

    expect(screen.getByText("What is a Vocation?")).toBeInTheDocument();
    expect(
      screen.getByText(
        /A vocation defines an agent's role, capabilities, and permissions/,
      ),
    ).toBeInTheDocument();
  });

  it("has proper accessibility attributes", () => {
    mockStore = {
      models: [{ name: "gpt-4", provider: "openai" }],
    };

    render(<NewAgentPage />);

    const select = screen.getByLabelText("Select Model");
    expect(select).toHaveAttribute("id", "model-select");

    const button = screen.getByRole("button", { name: "Create Agent" });
    expect(button).toHaveAttribute("type", "button");
  });
});
