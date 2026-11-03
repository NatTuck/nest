defmodule Nest.Agents.Agent.SystemPrompt.Identity do
  @moduledoc """
  The two facts `Nest.Agents.Agent.SystemPrompt.compose_vocation_config/5` states
  about the agent it is writing for: its spawn `depth` (rendered into the
  identity line) and its `model` (the model section, which is the only place an
  agent is told what its own model accepts).

  They travel as a struct rather than as two more positional arguments (#128).
  Both used to arrive as anonymous trailing arguments whose types are `term()`,
  and a transposition of that shape is not hypothetical: a caller once passed
  `mode` and `depth` the wrong way round and every agent started reading "at
  spawn depth act of 3". A keyword list would not have helped — the keys are
  only labels, and `Keyword.get/2` is silent about a missing one — so the
  `@enforce_keys` below is what makes an omitted value a loud failure at the
  call site instead of a silent `nil` in the prompt.

  `depth` is the agent's distance from its tree root (0 for a root,
  `parent.depth + 1` for a child) and `model` is the model's **name**, a string
  or `nil` for a caller with no model to state. The agent's own name stays a
  separate argument of the composer: it is the label the caller already holds,
  and it is not adjacent to either of these.
  """

  @enforce_keys [:depth, :model]
  defstruct [:depth, :model]

  @type t :: %__MODULE__{depth: non_neg_integer(), model: String.t() | nil}
end
