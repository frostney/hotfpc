#!/usr/bin/env python3
"""The agent on its own: hotfpc builds a small program, so that the program has the agent as
hotfpc compiles it, and this script then starts the program itself and stands in for hotfpc
on the agent's protocol (source/HotFPC.Agent.pas): it waits for the agent's hello, sends each
case's command and checks the agent's reply. $HOT_DRIVER picks the driver (default:
build/hotfpc) and $HOT_DRIVER_OPTS adds options to it, as for the scenarios.

  check.py
"""
import os, platform, shlex, shutil, socket, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# absolute: hotfpc runs in the work directory, so that fpc's link files go there
DRIVER = os.path.abspath(os.environ.get("HOT_DRIVER") or os.path.join(HERE, "..", "..", "build", "hotfpc"))
OPTS = shlex.split(os.environ.get("HOT_DRIVER_OPTS", ""))
WORK = os.path.join(HERE, "work")
TOKEN = "agent-check"
# the longest the build, the agent's connection or a reply may take, in s
TIMEOUT = 120

# The program waits for the file its first argument names, so that its agent stays connected;
# without one it ends at once, as when hotfpc starts it to build it
MAIN = r'''program main;
{$mode objfpc}{$H+}
uses SysUtils;
begin
  if ParamCount >= 1 then
    while not FileExists(ParamStr(1)) do
      Sleep(50);
end.
'''

WINDOWS = sys.platform == "win32" or any(opt.startswith("-Twin") for opt in OPTS)
# a Windows program on another system runs under Wine, which hotfpc uses too (--run)
WINE = WINDOWS and sys.platform != "win32"


def agent_path(path):
    """A path as the agent opens it: under Wine, the Windows path of the file."""
    return "Z:" + path.replace("/", "\\") if WINE else path


def object_format():
    """The object files the agent reads on this system, as its errors name them."""
    if WINDOWS:
        return "x86-64 COFF"
    machine = platform.machine().lower()
    arm = machine in ("arm64", "aarch64")
    if sys.platform == "darwin":
        return "arm64 Mach-O" if arm else "x86-64 Mach-O"
    return "aarch64 ELF" if arm else "x86-64 ELF"


def build():
    """Builds the program with hotfpc, which starts it once; it ends at once. Returns the path
    of the executable."""
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    source = os.path.join(WORK, "main.pas")
    with open(source, "w") as f:
        f.write(MAIN)
    command = ([sys.executable, DRIVER] if DRIVER.endswith(".py") else [DRIVER]) + OPTS + ["--no-restart", source]
    run = subprocess.run(command, cwd=WORK, capture_output=True, text=True, timeout=TIMEOUT)
    executable = os.path.join(WORK, ".hot", "main.exe" if WINDOWS else "main")
    if not os.path.exists(executable):
        sys.exit("hotfpc built no %s (exit %d):\n%s%s" % (executable, run.returncode, run.stdout, run.stderr))
    return executable


class Agent:
    """The program, started with the environment hotfpc gives it, and its agent's connection."""

    def __init__(self, executable):
        self.stop = os.path.join(WORK, "stop")
        if os.path.exists(self.stop):
            os.remove(self.stop)
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(TIMEOUT)
        env = dict(os.environ, HOT_PORT=str(listener.getsockname()[1]), HOT_TOKEN=TOKEN)
        self.process = subprocess.Popen((["wine"] if WINE else []) + [executable, agent_path(self.stop)], cwd=WORK, env=env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.connection = None
        try:
            try:
                self.connection, _ = listener.accept()
            finally:
                listener.close()
            self.connection.settimeout(TIMEOUT)
            self.pending = b""
            hello = self.line()
            if hello != "hello " + TOKEN:
                raise RuntimeError("the agent said %r instead of its hello" % hello)
        except BaseException:
            self.close()
            raise

    def line(self):
        while b"\n" not in self.pending:
            data = self.connection.recv(4096)
            if not data:
                raise RuntimeError("the agent closed its connection")
            self.pending += data
        line, self.pending = self.pending.split(b"\n", 1)
        return line.decode("utf-8", "replace").rstrip("\r")

    def command(self, *fields):
        """Sends a command; the agent's reply, its lines up to the "." that ends it."""
        self.connection.sendall(("\t".join(fields) + "\n").encode())
        reply = []
        while True:
            line = self.line()
            if line == ".":
                return reply
            reply.append(line)

    def close(self):
        """Ends the program through the file it waits for, or kills it when it doesn't end."""
        with open(self.stop, "w"):
            pass
        try:
            self.process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise
        finally:
            if self.connection is not None:
                self.connection.close()


def bad_object(agent):
    """A file that is no object file: the agent names the object files it reads, for the
    system it runs on."""
    path = os.path.join(WORK, "notanobject.o")
    with open(path, "w") as f:
        f.write("this is not an object file\n")
    reply = agent.command("load", agent_path(path))
    expected = "error %s is not an %s object" % (agent_path(path), object_format())
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
        agent.close()
    print("%d of %d cases as expected" % (len(CASES) - failed, len(CASES)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
