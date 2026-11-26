# Testing

> **Audience: contributors.** How hotfpc is tested, and when a change is done.

hotfpc has three layers of tests: unit tests of the driver's internals, a check of the
agent on its own, and end-to-end scenarios that run real programs under hotfpc and save
edits into them.

```sh
./build.sh tests                               # unit tests (the end of source/HotFPC.pas)
python3 tests/scenarios/check.py               # all 40 scenarios, about 2 minutes
python3 tests/scenarios/check.py globals rename
python3 tests/agent/check.py                   # the agent on its own
HOT_DRIVER_OPTS="--fpc /path/to/fpc" python3 tests/scenarios/check.py
```

## When a change is done

A change is done when the unit tests pass, `check.py` prints "40 of 40 cases as expected"
and `tests/agent/check.py` passes, on every system the change can affect: macOS arm64,
macOS x86-64, Linux x86-64, Linux arm64, and Windows x86-64 (`-Twin64 -Px86_64` with win64
units, under Wine or on Windows). Changes to the agent or to the checks of layouts and
sizes are tested with fpc 3.2.2 and 3.3.1. CI runs the unit tests, the scenarios and the
check of the agent with fpc 3.2.2 on all five systems ([tooling](tooling.md#ci)); the other
compilers and Wine are run by hand.

## The unit tests

The unit tests are at the end of `source/HotFPC.pas`, inside `{$ifdef HOTFPC_TESTS}`. They
test the driver's parts on their own: parsing the command line, watching files, finding
leftovers, reading ppudump's output, counting sizes in assembler, the agent link. There is
no framework: `Expect` and `ExpectEqual` print `FAIL: ...` and count, and the program ends
with 1 when a check failed. `./build.sh tests` compiles `source/HotFPC.pas` with
`-dHOTFPC_TESTS` into `build/tests/hotfpc-tests` and runs it
([build system](build-system.md#the-unit-tests)).

## The agent on its own

`tests/agent/check.py` checks what the agent answers to commands that hotfpc doesn't send in
a scenario, such as an object file it can't read. hotfpc builds a small program with the
agent in `tests/agent/work/`, which git ignores, and starts it once; the program ends at
once. The script then starts the program itself, with `HOT_PORT` set to a port it listens
on and `HOT_TOKEN` to the token it expects in the agent's hello, and stands in for hotfpc on
the agent's protocol (the comment at the top
of `source/HotFPC.Agent.pas`): it waits for the agent's hello, sends each case's command and
checks the reply, and at the end that the agent closes its connection as the program ends.
The one case so far, `badobject`, loads a file that is no object file and
expects the error to name the object files of the system the agent runs on, such as
`is not an x86-64 ELF object`. `HOT_DRIVER` and `HOT_DRIVER_OPTS` pick the hotfpc and its
options as for the scenarios, and hotfpc runs in the directory the script runs in, as for
them. The script starts the program as hotfpc does, with `--run`'s launcher, or under Wine
for a Windows target on another system, in `tests/agent/work/`.

## The scenarios

`tests/scenarios/scenario.py` holds 40 cases. Each is a small program, `main.pas` and its
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
after it, which that save makes hotfpc do. An `AT_START` step may be `EMPTIED_FIRST` too. An edit `(path, None, BLOCKED)` puts a directory where hotfpc
writes a file, such as `.hot/asm/main.s`, so that fpc can't write it, and
`(path, None, None)` removes it again. After the last step the script tells the program to
end. The program prints a numbered tick every 0.3 s, with what the unit's code returns.

Once a case has failed, it ends within seconds. The script's own complaint, a line that starts
with `!!!` (an edit that doesn't apply, or a save hotfpc gave no outcome for within 150 s),
fails the case, and the script saves no step after it but tells the program to end. hotfpc
runs in a process group of its own, with the program it starts, so the script can stop
both by hotfpc's process ID, and it does when:

- the program hasn't ended 30 s after the script told it to;
- the run prints a line longer than 64 KiB, or more than 1 MiB in all (a case prints a few
  kilobytes; a program whose memory a swap broke can print a string of a wrong length,
  gigabytes on one line);
- the case takes more than 300 s in all (the slowest system in CI runs all 40 in under 4
  minutes).

The complaint names the step the case was at. Ctrl+C, `SIGTERM` or `SIGHUP` to the script
stops hotfpc and the program too.

`check.py` runs `scenario.py` and checks each case's run, line by line without the script's
timestamps: hotfpc's lines start with `[hot]`, and a check matches a whole line from its
start, so a line the program prints is never taken for one of hotfpc's:

- the closing summary: the number of reloads applied, refused and failed to compile, and of
  restarts, against the case's expected numbers in `EXPECT` and `RESTARTS` (a tuple lists
  the numbers a case may give, where two saves may be compiled together);
- a clean exit (code 0), and no step whose text didn't apply to the file;
- no swap that prints the same note twice, and for some cases notes every swap must print
  (`NOTES`);
- the ticks, each a line of the program's own: every number from 1 to the last is there,
  so the program's output has no gaps (a restart where none was expected shows in the
  count of restarts);
- for some cases, lines the program must print after a swap (`PRINTS`), what the ticks
  after the last swap print, so that the program runs the saved code (`SWAPPED`: the first
  of them may still print the old code's line, as it may have been running when the swap
  was written, and every one after it the saved code's), a counter in the implementation
  section that every tick prints and that must keep pace with the ticks (`COUNTERS`),
  `[hot]` lines hotfpc must print (`SAYS`), the most a load may take inside the program
  (`LOAD_LIMITS`), and a tick the program prints once where it hands over from the old code
  to the new, with what every tick before it and after it prints (`HANDOFFS`).

It prints one line per case, with the script's first complaint and how long the case took,
the run of each case that failed, and "N of M cases as expected", and ends with 1 when one
failed. [Edits and what they do](../guides/edits.md)
lists every step and its outcome.

For a Windows target (`-Twin` in `HOT_DRIVER_OPTS`), `check.py` expects a restart in three
cases where the other systems swap: in two, fpc's Windows linker leaves out runtime
routines the program never called; in `progvar`, fpc can't write the assembler that shows
a save's sizes. The comments in `check.py` say which. In the cases that check how a start
leaves the sizes, `startblock`, `startcap`, `startnoasm` and `newconst`, it also requires
the reason a Windows program gives for its restart, so that a case passes only with the
sizes it is about. `shortentry` is swapped on Windows
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
but `restart`, `linkfail`, `crash`, `newconst`, `shortentry`, `shortcall`, `sighandler` and
`sigmasked` passes `--no-restart`, so the program it checks keeps running after a refused
edit.

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
a third element, `WHILE_COMPILING` or `AT_START`, times the save as above. `restart=True` lets hotfpc start the program over, and `env={...}` adds variables to hotfpc's environment, which the program inherits, such as one of the agent's test variables ([environment](../reference/environment.md#read-by-the-agent-for-testing)). Then add the case's expected numbers to
`EXPECT` in `check.py`, from a run on every system the case can differ on, and say in a
comment why where it isn't obvious.

## Other tests

Some checks were run by hand and are recorded in [platforms](../reference/platforms.md):
the stress test (20,000 reloads of one unit while two threads call it) and the swaps of
lwpt's formatter units.
