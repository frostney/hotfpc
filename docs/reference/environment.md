# Environment variables

hotfpc needs none of these. Two help with diagnosing hotfpc itself, two connect the
program to hotfpc, and three exist for hotfpc's own tests.

## Read by hotfpc

| Variable | Effect |
| --- | --- |
| `HOT_DEBUG` | Any value: hotfpc also prints `[hot debug]` lines, which say which files changed, which unit files it deleted so that fpc compiles them again, and how long a compile to assembler took. They aren't part of the stable output. |
| `HOT_TRUST_TIMESTAMPS` | Any value: hotfpc leaves it to fpc to see which units changed. Without it, hotfpc deletes the unit file of every changed unit before the compile: fpc compares file times to the second, so it can miss an edit saved within the same second as the compile before it. A changed include file makes every unit compile again. |

## Set by hotfpc for the program

| Variable | Effect |
| --- | --- |
| `HOT_PORT` | The TCP port on 127.0.0.1 where hotfpc waits for the agent. The agent connects to it when the program starts. Without it, the agent does nothing and the program runs as if it weren't there. |
| `HOT_TOKEN` | A token the agent sends when it connects, so that hotfpc talks only to the program it started. |

The agent removes both from the program's environment when it starts, so a program that
the program starts doesn't connect to hotfpc too.

## Read by the agent, for testing

| Variable | Effect |
| --- | --- |
| `HOT_NOSUSPEND` | Any value: the agent doesn't stop the program's other threads during a swap, which is then not safe while they run. |
| `HOT_TEST_DATA_WRITE` | `1`, or any value but an empty one: just before it stops the program's threads to write a swap, the agent adds 1 to the first byte of each variable it is about to give a new initial value, as a thread of the program could write it while the swap loads. The swap then keeps the value the variable has. The `initrace` scenario sets it. |
| `HOT_TEST_BLOCK` | A number of MiB: on Linux and macOS, the agent maps a block of that size just above the program before it looks for memory for new code, to test the case where something else took that space. |

## Read by the scenario tests

`HOT_DRIVER`, `HOT_DRIVER_OPTS` and `HOT_TRANSCRIPT` choose the hotfpc the scenarios run,
add options to it and save the transcript; they are described in
[Testing](../internals/testing.md).
