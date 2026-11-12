# Code style

hotfpc follows the native-nostalgia-stack code style. In short:

- **Delphi mode:** the program and the agent unit start with `{$mode delphi}{$H+}`. Checks and
  optimisation come from the command line (docs/build-system.md), so other directives
  appear only where a file needs them, with the reason. The agent sets its own, because the
  user's compiler builds it with the user's options.
- **Files:** few, so a copy is easy to take. `source/HotFPC.pas` is the driver,
  `source/HotFPC.Agent.pas` the agent, and `source/HotFPC.AgentSource.inc` the agent's
  source generated for the driver. The driver's unit tests are in
  `source/HotFPC.Test.inc`, next to it. A new part of the driver is a new section, not a new
  unit. End-to-end scenarios are in `tests/`.
- **Sections:** a `// ------ name` ruler starts each section of a file, followed by a short
  comment on what the section owns.
- **Names:**
  - classes `T`, interfaces `I`, exceptions `E`, private fields `F`, parameters `A`;
  - PascalCase full words with no abbreviations and no numeric suffixes;
  - single letters only for loop counters;
  - standard initialisms in capitals (`TCPPort`, `ELFHeader`).
  - Declarations that mirror an external specification keep its spelling: relocation and
    section constants such as `R_X86_64_PC32` and `IMAGE_REL_AMD64_REL32`, and the C field
    names of records that mirror system structures. Imported C functions get Pascal names
    and keep the C name in `name '...'`.
- **Structure:** classes for things with behaviour and explicit responsibilities; records
  and procedures where there is none. `const` parameters unless the routine changes them.
  Named constants instead of magic literals.
- **Uses clauses:** one unit per line, alphabetised, with the platform units first in
  `{$ifdef}` blocks.
- **Comments:** say why, not what. A file starts with a short comment on what it is.

Two rules come from how hotfpc is used:

- **No dependencies beyond fpc.** Use only units that ship with fpc 3.2.2: the RTL and FCL
  (`Classes`, `SysUtils`, `Process`, `Sockets`, `fpjson`, ...). That keeps a copy of
  `source/` buildable on its own.
- **The agent is compiled by the user's compiler.** `HotFPC.Agent` must compile with every
  fpc from 3.2.2 on, for every supported target. It must not use `SysUtils` or other units
  that change how the user's program reports runtime errors: on Unix it uses `cthreads`,
  `baseunix` and `sockets`, and on Windows only `system` and its own declarations.
