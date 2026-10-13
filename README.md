# Nest

## System dependencies

`scripts/install-deps.sh` installs everything the build needs from the
system side: the Erlang/OTP 27 build prerequisites, Postgres (server plus
a login role for the current user), a working `bwrap`, and the usual
tooling. Supported targets are Ubuntu 24.04/26.04, Linux Mint 22.x and
Debian 13; anything else is refused up front.

```sh
sudo bash scripts/install-deps.sh
```

It is safe to re-run, and `--dry-run` prints what it would do without
doing it. The language runtimes come from mise (`.tool-versions`), so run
`mise install` afterwards.

## Development Server

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Migrations

**Run migrations at boot, or with the server stopped.** `Nest.Application`
starts `Ecto.Migrator` before `Nest.Agents.Supervisor`, so in a release
(where migrations are not skipped) every migration completes before any
agent process exists. That ordering is load-bearing for data migrations that
rewrite agent state: a running agent keeps its name in memory and resolves
its own row by name on every write, so a migration such as
`20261011000000_sanitize_agent_names` — which renames `agents` rows in place
— applied against a *live* server desynchronizes those agents (their
messages stop persisting) until they are restarted.

In development the boot-time migrator is skipped, so `mix ecto.migrate` is a
manual step: stop `mix phx.server` first (or expect to restart it after).

## License

Keep in mind that GNU AGPL means that if you host this software for
users, the source code link on the About page must point to the
actual corresponding source code of the version of this program
that's being run, provided to your users under the same license.

If you would like to negotiate alternate licensing that allows for
unpublished custom changes, send me an email.

Nest, Something About a Flock of LLM Agents
Copyright (C) 2026  Nat Tuck

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
