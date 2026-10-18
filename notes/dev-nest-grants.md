# The project's own `.nest` grants

`.nest` is human-authored project config and is masked read-only into every
agent's sandbox (`Nest.ConfigFile`), so **an agent cannot edit it**. That is why
this note exists rather than a comment in the file, and why the change at the
bottom has to be made by a human.

## The grants

- `~/.cache/rustler_precompiled` — `rustler_precompiled` writes there on the first
  compile of a NIF crate.
- `~/.hex` — `mix deps.get` and `mix compile` write the hex registry and tarballs.
- `~/.local/share/pnpm/store` — the pnpm **content** store.
- `~/.local/share/pnpm/package-manager-store` — pnpm's **engine** store.
  `package.json` pins `devEngines.packageManager` with `onFail: "download"`, so a
  cold or mismatched engine has to be downloaded into that directory or
  `pnpm install` fails under `mix precommit`. The pin is about to move to 12,
  which lays its directories out differently again.

## Why `~/.local/share/pnpm` itself is **not** granted

The pnpm home also contains `bin/`, and `bin/` may be on the human's `PATH` ahead
of `/usr/bin`. A writable `bin/` is a write primitive into the *human's* shell: an
`act` agent could drop `git`, `node` or `mix` there and the next command the human
runs outside the sandbox would execute it. That is worse than anything the
config-file mask protects, so the two stores are granted by name and the parent
directory is not.

## The change (needs a human, because of the mask)

Replace the single `~/.local/share/pnpm` mount with these two:

```toml
[[mount]]
path   = "~/.local/share/pnpm/store"
mode   = "rw"
create = true

[[mount]]
path   = "~/.local/share/pnpm/package-manager-store"
mode   = "rw"
create = true
```
