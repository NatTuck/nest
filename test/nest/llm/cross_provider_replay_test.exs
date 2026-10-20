defmodule Nest.LLM.CrossProviderReplayTest do
  @moduledoc """
  Pins the one cross-provider replay behaviour no other test covers:
  `OpenAIClient` drops a historical `%Part.Thinking{}` on the wire and
  keeps only the visible text.

  The rest of the mixed-history replay contract is pinned next to the
  clients that implement it:

    * tool_use / tool_result id pass-through and wire role mapping —
      `Nest.LLM.OpenAIClientTest` and `Nest.LLM.AnthropicClientTest`
      (`format_request_payload/2`).
    * signed thinking replayed only while thinking is on, unsigned
      thinking never replayed — `Nest.LLM.AnthropicClientTest`.
    * unpaired ids surfaced as an Anthropic-shaped 400 through
      `MockClient` — `Nest.LLM.MockClientPreflightTest`.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.OpenAIClient
  alias Nest.LLM.RunRequest
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part

  test "OpenAI wire drops historical thinking and keeps the visible text" do
    # History that originated from an Anthropic reasoning turn. The
    # signature has no OpenAI wire field, so the whole Thinking part must
    # vanish rather than leak into the content or become a tool call.
    req = %RunRequest{
      messages: [
        {:assistant,
         %Assistant{
           index: 2,
           parts: [
             %Part.Text{text: "done"},
             %Part.Thinking{thinking: "deep thoughts", signature: "sig_xyz"}
           ]
         }}
      ]
    }

    assert OpenAIClient.format_request_payload(req, [])["messages"] == [
             %{"role" => "assistant", "content" => "done"}
           ]
  end
end
