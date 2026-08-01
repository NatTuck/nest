defmodule Nest.LLM.RecoveryClientTest do
  @moduledoc """
  Tests for the inert LLM client used in the `:model_missing`
  recovery flow. The client never makes a network call —
  every `run/2` yields a fixed textual response so the
  agent's GenServer stays alive and introspection handlers
  (`:get_public_info`, `:get_messages`, etc.) continue to
  work even when the underlying provider is gone.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.Client
  alias Nest.LLM.RecoveryClient
  alias Nest.LLM.RunRequest

  describe "run/2" do
    test "yields a single fixed-text assistant response" do
      req = %RunRequest{model: "ghost-model"}

      assert {:ok, stream} = RecoveryClient.run(req, [])

      events = Enum.to_list(stream)
      assert length(events) >= 3

      text_events = for {:text, t} <- events, do: t

      assert text_events == [
               "Model is no longer available. Pick a replacement from the " <>
                 "model selector above to continue."
             ]

      finish_events = for {:finish_reason, r} <- events, do: r
      assert "stop" in finish_events

      # The stream must end with a `{:done, _}` so the
      # Runner's reducer can dispatch the on_response
      # callback and finalize the chat turn cleanly.
      assert match?({:done, %{response: _}}, List.last(events))
    end
  end

  describe "format_request_payload/2" do
    test "returns a JSON-safe payload identifying the recovery client" do
      req = %RunRequest{model: "ghost-model", messages: [], stream: true}

      payload = RecoveryClient.format_request_payload(req, [])

      assert payload["model"] == "ghost-model"
      assert payload["messages"] == []
      assert payload["stream"] == true
      # Marker so downstream code that pattern-matches on the
      # request payload can identify this client (e.g. in
      # api_log renders).
      assert payload["_recovery"] == true
    end
  end

  describe "behaviour compliance" do
    test "implements the Client behaviour" do
      # Compile-time check: the `@behaviour` declaration in
      # `RecoveryClient` would fail to compile if a callback
      # were missing, so just confirming the attribute is
      # present is enough here.
      attrs = RecoveryClient.module_info(:attributes)
      assert List.flatten(Keyword.get_values(attrs, :behaviour)) == [Client]
    end
  end
end
