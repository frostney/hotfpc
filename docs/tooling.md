# Tooling

| Tool | Version | Used for |
| --- | --- | --- |
| Free Pascal | 3.2.2 (the pinned compiler); also tested with fpc-toolchain's 3.2.4-rc and 3.3.1 | building hotfpc; the scenarios use it to build the test programs |
| fpcres | ships with fpc | turns the agent's source into a resource of hotfpc ([build-system.md](build-system.md#the-embedded-agent)) |
| Python | 3.9 or later | the scenario tests in `tests/scenarios/` |
| Lefthook | 1.5 or later | the pre-commit hook in [`lefthook.yml`](../lefthook.yml) (`lefthook install` once per clone) |
| tmux, vim, asciinema, agg, ffmpeg | any recent | recording the demo with `scripts/record-demo.py`; only needed to re-record |

Only fpc is needed to build hotfpc. Everything else is for working on it.

## The pre-commit hook

`lefthook.yml` runs `./build.sh hotfpc tests` before each commit that changes the source,
which builds hotfpc and runs the unit tests.

The scenarios take about a minute and a half, so CI runs them, not the hook. Don't bypass
the hook with `--no-verify` unless the maintainer agrees.

## CI

`.github/workflows/ci.yml` runs on every push and pull request. On Linux x86-64 and macOS
arm64 with fpc 3.2.2 it builds hotfpc, runs the unit tests and runs the scenarios. On
Windows it builds `hotfpc.exe` with `build.bat` and runs the unit tests.

`.github/workflows/release.yml` builds the release binaries for a version tag
([build-system.md](build-system.md#release-binaries)).
