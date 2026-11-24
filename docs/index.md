# Documentation

hotfpc is hot reloading for Free Pascal. Run your program under hotfpc, edit a unit and
save, and the running program carries on with the new code and everything it had. When an
edit changes something the running program depends on, hotfpc says which declaration is in
the way and starts the program over.

New to it? The [introduction](guides/introduction.md) explains what happens to your program,
and the [quick start](guides/quick-start.md) has you watching a program change in a few
minutes.

## Guides

- [Introduction](guides/introduction.md): what hot reloading is, swaps and restarts, and
  the agent hotfpc puts into your program.
- [Quick start](guides/quick-start.md): install fpc and hotfpc, run the demo, make four
  edits.
- [What a save does](guides/saves-and-restarts.md): what a swap keeps, which edits need a
  restart, and what a restart does.
- [Your own program](guides/your-program.md): fpc options, the compiler and ppudump, the
  files hotfpc watches, and how to lay out code you want to change.
- [Edits and what they do](guides/edits.md): every kind of edit hotfpc is tested with, and
  its outcome.
- [With lwpt](guides/lwpt.md): a run task that starts your package under hotfpc.
- [With raylib](guides/raylib.md): a game to tune while it runs.
- [Windows programs](guides/windows.md): `hotfpc.exe` on Windows, and Windows programs
  under Wine.
- [Troubleshooting](guides/troubleshooting.md): what hotfpc's messages mean and what to do.

## Reference

- [Command line](reference/cli.md): every option, what hotfpc passes to fpc, exit codes,
  the `.hot/` directory.
- [Output](reference/output.md): every `[hot]` line.
- [Environment variables](reference/environment.md): the `HOT_*` variables.
- [Platforms](reference/platforms.md): where hotfpc runs, how to get it, and what was
  tested with which compiler.
- [Limits](reference/limits.md): what hotfpc doesn't do, and why.

## Contributing

How hotfpc itself works and is built: [how it works](internals/how-it-works.md),
[build system](internals/build-system.md), [code style](internals/code-style.md),
[tooling](internals/tooling.md), [testing](internals/testing.md),
[releasing](internals/releasing.md) and [recording the demos](internals/demos.md). The
workflow for a change is in [CONTRIBUTING.md](../CONTRIBUTING.md).
