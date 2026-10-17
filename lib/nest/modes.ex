defmodule Nest.Modes do
  @moduledoc """
  The two universal modes, and everything about them that is a constant.

  A mode is a *per-agent runtime property*: every agent is in exactly one, it can
  change while the agent works, and it is what the sandbox's caps are derived
  from. The modes themselves are therefore code constants rather than
  per-vocation data — `plan` may write only the space's scratch directory, `act`
  may also write the workspace, and nothing else varies per call (the network is
  the space's: `Nest.Spaces.network_access`).

  Everything about them lives here and nowhere else: their names, the ordering
  the monotone rule needs, the caps a mode resolves to, and the catalog the
  system prompt carries. Nothing here reads the database or the sandbox, which is
  what lets `Nest.Vocations` (which reads the schema) and the sandbox layer
  (which must not) both use it.
  """

  @plan "plan"
  @act "act"

  # Least permission first. The monotone rule is "an agent may move a descendant
  # to a mode it is in itself, or to a less permissive one", so this order *is*
  # the rule's ordering (`allows?/2`).
  @order [@plan, @act]

  # The mode an agent starts in when nothing says otherwise: the permissive one,
  # because that is what an agent had before modes existed. What actually seeds a
  # new agent is its blueprint's `default_mode` (`Nest.Blueprints.Blueprint`).
  @default @act

  # The caps each mode resolves to. `"net"` is a placeholder: the network is the
  # space's, injected at caps-resolution time by
  # `Nest.ProjectConfig.resolve_caps/2`, so a mode's own value is never read.
  # `"fs.read"` is the full read set in both modes — a mode restricts *writes*.
  @plan_caps %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}

  @act_caps %{
    "net" => false,
    "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
  }

  @doc """
  Every mode, least permissive first: `#{inspect(@order)}`.

  The authority for what a client may choose, and for the order the monotone rule
  compares in.
  """
  @spec names() :: [String.t()]
  def names, do: @order

  @doc "The read-only mode: the agent may write only the space's scratch."
  @spec plan() :: String.t()
  def plan, do: @plan

  @doc "The mode that may also write the workspace."
  @spec act() :: String.t()
  def act, do: @act

  @doc "The mode an agent gets when nothing names one: `#{@default}`."
  @spec default() :: String.t()
  def default, do: @default

  @doc """
  Whether `name` is a mode this build implements.
  """
  @spec valid?(term()) :: boolean()
  def valid?(name), do: name in @order

  @doc """
  The caps `name` resolves to, in the shape `Nest.Sandbox` reads.

  A name this build does not know — a row written by another build, a client that
  made one up — resolves to `default/0`'s caps rather than to nothing: a mode
  that cannot be honoured must not become a mode with no restrictions at all.
  """
  @spec caps(String.t() | nil) :: map()
  def caps(@plan), do: @plan_caps
  def caps(@act), do: @act_caps
  def caps(_unknown), do: caps(@default)

  @doc """
  Whether an agent in `actor` may move a *descendant* to `requested`.

  This is the monotone rule's whole arithmetic, and it is about an **agent's**
  authority only: a mode may be held or lowered, never raised, so an agent can
  pass on the permission it has and no more. Only the human may raise a mode, and
  only the human may set an agent's own mode; neither is this function's
  business — `Nest.Agents.Agent.ModeAuthority` is where the rule is applied.

  A `requested` this module does not know is refused rather than resolved, and an
  `actor` it does not know can set nothing.
  """
  @spec allows?(String.t(), String.t()) :: boolean()
  def allows?(actor, requested) do
    valid?(requested) and rank(requested) <= rank(actor)
  end

  @doc """
  The `Modes` section of the system prompt.

  `tool_capable?` is the agent's: with no tools there is nothing for a mode to
  restrict, so the section is empty rather than describing a distinction the
  agent cannot act on. (The `compact` contract is rendered separately by
  `Nest.Agents.Agent.SystemPrompt`, because it is not about modes and a tool-less
  agent still compacts.)

  `enforced?` is the *space's* — `false` only for a `"none"` space, where nothing
  enforces the restriction. The text has to say which, because "writes will fail"
  is a lie in a `none` space.

  Both arguments are properties of the agent and its space, so the bytes are the
  same on every composition for a given agent — which is what keeps them
  cache-safe.
  """
  @spec catalog(boolean(), boolean()) :: String.t()
  def catalog(false, _enforced?), do: ""

  def catalog(true, enforced?) do
    "\n\n[Available modes]\n\n" <>
      catalog_intro() <>
      "\n\n**`#{@plan}`** — " <>
      "the goal is agreement before action. Read anything you can reach, run " <>
      "commands that only read, and use your own scratch directory for working " <>
      "files, but do not change anything else. Treat a request as a proposal " <>
      "rather than a final instruction: ask about anything unclear, look for " <>
      "flaws in the plan and push back on them, and suggest improvements — the " <>
      "point is the best plan we can get before any work starts. Some changes " <>
      "have effects no sandbox can see (an HTTP request that creates something, " <>
      "for instance), so this is not only about what your tools will let you do." <>
      "\n\n**`#{@act}`** — you may change things, including the workspace. That " <>
      "is a permission rather than an instruction: make the changes the task " <>
      "needs, and no others.\n\n" <>
      catalog_switching() <>
      "\n\n" <>
      enforcement_sentence(enforced?) <>
      "\n"
  end

  defp catalog_intro do
    "You are always in exactly one mode, and it is shown on every message you " <>
      "receive — as a prefix on a message from the user, and in the header of a " <>
      "message from another agent. It can change while you are working."
  end

  defp catalog_switching do
    "Being switched is normal. The user may move you from `#{@plan}` to `#{@act}` " <>
      "so you can carry out the plan you just produced, or back to `#{@plan}` so " <>
      "you stop writing and report where things stand. Another agent can move you " <>
      "to `#{@plan}`, or to `#{@act}` if it is in `#{@act}` itself; only the user " <>
      "can give you more permission than you have. When your mode changes, adapt " <>
      "rather than continuing to attempt writes you have been told will not land."
  end

  defp enforcement_sentence(true) do
    "In this space `#{@plan}` mode's filesystem restriction is enforced by the " <>
      "sandbox: a write outside your scratch directory fails."
  end

  defp enforcement_sentence(false) do
    "In this space the sandbox cannot enforce `#{@plan}` mode at all — your " <>
      "tools will let you write anywhere. Keeping to it is on you."
  end

  # A mode this build does not know has no rank to compare: it is neither the
  # actor's mode nor any other, so `allows?/2` must refuse rather than guess.
  defp rank(name), do: Enum.find_index(@order, &(&1 == name)) || -1
end
