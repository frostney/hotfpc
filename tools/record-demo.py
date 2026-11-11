#!/usr/bin/env python3
"""record-demo.py WORKDIR: the script behind docs/demo.gif and docs/demo.mp4.

Copies examples/demo to WORKDIR, starts `hotfpc demo.pas` there and draws a split screen:
scene.pas on the left, the running program's output on the right, and below them a table
with the time from each save to the swap and to the first line of output that shows it.
The left pane is this script's own view of the file: it types each edit there and writes
the file at the moment it shows "saved". The right pane and the timings come from the real
run. hotfpc and fpc must be on PATH; the terminal must be at least 130x45.

From the repository root:

  asciinema rec --headless --window-size 130x45 --overwrite -c "python3 tools/record-demo.py ../demo-work" docs/demo.cast
  agg --font-size 14 --theme monokai --fps-cap 20 --last-frame-duration 5 docs/demo.cast docs/demo.gif
  ffmpeg -i docs/demo.gif -movflags +faststart -pix_fmt yuv420p \\
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -crf 22 docs/demo.mp4
"""
import os, pty, re, select, shutil, subprocess, sys, time

here = os.path.dirname(os.path.abspath(__file__))
work = os.path.abspath(sys.argv[1])
shutil.rmtree(work, ignore_errors=True)
shutil.copytree(os.path.join(here, "..", "examples", "demo"), work)
SCENE = os.path.join(work, "scene.pas")

COLS, ROWS = 130, 45
LEFT = 85                       # the editor pane, with the separator after it
RIGHT = COLS - LEFT - 1
TOP = 2                         # rows above the panes
PANE = ROWS - TOP - 9           # rows of the panes
ESC = "\x1b["
RST = ESC + "0m"
DIM, BOLD, REV = ESC + "2m", ESC + "1m", ESC + "7m"
CYAN, GREEN, YELLOW, RED, BLUE, MAGENTA = (ESC + c + "m" for c in ("36", "32", "33", "31", "34", "35"))
BG_EDIT, BG_SAVED = ESC + "48;5;237m", ESC + "48;5;58m"
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def strip(s):
    return ANSI.sub("", s)


def fit(s, width):
    """s cut or padded to width visible columns, its escapes kept."""
    out, n, i = [], 0, 0
    while i < len(s) and n < width:
        m = ANSI.match(s, i)
        if m:
            out.append(m.group())
            i = m.end()
            continue
        out.append(s[i])
        n += 1
        i += 1
    return "".join(out) + RST + " " * (width - n)


KEYWORDS = set("""unit interface implementation uses const var procedure function begin end
string integer int64 type if then else for to do while repeat until result""".split())


def pascal(line):
    """A line of Pascal with colours for keywords, strings and character codes."""
    out = []
    for tok in re.findall(r"'[^']*'|#\d+|\{[^}]*\}|[A-Za-z_][A-Za-z0-9_]*|\d+|.", line):
        if tok.startswith("'") or tok.startswith("#"):
            out.append(GREEN + tok + RST)
        elif tok.startswith("{"):
            out.append(DIM + tok + RST)
        elif tok.lower() in KEYWORDS:
            out.append(BLUE + BOLD + tok + RST)
        elif tok.isdigit():
            out.append(MAGENTA + tok + RST)
        else:
            out.append(tok)
    return "".join(out)


# the edits: what the table calls it, the text before and after (on one line), and how to
# recognise the first line of output that shows it (None: it is not expected to show)
EDITS = [
    ("Glyph '#' becomes '*'", "  Glyph = '#';", "  Glyph = '*';",
     lambda line, prev: "*" in strip(line)),
    ("Step counts in twos", "  Inc(Score, 1);", "  Inc(Score, 2);",
     lambda line, prev: prev is not None and score(line) == prev + 2),
    ("Color green becomes yellow", "  Color = #27'[32m';", "  Color = #27'[33m';",
     lambda line, prev: ESC + "33m" in line),
    ("Score: Integer becomes Int64", "  Score: Integer = 0;", "  Score: Int64 = 0;", None),
]


def score(line):
    m = re.search(r"score\s+(\d+)", strip(line))
    return int(m.group(1)) if m else None


class Run:
    def __init__(self):
        self.t0 = time.time()
        self.text = open(SCENE).read().split("\n")
        self.cursor = None          # (row, column) while typing
        self.edit_row = None
        self.saved_at = None        # (row, time) of the last save, for its highlight
        self.output = []            # the program's lines
        self.hot = []               # hotfpc's lines
        self.partial = ""
        self.pending = ""           # the start of a program line that a [hot] line cut in two
        self.rows = []              # the timing table: dicts
        self.last = None

    # ---- the program's side
    def feed(self, data):
        self.partial += data.decode("utf-8", "replace").replace("\r", "")
        while "\n" in self.partial:
            line, self.partial = self.partial.split("\n", 1)
            i = line.find("[hot]")
            if i > 0:
                self.pending += line[:i]
                line = line[i:]
            if line.startswith("[hot]"):
                self.on_hot(line)
            else:
                self.on_output(self.pending + line)
                self.pending = ""

    def on_hot(self, line):
        now = time.time()
        self.hot.append(line)
        row = self.rows[-1] if self.rows else None
        if row is None or row.get("result"):
            return
        m = re.search(r"compile ([\d.]+)", line)
        row["compile"] = float(m.group(1)) if m else None
        if " swapped:" in line:
            row["swap"] = now - row["saved"]
            row["result"] = GREEN + line.split(":")[0].replace("[hot] ", "") + RST
        elif "restart needed" in line:
            row["swap"] = None
            row["result"] = YELLOW + "restart needed" + RST + ", program left running"
        elif "not swapped" in line:
            row["result"] = RED + "not swapped" + RST

    def on_output(self, line):
        now = time.time()
        prev = score(self.output[-1]) if self.output else None
        self.output.append(line)
        for row in self.rows:
            if row.get("first") is None and row["test"] and row["test"](line, prev):
                row["first"] = now - row["saved"]

    # ---- the screen
    def draw(self):
        t = time.time() - self.t0
        lines = []
        title = " hotfpc: edit a unit on the left, the program keeps running on the right"
        clock = "t = %5.1f s " % t
        lines.append(REV + BOLD + title + " " * (COLS - len(title) - len(clock)) + clock + RST)
        saved_note = ""
        if self.saved_at and time.time() - self.saved_at[1] < 1.5:
            saved_note = YELLOW + "  saved" + RST
        lines.append(fit(BOLD + " scene.pas" + RST + saved_note, LEFT) + DIM + "│" + RST
                     + fit(BOLD + " $ hotfpc demo.pas" + RST + DIM + "   (the program's output)" + RST, RIGHT))
        out = self.output[-PANE:]
        for r in range(PANE):
            if r < len(self.text):
                code = self.text[r]
                bg = ""
                if self.cursor and self.cursor[0] == r:
                    c = self.cursor[1]
                    code = code[:c] + REV + (code[c:c + 1] or " ") + RST + BG_EDIT + code[c + 1:]
                    bg = BG_EDIT
                elif self.saved_at and self.saved_at[0] == r and time.time() - self.saved_at[1] < 1.5:
                    bg = BG_SAVED
                    code = pascal(code).replace(RST, RST + bg)
                else:
                    code = pascal(code)
                left = DIM + "%3d " % (r + 1) + RST + bg + code
                left = fit(left, LEFT).replace(RST + " ", RST + bg + " ", 1) if bg else fit(left, LEFT)
            else:
                left = " " * LEFT
            right = " " + out[r] if r < len(out) else ""
            lines.append(left + RST + DIM + "│" + RST + fit(right, RIGHT))
        lines.append(DIM + "─" * COLS + RST)
        head = " %-34s %16s %12s %22s   %s" % ("edit", "save → swapped", "compile", "save → new output", "result")
        lines.append(BOLD + fit(head, COLS) + RST)
        for i in range(len(EDITS)):
            if i < len(self.rows):
                row = self.rows[i]
                swap = "%.0f ms" % (row["swap"] * 1000) if row.get("swap") else ("—" if row.get("result") else "…")
                comp = "%.0f ms" % row["compile"] if row.get("compile") else ("—" if row.get("result") else "")
                first = "%.0f ms" % (row["first"] * 1000) if row.get("first") else ("—" if row["test"] is None and row.get("result") else "")
                lines.append(fit(" %-34s %16s %12s %22s   %s" % (row["name"], swap, comp, first, row.get("result") or ""), COLS))
            else:
                lines.append(" " * COLS)
        hot = self.hot[-1] if self.hot else ""
        lines.append(DIM + "─" * COLS + RST)
        lines.append(fit(CYAN + hot[:COLS] + RST, COLS))
        lines.append(fit(CYAN + hot[COLS:2 * COLS] + RST, COLS))
        screen = ESC + "H" + "\r\n".join(lines[:ROWS])
        if screen != self.last:
            sys.stdout.write(screen)
            sys.stdout.flush()
            self.last = screen


run = Run()
sys.stdout.write(ESC + "?25l" + ESC + "2J")
master, slave = pty.openpty()
p = subprocess.Popen(["hotfpc", "demo.pas"], cwd=work, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
                     start_new_session=True)
os.close(slave)


def wait(seconds):
    """Pump the program's output and redraw for this long."""
    end = time.time() + seconds
    while True:
        left = end - time.time()
        if left <= 0:
            break
        r, _, _ = select.select([master], [], [], min(left, 0.05))
        if r:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if data:
                run.feed(data)
        run.draw()


def type_edit(old, new):
    """Shows the edit typed into the line: the differing part deleted, then the new part."""
    row = run.text.index(old)
    pre = 0
    while pre < min(len(old), len(new)) and old[pre] == new[pre]:
        pre += 1
    suf = 0
    while suf < min(len(old), len(new)) - pre and old[-1 - suf] == new[-1 - suf]:
        suf += 1
    line = old
    run.cursor = (row, len(old) - suf)
    wait(0.5)
    while len(line) - suf > pre:            # backspace over the old part
        cut = len(line) - suf
        line = line[:cut - 1] + line[cut:]
        run.text[row] = line
        run.cursor = (row, cut - 1)
        wait(0.09)
    for ch in new[pre:len(new) - suf]:      # type the new part
        cut = len(line) - suf
        line = line[:cut] + ch + line[cut:]
        run.text[row] = line
        run.cursor = (row, cut + 1)
        wait(0.09)
    wait(0.35)
    return row


wait(3.0)
for name, old, new, test in EDITS:
    row = type_edit(old, new)
    run.cursor = None
    with open(SCENE, "w") as f:
        f.write("\n".join(run.text))
    now = time.time()
    run.saved_at = (row, now)
    run.rows.append({"name": name, "saved": now, "test": test})
    wait(3.2)
wait(2.0)
os.killpg(p.pid, 2)
try:
    p.wait(timeout=5)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, 9)
sys.stdout.write(ESC + "?25h")
sys.stdout.flush()
