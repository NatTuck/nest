defmodule Nest.Agents.Agent.TreePosition do
  @moduledoc """
  Sub-struct holding the agent's position in the spawned
  child tree. Extracted from the parent `Agent` struct so
  the parent doesn't push past the 16-field cap.

  `parent_id` is the integer `agents.id` of the agent that
  spawned this one via `agents-spawn` (with `clone_context`). `nil` for root agents.
  `parent_name` is the parent's readable identifier (a
  String), held so the child can dispatch messages to the
  parent's GenServer through `Agents.Registry.via_tuple/2`
  without an integer→name lookup at completion time.

  `fork_message_index` is the clone's first own `message_index`.
  The clone shares its ancestors' rows below it and owns from it
  up (see `notes/shared-message-structure.md`). `nil` for a root
  or a fresh child (owns from index 0); a clone keeps an integer
  fork index for life.
  """

  defstruct parent_id: nil, parent_name: nil, fork_message_index: nil
end
