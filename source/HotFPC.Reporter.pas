unit HotFPC.Reporter;
{ HotFPC.Reporter: the [hot] lines on standard output and their optional copy, with times, in
  the --log file. }
{$mode delphi}{$H+}
{ fpc 3.3.1 before fpc-toolchain release 3.3.1+4 miscompiles loops at -O1 and above
  (docs/how-it-works.md, "A compiler bug"); fpc -iV cannot tell those builds from fixed ones. }
{$IF FPC_FULLVERSION >= 30301}{$optimization off}{$ENDIF}

interface

type
  TReporter = class
  private
    FLog: TextFile;
    FLogging: Boolean;
  public
    { ALogPath is empty when there is no log file. }
    constructor Create(const ALogPath: string);
    destructor Destroy; override;
    procedure Say(const AMessage: string);
  end;

implementation

uses
  SysUtils,

  HotFPC.Timing;

const
  LinePrefix = '[hot] ';
  LogTimeFormat = '0.000000';

constructor TReporter.Create(const ALogPath: string);
begin
  inherited Create;
  if ALogPath <> '' then
  begin
    AssignFile(FLog, ALogPath);
    Rewrite(FLog);
    FLogging := True;
  end;
end;

destructor TReporter.Destroy;
begin
  if FLogging then
    CloseFile(FLog);
  inherited Destroy;
end;

procedure TReporter.Say(const AMessage: string);
var
  Line: string;
begin
  Line := LinePrefix + AMessage;
  WriteLn(Line);
  Flush(Output);
  if FLogging then
  begin
    WriteLn(FLog, FormatFloat(LogTimeFormat, NowSeconds), ' ', Line);
    Flush(FLog);
  end;
end;

end.
