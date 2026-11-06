defmodule NestWeb.LobbyChannel.SaveProvidersSerialTest do
  @moduledoc """
  A test that pushes `save_providers` must run `async: false`.

  `Providers.save/2` broadcasts `providers_updated` on the **process-global**
  `"lobby"` topic, and `Phoenix.ChannelTest` delivers every frame on a topic a
  test joined to that test's process. So a test pushing `save_providers` while
  another test is joined to `"lobby"` can hand it that frame, and
  `assert_push "providers_updated"` takes the *first* frame it is given — which
  was `mix test --seed 805575`'s two failures.

  Three modules carry that risk today and are `async: false`. This is what stops
  a fourth from reintroducing it silently: the rule is enforced rather than
  remembered.
  """

  use ExUnit.Case, async: true

  alias Nest.Test.SourceScan

  # The *channel push*, not `Writer.save_providers/2`: that writes the file and
  # does not broadcast, so the `dot_config/*` tests that call it stay async.
  @push ~r/push\(\w+, "save_providers"/

  @known_pushers [
    "test/nest_web/channels/lobby_channel/providers_save_failure_test.exs",
    "test/nest_web/channels/lobby_channel/providers_test.exs",
    "test/nest_web/channels/lobby_channel/providers_write_only_test.exs"
  ]

  test "every test that pushes save_providers runs async: false" do
    root = Path.expand("../../../..", __DIR__)

    pushers =
      root
      |> Path.join("test/**/*.exs")
      |> Path.wildcard()
      |> SourceScan.flat_map(fn file ->
        source = File.read!(file)

        if Regex.match?(@push, source),
          do: [{Path.relative_to(file, root), source}],
          else: []
      end)

    # A scan that matched nothing would pass the assertion below vacuously, so
    # the modules this rule was written for have to be among what it found.
    found = MapSet.new(pushers, &elem(&1, 0))
    assert MapSet.subset?(MapSet.new(@known_pushers), found)

    offenders = for {path, source} <- pushers, not async_false?(source), do: path

    assert offenders == [],
           "these tests push `save_providers`, which broadcasts on the global " <>
             "\"lobby\" topic, so they must run `async: false`: #{inspect(offenders)}"
  end

  # The module's own `use`, which is where `async: false` lives. A file with no
  # `use` line at all cannot be a test module.
  defp async_false?(source), do: Regex.match?(~r/use\s+[\w.]+\s*,\s*async:\s*false/, source)
end
