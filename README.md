# hotfpc

Hot reloading for Free Pascal programs. Edit a unit while your program runs, save it, and
the program carries on with the new code and keeps its state: its variables, objects, open
files and threads. When an edit can't be swapped in safely, hotfpc says why and leaves the
program running as it was.

![hotfpc running examples/demo: scene.pas on the left is edited four times while the program on the right keeps running](docs/demo.gif)

This is a real run of [`examples/demo`](examples/demo) on macOS arm64 with fpc 3.3.1
([video](docs/demo.mp4), [asciinema cast](docs/demo.cast)). The left pane shows
`scene.pas`, and the right pane shows the program's output, which hotfpc started and keeps
running. The table at the bottom shows the timings the script measured for each save:
how long until the swap, how much of that was fpc compiling, and how long until the first
line of output showed the change.

- The first three edits change a character, a step size and a colour. Each one is swapped
  in 110 to 200 ms after the save, and the score carries on from where it was.
- The fourth edit changes the score from `Integer` to `Int64`. That can't be swapped into
  a running program, so hotfpc reports a restart and leaves the program running.

[`tools/record-demo.py`](tools/record-demo.py) types each edit into the left pane, writes
the file to disk at the moment it shows "saved", and reads the program's output live.

hotfpc wraps fpc and nothing else. It needs no build tool and no C compiler, and you don't
change your program for it. It's a single program written in Pascal, and it doesn't depend
on your compiler's version. It carries the source of the part that runs inside your program
and has your fpc compile that part.

## Install

You need Free Pascal 3.2 or later. Build hotfpc with that compiler:

```sh
git clone https://github.com/frostney/hotfpc
cd hotfpc
./build.sh            # bin/hotfpc, with the fpc on PATH
./build.sh /path/to/fpc
```

On Windows, run `build.bat` (it writes `bin\hotfpc.exe`). The build script passes any extra
options to fpc, so `./build.sh fpc -Twin64 -Px86_64` cross-builds `bin/hotfpc.exe`.

Put `bin/` on your `PATH`, or copy `bin/hotfpc` to a directory that is.

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
hotfpc [--fpc FPC] [--ppudump PPUDUMP] [--run LAUNCHER] [--quiet] [--settle MS]
       [--log FILE] [fpc options] program.pas [-- program arguments]
```

| Option | What it does |
| --- | --- |
| `--fpc FPC` | The compiler to use (default: `fpc`). |
| `--ppudump PPUDUMP` | ppudump from the same compiler, used to check interface layouts (default: the one next to the compiler). Without it, or with one that can't read the compiler's units, the check is off and hotfpc says so at start. |
| `--run LAUNCHER` | A program to start the built program with. The default is `wine` when the target is Windows (`-Twin64`) and hotfpc isn't running on Windows. |
| `--settle MS` | How long a saved file must stay unchanged before hotfpc compiles it (default: 2 ms). |
| `--log FILE` | Writes a copy of every line hotfpc prints, with times. |
| `--quiet` | Leaves out the start line and the closing summary. |

## With lwpt

[lwpt](https://github.com/frostney/lwpt) writes the package's unit paths, and those of its
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

| Program built for | Tested | fpc 3.3.1 | fpc 3.2.4-rc | fpc 3.2.2 |
| --- | --- | --- | --- | --- |
| macOS arm64 | natively | ✓ | ✓ | ✓ |
| Linux x86-64 | natively | ✓ | ✓ | ✓ |
| Windows x86-64 | under Wine 9.0, hotfpc on Linux | ✓ | ✓ | ✓ |
| Windows x86-64 | under Wine 9.0, `hotfpc.exe` and the Windows fpc under Wine too | ✓ | not tried | not tried |
| Linux arm64 | compiles; not run yet | | | |

Each ✓ means all 17 [scenarios](test/scenarios) gave the expected result. Each scenario is
a program that has edits saved into it while it runs. Except for the `hotfpc.exe` row,
each ✓ also passed a stress test (20,000 reloads of one unit while two threads called it,
with no stale or wrong results) and four edits to lwpt's formatter units (6,600 lines).
fpc 3.2.2 is the released compiler. macOS x86-64 and 32-bit targets aren't supported.

On Windows, fpc's linker always leaves out runtime routines the program never calls. New
code that calls such a routine needs a restart there, while Linux and macOS link the whole
unit. Native Windows (not Wine) hasn't been tried yet.

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
./build.sh
python3 test/scenarios/check.py               # all 17 scenarios, about 1.5 minutes
python3 test/scenarios/check.py globals rename
HOT_DRIVER_OPTS="--fpc /path/to/fpc" python3 test/scenarios/check.py
```

`test/scenarios/scenario.py` holds the programs and their edits. `check.py` compares each
run with its expected count of reloads applied, refused and failed, and checks that the
program's output had no gaps.

## License

MIT, see [LICENSE](LICENSE).
