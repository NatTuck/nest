defmodule Nest.Agents.Agent.ToolLoopModelsListTest do
  @moduledoc """
  Tests for the `models-list` sub-agent tool execution in
  `Nest.Agents.Agent.ToolLoop`.

  `ToolLoop` runs `models-list` inline (no GenServer round-trip):
  it lists the models from providers configured with
  `expose-models = true` (optionally filtered by `provider`) and
  formats them as `"provider/model-name"` lines, ready to feed to
  `agents-spawn`'s `model` argument.

  `DotConfig.load/0` and `Models.list/0` are stubbed so the
  listing is deterministic.
  """

  use ExUnit.Case, async: true
  use Mimic

  alias Nest.Agents.Agent.ToolLoop
  alias Nest.DotConfig
  alias Nest.DotConfig.Provider
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Models

  setup :verify_on_exit!

  @alpha %{"name" => "qwen3.5-plus", "provider" => "alpha"}
  @nested %{"name" => "Qwen/Qwen3.5-122B-A10B-FP8", "provider" => "alpha"}
  @beta %{"name" => "gpt-4o", "provider" => "beta"}
  @gamma %{"name" => "claude-3-opus-20240229", "provider" => "gamma"}

  defp provider(name, expose_models), do: %Provider{name: name, expose_models: expose_models}

  defp stub_config(provider_specs) do
    Mimic.stub(DotConfig, :load, fn ->
      {:ok,
       %{
         providers:
           Map.new(provider_specs, fn {name, expose} -> {name, provider(name, expose)} end)
       }}
    end)
  end

  defp stub_models(entries) do
    Mimic.stub(Models, :list, fn -> entries end)
  end

  defp run_models_list(arguments) do
    ctx = %{context_limit: 100_000, messages: []}

    [%ToolResult{} = result] =
      ToolLoop.execute(ctx, %{}, [
        %ToolCall{id: "c1", name: "models-list", arguments: arguments}
      ])

    assert result.tool_call_id == "c1"
    assert result.name == "models-list"
    assert result.is_error == false
    result.content
  end

  describe "models-list tool" do
    test "lists models only from providers with expose-models enabled" do
      stub_config(%{"alpha" => true, "beta" => false, "gamma" => true})
      stub_models([@alpha, @nested, @beta, @gamma])

      content = run_models_list(%{})

      assert content =~ "alpha/qwen3.5-plus"
      assert content =~ "alpha/Qwen/Qwen3.5-122B-A10B-FP8"
      assert content =~ "gamma/claude-3-opus-20240229"
      refute content =~ "beta/gpt-4o"
    end

    test "filters by the provider argument" do
      stub_config(%{"alpha" => true, "gamma" => true})
      stub_models([@alpha, @gamma])

      content = run_models_list(%{"provider" => "alpha"})

      assert content =~ "alpha/qwen3.5-plus"
      refute content =~ "gamma/claude-3-opus-20240229"
    end

    test "reports when no provider has expose-models enabled" do
      stub_config(%{"alpha" => false, "beta" => false})
      stub_models([@alpha, @beta])

      content = run_models_list(%{})

      assert content =~ "no configured provider has expose-models enabled"
    end

    test "reports no match when the provider filter matches nothing exposed" do
      stub_config(%{"alpha" => true})
      stub_models([@alpha])

      content = run_models_list(%{"provider" => "beta"})

      assert content == "No models match the request."
    end

    test "keeps model names that themselves contain slashes intact" do
      stub_config(%{"alpha" => true})
      stub_models([@nested])

      content = run_models_list(%{})

      assert content == "alpha/Qwen/Qwen3.5-122B-A10B-FP8"
    end
  end
end
