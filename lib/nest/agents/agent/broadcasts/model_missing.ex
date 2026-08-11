defmodule Nest.Agents.Agent.Broadcasts.ModelMissing do
  @moduledoc """
  Broadcasts a `chat:status` event for an agent whose persisted
  `model` could not be resolved at startup (status
  `:model_missing`). Extracted from `Nest.Agents.Agent.Broadcasts`
  so the parent module stays under the credo 500-line cap.

  Channel subscribers drive the repair banner in
  `ChatPage.jsx` from the `payload.status === "model_missing"`
  marker; the resolved model label and the original reason
  ride along for log/UI display.
  """

  alias Nest.PubSub

  def broadcast(space_id, name, model, reason) do
    Phoenix.PubSub.broadcast(
      PubSub,
      "agent:#{space_id}:#{name}",
      {:chat_status,
       %{
         status: "model_missing",
         model: model_label(model),
         reason: inspect(reason)
       }}
    )
  end

  defp model_label(nil), do: nil

  defp model_label(model) when is_map(model) do
    model
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp model_label(other), do: %{"name" => to_string(other)}
end
