# Changelog

## Unreleased

- On Windows, a variable with an initial value in the program file that changes size
  (`Calls: Integer = 0` to `Int64 = 0`) now needs a restart, as on the other systems, and
  so does a typed constant declared in a routine, or with fpc 3.2 in a unit's
  implementation section. They used to be swapped, and the new code then wrote past the
  variable. COFF objects state no sizes, so hotfpc now also compiles a Windows program to
  assembler (`-s -Aas`, into `.hot/asm/`) when a changed unit has such a variable, and
  compares the sizes there. A save whose sizes it can't compare, because fpc didn't write
  the assembler, needs a restart too.

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
