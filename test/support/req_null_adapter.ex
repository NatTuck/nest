defmodule Nest.Test.ReqNullAdapter do
  @moduledoc """
  A Req adapter that crashes the application for unexpected HTTP requests.

  Used in test mode to prevent real HTTP requests. Only allows requests to
  /models endpoints for auto-discovery testing. All other requests cause
  an immediate crash with a clear error message.

  Elixir's default exception formatting includes the full stacktrace
  on uncaught raises, so the caller info is preserved without us
  having to format it manually (which is fragile — stacktrace
  frame shapes vary between Erlang/Elixir and try/catch boundaries).
  """

  alias Req.Response

  @doc """
  Runs the null adapter. Only allows /models endpoints.

  For /models endpoints, returns a fake test model.
  For all other endpoints, raises a fatal error to prevent real HTTP requests.
  """
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t()}
  def run(request) do
    url = to_string(request.url)

    if String.ends_with?(url, "/models") do
      # Return a fake test model for auto-discovery
      response =
        Response.new(
          status: 200,
          body: %{
            "data" => [
              %{"id" => "fake_test_model"}
            ]
          }
        )

      {request, response}
    else
      # Crash immediately for any unexpected HTTP request. The full
      # stacktrace is included by Elixir's default exception
      # formatting, so the caller doesn't need to be embedded here.
      raise """
      WTF YOU TRIED TO DO A REAL HTTP REQUEST

      Attempted to make HTTP request to: #{url}
      Method: #{request.method}

      Real HTTP requests are not allowed in tests. If this request is expected,
      you must mock it using Mimic.stub_with/2 or similar.

      Example:
        Mimic.stub_with(Nest.LLM.OpenAIClient, Nest.LLM.MockClient)
      """
    end
  end
end
