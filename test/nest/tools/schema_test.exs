defmodule Nest.Tools.SchemaTest do
  @moduledoc """
  The schema — and the model-facing description — of every sub-agent tool.

  Split out of `Nest.ToolsTest` when the #62/#54 schema assertions pushed that
  file over the credo line cap. Every description assertion the tool text
  promises lives here, so a wording change is caught in one place.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.Tool, as: Function
  alias Nest.Sandbox.Mounts
  alias Nest.Tools

  describe "sub-agent tools" do
    test "models-list resolves to a registered tool" do
      function = Tools.get_function("models-list", Mounts.new("/tmp", nil))

      assert %Function{} = function
      assert function.name == "models-list"
      assert function.description =~ "expose_models"
    end

    test "agents-spawn schema exposes the optional vocation and model arguments" do
      function = Tools.get_function("agents-spawn", Mounts.new("/tmp", nil))
      props = function.parameters_schema["properties"]

      assert props["vocation"]["type"] == "string"
      assert props["vocation"]["description"] =~ "vocation slug"
      assert props["model"]["type"] == "string"
      assert props["model"]["description"] =~ "provider/model-name"
      # Both are optional: the name is the only required argument.
      assert function.parameters_schema["required"] == ["name"]

      # Nothing waits any more, so neither of the blocking controls applies.
      for gone <- ["async", "timeout"] do
        refute Map.has_key?(props, gone),
               "agents-spawn still offers `#{gone}`, which the async contract removed"
      end

      assert function.description =~ "arrives later as a message"
      refute function.description =~ "blocks"
      refute function.description =~ "agents-spawn result"
      # A child that fails, is stopped or produces nothing sends a message
      # too, so the description must not promise an answer unconditionally
      # — and that message is a runtime notice naming the reason, not the
      # child's words.
      assert function.description =~ "fails, is stopped or produces nothing"
      assert function.description =~ "a runtime notice naming the reason"
    end

    test "agents-query schema takes name, prompt and an optional set_mode" do
      function = Tools.get_function("agents-query", Mounts.new("/tmp", nil))
      props = function.parameters_schema["properties"]
      assert Map.keys(props) |> Enum.sort() == ["name", "prompt", "set_mode"]
      assert props["set_mode"]["enum"] == ["mine", "plan", "act"]

      assert function.parameters_schema["required"] == ["name", "prompt"]

      assert function.description =~ "owes you a reply"
      assert function.description =~ "arrives later as a message"
      # The debtor does go idle after a give-up, so the description must
      # not promise an answer unconditionally.
      assert function.description =~ "runtime gives up"
    end

    test "agents-batch schema exposes items/glob/template with no required args" do
      function = Tools.get_function("agents-batch", Mounts.new("/tmp", nil))
      props = function.parameters_schema["properties"]
      assert props["items"]["type"] == "array"
      assert props["glob"]["type"] == "string"
      assert props["template"]["type"] == "string"
      assert props["on_error"]["enum"] == ["collect", "fail_fast"]

      # The items/XOR/glob shape is validated at runtime, so nothing is
      # required at the schema level.
      assert (function.parameters_schema["required"] || []) == []

      # The aggregate is a message now; `timeout` stays as the
      # coordinator's per-item deadline.
      assert function.description =~ "receive the aggregate later as a message"
      refute function.description =~ "get back ONE aggregated result"
      assert props["timeout"]["type"] == "integer"
    end

    test "agents-send schema requires name and message" do
      function = Tools.get_function("agents-send", Mounts.new("/tmp", nil))

      assert function.parameters_schema["required"] == ["name", "message"]
      assert function.parameters_schema["properties"]["name"]["type"] == "string"
      assert function.parameters_schema["properties"]["message"]["type"] == "string"

      # Replying is what discharges an owed reply, so the description
      # must say so rather than pointing at `agents-query`.
      assert function.description =~ "discharges the reply you owe"
      refute function.description =~ "when you need the response now"
    end

    test "the wait schemas" do
      # Issue #62: the wait is synchronisation only — it carries no message
      # content, because the body arrives as an ordinary inbox delivery.
      # Issue #54: the wait never blocks, so it offers no way to block — no
      # `block` property at all, not merely a `false` default. An empty
      # `names` is meaningful, so nothing is required.
      wait = Tools.get_function("agents-wait", Mounts.new("/tmp", nil))
      props = wait.parameters_schema["properties"]
      assert props["names"]["type"] == "array"
      assert props["names"]["items"]["type"] == "string"
      assert props["timeout"]["type"] == "integer"
      assert props["all"]["type"] == "boolean"
      refute Map.has_key?(props, "block")
      refute wait.description =~ "block"
      assert (wait.parameters_schema["required"] || []) == []
      assert wait.description =~ "carries NO message content"
      assert wait.description =~ "returns immediately"
      assert wait.description =~ "not an error"
      # The wait ends the caller's turn whenever it leaves a watch outstanding;
      # the description has to say so, because the model cannot undo it.
      assert wait.description =~ "ends your turn"
      # Only a peer this agent queried owes it anything; a peer that owes
      # someone else nothing relevant to this caller may be idle too.
      assert wait.description =~ "owes no replies"
      assert wait.description =~ "a peer you queried"
      # A give-up is announced, but only if the runtime can reach the requester:
      # a refusal is recorded, not promised away.
      assert wait.description =~ "give-up reaches you as a runtime notice"
      assert wait.description =~ "only records the refusal"

      # `shell-wait` is the same shape: a watch, never a block.
      shell_wait = Tools.get_function("shell-wait", Mounts.new("/tmp", nil))
      shell_props = shell_wait.parameters_schema["properties"]
      refute Map.has_key?(shell_props, "block")
      refute shell_wait.description =~ "block"
      assert shell_props["timeout"]["type"] == "integer"
      assert shell_wait.parameters_schema["required"] == ["id"]
    end

    test "the history schema states its indexing rule and its search shape" do
      # Issue #22. The negative-index rule and the search result's shape are
      # behaviour the model has to know to use the tool at all, so they are
      # pinned as text here, next to the other model-facing promises.
      history = Tools.get_function("agents-history", Mounts.new("/tmp", nil))
      props = history.parameters_schema["properties"]

      assert Enum.sort(Map.keys(props)) == ["length", "name", "search", "start_index"]
      assert (history.parameters_schema["required"] || []) == []
      assert {props["start_index"]["type"], props["length"]["type"]} == {"integer", "integer"}
      assert props["search"]["type"] == "string"

      # A bare read is the last message, which is what `start_index: -1` spells
      # out; the window runs forward from the resolved index.
      assert props["start_index"]["description"] =~ "Defaults to -1"
      assert props["start_index"]["description"] =~ "Negative counts from the end"
      assert history.description =~ "start_index: -5, length: 5"
      assert history.description =~ "runs past the end"
      assert history.description =~ "never a silent truncation"

      # The search result's shape, key by key.
      assert history.description =~ "case-insensitive literal substring"
      assert history.description =~ ~s("matches")
      assert history.description =~ ~s("index": N)
      assert history.description =~ ~s("role")
      assert history.description =~ ~s("text")
      assert history.description =~ ~s("text_truncated")
    end

    test "the status schema reports the count, the boundary and the state" do
      status = Tools.get_function("agents-status", Mounts.new("/tmp", nil))

      assert Map.keys(status.parameters_schema["properties"]) == ["name"]
      assert (status.parameters_schema["required"] || []) == []

      assert status.description =~ "how many messages its history holds"
      assert status.description =~ "the index of its last compaction"
      assert status.description =~ "not_running"
      assert status.description =~ "never starts one"
    end
  end

  describe "the compaction tool" do
    test "context-compact splits its guidance into cover and preserve" do
      # This schema is the only place the model learns the contract: the
      # request names the arguments rather than repeating them, and the
      # validator refuses what the schema does not describe.
      function = Tools.get_function("context-compact", Mounts.new("/tmp", nil))
      props = function.parameters_schema["properties"]

      assert Enum.sort(Map.keys(props)) == ["cover", "preserve"]
      assert (function.parameters_schema["required"] || []) == []

      # The limit is enforced in `Machine.Response` (a longer `cover` is
      # refused, not truncated), and both sides read it from
      # `Tools.context_compact_cover_limit/0`.
      assert props["cover"]["type"] == "string"
      assert props["cover"]["maxLength"] == Tools.context_compact_cover_limit()
      assert props["cover"]["description"] =~ "100 characters or fewer"
      assert props["cover"]["description"] =~ "`preserve`"

      assert props["preserve"]["type"] == "string"
      assert props["preserve"]["description"] =~ "verbatim"
      assert props["preserve"]["description"] =~ "not as instructions to the summarizer"

      # `focus` is gone; `MachineCompactionRequestTest` pins that a caller
      # still passing it is refused rather than ignored, and the description
      # must not point at it either.
      refute function.description =~ "focus"
    end
  end
end
