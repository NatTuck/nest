import { describe, expect, test, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, cleanup } from "@testing-library/react";
import { AgentModelPicker } from "./AgentModelPicker";
import { useStore } from "../store";

const mockModels = [
  { name: "qwen3.5-plus", provider: "model-studio" },
  { name: "claude-3-opus-20240229", provider: "anthropic-provider" },
  { name: "MiniMax-M2.5", provider: "model-studio" },
];

describe("AgentModelPicker", () => {
  beforeEach(() => {
    cleanup();
    useStore.setState({ models: mockModels });
  });

  test("renders nothing when open is false", () => {
    const { container } = render(
      <AgentModelPicker open={false} onClose={() => {}} onSelect={() => {}} />,
    );
    expect(container.firstChild).toBeNull();
  });

  test("renders the model catalog when open", () => {
    render(
      <AgentModelPicker open={true} onClose={() => {}} onSelect={() => {}} />,
    );
    expect(screen.getByText("qwen3.5-plus")).toBeDefined();
    expect(screen.getByText("claude-3-opus-20240229")).toBeDefined();
    expect(screen.getByText("MiniMax-M2.5")).toBeDefined();
  });

  test("filters the model list by the search input", () => {
    render(
      <AgentModelPicker open={true} onClose={() => {}} onSelect={() => {}} />,
    );
    fireEvent.input(screen.getByPlaceholderText("Filter models…"), {
      target: { value: "claude" },
    });
    expect(screen.getByText("claude-3-opus-20240229")).toBeDefined();
    expect(screen.queryByText("qwen3.5-plus")).toBeNull();
    expect(screen.queryByText("MiniMax-M2.5")).toBeNull();
  });

  test("calls onSelect with the chosen model map on click", () => {
    const onSelect = vi.fn();
    render(
      <AgentModelPicker open={true} onClose={() => {}} onSelect={onSelect} />,
    );
    fireEvent.click(screen.getByText("claude-3-opus-20240229"));
    expect(onSelect).toHaveBeenCalledWith({
      name: "claude-3-opus-20240229",
      provider: "anthropic-provider",
    });
  });

  test("calls onClose when the close button is clicked", () => {
    const onClose = vi.fn();
    render(
      <AgentModelPicker open={true} onClose={onClose} onSelect={() => {}} />,
    );
    fireEvent.click(screen.getByLabelText("Close"));
    expect(onClose).toHaveBeenCalled();
  });
});
