# Contributing to hotfpc

This guide is for people changing hotfpc itself. To use hotfpc, see the
[README](README.md) and the [quick start](docs/guides/quick-start.md). Agents also follow
[AGENTS.md](AGENTS.md).

## Toolchain

- **Free Pascal 3.2.2**, the release hotfpc is built and tested with:
  `sudo apt-get install fpc`, `brew install fpc` on a Mac with Apple silicon, or the
  installer from [freepascal.org](https://www.freepascal.org/download.html) for an Intel Mac
  and for Windows (win32 and win64). fpcres and ppudump come with it.
- **Python 3.9 or later**, for the scenarios and the reference check.
- **Lefthook**: `lefthook install` once per clone sets up the pre-commit hook.
- **Node.js**, only for the Markdown lint, in the version [Tooling](docs/internals/tooling.md)
  gives.

[Tooling](docs/internals/tooling.md) lists the rest, such as what recording the demo needs.

## Build and test

```sh
git clone https://github.com/frostney/hotfpc
cd hotfpc
./build.sh                                   # build/hotfpc and the unit tests
python3 tests/scenarios/check.py             # the 38 scenarios, about 2 minutes
python3 tests/agent/check.py                 # the agent on its own
python3 scripts/check-reference-docs.py      # docs/reference/ against the source
npx --yes markdownlint-cli2@0.24.0           # the Markdown lint
```

On Windows, `build.bat` takes the same arguments as `build.sh`. The installer's fpc builds
32-bit programs by default, so give it the 64-bit target, `build.bat -- -Twin64 -Px86_64`,
and run the scenarios with `HOT_DRIVER_OPTS` set to `-Twin64 -Px86_64`.

## When a change is done

The unit tests pass, `check.py` prints "38 of 38 cases as expected", and
`tests/agent/check.py` passes, on every system
the change can affect: macOS arm64, macOS x86-64, Linux x86-64, Linux arm64, and Windows
x86-64. Changes
to the agent, or to the checks of layouts and sizes, are tested with fpc 3.2.2 and 3.3.1.
[Testing](docs/internals/testing.md) explains the tests and how to add a scenario.

A change that adds an option or a `[hot]` line documents it in `docs/reference/`; the
reference check fails until it does. A change users can see goes into `CHANGELOG.md` under
`## Unreleased`.

## Ground rules

- **Three files.** The driver and its unit tests stay in `source/HotFPC.pas`, the agent in
  `source/HotFPC.Agent.pas`, and `source/HotFPC.rc` makes the agent a resource. No units
  split off and no `.inc` files: people copy `source/` into their own trees.
- **No build-tool dependency.** fpc and fpcres must build a copy of `source/`, so only units
  and tools that ship with fpc 3.2.2.
- **The agent is compiled by the user's fpc.** Keep it to what fpc 3.2.2 accepts, and
  don't let it use `SysUtils` or any unit that changes how a program reports runtime
  errors.
- **The output is an interface.** Keep every `[hot]` line and the agent's protocol stable:
  the scenarios and `scripts/record-demo.py` parse them.
- **Don't invent results.** A test outcome in the docs comes from a run.

## CI

`.github/workflows/ci.yml` runs on pull requests and on pushes to main: the build, the unit
tests and the scenarios on Linux x86-64, Linux arm64, macOS arm64, macOS x86-64 and Windows
x86-64 with
fpc 3.2.2, and a `docs` job with the reference check and the Markdown lint.

## Contributor docs

- [How it works](docs/internals/how-it-works.md): the driver, the agent, one save, each
  system. Read it before changing either.
- [Build system](docs/internals/build-system.md): `build.sh`, `build.bat`, the embedded
  agent.
- [Code style](docs/internals/code-style.md).
- [Tooling](docs/internals/tooling.md): the hook, the documentation checks, CI.
- [Testing](docs/internals/testing.md): the unit tests and the scenarios.
- [Releasing](docs/internals/releasing.md) and [recording the demos](docs/internals/demos.md).
