# Build system

hotfpc has no build-tool dependency. Anyone can copy `source/` and build it with fpc
3.2.2 or later:

```sh
fpc source/HotFPC.pas
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
| `tests` | compiles `source/HotFPC.pas` with `-dHOTFPC_TESTS`, which includes the unit tests in `source/HotFPC.Test.inc`, and runs it; fails if a check fails | `build/tests/hotfpc-tests` |
| `embed` | only writes `source/HotFPC.AgentSource.inc` | |
| `clean` | removes `build/`; runs first, wherever it's named | |

Units go to `build/units/<target>/`. Everything under `build/` is ignored by git.

## Modes

- **Development** (the default): `-gl -Co -Cr -Ct -CR -Sa`, which is line information plus
  overflow, range, stack and object checks and assertions.
- **Production** (`--production`): `-dPRODUCTION -O2 -Xs`.

Both modes pass `-B`, so every build compiles every unit. A plain `fpc` build gets fpc's
defaults.

There is no shared include file. `HotFPC.pas` starts with `{$mode delphi}{$H+}`,
and the checks and optimisation come from the command line. The agent is the exception:
the user's compiler builds it with the user's options, so it sets its own directives at
the top of `HotFPC.Agent.pas`. It turns overflow and range checks off, because it works
with raw addresses inside the user's program, and it turns optimisation off for fpc 3.3.1
(docs/how-it-works.md, "A compiler bug").

## The embedded agent

`source/HotFPC.AgentSource.inc` holds the lines of `source/HotFPC.Agent.pas` as a string
array. The driver writes them out and compiles the agent with the user's compiler (docs/how-it-works.md, "Why the agent's source is embedded").

`build.pas` regenerates the file before every build of hotfpc, and only writes it when it
changed. It's committed so that a plain `fpc` build of a copy of `source/` works. After
changing the agent, commit the regenerated file with it. The pre-commit
hook does this for you.

## Release binaries

`.github/workflows/release.yml` builds `hotfpc` for macOS arm64, Linux x86-64 and Windows
x86-64 with fpc 3.2.2 (`instantfpc build.pas hotfpc --production`) when a version tag is
pushed. It attaches the archives and a checksum file to the GitHub release.
