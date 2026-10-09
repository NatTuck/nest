# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Idempotent: uses `Vocations.upsert_vocation/1` so re-running
# this script updates existing rows (system prompts, modes,
# tools) in place rather than failing on duplicate names or
# creating a second row. Safe to re-run after editing any
# vocation field below.
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
all_groups = ["file", "shell", "context", "agents"]

# Default - minimal vocation for agents without a specific role.
# Used as the fallback for any test or runtime path that needs a
# vocation but doesn't care which one. Single "chat" mode with the
# context tools only (no filesystem, no network).
{:ok, _default_vocation} =
  Vocations.upsert_vocation(%{
    name: "Default",
    description: "A minimal default vocation for agents without a specific role",
    system_prompt: "You are a helpful assistant.",
    tools: ["context", "agents"],
    modes: %{
      "chat" => %{
        "description" => "General conversation.",
        "caps" => %{
          "net" => false,
          "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
        }
      }
    }
  })

# Programmer - code-focused agent with tools and workspace.
# Two modes:
#   - "build": can read/write the workspace, run shell commands,
#              and access the network (for fetching docs, packages, etc.)
#   - "plan":  read-only; explore the workspace without making changes
# Network is enabled in both modes.
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
    useful outputs with head, tail, grep, or similar for commands that cost significant time
    or access remote APIs.
    """,
    tools: all_groups,
    modes: %{
      "build" => %{
        "description" => """
        You have write access to the workspace. You can make modifications as appropriate. Don't make extra changes the user didn't request.
        """,
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
        }
      },
      "plan" => %{
        "description" => """
        You have read-only access to the workspace. You are free to make tool calls, but workspace writes will fail because you're supposed to
        be inspecting the workspace but not changing it right now.
        """,
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
        }
      }
    }
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
    tools: [],
    modes: %{
      "chat" => %{
        "description" => "General conversation.",
        "caps" => %{
          "net" => false,
          "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
        }
      }
    }
  })

# Game Master — runs a tabletop RPG campaign.
{:ok, _} =
  Vocations.upsert_vocation(%{
    name: "Game Master",
    description: "A game master that runs tabletop RPG campaigns.",
    system_prompt:
      "You are a tabletop RPG game master. Narrate the world, run NPCs, and arbitrate the rules.",
    tools: all_groups,
    modes: %{
      "chat" => %{
        "description" => "General conversation.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
        }
      }
    }
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
    tools: all_groups,
    modes: %{
      "plan" => %{
        "description" => "Read-only access to workspace.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
        }
      },
      "act" => %{
        "description" => "Full workspace access.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
        }
      }
    }
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
    tools: all_groups,
    modes: %{
      "plan" => %{
        "description" => "Read-only access to workspace.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
        }
      },
      "act" => %{
        "description" => "Full access to workspace.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
        }
      }
    }
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
    4. Use `agents-query` (or `agents-spawn` with a `query`) when you need a
       result before continuing; pass `async: true` to either to keep working
       while the answer is produced and receive it later as a message in your
       inbox, and use `agents-wait` to wait for a peer to finish. Use
       `agents-send` to hand off work you don't need to block on.
    5. Review the results yourself, run the tests, and fix integration issues.
       Your leverage is delegation and review, so don't do all of the
       implementation yourself.
    6. Report progress and the final result to the user clearly, including
       what changed and how it was verified.

    You should not be doing significant work on the project yourself. Any codebase 
    investigation or non-trivial code changes must be delegated to a minion.

    To reiterate:

    - **NEVER** write code yourself.
    - **NEVER** review code yourself to justify a commit, push, PR, or merge.
    - You generally should not be reading code. Delegate it.
    """,
    tools: all_groups,
    modes: %{
      "build" => %{
        "description" => "Full workspace access for reviewing and integrating changes.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
        }
      },
      "plan" => %{
        "description" => "Read-only workspace access for planning and inspection.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
        }
      }
    }
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
    possible. Report precise issues with file paths and line references and
    propose minimal fixes. Apply a fix yourself only when it is small and
    tightly scoped, and explain what you changed.
    """,
    tools: all_groups,
    modes: %{
      "build" => %{
        "description" => "Full workspace access so you can run tests and apply small fixes.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
        }
      },
      "plan" => %{
        "description" => "Read-only workspace access for inspection.",
        "caps" => %{
          "net" => true,
          "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
        }
      }
    }
  })

# ---- Blueprints ----
# Each blueprint pins a root vocation by slug (so the space's first
# agent starts with the right role) and lists the vocation slugs the
# space's agents are allowed to spawn. `spawnable_vocations: []`
# means unrestricted. `workspace_template` and `main_view_config`
# ship as empty maps for now.

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
    spawnable_vocations: []
  })

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Coding",
    description: "A coding agent that reads and writes a workspace.",
    root_vocation: "programmer",
    spawnable_vocations: []
  })

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Tabletop RPG",
    description: "A game master that runs a tabletop RPG campaign.",
    root_vocation: "game-master",
    spawnable_vocations: []
  })

{:ok, _} =
  Blueprints.upsert_blueprint(%{
    name: "Grading",
    description: "Automatic assignment feedback and grading with Head TA coordination.",
    root_vocation: "head-ta",
    spawnable_vocations: ["grader"],
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
    spawnable_vocations: ["programmer", "code-reviewer"]
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
