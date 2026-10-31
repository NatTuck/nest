defmodule Nest.Agents.Agent.SpawnErrorMessagesTest do
  @moduledoc """
  The two spawn-error renderers — `agents-spawn` and `agents-batch` — and what the
  *model* reads when a spawn is refused.

  Both pass a reason that is already a sentence through rather than wrapping it in
  `inspect`, because a tagged reason rendered with `inspect` hands the model a
  tuple it cannot act on.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.BatchPlan
  alias Nest.Agents.Agent.SpawnErrors
  alias Nest.ConfigFile

  test "renders a config-file refusal as the sentence, not as a tuple" do
    reason = {:config_file_not_regular, "/ws/AGENTS.md", :symlink}
    sentence = ConfigFile.error_message(reason)

    assert SpawnErrors.message(reason) == "Could not spawn agent: #{sentence}"

    assert BatchPlan.spawn_error_message(reason) ==
             "Could not spawn batch children: #{sentence}"
  end

  # The two `Nest.Sandbox.workspace_error/1` refusals a spawn can carry. Both used
  # to reach the model as `inspect(atom)`, the way the `grandchild-glitch` spawn
  # failures reached it as `:workspace_required` — an atom naming a state a space
  # cannot be in, and nothing the agent could act on. Neither of these is
  # something the spawning agent can fix, so the sentence has to say so: the move
  # is to report it, not to retry.
  test "renders a workspace refusal as a sentence the agent can act on, in both renderers" do
    for reason <- [:workspace_missing, :workspace_under_tmp] do
      sentence = SpawnErrors.workspace_message(reason)

      assert sentence =~ "Report this to the user"

      assert SpawnErrors.message(reason) == "Could not spawn agent: " <> sentence

      assert BatchPlan.spawn_error_message(reason) ==
               "Could not spawn batch children: " <> sentence
    end
  end
end
