# Quick start

Install fpc and hotfpc, run the demo program under hotfpc, and make four edits while it
runs: three that swap in with the score still counting, and one that needs a restart.

This page is for people using hotfpc. Changing hotfpc itself is covered in
[CONTRIBUTING.md](../../CONTRIBUTING.md).

## Install Free Pascal

hotfpc needs Free Pascal 3.2.2 or later. It also uses the `ppudump` that comes with fpc.

- **macOS:** `brew install fpc`.
- **Debian and Ubuntu:** `sudo apt-get install fpc`.
- **Windows:** the win32 and win64 installer from
  [freepascal.org](https://www.freepascal.org/download.html).

`fpc -iV` prints the version.

## Install hotfpc

**With Homebrew**, on macOS on Apple silicon and Linux on x86-64, fpc and hotfpc together:

```sh
brew install fpc frostney/tap/hotfpc
```

**From a release.** The [releases](https://github.com/frostney/hotfpc/releases) have an
archive for each system and a checksum file. On Linux x86-64, download both, check the
archive, and copy `hotfpc` into a directory on your `PATH`, here `~/.local/bin`:

```sh
curl -LO https://github.com/frostney/hotfpc/releases/download/1.1.0/hotfpc-1.1.0-linux-x64.tar.gz
curl -LO https://github.com/frostney/hotfpc/releases/download/1.1.0/hotfpc-1.1.0-checksums.txt
grep linux-x64 hotfpc-1.1.0-checksums.txt | sha256sum -c    # hotfpc-1.1.0-linux-x64.tar.gz: OK
tar -xzf hotfpc-1.1.0-linux-x64.tar.gz
mkdir -p ~/.local/bin
cp hotfpc-1.1.0-linux-x64/hotfpc ~/.local/bin/
export PATH="$HOME/.local/bin:$PATH"    # this shell only; add it to your shell's profile
```

On macOS, take `macos-arm64` instead of `linux-x64`, and `shasum -a 256 -c` instead of
`sha256sum -c`. On Windows, download `hotfpc-1.1.0-windows-x64.zip`, compare the hash that
PowerShell's `Get-FileHash hotfpc-1.1.0-windows-x64.zip` prints with the archive's line in
the checksum file, unpack it, and put the folder with `hotfpc.exe` on your `PATH`.
[Platforms](../reference/platforms.md) lists which archive each system has.

**From source.** hotfpc is plain Pascal and needs nothing beyond what ships with fpc. Build
it in a clone and put `build/` on your `PATH`:

```sh
git clone https://github.com/frostney/hotfpc
cd hotfpc
./build.sh hotfpc     # build/hotfpc
export PATH="$PWD/build:$PATH"
```

On Windows, `build.bat hotfpc` builds `build\hotfpc.exe`. To build it in your own tree
without the scripts, see [Building hotfpc](../internals/build-system.md).

`hotfpc --version` prints the version.

## Run the demo

[`examples/demo`](../../examples/demo) is a program that draws a score every 0.15 s. The
score and the way it's drawn live in `scene.pas`. In your clone, `cd examples/demo`. With
Homebrew or a release, download the source of the same release and go to its demo:

```sh
curl -L https://github.com/frostney/hotfpc/archive/refs/tags/1.1.0.tar.gz | tar -xz
cd hotfpc-1.1.0/examples/demo
```

On Windows, the release's "Source code (zip)" has the same files. Then start it:

```sh
hotfpc demo.pas
```

hotfpc builds the program, starts it and prints one line of its own:

```text
[hot] v1: built in 228.0 ms, started in 5.0 ms, 2 units of its own, watching 2 files
score    2  ###
score    3  ####
```

## Make it change

Leave it running, open `scene.pas` in your editor, and make these edits one at a time,
saving after each:

1. `Glyph = '#'` to `Glyph = '*'`. The bars are drawn with `*` from the next frame on, and
   the score carries on:

   ```text
   score   19  ####################
   [hot] v2 swapped: scene: 2 functions redirected (1 with other code, 0 new), 1 variables and tables kept, 0 new, 432 bytes; 193.0 ms after the save was seen (settle 4.0, compile 138.0, interface check 30.0, load 19.0 of which in the program 17.867)
   score   20  *
   ```

2. `Inc(Score, 1)` to `Inc(Score, 2)`. The score counts in twos from where it was:

   ```text
   [hot] v3 swapped: scene: 2 functions redirected (1 with other code, 0 new), 1 variables and tables kept, 0 new, 432 bytes; 160.0 ms after the save was seen (settle 4.0, compile 147.0, interface check 6.0, load 3.0 of which in the program 1.405)
   score   40  *
   score   42  ***
   ```

3. `#27'[32m'` to `#27'[33m'`. The score turns from green to yellow:

   ```text
   [hot] v4 swapped: scene: 2 functions redirected (1 with other code, 0 new), 1 variables and tables kept, 0 new, 432 bytes; 119.0 ms after the save was seen (settle 5.0, compile 106.0, interface check 6.0, load 2.0 of which in the program 0.682)
   ```

4. `Score: Integer` to `Score: Int64`. The running program's `Score` is four bytes, and the
   new code expects eight. hotfpc says which declaration is in the way, links the program
   again and starts it over, so the score starts again from zero:

   ```text
   [hot] restart needed: scene.Score: the declaration changed its layout or type (not applied; compile 118.0 ms)
   score  120  *
   score    2  ***
   [hot] v5 restarted: the program starts over; 387.0 ms after the save was seen (link 243.0, stop 2.0, start 6.0)
   ```

Press Ctrl-C to stop hotfpc and the program. The output above is from a run on Linux
x86-64 with fpc 3.2.4-rc2+1 on 2026-11-24; the times vary with the machine. The
[README](../../README.md) shows the same four edits recorded on macOS.

Change something that doesn't compile, and you get fpc's errors as `[hot] error:` lines
while the program keeps running the code it had. [Output](../reference/output.md) explains
every line.

## Next steps

- [Your own program](your-program.md): fpc options, program arguments, the files hotfpc
  watches, and where to put code you want to change.
- [What a save does](saves-and-restarts.md): which edits swap, which restart, and what
  happens to the program's state.
- [With lwpt](lwpt.md), [with raylib](raylib.md), and
  [Windows programs](windows.md).
