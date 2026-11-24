#!/usr/bin/env python3
"""Regression check for the scenarios: runs scenario.py (all cases, or those named) and
compares each case's closing line with the outcome established for it. Prints the run of
each case that failed after the summary lines, so a CI log shows why. Writes the full
transcript to $HOT_TRANSCRIPT when set. $HOT_DRIVER picks the driver (default: build/hotfpc),
$HOT_DRIVER_OPTS adds options to it (--fpc, fpc options).

  check.py [case ...]
"""
import os, re, shlex, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# case: (reloads applied, refused, failed to compile); rapid may merge two quick saves into one reload
EXPECT = {
    "globals": (4, 1, 0), "classes": (3, 2, 0), "heap": (1, 0, 0), "interfaces": (2, 1, 0), "exceptions": (2, 0, 0),
    "threadvars": (1, 1, 0), "initfinal": (2, 0, 0), "generics": (1, 0, 0), "inline": (1, 0, 0), "signature": (1, 0, 0),
    "procvars": (1, 0, 0), "records": (1, 2, 0), "newunit": (1, 2, 0), "rapid": ((2, 3, 4), 0, 0), "hidden": (1, 3, 0),
    # an include file shared by two units; a unit renamed (a restart: the new name is a new
    # unit) and renamed back with another body
    "include": (2, 0, 0), "rename": (1, 1, 0), "constants": (2, 0, 0),
    "signals": (1, 0, 0),
    # the program starts over: a link that fails counts as a failed compile, and a restarted
    # program that fails is started again by the next save
    "restart": (2, 1, 0), "linkfail": (2, 2, 1), "crash": (0, 1, 0),
    # a variable with an initial value and a typed constant that grow: fpc pads the section
    # of each to 16 bytes, so the type in the unit file shows it, or the size an ELF object
    # states (a COFF object on Windows states none)
    "initvar": (1, 1, 0), "typedconst": (1, 1, 0), "progvar": (1, 1, 0),
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
# case: the most a load may take inside the program, in ms; the agent must not wait for a
# thread that cannot stop
LOAD_LIMITS = {"signals": 1000}


def fpc_version():
    """The version of the fpc the driver uses: --fpc in $HOT_DRIVER_OPTS, or fpc."""
    opts = shlex.split(os.environ.get("HOT_DRIVER_OPTS", ""))
    fpc = opts[opts.index("--fpc") + 1] if "--fpc" in opts[:-1] else "fpc"
    return subprocess.run([fpc, "-iV"], capture_output=True, text=True).stdout.strip()


if "-Twin" in os.environ.get("HOT_DRIVER_OPTS", ""):
    # fpc's internal linker for Windows always leaves out code the program does not reach,
    # so new code that calls a routine of the runtime the program never called needs a
    # restart there: Supports (interfaces, second step) and IntToHex/UpperCase (newunit,
    # third step). Linux and macOS link the whole unit.
    EXPECT["interfaces"] = (1, 2, 0)
    EXPECT["newunit"] = (0, 3, 0)
    # A COFF object states no sizes, so a variable with an initial value that grows inside
    # the 16 bytes fpc pads its section to shows only in a unit file. fpc writes none for
    # the program, and fpc 3.2 leaves an implementation section's typed constant out of it:
    # those edits are swapped (see README "Limits").
    EXPECT["progvar"] = (2, 0, 0)
    if fpc_version().startswith("3.2"):
        EXPECT["typedconst"] = (2, 0, 0)
names = sys.argv[1:] or list(EXPECT)
run = subprocess.run([sys.executable, os.path.join(HERE, "scenario.py")] + names, capture_output=True, text=True)
out = run.stdout
if os.environ.get("HOT_TRANSCRIPT"):
    with open(os.environ["HOT_TRANSCRIPT"], "w") as f:
        f.write(out)
bad = 0
# the transcripts of the cases that failed, printed at the end: a CI log then shows why
failing = []
for name in names:
    m = re.search(r"=== %s\n(.*?)(?=\n=== |\Z)" % re.escape(name), out, re.S)
    body = m.group(1) if m else ""
    end = re.search(r"ended with (-?\d+) after .*?; (\d+) reloads applied, (\d+) refused, (\d+) failed to compile, (\d+) without a change in code, (\d+) restarts", body)
    if not end:
        print("%-11s FAIL  no closing line" % name)
        bad += 1
        failing.append((name, body))
        continue
    rc, applied, refused, failed, unchanged, restarts = map(int, end.groups())
    ea, er, ef = EXPECT[name]
    # rapid: a save that lands while fpc reads the file is compiled with the one before it,
    # and the compile for it then finds the same code ("not swapped"); the program shows the
    # newest text either way
    merged = unchanged if name == "rapid" else 0
    ok = rc == 0 and (applied + merged in ea if isinstance(ea, tuple) else applied == ea) and refused == er and failed == ef and unchanged == merged and restarts == RESTARTS.get(name, 0) and "!!! the edit does not apply" not in body
    ticks = [int(x) for x in re.findall(r"tick (\d+):", body)]
    seq = sorted(set(ticks)) == list(range(1, max(ticks) + 1)) if ticks else False
    ok = ok and seq
    missing = [text for text in PRINTS.get(name, []) if not re.search(r"tick \d+: " + re.escape(text) + "$", body, re.M)]
    ok = ok and not missing
    loads = [float(x) for x in re.findall(r"of which in the program (-?[\d.]+)\)", body)]
    slow = [x for x in loads if name in LOAD_LIMITS and not 0 <= x < LOAD_LIMITS[name]]
    ok = ok and not slow
    print("%-11s %s  exit %d, %d applied, %d refused, %d failed, %d unchanged, %d restarts; ticks 1..%d %s"
          % (name, "ok  " if ok else "FAIL", rc, applied, refused, failed, unchanged, restarts, max(ticks) if ticks else 0, "all present" if seq else "WITH GAPS")
          + "".join("; never printed %r" % text for text in missing)
          + "".join("; a load took %s ms in the program" % x for x in slow))
    bad += 0 if ok else 1
    if not ok:
        failing.append((name, body))
for name, body in failing:
    print("\n=== %s, as it ran\n%s" % (name, body.rstrip()))
# scenario.py's own errors, such as a traceback that cut a case short
if failing and run.stderr.strip():
    print("\n=== scenario.py's errors\n%s" % run.stderr.rstrip())
print("%d of %d cases as expected" % (len(names) - bad, len(names)))
sys.exit(1 if bad else 0)
