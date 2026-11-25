# Windows programs

hotfpc hot-reloads 64-bit Windows programs in two ways: with `hotfpc.exe` on Windows, and
from Linux or macOS with the program cross-compiled and run under Wine. The agent is the
same in both; it is compiled for the target, like the program.

## On Windows

Install fpc with the win32 and win64 installer from
[freepascal.org](https://www.freepascal.org/download.html), and get `hotfpc.exe` from the
`windows-x64` release archive or build it with `build.bat hotfpc -- -Twin64 -Px86_64`. The
installer's `fpc` builds 32-bit programs by default, which the agent doesn't support, so ask
for a 64-bit one, for hotfpc and for your program:

```bat
hotfpc -Twin64 -Px86_64 demo.pas
```

That is what CI runs on Windows with fpc 3.2.2: the unit tests and all scenarios, with
`hotfpc.exe`, on pull requests and on pushes to main.

## From Linux or macOS, under Wine

With an fpc that has the win64 cross compiler and units, give hotfpc the target:

```sh
hotfpc -Twin64 -Px86_64 demo.pas
```

hotfpc builds a Windows program and starts it with `wine`, which it uses by default when
the target is Windows and hotfpc itself isn't on Windows. To start it with something else,
name it with `--run`:

```sh
hotfpc --run /opt/wine-staging/bin/wine -Twin64 -Px86_64 demo.pas
```

Use Wine 6.8 or later: an older Wine lacks a call the agent needs to stop the program's
threads, and every swap there fails with `the threads of the program could not be listed`
([how it works](../internals/how-it-works.md#per-system)).

When the launcher's name contains `wine`, hotfpc gives the agent Windows paths (`Z:\...`).
The agent talks to hotfpc over TCP on 127.0.0.1, which works the same between a program
under Wine and hotfpc outside it.

A restart stops the launcher. A launcher that starts the program as its child has to end
it too; otherwise the old program keeps running, and hotfpc says so:

```text
[hot] the stopped program's connection is still open: a launcher (--run) that starts the program as its child has to end it too, or the old program keeps running
```

`hotfpc.exe` with the Windows fpc can also both run under Wine; that was tested with fpc
3.3.1 ([platforms](../reference/platforms.md#programs-hotfpc-hot-reloads)).

## What differs for a Windows program

- **A runtime routine the program never called needs a restart.** fpc's Windows linker
  leaves out code the program doesn't reach, so new code that calls such a routine, such
  as `SysUtils.Supports`, can't find it in the program. On Linux and macOS the whole unit
  is linked, and the same edit is swapped. In the scenarios, that makes two edits restart
  on Windows that swap elsewhere ([edits](edits.md)).
- **A save can compile twice.** Windows object files don't state the sizes of variables,
  and fpc pads a variable with an initial value, and a typed constant, to 16 bytes. So when
  a changed unit has one, hotfpc also compiles the program to assembler, into `.hot/asm/`,
  and compares the sizes there. That compile costs about as much as the first. If it
  fails for a save, at the start or when the program started over, a save that needs the
  sizes needs a restart: a variable it can't see may have grown. At the start hotfpc says
  so, and the check stays on until a restart gives it the sizes. So does a save that changes a variable the object
  file has and the assembler gives no size for, and one whose files' times can't show
  whether another save came and was put back during its compiles, as on a file system that
  keeps whole seconds.
- **A restart waits for the file.** Windows keeps a program's file locked for a moment after
  the program ends. hotfpc links the new program into `.hot/next/` and moves it into place,
  trying for up to 5 s.
- **hotfpc links with `-Xm`.** The agent reads the linker's map, `.hot/<program>.map`, to
  find the variables fpc 3.2 gives no symbol.

[How it works](../internals/how-it-works.md#per-system) has the details for each system.
