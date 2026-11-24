#!/usr/bin/env python3
"""Regression check for the scenarios: runs scenario.py (all cases, or those named) and
compares each case's closing line with the outcome established for it. Prints the run of
each case that failed after the summary lines, so a CI log shows why. Writes the full
transcript to $HOT_TRANSCRIPT when set. $HOT_DRIVER picks the driver (default: build/hotfpc),
$HOT_DRIVER_OPTS adds options to it (--fpc, fpc options).

  check.py [case ...]
"""
import os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# case: (reloads applied, refused, failed to compile); rapid may merge two quick saves into one reload
EXPECT = {
    "globals": (4, 1, 0), "classes": (3, 2, 0), "heap": (1, 0, 0), "interfaces": (2, 1, 0), "exceptions": (2, 0, 0),
    "threadvars": (1, 1, 0), "initfinal": (2, 0, 0), "generics": (1, 0, 0), "inline": (1, 0, 0), "signature": (1, 0, 0),
    "slowsave": (1, 0, 0), "procvars": (1, 0, 0), "records": (1, 2, 0), "newunit": (1, 2, 0), "rapid": ((2, 3, 4), 0, 0), "hidden": (1, 3, 0),
    # an include file shared by two units; a unit renamed (a restart: the new name is a new
    # unit) and renamed back with another body
    "include": (2, 0, 0), "rename": (1, 1, 0), "constants": (2, 0, 0),
    "signals": (1, 0, 0),
    # the program starts over: a link that fails counts as a failed compile, and a restarted
    # program that fails is started again by the next save
    "restart": (2, 1, 0), "linkfail": (2, 2, 1), "crash": (0, 1, 0),
    # a variable with an initial value and a typed constant that grow inside the 16 bytes fpc
    # pads the section of each to: the size an ELF object states shows it, and on Windows,
    # where a COFF object states none, the size in fpc's assembler output
    "initvar": (1, 1, 0), "typedconst": (1, 1, 0), "progvar": (2, 1, 0), "localconst": (1, 1, 0),
}
# case: restarts; every other case passes --no-restart and expects none
RESTARTS = {"restart": 1, "linkfail": 1, "crash": 2}
# case: lines the program must print, so that a swap shows its new values
PRINTS = {
    "constants": ["rate 2.50 scale 0.25", "offset 9.75 rate 2.50 scale 0.25"],
    "signals": ["text two"],
    # a restarted program runs the new code and counts from the start
    "restart": ["three calls 1"], "linkfail": ["three calls 1 extra 1"], "crash": ["three calls 1"],
}
# case: the word before a number that counts the calls of Tick, as the tick number does. It
# is a variable of the unit's implementation section, which every swap must leave in place,
# so every tick prints it and the two numbers stay equal
COUNTERS = {"globals": "hidden", "hidden": "calls"}
# case: the most a load may take inside the program, in ms; the agent must not wait for a
# thread that cannot stop
LOAD_LIMITS = {"signals": 1000}


if "-Twin" in os.environ.get("HOT_DRIVER_OPTS", ""):
    # fpc's internal linker for Windows always leaves out code the program does not reach,
    # so new code that calls a routine of the runtime the program never called needs a
    # restart there: Supports (interfaces, second step) and IntToHex/UpperCase (newunit,
    # third step). Linux and macOS link the whole unit.
    EXPECT["interfaces"] = (1, 2, 0)
    EXPECT["newunit"] = (0, 3, 0)
    # a save whose sizes hotfpc cannot check, because fpc did not write the assembler,
    # needs a restart (progvar, second step)
    EXPECT["progvar"] = (1, 2, 0)
names = sys.argv[1:] or list(EXPECT)
run = subprocess.run([sys.executable, os.path.join(HERE, "scenario.py")] + names, capture_output=True, text=True)
out = run.stdout
if os.environ.get("HOT_TRANSCRIPT"):
    with open(os.environ["HOT_TRANSCRIPT"], "w") as f:
        f.write(out)
# each case's section of the transcript, in the order the cases ran: a case named twice has
# two sections, and a case that never started has none
sections = re.findall(r"^=== (\S+)\n(.*?)(?=\n=== |\Z)", out, re.S | re.M)
# the cases that failed, with their section (None when the case never started); the runs
# that printed anything are shown at the end, so a CI log shows why
failing = []
for name in names:
    body = sections.pop(0)[1] if sections and sections[0][0] == name else None
    end = re.search(r"ended with (-?\d+) after .*?; (\d+) reloads applied, (\d+) refused, (\d+) failed to compile, (\d+) without a change in code, (\d+) restarts", body or "")
    if not end:
        print("%-11s FAIL  %s" % (name, "no closing line" if body is not None else "did not run"))
        failing.append((name, body))
        continue
    rc, applied, refused, failed, unchanged, restarts = map(int, end.groups())
    ea, er, ef = EXPECT[name]
    # rapid: a save that lands while fpc compiles the one before is compiled again with it,
    # so the two may make one reload; a compile is never acted on when the sources changed
    # during it, so none finds the same code ("not swapped")
    # "!!! " is the script's own complaint: an edit that does not apply, or a save the driver
    # gave no outcome for
    ok = rc == 0 and (applied in ea if isinstance(ea, tuple) else applied == ea) and refused == er and failed == ef and unchanged == 0 and restarts == RESTARTS.get(name, 0) and "!!! " not in body
    # the program's tick records, each a line of its own after the script's timestamp: the
    # same records count toward continuity and carry the counters
    records = re.findall(r"^ *\d+\.\d+s  tick (\d+):(.*)$", body, re.M)
    ticks = [int(tick) for tick, _ in records]
    seq = sorted(set(ticks)) == list(range(1, max(ticks) + 1)) if ticks else False
    ok = ok and seq
    missing = [text for text in PRINTS.get(name, []) if not re.search(r"tick \d+: " + re.escape(text) + "$", body, re.M)]
    ok = ok and not missing
    drift = []
    for tick, text in records if name in COUNTERS else []:
        count = re.search(r"\b%s (\d+)" % COUNTERS[name], text)
        if not count or count.group(1) != tick:
            drift.append((tick, count and count.group(1)))
    ok = ok and not drift
    loads = [float(x) for x in re.findall(r"of which in the program (-?[\d.]+)\)", body)]
    slow = [x for x in loads if name in LOAD_LIMITS and not 0 <= x < LOAD_LIMITS[name]]
    ok = ok and not slow
    print("%-11s %s  exit %d, %d applied, %d refused, %d failed, %d unchanged, %d restarts; ticks 1..%d %s"
          % (name, "ok  " if ok else "FAIL", rc, applied, refused, failed, unchanged, restarts, max(ticks) if ticks else 0, "all present" if seq else "WITH GAPS")
          + "".join("; never printed %r" % text for text in missing)
          + "".join("; tick %s printed %s" % (tick, "%s %s" % (COUNTERS[name], count) if count else "no %s number" % COUNTERS[name])
                    for tick, count in drift[:1])
          + "".join("; a load took %s ms in the program" % x for x in slow))
    if not ok:
        failing.append((name, body))
for name, body in failing:
    if body and body.strip():
        print("\n=== %s, as it ran\n%s" % (name, body.rstrip()))
# scenario.py's own failure, such as a traceback that cut the run short, fails the check
# even when every case that ran was as expected
if run.returncode != 0:
    print("\n=== scenario.py ended with %d\n%s" % (run.returncode, run.stderr.rstrip()))
print("%d of %d cases as expected" % (len(names) - len(failing), len(names)))
sys.exit(1 if failing or run.returncode != 0 else 0)
