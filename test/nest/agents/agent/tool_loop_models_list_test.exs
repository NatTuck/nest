defmodule Nest.Agents.Agent.ToolLoopModelsListTest do
  @moduledoc """
  Tests for the `models-list` sub-agent tool execution in
  `Nest.Agents.Agent.ToolLoop`.

  `ToolLoop` runs `models-list` inline (no GenServer round-trip):
  it lists the models from providers configured with
  `expose-models = true` (optionally filtered by `provider`) and
  formats each as a `"provider/model-name"` line, ready to feed to
  `agents-spawn`'s `model` argument, followed by the fields that
  decide whether it is the *right* model — `input:` (the input
  modalities the model claims), `ctx:` (its context limit) and
  `tags:` (the provider's tags) — each present only when known.

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

  # A provider spec is `expose_models`, or `{expose_models, tags}` when the
  # test needs the provider to carry tags.
  defp stub_config(provider_specs) do
    providers =
      Map.new(provider_specs, fn
        {name, {expose, tags}} ->
          {name, %Provider{name: name, expose_models: expose, tags: tags}}

        {name, expose} ->
          {name, %Provider{name: name, expose_models: expose, tags: []}}
      end)

    Mimic.stub(DotConfig, :load, fn -> {:ok, %{providers: providers}} end)
  end

  # A `Models.list/0` entry, plus whatever metadata the test wants on it.
  defp entry(name, provider, extra \\ %{}),
    do: Map.merge(%{"name" => name, "provider" => provider}, extra)

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

    test "renders the fields a model and its provider do claim, and omits the rest" do
      stub_config(%{"alpha" => {true, ["local", "vision"]}, "beta" => true})

      stub_models([
        entry("kraken-flash", "alpha", %{
          "multi_modal" => %{"input" => ["image"]},
          "context_limit" => 262_144
        }),
        entry("plain", "beta")
      ])

      lines = run_models_list(%{}) |> String.split("\n")

      assert Enum.at(lines, 0) ==
               "alpha/kraken-flash  input: image  ctx: 262144  tags: local,vision"

      # No `multi_modal` key, no `context_limit`, and a provider with no
      # tags: the line stays exactly what it was before this feature.
      assert Enum.at(lines, 1) == "beta/plain"
    end

    test "distinguishes a claimed modality, an explicit negative, and no claim at all" do
      stub_config(%{"alpha" => true})

      stub_models([
        entry("audio-only", "alpha", %{"multi_modal" => %{"input" => ["audio"]}}),
        entry("claims-no-modalities", "alpha", %{"multi_modal" => %{"input" => []}}),
        entry("says-nothing", "alpha")
      ])

      content = run_models_list(%{})

      # A vocabulary that is not `image` is rendered as it stands rather
      # than reported as no claim.
      assert content =~ "alpha/audio-only  input: audio"

      # An empty modality list is a claim — of no input modalities at all
      # — so it is shown. `false` is deliberately not a case here: it is
      # not a state that can occur, because `parse_model/1` coerces a
      # non-map `multi-modal` to `nil` (that is #82).
      assert content =~ "alpha/claims-no-modalities  input: none"

      # Silence is not a negative: the model may still accept images, so
      # it gets no `input:` field rather than a misleading `input: none`.
      refute content =~ "says-nothing  input:"
    end

    test "does not crash on a modality or tag list it cannot join" do
      stub_config(%{"alpha" => {true, [%{"a" => 1}]}})

      stub_models([
        entry("bad-modalities", "alpha", %{"multi_modal" => %{"input" => [%{"a" => 1}]}}),
        entry("mixed-modalities", "alpha", %{"multi_modal" => %{"input" => ["image", 7]}})
      ])

      content = run_models_list(%{})

      assert content =~ "alpha/bad-modalities"
      assert content =~ "alpha/mixed-modalities"

      # `Enum.join/2` raises on a non-binary element, and both lists reach
      # us unvalidated from TOML, so each falls through to no claim rather
      # than killing the tool call.
      refute content =~ "bad-modalities  input:"
      refute content =~ "mixed-modalities  input:"
      refute content =~ "tags:"
    end

    test "reports nothing listed when the config cannot be loaded" do
      Mimic.stub(DotConfig, :load, fn -> {:error, :enoent} end)
      stub_models([@alpha])

      # The existing fallback: an unreadable config yields no exposed
      # providers, so the listing reports none.
      assert run_models_list(%{}) =~ "no configured provider has expose-models enabled"
    end

    test "tolerates a multi_modal shape it does not recognize" do
      stub_config(%{"alpha" => true})
      stub_models([entry("odd-shape", "alpha", %{"multi_modal" => %{"image" => true}})])

      content = run_models_list(%{})

      # `multi_modal` is an unvalidated pass-through map, so an
      # unrecognized shape must not raise and must not be read as a
      # claim of `image` input.
      assert content =~ "alpha/odd-shape"
      refute content =~ "odd-shape  input: image"
    end
  end
end
