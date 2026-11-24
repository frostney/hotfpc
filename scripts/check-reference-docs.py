#!/usr/bin/env python3
"""check-reference-docs.py: fails when docs/reference/ no longer describes what hotfpc
prints and reads (docs/internals/tooling.md, "The reference check").

The reference is written by hand. This keeps it complete: a new option, a new [hot] line or
a new environment variable fails CI until it is documented. It checks that docs/reference/

  - quotes the driver's usage text (UsageText in source/HotFPC.pas) exactly;
  - describes every option in it in a table row of its own (a line that starts with
    | `--option), and no option that the usage text doesn't have;
  - has every [hot] line the driver prints (FReporter.Say, WriteLn('[hot] ...'), and the
    compiler problems it prints that way), and every restart reason, note and error that
    the agent sends back (source/HotFPC.Agent.pas);
  - describes every HOT_* environment variable in source/ in a table row of its own.

A line matches when its fixed parts appear in order on one line of docs/reference/. The
parts filled in at run time, such as a unit's name or a time, can be written as anything
there, such as <unit> or <ms>. Python 3.9 or later, nothing else.

  python3 scripts/check-reference-docs.py
"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVER = os.path.join(ROOT, "source", "HotFPC.pas")
AGENT = os.path.join(ROOT, "source", "HotFPC.Agent.pas")
REFERENCE = os.path.join(ROOT, "docs", "reference")
# The agent's replies start with a word of the protocol that the driver turns into its own
# words ("restart needed:", "note:", "error:"); the rest is what the reference shows.
AGENT_PREFIXES = ("restart ", "note ", "error ")
# A fixed part this short ('.', ', ', ' s') says nothing about the line and isn't matched.
SHORTEST_PART = 3
HOLE = None  # a part filled in at run time
FORMAT_SPECIFIER = re.compile(r"%[-\d.:*]*[dsfegnmpux]", re.I)


def blank_comments(text):
    """The source with its comments replaced by spaces, strings kept, so that a call
    mentioned in a comment isn't taken for one."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif c == "{" or text.startswith("(*", i):
            close = "}" if c == "{" else "*)"
            j = text.find(close, i + 1)
            j = n if j < 0 else j + len(close)
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def read_until(text, start, stop):
    """The text from start to the first character in stop outside strings and brackets,
    and the index of that character."""
    depth, i = 0, start
    while i < len(text):
        c = text[i]
        if c == "'":
            i += 1
            while i < len(text) and not (text[i] == "'" and text[i + 1:i + 2] != "'"):
                i += 2 if text[i] == "'" else 1
        elif depth == 0 and c in stop:
            return text[start:i], i
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        i += 1
    raise ValueError("unterminated expression at %d" % start)


def string_value(literal):
    return literal[1:-1].replace("''", "'")


def parts_of(expression):
    """The parts of a string expression: fixed text, and HOLE for each part that is only
    known at run time. Format('...', [...]) counts as its format string."""
    expression = expression.strip()
    if expression.startswith("Format("):
        inner, _ = read_until(expression, len("Format("), ",")
        return parts_of(inner)
    parts, i = [], 0
    while i < len(expression):
        c = expression[i]
        if c.isspace() or c in "+,":
            i += 1
        elif c == "'":
            match = re.compile(r"'(?:[^']|'')*'").match(expression, i)
            for k, piece in enumerate(FORMAT_SPECIFIER.split(string_value(match.group()))):
                if k:
                    parts.append(HOLE)
                parts.append(piece)
            i = match.end()
        else:
            _, i = read_until(expression + "+", i, "+,")
            parts.append(HOLE)
    return parts


def calls(text, pattern):
    """The argument text of every call whose opening matches pattern (which ends at the
    opening bracket)."""
    for match in re.finditer(pattern, text):
        argument, _ = read_until(text, match.end(), ")")
        yield argument


def fixed_parts(parts):
    return [p.strip() for p in parts if p is not HOLE and len(p.strip()) >= SHORTEST_PART]


def show(parts):
    return "".join("…" if p is HOLE else p for p in parts).strip()


def driver_lines(text):
    lines = [parts_of(a) for a in calls(text, r"\bFReporter\.Say\(")]
    for argument in calls(text, r"\bWriteLn\((?='\[hot\] )"):
        parts = parts_of(argument)
        parts[0] = parts[0][len("[hot] "):]
        lines.append(parts)
    # what the compiler check reports, as a [hot] line of its own
    for match in re.finditer(r"\bAProblem\s*:=", text):
        expression, _ = read_until(text, match.end(), ";")
        lines.append(parts_of(expression))
    return lines


def agent_lines(text):
    lines = [parts_of(a) for a in calls(text, r"(?<!procedure )\bRestart\(")]
    for argument in calls(text, r"\bSay\("):
        parts = parts_of(argument)
        if parts and parts[0] is not HOLE and parts[0].startswith(AGENT_PREFIXES):
            parts[0] = parts[0].split(" ", 1)[1]
            lines.append(parts)
    return lines


def documented(parts, reference_lines):
    """Whether one line of the reference has the fixed parts in order."""
    wanted = fixed_parts(parts)
    for line in reference_lines:
        at = 0
        for part in wanted:
            at = line.find(part, at)
            if at < 0:
                break
            at += len(part)
        else:
            return True
    return False


def main():
    driver = blank_comments(open(DRIVER, encoding="utf-8").read())
    agent = blank_comments(open(AGENT, encoding="utf-8").read())
    reference_files = sorted(glob.glob(os.path.join(REFERENCE, "*.md")))
    reference = "\n".join(open(f, encoding="utf-8").read() for f in reference_files)
    reference_lines = reference.splitlines()
    problems = []

    usage_expression, _ = read_until(driver, re.search(r"\bUsageText\s*=", driver).end(), ";")
    usage = "".join(p for p in parts_of(usage_expression) if p is not HOLE)
    if usage not in reference:
        problems.append("the usage text is not quoted as hotfpc prints it:\n    " + usage)
    options = sorted(set(re.findall(r"--[a-z][a-z-]*", usage)))
    for option in options:
        if not re.search(r"^\| `" + re.escape(option) + r"[ `]", reference, re.M):
            problems.append("option %s (in the usage text) has no row in an options table" % option)
    for option in sorted(set(re.findall(r"`(--[a-z][a-z-]*)", reference)) - set(options)):
        problems.append("option %s is described but hotfpc doesn't have it" % option)

    lines = [("driver", p) for p in driver_lines(driver)] + [("agent", p) for p in agent_lines(agent)]
    checked = 0
    for source, parts in lines:
        if not fixed_parts(parts):
            continue  # nothing fixed to look for, such as FReporter.Say(Problem)
        checked += 1
        if not documented(parts, reference_lines):
            problems.append("%s line is not documented: %s" % (source, show(parts)))

    variables = sorted(set(re.findall(r"\bHOT_[A-Z_]+\b", open(DRIVER).read() + open(AGENT).read())))
    for variable in variables:
        if not re.search(r"^\| `" + variable + r"`", reference, re.M):
            problems.append("environment variable %s has no row in a table" % variable)

    for problem in problems:
        print(problem)
    if problems:
        print("\n%d missing from docs/reference/; add them to the page that covers them." % len(problems))
        return 1
    print("docs/reference/ covers the usage text, its %d options, %d [hot] lines and %d environment variables"
          % (len(options), checked, len(variables)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
