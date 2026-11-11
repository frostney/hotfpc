# demo

The program from the recording in the main README. Every 0.15 s, `demo.pas` calls `Step`
and `Frame` from `scene.pas`.

```sh
cd examples/demo
hotfpc demo.pas
```

While it runs, edit `scene.pas` and save. For example:

- set `Glyph` to `'*'`;
- change `Inc(Score, 1)` to `Inc(Score, 2)`;
- set `Color` to `#27'[33m'` (yellow).

Each save prints `[hot] vN swapped`, and the score carries on from where it was. Changing
`Score: Integer` to `Score: Int64` prints `restart needed` instead, because a running
program's variable can't change its size.

[`tools/record-demo.py`](../../tools/record-demo.py) makes the same edits in vim inside
tmux, which is what the recording shows.
