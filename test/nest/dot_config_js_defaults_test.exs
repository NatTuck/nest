defmodule Nest.DotConfigJsDefaultsTest do
  @moduledoc """
  The Providers editor's placeholder numbers are the server's defaults.

  `assets/js/components/providerConstants.js` cannot read `Nest.DotConfig` — the
  browser has no config file — so the two silence bounds are written down
  twice. This pins the copy: changing a default in `lib/nest/dot_config.ex`
  without the editor's placeholder fails here, instead of leaving the GUI
  telling an operator that leaving a field blank means the old number.

  The file is read directly rather than through `Nest.Test.SourceScan`, which
  exists to spread a tree-wide credo scan over the schedulers; this is one
  file, and the assertion is about its text.
  """
  use ExUnit.Case, async: true

  alias Nest.DotConfig

  @constants Path.join(["assets", "js", "components", "providerConstants.js"])

  test "the editor's placeholder defaults match DotConfig's" do
    source = File.read!(Path.join(File.cwd!(), @constants))

    assert source =~
             "DEFAULT_FIRST_BYTE_TIMEOUT_SECONDS = " <>
               "#{DotConfig.default_first_byte_timeout_seconds()};"

    assert source =~
             "DEFAULT_STREAM_IDLE_TIMEOUT_SECONDS = " <>
               "#{DotConfig.default_stream_idle_timeout_seconds()};"
  end
end
