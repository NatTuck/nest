defmodule Nest.LLM.Tool do
  @moduledoc """
  Nest-native tool spec.

  The `function` callback is invoked with the decoded arguments
  map and a context map (carrying caps and other per-call data),
  and returns `{:ok, String.t()}` on success or `{:error, String.t()}`
  on failure.

  Tool-result sizing is enforced by `Nest.Agents.Agent.BatchSizer`,
  not by this struct. The BatchSizer computes an inline cap per
  batch equal to 80% of the remaining usable context window and
  routes results that exceed the cap through a per-tool path:

    * `execute_command` → path-and-head summary (full output saved to tmp)
    * `read_file`        → `{:error, "File is X tokens which exceeds your requested limit of Y."}`
    * Other tools        → log warning, keep full (cap unreachable in practice)

  The LLM may override the cap on a per-call basis by passing
  `max_result_tokens` in the call's arguments; the override may
  only lower the cap (lower it to force a summary/error path even
  when full content would fit inline). The schema for
  `max_result_tokens` lives on `parameters_schema`, not on the
  struct.
  """

  defstruct name: nil,
            description: nil,
            parameters_schema: nil,
            function: nil

  @type execute_result :: {:ok, String.t()} | {:error, String.t()}

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
