# Command line

Everything hotfpc takes on its command line, what it passes to fpc, the exit codes and the
files it writes. The [quick start](../guides/quick-start.md) and
[your own program](../guides/your-program.md) show it in use; this page is the complete
surface.

## Synopsis

Run without a program, hotfpc prints its usage and exits with 2:

```text
usage: hotfpc [--version] [--fpc FPC] [--ppudump PPUDUMP] [--run LAUNCHER] [--quiet] [--no-restart] [--settle MS] [--log FILE] [fpc options] program.pas [-- program arguments]
```

hotfpc reads its arguments from left to right:

- Its own options, below, are taken wherever they appear before `--`. An option that takes
  a value counts only when a value follows it.
- Every other argument that starts with `-` or `@` is an fpc option or response file. They
  go to fpc in the order given.
- Any other argument is the program's source file. If there are several, the last one
  counts.
- Everything after `--` goes to the program as its arguments.

## Options

| Option | Default | What it does |
| --- | --- | --- |
| `--fpc FPC` | `fpc` | The compiler: a name looked up on `PATH`, or a path, which can be a wrapper script. hotfpc runs `FPC -iV` first and stops if it isn't 3.2.2 or later. |
| `--ppudump PPUDUMP` | the `ppudump` next to the compiler that fpc runs (the one `FPC -PB` names), or else, or when that one can't read the compiler's units, the one next to `FPC` | ppudump of the same compiler. hotfpc reads each changed unit's file with it to check the layouts of records, classes and variables. Without one, or with one that can't read the compiler's units, that check is off and hotfpc says so when it starts. |
| `--run LAUNCHER` | `wine` for a Windows target when hotfpc doesn't run on Windows; none otherwise | A program to start the built program with: hotfpc runs `LAUNCHER .hot/program [program arguments]`. A restart stops the launcher, so a launcher that runs the program as its child has to end it too; hotfpc says so when the old program's connection stays open. When the launcher's file name contains `wine`, the paths hotfpc gives the agent are Wine paths (`Z:\...`). |
| `--settle MS` | `2` | How long, in milliseconds, the saved files have to stay unchanged before hotfpc compiles them. A value that isn't a number counts as 2. Files that keep changing are compiled after a second, or after one such wait when it is longer. For a Windows program whose sizes of variables with initial values hotfpc checks, each wait is 20 ms at least, so that a save during the compile shows in the files' times ([how it works](../internals/how-it-works.md#one-save)). |
| `--log FILE` | none | Writes a copy of the `[hot]` lines to `FILE`, each after a timestamp in seconds: all of them from the version check on, except a few about starting the program ([output](output.md#before-the-program-starts)). The file is written again from the start on every run. |
| `--quiet` | off | Leaves out the start line (`v1: built in ...`) and the closing summary. |
| `--no-restart` | off | When an edit needs a restart, leaves the program running its old code instead of starting it over. The next save that can be swapped is swapped. |
| `--version` | | Prints `hotfpc 1.1.0` (its version) and exits with 0, whatever else is on the command line before it, unless it is an option's value. After `--`, it is the program's. |

A target is a Windows one when an fpc option on hotfpc's command line starts with `-Twin`
(`-Twin64`), or when
hotfpc itself runs on Windows.

## What hotfpc adds to fpc

hotfpc runs fpc in the current directory, so relative paths in options, in response files
and in a local `fpc.cfg` mean what they mean to fpc. It passes your options as they are and
adds these, with absolute paths into the program's `.hot/` directory:

| Compile | Added options |
| --- | --- |
| Every compile of the program | `-Xs-` (keep the symbols), `-FaHotFPC.Agent` (load the agent before the program's `uses`), `-Fu.hot/agent`, `-FU.hot/units`, `-o.hot/<program>` before your options; the source file last |
| A save | `-Cn`: compile without linking |
| A link for a Windows target | `-Xm`: write the linker's map, where the agent finds the sections fpc 3.2 gives no symbol |
| A restart | links into `.hot/next/` first, so a link that fails leaves the running program as it is |
| A Windows target, when a changed unit has a variable with an initial value or a typed constant | a second compile to assembler, `-s -Aas`, into `.hot/asm/` |
| The agent, once at the start | only your options that decide the target, code generation and paths (`-T`, `-P`, `-Cp`, `-Cf`, `-Ca`, `-XP`, `-Fl`, `-Fu`, `-k`, `-XR`, `-Xd`, `-n`, `-V` and `@` files), and `-FU.hot/agent` |

fpc writes link scripts (`link*.res`, `ppas.sh`, `ppas.bat`, `symbol_order*`) into the
directory it runs in.
hotfpc removes the ones a compile created there and leaves any that were there before.

## Watched files

hotfpc watches the `.pas`, `.pp`, `.inc`, `.lpr` and `.dpr` files directly in these
directories, not in their subdirectories:

- the program's directory;
- every `-Fu` and `-Fi` directory, including several separated by `;`, and those in `@`
  response files such as lwpt's `lwpt.cfg`. Relative paths are taken from the current
  directory, as fpc takes them. A path with a wildcard isn't watched.

It checks sizes and times every 10 ms and contents twice a second. The start line says how
many files it watches.

## Exit codes

| Code | When |
| --- | --- |
| the program's | The program ended. hotfpc ends with it, with its exit code. A program a restart started doesn't end hotfpc when it ends before its agent connects, whatever its code, or later with a non-zero code (see [What a save does](../guides/saves-and-restarts.md#when-a-restarted-program-fails)). |
| 0 | `--version`. |
| 1 | hotfpc stopped before the program ran: the compiler is missing or too old, the agent or the program didn't compile, hotfpc couldn't listen on 127.0.0.1, or the program didn't connect within 60 s. |
| 2 | No program was named: hotfpc printed its usage. |

The closing summary, and the line of a program that ended before its agent connected,
print `-1` as the exit code of a program that a signal ended. When that program's end ends
hotfpc, hotfpc ends with 255 on Linux and macOS. A program a restart started that ends
before its agent connects prints the same line, and hotfpc keeps watching.

## The `.hot/` directory

hotfpc builds into `.hot/` next to the program's source, and removes and creates it again
on every start. Add `.hot/` to your `.gitignore`.

| Path | What it holds |
| --- | --- |
| `.hot/<program>` | The built program, `<program>.exe` for a Windows target, with `<program>.map` from the linker there. |
| `.hot/units/` | The units and object files of the last compile. |
| `.hot/live/` | The units as the running program has them: what the next save is compared with. |
| `.hot/agent/`, `.hot/agent-src/` | The compiled agent, and its source as hotfpc writes it out. |
| `.hot/v<N>/` | The object files of version N, handed to the agent. |
| `.hot/next/` | Where a restart links the program before it replaces the running one. |
| `.hot/asm/` | For a Windows target: the compile to assembler, with units of its own. |
