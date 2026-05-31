defmodule Nest.Test.ReqNullAdapter do
  @moduledoc """
  A Req adapter that crashes the application for unexpected HTTP requests.

  Used in test mode to prevent real HTTP requests. Only allows requests to
  /models endpoints for auto-discovery testing. All other requests cause
  an immediate crash with a clear error message.
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
      # Crash immediately for any unexpected HTTP request
      raise """
      WTF YOU TRIED TO DO A REAL HTTP REQUEST

      Attempted to make HTTP request to: #{url}
      Method: #{request.method}

      Real HTTP requests are not allowed in tests. If this request is expected,
      you must mock it using Mimic.stub_with/2 or similar.

      Example:
        Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)
      """
    end
  end
end
