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

  test "carries the path and the type of a config file Nest cannot protect" do
    # Both are the point: the user has to know which file to replace, and the
    # wording depends on the type — a hardlink *is* a regular file, and its remedy
    # is different. `describeConfigFileError` in the browser renders both.
    assert %{
             "reason" => "config_file_not_regular",
             "path" => "/ws/AGENTS.md",
             "type" => "hardlink"
           } = ErrorPayload.from_reason({:config_file_not_regular, "/ws/AGENTS.md", :hardlink})

    assert %{"type" => "symlink"} =
             ErrorPayload.from_reason({:config_file_not_regular, "/ws/.nest", :symlink})
  end

  test "passes a wire code through and stringifies a bare reason" do
    # A caller that already has the code keeps its spelling — `:not_found` is
    # `"agent_not_found"` on the agent channel, and a binary is that spelling.
    assert ErrorPayload.from_reason("agent_not_found") == %{"reason" => "agent_not_found"}
    assert ErrorPayload.from_reason(:agent_busy) == %{"reason" => "agent_busy"}
  end

  test "answers a tagged reason of any arity with the tag, and logs the detail" do
    # Losing the detail is worse than a crash; keeping it in a key nothing reads
    # is worse than losing it, so it goes to the log. Any arity, not just two: a
    # reason that grows a field (`{:config_file_not_regular, path, type}` did) must
    # not fall silently to the catch-all's `"unknown_error"`.
    log =
      capture_log(fn ->
        for {reason, tag} <- [
              {{:some_new_refusal, "detail"}, "some_new_refusal"},
              {{:a_new_reason, "one", :two}, "a_new_reason"}
            ] do
          assert ErrorPayload.from_reason(reason) == %{"reason" => tag}
        end
      end)

    assert log =~ "Unmapped error reason :some_new_refusal"
    assert log =~ "detail"
    assert log =~ "Unmapped error reason :a_new_reason"
    assert log =~ ~s(["one", :two])
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
