# Edits and what they do

Every kind of edit hotfpc has a test for, and what it does. Each row is a step of one of
the scenarios in [`tests/scenarios/scenario.py`](../../tests/scenarios/scenario.py): a
small program that runs while the test saves the edit into it, run by CI on pull requests
and on pushes to main. The
outcomes are from runs of all 28 scenarios on Linux x86-64 with fpc 3.2.2 on 2026-11-25, and they are what `check.py` expects on macOS and Linux. Where a Windows
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
| Two bodies, while the main block holds a procedure variable and a method pointer taken before the swap | swap: both call the new code | `procvars` |
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
| `Hidden: Integer` becomes `Hidden: Int64` | restart: `u.Hidden: the declaration changed its layout or type` | `globals` |
| `Calls: Integer` in the implementation section becomes `Calls: Single`, the same size | restart: `u.Calls: the declaration changed its layout or type` | `hidden` |
| `Calls: Integer = 0` in the implementation section becomes `Int64 = 0` | restart: `u.Calls: the declaration changed its layout or type` | `initvar` |
| The typed constant `Calls: Integer = 0` becomes `Int64 = 0` | restart: `variable U.CALLS changed size from 4 to 8 bytes` | `typedconst` |
| Another text in the program file, saved while fpc can't write the program's assembler (`.hot/asm/main.s` is a directory) | swap; on Windows, restart: `the sizes of variables with initial values are unknown: <fpc> did not compile the program to assembler (...)` | `progvar` |
| `Calls: Integer = 0` in the program file becomes `Int64 = 0` | restart: `variable MAIN.CALLS changed size from 4 to 8 bytes`, also on Windows after the save before | `progvar` |
| A typed constant in a routine, `Calls: Integer = 0`, becomes `Int64 = 0` | restart: `variable U.TICK(LONGINT):ANSISTRING.CALLS changed size from 4 to 8 bytes` | `localconst` |

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
| The initialization section assigns something else | swap, with the note `the initialization section of u changed; it is not run again` | `initfinal` |
| The finalization section prints something else | swap | `initfinal` |
| The program now uses a new unit of its own | restart: `unit extra is not part of the running program` | `newunit` |
| A unit now uses `Math`, a unit of the runtime the program wasn't linked with | restart: `u uses MATH.POWER(EXTENDED,EXTENDED):EXTENDED, which the running program does not contain` | `newunit` |
| New code calls functions of `SysUtils` the program never called | swap; restart on Windows | `newunit` |
| `u.pas` becomes `w.pas`, and the program uses `w` | restart: `unit w is not part of the running program` | `rename` |
| Another text, with a thread variable untouched | swap | `threadvars` |
| A second thread variable | restart: `the thread variables of unit u changed` | `threadvars` |
| Another text, while a thread of the program blocks every signal | swap, within the scenario's limit of 1 s inside the program | `signals` |

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

## Saves in quick succession

| Edit | Outcome | Scenario |
| --- | --- | --- |
| Two saves 0.12 s apart, twice | each save is swapped, or two are compiled together; the program shows the newest text either way | `rapid` |
| One save whose second file is written while fpc compiles the first | compiled again once the files settle, then swapped once | `slowsave` |

## Running one yourself

```sh
./build.sh hotfpc
python3 tests/scenarios/check.py records
```

`check.py` prints one line per scenario and the run of each one that failed.
[Testing](../internals/testing.md) explains the scenarios and how to add one.
