defmodule Nest.LLM.Tool do
  @moduledoc """
  Nest-native tool spec.

  The `function` callback is invoked with the decoded arguments
  map and a context map (carrying caps and other per-call data),
  and returns `{:ok, String.t()}` on success or `{:error, String.t()}`
  on failure.

  Tool-result sizing is enforced by `Nest.Agents.Agent.ResultPolicy`,
  not by this struct. It decides `min(requested, budget)` per result —
  `requested` being the call's `max_result_tokens` or the tool's default,
  and `budget` what the context has left — and routes a result over it
  through a per-tool path:

    * `file-read` → `{:error, "File is X tokens which exceeds your requested limit of Y."}`
    * Every other tool → a pointer + preview, with the full output saved to
      the agent's scratch dir.

  No tool result is ever kept over budget: every result goes through that
  one admission, whatever its kind (a success, an error, a cancellation and
  a wait are the same content question). The LLM chooses the size by
  passing `max_result_tokens` in the call's arguments; the schema for it
  lives on `parameters_schema`, not on the struct.
  """

  defstruct name: nil,
            description: nil,
            parameters_schema: nil,
            function: nil

  # `{:cancelled, reason}` is a call the space edit called off
  # (`Nest.Agents.SpaceGate`): `Nest.Tools.ShellCmd.execute/4`'s shape for it, and
  # `BatchSizer` carries it as the entry kind `:cancelled` — `is_error: true` for
  # the model, silent in the operator log.
  @type execute_result :: {:ok, String.t()} | {:error, String.t()} | {:cancelled, String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters_schema: map() | nil,
          function: (map(), map() -> execute_result()) | nil
        }

  @doc """
  Invoke the tool's function with the given arguments and context.
  """
  @spec execute(t(), map(), map()) :: execute_result()
  def execute(%__MODULE__{function: fun}, args, context) when is_function(fun, 2) do
    fun.(args, context)
  end
end
