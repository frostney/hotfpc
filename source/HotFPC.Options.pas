unit HotFPC.Options;
{ HotFPC.Options: the command line of hotfpc as an options object, and the names of the
  environment variables it reads. Parsing only reads the arguments; printing the version or the
  usage and exiting is the program's. }
{$mode delphi}{$H+}
{ fpc 3.3.1 before fpc-toolchain release 3.3.1+4 miscompiles loops at -O1 and above
  (docs/how-it-works.md, "A compiler bug"); fpc -iV cannot tell those builds from fixed ones. }
{$IF FPC_FULLVERSION >= 30301}{$optimization off}{$ENDIF}

interface

uses
  Classes;

const
  HotFPCVersion = '1.0.0';
  UsageText = 'usage: hotfpc [--version] [--fpc FPC] [--ppudump PPUDUMP] [--run LAUNCHER] [--quiet] '
    + '[--settle MS] [--log FILE] [fpc options] program.pas [-- program arguments]';
  { The environment variables the driver reads. }
  DebugVariable = 'HOT_DEBUG';
  TrustTimestampsVariable = 'HOT_TRUST_TIMESTAMPS';
  DefaultCompiler = 'fpc';
  DefaultSettleMilliseconds = 2;

type
  { What the command line asks hotfpc to do. }
  TCommandAction = (caRun, caShowVersion, caShowUsage);

  TOptions = class
  private
    FCompiler: string;
    FPPUDump: string;
    FLauncher: string;
    FLogPath: string;
    FSource: string;
    FQuiet: Boolean;
    FTargetWindows: Boolean;
    FWinePaths: Boolean;
    FSettleSeconds: Double;
    FCompilerOptions: TStringList;
    FProgramArguments: TStringList;
    procedure Finish(const AHostIsWindows: Boolean);
  public
    constructor Create;
    destructor Destroy; override;
    { AHostIsWindows decides whether a Windows target needs a launcher (wine) and whether
      paths are Wine paths; it is a parameter so that both systems can be tested anywhere. }
    function Parse(const AArguments: array of string; const AHostIsWindows: Boolean): TCommandAction;
    function ParseCommandLine: TCommandAction;
    { The compiler (--fpc); a name that is looked up on PATH or a path, perhaps of a wrapper. }
    property Compiler: string read FCompiler;
    { ppudump as named by --ppudump; empty when the compiler's neighbour is to be used. }
    property PPUDump: string read FPPUDump;
    { The program that starts the built program (--run), or the one a Windows target needs. }
    property Launcher: string read FLauncher;
    property LogPath: string read FLogPath;
    { The full path of the program's source file. }
    property Source: string read FSource;
    property Quiet: Boolean read FQuiet;
    property TargetWindows: Boolean read FTargetWindows;
    property WinePaths: Boolean read FWinePaths;
    property SettleSeconds: Double read FSettleSeconds;
    { Everything on the command line that is an option for fpc, in order. }
    property CompilerOptions: TStringList read FCompilerOptions;
    property ProgramArguments: TStringList read FProgramArguments;
  end;

implementation

uses
  SysUtils;

const
  SeparatorArgument = '--';
  MillisecondsPerSecond = 1000.0;
  WindowsTargetPrefix = '-T';
  WindowsTargetName = 'win';
  WineLauncher = 'wine';
  WineName = 'wine';

constructor TOptions.Create;
begin
  inherited Create;
  FCompiler := DefaultCompiler;
  FSettleSeconds := DefaultSettleMilliseconds / MillisecondsPerSecond;
  FCompilerOptions := TStringList.Create;
  FProgramArguments := TStringList.Create;
end;

destructor TOptions.Destroy;
begin
  FProgramArguments.Free;
  FCompilerOptions.Free;
  inherited Destroy;
end;

procedure TOptions.Finish(const AHostIsWindows: Boolean);
var
  I: Integer;
  Option: string;
begin
  for I := 0 to FCompilerOptions.Count - 1 do
  begin
    Option := FCompilerOptions[I];
    if (Copy(Option, 1, Length(WindowsTargetPrefix)) = WindowsTargetPrefix)
      and (LowerCase(Copy(Option, 3, Length(WindowsTargetName))) = WindowsTargetName) then
      FTargetWindows := True;
  end;
  if AHostIsWindows then
    FTargetWindows := True
  else if FTargetWindows and (FLauncher = '') then
    FLauncher := WineLauncher;
  FWinePaths := Pos(WineName, LowerCase(ExtractFileName(FLauncher))) > 0;
end;

function TOptions.Parse(const AArguments: array of string; const AHostIsWindows: Boolean): TCommandAction;
var
  Index: Integer;
  Argument: string;
  InProgramArguments: Boolean;
begin
  InProgramArguments := False;
  Index := 0;
  while Index <= High(AArguments) do
  begin
    Argument := AArguments[Index];
    { An option that takes a value only counts when a value follows. }
    if InProgramArguments then
      FProgramArguments.Add(Argument)
    else if Argument = SeparatorArgument then
      InProgramArguments := True
    else if (Argument = '--fpc') and (Index < High(AArguments)) then
    begin
      Inc(Index);
      FCompiler := AArguments[Index];
    end
    else if (Argument = '--ppudump') and (Index < High(AArguments)) then
    begin
      Inc(Index);
      FPPUDump := AArguments[Index];
    end
    else if (Argument = '--run') and (Index < High(AArguments)) then
    begin
      Inc(Index);
      FLauncher := AArguments[Index];
    end
    else if Argument = '--quiet' then
      FQuiet := True
    else if Argument = '--version' then
      Exit(caShowVersion)
    else if (Argument = '--settle') and (Index < High(AArguments)) then
    begin
      Inc(Index);
      FSettleSeconds := StrToFloatDef(AArguments[Index], DefaultSettleMilliseconds) / MillisecondsPerSecond;
    end
    else if (Argument = '--log') and (Index < High(AArguments)) then
    begin
      Inc(Index);
      FLogPath := AArguments[Index];
    end
    else if (Argument <> '') and (Argument[1] in ['-', '@']) then
      FCompilerOptions.Add(Argument)
    else
      FSource := ExpandFileName(Argument);
    Inc(Index);
  end;
  if FSource = '' then
    Exit(caShowUsage);
  Finish(AHostIsWindows);
  Result := caRun;
end;

function TOptions.ParseCommandLine: TCommandAction;
var
  Arguments: array of string;
  I: Integer;
begin
  SetLength(Arguments, ParamCount);
  for I := 1 to ParamCount do
    Arguments[I - 1] := ParamStr(I);
  Result := Parse(Arguments, {$ifdef windows}True{$else}False{$endif});
end;

end.
