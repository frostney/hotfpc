# Edits and what they do

Every kind of edit hotfpc has a test for, and what it does. Each row is a step of one of
the scenarios in [`tests/scenarios/scenario.py`](../../tests/scenarios/scenario.py): a
small program that runs while the test saves the edit into it, run by CI on pull requests
and on pushes to main. The
outcomes are from runs of all 44 scenarios on Linux x86-64 with fpc 3.2.4 on 2026-11-26, and they are what `check.py` expects on macOS and Linux. Where a Windows
program ends differently, the row says so.

In a swap, the program keeps running with its state; in a restart, hotfpc starts it over
with the new code ([What a save does](saves-and-restarts.md)).

## Routines

| Edit | Outcome | Scenario |
| --- | --- | --- |
| The body of a virtual method | swap | `classes` |
| A class gains an override of a virtual method its parent declares | swap | `classes` |
| New code tests the class of an object old code made (`is`) | swap | `classes` |
| The body of a method called through an interface reference the program has held since it started | swap | `interfaces` |
| New code queries an old object for an interface (`Supports`) and drops the reference, so the destructor runs | swap; restart on Windows, where the program was linked without `Supports` | `interfaces` |
| The body of a generic method, specialised in a unit and in the main program | swap | `generics` |
| The body of an inline function that the running main block and a unit both inlined | swap, with a note that the main block keeps its old code | `inline` |
| `Area(w)` becomes `Area(w, h)`, and its callers pass two arguments | swap, with a note that the old `Area` stays for callers that weren't compiled again | `signature` |
| Three bodies, while the main block holds procedure variables and a method pointer taken before the swap, one of them of a routine declared only in the implementation section | swap: all three call the new code | `procvars` |
| That routine is declared in the interface too, with another body | swap: the procedure variable calls the new code | `procvars` |
| Its declaration in the interface is removed again, with another body | swap: the procedure variable calls the new code | `procvars` |
| Locals around those a nested routine reads, and another body for it, while its parent runs across the swap and calls it | swap: the running parent keeps calling the old nested routine, with its own values | `nestedframe` |
| New code raises an exception that the old main block catches | swap | `exceptions` |
| New code makes the runtime raise (`StrToInt` of a word) and catches it | swap | `exceptions` |
| New code shrinks an array, cuts a string and frees a list that old code allocated | swap | `heap` |

## Constants and variables

| Edit | Outcome | Scenario |
| --- | --- | --- |
| `Rate = 1.5` becomes `Rate = 2.5` | swap: the new value is used at once | `constants` |
| A new constant, used before the others | swap | `constants` |
| A new variable with an initial value | swap | `globals` |
| `Speed: Integer = 5` becomes `= 50`, and `Speed` still holds 5 | swap: `Speed` is 50, with the note `U.SPEED still had its initial value; set to the new one` | `globals` |
| `Total: Integer = 0` becomes `= 1000`, and the program has changed `Total` from 0 | swap: `Total` keeps its value, with the note `the initial value of U.TOTAL changed; the running value is kept` | `globals` |
| `Speed: Integer = 5` becomes `= 50` and a 16-byte record `Pair = (A: 1; B: 2)` becomes `(10, 20)`, and a write to each lands while the swap loads (`HOT_TEST_DATA_WRITE` makes it) | swap: both keep the program's values, each with the note `the initial value of U.<name> changed; the running value is kept` | `initrace` |
| `Hidden: Integer` becomes `Hidden: Int64` | restart: `u.Hidden: the declaration changed its layout or type` | `globals` |
| `Calls: Integer` in the implementation section becomes `Calls: Single`, the same size | restart: `u.Calls: the declaration changed its layout or type` | `hidden` |
| `Calls: Integer = 0` in the implementation section becomes `Int64 = 0` | restart: `u.Calls: the declaration changed its layout or type` | `initvar` |
| The typed constant `Calls: Integer = 0` becomes `Int64 = 0` | restart: `variable U.CALLS changed size from 4 to 8 bytes` | `typedconst` |
| Another text in the program file, saved while fpc can't write the program's assembler (`.hot/asm/main.s` is a directory) | swap; on Windows, restart: `the sizes of variables with initial values are unknown: <fpc> did not compile the program to assembler (...)` | `progvar` |
| `Calls: Integer = 0` in the program file becomes `Int64 = 0` | restart: `variable MAIN.CALLS changed size from 4 to 8 bytes`, also on Windows after the save before | `progvar` |
| A save removes `Calls: Integer = 0` and its uses from the program file | swap | `readdvar` |
| A later save adds `Calls: Int64 = 0` back | restart: `variable MAIN.CALLS changed size from 4 to 8 bytes` | `readdvar` |
| Then `Calls: Integer = 0`, its first type | swap: `Calls` counts on from the value it had, with the note `MAIN.CALLS is back after a save removed it; it keeps its running value` | `readdvar` |
| A save removes `Hits: Integer` from a unit's interface and `Calls: Integer` from its implementation section, with their uses | swap | `readdtype` |
| A later save adds both back as `Single`, the same size | restart: `u.Hits: the declaration changed its layout or type`, and the same for `u.Calls` | `readdtype` |
| Then both as `Integer`, their first type | swap, with the note `U.HITS is back after a save removed it; it keeps its running value`, and the same for `U.CALLS` | `readdtype` |
| A typed constant in a routine, `Calls: Integer = 0`, becomes `Int64 = 0` | restart: `variable U.TICK(LONGINT):ANSISTRING.CALLS changed size from 4 to 8 bytes` | `localconst` |
| `Small: Word = 1` in the program file, before `Big: Int64 = 2`, becomes `LongInt = 1`: it grows within the padding before `Big` | restart: `variable MAIN.SMALL changed size from 2 to 4 bytes` | `padvar` |
| Then `Small` is a `Word` again, and `Flag: Byte`, before `Wide: Int64`, becomes `Word` | restart: `variable MAIN.FLAG changed size from 1 to 2 bytes` | `padvar` |
| Then `Flag` is a `Byte` again, with a new `Flag2: Byte` after it | swap | `padvar` |
| A save removes `Small` and its uses | swap | `padvar` |
| A later save brings `Small` back as `LongInt = 1`, with its uses | restart: `variable MAIN.SMALL changed size from 2 to 4 bytes` | `padvar` |
| The first three of those saves in a unit's implementation section, without the check of layouts (`--ppudump` names a ppudump that doesn't exist) | restart, restart and swap: `variable U.SMALL changed size from 2 to 4 bytes`, then `variable U.FLAG changed size from 1 to 2 bytes` | `padunit` |
| Then `Shared: Word = 1` in the unit's interface, before `SharedNext: Int64`, which only the program's code uses, becomes `LongInt = 1`: on macOS the unit's object file comes out the same | restart: `variable U.SHARED changed size from 2 to 4 bytes`; on Windows, swap, as the unit's COFF object comes out the same too ([#45](https://github.com/frostney/hotfpc/issues/45)) | `padunit` |

The program's variables keep their values through every swap: the scenarios `globals` and
`hidden` check that a counter in a unit's implementation section keeps counting.

## Records, classes and interfaces

| Edit | Outcome | Scenario |
| --- | --- | --- |
| A record's field `y: Integer` becomes `y: Single`, the same size | restart: `u.TPos: the declaration changed its layout or type` | `records` |
| A record gains a field | restart, the same | `records` |
| A class gains a field | restart, for the class and each class derived from it | `classes` |
| A class gains a virtual method | restart: `class U.TANIMAL: the virtual method table changed from 27 to 28 slots`, and the same for each derived class | `classes` |
| Two fields of a class in the interface section swap places, the instance size the same | restart: `u.TPair: the declaration changed its layout or type` | `hidden` |
| Two fields of a class in the implementation section swap places | restart: `u.THidden: the declaration changed its layout or type` | `hidden` |
| An interface gains a method | restart: `type U.IGREETER: its layout or type information changed` | `interfaces` |

## Units, threads and include files

| Edit | Outcome | Scenario |
| --- | --- | --- |
| An include file used by two units | swap, of both units | `include` |
| A constant in an include file | swap, of both units | `include` |
| A save that empties one file first and writes it 0.3 s later, with another file written meanwhile | one swap, of both, once the file is written | `include` |
| The initialization section assigns something else | swap, with the note `the initialization section of u changed; it is not run again` | `initfinal` |
| The finalization section prints something else | swap | `initfinal` |
| The program now uses a new unit of its own | restart: `unit extra is not part of the running program` | `newunit` |
| A unit now uses `Math`, a unit of the runtime the program wasn't linked with | restart: `u uses MATH.POWER(EXTENDED,EXTENDED):EXTENDED, which the running program does not contain` | `newunit` |
| New code calls functions of `SysUtils` the program never called | swap; restart on Windows | `newunit` |
| `u.pas` becomes `w.pas`, and the program uses `w` | restart: `unit w is not part of the running program` | `rename` |
| Another text, with a thread variable untouched | swap | `threadvars` |
| A second thread variable | restart: `the thread variables of unit u changed` | `threadvars` |
| Another text, and `Speed: Integer = 5` becomes `= 50`, while a thread of the program blocks every signal | swap, within the scenario's limit of 1 s inside the program: `Speed` is 50 | `signals` |

## Restarts

These scenarios let hotfpc start the program over; the others pass `--no-restart`.

| Edit | Outcome | Scenario |
| --- | --- | --- |
| `Calls: Integer` becomes `Int64`, with another text | restart, then the program runs the new code and counts from 1 | `restart` |
| Another text, after that restart | swap, into the restarted program | `restart` |
| A unit uses a new unit whose code calls a routine no library has | restart, but the link fails: fpc's errors, and the program carries on with its old code | `linkfail` |
| The new unit no longer calls it | restart | `linkfail` |
| `Calls` becomes `Int64`, and the initialization section ends the program with exit code 3 | restart; the new program fails, and hotfpc waits | `crash` |
| The initialization no longer ends it | the next save starts the program again | `crash` |
| An assembler routine of 3 bytes, packed right before the next with `{$codealign proc=1}`, returns another value | restart on x86-64 macOS and Linux: `U.SMALL:LONGINT is 3 bytes from the next routine, too close for the 5-byte jump to its new code`; swap on arm64 and Windows, where the jump fits | `shortentry` |
| An assembler routine whose first instruction, 2 bytes long, calls a routine a thread waits in returns another value | restart on x86-64 macOS, Linux and Windows: `U.RELAY(POINTER,POINTER):LONGINT may call a routine within its first 5 bytes, and a thread could return from it into the middle of the jump to its new code`; swap on arm64, where the call returns after the jump | `shortcall` |
| A thread traps in an assembler routine's first bytes and its signal handler, or on Windows its vectored exception handler, waits until new code runs; the routine returns another value | restart on x86-64 macOS, Linux and Windows: `a thread may resume within the first 5 bytes of U.ENTRY:LONGINT, in the middle of the jump to its new code, such as one a signal or an exception interrupted there`; swap on arm64, where the thread resumes after the branch | `sighandler` |
| The same, with a signal handler that blocks every signal: on Linux the agent can't stop the thread, and reads its stack where it sleeps | the same | `sigmasked` |

## Saves in quick succession

| Edit | Outcome | Scenario |
| --- | --- | --- |
| Two saves 0.12 s apart, twice | each save is swapped, or two are compiled together; the program shows the newest text either way | `rapid` |
| One save whose second file is written while fpc compiles the first | compiled again once the files settle, then swapped once | `slowsave` |
| `Calls: Integer = 0` in the program file becomes `Int64 = 0`, with another text, saved while hotfpc builds the program to start it, after fpc has read the file | built again before the program starts: the program runs the save from its first tick | `startsave` |
| Another text, after that start | swap | `startsave` |
| Another text, saved during the first build while fpc can't write the program's assembler, and another during the build that follows | built again each time: the program runs the second from its first tick | `startblock` |
| `Calls: Integer = 0` in the program file becomes `Int64 = 0`, after that start | restart: `variable MAIN.CALLS changed size from 4 to 8 bytes` | `startblock` |
| Saves during each of the first four builds, the last of which makes `Calls: Integer = 0` `Int64 = 0` | the fourth build is used as it is: the program runs the third save | `startcap` |
| That save, compiled once the program runs, and another text | restart: `variable MAIN.CALLS changed size from 4 to 8 bytes`; on Windows `the sizes of variables with initial values are unknown: the sources changed while fpc compiled them`, for one or both saves | `startcap` |
| Saves during each of the first four builds, as in `startcap`, while fpc can't write the program's assembler for the fourth | the fourth build is used as it is; on Windows its sizes are unknown, and hotfpc says so | `startnoasm` |
| The save that grew `Calls`, compiled once the program runs, and another text once fpc can write the assembler again | restart: `variable MAIN.CALLS changed size from 4 to 8 bytes`; on Windows `the sizes of variables with initial values are unknown: <fpc> did not compile the program to assembler (<problem>)`, for one or both saves | `startnoasm` |
| Another text, saved while hotfpc builds the program to start it, by an editor that empties the file and writes it 0.3 s later | built again once the file is written: the program runs the save from its first tick | `startempty` |
| Another text | swap | `startempty` |
| The program no longer uses a unit, saved while hotfpc builds the program to start it | built again before the program starts: the program starts without the unit | `startunit` |
| The program uses that unit again | restart: `unit w is not part of the running program` | `startunit` |
| A unit the program uses gets a new unit with a typed constant, `Limit: Integer = 7` | restart: `unit w is not part of the running program` | `newconst` |
| That constant becomes `Limit: Int64 = 8` | restart: `variable W.LIMIT changed size from 4 to 8 bytes` | `newconst` |

## Running one yourself

```sh
./build.sh hotfpc
python3 tests/scenarios/check.py records
```

`check.py` prints one line per scenario and the run of each one that failed.
[Testing](../internals/testing.md) explains the scenarios and how to add one.
