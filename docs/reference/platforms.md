# Platforms

What hotfpc runs on, which programs it hot-reloads, and with which compilers it was tested.
This page is the record; the README and the guides link here.

## Getting hotfpc

| hotfpc runs on | Release archive | Homebrew | From source |
| --- | --- | --- | --- |
| macOS arm64 | `macos-arm64` | ✓ | `./build.sh hotfpc` |
| macOS x86-64 | `macos-x64` | ✓, without fpc | `./build.sh hotfpc` |
| Linux x86-64 | `linux-x64` | ✓ | `./build.sh hotfpc` |
| Linux arm64 | `linux-arm64` | ✓ | `./build.sh hotfpc` |
| Windows x86-64 | `windows-x64` | | `build.bat hotfpc -- -Twin64 -Px86_64` |

The [releases](https://github.com/frostney/hotfpc/releases) have an archive per system
(`hotfpc-<version>-<system>.tar.gz`, `.zip` for Windows) and a checksum file. From 1.2.0
on they have all five; 1.1.0 has `macos-arm64`, `linux-x64` and `windows-x64`.

The Homebrew formula, `frostney/tap/hotfpc`, installs the release binary for macOS and
Linux, on arm64 and x86-64. It doesn't install fpc. On macOS on Apple silicon and on
Linux, install both:

```sh
brew install fpc frostney/tap/hotfpc
```

Homebrew has no prebuilt fpc for Intel Macs, so there fpc comes from the
[freepascal.org](https://www.freepascal.org/download.html) installer, and Homebrew installs
only hotfpc:

```sh
brew install frostney/tap/hotfpc
```

## Compilers

hotfpc needs Free Pascal 3.2.2 or later, and checks the version when it starts. It builds
its agent with the same fpc as the program, so one hotfpc works with every fpc from 3.2.2
on. fpc 3.2.2 is the official Free Pascal release. fpc 3.2.4-rc and 3.3.1 below are
[fpc-toolchain](https://github.com/frostney/fpc-toolchain)'s builds.

To build hotfpc itself, use fpc 3.2.2 or fpc-toolchain's 3.3.1+4 or later. Its earlier
3.3.1 builds miscompile hotfpc when optimising
([how it works](../internals/how-it-works.md#a-compiler-bug)).

## Programs hotfpc hot-reloads

hotfpc runs on macOS, Linux and Windows, and hot-reloads programs built for:

| Program built for | Tested | fpc 3.2.2 | fpc 3.2.4-rc | fpc 3.3.1 |
| --- | --- | --- | --- | --- |
| macOS arm64 | natively | ✓ | ✓ | ✓ |
| macOS x86-64 | natively, on GitHub's Intel macOS runner | ✓ | not tried | ✓ |
| Linux x86-64 | natively | ✓ | ✓ | ✓ |
| Linux arm64 | natively: GitHub's arm64 runner (3.2.2) and an Ubuntu 24.04 arm64 VM | ✓ | ✓ | ✓ |
| Windows x86-64 | natively, `hotfpc.exe` on GitHub's Windows runner | ✓ | not tried | not tried |
| Windows x86-64 | under Wine 9.0, hotfpc on Linux | ✓ | ✓ | ✓ |
| Windows x86-64 | under Wine 9.0, `hotfpc.exe` and the Windows fpc under Wine too | not tried | not tried | ✓ |

Each ✓ means all 19 [scenarios](../internals/testing.md#the-scenarios) gave the expected
result with hotfpc 1.0.0. For Linux arm64 it means all 25 with hotfpc after 1.1.0: hotfpc
1.1.0 itself loses the values of variables in a unit's implementation section on Linux
arm64 (see the [changelog](../../CHANGELOG.md)). For macOS x86-64 it means all 27 with fpc
3.2.2 and all 25 with fpc 3.3.1, the cases there were when it ran. An x86-64 program under
Rosetta 2 on an Apple silicon Mac hasn't been tried.
On Windows, three scenarios expect a restart where the other systems swap
([Windows programs](../guides/windows.md)), and `shortentry` swaps there and on arm64, where
x86-64 macOS and Linux restart ([limits](limits.md)). `shortcall`, `sighandler` and
`sigmasked` swap on arm64 and restart on every x86-64 system.

With fpc 3.2.2 and 3.3.1, a stress test also passed on all three systems (Windows under
Wine): 20,000 reloads of one unit while two threads kept calling it, with no stale or wrong
results. On macOS and Linux, four edits to lwpt's formatter units (6,600 lines) all swapped
in. On macOS x86-64, with fpc 3.2.2 on GitHub's Intel runner, 247 swaps of one unit
while two threads called it 8.26 billion times gave no wrong results.

Not supported: programs for 32-bit targets, and hardened or notarised
macOS programs ([limits](limits.md)).

## What CI runs

On pull requests and on pushes to main, CI builds hotfpc with fpc 3.2.2, runs the unit
tests, all scenarios and the check of the agent on Linux x86-64, Linux arm64, macOS arm64 and macOS
x86-64, and on
Windows x86-64 with `hotfpc.exe` ([tooling](../internals/tooling.md#ci)). Release 1.2.0's
commit passed on all five in
[run 45824842999](https://github.com/frostney/hotfpc/actions/runs/45824842999)
(2026-11-26). On 2026-11-26, all 44 scenarios passed at this version of the repository on
Linux x86-64 with fpc 3.2.2.

## Timings

A swap usually takes 40 to 150 ms from save to running, and most of that is fpc compiling
the unit. A unit with about 500 functions takes 0.5 to 1.1 s. A restart adds the link and
the program's start: 360 to 500 ms in the scenarios on Linux x86-64. For a Windows program,
a save that changes a unit with a variable with an initial value or a typed constant
compiles twice: the second compile, to assembler, shows their sizes, which Windows object
files don't.
