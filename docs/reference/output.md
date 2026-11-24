# Output

Every line hotfpc prints starts with `[hot]`. Everything else on the terminal is your
program's output, or fpc's errors when the first build fails. `--log FILE` writes a copy of
the `[hot]` lines with a timestamp, from the version check on, except the lines in
[Before the program starts](#before-the-program-starts) that are about ppudump, the agent,
the port and the program's connection. `--quiet` leaves out the start line and the closing
summary. The scenarios and `scripts/record-demo.py` parse these lines, so their wording is
kept stable.

Below, `<...>` stands for what hotfpc fills in. The examples are from real runs: the
scenarios and `examples/demo`, on Linux x86-64 with fpc 3.2.4-rc2+1, on 2026-11-24.

## The start

```text
v1: built in <ms> ms, started in <ms> ms, <n> units of its own, watching <n> files
```

The program built and its agent connected. "Units of its own" counts the object files fpc
made for the program, the program file included; "watching" counts the source files in the
[watched directories](cli.md#watched-files).

```text
[hot] v1: built in 228.0 ms, started in 5.0 ms, 2 units of its own, watching 2 files
```

## The outcome of a save

Every save ends in one of five ways, and the closing summary counts each:

| Line | What happened | Counted as |
| --- | --- | --- |
| `v<N> swapped: ...` | The new code runs from the next call on, and the program keeps its state. | reloads applied |
| `restart needed: ...` | The edit changes something the running program depends on. Unless `--no-restart`, hotfpc starts the program over next. | refused |
| `v<N> restarted: ...` | The program was linked again and started over with the new code. Its state is gone. | restarts |
| `not swapped: ...` | The source changed, but the code fpc made from it didn't. | without a change in code |
| `error: ... (nothing changed)` | fpc or the agent failed. The program keeps running the code it had. | failed to compile |

`<N>` is the version: 1 is the program as it started, and each swap and each restart adds
one. A restart counts, and adds one, as soon as hotfpc starts the new program, even when
that program then ends before its agent connects.

### Swapped

```text
v<N> swapped: <units>: <n> functions redirected (<n> with other code, <n> new), <n> variables and tables kept, <n> new, <n> bytes; <ms> ms after the save was seen (settle <ms>, compile <ms>, interface check <ms>, load <ms> of which in the program <ms>)
```

```text
[hot] v2 swapped: scene: 2 functions redirected (1 with other code, 0 new), 1 variables and tables kept, 0 new, 432 bytes; 193.0 ms after the save was seen (settle 4.0, compile 138.0, interface check 30.0, load 19.0 of which in the program 17.867)
```

| Part | Meaning |
| --- | --- |
| `<units>` | The units whose object files changed. The program file is named after its source file, such as `demo` for `demo.pas`. A changed include file can change several. |
| functions redirected | The program's functions that now jump to their new code. |
| with other code | Of the unit's functions, those whose code differs from the running version. |
| new | Functions the running version didn't have. |
| variables and tables kept | Variables, virtual method tables and type information the new code shares with the program: they keep their addresses and values. |
| new (after "kept") | Data the new code brings: new variables, constants, literals. |
| bytes | Code and data in the loaded object files. |
| ms after the save was seen | From the moment hotfpc saw the change to the moment the new code was in place. |
| settle | Waiting for the files to stop changing (`--settle`). |
| compile | fpc compiling the changed units, without linking. |
| interface check | Comparing layouts with ppudump, and for a Windows program the sizes in fpc's assembler, including that compile. |
| load | Handing the object files to the agent until it answered. |
| of which in the program | The agent's own time: reading, placing, binding and redirecting. |

A swap can be followed by notes:

| Note | What it means |
| --- | --- |
| `note: <name> still had its initial value; set to the new one` | A variable with an initial value, or a typed constant, got a new initial value, and the program hadn't changed it: it now has the new value. |
| `note: the initial value of <name> changed; the running value is kept` | The same, but the program had changed it: it keeps the value it has. |
| `note: resource string <name> changed; the running text is kept` | A `resourcestring` changed. The program keeps the text it has. |
| `note: <name> changed; the running copy is kept` | Other data the program already has, such as a table, changed in a way that doesn't need a restart. The program keeps its copy. |
| `note: the initialization section of <unit> changed; it is not run again` | The section isn't run again. The new code is in place for the next start. |
| `note: the main block changed; the frame that is running keeps its old code` | The program's main block is already running and keeps its old code. Keep the code you change in routines and units. |
| `note: <name> is gone from the source; its old code stays for callers that were not recompiled` | A function was removed or its signature changed. Code that still calls it keeps calling the old one. At most four are named. |
| `note: ... and <n> more functions gone from the source` | Follows the fourth. |
| `note: <name> exists in the program but not in the version of <unit> the agent knows; kept without a check` | The new code uses a variable of the program that the agent couldn't compare with an earlier version. It is bound to the program's and keeps its value. |

Names of symbols in notes and in the agent's reasons below are the compiler's: upper case,
with the unit and the parameters, such as `U.SPEED` or `U.AREA(LONGINT):LONGINT`. Units are
named after their files (`u`, `scene`), and the check of layouts names a declaration as the
source spells it (`scene.Score`).

### Restart needed

```text
restart needed: <reason> (not applied; compile <ms> ms)
```

The reason names the declaration in the way. hotfpc finds most of them before the agent
sees the new code; the agent finds the rest when it binds it. One save can print several.

| Reason | What changed | Scenario |
| --- | --- | --- |
| `<unit>.<declaration>: the declaration changed its layout or type` | A variable's type, or a record's or class's fields, by ppudump: also when the size stays the same (`Integer` to `Single`, two fields swapped). | `globals`, `records`, `hidden`, `restart` |
| `unit <unit> is not part of the running program` | The program now uses a unit of its own that it didn't use when it started, or a unit was renamed. | `newunit`, `rename`, `linkfail` |
| `variable <name> changed size from <n> to <n> bytes` | A variable, a variable with an initial value or a typed constant changed size. | `typedconst`, `progvar`, `localconst` |
| `<name> changed size from <n> to <n> bytes` | Other data the program has changed size, such as the resource string tables when a unit of the runtime is added. | `newunit` |
| `class <name>: instance size changed from <n> to <n> bytes` | A class gained or lost fields. | |
| `class <name>: the virtual method table changed from <n> to <n> slots` | A class gained or lost a virtual method, or one it inherits did. | `classes` |
| `class <name>: the parent class changed` | A class derives from another class now. | |
| `type <name>: its layout or type information changed` | A type's run-time type information changed, such as an interface that gained a method. | `interfaces` |
| `<name> was <code or data> and is now <data or code>` | A name went from a routine to data, or the other way round. | |
| `unit <unit> gained the thread variable <name>` | A new `threadvar`: every thread's copy is laid out when the thread starts. | |
| `unit <unit> gained its first thread variable` | The same, in a unit that had none. | |
| `the thread variable <name> changed size from <n> to <n> bytes` | A `threadvar` changed size. | |
| `the thread variables of unit <unit> changed` | The unit's `threadvar` block changed. | `threadvars` |
| `<unit> uses <name>, which the running program does not contain` | The new code calls a routine that isn't in the program, such as one of a runtime unit it wasn't linked with. On Windows, also a runtime routine the program never called: fpc's Windows linker leaves those out. | `newunit`, `interfaces` on Windows |
| `no room left for new code or data` | The memory near the program that new code and data go into is used up. | |
| `no room left for call islands` | The same, for the jumps the agent puts between old and new code. | |
| `no room left for data` | The same, for the addresses new code loads through. | |
| `hot reloading is off in this process: no free memory within reach of the program's code` | The agent found no memory close enough to the program's code for new code, so nothing can be swapped in this run. | |
| `an earlier reload failed after some functions were already redirected` | An earlier swap stopped halfway (see the errors below). Until the program starts over, no swap is applied. | |

Examples from the scenarios:

```text
[hot] restart needed: u.Hidden: the declaration changed its layout or type (not applied; compile 127.0 ms)
[hot] restart needed: class U.TANIMAL: the virtual method table changed from 27 to 28 slots (not applied; compile 110.0 ms)
[hot] restart needed: variable MAIN.CALLS changed size from 4 to 8 bytes (not applied; compile 109.0 ms)
[hot] restart needed: unit extra is not part of the running program (not applied; compile 112.0 ms)
[hot] restart needed: u uses MATH.POWER(EXTENDED,EXTENDED):EXTENDED, which the running program does not contain (not applied; compile 100.0 ms)
```

### Restarted

```text
v<N> restarted: the program starts over; <ms> ms after the save was seen (link <ms>, stop <ms>, start <ms>)
```

```text
[hot] v5 restarted: the program starts over; 387.0 ms after the save was seen (link 243.0, stop 2.0, start 6.0)
```

"link" is fpc linking the program again, "stop" is stopping the old program, and "start" is
from starting the new one until its agent connected. With `--no-restart`, a
`restart needed` line isn't followed by this, and the program keeps its old code.

### Not swapped

```text
not swapped: the generated code is the same (compile <ms> ms)
```

The source changed, but fpc made the same object files from it: a comment, blank lines, or
a change to code that nothing uses.

### Errors

```text
error: <message> (nothing changed)
```

When fpc fails, the message is one of its errors, with the file and line, and at most six
are shown:

```text
[hot] error: main.pas(14,1) Error: Error while linking (nothing changed)
```

A failed compile, a failed link for a restart and a swap the agent couldn't apply leave the
running program as it was: it keeps running the code it had, and the next save tries again.
The one exception is a swap that stopped halfway, below.

Other errors hotfpc reports:

| Error | What it means |
| --- | --- |
| `error: the program did not answer (nothing changed)` | The agent didn't reply to the load. |
| `error: cannot replace <program> (the program is not running; the next save that builds starts it again)` | A restart linked the new program but couldn't put it in place of the old one, which had already stopped. On Windows a program's file stays locked for a moment; hotfpc tries for 5 s. |

When the agent couldn't stop the program's threads or write its code, the swap isn't
applied:

| Error | Where | What it means |
| --- | --- | --- |
| `a thread of the program did not stop` | Linux | A thread didn't stop within 2 s. |
| `a thread that blocks signals kept running` | Linux | A thread that blocks every signal, as some libraries start, was running, not waiting in the kernel. |
| `the program has more threads than the agent can stop` | Linux, Windows | The agent's list of threads to stop is full. |
| `an entry to rewrite could not be written in one store while a thread that blocks signals sleeps` | Linux | A function's entry wasn't aligned for the one 8-byte store that keeps such a thread safe. |
| `a thread stayed inside the first bytes of a function being redirected` | x86-64 | A thread kept stopping inside an entry the jump overwrites. |
| `cannot copy a code page of the program` | macOS | The system refused the copy of a signed code page. |
| `cannot replace a code page of the program` | macOS | The same, for mapping the copy back. |
| `cannot make a code page of the program writable` | Linux, Windows | `mprotect` or `VirtualProtect` failed. |

On macOS, the system's reason follows, after a colon. When this happens after some
functions were already redirected, the line is followed by:

```text
error: the reload stopped halfway: <n> functions are redirected and the rest are not; restart the program (nothing changed)
```

The program then runs a mix of old and new code. Restart it: until it starts over, hotfpc
refuses every swap with `an earlier reload failed after some functions were already
redirected`.

Errors about the object file the agent was given, with the unit or file they concern. They
say that hotfpc can't load it; please report them with the unit that causes them:

| Error | Where |
| --- | --- |
| `<file> is not an arm64 Mach-O object` | macOS |
| `<file> is not an aarch64 ELF object` | Linux arm64 |
| `<file> is not an x86-64 COFF object` | Windows |
| `<file> has no symbol table` | any |
| `cannot read <file>` | any |
| `<unit>: malformed subtractor relocation` | macOS |
| `<unit>: relocations without addends (REL) are not handled` | Linux |
| `<unit>: a relocation refers to a section that is not loaded` | any |
| `<unit>: <symbol> is above 4 GiB, out of reach of a 32-bit address` | x86-64 |
| `<unit>: <symbol> is above 2 GiB, out of reach of a 32-bit address` | x86-64 |
| `<unit>: <symbol> is out of reach of a 32-bit offset` | x86-64 |
| `<unit>: <symbol> is out of reach of a 32-bit offset from the image base` | Windows |
| `<unit>: a branch into the middle of <symbol> is out of reach` | x86-64 |
| `<unit>: <symbol> is out of reach of adrp` | arm64 |
| `<unit>: a GOT relocation without a symbol` | arm64, Linux x86-64 |
| `<unit>: misaligned load of <symbol>` | arm64 |
| `<unit>: a thread-variable relocation to <symbol>, which is not a thread variable of the program` | Linux |
| `<unit>: thread variable <symbol> out of reach` | Linux |
| `<unit>: unsupported relocation type <n> (thread-local variables of the system are not handled)` | any |
| `<name> is out of reach of its island` | any |
| `the system did not take the unwind tables of the new code` | Windows |
| `unknown command` | The agent got a command it doesn't know. It can't happen with the agent hotfpc builds. |

## Before the program starts

Most of these end hotfpc, with exit code 1 unless the row says otherwise. The two about
ppudump only turn a check off:

| Line | What to do |
| --- | --- |
| `<fpc> is version <version>; hotfpc requires 3.2.2 or later` | Install a newer fpc, or name one with `--fpc`. |
| `cannot tell which version <fpc> is (-iV printed <text>); hotfpc requires 3.2.2 or later` | `--fpc` names something that isn't fpc, or a wrapper that prints something else first. |
| `cannot run <fpc>; hotfpc requires 3.2.2 or later` | fpc isn't on `PATH`, or `--fpc` names a file that doesn't run. |
| `cannot run <fpc> (<reason>); hotfpc requires 3.2.2 or later` | The same, with the system's reason. |
| `no ppudump next to the compiler (--ppudump): the check of interface layouts is off` | hotfpc carries on, without the check of layouts. Name ppudump with `--ppudump`. |
| `<ppudump> cannot read this compiler's units (<reason>): the check of interface layouts is off; --ppudump names one that can` | The ppudump found belongs to another fpc. hotfpc carries on without the check. |
| `the agent did not compile:` | fpc's output follows. Your options for the target or paths may not suit a unit compiled on its own. |
| `cannot listen on 127.0.0.1` | hotfpc couldn't open a TCP port on the loopback interface. |
| `the program ended (exit code <n>) before hot reloading could start` | The program ended, or crashed, before its agent connected. hotfpc ends with its exit code; after a restart, it waits for the next save instead. |
| `the program did not connect within <n> s` | The agent didn't connect within 60 s. hotfpc stops the program. |

When the first build fails, hotfpc prints fpc's errors, without `[hot]`: the lines that
name a place in a source file, or fpc's closing lines when there are none. It ends with 1.

## Windows programs: the check of sizes

```text
<fpc> did not compile the program to assembler (<problem>): the check of sizes of variables with initial values is off
<fpc> did not compile the program to assembler (<problem>): the sizes of variables with initial values are not checked
```

For a Windows program hotfpc compiles to assembler as well, to see the sizes of variables
with initial values and typed constants ([Windows programs](../guides/windows.md)). The
first line comes at the start, when that compile failed: the check is off for the run. The
second comes after a save or a restart: the sizes weren't checked this time. A swap still
goes ahead.

## While it runs

| Line | What happened |
| --- | --- |
| `the program ended with <n>; the next save that builds starts it again` | A program that a restart started ended with a non-zero exit code, or a signal ended it. hotfpc keeps watching. |
| `the next save that builds starts the program again` | A restarted program ended before its agent connected, such as from a runtime error in an initialization section. |
| `the stopped program's connection is still open: a launcher (--run) that starts the program as its child has to end it too, or the old program keeps running` | After a restart stopped the launcher, the old program's agent stayed connected for 2 s: the launcher left its child running. |

## The end

```text
the program ended with <n> after <s> s; <n> reloads applied, <n> refused, <n> failed to compile, <n> without a change in code, <n> restarts
```

When the program ends, hotfpc prints this and ends with the program's exit code. `<n>` is
`-1` when a signal ended the program. `--quiet` leaves it out.

```text
[hot] the program ended with 0 after 6.8 s; 0 reloads applied, 1 refused, 0 failed to compile, 0 without a change in code, 2 restarts
```
