defmodule Nest.DotConfigJsDefaultsTest do
  @moduledoc """
  The Providers editor's copies are the server's values.

  `assets/js/components/providerConstants.js` cannot read `Nest.DotConfig` — the
  browser has no config file — so two things are written down twice: the two
  silence bounds, and the protocols a provider may name. This pins both copies:
  changing a default in `lib/nest/dot_config.ex` without the editor's
  placeholder fails here, instead of leaving the GUI telling an operator that
  leaving a field blank means the old number — and adding a protocol on one side
  only fails here, instead of the editor offering a value the config refuses at
  load (or the config accepting one the editor cannot express).

  The file is read directly rather than through `Nest.Test.SourceScan`, which
  exists to spread a tree-wide credo scan over the schedulers; this is one
  file, and the assertion is about its text.
  """
  use ExUnit.Case, async: true

  alias Nest.DotConfig
  alias Nest.DotConfig.FieldValidation

  @constants Path.join(["assets", "js", "components", "providerConstants.js"])

  test "the editor's constants match the server's" do
    source = File.read!(Path.join(File.cwd!(), @constants))

    assert source =~
             "DEFAULT_FIRST_BYTE_TIMEOUT_SECONDS = " <>
               "#{DotConfig.default_first_byte_timeout_seconds()};"

    assert source =~
             "DEFAULT_STREAM_IDLE_TIMEOUT_SECONDS = " <>
               "#{DotConfig.default_stream_idle_timeout_seconds()};"

    # The protocol list, in the editor's own literal form. `FieldValidation`
    # owns the rule both sides call, and `NestWeb.LobbyChannel.Providers` hands
    # a GUI value to it — so a list that differs from the editor's `<select>`
    # means the editor can offer a value the config refuses.
    assert source =~
             "export const PROTOCOLS = " <>
               "[#{Enum.map_join(FieldValidation.protocols(), ", ", &inspect/1)}];"
  end
end
