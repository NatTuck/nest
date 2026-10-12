defmodule Nest.Agents.Agent.BatchSizerMediaTest do
  @moduledoc """
  `BatchSizer`'s handling of media tool results (issue #40).

  A media result is not a string: the tool returns `{:ok, {:media, part}}`, and
  the BatchSizer has to price it, decide keep-or-refuse, and emit it as a part
  beside the `ToolResult` it answers.

  Split from `batch_sizer_test.exs` to keep that file under credo's line cap.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent.BatchSizer
  alias Nest.LLM.Tool
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  defp make_tool(name, fn_) do
    %Tool{name: name, description: name, parameters_schema: nil, function: fn_}
  end

  defp call(id, name, arguments) do
    %ToolCall{id: id, name: name, arguments: arguments}
  end

  # A real 1x1 PNG, so the fixture cannot drift from `new_media/1`'s invariant
  # that `data` decodes to exactly `bytes`.
  defp media_part(tool_call_id) do
    data =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="

    {:ok, part} =
      Part.new_media(%{
        tool_call_id: tool_call_id,
        modality: :image,
        media_type: "image/png",
        data: data,
        bytes: byte_size(Base.decode64!(data)),
        path: "shot.png"
      })

    part
  end

  defp ctx(tools, opts \\ []) do
    %{
      tools: tools,
      caps: %{"fs" => %{"read" => ["/"], "write" => ["/tmp"]}, "net" => false},
      context_limit: Keyword.get(opts, :context_limit, 100_000),
      messages: Keyword.get(opts, :messages, []),
      tmp_path: Keyword.get(opts, :tmp_path, nil),
      agent_pid: self(),
      agent_name: "test"
    }
  end

  defp media_tool(part) do
    make_tool("media-probe", fn _, _ -> {:ok, {:media, part}} end)
  end

  describe "media tool results" do
    test "cook/2 emits the ToolResult and then its media part" do
      media = media_part("c1")

      assert [%ToolResult{} = result, ^media] =
               BatchSizer.run(
                 [call("c1", "media-probe", %{"path" => "shot.png"})],
                 ctx([media_tool(media)])
               )

      assert result.tool_call_id == "c1"
      assert result.name == "media-probe"
      assert result.is_error == false

      # The text anchor is what keeps `ToolResult.content` a string, and it
      # tells the model what rode along without repeating a byte of it.
      assert result.content =~ "attached below"
      assert result.content =~ "image/png"
      assert result.content =~ "shot.png"
      refute result.content =~ "base64"
    end

    test "an over-cap media result errors instead of being summarized" do
      media = media_part("c1")

      over_cap =
        call("c1", "media-probe", %{"path" => "shot.png", "max_result_tokens" => 100})

      log =
        capture_log(fn ->
          assert [%ToolResult{} = result] =
                   BatchSizer.run([over_cap], ctx([media_tool(media)]))

          # Media cannot be summarized or offloaded, so the only honest outcome
          # is an error naming the cap. Attaching it anyway would blow the
          # budget; offloading it would hand the model a pointer to something
          # it cannot see.
          assert result.is_error == true
          assert result.content =~ "exceeds your requested limit of 100"
          assert result.content =~ "cannot be summarized"
          refute result.content =~ "base64"
        end)

      # `cook/2` logs every `is_error` result as a permanent diagnostic, so this
      # path is one of them: pin the log rather than leaking it to the console.
      assert log =~ "BatchSizer produced is_error=true tool result"
      assert log =~ "media-probe"
    end

    test "a batch with two media reads keeps each result beside its own media" do
      a = media_part("c1")
      b = media_part("c2")

      tools = [
        make_tool("media-probe", fn %{"which" => which}, _ ->
          {:ok, {:media, if(which == "a", do: a, else: b)}}
        end)
      ]

      parts =
        BatchSizer.run(
          [
            call("c1", "media-probe", %{"which" => "a"}),
            call("c2", "media-probe", %{"which" => "b"})
          ],
          ctx(tools)
        )

      assert [r1, m1, r2, m2] = parts
      assert r1.tool_call_id == "c1"
      assert m1 == a
      assert r2.tool_call_id == "c2"
      assert m2 == b
    end

    test "a media part never reaches the binary or offload machinery" do
      # It is not a binary, so it must not reach `handle_binary_shell` (which
      # would write the base64 to a scratch file) or `offload` (which would
      # replace it with a pointer).
      media = media_part("c1")

      parts = BatchSizer.run([call("c1", "media-probe", %{})], ctx([media_tool(media)]))

      assert [%ToolResult{content: content}, %Part.Media{}] = parts
      refute content =~ "saved to"
      refute content =~ "scratch"
    end
  end
end
