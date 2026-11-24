# Limits

What hotfpc doesn't do, and why. [What a save does](../guides/saves-and-restarts.md) lists
the edits that need a restart; these are the limits around them.

- **A unit's initialization section doesn't run again.** The program ran it when it
  started. A swap puts the new code in place, and hotfpc notes that the section changed.
- **A new unit needs a restart.** Its initialization section has never run, and can't run
  on the agent's thread.
- **The main program's block keeps its old code.** It is already running. Code you want to
  change belongs in routines and units; the main block can call them.
- **In the program file, hotfpc checks sizes, not types.** It finds a type that changed
  without changing a size (`LongInt` to `Single`, two fields of a record swapped) by reading
  the changed unit's `.ppu` file with ppudump, and fpc writes none for the program file.
  Such an edit to a declaration there is swapped, and the new code reads the old bytes as
  the new type. A change of size is found, as in a unit. Declarations in units are checked
  in full.
- **A restart doesn't keep any state and doesn't run finalization sections.** hotfpc stops
  the program the way the system ends a process (`SIGTERM`, then `SIGKILL`, on Linux and
  macOS; `TerminateProcess` on Windows).
- **On Windows, new code can't call a runtime routine the program never called.** fpc's
  Windows linker always leaves out code the program doesn't reach, so such an edit needs a
  restart. Linux and macOS link the whole unit.
- **Memory for new code and data is never freed.** Old code stays where it was, because
  something may still call it. A long session of swaps grows the program a little each time.
- **Hardened and notarised macOS programs aren't supported.** The agent rewrites the
  program's signed code pages and puts new code into `MAP_JIT` memory, which the hardened
  runtime allows only with entitlements.
- **Programs for 32-bit targets aren't supported.** The agent is written for macOS on
  arm64 and x86-64, Linux on arm64 and x86-64, and Windows on x86-64. For any other
  target its compile stops with an error, and hotfpc says the agent did not compile.
- **hotfpc watches directories, not trees.** It watches the files directly in the
  program's directory and in the `-Fu` and `-Fi` directories, not their subdirectories
  ([command line](cli.md#watched-files)).
- **Build what you ship with plain fpc.** A program built by hotfpc carries the agent and
  keeps its symbols.
