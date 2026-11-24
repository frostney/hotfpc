# Your own program

hotfpc runs your program the way you would build it with fpc: put `hotfpc` in front of
your fpc command line. This page covers the options, what hotfpc watches, and how to lay
out a program so the code you change can be swapped. The full list of options is in
[Command line](../reference/cli.md).

## From fpc to hotfpc

```sh
fpc -Fusrc -Fiinclude -dDEBUG src/server.pas            # how you build it
hotfpc -Fusrc -Fiinclude -dDEBUG src/server.pas -- --port 8080
```

hotfpc passes your fpc options to fpc as they are, including `@` response files, and adds
the few it needs, such as `-Xs-` to keep the symbols and `-FU` and `-o` to build into
`.hot/` ([what hotfpc adds](../reference/cli.md#what-hotfpc-adds-to-fpc)). Anything after
`--` goes to your program as its arguments. It runs fpc in the current directory, so
relative paths, response files and a local `fpc.cfg` mean what they mean to fpc.

Your program's output goes to the terminal as usual, and hotfpc's own lines start with
`[hot]`. hotfpc ends when your program ends, with its exit code.

hotfpc builds into `.hot/` next to the program's source. Add it to your `.gitignore`:

```text
.hot/
```

## Choosing the compiler

hotfpc uses the `fpc` on your `PATH`. Name another with `--fpc`, such as a cross compiler
or a wrapper script:

```sh
hotfpc --fpc /opt/fpc-3.3.1/bin/fpc game.pas
```

hotfpc checks the layouts of records, classes and variables with the `ppudump` in the same
directory as the compiler. When there's none there, which happens with a wrapper script in
another directory, hotfpc says so when it starts and runs without that check. Name it with
`--ppudump`:

```sh
hotfpc --fpc ~/bin/fpc --ppudump /opt/fpc/bin/ppudump game.pas
```

Without the check, an edit that changes a type without changing its size, such as
`Integer` to `Single`, is swapped, and the program then reads its old values wrongly.

## What hotfpc watches

hotfpc watches the Pascal sources (`.pas`, `.pp`, `.inc`, `.lpr`, `.dpr`) in:

- the program's own directory;
- every `-Fu` and `-Fi` directory on the command line, and in `@` response files.

It watches the files directly in those directories, not in their subdirectories. A unit in
`src/game/` needs `-Fusrc/game` for fpc to find it anyway, and then hotfpc watches it too.
The start line says how many files it watches:

```text
[hot] v1: built in 228.0 ms, started in 5.0 ms, 2 units of its own, watching 2 files
```

A changed include file makes fpc compile every unit again; only those whose code comes out
different are swapped.

## Laying out code you want to change

- **Keep the code you change in units.** The main program's block is already running when
  you save, so it keeps its old code. Let the main block run the loop and call into units.
- **Keep state in variables, not in the main block's locals.** A unit's variables keep
  their values across swaps, and new code uses them.
- **A new unit needs a restart.** Add the units you expect to need before you start, or let
  hotfpc start the program over when you add one.

[`examples/raylib`](../../examples/raylib) is laid out this way: `game.pas` opens the window
and runs the frame loop, and `scene.pas` holds everything you see and the state behind it.

## Quieter, or with a record

- `--quiet` leaves out the start line and the closing summary.
- `--log hot.log` writes the `[hot]` lines to `hot.log` with a timestamp, for a record of
  the session or to see how long each save took.
- `--settle 50` waits 50 ms instead of 2 ms for the saved files to stop changing, for an
  editor or a tool that writes a file in several steps.

## What you ship

Build your release with plain fpc. A program built by hotfpc carries the agent and keeps
its symbols.

## Next steps

- [What a save does](saves-and-restarts.md): swaps, restarts and `--no-restart`.
- [Troubleshooting](troubleshooting.md): when a save doesn't do what you expected.
