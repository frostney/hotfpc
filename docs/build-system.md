# Build system

hotfpc has no build-tool dependency. Anyone can copy `source/` and build it with fpc
3.2.2 or later:

```sh
fpc -Fusource source/HotFPC.pas
```

For working on hotfpc itself, [`build.pas`](../build.pas) is the entry point. It's a
Pascal script that runs with InstantFPC, which ships with fpc:

```sh
instantfpc build.pas                    # clean development build: hotfpc and the unit tests
instantfpc build.pas hotfpc             # only build/hotfpc
instantfpc build.pas tests              # build and run the unit tests
instantfpc build.pas clean hotfpc       # remove build/ first
instantfpc build.pas --production       # release settings
instantfpc build.pas hotfpc -- -Twin64 -Px86_64   # options after -- go to fpc
FPC=/path/to/fpc instantfpc build.pas   # another compiler (default: fpc on PATH)
```

## Targets

| Target | What it does | Output |
| --- | --- | --- |
| (none) | `clean`, then `hotfpc`, then builds the tests without running them | |
| `hotfpc` | embeds the agent, then compiles `source/HotFPC.pas` | `build/hotfpc`, `build/hotfpc.exe` for a Windows target |
| `tests` | compiles every `source/*.Test.pas` and runs it; fails if any exits non-zero | `build/tests/` |
| `embed` | only writes `source/HotFPC.AgentSource.inc` | |
| `clean` | removes `build/`; runs first, wherever it's named | |

Units go to `build/units/<target>/`. Everything under `build/` is ignored by git.

## Modes

- **Development** (the default): line information (`-gl`) and, through
  [`source/Shared.inc`](../source/Shared.inc), overflow, range, stack and object checks and
  assertions.
- **Production** (`--production`): `-dPRODUCTION -O2 -Xs`, with the checks off.

Both modes pass `-B`, so every build compiles every unit.

All compiler directives live in `source/Shared.inc`, which every unit and program includes:
Delphi mode, `{$H+}`, read-only typed constants, the checks, and no optimisation for fpc
3.3.1 (docs/how-it-works.md, "A compiler bug"). The agent includes it too and then turns
overflow and range checks off for itself, because it works with raw addresses inside the
user's program.

## The embedded agent

`source/HotFPC.AgentSource.inc` holds the lines of `source/HotFPC.Agent.pas` and
`source/Shared.inc` as string arrays. The driver writes them out and compiles the agent
with the user's compiler (docs/how-it-works.md, "Why the agent's source is embedded").

`build.pas` regenerates the file before every build of hotfpc, and only writes it when it
changed. It's committed so that a plain `fpc` build of a copy of `source/` works. After
changing the agent or `Shared.inc`, commit the regenerated file with them. The pre-commit
hook does this for you.

## Release binaries

`.github/workflows/release.yml` builds `hotfpc` for macOS arm64, Linux x86-64 and Windows
x86-64 with fpc 3.2.2 (`instantfpc build.pas hotfpc --production`) when a version tag is
pushed. It attaches the archives and a checksum file to the GitHub release.
