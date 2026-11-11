#!/usr/bin/env python3
"""record-demo.py WORKDIR: the script behind docs/demo.gif. Copies examples/demo to WORKDIR,
starts `hotfpc demo.pas` there and edits scene.pas three times while the program runs,
printing each change as a diff. hotfpc and fpc must be on PATH. From the repository root:

  asciinema rec --headless --window-size 110x26 --overwrite -c "python3 tools/record-demo.py ../demo-work" docs/demo.cast
  agg --font-size 15 --theme monokai --last-frame-duration 4 docs/demo.cast docs/demo.gif
  ffmpeg -i docs/demo.gif -movflags +faststart -pix_fmt yuv420p \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -crf 23 docs/demo.mp4
"""
import difflib, os, shutil, signal, subprocess, sys, time

here = os.path.dirname(os.path.abspath(__file__))
work = sys.argv[1]
shutil.rmtree(work, ignore_errors=True)
shutil.copytree(os.path.join(here, "..", "examples", "demo"), work)
scene = os.path.join(work, "scene.pas")

CYAN, RED, GREEN, DIM, OFF = "\x1b[36m", "\x1b[31m", "\x1b[32m", "\x1b[2m", "\x1b[0m"

# the edits: (pause before, old text, new text, what it shows)
EDITS = [
    (4.5, "StringOfChar('#',", "StringOfChar('*',", "a function body changes; the counter keeps counting"),
    (4.5, "Inc(Score, 1);", "Inc(Score, 2);", "Step counts in twos from where it was"),
    (4.5, "[Score, StringOfChar('*', 1 + Score mod 20)]", "[Score, #27'[33m' + StringOfChar('*', 1 + Score mod 20) + #27'[0m']",
     "the bar turns yellow"),
]


def say(text):
    sys.stdout.write(text)
    sys.stdout.flush()


def typed(cmd):
    say(GREEN + "$ " + OFF)
    for ch in cmd:
        say(ch)
        time.sleep(0.05)
    time.sleep(0.4)
    say("\r\n")


typed("hotfpc demo.pas")
p = subprocess.Popen(["hotfpc", "demo.pas"], cwd=work, start_new_session=True)
time.sleep(1.5)
for pause, old, new, why in EDITS:
    time.sleep(pause)
    text = open(scene).read()
    assert old in text, old
    edited = text.replace(old, new)
    lines = [l for l in difflib.unified_diff(text.splitlines(), edited.splitlines(), n=0, lineterm="")
             if l[:1] in "+-" and l[:3] not in ("+++", "---")]
    say("\r\n" + CYAN + "--- saved scene.pas: " + why + OFF + "\r\n")
    for l in lines:
        say((RED if l[0] == "-" else GREEN) + l + OFF + "\r\n")
    open(scene, "w").write(edited)
time.sleep(5)
os.killpg(p.pid, signal.SIGINT)
p.wait()
say(DIM + "(stopped)" + OFF + "\r\n")
time.sleep(1)
