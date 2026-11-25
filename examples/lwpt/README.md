# hotfpc with lwpt

A minimal [lwpt](https://github.com/frostney/lwpt) package (made with `lwpt init`) with two
run tasks in `lwpt.toml` that start the program under hotfpc: `hot`, and `hot-windows`,
which adds the fpc options for a 64-bit Windows program.

```sh
cd examples/lwpt
lwpt install
lwpt run hot
```

On Windows, run `lwpt run hot-windows` instead. While it runs, change the text in
`source/greeting.pas` and save: the next tick prints the new text, and the count carries on.
[With lwpt](../../docs/guides/lwpt.md) explains the tasks and `lwpt.cfg`, and shows a run.
