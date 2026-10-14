defmodule NestWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a channel connection.

  Such tests rely on `Phoenix.ChannelTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  ## Why `subscribe_and_join` is shadowed

  A channel process is not an agent, but it borrows the same SQL-sandbox
  connection: it is started by the test, so it inherits `$callers` from the
  test process, and its `handle_in`/`handle_info` queries run on the test's
  checked-out connection. It also dies *with* the test process (it is started
  under the test's supervisor / linked to it), so a channel that is still
  processing a message when the test body ends is killed mid-query. The
  connection's ownership proxy still has it registered as the client, so when
  the owner's `:DOWN` arrives it disconnects the connection and logs at
  `:error`:

      Postgrex.Protocol (#PID<…>) disconnected: ** (DBConnection.ConnectionError)
      owner #PID<…> exited

  The `subscribe_and_join/2,3,4` wrappers below record each joined channel —
  pid and topic — in the test process, and
  `Nest.TestSupport.ChannelQuiescence.drain/0`, called by the test teardown
  while the sandbox checkout is still alive, lets those channels finish the
  message they were processing. The wrappers are explicit clauses rather than
  defaults so that shadowing the imported functions cannot collide with the
  arities `Phoenix.ChannelTest` derives from its own default argument.

  The record lives in the *calling* process's dictionary, so a channel joined
  from inside a spawned process is not recorded and not drained; see that
  module for what the drain does and does not cover.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Import conveniences for testing with channels. `subscribe_and_join`
      # is shadowed by this module's wrapper (imported on the next line), which
      # records the channel pid for the teardown to drain.
      import Phoenix.ChannelTest,
        except: [subscribe_and_join: 2, subscribe_and_join: 3, subscribe_and_join: 4]

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

  @doc """
  `Phoenix.ChannelTest.subscribe_and_join/2`, recording the joined channel.
  """
  def subscribe_and_join(socket, topic) do
    record(Phoenix.ChannelTest.subscribe_and_join(socket, topic))
  end

  @doc """
  `Phoenix.ChannelTest.subscribe_and_join/3`, recording the joined channel.
  """
  def subscribe_and_join(socket, topic, payload) do
    record(Phoenix.ChannelTest.subscribe_and_join(socket, topic, payload))
  end

  @doc """
  `Phoenix.ChannelTest.subscribe_and_join/4`, recording the joined channel.
  """
  def subscribe_and_join(socket, channel, topic, payload) do
    record(Phoenix.ChannelTest.subscribe_and_join(socket, channel, topic, payload))
  end

  defp record({:ok, reply, socket}) do
    if is_pid(socket.channel_pid) do
      # `{pid, topic}`: the topic is what a give-up log has to name, and it is
      # only reachable here — a channel that will not answer the drain cannot be
      # asked for it. Recorded in the *calling* process, so a channel joined
      # from inside a spawned process is not recorded (see
      # `Nest.TestSupport.ChannelQuiescence`).
      Process.put(
        :nest_joined_channels,
        [{socket.channel_pid, socket.topic} | Process.get(:nest_joined_channels, [])]
      )
    end

    {:ok, reply, socket}
  end

  defp record(other), do: other
end
