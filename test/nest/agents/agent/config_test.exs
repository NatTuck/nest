defmodule Nest.Agents.Agent.ConfigTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Config.configured_max_tool_iterations/0`.

  The function reads the optional `max-tool-iterations` key from
  `Nest.DotConfig.load/0` and falls back to a hardcoded default
  when the key is missing or the config can't be loaded.
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
end
