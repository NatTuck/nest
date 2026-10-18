defmodule Nest.Agents.Agent.ModeAuthority do
  @moduledoc """
  Who may move whom between modes.

  One rule, in one place: **a mode may be held or lowered, never raised**, and
  only the human is above it. Concretely:

    * the **human** may set any agent's mode to anything — including an agent's
      own mode, and including raising it;
    * an **agent** may never set its **own** mode. That is self-escalation, and it
      is refused even when the request arrives as a message the agent sent
      itself;
    * an agent may move a **descendant** only to a mode it is in itself, or to a
      less permissive one (`Nest.Modes.allows?/2`);
    * an agent may not move anything else at all: an agent it did not spawn is
      not its to command.

  A **spawn** is the same rule with `target: :child` — a `plan` parent may not
  spawn an `act` child, and may not spawn one and then raise it — so
  `Nest.Agents.Agent.PreSpawn` calls this for every creation, and a caller that
  bypasses the spawn tools is held to it too.

  Every refusal carries a sentence the caller can hand straight back to the agent
  that asked, so the rule is never enforced silently. The callers are the send
  tools' `set_mode` (`Nest.Tools.QueryAgent` and friends, which surface the
  sentence as a tool error) and `PreSpawn`.

  ## Why the actor's mode is passed in

  Every caller already has it — `ctx.mode` on a tool call, `state.live.mode` in an
  agent — and a lookup here would be a second source of truth for a value that
  can change under it.
  """

  alias Nest.Agents.ChildRegistry
  alias Nest.Modes

  # The tree is shallow (`Nest.Agents.Agent.Config.configured_max_depth/0`), so
  # walking the live parent links is cheap. The bound is a cycle guard: a
  # registry that somehow held a loop would otherwise walk forever.
  @max_walk 16

  @typedoc """
  Who is asking. `:kind` is the whole distinction the rule makes; `:space_id`,
  `:name`, `:mode` and `:target` describe an agent, and `:target` is `:child`
  for a spawn or the name of the existing agent being changed.
  """
  @type actor :: %{
          required(:kind) => :human | :agent,
          optional(:space_id) => integer(),
          optional(:name) => String.t(),
          optional(:mode) => String.t(),
          optional(:target) => :child | String.t()
        }

  @doc """
  Whether `actor` may set `requested` on the agent its `:target` names.

  Returns `:ok`, or `{:error, reason}` where `reason` is a sentence to show the
  agent that asked.
  """
  @spec authorize(actor(), String.t()) :: :ok | {:error, String.t()}
  def authorize(%{kind: :human}, requested) do
    if Modes.valid?(requested), do: :ok, else: {:error, unknown_mode(requested)}
  end

  def authorize(%{kind: :agent} = actor, requested) do
    cond do
      not Modes.valid?(requested) -> {:error, unknown_mode(requested)}
      target(actor) == actor[:name] -> {:error, self_refusal()}
      target(actor) == :child -> monotone(actor, requested)
      descendant?(actor) -> monotone(actor, requested)
      true -> {:error, not_a_descendant(actor)}
    end
  end

  defp monotone(actor, requested) do
    if Modes.allows?(actor[:mode], requested) do
      :ok
    else
      {:error, raise_refusal(actor, requested)}
    end
  end

  defp descendant?(%{space_id: space_id, name: name, target: target})
       when is_binary(target) and is_binary(name) and is_integer(space_id) do
    walk_up(space_id, target, name, 0)
  end

  defp descendant?(_actor), do: false

  # `ChildRegistry` is the authority on who spawned whom, and an agent that is
  # not registered there is nobody's descendant. A *stopped* child is not in the
  # registry either, which is the right answer: there is nothing left to move.
  defp walk_up(_space_id, _name, _actor, depth) when depth > @max_walk, do: false

  defp walk_up(space_id, name, actor, depth) do
    case ChildRegistry.parent_of(space_id, name) do
      nil -> false
      ^actor -> true
      parent -> walk_up(space_id, parent, actor, depth + 1)
    end
  end

  defp target(%{target: target}), do: target
  defp target(_actor), do: nil

  defp unknown_mode(requested) do
    "#{inspect(requested)} is not a mode. The modes are: #{Enum.join(Modes.names(), ", ")}."
  end

  defp self_refusal do
    "You cannot set your own mode: that is self-escalation, and only the user can " <>
      "give you more permission than you have. Ask the user to change it."
  end

  defp not_a_descendant(%{target: target}) do
    "You can only set the mode of an agent you spawned (a descendant), and " <>
      "#{inspect(target)} is not one. Ask the user to change it."
  end

  defp raise_refusal(%{mode: mode, target: target}, requested) do
    "You are in `#{mode}` mode, so you cannot put #{describe(target)} into " <>
      "`#{requested}`: a mode can be held or lowered, never raised. Only the user " <>
      "can give more permission than you have."
  end

  defp describe(:child), do: "a child you spawn"
  defp describe(name), do: inspect(name)
end
