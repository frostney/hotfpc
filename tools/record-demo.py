#!/usr/bin/env python3
"""record-demo.py WORKDIR: the script behind docs/demo.gif and docs/demo.mp4.

Copies examples/demo to WORKDIR and opens a tmux session with three panes: vim on
scene.pas (left), a shell (right) and hotfpc's timings (below vim). It types
`hotfpc --log hot.log demo.pas` into the shell, then makes four edits in vim, one key at a
time through `tmux send-keys`, and saves each with :w. The timings pane shows hotfpc's own
log (`record-demo.py --timings LOG`): for each save, the time from the save to the swap,
split into its parts. Needs tmux, vim, hotfpc and fpc on PATH.

From the repository root:

  asciinema rec --headless --window-size 130x45 --overwrite -c "python3 tools/record-demo.py ../demo-work" docs/demo.cast
  python3 tools/record-demo.py --trim docs/demo.cast
  agg --font-size 14 --theme monokai --fps-cap 20 --last-frame-duration 5 docs/demo.cast docs/demo.gif
  ffmpeg -i docs/demo.gif -movflags +faststart -pix_fmt yuv420p \\
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -crf 22 docs/demo.mp4

--trim drops what tmux prints when the session ends (it restores the screen it found).
"""
import json, os, random, re, shutil, subprocess, sys, time

ESC = "\x1b["
RST = ESC + "0m"


# ---------------------------------------------------------------------------- --timings
def timings(log):
    """Follows hotfpc's --log file and prints one line per build, swap or refusal."""
    print(ESC + "2m" + "hotfpc's own timings: save to swap, 1 block = 5 ms" + RST)
    print("  " + ESC + "90m" + "■ settle  " + ESC + "34m" + "■ compile  " + ESC + "35m" + "■ interface check  "
          + ESC + "32m" + "■ load into the program" + RST)
    print()
    while not os.path.exists(log):
        time.sleep(0.05)
    with open(log) as f:
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.03)
                continue
            line = line.split(" ", 1)[1].strip() if " " in line else line.strip()
            m = re.match(r"\[hot\] v1: built in ([\d.]+) ms, started in ([\d.]+) ms", line)
            if m:
                print("  v1  built in %.0f ms, started in %.0f ms" % (float(m.group(1)), float(m.group(2))))
                continue
            m = re.match(r"\[hot\] (v\d+) swapped: (\w+):.*?; ([\d.]+) ms after the save was seen \(settle ([\d.]+), compile ([\d.]+), interface check ([\d.]+), load ([\d.]+)", line)
            if m:
                v, unit, total, settle, comp, check, load = m.groups()
                parts = [(float(settle), "90"), (float(comp), "34"), (float(check), "35"), (float(load), "32")]
                bar = "".join(ESC + c + "m" + "■" * max(1, round(ms / 5)) for ms, c in parts) + RST
                print("  %-3s %s  %s%4.0f ms%s  %s" % (v, unit, ESC + "1m", float(total), RST, bar))
                continue
            m = re.match(r"\[hot\] restart needed: (.*) \(not applied; compile ([\d.]+) ms\)", line)
            if m:
                print("  " + ESC + "33m" + "restart needed: " + RST + m.group(1))
                print("      (compile %.0f ms; the program keeps running its current code)" % float(m.group(2)))
                continue
            m = re.match(r"\[hot\] not swapped: (.*)", line)
            if m:
                print("  " + ESC + "31m" + "not swapped: " + RST + m.group(1))


# ---------------------------------------------------------------------------- --trim
def trim(cast):
    """Drops the events from the moment tmux leaves its screen (and prints [server exited])."""
    lines = open(cast).read().splitlines()
    out = [lines[0]]
    for l in lines[1:]:
        ev = json.loads(l)
        if ev[1] == "o" and ("\x1b[?1049l" in ev[2] or "[server exited" in ev[2] or "[exited" in ev[2]):
            break
        out.append(l)
    open(cast, "w").write("\n".join(out) + "\n")


# ---------------------------------------------------------------------------- the recording
def record(work):
    here = os.path.dirname(os.path.abspath(__file__))
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(os.path.join(here, "..", "examples", "demo"), work)
    conf = os.path.join(work, ".tmux.conf")
    with open(conf, "w") as f:
        f.write("\n".join([
            "set -g status off",
            "set -g default-terminal screen-256color",
            "set -g escape-time 0",
            "set -g pane-border-status top",
            "set -g pane-border-format ' #{pane_title} '",
            "set -g pane-border-style fg=colour240",
            "set -g pane-active-border-style fg=colour240",
            "set -g allow-set-title off",
            "set -g allow-rename off",
        ]) + "\n")
    vimrc = os.path.join(work, ".vimrc")
    with open(vimrc, "w") as f:
        f.write("set nocompatible number ruler showcmd laststatus=2 noswapfile\nsyntax on\n")
    tmux = ["tmux", "-L", "hotfpc-demo", "-f", conf]
    env = ["-e", "PS1=$ ", "-e", "BASH_SILENCE_DEPRECATION_WARNING=1", "-e", "VIMINIT=source " + vimrc]
    shell = "bash --norc --noprofile"

    def t(*args):
        return subprocess.run(tmux + list(args), capture_output=True, text=True).stdout.strip()

    t("kill-server")
    pid = ["-P", "-F", "#{pane_id}"]
    editor = t("new-session", "-d", "-s", "demo", "-x", "130", "-y", "45", *pid, "-c", work, *env, shell)
    prog = t("split-window", "-h", "-l", "50", "-t", editor, *pid, "-c", work, *env, shell)
    timing = t("split-window", "-v", "-l", "11", "-t", editor, *pid, "-c", work, *env,
               "%s %s --timings hot.log" % (sys.executable, os.path.abspath(__file__)))
    t("select-pane", "-t", editor, "-T", "editor")
    t("select-pane", "-t", timing, "-T", "timings (from hot.log)")
    t("select-pane", "-t", prog, "-T", "terminal")
    t("select-pane", "-t", editor)
    client = subprocess.Popen(tmux + ["attach", "-t", "demo"], env=dict(os.environ, TERM="xterm-256color"))
    time.sleep(1.0)

    def keys(pane, text, delay=0.11):
        """Types text into a pane one key at a time; <CR> and <Esc> are those keys."""
        for tok in re.findall(r"<CR>|<Esc>|.", text, re.S):
            if tok == "<CR>":
                t("send-keys", "-t", pane, "Enter")
            elif tok == "<Esc>":
                t("send-keys", "-t", pane, "Escape")
            else:
                t("send-keys", "-t", pane, "-l", tok)
            time.sleep(delay * random.uniform(0.7, 1.3))

    keys(prog, "hotfpc --log hot.log demo.pas<CR>", 0.07)
    time.sleep(2.5)
    keys(editor, "vim scene.pas<CR>", 0.07)
    time.sleep(2.0)
    # the edits: find the place, change it, save
    for edit in ["/Glyph<CR>ci'*<Esc>:w<CR>",
                 "/Inc<CR>f1s2<Esc>:w<CR>",
                 "/32m<CR>cw33m<Esc>:w<CR>",
                 "/Integer<CR>cwInt64<Esc>:w<CR>"]:
        keys(editor, edit)
        time.sleep(3.5)
    time.sleep(1.0)
    t("kill-server")
    client.wait()


if __name__ == "__main__":
    if sys.argv[1] == "--timings":
        timings(sys.argv[2])
    elif sys.argv[1] == "--trim":
        trim(sys.argv[2])
    else:
        record(os.path.abspath(sys.argv[1]))
