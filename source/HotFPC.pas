program HotFPC;
{ hotfpc: hot reloading for Free Pascal programs, as a wrapper around fpc.

    hotfpc [--fpc FPC] [--ppudump PPUDUMP] [--run LAUNCHER] [--quiet] [--settle MS]
           [--log FILE] [fpc options] program.pas [-- program arguments]

  Builds the program with the given fpc and two additions: its symbols are kept (-Xs-) and
  the agent unit is loaded first (-FaHotFPC.Agent). Starts it, watches the sources, and on
  every save recompiles and hands the changed object files to the agent inside the
  program, which swaps the code in and keeps the program's state, or says why it needs a
  restart.

  The agent's source is part of this program. It is written out and compiled by the same
  fpc as the program, so hotfpc does not depend on the compiler's version. hotfpc needs
  fpc 3.2.2 or later.

  --fpc       the compiler (default: fpc)
  --ppudump   ppudump of the same compiler, for the check of interface layouts
              (default: next to the compiler; without one the check is off)
  --run       a program to start the built program with, such as wine (default: wine
              when the target is Windows and this is not)
  --settle    how long a save must stay unchanged before it is compiled (default 2 ms)
  --log       a copy of every line this program prints, with times

  The work is in the HotFPC.* units next to this file; this program reads the command line and
  hands it to the driver. }
{$mode delphi}{$H+}

uses
  {$ifdef unix}
  cthreads,
  {$endif}

  HotFPC.Driver,
  HotFPC.Options;

const
  ExitCodeUsage = 2;

function RunHotFPC: Integer;
var
  Options: TOptions;
begin
  Options := TOptions.Create;
  try
    case Options.ParseCommandLine of
      caShowVersion:
      begin
        WriteLn('hotfpc ', HotFPCVersion);
        Result := 0;
      end;
      caShowUsage:
      begin
        WriteLn(UsageText);
        Result := ExitCodeUsage;
      end;
    else
      Result := RunDriver(Options);
    end;
  finally
    Options.Free;
  end;
end;

begin
  Halt(RunHotFPC);
end.
