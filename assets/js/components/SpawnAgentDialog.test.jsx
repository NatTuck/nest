/**
 * SpawnAgentDialog tests (#209): the manual spawn form.
 *
 * The contract with the server is the payload, so that is what most of these
 * assert: `space_id` and `model` always, `name` and `vocation` only when the
 * operator chose them — an omitted field means "you decide", which is not the
 * same as an empty one. A model is not optional: an agent with none starts
 * blocked, so the button will not submit without one. The rest is the dialog's
 * own behaviour: an error reply
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

// A model is required, so every test that means to submit picks one first.
const chooseModel = () =>
  fireEvent.change(screen.getByLabelText(/model/i), {
    target: { value: "qwen3.5-plus" },
  });

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

    // The model list is the same one `EditAgentDialog` offers, and empty is only
    // the placeholder: the dialog will not submit without a choice.
    const model = screen.getByLabelText(/model/i);
    expect(model).toHaveValue("");
    expect(
      screen.getByRole("option", { name: "qwen3.5-plus (model-studio)" }),
    ).toBeInTheDocument();

    // The thinking level is sent to the model on every spawn, and the form has
    // no control for it — so it is named on screen rather than implied.
    expect(screen.getByText(/Thinking level: medium/)).toBeInTheDocument();
  });

  it("will not submit without a model, and says why", () => {
    renderDialog();

    // An agent created without a model starts blocked on `:model_missing`, so
    // this is a refusal rather than a default the server picks.
    expect(screen.getByRole("button", { name: /spawn/i })).toBeDisabled();
    expect(
      screen.getByText("A model is required — an agent with none cannot run."),
    ).toBeInTheDocument();

    submit();
    expect(spawnAgent).not.toHaveBeenCalled();
  });

  it("omits a blank name from the push, and always sends the model", () => {
    renderDialog();

    fireEvent.change(screen.getByLabelText(/model/i), {
      target: { value: "qwen3.5-plus" },
    });
    submit();

    // Omitted, not empty: a blank name means "generate one". The model is
    // always there, because the button cannot be pressed without it.
    expect(spawnAgent).toHaveBeenCalledWith(
      {
        space_id: SPACE_ID,
        vocation: "researcher",
        model: {
          name: "qwen3.5-plus",
          provider: "model-studio",
          thinking_level: "medium",
        },
      },
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
    chooseModel();
    submit();

    expect(screen.getByRole("alert")).toHaveTextContent("No such vocation");
    // Still open: the operator fixes the field rather than losing what they typed.
    expect(
      screen.getByRole("dialog", { name: "Spawn agent" }),
    ).toBeInTheDocument();
    expect(props.onClose).not.toHaveBeenCalled();
  });

  it("words the refusals the server sends as codes, using the detail when there is one", () => {
    // A `"none"`-backend collision is the refusal a manual spawn can really hit,
    // and the payload's `space_name` is what lets the operator act on it: the
    // raw code alone would be useless.
    spawnAgent.mockImplementation((_payload, _onOk, onError) => {
      onError({ reason: "scratch_name_in_use", space_name: "other-space" });
    });

    renderDialog();
    chooseModel();
    submit();

    expect(screen.getByRole("alert")).toHaveTextContent(
      'Space "other-space" already uses that agent name.',
    );

    // And a vocation that does not resolve is worded for an agent, not for a
    // blueprint (which is what the New Space form's describer says).
    spawnAgent.mockImplementation((_payload, _onOk, onError) => {
      onError({ reason: "vocation_not_found" });
    });

    fireEvent.change(screen.getByLabelText(/vocation/i), {
      target: { value: "programmer" },
    });
    submit();

    expect(screen.getByRole("alert")).toHaveTextContent(
      "That agent vocation no longer exists. Pick another one.",
    );

    // An archived space is the refusal a dialog left open can really receive,
    // and its reply carries no message — so the wording is this form's.
    spawnAgent.mockImplementation((_payload, _onOk, onError) => {
      onError({ reason: "space_archived" });
    });
    submit();

    expect(screen.getByRole("alert")).toHaveTextContent(
      "This space is archived. Unarchive it to add an agent.",
    );
  });

  it("falls back to the reply's reason when it carries no message", () => {
    spawnAgent.mockImplementation((_payload, _onOk, onError) => {
      onError({ reason: "failed_to_create" });
    });

    renderDialog();
    chooseModel();
    submit();

    expect(screen.getByRole("alert")).toHaveTextContent("failed_to_create");
  });

  it("closes on success and reports the name the server sent", () => {
    spawnAgent.mockImplementation((_payload, onOk) => {
      onOk({ name: "helper" });
    });

    const { props } = renderDialog();
    chooseModel();
    submit();

    expect(props.onSpawned).toHaveBeenCalledWith("helper");
    expect(props.onClose).toHaveBeenCalledTimes(1);
  });

  it("reports a reply that carries no name rather than claiming one", () => {
    spawnAgent.mockImplementation((_payload, onOk) => {
      onOk({});
    });

    const { props } = renderDialog();
    chooseModel();
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
    chooseModel();
    submit();
    submit();

    expect(spawnAgent).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: /spawning/i })).toBeDisabled();
  });
});
