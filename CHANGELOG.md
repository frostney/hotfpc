# Changelog

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
- Builds with plain fpc from a copy of `source/`, or with `instantfpc build.pas`; no other
  build tool.
