# Build system

hotfpc has no build-tool dependency. Anyone can copy `source/` and build it with fpc 3.2.2
or later and fpcres, which ships with fpc:

```sh
fpcres -of res -o source/HotFPC.res source/HotFPC.rc
fpc source/HotFPC.pas
```

For working on hotfpc itself, [`build.sh`](../build.sh) is the entry point, and
[`build.bat`](../build.bat) is the same for Windows:

```sh
./build.sh                       # hotfpc and the unit tests
./build.sh hotfpc                # only build/hotfpc
./build.sh tests                 # build and run the unit tests
./build.sh clean hotfpc          # remove build/ first
./build.sh hotfpc --production   # release settings
./build.sh hotfpc -- -Twin64 -Px86_64   # options after -- go to fpc
FPC=/path/to/fpc ./build.sh      # another compiler (default: fpc on PATH)
FPCRES=/path/to/fpcres ./build.sh   # another fpcres (default: fpcres on PATH)
```

On Windows, `build.bat` takes the same arguments and variables and builds `build\hotfpc.exe`.

## Targets

Targets run in the order given.

| Target | What it does | Output |
| --- | --- | --- |
| (none) | `hotfpc`, then `tests` | |
| `hotfpc` | writes `source/HotFPC.res`, then compiles `source/HotFPC.pas` | `build/hotfpc`, `build/hotfpc.exe` for a Windows target |
| `tests` | writes `source/HotFPC.res`, compiles `source/HotFPC.pas` with `-dHOTFPC_TESTS`, and runs it; fails if a check fails | `build/tests/hotfpc-tests` |
| `clean` | removes `build/` | |

Units go to `build/units/<name>/`. Everything under `build/` and `source/HotFPC.res` is
ignored by git.

## Modes

- **Development** (the default): `-gl -Co -Cr -Ct -CR -Sa`, which is line information plus
  overflow, range, stack and object checks and assertions.
- **Production** (`--production`): `-dPRODUCTION -O2 -Xs`.

Both modes pass `-B`, so every build compiles every unit. A plain `fpc` build gets fpc's
defaults.

There is no shared include file. `HotFPC.pas` starts with `{$mode delphi}{$H+}`, and the
checks and optimisation come from the command line. The agent is the exception: the user's
compiler builds it with the user's options, so it sets its own directives at the top of
`HotFPC.Agent.pas`. It turns overflow and range checks off, because it works with raw
addresses inside the user's program, and it turns optimisation off for fpc 3.3.1
(docs/how-it-works.md, "A compiler bug").

## The unit tests

The unit tests are at the end of `source/HotFPC.pas`, inside `{$ifdef HOTFPC_TESTS}`. They
test the driver's internals, and a program can't be used as a unit, so they're compiled
into hotfpc instead of hotfpc's own main block. A normal build leaves them out.

## The embedded agent

hotfpc carries the source of the agent, `source/HotFPC.Agent.pas`, as a resource
(docs/how-it-works.md, "Why the agent's source is embedded"). `source/HotFPC.rc` names the
file, fpcres compiles that into `source/HotFPC.res`, and `{$R HotFPC.res}` in `HotFPC.pas`
links it in. At run time the driver reads it back with `TResourceStream`.

fpc would compile the `.rc` file itself, but fpc 3.2.2 does that with `windres`, which it
doesn't ship on macOS or Linux. So the build scripts run fpcres first, on every system. fpc
looks for `HotFPC.res` next to `HotFPC.pas`, which is why it's written into `source/`.
Every build writes it again, so the binary always carries the agent it was built with.

## Release binaries

`.github/workflows/release.yml` builds `hotfpc` for macOS arm64, Linux x86-64 and Windows
x86-64 with fpc 3.2.2 (`./build.sh clean hotfpc --production`, and `build.bat` on Windows)
when a version tag is pushed. It attaches the archives and a checksum file to the GitHub
release.
