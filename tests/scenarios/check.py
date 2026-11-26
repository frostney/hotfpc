#!/usr/bin/env python3
"""Regression check for the scenarios: runs scenario.py (all cases, or those named) and
compares each case's closing line with the outcome established for it. Prints the run of
each case that failed after the summary lines, so a CI log shows why. Writes the full
transcript to $HOT_TRANSCRIPT when set. $HOT_DRIVER picks the driver (default: build/hotfpc),
$HOT_DRIVER_OPTS adds options to it (--fpc, fpc options).

  check.py [case ...]
"""
import os, platform, re, signal, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# case: (reloads applied, refused, failed to compile); a tuple lists the numbers a case may give, as
# when two saves may make one reload (rapid)
EXPECT = {
    "globals": (4, 1, 0), "classes": (3, 2, 0), "heap": (1, 0, 0), "interfaces": (2, 1, 0), "exceptions": (2, 0, 0),
    "threadvars": (1, 1, 0), "initfinal": (2, 0, 0), "generics": (1, 0, 0), "inline": (1, 0, 0), "signature": (1, 0, 0),
    "slowsave": (1, 0, 0), "procvars": (3, 0, 0), "nestedframe": (1, 0, 0), "records": (1, 2, 0), "newunit": (1, 2, 0), "rapid": ((2, 3, 4), 0, 0), "hidden": (1, 3, 0),
    # an include file shared by two units; a unit renamed (a restart: the new name is a new
    # unit) and renamed back with another body
    "include": (3, 0, 0), "rename": (1, 1, 0), "constants": (2, 0, 0),
    "signals": (1, 0, 0),
    # the program starts over: a link that fails counts as a failed compile, and a restarted
    # program that fails is started again by the next save
    "restart": (2, 1, 0), "linkfail": (2, 2, 1), "crash": (0, 1, 0),
    # x86-64: a routine shorter than the jump that redirects it, right before another; the
    # restarted program runs the new code
    "shortentry": (0, 1, 0),
    # x86-64: a routine whose first instruction is a call 2 bytes long, while a thread waits in
    # the routine it calls; the restarted program runs the new code
    "shortcall": (0, 1, 0),
    # x86-64: a thread trapped in a routine's first bytes waits in its signal handler (or
    # vectored exception handler); where it resumes is inside the jump, and the restarted
    # program runs the new code. In sigmasked the handler blocks every signal
    "sighandler": (0, 1, 0), "sigmasked": (0, 1, 0),
    # a variable with an initial value and a typed constant that grow inside the 16 bytes fpc
    # pads the section of each to: the size an ELF object states shows it, and on Windows,
    # where a COFF object states none, the size in fpc's assembler output
    "initvar": (1, 1, 0), "initrace": (1, 0, 0), "typedconst": (1, 1, 0), "progvar": (2, 1, 0), "localconst": (1, 1, 0),
    # a save while hotfpc builds the program to start it: the program starts with it, and the
    # save after it swaps
    "startsave": (1, 0, 0),
    # a save during the first build while fpc cannot write the assembler, and one during the
    # build after it: the program starts from the last, and its grown variable needs a restart
    "startblock": (0, 1, 0),
    # saves during four builds at the start, the last of which grows Calls: the program runs
    # the third, and the grown variable needs a restart, once or twice as hotfpc compiles it
    # alone or with the save after it
    "startcap": (0, (1, 2), 0),
    # startcap's saves, with no assembler for the fourth build: the check stays on, and the
    # grown variable needs a restart, once or twice
    "startnoasm": (0, (1, 2), 0),
    # a save that empties the program file during the first build: the build after it waits
    # for the file, and the program starts with the saved text
    "startempty": (1, 0, 0),
    # a unit the program no longer uses after a save during the first build, then uses again:
    # a restart, for a unit the running program does not have
    "startunit": (0, 1, 0),
    # a typed constant in a unit new to the program, which a restart adds, then grows: a
    # restart again
    "newconst": (0, 2, 0),
}
# case: restarts; every other case passes --no-restart and expects none
RESTARTS = {"restart": 1, "linkfail": 1, "crash": 2, "shortentry": 1, "shortcall": 1,
            "sighandler": 1, "sigmasked": 1, "newconst": 2}
# case: lines the program must print, so that a swap shows its new values
PRINTS = {
    "constants": ["rate 2.50 scale 0.25", "offset 9.75 rate 2.50 scale 0.25"],
    # Speed takes its new initial value while a thread that blocks the agent's signal sleeps
    # on (on Linux): it fits in one aligned word, which the commit writes in one step
    "signals": ["text two speed 50"],
    # Speed, a variable of the implementation section that nothing has written, takes its
    # new initial value: on Windows with fpc 3.2 the agent knows it only by its section
    "globals": [re.compile(r"TOTAL \d+ hidden \d+ speed 50 extra \d+")],
    "procvars": [re.compile(r"PLAIN V2 \d+, METHOD V2 \d+, HIDDEN V2 \d+, same address: TRUE TRUE"),
                 re.compile(r"PLAIN V2 \d+, METHOD V2 \d+, HIDDEN V3 \d+, same address: TRUE TRUE")],
    # the last of the quick saves shows, however they were merged (a pattern: the tick varies)
    "rapid": [re.compile(r"text five \d+")],
    # the save whose v.pas was emptied first runs with both of its files
    "include": [re.compile(r"two HITS \d+ scaled two:\d+0")],
    # a restarted program runs the new code and counts from the start
    "restart": ["three calls 1"], "linkfail": ["three calls 1 extra 1"], "crash": ["three calls 1"],
    "shortentry": ["small 3 next 7"], "shortcall": ["relay 2"],
    "sighandler": ["entry 2, resumed"], "sigmasked": ["entry 2, resumed"],
    # the program runs the save made during the start from its first tick
    "startsave": ["n 1 main two 1", re.compile(r"n \d+ main three \d+")],
    "newconst": ["n 1 limit 7", "n 1 limit 8"],
    "startblock": ["n 1 main three 1"], "startcap": ["n 1 main four 1"], "startnoasm": ["n 1 main four 1"],
    "startempty": ["n 1 main two 1", re.compile(r"n \d+ main three \d+")],
}
# case: what tick n prints once the case's last swap is in place, so that it runs the code of
# the save: Tick passes the new second argument, and the main block keeps its old code
SWAPPED = {name: lambda n: "main calls Area = %d, Tick calls Area = %d" % (n * n, 100 * n)
           for name in ("signature", "slowsave")}
# and what it printed before: the tick that runs while the swap is written may print this
# once after the swap's line, as its Tick ran the old code or had its result already
UNSWAPPED = {name: lambda n: "main calls Area = %d, Tick calls Area = %d" % (n * n, n * n)
             for name in ("signature", "slowsave")}
# procvars: procedure variables and a method pointer taken before the swaps call the new
# code, and @OnHidden keeps its first address: the old entry of each, also of a routine
# declared only in the implementation section, jumps to the new code, also after a save
# that declares it in the interface and one that takes that back (PRINTS has the save in
# between). The tick a swap is written in makes three calls, so it may print any mix of old
# and new
SWAPPED["procvars"] = lambda n: "PLAIN V2 %d, METHOD V2 %d, HIDDEN V4 %d, same address: TRUE TRUE" % (n, n, n)
UNSWAPPED["procvars"] = lambda n: re.compile(r"PLAIN V2 %d, METHOD V2 %d, HIDDEN V[34] %d, same address: TRUE (TRUE|FALSE)" % (n, n, n))
# initrace: Speed and Pair keep the values the program wrote while the swap loaded; a tick
# that ran while the swap was written may still print either from before that write
SWAPPED["initrace"] = lambda n: "speed 6 pair 2 2"
UNSWAPPED["initrace"] = lambda n: re.compile(r"speed [56] pair [12] 2")
# case: notes every swap of the case gives: these change the main block
NOTES = {name: ["the main block changed; the frame that is running keeps its old code"] for name in ("signature", "slowsave")}
# case: lines hotfpc must print (patterns, after "[hot] ")
SAYS = {
    # the program starts with the units of the build it runs, without one a save left out
    "startunit": [r"v1: built in [\d.]+ ms, started in [\d.]+ ms, 2 units of its own",
                  r"restart needed: unit w is not part of the running program"],
    # the save of Speed = 50, whose value PRINTS checks
    "globals": [r"  note: U\.SPEED still had its initial value; set to the new one"],
    # written during the load: the commit finds it so and keeps the program's value
    "initrace": [r"  note: the initial value of U\.SPEED changed; the running value is kept",
                 r"  note: the initial value of U\.PAIR changed; the running value is kept"],
}
# case: the word before a number that counts the calls of Tick, as the tick number does. It
# is a variable of the unit's implementation section, which every swap must leave in place,
# so every tick prints it and the two numbers stay equal
COUNTERS = {"globals": "hidden", "hidden": "calls"}
# case: (what every tick before the marker prints, the marker, what every tick after it
# prints): the program hands over from old code to new at the marker, which it prints once,
# and at least one tick follows it. The driver's record of the swap is no boundary: the
# program runs on while the driver prints it. In nestedframe the frame of Run that runs
# across the swap calls the old Show once more, with its own values (the new Show would read
# that frame with the new layout), and the fresh frames of the new Run after it the new Show
HANDOFFS = {"nestedframe": ("base 42 v1", "last 42 v1", "base 42 v2")}
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
    # the reason a Windows program gives, so that the sizes it is checked against are the
    # ones the case is about: the sizes of the build the program started from (startblock),
    # of the unit a restart added (newconst; with fpc 3.3 the unit file has the constant's
    # type, and the check of layouts finds it first), unknown after the sources kept changing
    # during the builds at the start (startcap), and unknown when fpc wrote no assembler for
    # the build the program started from, with the check still on (startnoasm)
    SAYS["startblock"] = [r"restart needed: variable MAIN\.CALLS changed size from 4 to 8 bytes"]
    SAYS["newconst"] = [r"restart needed: (variable W\.LIMIT changed size from 4 to 8 bytes|w\.Limit: the declaration changed its layout or type)"]
    SAYS["startcap"] = [r"restart needed: the sizes of variables with initial values are unknown: the sources changed while fpc compiled them"]
    SAYS["startnoasm"] = [r".* did not compile the program to assembler \(.*\): until the program starts over, a save that needs the sizes of variables with initial values needs a restart",
                          r"restart needed: the sizes of variables with initial values are unknown: .* did not compile the program to assembler"]
# On arm64 a redirect is one 4-byte instruction, which every routine has room for. A COFF
# object pads the section of each of fpc's routines to 16 bytes, so on Windows the jump
# fits too. There, shortentry is swapped.
if platform.machine().lower() not in ("x86_64", "amd64") or "-Twin" in os.environ.get("HOT_DRIVER_OPTS", "") or sys.platform == "win32":
    EXPECT["shortentry"] = (1, 0, 0)
    RESTARTS["shortentry"] = 0
# On arm64 a call is as long as the redirect, so it returns after it; Windows has the same
# x86-64 jump as macOS and Linux. On arm64 shortcall is swapped, and so are sighandler and
# sigmasked, where the trapped thread resumes after the branch.
if platform.machine().lower() not in ("x86_64", "amd64"):
    for name in ("shortcall", "sighandler", "sigmasked"):
        EXPECT[name] = (1, 0, 0)
        RESTARTS[name] = 0
names = sys.argv[1:] or list(EXPECT)
# scenario.py writes UTF-8 to this script whatever the console's encoding, and this script
# prints what its console can't show escaped
sys.stdout.reconfigure(errors="backslashreplace")
# SIGTERM or SIGHUP to this script ends scenario.py too, which stops the case it runs, also
# one that comes while scenario.py starts; Ctrl+C reaches both
signalled = []
scenarios = None
if sys.platform != "win32":
    def forward(number, frame):
        signalled.append(number)
        if scenarios is not None:
            scenarios.send_signal(number)
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, forward)
scenarios = subprocess.Popen([sys.executable, os.path.join(HERE, "scenario.py")] + names, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, encoding="utf-8", errors="backslashreplace",
                             env=dict(os.environ, PYTHONIOENCODING="utf-8:backslashreplace"))
if signalled:
    scenarios.send_signal(signalled[0])
stdout, stderr = scenarios.communicate()
if signalled:
    sys.exit(128 + signalled[0])
run = subprocess.CompletedProcess(scenarios.args, scenarios.returncode, stdout, stderr)
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
    # the run's lines without the script's timestamps: the driver's start with "[hot] ", the
    # script's own with "--- " or "!!! ", the program's with what it printed. Each check
    # matches a whole record from its start, so a line of the program that has a driver's
    # words in it is no record of the driver's
    lines = re.findall(r"^ *\d+\.\d+s  (.*)$", body or "", re.M)
    # the script's first complaint, with the step it was at, and how long the case took, its
    # end included
    complaint = next((line[4:] for line in lines if line.startswith("!!! ")), None)
    took = next(("; took %s s" % m.group(1) for m in (re.match(r"--- the case took ([\d.]+) s$", line) for line in lines) if m), "")
    said = ("; " + complaint if complaint is not None else "") + took
    ends = [m for m in (re.match(r"\[hot\] the program ended with (-?\d+) after .*?; (\d+) reloads applied, (\d+) refused, (\d+) failed to compile, (\d+) without a change in code, (\d+) restarts$", line) for line in lines) if m]
    end = ends[-1] if ends else None
    if not end:
        print("%-11s FAIL  %s%s" % (name, "no closing line" if body is not None else "did not run", said))
        failing.append((name, body))
        continue
    rc, applied, refused, failed, unchanged, restarts = map(int, end.groups())
    ea, er, ef = EXPECT[name]
    # rapid: a save that lands while fpc compiles the one before is compiled again with it,
    # so the two may make one reload; a compile is never acted on when the sources changed
    # during it, so none finds the same code ("not swapped")
    # "!!! " is the script's own complaint: an edit that does not apply, or a save the driver
    # gave no outcome for
    ok = rc == 0 and (applied in ea if isinstance(ea, tuple) else applied == ea) and (refused in er if isinstance(er, tuple) else refused == er) and failed == ef and unchanged == 0 and restarts == RESTARTS.get(name, 0) and complaint is None
    # the program's tick records: the same records count toward continuity and carry the
    # counters
    def tick_records(lines):
        return [m.groups() for m in (re.match(r"tick (\d+):(.*)$", line) for line in lines) if m]
    records = tick_records(lines)
    ticks = [int(tick) for tick, _ in records]
    # every number from 1 to the last, counted without listing them: a program whose memory a
    # swap broke can print any number
    seq = bool(ticks) and min(ticks) == 1 and len(set(ticks)) == max(ticks)
    ok = ok and seq
    missing = [text for text in PRINTS.get(name, [])
               if not any(re.match(r"tick \d+: " + (text.pattern if isinstance(text, re.Pattern) else re.escape(text)) + "$", line)
                          for line in lines)]
    ok = ok and not missing
    unsaid = [pattern for pattern in SAYS.get(name, []) if not any(re.match(r"\[hot\] " + pattern, line) for line in lines)]
    ok = ok and not unsaid
    drift = []
    for tick, text in records if name in COUNTERS else []:
        count = re.search(r"\b%s (\d+)" % COUNTERS[name], text)
        if not count or count.group(1) != tick:
            drift.append((tick, count and count.group(1)))
    ok = ok and not drift
    # the driver's records of its swaps, by their place among the lines
    swapped = [i for i, line in enumerate(lines) if re.match(r"\[hot\] v\d+ swapped: ", line)]
    # every tick after the last swap's record ran its code, but the first, which may have been
    # running when the swap was written; and one of them did
    after = tick_records(lines[swapped[-1] + 1:]) if name in SWAPPED and swapped else []
    def unswapped(tick, text):
        expected = UNSWAPPED[name](int(tick))
        return expected.fullmatch(text.strip()) if isinstance(expected, re.Pattern) else text == " " + expected
    stale = [(tick, text.strip()) for i, (tick, text) in enumerate(after)
             if text != " " + SWAPPED[name](int(tick)) and not (i == 0 and unswapped(tick, text))]
    if name in SWAPPED and not any(text == " " + SWAPPED[name](int(tick)) for tick, text in after):
        stale.append(("", "no tick"))
    ok = ok and not stale
    # each note of a swap comes once, though fpc may give what it notes two names (the main
    # block is PASCALMAIN and main); a swap's notes follow its record, up to the driver's next
    # record of another kind, and the program's lines may come between them
    swaps, notes = [], None
    for i, line in enumerate(lines):
        note = re.match(r"\[hot\]   note: (.*)$", line)
        if i in swapped:
            notes = []
            swaps.append(notes)
        elif note and notes is not None:
            notes.append(note.group(1))
        elif line.startswith("[hot] "):
            notes = None
    repeated = [text for notes in swaps for text in sorted(set(notes)) if notes.count(text) > 1]
    ok = ok and not repeated
    # and the notes every swap of the case must give
    unnoted = [text for text in NOTES.get(name, []) if not swaps or any(text not in notes for notes in swaps)]
    ok = ok and not unnoted
    handoff = []
    if name in HANDOFFS:
        before, marker, later = HANDOFFS[name]
        texts = [text.strip() for _, text in records]
        marks = [i for i, text in enumerate(texts) if text == marker]
        if len(marks) != 1:
            handoff.append("printed %r %d times" % (marker, len(marks)))
        else:
            wrong = [(records[i][0], text) for i, text in enumerate(texts) if text != (before if i < marks[0] else marker if i == marks[0] else later)]
            if wrong:
                handoff.append("tick %s printed %r" % wrong[0])
            if marks[0] == len(texts) - 1:
                handoff.append("no tick after %r" % marker)
    ok = ok and not handoff
    loads = [float(m.group(1)) for m in (re.search(r"of which in the program (-?[\d.]+)\)$", lines[i]) for i in swapped) if m]
    slow = [x for x in loads if name in LOAD_LIMITS and not 0 <= x < LOAD_LIMITS[name]]
    ok = ok and not slow
    print("%-11s %s  exit %d, %d applied, %d refused, %d failed, %d unchanged, %d restarts; ticks 1..%d %s"
          % (name, "ok  " if ok else "FAIL", rc, applied, refused, failed, unchanged, restarts, max(ticks) if ticks else 0, "all present" if seq else "WITH GAPS")
          + "".join("; never printed %r" % getattr(text, "pattern", text) for text in missing)
          + "".join("; hotfpc never said %r" % pattern for pattern in unsaid)
          + "".join("; tick %s printed %s" % (tick, "%s %s" % (COUNTERS[name], count) if count else "no %s number" % COUNTERS[name])
                    for tick, count in drift[:1])
          + "".join("; a load took %s ms in the program" % x for x in slow)
          + "".join("; after the swap tick %s printed %r" % (tick, text) if tick else "; no tick after the swap ran its code"
                    for tick, text in stale[:1])
          + "".join("; a swap noted %r twice" % text for text in repeated[:1])
          + "".join("; a swap did not note %r" % text for text in unnoted[:1])
          + "".join("; " + text for text in handoff[:1])
          + said)
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
