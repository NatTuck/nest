defmodule Nest.Support.CaptureLLMClient do
  @moduledoc """
  Test-only LLM client that captures the `RunRequest` it
  received and returns a canned event stream.

  Used by `Nest.Scripts.CompactionProbeSupportTest` to assert
  the exact request shape the compactor's summarization
  callback builds (model, tool_choice, summarization system
  message, etc.) without needing a live LLM.
  """

  def run(request, opts) do
    send(self(), {:captured_request, request})
    send(self(), {:captured_opts, opts})

    {:ok,
     [
       {:text, "fake summary"},
       {:done, %{response: %Nest.LLM.RunResponse{text: "fake summary"}}}
     ]}
  end
end
