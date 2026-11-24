# Troubleshooting

What it means when hotfpc doesn't do what you expected, and what to do. Every line hotfpc
can print is in [Output](../reference/output.md).

## Before the program starts

### `fpc is version 3.0.4; hotfpc requires 3.2.2 or later`

The `fpc` on your `PATH` is too old, or another one comes first. `fpc -iV` shows which.
Install a newer one, or name it with `--fpc /path/to/fpc`.

### `cannot run fpc; hotfpc requires 3.2.2 or later`

fpc isn't on the `PATH` that hotfpc sees. An editor or a task runner that starts hotfpc may
have a shorter `PATH` than your shell: name fpc with `--fpc`.

### `no ppudump next to the compiler (--ppudump): the check of interface layouts is off`

hotfpc looks for `ppudump` in the directory of the fpc it runs. A wrapper script, such as
one from a version manager, lives somewhere else. hotfpc carries on, but without the check
of layouts, so an edit that changes a type without changing its size (`Integer` to
`Single`, two fields swapped) is swapped instead of restarted, and the program then reads
its old values wrongly. Name it:

```sh
hotfpc --ppudump "$(command -v ppudump)" game.pas
```

### `... cannot read this compiler's units (...)`

The ppudump hotfpc found belongs to another fpc. Name the one that came with your
compiler with `--ppudump`.

### `the agent did not compile:`

fpc's output follows. hotfpc compiles the agent with your options that decide the target,
code generation and paths. An `@` response file or an `-Fu` path that only works for your
program's directory can break it; so can a target the agent doesn't support
([limits](../reference/limits.md)).

### `the program did not connect within 60 s`

The program started but its agent never connected. hotfpc waits up to 60 s, because the
first start can be slow: macOS checks a newly linked program when it first starts, which
can take seconds and more under load, and Wine starts its server the first time. hotfpc
stops the program and ends with 1.

### `the program ended (exit code 1) before hot reloading could start`

The program ended before its agent connected: it ran too briefly, or failed at once. Run
it with plain fpc to see why. A program that is meant to end quickly gets nothing from
hotfpc.

## While it runs

### I saved, and nothing happened

- **The file isn't watched.** hotfpc watches the program's directory and the `-Fu` and `-Fi`
  directories, not their subdirectories. The start line says how many files it watches.
  Add the directory with `-Fu` or `-Fi`.
- **The edit is in the main program's block.** It is already running and keeps its old
  code. hotfpc notes `the main block changed`. Move the code into a routine.
- **The edit is in an initialization section.** It doesn't run again. hotfpc notes it.
- **The code didn't change.** A comment or unused code gives `not swapped: the generated
  code is the same`.

### The change shows, but the program's values are wrong

The program read a variable with the new code's idea of its type. hotfpc refuses such an
edit when its check of layouts is on, so look for `the check of interface layouts is off`
at the start, and name `--ppudump`. Restart the program to get correct values back.

### Every save restarts the program

Something in each edit changes the running state, and the `restart needed` line names it:
[What a save does](saves-and-restarts.md#what-needs-a-restart) lists the reasons. After a
restart, the next save that only changes code is swapped into the new program.

### The restarted program fails

```text
[hot] the program ended (exit code 3) before hot reloading could start
[hot] the next save that builds starts the program again
```

The new code fails when it starts, such as in an initialization section. hotfpc keeps
watching: fix it and save, and it starts the program again.

### The old program keeps running after a restart

A launcher given with `--run` started the program as its child and didn't end it when
hotfpc stopped the launcher. Use a launcher that ends its child, or start the program
directly.

### A swap is slow

The time is in the swap line: usually the compile. A unit with about 500 functions takes
0.5 to 1.1 s to compile. For a Windows program, a unit with initialised variables compiles a
second time, to assembler ([Windows programs](windows.md)).

## Still stuck?

Run with `--log hot.log` for a record with timestamps, and with `HOT_DEBUG=1` to see which
files hotfpc saw change and which units it made fpc compile again:

```sh
HOT_DEBUG=1 hotfpc --log hot.log game.pas
```

If hotfpc swapped something it should have refused, or refused something it should have
swapped, that is a bug: [open an issue](https://github.com/frostney/hotfpc/issues) with the
edit and the `[hot]` lines.
