# hotfpc

Hot reloading for Free Pascal. Save a unit while your program runs, and the program carries
on with the new code and everything it had: its variables, objects, open files and threads.
If an edit changes something the running program depends on, such as a variable's size,
hotfpc names the declaration in the way and leaves the program running as it was.

![hotfpc running examples/demo: scene.pas is edited in vim on the left while the program keeps running on the right](docs/demo.gif)

This is a real run of [`examples/demo`](examples/demo) on macOS arm64 with fpc 3.3.1
([video](docs/demo.mp4), [asciinema cast](docs/demo.cast)), recorded in tmux. On the right,
a shell runs `hotfpc --log hot.log demo.pas`, and the program's output and hotfpc's `[hot]`
lines appear there. On the left, `scene.pas` is open in vim, and four edits get typed in and
saved with `:w`.

hotfpc's own timings from `hot.log` run below vim. They show how long each save took to
swap, and how much of that went to settling, compiling, the interface check and loading into
the program.

The first three edits change a character, a step size and a colour. Each one is swapped in
about 100 ms after the save, and the score keeps counting from where it was. The fourth
turns the score from an `Integer` into an `Int64`. A running program can't change the size
of a variable it already has, so hotfpc asks for a restart and the program keeps going.

[`scripts/record-demo.py`](scripts/record-demo.py) types every keystroke into the shell and
vim with `tmux send-keys`.

## For rapid development

hotfpc is for the edit-and-run loop while you develop. Change a routine, save, and see the
result in the running program, without rebuilding, restarting and finding your way back to
where you were. It pays off most in programs that run for a while and build up state: games,
servers, simulations, tools with a long setup, and anything you tune by eye.

Build what you ship with plain fpc. A program built by hotfpc carries the agent and keeps
its symbols, which you don't want in a release.

hotfpc wraps fpc and nothing else. You don't need a build tool or a C compiler, and you
don't change your program for it. It's a single program written in Pascal.

## Why there's an agent

Free Pascal has no way to replace code in a running program. There's no runtime linker for
units, and shared libraries only help if you write your program around them, with the code
to reload in a library and its state somewhere else. hotfpc is meant for the program you
already have.

So the new code has to go in from inside the process. Another process isn't always allowed
to write there: macOS signs a program's code pages, and Linux often restricts ptrace. The
program itself can, with ordinary calls, and it also knows where it was loaded and which of
its threads are running. hotfpc compiles a small unit into your program with fpc's `-Fa`
option, and that unit is the agent. You don't change your source for it. On every save, the
agent loads the new code, binds it to the variables the program already has and points the
old routines at it.

A compiled unit only works with the exact compiler, target and code generation options that
made it. Shipping compiled agents would mean one for every fpc version, target and option
set. So hotfpc carries the agent's source in its own binary and compiles it with your fpc
and your options when it starts. That's how one hotfpc binary works with every fpc from
3.2.2 on, and with cross-compiled programs too, such as a Windows program built on Linux. It
also can't end up with an agent from another version.
[docs/how-it-works.md](docs/how-it-works.md) has the details.

## Install

You need Free Pascal 3.2.2 or later. hotfpc checks the version when it starts.

Download a binary for macOS arm64, Linux x86-64 or Windows x86-64 from the
[releases](https://github.com/frostney/hotfpc/releases), or build it yourself. It's plain
Pascal and needs nothing beyond what ships with fpc:

```sh
git clone https://github.com/frostney/hotfpc
cd hotfpc
./build.sh hotfpc     # build/hotfpc
```

On Windows, `build.bat hotfpc` builds `build\hotfpc.exe`.

You don't need the whole repository to build it. All of hotfpc is in `source/`:

- `HotFPC.pas` is hotfpc itself, with its unit tests at the end.
- `HotFPC.Agent.pas` is the agent.
- `HotFPC.rc` makes the agent's source part of the hotfpc binary.

Copy them into your own tree and build them with fpc 3.2.2, or with fpc-toolchain's 3.3.1+4
or later. Its earlier 3.3.1 builds miscompile hotfpc when optimising
([docs/how-it-works.md](docs/how-it-works.md#a-compiler-bug) has the story). First fpcres,
which comes with fpc, turns `HotFPC.rc` into `HotFPC.res`, and then fpc builds the rest:

```sh
fpcres -of res -o HotFPC.res HotFPC.rc
fpc HotFPC.pas
```

Put the binary on your `PATH`, or copy it somewhere that is.

## Use

```sh
hotfpc program.pas
```

hotfpc builds the program, starts it and watches its sources. Leave it running, edit a unit
in your editor and save. Your program's output goes to the terminal as usual, and hotfpc's
own lines start with `[hot]`:

```text
[hot] v1: built in 142.0 ms, started in 172.0 ms, 2 units of its own, watching 2 files
score    1  ##
score    2  ###
...
[hot] v2 swapped: scene: 2 functions redirected (1 with other code, 0 new), 1 variables and tables kept, 0 new, 390 bytes; 105.0 ms after the save was seen (settle 7.0, compile 87.0, interface check 6.0, load 5.0 of which in the program 4.177)
...
```

Every save ends in one of these:

- `vN swapped`: the new code runs from the next call on, and the program keeps its state.
- `restart needed: ...`: the edit changes something the running state depends on, such as a
  variable's size, a class's instance size or virtual method table, a record's layout, a new
  unit, a new thread variable, or a runtime routine the program was linked without. The
  message names the declaration, and the program carries on unchanged. Stop hotfpc and start
  it again.
- `not swapped`: the source changed but the generated code didn't (a comment, for example).
- `error: ... (nothing changed)`: the unit doesn't compile, and you get fpc's errors. The
  program keeps running the code it had.

hotfpc passes your fpc options to fpc as they are and adds the few it needs, such as `-Xs-`,
`-Fa`, `-FU` and `-o`. Anything after `--` goes to your program:

```sh
hotfpc -Fusrc -Fiinclude -dDEBUG src/server.pas -- --port 8080
```

It watches the program's directory, every `-Fu` and `-Fi` directory, and the directories in
any `@file` response file. It builds into `.hot/` next to the program's source, so add
`.hot/` to your `.gitignore`.

Keep the code you want to change in units. The main program's block is already running, so
it keeps its old code.

### Options

```text
hotfpc [--version] [--fpc FPC] [--ppudump PPUDUMP] [--run LAUNCHER] [--quiet]
       [--settle MS] [--log FILE] [fpc options] program.pas [-- program arguments]
```

| Option | What it does |
| --- | --- |
| `--fpc FPC` | The compiler to use (default: `fpc`). |
| `--ppudump PPUDUMP` | ppudump from the same compiler, for checking interface layouts (default: the one next to the compiler). Without it, or with one that can't read the compiler's units, the check is off and hotfpc says so at the start. |
| `--run LAUNCHER` | A program to start the built program with. The default is `wine` when the target is Windows (`-Twin64`) and hotfpc isn't running on Windows. |
| `--settle MS` | How long a saved file has to stay unchanged before hotfpc compiles it (default: 2 ms). |
| `--log FILE` | Writes a copy of every line hotfpc prints, with times. |
| `--quiet` | Leaves out the start line and the closing summary. |
| `--version` | Prints hotfpc's version. |

## With lwpt

hotfpc doesn't need [lwpt](https://github.com/frostney/lwpt), but the two get along. lwpt
writes the unit paths of your package and its dependencies to `lwpt.cfg`, an fpc response
file. hotfpc passes that file to fpc and watches every directory listed in it, so edits to a
dependency's units are swapped in too. Add a run task to `lwpt.toml`:

```toml
[hot]
command = "hotfpc"
args = ["@lwpt.cfg", "source/greeter.pas"]
```

Then run it with lwpt:

```sh
lwpt install     # writes lwpt.cfg
lwpt run hot
```

[`examples/lwpt`](examples/lwpt) is a complete project. In it, run `lwpt install` and `lwpt
run hot`, then change the text in `source/greeting.pas` and save.

## With raylib

[`examples/raylib`](examples/raylib) is a small [raylib](https://www.raylib.com) program to
play with: balls that fall, bounce and change colour. Change the gravity, the colours or the
shapes in `scene.pas`, save, and the balls carry on from where they were. It declares the
raylib functions it uses itself, so raylib is the only thing to install.

## Platforms

hotfpc runs on macOS, Linux and Windows, and hot-reloads programs built for:

| Program built for | Tested | fpc 3.2.2 | fpc 3.2.4-rc | fpc 3.3.1 |
| --- | --- | --- | --- | --- |
| macOS arm64 | natively | ✓ | ✓ | ✓ |
| Linux x86-64 | natively | ✓ | ✓ | ✓ |
| Windows x86-64 | under Wine 9.0, hotfpc on Linux | ✓ | ✓ | ✓ |
| Windows x86-64 | under Wine 9.0, `hotfpc.exe` and the Windows fpc under Wine too | not tried | not tried | ✓ |
| Linux arm64 | compiles, not run yet | | | |

Each ✓ means all 19 [scenarios](tests/scenarios) gave the expected result with hotfpc 1.0.0.
A scenario is a program that gets edits saved into it while it runs. On Windows, two of them
expect a restart where the other systems swap (see below). With fpc 3.2.2 and 3.3.1, a
stress test also passed on all three systems (Windows under Wine): 20,000 reloads of one
unit while two threads kept calling it, with no stale or wrong results. On macOS and Linux,
four edits to lwpt's formatter units (6,600 lines) all swapped in.

fpc 3.2.2 is the official Free Pascal release. 3.2.4-rc and 3.3.1 are
[fpc-toolchain](https://github.com/frostney/fpc-toolchain)'s builds. Older compilers aren't
supported, and neither are macOS x86-64 and 32-bit targets.

On Windows, fpc's linker always leaves out runtime routines the program never calls, so new
code that calls one of them needs a restart there. Linux and macOS link the whole unit.

The scenarios have only run under Wine so far. On Windows itself, CI builds hotfpc and runs
its unit tests.

A swap usually takes 40 to 150 ms from save to running, and most of that is fpc compiling
the unit. A unit with about 500 functions takes 0.5 to 1.1 s.

## Limits

- The interface check only covers types in a unit's interface, because ppudump only sees
  interfaces. If you swap two fields of a class declared in the implementation section,
  their values swap too.
- A unit's initialization section doesn't run again, and a new unit needs a restart.
- Memory for new code and data is never freed.
- Hardened and notarised macOS programs aren't supported.

[docs/how-it-works.md](docs/how-it-works.md) explains how a save becomes a swap and what
each system needs.

## Tests

```sh
./build.sh tests                               # unit tests (the end of source/HotFPC.pas)
python3 tests/scenarios/check.py               # all 19 scenarios, about 2 minutes
python3 tests/scenarios/check.py globals rename
HOT_DRIVER_OPTS="--fpc /path/to/fpc" python3 tests/scenarios/check.py
```

`tests/scenarios/scenario.py` holds the programs and their edits. `check.py` runs
`build/hotfpc` on each one, compares the run with its expected number of swaps applied,
refused and failed, and checks for a clean exit and that the program's output had no gaps.
For some cases it also checks the values the program printed after a swap.
[docs/build-system.md](docs/build-system.md) describes `build.sh` and `build.bat`.

## Licence

MIT, see [LICENSE](LICENSE).
