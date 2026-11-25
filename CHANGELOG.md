# Changelog

## Unreleased

- hotfpc no longer crashes, or corrupts its memory, when a source file grows while it reads
  it, as when a save or a generator writes the file during the twice-a-second look at the
  contents. It read the file's size twice and could read more than it had room for.
- A save whose sources change again while fpc compiles them is compiled again once they
  settle, before hotfpc swaps, refuses or reports anything. fpc reads one file after the
  other, so when an editor wrote the files of one save a few milliseconds apart, or the
  next save came during the compile, hotfpc used to act on a mix of old and new files: it
  could report errors or a needed restart for a state nobody saved, and then compile the
  same save a second time. The same goes for a save's compile to assembler on Windows and
  the link of a restart. A save that landed during the first build, after fpc had read the
  file, used to be left out until the next save; it is now compiled as soon as the program
  runs. After three such compiles, links or compiles to assembler in a row, hotfpc uses the
  next one as it is, and it waits at most a second for the files to settle before a
  compile, so a file that keeps changing can't hold back every save, nor keep hotfpc
  running after the program has ended. On Windows a save whose sizes of variables with
  initial values are checked then needs a restart, as its compile and its compile to
  assembler may have read different sources.
- hotfpc keeps each source file by its whole path, with its case. In a directory whose
  path has `=` in it, the files used to share one entry, so unchanged sources looked
  changed after every compile: each save was compiled four times, and on Windows a save
  whose sizes of variables with initial values are checked needed a restart. Two files
  whose names differ only in case, such as `A.inc` and `a.inc` on a case-sensitive file
  system, used to count as one, so hotfpc didn't watch one of them.
- On Windows, a variable with an initial value in the program file that changes size
  (`Calls: Integer = 0` to `Int64 = 0`) now needs a restart, as on the other systems, and
  so does a typed constant declared in a routine, or with fpc 3.2 in a unit's
  implementation section. They used to be swapped, and the new code then wrote past the
  variable. COFF objects state no sizes, so hotfpc now also compiles a Windows program to
  assembler (`-s -Aas`, into `.hot/asm/`) when a changed unit has such a variable, and
  compares the sizes there. A save whose sizes it can't compare, because fpc didn't write
  the assembler or the assembler has no size for a variable the object file defines, needs
  a restart too.
- Linux arm64: the releases have a `linux-arm64` archive, and CI builds hotfpc, runs the
  unit tests and runs the scenarios on GitHub's arm64 runner.
- On Linux arm64, new code now uses the variables of its unit's implementation section
  that the program already has. It used to get new ones set to zero, so their values were
  lost and the program could crash: gas refers to such a variable through the symbol of
  its section, and the agent placed that section again. The scenarios now check that such
  a counter keeps counting across swaps.

## 1.1.0

- An edit that needs a restart now starts the program over, like webpack's full reload
  when a module can't be updated in place: hotfpc names the declaration, links the program
  again and starts it with the new code. If the link fails, the program keeps running.
  `--no-restart` keeps the 1.0.0 behaviour, where the program carries on with its old code.
- A restarted program that fails, for example with a runtime error in an initialization
  section, doesn't end hotfpc: the next save that builds starts it again.
- The closing summary also counts restarts.
- A variable with an initial value in a unit's implementation section that changes size
  (`Integer = 0` to `Int64 = 0`) now needs a restart. It used to be swapped on Linux and
  Windows, and the new code then wrote past the variable: fpc pads such a variable's
  section to 16 bytes. The agent now takes the size from the ELF symbol on Linux, and the
  check of layouts finds the new type on every system. On Windows, such a variable in the
  program file, and with fpc 3.2 a typed constant, still has the gap (README "Limits").
- The check of layouts now covers a unit's implementation section too, from ppudump's text
  output: its variables and its records and classes. Swapping two fields of a class
  declared there, or giving a variable there another type of the same size (`Integer` to
  `Single`), now needs a restart. Both used to be swapped, and the program then read its
  old values wrongly. The check takes about 8 ms more per save (macOS, fpc 3.2.4).

## 1.0.0

The first release.

- Hot reloading for Free Pascal 3.2.2 and later: edit a unit of a running program, save, and
  the program continues with the new code and its state. Edits that can't be swapped in
  safely are reported with the declaration that needs a restart, and the program keeps
  running.
- Programs for macOS arm64, Linux x86-64 and Windows x86-64; hotfpc itself runs on macOS,
  Linux and Windows, and drives Windows programs under Wine from Linux and macOS.
- One binary for every compiler version: hotfpc carries the agent's source and compiles it
  with the program's own fpc and target options.
- Watches the program's directory, `-Fu`/`-Fi` directories and the directories in `@file`
  response files such as lwpt's `lwpt.cfg`.
- Checks that the compiler is fpc 3.2.2 or later before it builds.
- Builds with fpc and fpcres from a copy of `source/`, or with `build.sh` and `build.bat`;
  no other build tool.
