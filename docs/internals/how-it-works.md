# How hotfpc works

> **Audience: contributors.** How hotfpc does what the [guides](../guides/introduction.md)
> describe. Using hotfpc needs none of it.

## Two parts

- **The driver** ([`source/HotFPC.pas`](../../source/HotFPC.pas)) is the `hotfpc` program you
  run. It builds and starts your program, watches its sources, compiles them, checks
  interfaces, and talks to the agent over TCP on 127.0.0.1. TCP works the same on every
  system, including between a program under Wine and a driver outside it.
- **The agent** ([`source/HotFPC.Agent.pas`](../../source/HotFPC.Agent.pas)) is a unit that
  hotfpc compiles into your program. It does the actual swap, from inside the program.

## Why an agent inside the program

Free Pascal has no way to replace code in a running program. There is no runtime linker
for units and no reloadable module system. Shared libraries would only help if the program
were written around them: the code to reload would have to live in a library and its state
somewhere else. hotfpc's aim is a program you don't change.

So something has to put new code into the process and point the old code at it, and that
works best from inside:

- **Permissions.** Rewriting code pages needs the process's own rights. On macOS, code
  pages are signed and another process may not touch them without special entitlements. On
  Linux, ptrace is often restricted. Inside the program, `mprotect`, `VM_PROT_COPY` and
  `VirtualProtect` are ordinary calls.
- **Knowing where things are.** The agent sees where the program was loaded (address space
  layout randomisation moves it on every start), reads its symbol table, and binds the new
  code to the program's existing variables and functions.
- **Stopping threads safely.** It stops the program's other threads only for the few
  microseconds of the writes, and checks that none of them is in the middle of an
  instruction it rewrites, or will resume there.
- **Exceptions.** On Windows it registers the new code's unwind tables with the system, so
  exceptions pass through the new code.

hotfpc adds the agent with fpc's `-Fa` option, which loads a unit before the program's own
`uses` clause. Your source doesn't change, and the agent is initialised before any of your
units. It starts a thread that waits for the driver's commands. Without the environment
variables hotfpc sets, it does nothing.

## Why the agent's source is embedded

The agent has to be compiled by the same compiler, with the same target options, as the
program it goes into:

- a compiled unit (`.ppu`/`.o`) only works with the exact compiler build and runtime library
  that produced it;
- the agent must match the program's target (`-T`, `-P`), code generation options (`-Cp`,
  `-Cf`) and unit paths.

Shipping precompiled agents would mean one for every fpc version, target and option set.
Instead, hotfpc carries the agent's source inside its own binary, as a resource made from
[`source/HotFPC.rc`](../../source/HotFPC.rc). On start it writes
the source out and compiles it with your fpc and your target options into `.hot/agent/`.
One hotfpc binary therefore works with every fpc from 3.2.2 on, including cross targets,
and stays a single file you can copy anywhere. It also can't be paired with an agent of
another version.

fpcres compiles `HotFPC.rc` into `HotFPC.res` before fpc builds hotfpc, so the resource is
always the `HotFPC.Agent.pas` next to it ([build-system.md](build-system.md#the-embedded-agent)).

Because your compiler builds it, the agent is written for what fpc 3.2.2 accepts. It
doesn't use `SysUtils`, which would change how a program without it reports runtime errors.
It is compiled into a directory without its source because fpc 3.3.1's `-Fa` can't load a
unit that the compiler decides to recompile.

hotfpc runs fpc in the current directory, so relative paths in options, in response files
and in a local `fpc.cfg` mean what they mean to fpc. It adds `-Xs-` to keep the program's
symbols and `-FU`/`-o` to build into `.hot/`.

## One save

1. The driver sees the change. It checks file sizes and times every 10 ms, the times as
   finely as the file system keeps them, and file contents twice a second. The content
   check catches an edit of the same size that the time doesn't show, such as one within
   the same second where the file system keeps whole seconds, which the compiler's own
   check misses. A save that leaves a file empty waits until half a second after the
   driver saw the file emptied, when the driver looks again, and is compiled then if the
   file is still empty: some editors empty a file before they write it. A file saved
   meanwhile waits with it, and doesn't move that look later. The driver keeps each such
   file by its whole path, as the file system names it. It then deletes the compiler's
   record of the changed units so they're recompiled. A changed include file causes every
   unit to be recompiled; units whose object file comes out the same are left alone.
2. fpc compiles without linking (`-Cn`). fpc reads the files one after the other, so a
   source that changes during the compile, such as the second file of a save written a
   moment after the first, or the next save, may be read before or after its change. When
   the sources changed, the driver neither swaps nor reports what fpc made: it waits for
   them to settle and compiles again. It checks a save's compile to assembler (step 4), the
   link of a restart and the first build the same way: a save during the first build makes
   the driver build the program again before it starts it, also when that build, or its
   compile to assembler, failed, and from scratch: the units of the build set aside, such
   as one the save no longer uses, are not the program's. Before that build it waits for a
   file the save emptied as it does in step 1, but about a second and a half at most for the
   settle and that wait together, also while saves keep emptying files. A source that
   changes faster
   than fpc compiles, such as a file a generator keeps rewriting, holds a save back for three
   compiles, links or compiles to assembler at most, each after a wait of a second at most
   for the files to settle: the fourth is used as it is. For a Windows program whose sizes
   step 4 checks, such a save needs a restart instead: its object files and its assembler
   may come from different sources, so the sizes counted may not be the code's. The same
   goes when the times of the sources can't show a save that came and was put back during
   the compiles, at the same size: the time of a file written less than 20 ms before the
   compile, about a tick of the clock behind file times, or less than two seconds before
   when the file system keeps whole seconds. For such a program the driver waits 22 ms for
   the files to settle, so that a save it saw isn't one of them. When either happens to the
   build or link the program starts from, its sizes are unknown, and until it starts over
   again every save that needs them needs a restart.
3. ppudump reads each changed unit: the interface from its JSON output, and the
   implementation section from its text output, which the JSON leaves out. A field that
   moved, or a field or variable that changed its type without changing a size, is
   invisible in the object file, so this check catches it. The check compares each record
   and class and the type of each variable with the running unit's, by name, because the
   compiler numbers types again on every compile. The program file has no `.ppu`, so its
   declarations get only the checks of sizes.
4. For a Windows program whose changed units have a variable with an initial value or a
   typed constant, fpc compiles the program again, to assembler (`-s -Aas`), into
   `.hot/asm/`, which keeps units of its own. The program and each changed unit compile
   there again, and their assembler from before is removed first, so one that fpc doesn't
   write has no size rather than an earlier one. The driver counts each one's bytes there and
   compares them with the running program's: a COFF object doesn't show one that grows (see
   [Per system](#per-system)). The running program's sizes come from a compile to assembler
   after the first build, or after the link of a restart, and before the check of the
   sources that covers both: they come from the sources the program was built from, and
   cover a unit the link adds to the program. A swap adds
   the sizes of the variables it brings. A variable keeps its first size until the program
   starts over, also when a save removed it: the agent keeps it at its first address, so
   bringing it back larger needs a restart. When fpc can't write the assembler for a save,
   or couldn't when the program started or started over, that save needs a restart: a size
   it can't see may have grown. At the start hotfpc says so; the check stays on, with the
   program's sizes unknown until a restart. The object file names the data the assembler must give a size for, a section of
   its own for each: one it names that the assembler has no size for, for this save or when
   the program started, needs a restart too, and so does a save when an object file can't
   be read. It costs about as much as the first compile.
5. The agent reads the object files (Mach-O, ELF or COFF) and places their code and data
   next to the program. Like a linker, it works out which parts the program can reach.
   Type information that nothing uses is never read, because it may refer to things the
   program doesn't have. Then the agent binds every name:
   - A variable the program already has keeps its address and its value.
   - A function keeps its first address, which gets a jump to the new code. That keeps
     `@Proc`, method pointers and virtual method tables valid. The jump must end before
     the next symbol or the end of the section, or it would break the routine after it:
     when an entry has less room, the save needs a restart. On x86-64 it must not replace
     a call either: a thread waiting in the routine it called would return into the middle
     of the jump, whether or not the agent can stop that thread and see where it is. Any
     bytes there that could be such a call make the save need a restart. Nor may a thread
     be about to resume inside those bytes: a signal handler, or on Windows an exception
     handler, keeps where the thread it interrupted resumes in its frame, on the thread's
     stack. With the threads stopped, the agent reads each one's stack, from its stack
     pointer to the end of the memory that holds it, for a word that is an address within
     the bytes a jump replaces. While there is one, it lets the threads run and tries
     again, as it does for a thread stopped inside them; when one stays, the save needs a
     restart. A value that only looks like such an address counts too.
   - A virtual method table is updated in place when its shape is unchanged.
   - A literal, such as a floating point constant, is new with the new code. fpc numbers a
     unit's literals in the order it makes them (`_$U$_Ld1` with fpc 3.2, local `.Ld1` labels
     with 3.3.1), so the number says nothing about which constant it is.

   The agent applies the relocations, stops the program's other threads for the few
   microseconds the writes take, and redirects.

### When a restart is needed

An edit needs a restart when the running state depends on what it changes. The driver
finds most cases in steps 3 and 4, and the agent the rest in step 5;
[What a save does](../guides/saves-and-restarts.md#what-needs-a-restart) lists them, and
[Output](../reference/output.md#restart-needed) gives every reason as hotfpc prints it.
hotfpc names the declaration and starts the program over, the way webpack reloads a page
when a module can't be updated in place. With `--no-restart`, the program keeps running
its old code instead.

### Starting over

1. fpc links the units of the compile that needed the restart into `.hot/next/`. If the link
   fails, hotfpc prints the errors and the program keeps running.
2. hotfpc stops the program the way the system ends a process: `SIGTERM` and then `SIGKILL`
   on Linux and macOS, `TerminateProcess` on Windows. Its state is gone, and its
   finalization sections don't run. With `--run`, the process hotfpc stops is the launcher.
   hotfpc waits up to 2 s for the agent's connection to close, which happens when the
   program has ended, and says so if it doesn't.
3. It moves the new program, and on Windows the linker's map, over the old one. A program's
   file stays locked on Windows while the program runs, which is why the link goes
   somewhere else first.
4. It starts the program with the same arguments and environment. The agent connects to the
   same port as before, and the units of the new program are the base of later swaps.

A restarted program that ends before its agent connects, or ends later with a non-zero exit
code or by a signal, doesn't end hotfpc: a runtime error in an initialization section is
fixed in the next save, so the next save that builds starts the program again. That holds
for exit code 0 too while its agent hasn't connected. A restarted program that ends with 0
after its agent connected, and the first program in every case, end hotfpc.

## Per system

- **macOS.** The agent stops the other threads with `thread_suspend`. A thread that runs
  until it's suspended can start another after the agent listed them, so the agent lists
  the threads again until a list has none it hasn't suspended. A thread that ended after
  the list was taken is left out. When a thread can't be suspended for another reason, or
  on x86-64 its state can't be read, the agent lets the others run and tries again, and it
  resumes only the threads it suspended.
- **macOS arm64.** The program's code pages are signed, so the agent copies a page, writes
  the copy, and maps it back (`VM_PROT_COPY`). New code goes into `MAP_JIT` memory. macOS
  checks a newly linked executable on its first start, which can take seconds, so the
  driver waits up to 60 s. A restart links a new executable, so it waits for that check too.
- **macOS x86-64.** Code pages are rewritten the same way. The jump at an entry is 5 bytes,
  so a patch can reach into the next page, and the agent copies every page it touches.
  `thread_get_state` says where each stopped thread is, and the agent retries while one is
  inside an entry it rewrites. Its stack pointer and `mach_vm_region` give the stack the
  agent reads. A handler on an alternate signal stack keeps where it returns to there, and
  a handler it interrupted is on the thread's own stack, which the agent then reads whole:
  the memory that holds the thread's pthread data, or `argv` for the main thread. New code
  goes into ordinary writable and executable memory; `MAP_JIT` is for Apple silicon. fpc
  reaches variables through 32-bit offsets from the instruction or through the GOT, so new
  code and data go within 2 GiB of the program. A Mach-O x86-64 object keeps each addend in
  the instruction's bytes, counted from the end of the instruction.
- **Linux.** The agent calls `mprotect` around the writes and stops other threads with a
  signal whose handler waits. It reads the threads from `/proc/self/task` with
  `getdents64` into a buffer of its own, so that nothing is allocated while a stopped
  thread may hold a lock, and reads them again until a list has none it hasn't met before,
  as on macOS; a thread that has ended may have started another before it did. A list read
  while a thread ends can leave out another, so the agent reads the list again while the
  `Threads:` line of the status file counts more threads than the list holds. A thread
  that ended before its signal is left out. When the list can't be read, or the signal
  can't be sent for another reason, the agent lets everything run and tries again; when
  new threads keep coming for 2 s, the swap is refused. Libraries start threads that block
  every signal (Mesa's software renderer starts one per core), and so the signal the agent
  stops threads with. The agent doesn't send a thread that blocks it the signal, because
  real-time signals queue and would pile up. It checks again once the others have stopped:
  a thread that has unblocked the signal since gets it and is waited for, and one that
  still blocks it has to be waiting in the kernel, or the agent lets everything run and
  tries again. A sleeping thread can wake during the swap, so the agent then writes each
  entry's jump in one 8-byte store: such a thread runs either the old entry or the new
  jump. fpc aligns functions, so the jump fits; if one didn't, the swap would be refused. A
  thread that doesn't stop within 2 s means the swap is refused. On x86-64 the handler
  notes each thread's stack pointer, and `/proc/self/maps` gives the memory it is in; when
  the thread is on its alternate signal stack, the handler notes where that ends, and the
  agent reads the thread's own stack whole too. A thread that blocks the signal and sleeps
  is read from where `/proc/self/task/<thread>/syscall` says it sleeps. fpc's x86-64 code
  reaches variables through 32-bit absolute addresses, so new code and data go below
  2 GiB when the program is loaded there. On aarch64, gas refers to a variable of the
  implementation section through the symbol of its section plus an offset; the agent maps
  such a reference back to the variable, so it keeps its value. On x86-64 Linux, fpc 3.3.1
  makes thread variables native ELF TLS variables. An existing one keeps its offset, and a
  new one needs a restart.
- **Windows.** The executable keeps a COFF symbol table when it's linked with `-Xs-`, which
  hotfpc passes. `SuspendThread` stops the other threads. The agent goes through them with
  `NtGetNextThread`, which opens one after another and allocates nothing (a Toolhelp
  snapshot takes its memory from the process heap, whose lock a suspended thread may hold),
  and goes through them again until a pass meets none it hasn't met before, as on macOS; new
  threads that keep coming for 2 s refuse the swap. On Windows `NtGetNextThread` leaves out a
  thread it can't open, so after the passes the agent lists the IDs of the process's threads
  with `NtQuerySystemInformation`, which runs in the kernel there; one that the agent didn't
  suspend and that hasn't terminated ran after the passes, and fails the stop. Wine's
  `NtGetNextThread` fails on such a thread instead, and Wine allocates for that list, so
  under Wine the agent doesn't make it. A thread that ended is left out. When a list can't
  be made, or a thread can't be suspended for another reason or its context can't be read,
  the agent lets the others run and tries again, and it resumes only the threads it
  suspended. Wine before 6.8 has no `NtGetNextThread`, and nothing else lists the threads
  again without allocating while some are suspended, so there every swap is refused. Under
  Wine a thread exists before it has started, with no TEB yet, and `GetThreadContext` would
  wait until it starts, which a suspended creator never lets it do; suspended, such a thread
  stops before it runs any of the program's code, so the agent keeps it suspended without
  its context. On x86-64 the agent also checks that no thread is stopped inside the five
  bytes of an entry it overwrites, and retries if one is; `GetThreadContext` gives its stack
  pointer, and `VirtualQuery` the committed memory of the stack it reads. New code's unwind
  tables are registered with `RtlAddFunctionTable`, so exceptions pass through it.
  - fpc's COFF objects refer to everything in the same unit as a section plus an offset.
    The agent maps those references back to the symbols they mean, allowing for an
    immediate's length that fpc folds into the offset, so a unit's own variables keep
    their values.
  - fpc 3.2 gives an implementation-section variable no symbol at all, only a section
    named after it. hotfpc links Windows programs with `-Xm`, and the agent finds those
    sections' addresses in the linker's map.
  - fpc gives a variable with an initial value, and a typed constant, a section of its own
    and pads it to 16 bytes, on Linux and Windows alike. On Linux the agent takes the size
    from the ELF symbol. COFF symbols have no size, and the unit file doesn't cover every
    case: fpc writes none for the program, a routine's typed constant is never in it, and
    fpc 3.2 leaves out an implementation section's typed constant too. fpc's assembler
    output lists each one's data, so for a
    Windows program the driver compiles to assembler as well (step 4 of [One
    save](#one-save)) and finds such a variable growing (`Integer = 0` to `Int64 = 0`)
    there.
  - fpc's Windows linker always leaves out code the program never reaches. New code that
    calls a runtime routine the program never called (`SysUtils.Supports`, for example)
    needs a restart. Linux and macOS link the whole unit.
- **Wine.** hotfpc translates the paths it gives a program under Wine to `Z:\...`.

## A compiler bug

fpc 3.3.1 from [fpc-toolchain](https://github.com/frostney/fpc-toolchain) up to release
3.3.1+3, for x86-64, at `-O1` and above, assigned a loop counter and a temporary string to
the same register while the counter was still live. In hotfpc's driver, that first caused
a crash ("List index (1619053936) out of bounds"). After the loop was rewritten, it silently
found no changed files.

The cause was the toolchain's patch that moves `raise` and `Halt` branches after the
routine's code: a register that such a branch used first had its live range start after
the routine's end. Patch 0122 fixes it
([fpc-toolchain#10](https://github.com/frostney/fpc-toolchain/pull/10)), and release
3.3.1+4 includes it.

`fpc -iV` prints 3.3.1 for both the old and the fixed builds, and the agent is compiled by
whatever 3.3.1 build you have. So the agent turns optimisation off for every 3.3.1; it
doesn't need the speed. Build hotfpc itself with fpc 3.2.2, or with 3.3.1+4 or later.
