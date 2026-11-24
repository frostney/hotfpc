# With lwpt

hotfpc doesn't need [lwpt](https://github.com/frostney/lwpt), but the two get along. lwpt
writes the unit paths of your package and its dependencies to `lwpt.cfg`, an fpc response
file. hotfpc passes that file to fpc and watches every directory listed in it, so edits to
a dependency's units are swapped in too.

## A run task

Add a task to `lwpt.toml` that starts your program under hotfpc:

```toml
[hot]
command = "hotfpc"
args = ["@lwpt.cfg", "source/greeter.pas"]
```

Then:

```sh
lwpt install     # writes lwpt.cfg
lwpt run hot
```

`lwpt build` still builds the program on its own, without hotfpc, for what you ship.

## The example

[`examples/lwpt`](../../examples/lwpt) is a complete package made with `lwpt init`, with
that task. Its program prints a line from `source/greeting.pas` every second. Run it, then
change the text in `source/greeting.pas` and save:

```text
tick 4: hello again, reloaded
[hot] v2 swapped: greeting: 1 functions redirected (1 with other code, 0 new), 0 variables and tables kept, 0 new, 144 bytes; 168.0 ms after the save was seen (settle 15.0, compile 134.0, interface check 9.0, load 10.0 of which in the program 8.885)
tick 5: hello from a swapped unit
```

That run used lwpt 0.8.1 on Linux x86-64 with fpc 3.2.4-rc2+1, on 2026-11-24.

## Things to know

- The task's `args` are hotfpc's arguments, so hotfpc's own options go there too:
  `args = ["--log", "hot.log", "@lwpt.cfg", "source/greeter.pas"]`.
- A dependency that lwpt adds later is a new directory in `lwpt.cfg`. hotfpc reads the
  response file when it starts, so run `lwpt run hot` again after `lwpt install`.
- `.hot/` is written next to the program's source, here `source/.hot/`. Add `.hot/` to the
  package's `.gitignore`.
