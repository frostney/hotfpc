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

`docs/raylib-demo.gif` and `docs/raylib-demo.mp4` were recorded on macOS arm64 on
25 Nov 2026, with Homebrew's fpc 3.2.2 and raylib and hotfpc built from commit `0cbf4ea`
([pull request #24](https://github.com/frostney/hotfpc/pull/24)), which reports version 1.1.0.
The run was `hotfpc -Fl/opt/homebrew/lib game.pas` in a copy of `examples/raylib`, and the
five edits the README describes were typed into vim one key at a time through
`tmux send-keys`, five seconds apart. The terminal (tmux with vim and the shell, 84 by 30)
was recorded by asciinema and drawn by agg; the game window was recorded by
[Knips](https://github.com/frostney/knips). The two were put side by side with ffmpeg,
lined up by the frame where the background turns purple and the `[hot] v4` line, and cut
to the time the game was recorded.

So that nothing appeared on the screens in use, the game ran on a virtual display, which
only the recording used. The copy's `game.pas` opened its window hidden, without a frame,
and moved it there; `scene.pas` was as it is in the repository.

The virtual display was only a choice for the capture. To record it again, run
`examples/raylib` as it is, with its ordinary window on any display, make the five edits
the README describes in `scene.pas`, and keep each `[hot]` line in view. Commit the GIF for the README and the
MP4, which the website's home page plays with the browser's controls, under the same names:
the README, the guides and the site pick up the new files as they are.
