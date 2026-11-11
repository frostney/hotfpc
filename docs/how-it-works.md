# How hotfpc works

## Two parts

- **The driver** ([`source/HotFPC.pas`](../source/HotFPC.pas) and the `HotFPC.*` units
  next to it) is the `hotfpc` program you run. It builds and starts your program, watches
  its sources, compiles them, checks interfaces, and talks to the agent over TCP on
  127.0.0.1. TCP works the same on every system, including between a program under Wine
  and a driver outside it.
- **The agent** ([`source/HotFPC.Agent.pas`](../source/HotFPC.Agent.pas)) is a unit that
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
Instead, hotfpc carries the agent's source inside its own binary
([`source/HotFPC.AgentSource.inc`](../source/HotFPC.AgentSource.inc)). On start it writes
the source out and compiles it with your fpc and your target options into `.hot/agent/`.
One hotfpc binary therefore works with every fpc from 3.2.2 on, including cross targets,
and stays a single file you can copy anywhere. It also can't be paired with an agent of
another version.

`build.pas` regenerates the include file from `HotFPC.Agent.pas` on every build. The file is committed, so `fpc -Fusource source/HotFPC.pas` builds hotfpc from a
copy of `source/` alone.

Because your compiler builds it, the agent is written for what fpc 3.2.2 accepts. It
doesn't use `SysUtils`, which would change how a program without it reports runtime errors.
It is compiled into a directory without its source because fpc 3.3.1's `-Fa` can't load a
unit that the compiler decides to recompile.

hotfpc runs fpc in the current directory, so relative paths in options, in response files
and in a local `fpc.cfg` mean what they mean to fpc. It adds `-Xs-` to keep the program's
symbols and `-FU`/`-o` to build into `.hot/`.

## One save

1. The driver sees the change. It checks file sizes and times every 10 ms and file contents
   twice a second. The content check catches an edit of the same size within the same
   second, which the compiler's own check misses. The driver then deletes the compiler's
   record of the changed units so they're recompiled. A changed include file causes every
   unit to be recompiled; units whose object file comes out the same are left alone.
2. fpc compiles without linking (`-Cn`).
3. ppudump reads the interface of each changed unit. A field that moved or changed its type
   without changing a size is invisible in the object file, so this check catches it.
4. The agent reads the object files (Mach-O, ELF or COFF) and places their code and data
   next to the program. Like a linker, it works out which parts the program can reach.
   Type information that nothing uses is never read, because it may refer to things the
   program doesn't have. Then the agent binds every name:
   - A variable the program already has keeps its address and its value.
   - A function keeps its first address, which gets a jump to the new code. That keeps
     `@Proc`, method pointers and virtual method tables valid.
   - A virtual method table is updated in place when its shape is unchanged.

   The agent applies the relocations, stops the program's other threads for the few
   microseconds the writes take, and redirects.

### When a restart is needed

An edit needs a restart when the running state depends on what it changes:

- a variable's size;
- a class's instance size or virtual method table shape;
- a record's or object's layout in an interface;
- a new unit or a new thread variable;
- a routine of the runtime that the program was linked without.

The program keeps running with its old code, and hotfpc names the declaration.

## Per system

- **macOS arm64.** The program's code pages are signed, so the agent copies a page, writes
  the copy, and maps it back (`VM_PROT_COPY`). New code goes into `MAP_JIT` memory. macOS
  checks a newly linked executable on its first start, which can take seconds, so the
  driver waits up to 60 s.
- **Linux.** The agent calls `mprotect` around the writes and stops other threads with a
  signal whose handler waits. fpc's x86-64 code reaches variables through 32-bit absolute
  addresses, so new code and data go below 2 GiB when the program is loaded there. On
  x86-64 Linux, fpc 3.3.1 makes thread variables native ELF TLS variables. An existing one
  keeps its offset, and a new one needs a restart.
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
