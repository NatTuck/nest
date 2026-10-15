git pull
mix deps.get
(cd assets && pnpm install)
mix ecto.migrate
mix run priv/repo/seeds.exs
