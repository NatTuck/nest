/**
 * Tests for ProviderEditor + ProviderModelRow.
 *
 * Covers:
 *  - Rendering the provider's fields and nested models.
 *  - Field edits propagating upward via `onChange`.
 *  - Adding and removing models.
 *  - Deleting the provider via `onRemove`.
 *  - Auto-discover / auto-probe toggles.
 */

import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";

import { ProviderEditor } from "./ProviderEditor";
import { ProviderModelRow } from "./ProviderModelRow";

const provider = {
  id: "prov-1",
  name: "acme",
  base_url: "https://acme.example/v1",
  api_key: "secret",
  protocol: "openai",
  auto_models: false,
  tags: [],
  timeout_seconds: 300,
  default_context_limit: 200000,
  default_thinking_effort: "high",
  probe_base_url: "https://probe.example/v1",
  auto_probe: true,
  models: [
    {
      id: "model-1",
      name: "acme-1",
      context_limit: 128000,
      thinking_effort: "off",
      multi_modal: null,
    },
    {
      id: "model-2",
      name: "acme-2",
      context_limit: null,
      thinking_effort: null,
      multi_modal: null,
    },
  ],
};

describe("ProviderEditor", () => {
  it("renders the provider fields and models", () => {
    render(
      <ProviderEditor
        provider={provider}
        onChange={() => {}}
        onRemove={() => {}}
      />,
    );

    expect(screen.getByLabelText(/provider name/i)).toHaveValue("acme");
    expect(screen.getByLabelText("Base URL")).toHaveValue(
      "https://acme.example/v1",
    );
    expect(screen.getByLabelText(/api key/i)).toHaveValue("secret");
    expect(screen.getByLabelText(/default context limit/i)).toHaveValue(200000);
    expect(screen.getByLabelText(/default thinking effort/i)).toHaveValue(
      "high",
    );
    expect(screen.getAllByLabelText(/model name/i)).toHaveLength(2);
  });

  it("propagates a name edit via onChange", () => {
    const onChange = vi.fn();
    render(
      <ProviderEditor
        provider={provider}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.change(screen.getByLabelText(/provider name/i), {
      target: { value: "renamed" },
    });

    expect(onChange).toHaveBeenCalledWith({ ...provider, name: "renamed" });
  });

  it("propagates a model edit via onChange", () => {
    const onChange = vi.fn();
    render(
      <ProviderEditor
        provider={provider}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.change(screen.getAllByLabelText(/model name/i)[0], {
      target: { value: "acme-1b" },
    });

    const [updated] = onChange.mock.calls[0];
    expect(updated.models[0].name).toBe("acme-1b");
  });

  it("adds an empty model when Add model is clicked", () => {
    const onChange = vi.fn();
    render(
      <ProviderEditor
        provider={provider}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /add model/i }));

    const [updated] = onChange.mock.calls[0];
    expect(updated.models).toHaveLength(3);
    expect(updated.models[2].name).toBe("");
  });

  it("removes a model when its delete button is clicked", () => {
    const onChange = vi.fn();
    render(
      <ProviderEditor
        provider={provider}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.click(
      screen.getByRole("button", { name: /remove model acme-1/i }),
    );

    const [updated] = onChange.mock.calls[0];
    expect(updated.models.map((m) => m.name)).toEqual(["acme-2"]);
  });

  it("calls onRemove when the provider delete button is clicked", () => {
    const onRemove = vi.fn();
    render(
      <ProviderEditor
        provider={provider}
        onChange={() => {}}
        onRemove={onRemove}
      />,
    );

    fireEvent.click(
      screen.getByRole("button", { name: /delete provider acme/i }),
    );

    expect(onRemove).toHaveBeenCalledTimes(1);
  });

  it("toggles auto-discover models", () => {
    const onChange = vi.fn();
    render(
      <ProviderEditor
        provider={provider}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.click(screen.getByLabelText(/auto-discover models/i));

    const [updated] = onChange.mock.calls[0];
    expect(updated.auto_models).toBe(true);
  });

  it("toggles auto-probe off", () => {
    const onChange = vi.fn();
    render(
      <ProviderEditor
        provider={provider}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.click(screen.getByLabelText(/auto-probe endpoint/i));

    const [updated] = onChange.mock.calls[0];
    expect(updated.auto_probe).toBe(false);
  });

  it("clears default context limit when the input is emptied", () => {
    const onChange = vi.fn();
    render(
      <ProviderEditor
        provider={provider}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.change(screen.getByLabelText(/default context limit/i), {
      target: { value: "" },
    });

    const [updated] = onChange.mock.calls[0];
    expect(updated.default_context_limit).toBe(null);
  });

  it("clears probe base url when the input is emptied", () => {
    const onChange = vi.fn();
    render(
      <ProviderEditor
        provider={provider}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.change(screen.getByLabelText(/probe base url/i), {
      target: { value: "" },
    });

    const [updated] = onChange.mock.calls[0];
    expect(updated.probe_base_url).toBe(null);
  });

  it("shows an empty-models hint and adds a model to a provider without models", () => {
    const onChange = vi.fn();
    const bare = { ...provider, models: undefined };

    render(
      <ProviderEditor
        provider={bare}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    expect(screen.getByText(/no models configured/i)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /add model/i }));

    const [updated] = onChange.mock.calls[0];
    expect(updated.models).toHaveLength(1);
    expect(updated.models[0]).toEqual({
      id: expect.any(String),
      name: "",
      context_limit: null,
      multi_modal: null,
      thinking_effort: null,
    });
  });

  it("renders an empty provider with defaults", () => {
    render(
      <ProviderEditor provider={{}} onChange={() => {}} onRemove={() => {}} />,
    );

    expect(screen.getByLabelText(/provider name/i)).toHaveValue("");
    expect(screen.getByLabelText("Base URL")).toHaveValue("");
    expect(screen.getByLabelText(/api key/i)).toHaveValue("");
    expect(screen.getByLabelText(/protocol/i)).toHaveValue("openai");
    expect(screen.getByLabelText(/auto-probe endpoint/i)).toBeChecked();
    expect(screen.getByText(/no models configured/i)).toBeInTheDocument();
  });

  it("changes default context limit to a number", () => {
    const onChange = vi.fn();
    render(
      <ProviderEditor
        provider={provider}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.change(screen.getByLabelText(/default context limit/i), {
      target: { value: "123" },
    });

    const [updated] = onChange.mock.calls[0];
    expect(updated.default_context_limit).toBe(123);
  });

  it("selects and clears the default thinking effort", () => {
    const onChange = vi.fn();
    render(
      <ProviderEditor
        provider={provider}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    const effort = screen.getByLabelText(/default thinking effort/i);
    fireEvent.change(effort, { target: { value: "low" } });
    expect(onChange.mock.calls[0][0].default_thinking_effort).toBe("low");

    fireEvent.change(effort, { target: { value: "" } });
    expect(onChange.mock.calls[1][0].default_thinking_effort).toBe(null);
  });

  it("renders a model without a name", () => {
    const bare = { ...provider, models: [{ context_limit: 1000 }] };
    render(
      <ProviderEditor
        provider={bare}
        onChange={() => {}}
        onRemove={() => {}}
      />,
    );

    expect(screen.getAllByLabelText(/model name/i)).toHaveLength(1);
    expect(screen.getByLabelText(/model name/i)).toHaveValue("");
  });
});

describe("ProviderModelRow", () => {
  it("renders the model fields", () => {
    const model = {
      name: "m1",
      context_limit: 1000,
      thinking_effort: "medium",
      multi_modal: null,
    };
    render(
      <ProviderModelRow
        model={model}
        onChange={() => {}}
        onRemove={() => {}}
      />,
    );

    expect(screen.getByLabelText(/model name/i)).toHaveValue("m1");
    expect(screen.getByLabelText(/model context limit/i)).toHaveValue(1000);
    expect(screen.getByLabelText(/model thinking effort/i)).toHaveValue(
      "medium",
    );
  });

  it("propagates a name edit via onChange", () => {
    const onChange = vi.fn();
    const model = {
      name: "m1",
      context_limit: null,
      thinking_effort: null,
      multi_modal: null,
    };
    render(
      <ProviderModelRow
        model={model}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.change(screen.getByLabelText(/model name/i), {
      target: { value: "m2" },
    });

    expect(onChange).toHaveBeenCalledWith({ ...model, name: "m2" });
  });

  it("calls onRemove when the remove button is clicked", () => {
    const onRemove = vi.fn();
    const model = {
      name: "m1",
      context_limit: null,
      thinking_effort: null,
      multi_modal: null,
    };
    render(
      <ProviderModelRow
        model={model}
        onChange={() => {}}
        onRemove={onRemove}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /remove model m1/i }));

    expect(onRemove).toHaveBeenCalledTimes(1);
  });

  it("renders gracefully with undefined optional fields", () => {
    const model = {};
    render(
      <ProviderModelRow
        model={model}
        onChange={() => {}}
        onRemove={() => {}}
      />,
    );

    expect(screen.getByLabelText(/model name/i)).toHaveValue("");
    expect(screen.getByLabelText(/model context limit/i)).toHaveValue(null);
    expect(screen.getByLabelText(/model thinking effort/i)).toHaveValue("");
  });

  it("clears context limit when the input is emptied", () => {
    const onChange = vi.fn();
    const model = { name: "m1", context_limit: 1000, thinking_effort: "high" };
    render(
      <ProviderModelRow
        model={model}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.change(screen.getByLabelText(/model context limit/i), {
      target: { value: "" },
    });

    expect(onChange).toHaveBeenCalledWith({ ...model, context_limit: null });
  });

  it("changes context limit to a number", () => {
    const onChange = vi.fn();
    const model = { name: "m1", context_limit: null, thinking_effort: null };
    render(
      <ProviderModelRow
        model={model}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.change(screen.getByLabelText(/model context limit/i), {
      target: { value: "256" },
    });

    expect(onChange).toHaveBeenCalledWith({ ...model, context_limit: 256 });
  });

  it("clears thinking effort when the select is reset to default", () => {
    const onChange = vi.fn();
    const model = { name: "m1", context_limit: null, thinking_effort: "high" };
    render(
      <ProviderModelRow
        model={model}
        onChange={onChange}
        onRemove={() => {}}
      />,
    );

    fireEvent.change(screen.getByLabelText(/model thinking effort/i), {
      target: { value: "" },
    });

    expect(onChange).toHaveBeenCalledWith({ ...model, thinking_effort: null });
  });
});
