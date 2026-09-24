defmodule NestWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a channel connection.

  Such tests rely on `Phoenix.ChannelTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import NestWeb.ChannelCase

      # Replace ExUnit's bare `test` with one that stops every agent the
      # test started, in-process, before the test (the sandbox owner)
      # exits. See `Nest.TestSupport.AgentTestMacro`.
      import ExUnit.Case, only: [describe: 2]
      import Nest.TestSupport.AgentTestMacro, only: [test: 1, test: 2, test: 3]

      # The default endpoint for testing
      @endpoint NestWeb.Endpoint
    end
  end

  setup tags do
    Nest.DataCase.setup_sandbox(tags)
    :ok
  end
end
