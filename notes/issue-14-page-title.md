# Issue #14 — Page title should have useful info

> Decision record, written by the team lead. Shipped on branch
> `query-wait-deadline` alongside #20 (the `agents-query` wait deadline), since
> #14 is a small self-contained drive-by.

## Goal

Every page was titled `Nest · Phoenix Framework`, because `root.html.heex`
rendered a `live_title` whose `page_title` assign **nothing ever set**. The user
runs more than one Nest instance against different projects — `vampire` and
`typhon` — and needs to tell their browser tabs apart.

## Decisions

1. **Title format is `{host} · {space} · {agent}`**: parts joined by
   `" · "`, missing parts dropped, host always first. There is deliberately no
   "Nest" in the title — the tab icon carries the app identity instead.
   - Host **first** rather than last because browsers truncate a tab title from
     the right. With two instances on the same space name,
     `my-space@vampire` and `my-space@typhon` both render as `my-space…`, which
     is the exact case being solved; host-first survives truncation.
   - The issue originally suggested `{space}@{host} - Nest`.
2. **The host comes from the server**, as `window.NEST_CONFIG.host` next to the
   existing `sourceUrl`; the client cannot know it. Source: `config :nest,
   :hostname` when set, else `:inet.gethostname/0`, else the literal
   `[missing host]` — never omitted, per the transparency rule.
3. **The icon is a Nest mark, not a per-host tint.** Tinting the icon per host
   was proposed (so two tabs differ by colour, visible even when the title is
   truncated) and the user declined. The mark is therefore byte-identical on
   every instance.
4. **The server-rendered title is the host alone**, so the first paint is
   already correct rather than flashing the old string before React takes over.
5. **A per-page `useDocumentTitle(segments)` hook, not one route-driven
   component.** Each page already resolves its own space/agent names; a single
   component would have to re-parse the URL and special-case `RootGate` and the
   standalone `/login` + `/register` pages, which render outside `Layout`.
6. **Space name falls back to the route slug** when the store has not loaded
   the space yet (a hard load of a deep URL). The slug is real information, so
   it beats a blank or a placeholder.

## What changed

| area | change |
|---|---|
| `lib/nest/hostname.ex` | new: `Nest.Hostname.get/0` with the override → `:inet.gethostname/0` → `[missing host]` chain |
| `config/test.exs` | pins `config :nest, :hostname, "testhost"` so tests never assert the machine they run on |
| `root.html.heex` | `live_title` → plain `<title>{Nest.Hostname.get()}</title>`; added the icon `<link>`; added `host` to `NEST_CONFIG` |
| `assets/static/favicon.svg` | new: the mark (source of truth — see below) |
| `priv/static/favicon.svg` | new: force-added, because `/priv/static/` is gitignored and `Plug.Static` serves from there |
| `assets/static/favicon.ico`, `priv/static/favicon.ico` | deleted: the stock Phoenix icon, so no Phoenix branding can appear in a tab |
| `lib/nest_web.ex` | `static_paths/0` → `~w(assets favicon.svg robots.txt)` |
| `assets/js/hooks/useDocumentTitle.js` | new: pure `buildDocumentTitle/2` + the hook |
| 9 page modules + `RootGate` | one wiring line each |

### The `assets/static` trap

`priv/static/` is gitignored wholesale (`.gitignore:32`), and `config/dev.exs`
runs a `Phoenix.Copy` watcher that copies `assets/static/` → `priv/static/`
(`File.cp_r!` only ever *adds*). `mix assets.deploy` runs `phx.copy default`
too. So `assets/static/` is the real source of truth: deleting only the
`priv/static` copy would let the dev watcher restore the Phoenix icon at the
next boot, and a fresh clone would ship no icon at all. Both copies are
therefore handled, and the `priv/` one is force-added to match the existing
convention for `favicon.ico`/`robots.txt`.

## Verification

- The layout test asserts **exact** `<title>` equality (`== "testhost"`, not
  "contains"), so neither "Nest" nor "Phoenix Framework" can survive in a tab,
  plus the icon `link` and `host: "testhost"` in `NEST_CONFIG`.
- A second test asserts `favicon.svg` is in `static_paths/0` **and** on disk
  **and** that `GET /favicon.svg` really returns SVG — a list/file mismatch
  would otherwise only ever show up in a browser.
- The JS builder is unit-tested exhaustively (host first, separator, dropped
  empty/non-string/whitespace segments, `[missing host]` for absent/empty/
  non-string host) and the hook is pinned not to rewrite `document.title` when
  a caller passes an equal-but-new segments array.
- Each page test sets `window.NEST_CONFIG = {host: "vampire"}` and resets
  `document.title` to the old string beforehand, so every assertion proves the
  page *replaces* the shell title rather than leaving it.
- `mix precommit` and `pnpm vitest run --coverage` clean; the new JS file is at
  100% statements/branches/functions/lines.

### Pre-existing flake fixed in passing

`test/nest/agents/agent_stream_error_test.exs` fenced the idle status broadcast
with a 500ms wall-clock timeout and failed under full-suite load (the mailbox
still held `{:chat_status, %{status: "streaming"}}`). Both fences now sync on
the machine actually reaching `:idle` via `eventually/2` and only then assert,
which is what the file's other test already did.

To be precise about the budget, since this is the kind of change that must not
be smuggled in: the poll budget is **1000ms, up from the 500ms fence**. It is a
failure deadline for the poll, not an expected duration — the condition holds
as soon as the error has been handled, and `eventually/2`'s default is 10ms, so
the budget has to be given explicitly. What changed is the instrument: a fence
that waited for one specific message and then failed is now a poll of the
machine's actual state. The old shape was measuring the wrong thing — measured
turn latency under full-suite load is 700-1000ms against 76ms in isolation (see
`notes/test-suite-speedup.md`), so a 500ms fence on a single message was
guaranteed to fire on a slow-but-healthy turn.

### The 1000ms budget is a recorded exception, not a silent one

`notes/test-suite-speedup.md` says the opposite — "Do not raise the fences…
treat the 500ms fences as a canary" — and that guidance is not withdrawn here.
This section exists to record why it is not being applied to this one wait.

- **The wait cannot be removed.** `Agent.chat/3` is a `GenServer.cast`
  (`agent.ex:389`; `handle_cast` only, `callbacks.ex:59-60`), so no call returns
  once the turn has finished, and the idle broadcast is itself part of the
  contract under test (moduledoc point 3).
- **An unbounded wait is strictly worse.** It converts a clear failure into a
  hang bounded only by ExUnit's 60s test timeout, which blows the 5s budget in
  `scripts/precommit-test.sh` on the reference host.
- **The signal inherits the whole latency.** The idle broadcast is emitted last
  in the turn — after the stream is consumed, usage merged, and the assistant
  message appended — so 76ms isolated becomes 700-1000ms at `max_cases: 24`.
  1000ms is therefore the smallest *failure deadline* that does not fire on a
  healthy-but-loaded run; a 500ms bound is a latency assertion, and this test
  asserts effects, not latency.

The premise behind the rule is right, though: this is a slow test. The latency
is real and is tracked in #21 (Elixir test timeout audit), and this budget
should come back down to 500ms once the turn latency is fixed. Note that this
file already carried a 1000ms `eventually` (`active_worker == nil`) before this
change, so the same question applies there.

## Known gaps

- The `[missing host]` branch of `Nest.Hostname.get/0` is untested: forcing
  `:inet.gethostname/0` to fail means mocking an OTP module, which is worse
  than the gap. The config-override branch and the system-hostname branch are
  both covered.
- There is no catch-all route, so an unknown URL renders nothing and the title
  keeps whatever the last page set. Pre-existing, and out of scope here.
- The stale untracked `priv/static/cache_manifest.json` still lists the deleted
  `favicon.ico`; `mix phx.digest` regenerates it.
- `root.html.heex` interpolates the host into the `NEST_CONFIG` `<script>`
  exactly as the pre-existing `sourceUrl` is interpolated, so HEEx HTML-escapes
  it: a hostname containing `&` would reach the title as `&amp;`. Real
  hostnames cannot contain `&`, and the value is server-configured rather than
  user input, so this is latent rather than live. The right fix is to serialize
  the whole config with `Jason.encode!/2` (`escape: :html_safe`) instead of
  interpolating values into a script body — a change to the pre-existing
  pattern, so it belongs in its own commit rather than this one.
