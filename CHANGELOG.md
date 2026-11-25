# Changelog

## Unreleased

- A swap no longer breaks a running routine that calls a routine nested in it. When a save
  moved the parent's locals, the frame that was still running called the new nested
  routine, which read that frame with the new layout: in the `nestedframe` scenario, the
  ticks printed wrong numbers, or the program stopped printing. A nested routine's old
  entry, and on Windows that of the helper fpc makes for each `finally`, now keeps its old
  code for the running frame; new code calls the new version. It happened wherever fpc
  names nested routines: on Linux, on macOS, and on Windows with fpc 3.3.1.
- On Windows with fpc 3.2, a swap now redirects the old entry of a routine declared only
  in a unit's implementation section, other than a method, to its new code, as it does on
  macOS and Linux and with fpc 3.3.1. fpc 3.2 gives such a routine no symbol in a Windows
  object file, so the agent couldn't find its old entry: a procedure variable taken before
  the swap, or a frame that kept calling the routine, ran its old code. The agent now
  finds the routine's section in the linker's map, as it does for such a variable.
- On Linux x86-64, a file the agent was given that is no relocatable ELF object for the
  system is reported as `<file> is not an x86-64 ELF object`. The error named aarch64,
  Linux arm64's architecture.
- A swap that changes the program's main block prints `note: the main block changed` once.
  It printed it twice: fpc gives the main block two names, `PASCALMAIN` and `main`.
- An empty source file in a watched directory, such as an empty `.inc` nothing uses, no
  longer holds back every save. hotfpc took any empty file for a save still being written
  and compiled nothing while one was there. Now only a file that a save has just emptied
  waits, for half a second, in case the editor has yet to write it.
- A program that a signal ends before its agent connects now prints `exit code -1`, as when
  a signal ends it later, and when that ends hotfpc, hotfpc ends with 255. hotfpc used to
  print `exit code 0` and end with 0, as if the program had succeeded. A program a restart
  started that a signal ends before its agent connects still leaves hotfpc watching for the
  next save that builds.
- macOS x86-64 (Intel Macs): the agent hot-reloads programs built for it, the releases have
  a `macos-x64` archive, and CI builds hotfpc, runs the unit tests and runs the scenarios
  on GitHub's Intel macOS runner.
- On x86-64, a swap no longer writes the jump at a routine's entry over the routine after
  it: with `{$codealign proc=1}`, fpc can pack an assembler routine shorter than the 5-byte
  jump right before the next one, on macOS and on Linux with `-Aas`, and the program then
  crashed when it called one of them through its old address. Such a save now needs a
  restart.
- On x86-64, a swap no longer writes the jump at a routine's entry over a call in its
  first 5 bytes, such as an assembler routine's `call rdi`. A thread waiting in the routine
  it called returned into the middle of the jump: in the `shortcall` scenario, it failed
  with an access violation. Such a save now needs a restart.
- On x86-64, a swap no longer writes the jump at a routine's entry while a thread is to
  resume within its first 5 bytes. A signal handler, or on Windows an exception handler,
  keeps where the thread it interrupted resumes in its frame, and a thread whose handler
  waited past the swap resumed in the middle of the jump: in the `sighandler` and
  `sigmasked` scenarios, it failed with an access violation. The agent now reads each
  stopped thread's stack for such an address, and on Linux the stack of a thread that
  blocks signals and sleeps; it tries again while there is one, and when one stays the save
  needs a restart. On Windows, a thread whose context can't be read now fails the stop
  instead of going unchecked.
- On macOS, a swap now also stops a thread that another thread started while the agent was
  stopping them, and a thread that can't be suspended makes the agent let the others run
  and try again. Such a thread used to run on while the agent rewrote code. The agent
  resumes only the threads it suspended.
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
  file, used to be left out until the next save; hotfpc now builds the program again before
  it starts it, also when the build failed on it, and waits for a file that save emptied
  first, as it does once the program runs, for about a second and a half at most. After three such compiles, links or compiles to assembler in a row, hotfpc
  uses the next one as it is, and it waits at most a second for the files to settle before
  a compile, so a file that keeps changing can't hold back every save, nor keep hotfpc
  running after the program has ended. On Windows a save whose sizes of variables with
  initial values are checked then needs a restart, as its compile and its compile to
  assembler may have read different sources; when that happens to the build a program
  starts from, every such save needs a restart until it starts over. hotfpc reads the
  times of the sources as finely as the file system keeps them, so a save that came and
  was put back during a compile, at the same size and within the same second, shows too.
  On Windows such a save needs a restart where the times can't show it, as on a file
  system that keeps whole seconds, and so does every save that needs the sizes when the
  times couldn't show it for the build the program starts from; hotfpc waits 22 ms for a
  save to settle instead of 4.
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
  compares the sizes there. The running program's sizes come from such a compile after the
  program is built or linked to start over, checked with its build or link against saves
  that land meanwhile, so they are the sizes of the sources the program was built from,
  also of a unit the restart adds. A save whose sizes it can't compare, because fpc didn't
  write the assembler for it or for the build the program started from, or the assembler
  has no size for a variable the object file defines, needs a restart too.
- Linux arm64: the releases have a `linux-arm64` archive, and CI builds hotfpc, runs the
  unit tests and runs the scenarios on GitHub's arm64 runner.
- On Linux arm64, new code now uses the variables of its unit's implementation section
  that the program already has. It used to get new ones set to zero, so their values were
  lost and the program could crash: gas refers to such a variable through the symbol of
  its section, and the agent placed that section again. The scenarios now check that such
  a counter keeps counting across swaps.
- The documentation is a tree under `docs/`: guides from an introduction to
  troubleshooting, a reference for the command line, every `[hot]` line, the environment
  variables, the platforms and the limits, and pages for contributors. The README shows the
  Homebrew install and a recording of `examples/raylib`: four saves swapped into the
  running game, then a fifth that grows a variable, after which hotfpc starts the game over
  by itself. CONTRIBUTING.md is new.

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
