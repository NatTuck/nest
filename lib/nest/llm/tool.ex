defmodule Nest.LLM.Tool do
  @moduledoc """
  Nest-native tool spec.

  The `function` callback is invoked with the decoded arguments
  map and a context map (carrying caps and other per-call data),
  and returns `{:ok, String.t()}` on success or `{:error, String.t()}`
  on failure.

  `max_result_tokens` is the default cap on the result size, in
  tokens. The agent's `BudgetPlanner` enforces this cap and may
  truncate the result before sending it to the LLM. The LLM can
  override the cap on a per-call basis by passing
  `max_result_tokens` in the call's arguments; the override is
  also capped at 50% of the model's context window (enforced at
  the tool-schema layer; the planner trusts whatever override it
  receives).
  """

  defstruct name: nil,
            description: nil,
            parameters_schema: nil,
            function: nil,
            max_result_tokens: nil

  @type execute_result :: {:ok, String.t()} | {:error, String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters_schema: map() | nil,
          function: (map(), map() -> execute_result()) | nil,
          max_result_tokens: pos_integer() | nil
        }

  @doc """
  Invoke the tool's function with the given arguments and context.
  """
  @spec execute(t(), map(), map()) :: execute_result()
  def execute(%__MODULE__{function: fun}, args, context) when is_function(fun, 2) do
    fun.(args, context)
  end
end
