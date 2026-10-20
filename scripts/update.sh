git pull
mix deps.get
(cd assets && pnpm install)

# `priv/static` is generated and not tracked: `phx.copy` puts `assets/static/`
# (favicon, robots.txt) there and vite writes `priv/static/assets/`. Dev mode
# serves from it, so both steps have to run here or the app boots with a
# missing favicon and no JS/CSS.
mix phx.copy default
mix assets.build

mix ecto.migrate
mix run priv/repo/seeds.exs
