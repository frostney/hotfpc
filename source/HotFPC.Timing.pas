unit HotFPC.Timing;
{ HotFPC.Timing: the clock behind hotfpc's measurements and how a duration prints in a [hot]
  line. }
{$mode delphi}{$H+}
{ fpc 3.3.1 before fpc-toolchain release 3.3.1+4 miscompiles loops at -O1 and above
  (docs/how-it-works.md, "A compiler bug"); fpc -iV cannot tell those builds from fixed ones. }
{$IF FPC_FULLVERSION >= 30301}{$optimization off}{$ENDIF}

interface

function NowSeconds: Double;
function SecondsSince(const AStart: TDateTime): Double;
function FormatMilliseconds(const ASeconds: Double): string;
function FormatSeconds(const ASeconds: Double): string;

implementation

uses
  SysUtils;

const
  SecondsPerDay = 86400.0;
  MillisecondsPerSecond = 1000.0;
  DurationFormat = '0.0';

function NowSeconds: Double;
begin
  Result := Now * SecondsPerDay;
end;

function SecondsSince(const AStart: TDateTime): Double;
begin
  Result := (Now - AStart) * SecondsPerDay;
end;

function FormatMilliseconds(const ASeconds: Double): string;
begin
  Result := FormatFloat(DurationFormat, ASeconds * MillisecondsPerSecond);
end;

function FormatSeconds(const ASeconds: Double): string;
begin
  Result := FormatFloat(DurationFormat, ASeconds);
end;

end.
