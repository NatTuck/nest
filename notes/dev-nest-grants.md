# The project's own `.nest` grants

`.nest` is human-authored project config and is masked read-only into every
agent's sandbox (`Nest.ConfigFile`), so an agent cannot edit it — which is why this
note exists rather than a comment in the file.

The grants are:

- `~/.cache/rustler_precompiled` — `rustler_precompiled` writes there on the first
  compile of a NIF crate.
- `~/.hex` — `mix deps.get` and `mix compile` write the hex registry and tarballs.
- `~/.local/share/pnpm` — **deliberately the whole pnpm home, not `.../store`.**

The last one is wider than the content store on purpose. `package.json`'s
`devEngines.packageManager` is pinned with `onFail: "download"`, so the *engine*
store (`~/.local/share/pnpm/package-manager-store`) needs write access too, not
just the content store at `~/.local/share/pnpm/store` — and the pnpm pin is about
to move to 12, which lays its directories out differently again. Narrowing the
grant to `.../store` makes `pnpm install` fail under `mix precommit`.

So it is not scope creep, and it should not be "tidied" back to the store path
without running `mix precommit` on a host with no warm pnpm store.
