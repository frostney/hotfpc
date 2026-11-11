#!/usr/bin/env python3
"""Regression check for the scenarios: runs scenario.py (all cases, or those named) and
compares each case's closing line with the outcome established for it. Writes the full
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
    "procvars": (1, 0, 0), "records": (1, 2, 0), "newunit": (1, 2, 0), "rapid": ((2, 3, 4), 0, 0), "limits": (2, 1, 0),
    # an include file shared by two units; a unit renamed (a restart: the new name is a new
    # unit) and renamed back with another body
    "include": (2, 0, 0), "rename": (1, 1, 0),
}
if "-Twin" in os.environ.get("HOT_DRIVER_OPTS", ""):
    # fpc's internal linker for Windows always leaves out code the program does not reach,
    # so new code that calls a routine of the runtime the program never called needs a
    # restart there: Supports (interfaces, second step) and IntToHex/UpperCase (newunit,
    # third step). Linux and macOS link the whole unit.
    EXPECT["interfaces"] = (1, 2, 0)
    EXPECT["newunit"] = (0, 3, 0)
names = sys.argv[1:] or list(EXPECT)
out = subprocess.run([sys.executable, os.path.join(HERE, "scenario.py")] + names, capture_output=True, text=True).stdout
if os.environ.get("HOT_TRANSCRIPT"):
    with open(os.environ["HOT_TRANSCRIPT"], "w") as f:
        f.write(out)
bad = 0
for name in names:
    m = re.search(r"=== %s\n(.*?)(?=\n=== |\Z)" % re.escape(name), out, re.S)
    body = m.group(1) if m else ""
    end = re.search(r"ended with (-?\d+) after .*?; (\d+) reloads applied, (\d+) refused, (\d+) failed to compile, (\d+) without a change", body)
    if not end:
        print("%-11s FAIL  no closing line" % name)
        bad += 1
        continue
    rc, applied, refused, failed, unchanged = map(int, end.groups())
    ea, er, ef = EXPECT[name]
    # rapid: a save that lands while fpc reads the file is compiled with the one before it,
    # and the compile for it then finds the same code ("not swapped"); the program shows the
    # newest text either way
    merged = unchanged if name == "rapid" else 0
    ok = rc == 0 and (applied + merged in ea if isinstance(ea, tuple) else applied == ea) and refused == er and failed == ef and unchanged == merged and "!!! the edit does not apply" not in body
    ticks = [int(x) for x in re.findall(r"tick (\d+):", body)]
    seq = sorted(set(ticks)) == list(range(1, max(ticks) + 1)) if ticks else False
    ok = ok and seq
    print("%-11s %s  exit %d, %d applied, %d refused, %d failed, %d unchanged; ticks 1..%d %s"
          % (name, "ok  " if ok else "FAIL", rc, applied, refused, failed, unchanged, max(ticks) if ticks else 0, "all present" if seq else "WITH GAPS"))
    bad += 0 if ok else 1
print("%d of %d cases as expected" % (len(names) - bad, len(names)))
sys.exit(1 if bad else 0)
