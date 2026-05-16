defmodule Nest.ReqMock do
  @moduledoc """
  Mock implementation of Req for testing HTTP requests.

  Used for auto-discovery of models from providers.
  Returns hardcoded responses for testing.
  """

  @doc """
  Mock implementation of Req.get/2 for /models endpoint.

  Returns a list of models from pegasus provider for testing.
  """
  def get(url, _opts \\ []) do
    if String.ends_with?(url, "/models") do
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => [
             %{"id" => "llama3.1-8b"},
             %{"id" => "llama3.1-70b"},
             %{"id" => "qwen2.5-7b"},
             %{"id" => "qwen2.5-72b"}
           ]
         }
       }}
    else
      {:error, "Unknown endpoint"}
    end
  end
end
