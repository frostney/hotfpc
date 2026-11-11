unit HotFPC.Driver;
{ HotFPC.Driver: one run of hotfpc. It builds the program with the agent, starts it, waits for
  its agent to connect, and then polls the sources: on every save it compiles, checks the
  interfaces, hands the changed object files to the agent, and prints what happened as [hot]
  lines. It owns the order of these steps and the wording of what it prints; the work is in the
  units it asks. }
{$mode delphi}{$H+}
{ fpc 3.3.1 before fpc-toolchain release 3.3.1+4 miscompiles loops at -O1 and above
  (docs/how-it-works.md, "A compiler bug"); fpc -iV cannot tell those builds from fixed ones. }
{$IF FPC_FULLVERSION >= 30301}{$optimization off}{$ENDIF}

interface

uses
  HotFPC.Options;

{ Runs hotfpc with the options until the program ends; the exit code for hotfpc. }
function RunDriver(const AOptions: TOptions): Integer;

implementation

uses
  Classes,
  Process,
  SysUtils,

  HotFPC.AgentLink,
  HotFPC.Compiler,
  HotFPC.Files,
  HotFPC.Layout,
  HotFPC.Reporter,
  HotFPC.Sources,
  HotFPC.Timing,
  HotFPC.Workspace;

const
  PortVariable = 'HOT_PORT';
  TokenVariable = 'HOT_TOKEN';
  PollIntervalMilliseconds = 10;
  AcceptIntervalMilliseconds = 5;
  SettleSlackMilliseconds = 2;
  MillisecondsPerSecond = 1000.0;
  DigestIntervalSeconds = 0.5;
  { macOS checks a newly linked executable on its first start (seconds, more under load); Wine
    starts its server the first time. }
  ConnectTimeoutSeconds = 60;
  MaximumShownErrors = 6;
  ObjectExtension = '.o';
  RecordExtension = '.ppu';
  VerdictOK = 'ok';
  VerdictRefused = 'refused';
  VerdictFailed = 'failed';
  NotePrefix = 'note ';
  RestartPrefix = 'restart ';
  ErrorPrefix = 'error ';

type
  TDriver = class
  private
    FOptions: TOptions;
    FPPUDump: string;
    FWorkspace: TWorkspace;
    FReporter: TReporter;
    FCompiler: TCompiler;
    FWatcher: TSourceWatcher;
    FLink: TAgentLink;
    FReader: TLayoutReader;
    FLayouts: TLayoutHistory;
    FDigests: TStringList;
    FBased: TStringList;
    FStart: TDateTime;
    FStartedAt: Double;
    FBuildSeconds: Double;
    FVersion: Integer;
    FApplied: Integer;
    FRefused: Integer;
    FFailed: Integer;
    FUnchanged: Integer;
    function BuildProgram: Boolean;
    procedure CopyObjectsToLive;
    procedure ProbeLayouts;
    function StartProgram: TProcess;
    function AwaitAgent(const AProgram: TProcess; out AExitCode: Integer): Boolean;
    procedure Watch(const AProgram: TProcess);
    function Settle(const AStamps: TFileStamps): TFileStamps;
    function CompileSources(out ACompileSeconds: Double): Boolean;
    function CollectChangedObjects(const AChanged: TStrings; const ACompileSeconds: Double): Boolean;
    function LayoutsAllowSwap(const AChanged: TStrings; const ACompileSeconds: Double;
      out AInterfaceSeconds: Double): Boolean;
    procedure Swap(const AChanged: TStrings; const ASeen, ASettled, ACompileSeconds, AInterfaceSeconds: Double);
    procedure Accept(const AChanged: TStrings; const AStage: string);
    procedure Reject(const AReply: TStrings; const AVerdict, AStage: string; const ACompileSeconds: Double);
    procedure Reload(const ASeen, ASettled: Double);
    procedure SayStart;
    procedure SayEnd(const AExitCode: Integer);
  public
    constructor Create(const AOptions: TOptions);
    destructor Destroy; override;
    function Run: Integer;
  end;

function RunDriver(const AOptions: TOptions): Integer;
var
  Driver: TDriver;
begin
  Driver := TDriver.Create(AOptions);
  try
    Result := Driver.Run;
  finally
    Driver.Free;
  end;
end;

constructor TDriver.Create(const AOptions: TOptions);
begin
  inherited Create;
  FOptions := AOptions;
  FReporter := TReporter.Create(AOptions.LogPath);
  FWorkspace := TWorkspace.Create(AOptions.Source, AOptions.TargetWindows);
  FCompiler := TCompiler.Create(AOptions, FWorkspace);
  FWatcher := TSourceWatcher.Create(FWorkspace.SourceDirectory, AOptions.CompilerOptions);
  FLink := TAgentLink.Create(AOptions.WinePaths);
  FBased := TStringList.Create;
  FPPUDump := AOptions.PPUDump;
  if FPPUDump = '' then
    FPPUDump := TLayoutReader.Locate(AOptions.Compiler, ExtractFileExt(ParamStr(0)));
  FVersion := 1;
  FStart := Now;
end;

destructor TDriver.Destroy;
begin
  FDigests.Free;
  FBased.Free;
  FLayouts.Free;
  FReader.Free;
  FLink.Free;
  FWatcher.Free;
  FCompiler.Free;
  FWorkspace.Free;
  FReporter.Free;
  inherited Destroy;
end;

function TDriver.BuildProgram: Boolean;
var
  Errors: TStringList;
  I: Integer;
begin
  Result := FCompiler.Compile(True, Errors, FBuildSeconds);
  try
    if not Result then
      for I := 0 to Errors.Count - 1 do
        WriteLn(Errors[I]);
  finally
    Errors.Free;
  end;
end;

procedure TDriver.CopyObjectsToLive;
var
  Search: TSearchRec;
begin
  if FindFirst(FWorkspace.UnitsDirectory + '*', faAnyFile, Search) = 0 then
  begin
    repeat
      if (ExtractFileExt(Search.Name) = ObjectExtension) or (ExtractFileExt(Search.Name) = RecordExtension) then
        CopyFileContents(FWorkspace.UnitsDirectory + Search.Name, FWorkspace.LiveDirectory + Search.Name);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
end;

procedure TDriver.ProbeLayouts;
var
  Reason: string;
begin
  if FPPUDump = '' then
    Exit;
  FReader := TLayoutReader.Create(FPPUDump);
  if FReader.Probe(FWorkspace.UnitsDirectory, Reason) then
    FLayouts := TLayoutHistory.Create(FReader, FWorkspace.LiveDirectory, FWorkspace.UnitsDirectory)
  else
  begin
    WriteLn('[hot] ', FPPUDump, ' cannot read this compiler''s units (', Reason,
      '): the check of interface layouts is off; --ppudump names one that can');
    FPPUDump := '';
    FreeAndNil(FReader);
  end;
end;

function TDriver.StartProgram: TProcess;
var
  I: Integer;
begin
  Result := TProcess.Create(nil);
  if FOptions.Launcher <> '' then
  begin
    Result.Executable := FOptions.Launcher;
    Result.Parameters.Add(FWorkspace.Executable);
  end
  else
    Result.Executable := FWorkspace.Executable;
  for I := 0 to FOptions.ProgramArguments.Count - 1 do
    Result.Parameters.Add(FOptions.ProgramArguments[I]);
  for I := 1 to GetEnvironmentVariableCount do
    Result.Environment.Add(GetEnvironmentString(I));
  Result.Environment.Add(PortVariable + '=' + IntToStr(FLink.Port));
  Result.Environment.Add(TokenVariable + '=' + FLink.Token);
  Result.Options := [];
  FStartedAt := NowSeconds;
  Result.Execute;
end;

function TDriver.AwaitAgent(const AProgram: TProcess; out AExitCode: Integer): Boolean;
var
  Deadline: Double;
begin
  AExitCode := 0;
  Deadline := NowSeconds + ConnectTimeoutSeconds;
  while not FLink.TryAccept do
  begin
    if not AProgram.Running then
    begin
      { too short for its agent to connect, or it did not start }
      WriteLn('[hot] the program ended (exit code ', AProgram.ExitCode, ') before hot reloading could start');
      AExitCode := AProgram.ExitCode;
      Exit(False);
    end;
    if NowSeconds > Deadline then
    begin
      WriteLn('[hot] the program did not connect within ', ConnectTimeoutSeconds, ' s');
      AProgram.Terminate(1);
      AExitCode := 1;
      Exit(False);
    end;
    Sleep(AcceptIntervalMilliseconds);
  end;
  Result := True;
end;

function TDriver.CompileSources(out ACompileSeconds: Double): Boolean;
var
  Errors: TStringList;
  I: Integer;
begin
  Result := FCompiler.Compile(False, Errors, ACompileSeconds);
  try
    if Result then
      Exit;
    Inc(FFailed);
    if Errors.Count = 0 then
      Errors.Add('the compiler failed');
    for I := 0 to Errors.Count - 1 do
      if I < MaximumShownErrors then
        FReporter.Say('error: ' + Errors[I] + ' (nothing changed)');
  finally
    Errors.Free;
  end;
end;

{ The object files that differ from the running program's. False when the compile made one
  of a unit the program does not have. }
function TDriver.CollectChangedObjects(const AChanged: TStrings; const ACompileSeconds: Double): Boolean;
var
  Objects: TStringList;
  I: Integer;
  ObjectName: string;
begin
  Objects := FWorkspace.UnitObjects;
  try
    for I := 0 to Objects.Count - 1 do
    begin
      ObjectName := Objects[I];
      if not FileExists(FWorkspace.LiveDirectory + ObjectName) then
      begin
        { Its initialization section has never run and cannot run on the agent's thread. }
        Inc(FRefused);
        FReporter.Say('restart needed: unit ' + ChangeFileExt(ObjectName, '')
          + ' is not part of the running program (not applied; compile ' + FormatMilliseconds(ACompileSeconds) + ' ms)');
        DeleteFile(FWorkspace.UnitsDirectory + ObjectName);
        DeleteFile(FWorkspace.UnitsDirectory + ChangeFileExt(ObjectName, RecordExtension));
        Exit(False);
      end;
      if not SameFileContents(FWorkspace.UnitsDirectory + ObjectName, FWorkspace.LiveDirectory + ObjectName) then
        AChanged.Add(ObjectName);
    end;
  finally
    Objects.Free;
  end;
  Result := True;
end;

{ The interface of each changed unit, as the compiler wrote it down: a field that moved or
  changed its type without changing a size is invisible in the object file. }
function TDriver.LayoutsAllowSwap(const AChanged: TStrings; const ACompileSeconds: Double;
  out AInterfaceSeconds: Double): Boolean;
var
  Start: Double;
  I, K: Integer;
  RecordName: string;
  Differing: TStringList;
begin
  Start := NowSeconds;
  if FLayouts <> nil then
    for I := 0 to AChanged.Count - 1 do
    begin
      RecordName := ChangeFileExt(AChanged[I], RecordExtension);
      if not (FileExists(FWorkspace.LiveDirectory + RecordName) and FileExists(FWorkspace.UnitsDirectory + RecordName)) then
        Continue;
      Differing := FLayouts.Differences(RecordName);
      try
        if Differing.Count > 0 then
        begin
          Inc(FRefused);
          for K := 0 to Differing.Count - 1 do
            FReporter.Say('restart needed: ' + ChangeFileExt(AChanged[I], '') + '.'
              + Copy(Differing[K], Pos(' ', Differing[K]) + 1, MaxInt)
              + ': the declaration changed its layout or type (not applied; compile '
              + FormatMilliseconds(ACompileSeconds) + ' ms)');
          Exit(False);
        end;
      finally
        Differing.Free;
      end;
    end;
  AInterfaceSeconds := NowSeconds - Start;
  Result := True;
end;

{ The swap is applied: the staged files become the running program's, and so do the layouts. }
procedure TDriver.Accept(const AChanged: TStrings; const AStage: string);
var
  I: Integer;
  RecordName: string;
begin
  for I := 0 to AChanged.Count - 1 do
  begin
    CopyFileContents(AStage + AChanged[I], FWorkspace.LiveDirectory + AChanged[I]);
    RecordName := ChangeFileExt(AChanged[I], RecordExtension);
    if FileExists(FWorkspace.UnitsDirectory + RecordName) then
      CopyFileContents(FWorkspace.UnitsDirectory + RecordName, FWorkspace.LiveDirectory + RecordName);
    if FLayouts <> nil then
      FLayouts.Accept(RecordName);
    if FBased.IndexOf(AChanged[I]) < 0 then
      FBased.Add(AChanged[I]);
  end;
end;

procedure TDriver.Reject(const AReply: TStrings; const AVerdict, AStage: string; const ACompileSeconds: Double);
var
  I: Integer;
  Detail: string;
begin
  if AVerdict = VerdictRefused then
    Inc(FRefused)
  else
    Inc(FFailed);
  RemoveTree(ExcludeTrailingPathDelimiter(AStage));
  for I := 0 to AReply.Count - 1 do
    if (AVerdict = VerdictRefused) and TAgentLink.ReplyDetail(AReply[I], RestartPrefix, Detail) then
      FReporter.Say('restart needed: ' + Detail + ' (not applied; compile ' + FormatMilliseconds(ACompileSeconds) + ' ms)')
    else if (AVerdict <> VerdictRefused) and TAgentLink.ReplyDetail(AReply[I], ErrorPrefix, Detail) then
      FReporter.Say('error: ' + Detail + ' (nothing changed)');
  if AReply.Count = 0 then
    FReporter.Say('error: the program did not answer (nothing changed)');
end;

procedure TDriver.Swap(const AChanged: TStrings; const ASeen, ASettled, ACompileSeconds, AInterfaceSeconds: Double);
var
  Start, LoadSeconds: Double;
  I: Integer;
  Stage, Verdict, Units, Detail: string;
  Staged, Reply: TStringList;
begin
  Start := NowSeconds;
  for I := 0 to AChanged.Count - 1 do
    if (FBased.IndexOf(AChanged[I]) < 0) and FileExists(FWorkspace.LiveDirectory + AChanged[I]) then
    begin
      FLink.Base(FWorkspace.LiveDirectory + AChanged[I]);
      FBased.Add(AChanged[I]);
    end;
  Stage := FWorkspace.StageDirectory(FVersion + 1);
  ForceDirectories(Stage);
  Staged := TStringList.Create;
  try
    for I := 0 to AChanged.Count - 1 do
    begin
      CopyFileContents(FWorkspace.UnitsDirectory + AChanged[I], Stage + AChanged[I]);
      Staged.Add(Stage + AChanged[I]);
    end;
    Reply := FLink.Load(Staged);
  finally
    Staged.Free;
  end;
  try
    LoadSeconds := NowSeconds - Start;
    if Reply.Count > 0 then
      Verdict := Reply[Reply.Count - 1]
    else
      Verdict := VerdictFailed;
    Units := '';
    for I := 0 to AChanged.Count - 1 do
    begin
      if I > 0 then
        Units := Units + ', ';
      Units := Units + ChangeFileExt(AChanged[I], '');
    end;
    if Verdict <> VerdictOK then
    begin
      Reject(Reply, Verdict, Stage, ACompileSeconds);
      Exit;
    end;
    Inc(FVersion);
    Inc(FApplied);
    Accept(AChanged, Stage);
    FReporter.Say(Format('v%d swapped: %s: %s functions redirected (%s with other code, %s new), %s variables and tables kept, %s new, %s bytes; '
      + '%s ms after the save was seen (settle %s, compile %s, interface check %s, load %s of which in the program %s)',
      [FVersion, Units, TAgentLink.ReplyField(Reply, 'stat', 'redirected'), TAgentLink.ReplyField(Reply, 'stat', 'changed'),
       TAgentLink.ReplyField(Reply, 'stat', 'added'), TAgentLink.ReplyField(Reply, 'stat', 'kept'),
       TAgentLink.ReplyField(Reply, 'stat', 'newdata'), TAgentLink.ReplyField(Reply, 'stat', 'bytes'),
       FormatMilliseconds(NowSeconds - ASeen), FormatMilliseconds(ASettled - ASeen), FormatMilliseconds(ACompileSeconds),
       FormatMilliseconds(AInterfaceSeconds), FormatMilliseconds(LoadSeconds),
       TAgentLink.ReplyField(Reply, 'time', 'total')]));
    for I := 0 to Reply.Count - 1 do
      if TAgentLink.ReplyDetail(Reply[I], NotePrefix, Detail) then
        FReporter.Say('  note: ' + Detail);
  finally
    Reply.Free;
  end;
end;

{ One save: compile, then swap what changed in the running program or say why not. }
procedure TDriver.Reload(const ASeen, ASettled: Double);
var
  Changed: TStringList;
  CompileSeconds, InterfaceSeconds: Double;
begin
  if not CompileSources(CompileSeconds) then
    Exit;
  Changed := TStringList.Create;
  try
    if not CollectChangedObjects(Changed, CompileSeconds) then
      Exit;
    if not LayoutsAllowSwap(Changed, CompileSeconds, InterfaceSeconds) then
      Exit;
    if Changed.Count = 0 then
    begin
      Inc(FUnchanged);
      FReporter.Say('not swapped: the generated code is the same (compile ' + FormatMilliseconds(CompileSeconds) + ' ms)');
      Exit;
    end;
    Swap(Changed, ASeen, ASettled, CompileSeconds, InterfaceSeconds);
  finally
    Changed.Free;
  end;
end;

{ Waits for the save to stop changing the files. }
function TDriver.Settle(const AStamps: TFileStamps): TFileStamps;
var
  Again: TFileStamps;
begin
  Result := AStamps;
  repeat
    Sleep(Trunc(FOptions.SettleSeconds * MillisecondsPerSecond) + SettleSlackMilliseconds);
    Again := FWatcher.Stamps;
    if TSourceWatcher.SameStamps(Again, Result) then
      Break;
    Result := Again;
  until False;
end;

{ Polls the sizes and times of the sources every few milliseconds and their contents twice a
  second: the content check catches an edit of the same size within the same second. }
procedure TDriver.Watch(const AProgram: TProcess);
var
  Seen, Current: TFileStamps;
  Digests, Changed: TStringList;
  LastDigest, SeenAt: Double;
begin
  Seen := FWatcher.Stamps;
  LastDigest := NowSeconds;
  while True do
  begin
    Sleep(PollIntervalMilliseconds);
    if not AProgram.Running then
      Break;
    Current := FWatcher.Stamps;
    if TSourceWatcher.SameStamps(Current, Seen) and (NowSeconds - LastDigest < DigestIntervalSeconds) then
      Continue;
    SeenAt := NowSeconds;
    if not TSourceWatcher.SameStamps(Current, Seen) then
      Current := Settle(Current);
    Seen := Current;
    LastDigest := NowSeconds;
    { a missing or empty file: a save in progress }
    if not FWatcher.ReadDigests(Digests) then
      Continue;
    if (FDigests <> nil) and (Digests.Text = FDigests.Text) then
    begin
      Digests.Free;
      Continue;
    end;
    Changed := TSourceWatcher.ChangedFiles(FDigests, Digests);
    if GetEnvironmentVariable(DebugVariable) <> '' then
      WriteLn('[hot debug] seen at ', FormatFloat('0.000', SeenAt - LastDigest), ' changed ', Changed.CommaText);
    FCompiler.ForgetUnits(Changed);
    Changed.Free;
    FDigests.Free;
    FDigests := Digests;
    Reload(SeenAt, NowSeconds);
    if not AProgram.Running then
      Break;
  end;
end;

procedure TDriver.SayStart;
var
  Objects, Watched: TStringList;
begin
  if FOptions.Quiet then
    Exit;
  Objects := FWorkspace.UnitObjects;
  Watched := FWatcher.Files;
  try
    FReporter.Say(Format('v1: built in %s ms, started in %s ms, %d units of its own, watching %d files',
      [FormatMilliseconds(FBuildSeconds), FormatMilliseconds(NowSeconds - FStartedAt), Objects.Count, Watched.Count]));
  finally
    Watched.Free;
    Objects.Free;
  end;
end;

procedure TDriver.SayEnd(const AExitCode: Integer);
begin
  if not FOptions.Quiet then
    FReporter.Say(Format('the program ended with %d after %s s; %d reloads applied, %d refused, %d failed to compile, %d without a change in code',
      [AExitCode, FormatSeconds(SecondsSince(FStart)), FApplied, FRefused, FFailed, FUnchanged]));
end;

function TDriver.Run: Integer;
var
  Problem, Output: string;
  Running: TProcess;
begin
  if not FCompiler.VerifyVersion(Problem) then
  begin
    FReporter.Say(Problem);
    Exit(1);
  end;
  RemoveTree(ExcludeTrailingPathDelimiter(FWorkspace.HotDirectory));
  ForceDirectories(FWorkspace.UnitsDirectory);
  ForceDirectories(FWorkspace.LiveDirectory);
  if FPPUDump = '' then
    WriteLn('[hot] no ppudump next to the compiler (--ppudump): the check of interface layouts is off');
  if not FCompiler.BuildAgent(Output) then
  begin
    WriteLn('[hot] the agent did not compile:');
    WriteLn(Output);
    Exit(1);
  end;
  if not BuildProgram then
    Exit(1);
  CopyObjectsToLive;
  ProbeLayouts;
  if not FLink.Listen then
  begin
    WriteLn('[hot] cannot listen on 127.0.0.1');
    Exit(1);
  end;
  FWatcher.ReadDigests(FDigests);
  Running := StartProgram;
  try
    if not AwaitAgent(Running, Result) then
      Exit;
    SayStart;
    Watch(Running);
    Running.WaitOnExit;
    Result := Running.ExitCode;
    { ended by a signal }
    if (Result = 0) and (Running.ExitStatus <> 0) then
      Result := -1;
    SayEnd(Result);
  finally
    Running.Free;
  end;
end;

end.
