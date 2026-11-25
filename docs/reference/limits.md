# Limits

What hotfpc doesn't do, and why. [What a save does](../guides/saves-and-restarts.md) lists
the edits that need a restart; these are the limits around them.

- **A unit's initialization section doesn't run again.** The program ran it when it
  started. A swap puts the new code in place, and hotfpc notes that the section changed.
- **A new unit needs a restart.** Its initialization section has never run, and can't run
  on the agent's thread.
- **A routine shorter than the jump at its entry, right before another, needs a
  restart.** A swap writes a 5-byte jump at the entry of each routine on x86-64. With
  `{$codealign proc=1}`, an assembler routine can be shorter than that and the next one can
  follow right after it; then every save of its unit restarts the program
  ([Output](output.md#restart-needed)).
- **On x86-64, a routine that calls another within its first 5 bytes needs a restart.**
  A thread waiting in the routine it called would return into the middle of the jump that
  a swap writes there. An assembler routine can start with such a call, through a register
  or memory. The agent can't tell where the instructions of an entry begin, so it also
  takes bytes that could be such a call for one: rarely, a routine that starts with another
  instruction restarts too ([Output](output.md#restart-needed)).
- **On x86-64, a save restarts while a thread waits to resume within a routine's first 5
  bytes.** A signal handler, or on Windows an exception handler, keeps where the thread it
  interrupted resumes in its frame. When a handler that interrupted a routine there waits,
  as one that sleeps does, the jump a swap writes is in the way: the agent tries again, up
  to 200 times (about half a second in the scenarios on Linux x86-64), and then restarts
  the program ([Output](output.md#restart-needed)). It looks for that address in every word of each
  stopped thread's stack, so rarely a value that only looks like one restarts a save too.
  A handler that moves where its thread resumes to within a routine's first bytes after
  the swap isn't caught.
- **On Linux, a thread that blocks the agent's signal and sleeps isn't stopped.** The
  agent stops threads with a signal (signal 40), which a thread that blocks it, such as
  one of the threads some libraries start that block every signal, never takes. When the
  agent finds such a thread asleep in the kernel, it goes on without it: the thread can
  wake while the agent writes, and run, or start a thread, during the swap; the agent
  writes each entry in one 8-byte store for it
  ([how it works](../internals/how-it-works.md#per-system)). When it finds one running, it
  lets everything run and tries again.
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
  program's signed code pages and puts new code into memory that is writable and
  executable (`MAP_JIT` memory on Apple silicon), which the hardened runtime allows only
  with entitlements.
- **Programs for 32-bit targets aren't supported.** The agent is written for macOS on
  arm64 and x86-64, Linux on arm64 and x86-64, and Windows on x86-64. For any other
  target its compile stops with an error, and hotfpc says the agent did not compile.
- **hotfpc watches directories, not trees.** It watches the files directly in the
  program's directory and in the `-Fu` and `-Fi` directories, not their subdirectories
  ([command line](cli.md#watched-files)).
- **Build what you ship with plain fpc.** A program built by hotfpc carries the agent and
  keeps its symbols.
