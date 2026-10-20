defmodule Nest.Agents.Agent.ConfigTest do
  @moduledoc """
  Tests for the `Nest.Agents.Agent.Config` readers over
  `Nest.DotConfig.load/0`: `configured_max_tool_iterations/0`,
  `configured_async_message_max_tokens/0` and
  `resolve_thinking_effort/1`.

  Each reader falls back to a hardcoded default when its key is
  missing or the config can't be loaded. `resolve_thinking_effort/1`
  resolves the per-agent, per-model, per-provider and global
  thinking levels in that order.

  `create_client_config/1`'s threading of the resolved effort onto the
  `ClientConfig` is asserted end-to-end by
  `Nest.Agents.Agent.ModelNoticeTest` ("a thinking-only edit appends
  nothing, and is still a real edit").
  """

  use ExUnit.Case, async: true

  import Mimic

  alias Nest.Agents.Agent

  setup :verify_on_exit!

  test "returns the configured value when DotConfig has one" do
    Mimic.stub(Nest.DotConfig, :load, fn ->
      {:ok, %{providers: %{}, models: %{}, max_tool_iterations: 7}}
    end)

    assert Agent.Config.configured_max_tool_iterations() == 7
  end

  test "returns the hardcoded default of 99 when DotConfig has no max_tool_iterations" do
    Mimic.stub(Nest.DotConfig, :load, fn ->
      {:ok, %{providers: %{}, models: %{}, max_tool_iterations: nil}}
    end)

    assert Agent.Config.configured_max_tool_iterations() == 99
  end

  test "returns the hardcoded default of 99 when DotConfig.load/0 returns an error" do
    Mimic.stub(Nest.DotConfig, :load, fn -> {:error, "no config file"} end)

    assert Agent.Config.configured_max_tool_iterations() == 99
  end

  describe "resolve_thinking_effort/1" do
    # DotConfig.load returns a config whose DotConfig.Model /
    # DotConfig.Provider structs carry per-model and per-provider
    # thinking defaults. The `thinking_effort` fields are already
    # normalized atoms (parsing happens in DotConfig.parse_config).
    defp config_with(model_effort, provider_effort, global_effort) do
      model = %Nest.DotConfig.Model{
        name: "test-model",
        provider_name: "test-provider",
        thinking_effort: model_effort
      }

      provider = %Nest.DotConfig.Provider{
        name: "test-provider",
        default_thinking_effort: provider_effort
      }

      {:ok,
       %{
         models: %{"test-model" => model},
         providers: %{"test-provider" => provider},
         default_thinking_effort: global_effort
       }}
    end

    test "an explicit model-map thinking_level beats config defaults" do
      Mimic.stub(Nest.DotConfig, :load, fn -> config_with(:off, :high, :low) end)

      assert Agent.Config.resolve_thinking_effort(%{
               name: "test-model",
               provider: "test-provider",
               thinking_level: "xhigh"
             }) == :xhigh
    end

    test "per-model thinking-effort beats provider and global defaults" do
      Mimic.stub(Nest.DotConfig, :load, fn -> config_with(:off, :high, :low) end)

      assert Agent.Config.resolve_thinking_effort(%{
               name: "test-model",
               provider: "test-provider"
             }) ==
               :off
    end

    test "provider default beats the global default" do
      Mimic.stub(Nest.DotConfig, :load, fn -> config_with(nil, :high, :low) end)

      assert Agent.Config.resolve_thinking_effort(%{
               name: "test-model",
               provider: "test-provider"
             }) ==
               :high
    end

    test "global default applies when neither model nor provider sets one" do
      Mimic.stub(Nest.DotConfig, :load, fn -> config_with(nil, nil, :low) end)

      assert Agent.Config.resolve_thinking_effort(%{
               name: "test-model",
               provider: "test-provider"
             }) ==
               :low
    end

    test "falls back to :medium when nothing is configured" do
      Mimic.stub(Nest.DotConfig, :load, fn -> config_with(nil, nil, nil) end)

      assert Agent.Config.resolve_thinking_effort(%{
               name: "test-model",
               provider: "test-provider"
             }) ==
               :medium
    end
  end

  describe "configured_async_message_max_tokens/0" do
    test "returns the configured value when DotConfig has one" do
      Mimic.stub(Nest.DotConfig, :load, fn ->
        {:ok, %{providers: %{}, models: %{}, max_async_message_tokens: 1_234}}
      end)

      assert Agent.Config.configured_async_message_max_tokens() == 1_234
    end

    test "returns the hardcoded default of 8000 when unset" do
      Mimic.stub(Nest.DotConfig, :load, fn ->
        {:ok, %{providers: %{}, models: %{}, max_async_message_tokens: nil}}
      end)

      assert Agent.Config.configured_async_message_max_tokens() == 8_000
    end

    test "returns the default when DotConfig.load/0 errors" do
      Mimic.stub(Nest.DotConfig, :load, fn -> {:error, "no config file"} end)

      assert Agent.Config.configured_async_message_max_tokens() == 8_000
    end
  end
end
