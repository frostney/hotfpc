# Recording the demos

> **Audience: contributors.** How the two recordings in the README were made, and when to
> make them again.

Both recordings are real runs, not mock-ups, and the README describes what each shows. If
what a recording shows changes, such as the output of `examples/demo` or the `[hot]` lines
it contains, record it again, and change its description in the README to match.

## The terminal demo

`docs/demo.gif`, `docs/demo.mp4` and `docs/demo.cast` come from
[`scripts/record-demo.py`](../../scripts/record-demo.py). It copies `examples/demo` to a
work directory and opens a tmux session with three panes: vim on `scene.pas`, a shell that
runs `hotfpc --log hot.log demo.pas`, and hotfpc's timings from that log. Then it types
four edits into vim, one key at a time through `tmux send-keys`, and saves each with `:w`.
It needs tmux, vim, hotfpc and fpc on `PATH`; recording needs asciinema, agg and ffmpeg.

From the repository root:

```sh
asciinema rec --headless --window-size 130x45 --overwrite -c "python3 scripts/record-demo.py ../demo-work" docs/demo.cast
python3 scripts/record-demo.py --trim docs/demo.cast
agg --font-size 14 --theme monokai --fps-cap 20 --last-frame-duration 5 docs/demo.cast docs/demo.gif
ffmpeg -i docs/demo.gif -movflags +faststart -pix_fmt yuv420p \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -c:v libx264 -crf 22 docs/demo.mp4
```

`--trim` drops what tmux prints when the session ends. The script's docstring is the
reference for these steps.

## The raylib demo

`docs/raylib-demo.gif` and `docs/raylib-demo.mp4` were recorded on macOS arm64 with
[Knips](https://github.com/frostney/knips) on 14 Nov 2026. Knips captured the terminal
(Ghostty, with tmux and vim) and the game window separately; the two were put side by side
and trimmed to the four swaps. The run was `hotfpc -Fl/opt/homebrew/lib game.pas` in
`examples/raylib`, with Homebrew's fpc 3.2.2 and raylib, and hotfpc 1.0.0.

To record it again, run the example the same way, make the four edits the README describes
in `scene.pas`, and keep each `[hot]` line in view. Commit the GIF for the README and the
MP4, which the website's home page plays with the browser's controls, under the same names:
the README, the guides and the site pick up the new files as they are.
