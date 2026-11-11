# hotfpc: guide for contributors and agents

Hot reloading for Free Pascal programs: a driver (`source/hotfpc.pas`) and an agent unit
that runs inside the program (`source/hotagent.pas`). `docs/how-it-works.md` explains the
design; read it before changing either part.

## Layout

| Path | What |
| --- | --- |
| `source/hotfpc.pas` | the driver: build, start, watch, compile, check interfaces, talk to the agent |
| `source/hotagent.pas` | the agent unit: object file readers, binding, relocation, the per-system code |
| `source/embed.pas` | writes the agent's source into `build/agentsource.inc` for the driver |
| `build.sh`, `build.bat` | build `bin/hotfpc` (`bin\hotfpc.exe`); `build.bat` has CRLF line ends |
| `test/scenarios/` | `scenario.py` (17 programs and the edits saved into them), `check.py` (expected outcomes) |
| `examples/demo`, `examples/lwpt` | the README's demo program; an lwpt package with a `hot` run task |
| `tools/record-demo.py` | records `docs/demo.cast` (tmux, vim, asciinema); `docs/demo.gif` and `docs/demo.mp4` are made from it |

## Build and test

```sh
./build.sh [FPC [options]]
python3 test/scenarios/check.py [case ...]
HOT_DRIVER_OPTS="--fpc FPC" python3 test/scenarios/check.py
```

A change is done when `check.py` prints "17 of 17 cases as expected" on every system the
change can affect: macOS arm64, Linux x86-64, and Windows x86-64 (`-Twin64 -Px86_64` with
win64 units, run under Wine or on Windows). For Windows programs, `check.py` expects a
restart in two cases where the other systems swap (see the comment in it).

## Rules

- The agent is compiled by the user's fpc. Keep it to what fpc 3.2.2 accepts (for example,
  `{$if defined(...)}` instead of `{$ifdef}...{$elseif}`), and build and test with 3.2 as
  well as 3.3.1 when touching it.
- The agent must not use `SysUtils` or any unit that changes how a program reports runtime
  errors. On Unix it uses `cthreads`, `baseunix` and `sockets`; on Windows only `system`
  and its own declarations.
- Both sources keep `{$optimization off}` until a released fpc-toolchain 3.3.1 includes
  patch 0122 (`docs/how-it-works.md`, "A compiler bug").
- The driver runs fpc in the user's current directory and removes only the leftover files
  that the compile created there.
- Don't invent results: when the docs state a test outcome, it comes from a run.
- If the program's output in `examples/demo` changes, record the demo again with
  `tools/record-demo.py` (see its docstring).
