defmodule Nest.ToolsContextCheckTest do
  use ExUnit.Case, async: true

  alias Nest.Tools

  describe "context-check tool" do
    test "reports message count, tokens used, limit, percent, and usable remaining" do
      function = Tools.get_function("context-check", "/tmp")

      messages = [
        {:system, %Nest.Messages.System{parts: []}},
        {:user, %Nest.Messages.User{tokens: 5_000, parts: []}}
      ]

      # reserve = max(8192, 0.20 * 100000) = 20000
      # used = 5000 (real floor from the user message's tokens)
      # usable = 100000 - 5000 - 20000 = 75000
      assert {:ok, content} =
               function.function.(%{}, %{messages: messages, context_limit: 100_000})

      assert content =~ "2 messages"
      assert content =~ "5000 / 100000 tokens used"
      assert content =~ "(5%)"
      assert content =~ "Usable remaining: ~75000"
    end

    test "falls back to message count when the context limit is unknown" do
      function = Tools.get_function("context-check", "/tmp")

      messages = [
        {:system, %Nest.Messages.System{parts: []}},
        {:user, %Nest.Messages.User{parts: []}}
      ]

      assert {:ok, content} = function.function.(%{}, %{messages: messages})
      assert content =~ "2 messages"
      assert content =~ "limit unknown"
    end
  end
end
