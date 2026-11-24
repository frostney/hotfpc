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
  instruction it rewrites.
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
   check misses. The driver then deletes the compiler's
   record of the changed units so they're recompiled. A changed include file causes every
   unit to be recompiled; units whose object file comes out the same are left alone.
2. fpc compiles without linking (`-Cn`). fpc reads the files one after the other, so a
   source that changes during the compile, such as the second file of a save written a
   moment after the first, or the next save, may be read before or after its change. When
   the sources changed, the driver neither swaps nor reports what fpc made: it waits for
   them to settle and compiles again. It checks a save's compile to assembler (step 4), the
   link of a restart and the first build the same way: a save during the first build is
   compiled as soon as the program runs. A source that changes faster than fpc compiles, such
   as a file a generator keeps rewriting, holds a save back for three compiles, links or
   compiles to assembler at most, each after a wait of a second at most for the files to
   settle: the fourth is used as it is. For a Windows program whose
   sizes step 4 checks, such a save needs a restart instead: its object files and its
   assembler may come from different sources, so the sizes counted may not be the code's.
   The same goes when the times of the sources can't show a save that came and was put
   back during the compiles, at the same size: the time of a file written less than 20 ms
   before the compile, about a tick of the clock behind file times, or less than two
   seconds before when the file system keeps whole seconds. For such a program the driver
   waits 22 ms for the files to settle, so that a save it saw isn't one of them.
3. ppudump reads each changed unit: the interface from its JSON output, and the
   implementation section from its text output, which the JSON leaves out. A field that
   moved, or a field or variable that changed its type without changing a size, is
   invisible in the object file, so this check catches it. The check compares each record
   and class and the type of each variable with the running unit's, by name, because the
   compiler numbers types again on every compile.
4. For a Windows program whose changed units have a variable with an initial value or a
   typed constant, fpc compiles the program again, to assembler (`-s -Aas`), into
   `.hot/asm/`, which keeps units of its own. The program and each changed unit compile
   there again, and their assembler from before is removed first, so one that fpc doesn't
   write has no size rather than an earlier one. The driver counts each one's bytes there and
   compares them with the running program's: a COFF object doesn't show one that grows (see
   [Per system](#per-system)). The running program's sizes come from the same compile when
   the program starts and when it starts over, and a swap adds those of the variables it
   brings. A variable keeps its first size until the program starts over, also when a save
   removed it: the agent keeps it at its first address, so bringing it back larger needs a
   restart. When fpc can't write the assembler at the start, the check is off for the run
   and hotfpc says so. When it can't for a save, or couldn't when the program started over,
   that save needs a restart: a size it can't see may have grown. The object file names the
   data the assembler must give a size for, a section of its own for each: one it names
   that the assembler has no size for, for this save or when the program started, needs a
   restart too, and so does a save when an object file can't be read. It costs about as
   much as the first compile.
5. The agent reads the object files (Mach-O, ELF or COFF) and places their code and data
   next to the program. Like a linker, it works out which parts the program can reach.
   Type information that nothing uses is never read, because it may refer to things the
   program doesn't have. Then the agent binds every name:
   - A variable the program already has keeps its address and its value.
   - A function keeps its first address, which gets a jump to the new code. That keeps
     `@Proc`, method pointers and virtual method tables valid.
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
fixed in the next save, so the next save that builds starts the program again. A restarted
program that ends with 0, and the first program in every case, end hotfpc as before.

## Per system

- **macOS arm64.** The program's code pages are signed, so the agent copies a page, writes
  the copy, and maps it back (`VM_PROT_COPY`). New code goes into `MAP_JIT` memory. macOS
  checks a newly linked executable on its first start, which can take seconds, so the
  driver waits up to 60 s. A restart links a new executable, so it waits for that check too.
- **Linux.** The agent calls `mprotect` around the writes and stops other threads with a
  signal whose handler waits. Libraries start threads that block every signal (Mesa's
  software renderer starts one per core). The agent doesn't send those the signal, because
  real-time signals queue and would pile up. It checks again once the others have stopped:
  a thread that has unblocked the signal since gets it and is waited for, and one that
  still blocks it has to be waiting in the kernel, or the agent lets everything run and
  tries again. A sleeping thread can wake during the swap, so the agent then writes each
  entry's jump in one 8-byte store: such a thread runs either the old entry or the new
  jump. fpc aligns functions, so the jump fits; if one didn't, the swap would be refused. A
  thread that doesn't stop within 2 s means the swap is refused. fpc's x86-64 code
  reaches variables through 32-bit absolute addresses, so new code and data go below
  2 GiB when the program is loaded there. On aarch64, gas refers to a variable of the
  implementation section through the symbol of its section plus an offset; the agent maps
  such a reference back to the variable, so it keeps its value. On x86-64 Linux, fpc 3.3.1
  makes thread variables native ELF TLS variables. An existing one keeps its offset, and a
  new one needs a restart.
- **Windows.** The executable keeps a COFF symbol table when it's linked with `-Xs-`, which
  hotfpc passes. `SuspendThread` stops the other threads. On x86-64 the agent also checks
  that no thread is stopped inside the five bytes of an entry it overwrites, and retries if
  one is. New code's unwind tables are registered with `RtlAddFunctionTable`, so exceptions
  pass through it.
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
