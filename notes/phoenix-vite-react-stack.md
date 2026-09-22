# Phoenix + Vite + React Stack

How to replicate the basic stack used by Nest in a fresh Phoenix app. Intended
to be readable in isolation — drop into any opencode session.

## What this stack is

A Phoenix 1.8 server that serves a React single-page app. React Router owns
all client-side routing; Phoenix serves the shell HTML, static assets, and
JSON APIs (and channels if you add them). No LiveView pages.

| Layer            | Choice                                        |
| ---------------- | --------------------------------------------- |
| Web framework    | Phoenix 1.8 (`--no-live`)                     |
| HTTP             | Bandit                                        |
| DB               | Ecto + PostgreSQL (skip with `--no-ecto`)    |
| JS bundler       | Vite 6                                        |
| JS framework     | React 19 + react-router-dom 7                 |
| Styling          | Tailwind v4 (via `@tailwindcss/vite`)         |
| State            | zustand                                       |
| JS pkg manager   | pnpm 11 (workspaces at `assets/pnpm-workspace.yaml`) |
| JS lint/format   | Biome 2                                       |
| JS tests         | Vitest + Testing Library + jsdom              |
| Elixir lint      | Credo (`strict: true`)                        |
| Static copy      | `phoenix_copy` for `assets/static → priv/static` |
| Live reload      | `phoenix_live_reload` watching `priv/static/assets/**` |

## 1. Generate the app

```
mix phx.new my_app --no-live
```

Then delete the esbuild Tailwind setup that Phoenix 1.8 still ships with:

- Remove `config :esbuild` and `config :tailwind` blocks from
  `config/config.exs`.
- Remove the esbuild-related aliases (`esbuild.build`, `esbuild.deploy`,
  `tailwind.*`) from `mix.exs`.
- Delete the generated `assets/` directory — we are replacing it wholesale.

## 2. Recreate `assets/`

The new layout, top to bottom:

- `assets/package.json` — `"type": "module"`, `dev`/`build`/`test` scripts
  that call `vite`, `vite build`, `vitest run`. Declares React, react-router,
  zustand, phoenix (for the Vite alias resolver) as deps; vite plugin-react,
  tailwindcss + @tailwindcss/vite, @tailwindcss/typography, biome, vitest +
  coverage, testing-library, jsdom, and the rollup commonjs plugin as
  devDeps. `devEngines.packageManager` pinned to pnpm.
- `assets/pnpm-workspace.yaml` — allowBuilds for `canvas`, `esbuild`;
  `es5-ext` off.
- `assets/biome.json` — formatter + linter, recommended rules, double
  quotes, semicolons, `vcs.root` pointing at `../` so the repo-level
  `.gitignore` is honored.
- `assets/vite.config.ts` — `base: "/assets/"`, plugins `react()` +
  `tailwindcss()` + `commonjs()` (for CJS vendor), `outDir:
  ../priv/static/assets`, entry `js/app.js`, asset filenames route
  `.css` → `css/app.css`, images → `images/[name]-[hash][extname]`,
  fonts → `fonts/...`. Aliases: `@` → `assets/js`, `@css` → `assets/css`,
  `phoenix` / `phoenix_html` / `phoenix_live_view` → the corresponding
  files under `deps/<dep>/priv/static/`. Test block sets up jsdom + a
  Vitest setup file with 90% coverage thresholds.
- `assets/tsconfig.json` — minimal, `allowJs`, `noEmit`, baseUrl `.`,
  includes `js/**/*`. Mostly there so editors autocomplete the phoenix
  JS API.
- `assets/css/app.css` — single file with `@import "tailwindcss"
  source(none)`, `@source` rules pointing at `../css`, `../js`, and
  `../../lib/my_app_web`, plus a `dark` custom variant keyed off
  `[data-theme=dark]`.
- `assets/js/app.js` — entry. Imports `phoenix_html`, imports the CSS,
  calls `initApp(document.getElementById("root"))` on `DOMContentLoaded`.
  Also wires up the phoenix live reloader dev-only editor-click handlers
  if you want them.
- `assets/js/root.jsx` — `createRoot(...).render(<StrictMode><App/></StrictMode>)`.
- `assets/js/App.jsx` — `createBrowserRouter` with a `<Layout>` (sidebar +
  `<Outlet>`) and whatever routes you want.
- `assets/js/socket.js` — optional phoenix `Socket` singleton (only if
  you need channels).
- `assets/static/` — favicon, robots.txt, anything you want copied to
  `priv/static/` verbatim by `phoenix_copy`.
- `assets/vendor/` — for raw JS you want Vite to bundle via the commonjs
  plugin (e.g. topbar).

## 3. Elixir wiring

### `mix.exs`

Add `phoenix_copy` as a `:dev`-only dep. Replace the esbuild aliases
with the `assets.*` aliases that shell out to `pnpm` via `cmd --cd
assets`. Keep the `setup` alias that chains `assets.setup` +
`assets.build` after `deps.get`/`ecto.setup`.

### `config/config.exs`

Already emptied by step 1. Nothing else to add at the root level.

### `config/dev.exs`

Configure `phoenix_copy` (`source: assets/static/`, `destination:
priv/static/`, `debounce: 100`). In `MyAppWeb.Endpoint`, set `watchers:
[copy: {Phoenix.Copy, :watch, [:default]}, vite: ...]` where the vite
watcher shells out to `pnpm exec vite build --watch --mode
development` from inside `assets/`. Set `live_reload.patterns` to match
`priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$` — that is
what triggers browser refresh when Vite (or phoenix_copy) writes
output.

### `lib/my_app_web/components/layouts/root.html.heex`

Replace the esbuild asset tags with two `phx-track-static` tags
pointing at `~p"/assets/css/app.css"` and
`~p"/assets/js/app.js"` (`<script defer type="module">`).

### `lib/my_app_web/router.ex`

Keep the `:browser` pipeline. Add two routes under the same scope:
`get "/", PageController, :home` and `get "/*path",
PageController, :home` (catch-all so React Router gets every URL).

### Page template

`lib/my_app_web/controllers/page_html/home.html.heex` is a single
`<div id="root" class="h-screen"></div>` — the React app mounts into
it.

## 4. Credo

Nest ships a `.credo.exs` that is `strict: true` and adds custom
checks under `test/support/credo/`. For a fresh app:

- Add `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` to
  `mix.exs`.
- Run `mix credo.gen.config` once to scaffold `.credo.exs`, then flip
  `strict: true` so warnings become hard failures.
- Add `credo` to the `precommit` mix alias so lint runs on every
  precommit (and in CI).

`strict: true` matters: it surfaces every stylistic warning as an
error, which is what makes the precommit gate meaningful.

## 5. `precommit` mix alias

The single gate the repo expects to pass before any commit. Chain
(in order): `compile --warnings-as-errors`, `deps.unlock --unused`,
`format`, `credo`, `mix test` (with a hard `timeout 5`), JS-side
`pnpm biome ci`, then `mix test --cover`, then `assets.test` (Vitest
with coverage).

## 6. Commands

```
mix setup                  # deps + db + pnpm install + initial Vite build
mix phx.server             # Phoenix on :4000; vite --watch via watchers
mix assets.deploy          # prod: vite build + phx.copy + phx.digest
mix assets.check           # biome
mix assets.test            # vitest run --coverage
mix precommit              # the full gate
```

## 7. What this guide intentionally does not cover

- shadcn/ui (`components.json`, `lib/utils.js`, the Tailwind shadcn
  preset) — add separately if needed.
- `@llamaindex/chat-ui`, `@ai-sdk/react` — Nest-specific.
- Phoenix channels, presence, LiveView JS hooks — not part of the
  base stack.
- Auth, scopes, sessions — generated by `phx.new`; tweak as needed.
- Any of Nest's agent / LLM / compaction machinery.

## 8. Conventions to keep

- JS lives only in `./assets/`. If you see a `package.json` in the
  project root, something has gone wrong — delete it.
- Always `cd assets` before any `pnpm` command.
- Never run dev servers (`mix phx.server`, `npx vite`); the user
  manages those.
- The `precommit` alias is the contract — code that doesn't pass it
  doesn't ship.