defmodule Nest.Tools.SchemaTest do
  @moduledoc """
  The schema — and the model-facing description — of every sub-agent tool.

  Split out of `Nest.ToolsTest` when the #62/#54 schema assertions pushed that
  file over the credo line cap. Every description assertion the tool text
  promises lives here, so a wording change is caught in one place.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.Tool, as: Function
  alias Nest.Tools

  describe "sub-agent tools" do
    test "models-list resolves to a registered tool" do
      function = Tools.get_function("models-list", "/tmp")

      assert %Function{} = function
      assert function.name == "models-list"
      assert function.description =~ "expose_models"
    end

    test "agents-spawn schema exposes the optional vocation and model arguments" do
      function = Tools.get_function("agents-spawn", "/tmp")
      assert function.name == "agents-spawn"

      props = function.parameters_schema["properties"]
      assert props["vocation"]["type"] == "string"
      assert props["vocation"]["description"] =~ "vocation slug"
      refute "vocation" in (function.parameters_schema["required"] || [])

      assert props["model"]["type"] == "string"
      assert props["model"]["description"] =~ "provider/model-name"
      refute "model" in (function.parameters_schema["required"] || [])

      # Nothing waits any more, so neither the blocking controls nor the
      # result-size override (the answer is an inbox message now) apply.
      for gone <- ["async", "timeout", "max_result_tokens"] do
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

    test "agents-query schema takes name and prompt and nothing that waits" do
      function = Tools.get_function("agents-query", "/tmp")
      assert function.name == "agents-query"

      props = function.parameters_schema["properties"]
      assert Map.keys(props) |> Enum.sort() == ["name", "prompt"]

      assert function.parameters_schema["required"] == ["name", "prompt"]

      assert function.description =~ "owes you a reply"
      assert function.description =~ "arrives later as a message"
      # The debtor does go idle after a give-up, so the description must
      # not promise an answer unconditionally.
      assert function.description =~ "runtime gives up"
    end

    test "agents-batch schema exposes items/glob/template with no required args" do
      function = Tools.get_function("agents-batch", "/tmp")
      assert function.name == "agents-batch"

      props = function.parameters_schema["properties"]
      assert props["items"]["type"] == "array"
      assert props["glob"]["type"] == "string"
      assert props["template"]["type"] == "string"
      assert props["on_error"]["enum"] == ["collect", "fail_fast"]

      # The items/XOR/glob shape is validated at runtime, so nothing is
      # required at the schema level.
      assert (function.parameters_schema["required"] || []) == []

      # The aggregate is a message now; `timeout` stays as the
      # coordinator's per-item deadline. The result-size cap is gone
      # (decision 14, extended to batch): there is no inline result left
      # to bound.
      assert function.description =~ "receive the aggregate later as a message"
      refute function.description =~ "get back ONE aggregated result"
      assert props["timeout"]["type"] == "integer"
      refute Map.has_key?(props, "max_result_tokens")
    end

    test "agents-send schema requires name and message" do
      function = Tools.get_function("agents-send", "/tmp")
      assert function.name == "agents-send"

      assert function.parameters_schema["required"] == ["name", "message"]
      assert function.parameters_schema["properties"]["name"]["type"] == "string"
      assert function.parameters_schema["properties"]["message"]["type"] == "string"

      # Replying is what discharges an owed reply, so the description
      # must say so rather than pointing at `agents-query`.
      assert function.description =~ "discharges the reply you owe"
      refute function.description =~ "when you need the response now"
    end

    test "the wait and fetch schemas" do
      # Issue #62: the wait is synchronisation only and the fetch consumes;
      # issue #54: the wait is non-blocking by default with an explicit
      # blocking mode. An empty `names` is meaningful, so nothing is required.
      wait = Tools.get_function("agents-wait-for-idle", "/tmp")
      props = wait.parameters_schema["properties"]
      assert wait.name == "agents-wait-for-idle"
      assert props["names"]["type"] == "array"
      assert props["names"]["items"]["type"] == "string"
      assert props["timeout"]["type"] == "integer"
      assert {props["all"]["type"], props["block"]["type"]} == {"boolean", "boolean"}
      assert (wait.parameters_schema["required"] || []) == []
      assert wait.description =~ "carries NO message content"
      assert wait.description =~ "returns immediately"
      # Only a peer this agent queried owes it anything; a peer that owes
      # someone else nothing relevant to this caller may be idle too.
      assert wait.description =~ "owes no replies"
      assert wait.description =~ "a peer you queried"
      # A give-up is announced, but only if the runtime can reach the requester:
      # a refusal is recorded, not promised away.
      assert wait.description =~ "give-up reaches you as a runtime notice"
      assert wait.description =~ "only records the refusal"

      fetch = Tools.get_function("agents-last-message", "/tmp")
      assert fetch.name == "agents-last-message"
      assert fetch.parameters_schema["properties"]["name"]["type"] == "string"
      assert fetch.parameters_schema["required"] == ["name"]
      assert fetch.description =~ "consumed"
    end
  end
end
