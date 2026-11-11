# demo

The program from the recording in the main README. `demo.pas` calls `Step` and `Frame` from
`scene.pas` every 0.4 s.

```sh
cd examples/demo
hotfpc demo.pas
```

While it runs, edit `scene.pas` and save. For example:

- change `'#'` to `'*'` in `Frame`;
- change `Inc(Score, 1)` to `Inc(Score, 2)` in `Step`;
- add a field to the line `Frame` returns.

Each save prints `[hot] vN swapped`, and the score carries on from where it was. Changing
`Score: Integer` to `Score: Int64` prints `restart needed` instead, because the running
program's variable can't change its size.

`tools/record-demo.py` makes the same three edits from a script and is what the recording
shows.
