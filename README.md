# hotfpc

Hot reloading for Free Pascal programs. Edit a unit while your program runs, save it, and
the program carries on with the new code and keeps its state: its variables, objects, open
files and threads. When an edit can't be swapped in safely, hotfpc says why and leaves the
program running as it was.

![hotfpc running examples/demo: scene.pas is edited in vim on the left while the program keeps running on the right](docs/demo.gif)

This is a real run of [`examples/demo`](examples/demo) on macOS arm64 with fpc 3.3.1
([video](docs/demo.mp4), [asciinema cast](docs/demo.cast)), recorded in tmux:

- **Right:** `hotfpc --log hot.log demo.pas` typed into a shell. The program's output and
  hotfpc's `[hot]` lines appear there.
- **Left:** `scene.pas` open in vim. Four edits are typed in and saved with `:w`.
- **Below vim:** hotfpc's own timings from `hot.log`, showing for each save how long it
  took to swap and which part of that went to settling, compiling, the interface check
  and loading into the program.

The first three edits change a character, a step size and a colour. Each one is swapped in
about 100 ms after the save, and the score carries on from where it was. The fourth edit
changes the score from `Integer` to `Int64`, which can't be swapped into a running
program, so hotfpc reports a restart and the program keeps running.

[`scripts/record-demo.py`](scripts/record-demo.py) makes the recording. It sends each
keystroke to the shell and to vim with `tmux send-keys`.

## For rapid development

hotfpc is meant for the edit-and-run loop while you develop: change a routine, save, and
see the result in the running program without rebuilding, restarting and getting back to
where you were. It's most useful for programs that run for a while and build up state,
such as games, servers, simulations, tools with a long setup, and anything you're tuning
by eye.

Build what you ship with fpc as usual, without hotfpc. A program that hotfpc builds
carries the hot-reload agent, keeps its symbols and is built for being changed, not for
speed or size.

hotfpc wraps fpc and nothing else. It needs no build tool and no C compiler, and you don't
change your program for it. It's a single program written in Pascal.

### Why there is an agent

Free Pascal has no way to replace code in a running program, and another process isn't
allowed to rewrite a program's code on every system. So hotfpc compiles a small unit, the
agent, into your program with fpc's `-Fa` option. You don't edit the program for this. On
each save, the agent loads the newly compiled code into the program and redirects the old
routines to it, keeping your variables where they are.

A compiled unit only works with the exact compiler and target that made it. That's why
hotfpc carries the agent's source in its own binary and compiles it with your fpc and
your options. One hotfpc binary works with any fpc from 3.2.2 on, including cross
targets. [docs/how-it-works.md](docs/how-it-works.md) has the details.

## Install

You need Free Pascal 3.2.2 or later. hotfpc checks this when it starts.

Download a binary for macOS arm64, Linux x86-64 or Windows x86-64 from the
[releases](https://github.com/frostney/hotfpc/releases), or build it. hotfpc is plain
Pascal with no dependencies beyond what ships with fpc, so either of these works:

```sh
git clone https://github.com/frostney/hotfpc
cd hotfpc
instantfpc build.pas hotfpc     # build/hotfpc (build\hotfpc.exe on Windows)
```

or, with plain fpc:

```sh
mkdir build
fpc -Fusource -FUbuild -obuild/hotfpc source/HotFPC.pas
```

You can also copy the `source/` folder into your own tree and build `source/HotFPC.pas`
with any fpc 3.2.2 or later. Put `build/` on your `PATH`, or copy `build/hotfpc` to a
directory that is.

## Use

```sh
hotfpc program.pas
```

hotfpc builds the program, starts it and watches its sources. Leave it running, edit a unit
in your editor and save. The program's output goes to the terminal as usual. hotfpc's own
lines start with `[hot]`:

```text
[hot] v1: built in 146.0 ms, started in 173.0 ms, 2 units of its own, watching 2 files
score    1  ##
...
[hot] v2 swapped: scene: 2 functions redirected (1 with other code, 0 new), 1 variables and tables kept, ...; 111.0 ms after the save was seen
score   15  ****************
```

After each save, hotfpc prints one of three results:

- `vN swapped`: the new code runs from the next call on, and the program's state is kept.
- `restart needed: ...`: the edit changes something the running state depends on, such as
  a variable's size, a class's instance size or virtual method table, a record's layout, a
  new unit, a new thread variable, or a runtime routine the program was linked without.
  The message names the declaration, and the running program is left unchanged. Stop
  hotfpc and start it again.
- `not swapped`: the source changed but the generated code didn't (for example, only a
  comment changed), or the unit doesn't compile. Compile errors are shown.

hotfpc passes your fpc options to fpc unchanged, and anything after `--` goes to the
program:

```sh
hotfpc -Fusrc -Fiinclude -dDEBUG src/server.pas -- --port 8080
```

hotfpc watches the program's directory, every `-Fu` and `-Fi` directory, and the
directories in any `@file` response file. It builds into `.hot/` next to the program's
source, so add `.hot/` to your `.gitignore`.

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
| `--ppudump PPUDUMP` | ppudump from the same compiler, used to check interface layouts (default: the one next to the compiler). Without it, or with one that can't read the compiler's units, the check is off and hotfpc says so at start. |
| `--run LAUNCHER` | A program to start the built program with. The default is `wine` when the target is Windows (`-Twin64`) and hotfpc isn't running on Windows. |
| `--settle MS` | How long a saved file must stay unchanged before hotfpc compiles it (default: 2 ms). |
| `--log FILE` | Writes a copy of every line hotfpc prints, with times. |
| `--quiet` | Leaves out the start line and the closing summary. |
| `--version` | Prints hotfpc's version. |

## With lwpt

hotfpc doesn't need [lwpt](https://github.com/frostney/lwpt), but works with it. lwpt writes the package's unit paths, and those of its
dependencies, to `lwpt.cfg`, an fpc response file. hotfpc takes that file like fpc does and
watches every directory listed in it. Add a run task to `lwpt.toml`:

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

[`examples/lwpt`](examples/lwpt) is a complete project: `lwpt run hot`, then change the text
in `source/greeting.pas` and save.

## Platforms

hotfpc runs on macOS, Linux and Windows, and can hot-reload programs built for:

| Program built for | Tested | fpc 3.2.2 | fpc 3.2.4-rc | fpc 3.3.1 |
| --- | --- | --- | --- | --- |
| macOS arm64 | natively | ✓ | ✓ | ✓ |
| Linux x86-64 | natively | ✓ | ✓ | ✓ |
| Windows x86-64 | under Wine 9.0, hotfpc on Linux | ✓ | ✓ | ✓ |
| Windows x86-64 | under Wine 9.0, `hotfpc.exe` and the Windows fpc under Wine too | not tried | not tried | ✓ |
| Linux arm64 | compiles; not run yet | | | |

Each ✓ means all 17 [scenarios](tests/scenarios) gave the expected result with hotfpc
1.0.0. Each scenario is a program that has edits saved into it while it runs. With fpc
3.2.2 and 3.3.1, a stress test also passed on all three systems: 20,000 reloads of one
unit while two threads called it, with no stale or wrong results. On macOS and Linux,
four edits to lwpt's formatter units (6,600 lines) were all swapped in.

fpc 3.2.2 is the current release of Free Pascal, and fpc 3.2.4-rc and 3.3.1 are
[fpc-toolchain](https://github.com/frostney/fpc-toolchain)'s builds. Older compilers aren't
supported. macOS x86-64 and 32-bit targets aren't supported.

On Windows, fpc's linker always leaves out runtime routines the program never calls. New
code that calls such a routine needs a restart there, while Linux and macOS link the whole
unit. On Windows itself, CI builds hotfpc and runs its unit tests; the scenarios have only
run under Wine so far.

A swap usually takes 40 to 150 ms from save to running, and most of that is fpc compiling
the unit. A unit with about 500 functions takes 0.5 to 1.1 s.

## Limits

- Changes to a type declared in a unit's implementation section aren't checked, because
  ppudump only sees interfaces. If you swap two fields of such a class, their values swap
  too.
- A unit's initialization section doesn't run again, and a new unit needs a restart.
- Memory for new code and data is never freed.
- Hardened and notarized macOS programs aren't supported.

[docs/how-it-works.md](docs/how-it-works.md) explains how a save becomes a swap and what
each system needs.

## Tests

```sh
instantfpc build.pas tests                     # unit tests (source/*.Test.pas)
python3 tests/scenarios/check.py               # all 17 scenarios, about 1.5 minutes
python3 tests/scenarios/check.py globals rename
HOT_DRIVER_OPTS="--fpc /path/to/fpc" python3 tests/scenarios/check.py
```

`tests/scenarios/scenario.py` holds the programs and their edits. `check.py` runs
`build/hotfpc` on each, compares the run with its expected count of reloads applied,
refused and failed, and checks that the program's output had no gaps.
[docs/build-system.md](docs/build-system.md) describes `build.pas`.

## License

MIT, see [LICENSE](LICENSE).
