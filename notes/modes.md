# The two modes

`plan` and `act`. They are **code constants** (`Nest.Modes`), not per-vocation
data, and a mode is a **per-agent runtime property** rather than something the
vocation or the message decides.

## What each mode may do

| | `plan` | `act` |
|---|---|---|
| `caps.fs.write` | `["/tmp"]` | `["/tmp", ":workspace"]` |
| may change the workspace | no | yes |
| everything else | identical — the network is the *space's*, and the read set is the same | |

`plan` is about *effects*, not only writes. An HTTP request that creates
something is a change no sandbox can see, so the prompt says the restriction is
about more than what the tools allow. The catalog's one space-specific sentence
says whether anything enforces it at all: under `bwrap` and `docker` the sandbox
does (a write outside the scratch directory fails), and in a `"none"` space
nothing does, so keeping to it is on the agent. "Writes will fail" would be a lie
in a `none` space.

The catalog is a constant plus two properties that cannot change for a given
agent (whether it has tools, and whether its space can enforce anything), which
is what keeps the system message's bytes stable — and therefore the prefix cache
intact. A mode change never touches the system message; it travels on the
messages (below).

## How an agent learns its own mode

Every message an agent receives states **the recipient's** mode:

* a user message as a `[mode: <mode>]\n` prefix;
* a message from another agent in its header,
  `[Message from agent "NAME" | mode: <mode>]\n`.

Both are the mode *at delivery* — the mode the turn will run in — not the
sender's, and not a request to change anything. That is the only mechanism by
which an agent whose inbox is all peer traffic learns its own mode.

The UI drops the header's copy from the display when it agrees with the row's
`mode` badge (which shows the same value), exactly as it drops the `[mode: X]`
prefix; a header that *disagrees* keeps its text, so a disagreement stays visible
rather than being silently resolved either way
(`assets/js/utils/agentHeader.js`).

## How a mode changes

* **Inherited at spawn.** A child gets its parent's current mode unless the
  spawn names one.
* **The human, on any agent.** The UI selector pushes `set_agent_mode`; the
  change applies immediately (the mode is persisted, so it does not have to ride
  the next message).
* **An ancestor, on a descendant.** It rides the send tools as an optional
  `set_mode` (`"mine" | "plan" | "act"`, where `"mine"` is the sender's current
  mode), so the change and the instruction that depends on it arrive together.
* **From the next turn, never mid-turn.** The mode is applied at the drain, and
  `Turn.prepare/1` rebuilds `ctx.mode`/`ctx.caps` from `state.live.mode` before
  each step — so the *next* turn runs in the new mode and the ongoing one is not
  re-resolved underneath its remaining tool calls. A batch that is not consumed
  (a decline, a park, a block) does not keep the mode
  (`Turn.restore_undelivered_mode/3`).
* **Announced.** A `[Nest notice]` message in the target's transcript names the
  actor and the new mode — for the human's selector and for another agent's
  `set_mode`. A mode carried on a message the agent itself received is stated by
  that message's own `[mode: X]` prefix (or its header), so it gets no second
  notice.
* **Stated twice on the wire, once in the UI — deliberately.** A peer delivery
  carries the recipient's mode in *both* the user-role row's `[mode: X]` prefix
  and the `[Message from agent … | mode: M]` header. That is not redundancy to be
  tidied away: the prefix is what the runtime's mode machinery reads and the
  header is what a reader sees, and the UI drops whichever copy agrees with the
  row's badge so that a disagreement stays visible
  (`assets/js/utils/agentHeader.js`).
* **Never propagated.** A parent's own change does not touch existing
  descendants: the user flipping the root to `plan` for a planning discussion
  must not jam background workers that are mid-task in `act`.

## The monotone rule

One place: `Nest.Agents.Agent.ModeAuthority`, which every mode-setting path goes
through — the human's selector, a message's `set_mode`, and the spawn. It decides
`:ok | {:error, reason}` from who is asking and who is being asked about:

| actor | target | may set |
|---|---|---|
| the human | anything, including itself | anything, including raising |
| an agent | **itself** | nothing — self-escalation, even by sending itself a `set_mode` |
| an agent | a **descendant** | a mode it is in itself, or a less permissive one (`Nest.Modes.allows?/2`) |
| an agent | anyone else | nothing |

The spawn is the same rule: a `plan` parent must not spawn an `act` child, nor
spawn one and then raise it. A refusal reaches the sender as a tool error naming
why, never silently.

## Where the state lives

**No mode data is in the database.** The modes are a code constant
(`Nest.Modes`): their names, their ordering, their caps and the catalog the
system prompt carries all live there, and `vocations.modes` — the JSONB column
that used to hold them per vocation — no longer exists. A vocation is its prompt
and its tools. A blueprint holds only *defaults*: `default_mode`, `default_net`
and `default_spawnable_vocation`.

What the database holds is the one thing that is genuinely per agent: the mode
that agent is in. `agents.mode` (string, `null: false`, default `"act"`), seeded
at creation from the blueprint's `default_mode`. `live.mode` is initialized from
the row, and a restart **restores the row's mode** rather than the default — a
child spawned read-only must not be widened by a restart. The mode is exposed to
the UI as `currentMode`, alongside `modes` and `defaultMode` from `Nest.Modes`.
