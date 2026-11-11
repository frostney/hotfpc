# hotfpc with lwpt

A minimal [lwpt](https://github.com/frostney/lwpt) package (made with `lwpt init`) with a
run task that starts the program under hotfpc:

```toml
[hot]
command = "hotfpc"
args = ["@lwpt.cfg", "source/greeter.pas"]
```

`lwpt.cfg` is the fpc response file that `lwpt install` writes, with the unit paths of the
package and its dependencies. hotfpc passes it to fpc and watches every directory listed in
it, so edits to a dependency's units are swapped in too.

```sh
cd examples/lwpt
lwpt install
lwpt run hot
```

While it runs, change the text in `source/greeting.pas` and save:

```text
[hot] v1: built in 157.0 ms, started in 270.0 ms, 2 units of its own, watching 2 files
tick 1: hello from lwpt
...
[hot] v2 swapped: greeting: 1 functions redirected (1 with other code, 0 new), ...
tick 9: hello again, reloaded
```

`lwpt build` still builds the program on its own, without hotfpc.
