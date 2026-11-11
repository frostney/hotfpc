unit HotFPC.Compiler;
{ HotFPC.Compiler: everything hotfpc asks of the user's fpc. It checks the compiler's version,
  builds the agent unit, compiles the program (with linking or without), reads the errors out of
  the output, makes fpc recompile the units whose source changed, and removes the leftovers
  fpc makes in its working directory. fpc runs in the current directory, as the user would run
  it: relative paths in options and response files, and a fpc.cfg there, mean what they mean to
  fpc. }
{$mode delphi}{$H+}
{ fpc 3.3.1 before fpc-toolchain release 3.3.1+4 miscompiles loops at -O1 and above
  (docs/how-it-works.md, "A compiler bug"); fpc -iV cannot tell those builds from fixed ones. }
{$IF FPC_FULLVERSION >= 30301}{$optimization off}{$ENDIF}
{$modeswitch advancedrecords}

interface

uses
  Classes,

  HotFPC.Options,
  HotFPC.Workspace;

type
  TCompilerVersion = record
    Major: Integer;
    Minor: Integer;
    Patch: Integer;
    { The version at the start of the text ("3.2.2", also "3.3.1+3" or "3.2.2-r1"); a missing
      patch is 0. False when the text does not start like a version. }
    class function TryParse(const AText: string; out AVersion: TCompilerVersion): Boolean; static;
    { Negative, zero or positive as this version is before, the same as or after the other. }
    function CompareTo(const AOther: TCompilerVersion): Integer;
    function ToString: string;
  end;

  TCompiler = class
  private
    FCompiler: string;
    FDirectory: string;
    FOptions: TStrings;
    FTargetWindows: Boolean;
    FWorkspace: TWorkspace;
    function Execute(const AArguments: array of string; out AOutput: string): Integer;
  public
    constructor Create(const AOptions: TOptions; const AWorkspace: TWorkspace);
    { Runs "<compiler> -iV". False, with the one-line reason in AProblem, when the compiler
      cannot be run, its version cannot be read, or it is older than MinimumVersion. }
    function VerifyVersion(out AProblem: string): Boolean;
    { Writes out the agent's source and compiles it once into the workspace's agent
      directory. fpc 3.3.1's -Fa cannot load a unit it would recompile, so the source is not on
      the program's search path. False when it did not compile; AOutput is then fpc's output. }
    function BuildAgent(out AOutput: string): Boolean;
    { Compiles the program, linking it when ALink; without linking (-Cn) the object files
      are all that is made. AErrors holds the diagnostics that name a place in a source file,
      or the closing lines when there are none; the caller frees the list. }
    function Compile(const ALink: Boolean; out AErrors: TStringList; out ASeconds: Double): Boolean;
    { Makes the compiler recompile the units whose source changed, whatever it thinks. Its own
      check compares times of one-second granularity: an edit saved in the same second as its
      previous compile of the unit goes unnoticed. The driver knows from the content which
      files changed, so it removes the compiler's record of those units from its own unit
      directory. HOT_TRUST_TIMESTAMPS=1 turns this off. }
    procedure ForgetUnits(const AChangedFiles: TStrings);
    { The arguments of the program's compile. }
    function CompileArguments(const ALink: Boolean): TStringList;
    { The options the agent's compile shares with the program's: the ones that decide the
      target, how code is generated and where units are. }
    class function AgentOptions(const AOptions: TStrings): TStringList;
    { What fpc leaves in its working directory when it does not link or links through a script. }
    class function IsLeftover(const AName: string): Boolean;
    class function FindLeftovers(const ADirectory: string): TStringList;
    { Removes the leftovers in the directory that are not in ABefore. }
    class procedure RemoveNewLeftovers(const ADirectory: string; const ABefore: TStrings);
    { A diagnostic that names a place in a source file: "name(12) " or "name(12,5) ". }
    class function IsPlaced(const ALine: string): Boolean;
    class function ExtractErrors(const AOutput: string): TStringList;
    { Whether a changed file means the compiler's record of a unit has to go: an include file
      can be part of any unit, any other file is the unit of that name. }
    class function AffectsUnit(const AChangedFile, AUnitRecord: string): Boolean;
    { What VerifyVersion decides from the output of -iV. }
    class function JudgeVersion(const ACompiler, AOutput: string; out AProblem: string): Boolean;
  end;

const
  MinimumVersion: TCompilerVersion = (Major: 3; Minor: 2; Patch: 2);

implementation

uses
  Process,
  SysUtils,

  HotFPC.Timing;

{$I HotFPC.AgentSource.inc}

const
  AgentSourceFileName = 'HotFPC.Agent.pas';
  AgentRecordFileName = 'hotfpc.agent.ppu';
  AgentUnitOption = '-FaHotFPC.Agent';
  KeepSymbolsOption = '-Xs-';
  NoLinkOption = '-Cn';
  LinkMapOption = '-Xm';
  VersionOption = '-iV';
  UnitDirectoryOption = '-FU';
  UnitPathOption = '-Fu';
  OutputOption = '-o';
  RecordExtension = '.ppu';
  IncludeExtension = '.inc';
  LinkScriptPrefix = 'link';
  LinkScriptExtension = '.res';
  SymbolOrderPrefix = 'symbol_order';
  UnixLinkScriptName = 'ppas.sh';
  WindowsLinkScriptName = 'ppas.bat';
  ErrorMarker = ' Error: ';
  FatalMarker = ' Fatal: ';
  FatalPrefix = 'Fatal:';
  ErrorPrefix = 'Error:';
  { Options that decide the target, how code is generated and where units are: the agent is
    built with them too. }
  AgentOptionPrefixes: array[0..13] of string = ('-T', '-P', '-Cp', '-Cf', '-Ca', '-XP', '-Fl', '-Fu',
    '-k', '-XR', '-Xd', '-n', '@', '-V');
  RequirementText = ' or later';

function StartsWith(const AText, APrefix: string): Boolean; inline;
begin
  Result := Copy(AText, 1, Length(APrefix)) = APrefix;
end;

function StartsWithAny(const AText: string; const APrefixes: array of string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(APrefixes) do
    if StartsWith(AText, APrefixes[I]) then
      Exit(True);
  Result := False;
end;

function ReadNumber(const AText: string; var APosition: Integer; out AValue: Integer): Boolean;
var
  Start: Integer;
begin
  Start := APosition;
  while (APosition <= Length(AText)) and (AText[APosition] in ['0'..'9']) do
    Inc(APosition);
  Result := APosition > Start;
  if Result then
    AValue := StrToIntDef(Copy(AText, Start, APosition - Start), MaxInt)
  else
    AValue := 0;
end;

class function TCompilerVersion.TryParse(const AText: string; out AVersion: TCompilerVersion): Boolean;
var
  Text: string;
  Position: Integer;
begin
  AVersion.Major := 0;
  AVersion.Minor := 0;
  AVersion.Patch := 0;
  Text := Trim(AText);
  Position := 1;
  Result := False;
  if not ReadNumber(Text, Position, AVersion.Major) then
    Exit;
  if (Position > Length(Text)) or (Text[Position] <> '.') then
    Exit;
  Inc(Position);
  if not ReadNumber(Text, Position, AVersion.Minor) then
    Exit;
  if (Position < Length(Text)) and (Text[Position] = '.') and (Text[Position + 1] in ['0'..'9']) then
  begin
    Inc(Position);
    ReadNumber(Text, Position, AVersion.Patch);
  end;
  Result := True;
end;

function TCompilerVersion.CompareTo(const AOther: TCompilerVersion): Integer;
begin
  if Major <> AOther.Major then
    Result := Major - AOther.Major
  else if Minor <> AOther.Minor then
    Result := Minor - AOther.Minor
  else
    Result := Patch - AOther.Patch;
end;

function TCompilerVersion.ToString: string;
begin
  Result := IntToStr(Major) + '.' + IntToStr(Minor) + '.' + IntToStr(Patch);
end;

constructor TCompiler.Create(const AOptions: TOptions; const AWorkspace: TWorkspace);
begin
  inherited Create;
  FCompiler := AOptions.Compiler;
  FOptions := AOptions.CompilerOptions;
  FTargetWindows := AOptions.TargetWindows;
  FWorkspace := AWorkspace;
  FDirectory := GetCurrentDir;
end;

class function TCompiler.IsLeftover(const AName: string): Boolean;
begin
  Result := (StartsWith(AName, LinkScriptPrefix) and (ExtractFileExt(AName) = LinkScriptExtension))
    or StartsWith(AName, SymbolOrderPrefix) or (AName = UnixLinkScriptName) or (AName = WindowsLinkScriptName);
end;

class function TCompiler.FindLeftovers(const ADirectory: string): TStringList;
var
  Search: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*', faAnyFile, Search) = 0 then
  begin
    repeat
      if IsLeftover(Search.Name) then
        Result.Add(Search.Name);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
end;

class procedure TCompiler.RemoveNewLeftovers(const ADirectory: string; const ABefore: TStrings);
var
  After: TStringList;
  I: Integer;
begin
  After := FindLeftovers(ADirectory);
  try
    for I := 0 to After.Count - 1 do
      if ABefore.IndexOf(After[I]) < 0 then
        DeleteFile(IncludeTrailingPathDelimiter(ADirectory) + After[I]);
  finally
    After.Free;
  end;
end;

function TCompiler.Execute(const AArguments: array of string; out AOutput: string): Integer;
var
  Before: TStringList;
begin
  Before := FindLeftovers(FDirectory);
  try
    AOutput := '';
    Result := 0;
    RunCommandInDir(FDirectory, FCompiler, AArguments, AOutput, Result, [poStderrToOutPut]);
    RemoveNewLeftovers(FDirectory, Before);
  finally
    Before.Free;
  end;
end;

class function TCompiler.JudgeVersion(const ACompiler, AOutput: string; out AProblem: string): Boolean;
var
  Lines: TStringList;
  Version: TCompilerVersion;
  I: Integer;
  Printed: string;
begin
  AProblem := '';
  Lines := TStringList.Create;
  try
    Lines.Text := AOutput;
    { a wrapper script may print other lines too; the version is the first line that is one }
    for I := 0 to Lines.Count - 1 do
      if TCompilerVersion.TryParse(Lines[I], Version) then
      begin
        Result := Version.CompareTo(MinimumVersion) >= 0;
        if not Result then
          AProblem := ACompiler + ' is version ' + Version.ToString + '; hotfpc requires '
            + MinimumVersion.ToString + RequirementText;
        Exit;
      end;
    Printed := 'nothing';
    for I := 0 to Lines.Count - 1 do
      if Trim(Lines[I]) <> '' then
      begin
        Printed := '"' + Trim(Lines[I]) + '"';
        Break;
      end;
    AProblem := 'cannot tell which version ' + ACompiler + ' is (' + VersionOption + ' printed ' + Printed
      + '); hotfpc requires ' + MinimumVersion.ToString + RequirementText;
    Result := False;
  finally
    Lines.Free;
  end;
end;

function TCompiler.VerifyVersion(out AProblem: string): Boolean;
var
  Output: string;
  Status: Integer;
begin
  Output := '';
  try
    if RunCommandInDir(FDirectory, FCompiler, [VersionOption], Output, Status, [poStderrToOutPut]) <> 0 then
    begin
      AProblem := 'cannot run ' + FCompiler + '; hotfpc requires ' + MinimumVersion.ToString + RequirementText;
      Exit(False);
    end;
  except
    on Failure: Exception do
    begin
      AProblem := 'cannot run ' + FCompiler + ' (' + Failure.Message + '); hotfpc requires '
        + MinimumVersion.ToString + RequirementText;
      Exit(False);
    end;
  end;
  Result := JudgeVersion(FCompiler, Output, AProblem);
end;

class function TCompiler.AgentOptions(const AOptions: TStrings): TStringList;
var
  I: Integer;
begin
  Result := TStringList.Create;
  for I := 0 to AOptions.Count - 1 do
    if StartsWithAny(AOptions[I], AgentOptionPrefixes) then
      Result.Add(AOptions[I]);
end;

function TCompiler.BuildAgent(out AOutput: string): Boolean;
var
  Source: TextFile;
  Arguments: TStringList;
  I: Integer;
begin
  ForceDirectories(FWorkspace.AgentDirectory);
  ForceDirectories(FWorkspace.AgentSourceDirectory);
  AssignFile(Source, FWorkspace.AgentSourceDirectory + AgentSourceFileName);
  Rewrite(Source);
  for I := 0 to High(AgentSourceLines) do
    WriteLn(Source, AgentSourceLines[I]);
  CloseFile(Source);
  Arguments := AgentOptions(FOptions);
  try
    Arguments.Add(UnitDirectoryOption + ExcludeTrailingPathDelimiter(FWorkspace.AgentDirectory));
    Arguments.Add(FWorkspace.AgentSourceDirectory + AgentSourceFileName);
    Result := (Execute(Arguments.ToStringArray, AOutput) = 0)
      and FileExists(FWorkspace.AgentDirectory + AgentRecordFileName);
  finally
    Arguments.Free;
  end;
end;

function TCompiler.CompileArguments(const ALink: Boolean): TStringList;
var
  I: Integer;
begin
  Result := TStringList.Create;
  Result.Add(KeepSymbolsOption);
  Result.Add(AgentUnitOption);
  Result.Add(UnitPathOption + ExcludeTrailingPathDelimiter(FWorkspace.AgentDirectory));
  Result.Add(UnitDirectoryOption + ExcludeTrailingPathDelimiter(FWorkspace.UnitsDirectory));
  Result.Add(OutputOption + FWorkspace.Executable);
  for I := 0 to FOptions.Count - 1 do
    Result.Add(FOptions[I]);
  if not ALink then
    Result.Add(NoLinkOption)
  { the linker's map: where it put sections that fpc 3.2 gives no symbol (the agent reads it) }
  else if FTargetWindows then
    Result.Add(LinkMapOption);
  Result.Add(FWorkspace.Source);
end;

class function TCompiler.IsPlaced(const ALine: string): Boolean;
var
  Open, Position: Integer;
begin
  Result := False;
  Open := Pos('(', ALine);
  if (Open < 2) or (Pos(' ', Copy(ALine, 1, Open)) > 0) then
    Exit;
  Position := Open + 1;
  if (Position > Length(ALine)) or not (ALine[Position] in ['0'..'9']) then
    Exit;
  while (Position <= Length(ALine)) and (ALine[Position] in ['0'..'9', ',']) do
    Inc(Position);
  Result := (Position < Length(ALine)) and (ALine[Position] = ')') and (ALine[Position + 1] = ' ');
end;

class function TCompiler.ExtractErrors(const AOutput: string): TStringList;
var
  Lines, Closing: TStringList;
  I: Integer;
  Line: string;
begin
  Result := TStringList.Create;
  Lines := TStringList.Create;
  Closing := TStringList.Create;
  try
    Lines.Text := AOutput;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if (Pos(ErrorMarker, Line) > 0) or (Pos(FatalMarker, Line) > 0) or StartsWith(Line, FatalPrefix)
        or StartsWith(Line, ErrorPrefix) then
      begin
        Closing.Add(Line);
        if IsPlaced(Line) then
          Result.Add(Line);
      end;
    end;
    { the diagnostics that name a place in a source file; the closing lines only when there is
      nothing else }
    if Result.Count = 0 then
      Result.Assign(Closing);
  finally
    Lines.Free;
    Closing.Free;
  end;
end;

function TCompiler.Compile(const ALink: Boolean; out AErrors: TStringList; out ASeconds: Double): Boolean;
var
  Arguments: TStringList;
  Output: string;
  Status: Integer;
  Start: Double;
begin
  Arguments := CompileArguments(ALink);
  try
    Start := NowSeconds;
    Status := Execute(Arguments.ToStringArray, Output);
    ASeconds := NowSeconds - Start;
  finally
    Arguments.Free;
  end;
  AErrors := ExtractErrors(Output);
  Result := Status = 0;
end;

class function TCompiler.AffectsUnit(const AChangedFile, AUnitRecord: string): Boolean;
begin
  Result := (LowerCase(ExtractFileExt(AChangedFile)) = IncludeExtension)
    or (LowerCase(ChangeFileExt(AUnitRecord, '')) = LowerCase(ChangeFileExt(ExtractFileName(AChangedFile), '')));
end;

procedure TCompiler.ForgetUnits(const AChangedFiles: TStrings);
var
  I, K: Integer;
  Records: TStringList;
  Search: TSearchRec;
begin
  if GetEnvironmentVariable(TrustTimestampsVariable) <> '' then
    Exit;
  Records := TStringList.Create;
  try
    if FindFirst(FWorkspace.UnitsDirectory + '*' + RecordExtension, faAnyFile, Search) = 0 then
    begin
      repeat
        Records.Add(Search.Name);
      until FindNext(Search) <> 0;
      FindClose(Search);
    end;
    for I := 0 to AChangedFiles.Count - 1 do
      for K := 0 to Records.Count - 1 do
        if AffectsUnit(AChangedFiles[I], Records[K]) then
        begin
          if GetEnvironmentVariable(DebugVariable) <> '' then
            WriteLn('[hot debug] forget ', Records[K], ' for ', AChangedFiles[I]);
          DeleteFile(FWorkspace.UnitsDirectory + Records[K]);
        end;
  finally
    Records.Free;
  end;
end;

end.
