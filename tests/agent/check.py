#!/usr/bin/env python3
"""The agent on its own: hotfpc builds a small program, so that the program has the agent as
hotfpc compiles it, and this script then starts the program itself and stands in for hotfpc
on the agent's protocol (source/HotFPC.Agent.pas): it waits for the agent's hello, sends each
case's command and checks the agent's reply. $HOT_DRIVER picks the driver (default:
build/hotfpc) and $HOT_DRIVER_OPTS adds options to it, as for the scenarios.

  check.py
"""
import os, platform, shlex, shutil, signal, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
# hotfpc runs in this script's directory, as for the scenarios, so that a relative path in
# these means the same to both
DRIVER = os.environ.get("HOT_DRIVER") or os.path.join(HERE, "..", "..", "build", "hotfpc")
OPTS = shlex.split(os.environ.get("HOT_DRIVER_OPTS", ""))
WORK = os.path.join(HERE, "work")
TOKEN = "agent-check"
# the longest the build, the agent's connection, a reply or the program's end may take, in s
TIMEOUT = 120
# The program and the agent get paths relative to the work directory, where the program runs
# (a --run launcher has to start it there): the Windows agent opens files with the system's
# ANSI code page, which a checkout's absolute path may not fit
STOP = "stop"

# The program waits for the file its first argument names, so that its agent stays connected,
# for 300 s at most; without one it ends at once, as when hotfpc starts it to build it
MAIN = r'''program main;
{$mode objfpc}{$H+}
uses SysUtils;
var
  Waited: Integer = 0;
begin
  if ParamCount >= 1 then
    while not FileExists(ParamStr(1)) and (Waited < 6000) do
    begin
      Sleep(50);
      Inc(Waited);
    end;
end.
'''


def read_options(arguments):
    """hotfpc's launcher (--run, the last one) and fpc options in $HOT_DRIVER_OPTS, read as
    hotfpc reads its command line (TOptions.Parse): an option that takes a value takes the
    argument after it."""
    launcher, compiler_options, i = None, [], 0
    while i < len(arguments):
        argument = arguments[i]
        if argument in ("--fpc", "--ppudump", "--run", "--settle", "--log") and i + 1 < len(arguments):
            i += 1
            if argument == "--run":
                launcher = arguments[i]
        elif argument.startswith(("-", "@")) and argument not in ("--quiet", "--no-restart", "--version"):
            compiler_options.append(argument)
        i += 1
    return launcher, compiler_options


RUN, COMPILER_OPTIONS = read_options(OPTS)
# a Windows target, as hotfpc decides it: an fpc option -T followed by win in any case
WINDOWS = sys.platform == "win32" or any(opt[:2] == "-T" and opt[2:5].lower() == "win" for opt in COMPILER_OPTIONS)
# what hotfpc starts the program with: --run's launcher, and for a Windows program on another
# system Wine
LAUNCHER = RUN or ("wine" if WINDOWS and sys.platform != "win32" else None)
# the program runs in the work directory: a launcher's path is taken from here, as hotfpc
# takes it, and a bare name is looked up on PATH
if LAUNCHER and os.path.dirname(LAUNCHER):
    LAUNCHER = os.path.abspath(LAUNCHER)
# the most stopping a program and what it started may take, in s
STOP_TIMEOUT = 30


def object_format():
    """The object files the agent reads on this system, as its errors name them."""
    if WINDOWS:
        return "x86-64 COFF"
    machine = platform.machine().lower()
    arm = machine in ("arm64", "aarch64")
    if sys.platform == "darwin":
        return "arm64 Mach-O" if arm else "x86-64 Mach-O"
    return "aarch64 ELF" if arm else "x86-64 ELF"


def start(command, **options):
    """Starts a process in a group of its own, so that stop_tree reaches what it starts."""
    if sys.platform == "win32":
        return subprocess.Popen(command, creationflags=subprocess.CREATE_NEW_PROCESS_GROUP, **options)
    return subprocess.Popen(command, start_new_session=True, **options)


def stop_tree(process):
    """Stops a process this script started and what it started (fpc, or the program behind a
    launcher), by its PID. Raises when they don't end."""
    if sys.platform == "win32":
        if process.poll() is None:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(process.pid)], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=STOP_TIMEOUT)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)   # the group start() gave it
        except ProcessLookupError:
            pass
    process.wait(timeout=STOP_TIMEOUT)


def build():
    """Builds the program with hotfpc, which starts it once; it ends at once. Returns the path
    of the executable."""
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    with open(os.path.join(WORK, "main.pas"), "w") as f:
        f.write(MAIN)
    command = ([sys.executable, DRIVER] if DRIVER.endswith(".py") else [DRIVER]) + OPTS + ["--no-restart", os.path.join(WORK, "main.pas")]
    # hotfpc's output goes to a file: a pipe that something hotfpc started holds open could
    # keep this script waiting
    log = os.path.join(WORK, "hotfpc.log")
    with open(log, "w") as out:
        process = start(command, stdout=out, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            code = None
        finally:
            # also what it left running, as the program it started once
            stop_tree(process)
    with open(log) as f:
        output = f.read()
    executable = os.path.join(WORK, ".hot", "main.exe" if WINDOWS else "main")
    if code != 0 or not os.path.exists(executable):
        sys.exit("hotfpc %s, and %s %s:\n%s" % ("took more than %d s" % TIMEOUT if code is None else "ended with %d" % code,
                                                executable, "is there" if os.path.exists(executable) else "is missing", output))
    return executable


class Agent:
    """The program, started with the environment hotfpc gives it, and its agent's connection."""

    def __init__(self, executable):
        if os.path.exists(os.path.join(WORK, STOP)):
            os.remove(os.path.join(WORK, STOP))
        self.connection = None
        self.pending = b""
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(TIMEOUT)
        env = dict(os.environ, HOT_PORT=str(listener.getsockname()[1]), HOT_TOKEN=TOKEN)
        deadline = time.monotonic() + TIMEOUT
        self.process = start(([LAUNCHER] if LAUNCHER else []) + [executable, STOP], cwd=WORK, env=env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            try:
                self.connection, _ = listener.accept()
            finally:
                listener.close()
            hello = self.line(deadline)
            if hello != "hello " + TOKEN:
                raise RuntimeError("the agent said %r instead of its hello" % hello)
        except BaseException:
            self.close()
            raise

    def line(self, deadline):
        """The agent's next line, before the deadline (time.monotonic)."""
        while b"\n" not in self.pending:
            left = deadline - time.monotonic()
            if left <= 0:
                raise RuntimeError("the agent did not answer within %d s" % TIMEOUT)
            self.connection.settimeout(left)
            data = self.connection.recv(4096)
            if not data:
                raise RuntimeError("the agent closed its connection")
            self.pending += data
        line, self.pending = self.pending.split(b"\n", 1)
        return line.decode("utf-8", "replace").rstrip("\r")

    def command(self, *fields):
        """Sends a command; the agent's reply, its lines up to the "." that ends it."""
        deadline = time.monotonic() + TIMEOUT
        self.connection.sendall(("\t".join(fields) + "\n").encode())
        reply = []
        while True:
            line = self.line(deadline)
            if line == ".":
                return reply
            reply.append(line)

    def closed_by_agent(self, deadline):
        """Whether the agent closes its connection before the deadline, as it does when the
        program ends."""
        if self.connection is None:
            return False
        try:
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    return False
                self.connection.settimeout(left)
                if not self.connection.recv(4096):
                    return True
        except ConnectionResetError:
            return True
        except OSError:   # the timeout
            return False

    def close(self):
        """Ends the program through the file it waits for. Its exit code, or None when its
        agent didn't close the connection as the program ended: a launcher may end before
        the program does. It and what it started are stopped when it doesn't end."""
        try:
            with open(os.path.join(WORK, STOP), "w"):
                pass
            deadline = time.monotonic() + TIMEOUT
            if not self.closed_by_agent(deadline):
                return None
            return self.process.wait(timeout=max(deadline - time.monotonic(), 1))
        finally:
            try:
                stop_tree(self.process)
            finally:
                if self.connection is not None:
                    self.connection.close()


def bad_object(agent):
    """A file that is no object file: the agent names the object files it reads, for the
    system it runs on."""
    path = "notanobject.o"
    with open(os.path.join(WORK, path), "w") as f:
        f.write("this is not an object file\n")
    reply = agent.command("load", path)
    expected = "error %s is not an %s object" % (path, object_format())
    errors = [line for line in reply if line.startswith("error ")]
    return errors == [expected] and reply[-1:] == ["failed"], "replied %r, expected %r and failed" % (reply, expected)


CASES = [("badobject", bad_object)]


def main():
    agent = Agent(build())
    failed = 0
    try:
        for name, case in CASES:
            ok, detail = case(agent)
            print("%-11s %s%s" % (name, "ok" if ok else "FAIL  ", "" if ok else detail))
            failed += not ok
    finally:
        code = agent.close()
    if code is None:
        print("the program's agent did not close its connection within %d s" % TIMEOUT)
    elif code != 0:
        print("the program ended with %d" % code)
    print("%d of %d cases as expected" % (len(CASES) - failed, len(CASES)))
    return 1 if failed or code != 0 else 0


if __name__ == "__main__":
    sys.exit(main())
