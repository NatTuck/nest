defmodule Nest.LLM.RunRequestTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.RunRequest

  test "an empty request has no messages, no tools, no model, and sensible defaults" do
    req = %RunRequest{}

    assert req.messages == []
    assert req.tools == []
    assert req.model == nil
    assert req.tool_choice == :auto
    assert req.temperature == nil
    assert req.max_tokens == nil
    assert req.top_p == nil
    assert req.stream == true
    assert req.metadata == nil
  end
end
