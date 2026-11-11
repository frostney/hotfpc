# Code style

hotfpc follows the native-nostalgia-stack code style. In short:

- **Delphi mode** through [`source/Shared.inc`](../source/Shared.inc), which every unit and
  program includes. Don't repeat compiler directives in a unit. The one exception is the
  agent: it turns overflow and range checks off after the include, and says why.
- **Files:** namespaced and flat in `source/`: `HotFPC.pas` is the program, and
  `HotFPC.<Name>.pas` are its units. Unit tests sit next to the unit they test as
  `HotFPC.<Name>.Test.pas`. End-to-end scenarios are in `tests/`.
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
- **Uses clauses:** one unit per line, alphabetised within the groups system, third-party
  and project (`HotFPC.*`). Dependencies go in the `implementation` uses clause where
  possible.
- **Comments:** say why, not what. A unit starts with a short comment on what it owns.

Two rules come from how hotfpc is used:

- **No dependencies beyond fpc.** Use only units that ship with fpc 3.2.2: the RTL and FCL
  (`Classes`, `SysUtils`, `Process`, `Sockets`, `fpjson`, ...). That keeps a copy of
  `source/` buildable on its own.
- **The agent is compiled by the user's compiler.** `HotFPC.Agent` must compile with every
  fpc from 3.2.2 on, for every supported target. It must not use `SysUtils` or other units
  that change how the user's program reports runtime errors: on Unix it uses `cthreads`,
  `baseunix` and `sockets`, and on Windows only `system` and its own declarations.
