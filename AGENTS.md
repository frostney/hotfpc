# hotfpc: guide for contributors and agents

Hot reloading for Free Pascal programs. There are two parts:

- the driver: `source/HotFPC.pas`, the program you run;
- the agent: `source/HotFPC.Agent.pas`, a unit that hotfpc compiles into the user's
  program with the user's fpc.

Read [docs/internals/how-it-works.md](docs/internals/how-it-works.md) before changing
either. The code style is in [docs/internals/code-style.md](docs/internals/code-style.md),
the build in [docs/internals/build-system.md](docs/internals/build-system.md), the tools
in [docs/internals/tooling.md](docs/internals/tooling.md), and the tests in
[docs/internals/testing.md](docs/internals/testing.md). The contribution workflow is in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Layout

| Path | What |
| --- | --- |
| `source/HotFPC.pas` | the driver: everything but the agent, one program in sections, with its unit tests at the end (`-dHOTFPC_TESTS`) |
| `source/HotFPC.Agent.pas` | the agent unit: object file readers, binding, relocation, the per-system code |
| `source/HotFPC.rc` | makes the agent's source a resource of the driver; fpcres compiles it into `source/HotFPC.res` (not committed) |
| `build.sh`, `build.bat` | the build entry points, for Unix and for Windows; keep them doing the same |
| `tests/scenarios/` | end to end: `scenario.py` (27 programs and the edits saved into them), `check.py` (expected outcomes) |
| `examples/demo`, `examples/lwpt`, `examples/raylib` | the README's demo program; an lwpt package with a `hot` run task; a raylib program to play with |
| `scripts/record-demo.py` | records `docs/demo.cast` in tmux; `docs/demo.gif` and `docs/demo.mp4` are made from it |
| `docs/` | for people who use hotfpc, rendered as is: `index.md`, `guides/` (task-oriented), `reference/` (the complete surface: command line, output, environment, platforms, limits), `internals/` (for contributors); `meta.json` orders each folder. The demo recordings live here too |

## Build and test

```sh
./build.sh                                 # build hotfpc and run the unit tests
./build.sh tests                           # only the unit tests
python3 tests/scenarios/check.py [case...] # the scenarios, against build/hotfpc
HOT_DRIVER_OPTS="--fpc FPC" python3 tests/scenarios/check.py
```

A change is done when the unit tests pass and `check.py` prints "27 of 27 cases as
expected" on every system the change can affect: macOS arm64, Linux x86-64, Linux arm64,
and Windows x86-64 (`-Twin64 -Px86_64` with win64 units, under Wine or on Windows). For
Windows programs, `check.py` expects a restart in three cases where the other systems swap;
the comments in it explain why. Changes to the agent or to the checks of layouts and sizes
are tested with fpc 3.2.2 and 3.3.1.

## Rules

- Keep the source in its files: the driver and its tests in `HotFPC.pas`, the agent in
  `HotFPC.Agent.pas`, and `HotFPC.rc`. Don't split either into units and don't add `.inc`
  files; people copy them into their own trees.
- No build-tool dependency. fpcres and fpc must build a copy of `source/`
  (docs/internals/build-system.md), so use only units and tools that ship with fpc 3.2.2.
- The agent is compiled by the user's fpc. Keep it to what fpc 3.2.2 accepts (for example,
  `{$if defined(...)}` instead of `{$ifdef}...{$elseif}`), and don't let it use `SysUtils`
  or any unit that changes how a program reports runtime errors.
- Keep every `[hot]` line and the agent's protocol stable. The scenarios and
  `scripts/record-demo.py` parse them. A new option, `[hot]` line or `HOT_*` variable is
  documented in `docs/reference/` in the same change.
- The driver runs fpc in the user's current directory and removes only the leftover files
  that the compile created there.
- Don't invent results. When the docs state a test outcome, it comes from a run.
- Each topic in `docs/` has one page that owns it; other pages link to it. Docs describe
  the current state, checked against the source and real runs.
- If the output of `examples/demo` changes, record the demo again with
  `scripts/record-demo.py` (docs/internals/demos.md).
