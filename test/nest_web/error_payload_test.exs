defmodule NestWeb.ErrorPayloadTest do
  @moduledoc """
  Pins `NestWeb.ErrorPayload.from_reason/1`, the one mapper every channel
  `{:error, reason}` reply goes through.

  It exists because `to_string/1` is not total: a reason carrying a detail term
  raised `Protocol.UndefinedError` inside a channel handler, which killed the
  socket and left the client with no reply at all. Every clause here is one of
  the shapes a `handle_in/3` can actually be handed.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias NestWeb.ErrorPayload

  test "carries the path of a config file Nest cannot protect" do
    # The path is the whole point: the user has to know which file to replace,
    # and the browser renders it (`describeConfigFileError`).
    assert %{"reason" => "config_file_not_regular", "path" => "/ws/AGENTS.md"} =
             ErrorPayload.from_reason({:config_file_not_regular, "/ws/AGENTS.md"})
  end

  test "passes a wire code through and stringifies a bare reason" do
    # A caller that already has the code keeps its spelling — `:not_found` is
    # `"agent_not_found"` on the agent channel, and a binary is that spelling.
    assert ErrorPayload.from_reason("agent_not_found") == %{"reason" => "agent_not_found"}
    assert ErrorPayload.from_reason(:agent_busy) == %{"reason" => "agent_busy"}
  end

  test "answers a tagged reason it has no clause for with the tag, and logs the detail" do
    # Losing the detail is worse than a crash; keeping it in a key nothing reads
    # is worse than losing it. So it goes to the log, where the operator is.
    log =
      capture_log(fn ->
        assert ErrorPayload.from_reason({:some_new_refusal, "detail"}) ==
                 %{"reason" => "some_new_refusal"}
      end)

    assert log =~ "Unmapped error reason :some_new_refusal"
    assert log =~ "detail"
  end

  test "answers a reason of no known shape with a code rather than raising" do
    # An `Ecto.Changeset` is the shape that makes the catch-all load-bearing: it
    # is neither `to_string/1`-able nor fit to show a user.
    changeset = %Ecto.Changeset{errors: [name: {"can't be blank", []}]}

    log =
      capture_log(fn ->
        assert ErrorPayload.from_reason(changeset) == %{"reason" => "unknown_error"}
      end)

    assert log =~ "Unmapped error reason"
    assert log =~ "can't be blank"
  end
end
