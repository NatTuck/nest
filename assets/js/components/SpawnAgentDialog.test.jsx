/**
 * SpawnAgentDialog tests (#209): the manual spawn form.
 *
 * The contract with the server is the payload, so that is what most of these
 * assert: `space_id` always, and `name`, `vocation`, `model` only when the
 * operator chose them — an omitted field means "you decide", which is not the
 * same as an empty one. The rest is the dialog's own behaviour: an error reply
 * stays on screen with the dialog open, a success closes it and reports the name
 * the server sent, and a second click while the push is in flight is not a second
 * agent.
 *
 * The store is the real one (`vocations` and `models` are what the lobby's `init`
 * fills), and the transport is mocked so the push can be inspected.
 */

import { describe, it, expect, beforeEach, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";

import { SpawnAgentDialog } from "./SpawnAgentDialog";
import { spawnAgent } from "../channels";
import { useStore } from "../store";

vi.mock("../channels", () => ({
  spawnAgent: vi.fn(),
}));

const SPACE_ID = 7;

const VOCATIONS = [
  { id: 1, slug: "programmer", name: "Programmer" },
  { id: 2, slug: "researcher", name: "Researcher" },
];

const MODELS = [
  { name: "qwen3.5-plus", provider: "model-studio" },
  { name: "gpt-4", provider: "openai" },
];

const BLUEPRINT = { id: 10, name: "Coding", root_vocation: "researcher" };

function renderDialog(overrides = {}) {
  const props = {
    open: true,
    onClose: vi.fn(),
    spaceId: SPACE_ID,
    blueprint: BLUEPRINT,
    onSpawned: vi.fn(),
    ...overrides,
  };
  return { ...render(<SpawnAgentDialog {...props} />), props };
}

const submit = () =>
  fireEvent.click(screen.getByRole("button", { name: /spawn/i }));

beforeEach(() => {
  vi.clearAllMocks();
  useStore.getState()._reset();
  useStore.setState({ vocations: VOCATIONS, models: MODELS });
});

describe("SpawnAgentDialog", () => {
  it("renders the name, vocation and model fields", () => {
    renderDialog();

    expect(screen.getByLabelText(/name/i)).toHaveAttribute(
      "placeholder",
      "Leave blank to generate one",
    );

    // The vocation list is the store's, and the blueprint's root vocation is the
    // default: the agent being spawned by hand is usually the same kind as the
    // space's root.
    expect(screen.getByLabelText(/vocation/i)).toHaveValue("researcher");
    expect(
      screen.getByRole("option", { name: "Programmer" }),
    ).toBeInTheDocument();

    // The model list is the same one `EditAgentDialog` offers, and empty is a
    // real choice: it means the server's default.
    const model = screen.getByLabelText(/model/i);
    expect(model).toHaveValue("");
    expect(
      screen.getByRole("option", { name: "qwen3.5-plus (model-studio)" }),
    ).toBeInTheDocument();
  });

  it("omits a blank name and an unchosen model from the push", () => {
    renderDialog();

    submit();

    // Omitted, not empty: a blank name means "generate one", and no model means
    // the server's default. Sending `""` or a half-built model map would be a
    // different request.
    expect(spawnAgent).toHaveBeenCalledWith(
      { space_id: SPACE_ID, vocation: "researcher" },
      expect.any(Function),
      expect.any(Function),
    );
  });

  it("sends the chosen name, vocation and model", () => {
    renderDialog();

    fireEvent.change(screen.getByLabelText(/name/i), {
      target: { value: "  helper  " },
    });
    fireEvent.change(screen.getByLabelText(/vocation/i), {
      target: { value: "programmer" },
    });
    fireEvent.change(screen.getByLabelText(/model/i), {
      target: { value: "qwen3.5-plus" },
    });

    submit();

    expect(spawnAgent).toHaveBeenCalledWith(
      {
        space_id: SPACE_ID,
        // Trimmed: a name with spaces around it is the same name.
        name: "helper",
        vocation: "programmer",
        model: {
          name: "qwen3.5-plus",
          provider: "model-studio",
          // The form has no thinking control, so this is the application's
          // default (the level the new-space form starts at).
          thinking_level: "medium",
        },
      },
      expect.any(Function),
      expect.any(Function),
    );
  });

  it("shows the error reply and stays open", () => {
    spawnAgent.mockImplementation((_payload, _onOk, onError) => {
      onError({ reason: "invalid_vocation", message: "No such vocation" });
    });

    const { props } = renderDialog();
    submit();

    expect(screen.getByRole("alert")).toHaveTextContent("No such vocation");
    // Still open: the operator fixes the field rather than losing what they typed.
    expect(
      screen.getByRole("dialog", { name: "Spawn agent" }),
    ).toBeInTheDocument();
    expect(props.onClose).not.toHaveBeenCalled();
  });

  it("falls back to the reply's reason when it carries no message", () => {
    spawnAgent.mockImplementation((_payload, _onOk, onError) => {
      onError({ reason: "space_archived" });
    });

    renderDialog();
    submit();

    expect(screen.getByRole("alert")).toHaveTextContent("space_archived");
  });

  it("closes on success and reports the name the server sent", () => {
    spawnAgent.mockImplementation((_payload, onOk) => {
      onOk({ name: "helper" });
    });

    const { props } = renderDialog();
    submit();

    expect(props.onSpawned).toHaveBeenCalledWith("helper");
    expect(props.onClose).toHaveBeenCalledTimes(1);
  });

  it("reports a reply that carries no name rather than claiming one", () => {
    spawnAgent.mockImplementation((_payload, onOk) => {
      onOk({});
    });

    const { props } = renderDialog();
    submit();

    // The page renders that as "the reply carried no name", so the missing fact
    // is visible instead of a silent success.
    expect(props.onSpawned).toHaveBeenCalledWith(null);
  });

  it("does not spawn twice while the first push is in flight", () => {
    // No reply: the push is still in flight, which is exactly when a second click
    // would be a second agent.
    spawnAgent.mockImplementation(() => {});

    renderDialog();
    submit();
    submit();

    expect(spawnAgent).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: /spawning/i })).toBeDisabled();
  });
});
