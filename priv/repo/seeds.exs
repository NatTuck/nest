# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Idempotent: uses `Vocations.upsert_vocation/1` so re-running
# this script updates existing rows (system prompts, tools) in
# place rather than failing on duplicate names or creating a
# second row. Safe to re-run after editing any vocation field
# below.
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Nest.Repo.insert!(%Nest.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Nest.Accounts.{Password, User}
alias Nest.Blueprints
alias Nest.Vocations

# Tool capabilities are granted by group. `agents` bundles
# spawn/query/list/archive/batch plus the model-discovery
# `models-list`. `agents-spawn` and `agents-batch` are additionally
# stripped for max-depth agents at spawn/compaction time (the others
# remain).
# The standard capability set: what a seeded vocation gets when it needs no
# narrower or wider list (`Default` and `Chat` name their own). Written out
# rather than taken from `Nest.Tools.Groups.all/0` on purpose — a new group is a
# capability, and a vocation that should have it says so.
standard_groups = ["file", "shell", "context", "agents"]

# The groups a vocation that *coordinates* other agents gets: the standard set
# plus the pane (`decisions-*` / `todos-*`), which is how such an agent asks the
# human a question or shows its plan instead of burying either in a stop reply.
lead_groups = standard_groups ++ ["pane"]

# Default - minimal vocation for agents without a specific role.
# Used as the fallback for any test or runtime path that needs a
# vocation but doesn't care which one. The context tools only (no
# filesystem, no network).
{:ok, _default_vocation} =
  Vocations.upsert_vocation(%{
    name: "Default",
    description: "A minimal default vocation for agents without a specific role",
    system_prompt: "You are a helpful assistant.",
    tools: ["context", "agents"]
  })

# Programmer - code-focused agent with tools and workspace.
# The modes are universal (`Nest.Modes`): `plan` writes only the
# agent's scratch, `act` also writes the workspace, and whether the
# network is reachable is the *space's* `network_access`, not the
# vocation's.
{:ok, _} =
  Vocations.upsert_vocation(%{
    name: "Programmer",
    description: "A coding assistant that can read and write files in a workspace",
    system_prompt: """
    You are a skilled programmer. Help users write, review, and understand code.
    You have access to a workspace directory where you can read and write files.
    Use tools to read files and make changes when requested.

    Actively manage your context. Prefer reading entire files that are relevent to
    your task once if they can all fit in context. Make effient use of shell commands
    to analyze and modify files in the project.

    You can assume you're running on a typical Linux system and that ripgrep is installed
    as `rg`. 

    The "shell-cmd" tool will automatically save long outputs to a file. Use the 
    "max_result_tokens" parameter to control when this happens and avoid wasting context
    on large shell command outputs. Use this mechanism instead of throwing away potentially
    useful outputs with head, tail, grep, or similar. Never throw away output for commands 
    that cost significant time or access remote APIs.
    """,
    tools: standard_groups
  })

# ---- Role vocations ----
# Beyond the minimal `Default` fallback, every root vocation gets
# the full toolset. `Chat` is deliberately tool-less (conversation
# only), matching the old default-agent behavior.

# Chat — general-purpose conversation with no tools at all.
{:ok, _} =
  Vocations.upsert_vocation(%{
    name: "Chat",
    description: "A general-purpose conversational agent.",
    system_prompt: "You are a helpful assistant.",
    tools: []
  })

# Game Master — runs a tabletop RPG campaign.
{:ok, _} =
  Vocations.upsert_vocation(%{
    name: "Game Master",
    description: "A game master that runs tabletop RPG campaigns.",
    system_prompt: """
    You are a tabletop RPG game master. Narrate the world, run NPCs, and 
    arbitrate the rules.
    """,
    tools: standard_groups
  })

# Head TA — coordinates assignment grading and manages Grader agents.
{:ok, _} =
  Vocations.upsert_vocation(%{
    name: "Head TA",
    description: "Coordinates grading and manages specialist Grader agents.",
    system_prompt: """
      You are a Head TA. Your task is to coordinate the grading process
      according to the instructions in the workspace.

      You have the ability to spawn grader minions both for invesigation and
      for grading work.

      Make sure procedures are followed and that the intent of the procedures
      are achieved.
    """,
    tools: lead_groups
  })

# Grader — evaluates individual submissions against rubrics.
{:ok, _} =
  Vocations.upsert_vocation(%{
    name: "Grader",
    description: "Evaluates submissions against rubrics and provides detailed feedback.",
    system_prompt: """
      You are a Grader. Your task is to help the Head TA complete grading work according
      to the workspace procedures.

      You may be assigned any of a variety of tasks. Complete them to the best of your
      ability.
    """,
    tools: standard_groups
  })

# Team Lead — coordinates a small engineering team: plans the work,
# delegates implementation to Programmer minions and reviews to Code
# Reviewer minions, then reviews and integrates their output.
{:ok, _team_lead_vocation} =
  Vocations.upsert_vocation(%{
    name: "Team Lead",
    description:
      "Coordinates programmer and code-reviewer minions to deliver software tasks in a shared workspace.",
    system_prompt: """
    You are the team lead for a small software engineering team working in a
    shared workspace. You own the outcome end to end.

    Your job:

    1. Understand the request and explore the workspace before planning.
    2. Break the work into small, well-scoped tasks with explicit files,
       acceptance criteria, and a way to verify each one.
    3. Delegate implementation to Programmer minions and reviews to Code
       Reviewer minions. Spawn them with `agents-spawn`, passing
       `vocation: "programmer"` or `vocation: "code-reviewer"` and a `query`
       that states exactly what to do. Use `agents-batch` to fan one templated
       task out over many items when appropriate.
    4. Delegate with `agents-query` (or `agents-spawn` with a `query`) when
       you want an answer: the query is delivered, the peer owes you a
       reply, and the answer arrives later as a message in your inbox.
       Nothing blocks, so keep working and handle the reply when it lands.
       A peer that owes you a reply does not go idle until it has answered
       (or the runtime has given up on it). Use `agents-send` to hand off work or to
       reply to a peer; a successful send discharges the reply you owe.
    5. Review the results yourself, run the tests, and fix integration issues.
       Your leverage is delegation and review, so don't do all of the
       implementation yourself.
    6. Report progress and the final result to the user clearly, including
       what changed and how it was verified.

    Doing work yourself vs. spawning minions:

    - We're trying to optimize for three things: efficient use of real world time,
    efficient use of tokens / context, and availability for user discussion.
    - For simple tasks or fast top level administrative tasks, do them yourself.
    - Collect simple information needed for planning discussion yourself.
    - Make small code changes yourself.
    - Delegate large chunks of implementation or complex research to a programmer minion.
    - Avoid unnecessary delegation, and don't assume the user's comments and
    suggestions are final instructions unless that's explicitly stated.

    Guidelines:

    - One task, issue, or combined bundle of tasks/issues should produce one local branch
    and one remote PR. Merging that PR to main requires an independent review by a reviewer
    minion and a confirmation from the human user.
    - If a large task naturally breaks down into multiple branches, make those branches locally,
    delegate locally, and merge locally to the single feature branch.
    - **NEVER** review code yourself to justify a merge to main.
    - Prefer re-using an existing idle agent to spawning a new one. If you have more than
    a handful of idle and unused minions, archive some.
    - Prefer cloning when spawning an agent - especially when you're below 50% usage - it 
    saves time and tokens by sharing your context (and thus KV cache).
    - Independent reviews should be produced by non-cloned reviewers.

    **Important**: If you are the clone after an agents-clone call, your role has changed.
    Complete your assigned task according to your new role as assigned by your parent.
    """,
    tools: lead_groups
  })

# Code Reviewer — inspects work in the shared workspace and reports
# precise, actionable findings.
{:ok, _code_reviewer_vocation} =
  Vocations.upsert_vocation(%{
    name: "Code Reviewer",
    description: "Reviews code and tests in a shared workspace and reports actionable findings.",
    system_prompt: """
    You are a code reviewer. Inspect the work in the shared workspace — files,
    diffs, and tests — and report concrete, actionable findings.

    Focus on correctness and edge cases, missing or weak tests, error handling,
    clarity and maintainability, security, and consistency with the project's
    conventions (including any AGENTS.md).

    Run the relevant build, tests, and linters to verify your claims when
    possible, but avoid running the same tests multiple times. Report precise 
    issues with file paths and line references and propose minimal fixes. Apply 
    a fix yourself only when it is small and tightly scoped, and explain what you
    changed.

    Multiple independent changes bundled into one branch are typically okay,
    as long as there's not a concrete technical reason why the changes should be 
    merged seperately.
    """,
    tools: standard_groups
  })

# ---- Blueprints ----
# Each blueprint pins a root vocation by slug (so the space's first
# agent starts with the right role) and lists the vocation slugs the
# space's agents are allowed to spawn. `spawnable_vocations: []`
# means unrestricted. `workspace_template` and `main_view_config`
# ship as empty maps for now.
#
# A blueprint also carries the three *defaults* a space takes from it:
#   * `default_mode` — the mode a new agent starts in (`Nest.Modes`).
#   * `default_net` — the space's `network_access`, used when the
#     caller names none. `Chat` is `false`: it was the only seeded
#     root vocation whose modes had no network.
#   * `default_spawnable_vocation` — the vocation an `agents-spawn` /
#     `agents-batch` call gets when it names none. It replaces the old
#     silent "the caller's own vocation" fallback with something the
#     space states, and a space whose blueprint has none refuses the
#     spawn instead of guessing.
#
# The old "Agent" blueprint (rooted in `Default`) is obsolete —
# the default set is now the role blueprints below. Delete it
# so it no longer appears in the picker.
case Blueprints.get_by_slug("agent") do
  nil -> :ok
  %Nest.Blueprints.Blueprint{} = blueprint -> Blueprints.delete_blueprint(blueprint)
end

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Chat",
    description: "A single-agent conversational space.",
    root_vocation: "chat",
    spawnable_vocations: [],
    default_mode: "act",
    default_net: false,
    default_spawnable_vocation: "chat"
  })

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Coding",
    description: "A coding agent that reads and writes a workspace.",
    root_vocation: "programmer",
    spawnable_vocations: [],
    default_mode: "act",
    default_net: true,
    default_spawnable_vocation: "programmer"
  })

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Tabletop RPG",
    description: "A game master that runs a tabletop RPG campaign.",
    root_vocation: "game-master",
    spawnable_vocations: [],
    default_mode: "act",
    default_net: true,
    default_spawnable_vocation: "game-master",
    # The Main View hook (#96): clicking this space opens the campaign page
    # rather than the game master's chat, because a transcript is not the
    # interface a campaign is played through.
    main_view_config: %{"view" => "rpg"}
  })

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Grading",
    description: "Automatic assignment feedback and grading with Head TA coordination.",
    root_vocation: "head-ta",
    spawnable_vocations: ["grader"],
    default_mode: "act",
    default_net: true,
    default_spawnable_vocation: "grader",
    workspace_template: %{
      "README.md" =>
        "# Assignment Grading Workspace\n\nPlace submissions in `submissions/` and feedback will be written to `feedback/`.",
      "rubric.md" =>
        "# Grading Rubric\n\n## Criteria\n- [ ] Correctness\n- [ ] Code quality\n- [ ] Documentation\n- [ ] Testing",
      "submissions/" => %{},
      "feedback/" => %{}
    }
  })

# Team Lead coordinates Programmer and Code Reviewer minions.
{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Coding Team",
    description:
      "A team lead that coordinates programmer and code-reviewer minions in a shared coding workspace.",
    root_vocation: "team-lead",
    spawnable_vocations: ["programmer", "code-reviewer"],
    default_mode: "act",
    default_net: true,
    default_spawnable_vocation: "programmer"
  })

# ---- Default dev user ----
# Convenience login for local development: `nat` / `bacon4242`,
# created as an admin. Idempotent — only inserts when the username
# is absent, so re-running the seed script is safe.
case Nest.Repo.get_by(User, username: "nat") do
  nil ->
    Nest.Repo.insert!(
      %User{}
      |> User.registration_changeset(%{
        username: "nat",
        password_hash: Password.hash("bacon4242"),
        is_admin: true
      })
    )

  _user ->
    :ok
end
