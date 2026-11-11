{ The compiler settings of every unit and program of hotfpc. The driver writes this file next
  to the agent's source, so the agent is compiled with the same settings by the compiler of
  the program it is loaded into. }
{$mode delphi}{$H+}
{ Typed constants are read-only; Delphi mode would make them writable. }
{$J-}
{$IFDEF PRODUCTION}
  {$overflowchecks off}
  {$rangechecks off}
  {$S-}
  {$OBJECTCHECKS OFF}
  {$C-}
{$ELSE}
  {$overflowchecks on}
  {$rangechecks on}
  {$S+}
  {$OBJECTCHECKS ON}
  {$C+}
{$ENDIF}
{ fpc 3.3.1 from fpc-toolchain before release 3.3.1+4 gave a loop counter and a temporary
  string the same register on x86-64 at -O1 and above (docs/how-it-works.md, "A compiler
  bug"). fpc -iV cannot tell those builds from fixed ones, so every 3.3.1 compiles hotfpc
  without optimisation. Neither the driver nor the agent needs the speed. }
{$IF FPC_FULLVERSION >= 30301}
  {$optimization off}
{$ENDIF}
