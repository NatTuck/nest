defmodule Nest.Agents.Agent.SubAgentResultsTest do
  @moduledoc """
  Unit tests for `Nest.Agents.Agent.SubAgentResults.child_message/2` — the
  one place a child's outcome becomes inbox text.

  A completion is the child's own words (`kind: :agent`, so the inbox labels
  it `[Message from agent "X"]`). Everything else is the *runtime* speaking
  (`kind: :notice`, rendered bare), because the child did not say it: a child
  that finished its turn without text, failed, or was stopped before it
  answered.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.SubAgentResults

  test "a completion is the child's words; a child that did not answer is the runtime's" do
    for {result, content, kind} <- [
          {{:ok, "the answer"}, "the answer", :agent},
          {{:ok, ""}, "Child agent kid finished its turn without producing any text.", :notice},
          {{:failed, :boom}, "Child agent kid failed before it answered: :boom", :notice},
          {{:terminated, :shutdown}, "Child agent kid was stopped before it answered: :shutdown",
           :notice}
        ] do
      assert SubAgentResults.child_message("kid", result) == {content, kind}
    end
  end
end
