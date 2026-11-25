# Testing

> **Audience: contributors.** How hotfpc is tested, and when a change is done.

hotfpc has two layers of tests: unit tests of the driver's internals, and end-to-end
scenarios that run real programs under hotfpc and save edits into them.

```sh
./build.sh tests                               # unit tests (the end of source/HotFPC.pas)
python3 tests/scenarios/check.py               # all 36 scenarios, about 2 minutes
python3 tests/scenarios/check.py globals rename
HOT_DRIVER_OPTS="--fpc /path/to/fpc" python3 tests/scenarios/check.py
```

## When a change is done

A change is done when the unit tests pass and `check.py` prints "36 of 36 cases as
expected" on every system the change can affect: macOS arm64, macOS x86-64, Linux x86-64,
Linux arm64, and Windows x86-64 (`-Twin64 -Px86_64` with win64 units, under Wine or on
Windows). Changes to the agent or to the checks of layouts and sizes are tested with fpc
3.2.2 and 3.3.1. CI runs the unit tests and the scenarios with fpc 3.2.2 on all five
systems ([tooling](tooling.md#ci)); the other compilers and Wine are run by hand.

## The unit tests

The unit tests are at the end of `source/HotFPC.pas`, inside `{$ifdef HOTFPC_TESTS}`. They
test the driver's parts on their own: parsing the command line, watching files, finding
leftovers, reading ppudump's output, counting sizes in assembler, the agent link. There is
no framework: `Expect` and `ExpectEqual` print `FAIL: ...` and count, and the program ends
with 1 when a check failed. `./build.sh tests` compiles `source/HotFPC.pas` with
`-dHOTFPC_TESTS` into `build/tests/hotfpc-tests` and runs it
([build system](build-system.md#the-unit-tests)).

## The scenarios

`tests/scenarios/scenario.py` holds 36 cases. Each is a small program, `main.pas` and its
units, and a list of steps: the edits the script saves into the files while the program
runs. The script saves a step once hotfpc has reported its outcome for the step before (a
swap, a refusal, an error, a restart or no change in code), so the numbers don't depend on
how fast the machine compiles. A step marked `+` comes 0.12 s after the one before instead,
while hotfpc is still busy with it. A step marked `WHILE_COMPILING` writes its second file
once hotfpc has started to compile the first. A step marked `EMPTIED_FIRST` empties its
first file, writes the others 0.1 s later and the first 0.3 s after it emptied it, as an
editor that empties a file before it writes it. A step marked `AT_START` is saved while
hotfpc builds the program to start it, once fpc has written the program's object file: the
program starts with it. Each further `AT_START` step waits for the object file of the build
after it, which that save makes hotfpc do. An edit `(path, None, BLOCKED)` puts a directory where hotfpc
writes a file, such as `.hot/asm/main.s`, so that fpc can't write it, and
`(path, None, None)` removes it again. After the last step the script tells the program to
end. The program prints a numbered tick every 0.3 s, with what the unit's code returns.

`check.py` runs `scenario.py` and checks each case's run:

- the closing summary: the number of reloads applied, refused and failed to compile, and of
  restarts, against the case's expected numbers in `EXPECT` and `RESTARTS` (a tuple lists
  the numbers a case may give, where two saves may be compiled together);
- a clean exit (code 0), and no step whose text didn't apply to the file;
- the ticks, each a line of the program's own: every number from 1 to the last is there,
  so the program's output has no gaps (a restart where none was expected shows in the
  count of restarts);
- for some cases, lines the program must print after a swap (`PRINTS`), what the ticks
  after the last swap print, so that the program runs the saved code (`SWAPPED`: the first
  of them may still print the old code's line, as it may have been running when the swap
  was written, and every one after it the saved code's), a counter in the implementation
  section that every tick prints and that must keep pace with the ticks (`COUNTERS`),
  `[hot]` lines hotfpc must print (`SAYS`), and the most a load may take inside the program
  (`LOAD_LIMITS`).

It prints one line per case, the run of each case that failed, and "N of M cases as
expected", and ends with 1 when one failed. [Edits and what they do](../guides/edits.md)
lists every step and its outcome.

For a Windows target (`-Twin` in `HOT_DRIVER_OPTS`), `check.py` expects a restart in three
cases where the other systems swap: in two, fpc's Windows linker leaves out runtime
routines the program never called; in `progvar`, fpc can't write the assembler that shows
a save's sizes. The comments in `check.py` say which. `shortentry` is swapped on Windows
and arm64, where the jump at a routine's entry fits, and restarted on x86-64 macOS and
Linux. `shortcall` is swapped on arm64, where a call is as long as the jump, and restarted
on every x86-64 system; so are `sighandler` and `sigmasked`, whose trapped thread resumes
after the branch on arm64 and inside the jump on x86-64.

| Variable | Effect |
| --- | --- |
| `HOT_DRIVER` | The hotfpc to run (default `build/hotfpc`), such as `build/hotfpc.exe`. |
| `HOT_DRIVER_OPTS` | Options put before everything else, such as `--fpc`, `--ppudump` or `-Twin64 -Px86_64`. |
| `HOT_TRANSCRIPT` | A file to write the whole run to. |

The programs are written to `tests/scenarios/work/<case>/`, which git ignores. Every case
but `restart`, `linkfail`, `crash`, `shortentry`, `shortcall`, `sighandler` and `sigmasked`
passes `--no-restart`, so the program it checks keeps running after a refused edit.

### Adding a scenario

A case is a call to `case()` in `scenario.py`:

```python
case("records", {
    "main.pas": MAIN,          # the shared main program: calls Tick(n) every 0.3 s
    "u.pas": r'''unit u; ...''',
}, [
    ("y: Integer becomes y: Single (the record keeps its size)",
     [("u.pas", "y: Integer;", "y: Single;")]),
    ...
])
```

Each step is a description and a list of `(file, old text, new text)` replacements, saved
together. A description that starts with `+` is saved 0.12 s after the step before it, and
a third element, `WHILE_COMPILING` or `AT_START`, times the save as above. `restart=True` lets hotfpc start the program over. Then add the case's expected numbers to
`EXPECT` in `check.py`, from a run on every system the case can differ on, and say in a
comment why where it isn't obvious.

## Other tests

Some checks were run by hand and are recorded in [platforms](../reference/platforms.md):
the stress test (20,000 reloads of one unit while two threads call it) and the swaps of
lwpt's formatter units.
