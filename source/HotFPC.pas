program HotFPC;
{ hotfpc: hot reloading for Free Pascal programs, as a wrapper around fpc.

    hotfpc [--version] [--fpc FPC] [--ppudump PPUDUMP] [--run LAUNCHER] [--quiet]
           [--settle MS] [--log FILE] [fpc options] program.pas [-- program arguments]

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
  --quiet     leave out the start line and the closing summary
  --version   print hotfpc's version

  This file is the whole of hotfpc apart from the agent: HotFPC.Agent.pas is the agent's
  source, and HotFPC.AgentSource.inc is the same source as string constants, written by
  build.pas, which this program includes. Compiled with -dHOTFPC_TESTS, the program runs
  its unit tests (HotFPC.Test.inc) instead. }
{$mode delphi}{$H+}

uses
  {$ifdef unix}
  cthreads,
  BaseUnix,
  {$endif}
  {$ifdef windows}
  WinSock2,
  {$endif}
  Classes,
  Contnrs,
  fpjson,
  jsonparser,
  Process,
  Sockets,
  SysUtils;

// ---------------------------------------------------------------- timing
{ The clock behind hotfpc's measurements and how a duration prints in a [hot] line. }

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


// ---------------------------------------------------------------- files
{ The whole-file and directory operations the driver needs, none of which keeps state. }

{ False when the file cannot be read; AContents is then empty or partial. }
function ReadFileContents(const APath: string; out AContents: string): Boolean;
var
  Stream: TFileStream;
begin
  AContents := '';
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(AContents, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(AContents[1], Stream.Size);
      Result := True;
    finally
      Stream.Free;
    end;
  except
    Result := False;
  end;
end;

procedure CopyFileContents(const ASource, ADestination: string);
var
  Source, Destination: TFileStream;
begin
  Source := TFileStream.Create(ASource, fmOpenRead or fmShareDenyNone);
  try
    Destination := TFileStream.Create(ADestination, fmCreate);
    try
      Destination.CopyFrom(Source, 0);
    finally
      Destination.Free;
    end;
  finally
    Source.Free;
  end;
end;

function SameFileContents(const AFirst, ASecond: string): Boolean;
var
  FirstContents, SecondContents: string;
begin
  Result := ReadFileContents(AFirst, FirstContents) and ReadFileContents(ASecond, SecondContents)
    and (FirstContents = SecondContents);
end;

{ Removes the directory and everything in it; nothing happens when it does not exist. }
procedure RemoveTree(const ADirectory: string);
var
  Search: TSearchRec;
  Prefix: string;
begin
  if not DirectoryExists(ADirectory) then
    Exit;
  Prefix := IncludeTrailingPathDelimiter(ADirectory);
  if FindFirst(Prefix + '*', faAnyFile, Search) = 0 then
  begin
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      if (Search.Attr and faDirectory) <> 0 then
        RemoveTree(Prefix + Search.Name)
      else
        DeleteFile(Prefix + Search.Name);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  RemoveDir(ADirectory);
end;

{ The path of the file in ADirectory whose name is AName apart from case, or '' when there
  is none. fpc names a unit's files after its source file, so on a case-sensitive file
  system a unit's name alone does not give the file name. }
function FindFileIgnoringCase(const ADirectory, AName: string): string;
var
  Search: TSearchRec;
  Directory: string;
begin
  Directory := IncludeTrailingPathDelimiter(ADirectory);
  Result := '';
  if FindFirst(Directory + '*', faAnyFile, Search) = 0 then
  begin
    repeat
      if SameText(Search.Name, AName) then
      begin
        Result := Directory + Search.Name;
        Break;
      end;
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
end;


// ---------------------------------------------------------------- sockets
{ What differs between Unix and Windows in the sockets the driver uses: the start of the
  socket library, blocking mode, and closing. Everything else about sockets is the Sockets
  unit's, which both systems share. }

{ WinSock2 declares a TSocket of its own, so the routines below name the Sockets unit's. }

{$ifdef windows}
const
  WinSockVersion = $0202;
  NonBlockingOn = 1;
  NonBlockingOff = 0;
{$endif}

{ Windows needs the socket library started once; elsewhere there is nothing to do. }
procedure StartNetwork;
{$ifdef windows}
var
  Data: WinSock2.TWSAData;
begin
  WinSock2.WSAStartup(WinSockVersion, Data);
end;
{$else}
begin
end;
{$endif}

procedure SetBlocking(const ASocket: Sockets.TSocket; const ABlocking: Boolean);
{$ifdef windows}
var
  Mode: WinSock2.u_long;
begin
  if ABlocking then
    Mode := NonBlockingOff
  else
    Mode := NonBlockingOn;
  WinSock2.ioctlsocket(ASocket, LongInt(WinSock2.FIONBIO), Mode);
end;
{$else}
var
  Flags: LongInt;
begin
  Flags := FpFcntl(ASocket, F_GETFL);
  if ABlocking then
    Flags := Flags and not O_NONBLOCK
  else
    Flags := Flags or O_NONBLOCK;
  FpFcntl(ASocket, F_SETFL, Flags);
end;
{$endif}

procedure CloseSocketHandle(const ASocket: Sockets.TSocket);
begin
{$ifdef windows}
  WinSock2.closesocket(ASocket);
{$else}
  FpClose(ASocket);
{$endif}
end;


// ---------------------------------------------------------------- command line
{ The command line of hotfpc as an options object, and the names of the environment variables
  it reads. Parsing only reads the arguments; printing the version or the usage and exiting is
  the program's. }

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

const
  SeparatorArgument = '--';
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


// ---------------------------------------------------------------- the .hot directory
{ The .hot/ directory next to the program's source, where hotfpc builds and keeps what it
  needs: every path in it, and the object files it holds. }

type
  TWorkspace = class
  private
    FSource: string;
    FName: string;
    FSourceDirectory: string;
    FHotDirectory: string;
    FUnitsDirectory: string;
    FLiveDirectory: string;
    FAgentDirectory: string;
    FAgentSourceDirectory: string;
    FExecutable: string;
  public
    constructor Create(const ASource: string; const ATargetWindows: Boolean);
    { The directory a swap's object files are staged in before the agent loads them. }
    function StageDirectory(const AVersion: Integer): string;
    { The names of the object files the last compile left in UnitsDirectory, sorted. The caller
      frees the list. }
    function UnitObjects: TStringList;
    { The full path of the program's source file. }
    property Source: string read FSource;
    { The program's name: the source file without its extension. }
    property Name: string read FName;
    { The source file's directory, with a trailing path delimiter. }
    property SourceDirectory: string read FSourceDirectory;
    { The following directories all end in a path delimiter. }
    property HotDirectory: string read FHotDirectory;
    { Where fpc puts the program's units and object files. }
    property UnitsDirectory: string read FUnitsDirectory;
    { The units as the running program has them. }
    property LiveDirectory: string read FLiveDirectory;
    { The compiled agent unit. }
    property AgentDirectory: string read FAgentDirectory;
    { The agent's source, written out for the compile; kept away from the program's search
      path. }
    property AgentSourceDirectory: string read FAgentSourceDirectory;
    { The built program (no trailing delimiter). }
    property Executable: string read FExecutable;
  end;

const
  HotDirectoryName = '.hot';
  UnitsDirectoryName = 'units';
  LiveDirectoryName = 'live';
  AgentDirectoryName = 'agent';
  AgentSourceDirectoryName = 'agent-src';
  StageDirectoryPrefix = 'v';
  ObjectPattern = '*.o';
  WindowsExecutableExtension = '.exe';

constructor TWorkspace.Create(const ASource: string; const ATargetWindows: Boolean);
begin
  inherited Create;
  FSource := ASource;
  FSourceDirectory := ExtractFilePath(ASource);
  FName := ChangeFileExt(ExtractFileName(ASource), '');
  FHotDirectory := FSourceDirectory + HotDirectoryName + PathDelim;
  FUnitsDirectory := FHotDirectory + UnitsDirectoryName + PathDelim;
  FLiveDirectory := FHotDirectory + LiveDirectoryName + PathDelim;
  FAgentDirectory := FHotDirectory + AgentDirectoryName + PathDelim;
  FAgentSourceDirectory := FHotDirectory + AgentSourceDirectoryName + PathDelim;
  FExecutable := FHotDirectory + FName;
  if ATargetWindows then
    FExecutable := FExecutable + WindowsExecutableExtension;
end;

function TWorkspace.StageDirectory(const AVersion: Integer): string;
begin
  Result := FHotDirectory + StageDirectoryPrefix + IntToStr(AVersion) + PathDelim;
end;

function TWorkspace.UnitObjects: TStringList;
var
  Search: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if FindFirst(FUnitsDirectory + ObjectPattern, faAnyFile, Search) = 0 then
  begin
    repeat
      Result.Add(Search.Name);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
end;


// ---------------------------------------------------------------- [hot] lines
{ The [hot] lines on standard output and their optional copy, with times, in the --log file. }

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


// ---------------------------------------------------------------- watching
{ Which source files hotfpc watches (the program's directory and the -Fu and -Fi directories fpc
  will search, also those of response files), how it notices a change (sizes and times, then
  content digests) and which files changed. }

type
  TFileStamp = record
    Path: string;
    Size: Int64;
    Time: LongInt;
  end;

  TFileStamps = array of TFileStamp;

  TSourceWatcher = class
  private
    FDirectories: TStringList;
  public
    { ASourceDirectory is the program's own; ACompilerOptions are the options for fpc,
      where -Fu, -Fi and @response files name more directories. }
    constructor Create(const ASourceDirectory: string; const ACompilerOptions: TStrings);
    destructor Destroy; override;
    { Adds the directories one option makes fpc search for sources: -Fu and -Fi (several
      separated by ;), also inside a response file (@lwpt.cfg). Relative paths are taken from
      the current directory, as fpc takes them. A path with a wildcard is not watched. }
    class procedure AddOptionDirectories(const AOption: string; const ADirectories: TStrings);
    class function HasSourceExtension(const AName: string): Boolean;
    { A 64-bit hash of the contents: FNV-1a, from the seed the driver has always used. }
    class function ContentDigest(const AContents: string): QWord;
    class function SameStamps(const AFirst, ASecond: TFileStamps): Boolean;
    { The files whose digest differs between the two lists of path=digest, or that are new
      in ACurrent. APrevious may be nil: then every file is a change. }
    class function ChangedFiles(const APrevious, ACurrent: TStrings): TStringList;
    { The paths of every watched source file, sorted. The caller frees the list. }
    function Files: TStringList;
    { Names, sizes and times of the watched files. Times have whole seconds only. }
    function Stamps: TFileStamps;
    { The content of every watched file as path=digest. False while a file is missing or empty
      (a save in progress); ADigests is then nil. Otherwise the caller frees the list. }
    function ReadDigests(out ADigests: TStringList): Boolean;
    property Directories: TStringList read FDirectories;
  end;

const
  SourceExtensions: array[0..4] of string = ('.pas', '.pp', '.inc', '.lpr', '.dpr');
  ResponseFilePrefix = '@';
  UnitPathPrefix = '-Fu';
  IncludePathPrefix = '-Fi';
  PathListSeparator = ';';
  OptionSeparator = ' ';
  WildcardCharacter = '*';
  AllFilesPattern = '*';
  ResponseCommentCharacters = ['#', ';'];
  { FNV-1a's offset basis is 14695981039346656037; the driver has always started from this
    number, which lacks its last digit. The digests are only ever compared with each other, so
    the number stays as it was. }
  DigestSeed = QWord(1469598103934665603);
  FNVPrime = QWord(1099511628211);
  DigestWidth = 16;

constructor TSourceWatcher.Create(const ASourceDirectory: string; const ACompilerOptions: TStrings);
var
  I: Integer;
begin
  inherited Create;
  FDirectories := TStringList.Create;
  FDirectories.Add(ExcludeTrailingPathDelimiter(ASourceDirectory));
  for I := 0 to ACompilerOptions.Count - 1 do
    AddOptionDirectories(ACompilerOptions[I], FDirectories);
end;

destructor TSourceWatcher.Destroy;
begin
  FDirectories.Free;
  inherited Destroy;
end;

class procedure TSourceWatcher.AddOptionDirectories(const AOption: string; const ADirectories: TStrings);
var
  Rest, Part: string;
  Lines: TStringList;
  I, Separator: Integer;
begin
  if Copy(AOption, 1, Length(ResponseFilePrefix)) = ResponseFilePrefix then
  begin
    if not FileExists(Copy(AOption, 2, MaxInt)) then
      Exit;
    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(Copy(AOption, 2, MaxInt));
      for I := 0 to Lines.Count - 1 do
      begin
        Rest := Trim(Lines[I]);
        if (Rest = '') or (Rest[1] in ResponseCommentCharacters) then
          Continue;
        { options on a line are separated by blanks; a response file does not include another }
        while Rest <> '' do
        begin
          Separator := Pos(OptionSeparator, Rest);
          if Separator = 0 then
            Separator := Length(Rest) + 1;
          Part := Copy(Rest, 1, Separator - 1);
          Delete(Rest, 1, Separator);
          Rest := TrimLeft(Rest);
          if (Part <> '') and (Part[1] <> ResponseFilePrefix) then
            AddOptionDirectories(Part, ADirectories);
        end;
      end;
    finally
      Lines.Free;
    end;
    Exit;
  end;
  if (Copy(AOption, 1, Length(UnitPathPrefix)) <> UnitPathPrefix)
    and (Copy(AOption, 1, Length(IncludePathPrefix)) <> IncludePathPrefix) then
    Exit;
  Rest := Copy(AOption, Length(UnitPathPrefix) + 1, MaxInt);
  while Rest <> '' do
  begin
    Separator := Pos(PathListSeparator, Rest);
    if Separator = 0 then
      Separator := Length(Rest) + 1;
    Part := Copy(Rest, 1, Separator - 1);
    Delete(Rest, 1, Separator);
    if (Part <> '') and (Pos(WildcardCharacter, Part) = 0) then
      ADirectories.Add(ExcludeTrailingPathDelimiter(ExpandFileName(Part)));
  end;
end;

class function TSourceWatcher.HasSourceExtension(const AName: string): Boolean;
var
  Extension: string;
  I: Integer;
begin
  Extension := LowerCase(ExtractFileExt(AName));
  for I := 0 to High(SourceExtensions) do
    if Extension = SourceExtensions[I] then
      Exit(True);
  Result := False;
end;

class function TSourceWatcher.ContentDigest(const AContents: string): QWord;
var
  I: SizeInt;
begin
{$push}{$Q-}{$R-}
  Result := DigestSeed;
  for I := 1 to Length(AContents) do
    Result := (Result xor Ord(AContents[I])) * FNVPrime;
{$pop}
end;

class function TSourceWatcher.SameStamps(const AFirst, ASecond: TFileStamps): Boolean;
var
  I: Integer;
begin
  if Length(AFirst) <> Length(ASecond) then
    Exit(False);
  for I := 0 to High(AFirst) do
    if (AFirst[I].Path <> ASecond[I].Path) or (AFirst[I].Size <> ASecond[I].Size)
      or (AFirst[I].Time <> ASecond[I].Time) then
      Exit(False);
  Result := True;
end;

class function TSourceWatcher.ChangedFiles(const APrevious, ACurrent: TStrings): TStringList;
var
  I: Integer;
  Name, Value: string;
begin
  Result := TStringList.Create;
  { Each value goes into a variable of its own first: fpc 3.3.1+3 for x86-64 gave the loop
    counter and the temporary result of ValueFromIndex the same register when this was one
    expression (docs/how-it-works.md, "A compiler bug"). }
  for I := 0 to ACurrent.Count - 1 do
  begin
    Name := ACurrent.Names[I];
    Value := ACurrent.ValueFromIndex[I];
    if (APrevious = nil) or (APrevious.Values[Name] <> Value) then
      Result.Add(Name);
  end;
end;

function TSourceWatcher.Files: TStringList;
var
  I: Integer;
  Search: TSearchRec;
  Prefix: string;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  for I := 0 to FDirectories.Count - 1 do
  begin
    Prefix := IncludeTrailingPathDelimiter(FDirectories[I]);
    if FindFirst(Prefix + AllFilesPattern, faAnyFile, Search) = 0 then
    begin
      repeat
        if ((Search.Attr and faDirectory) = 0) and HasSourceExtension(Search.Name) then
          Result.Add(Prefix + Search.Name);
      until FindNext(Search) <> 0;
      FindClose(Search);
    end;
  end;
end;

function TSourceWatcher.Stamps: TFileStamps;
var
  Watched: TStringList;
  I: Integer;
  Search: TSearchRec;
begin
  Result := nil;
  Watched := Files;
  try
    SetLength(Result, Watched.Count);
    for I := 0 to Watched.Count - 1 do
    begin
      Result[I].Path := Watched[I];
      Result[I].Size := -1;
      Result[I].Time := 0;
      if FindFirst(Watched[I], faAnyFile, Search) = 0 then
      begin
        Result[I].Size := Search.Size;
        Result[I].Time := Search.Time;
        FindClose(Search);
      end;
    end;
  finally
    Watched.Free;
  end;
end;

function TSourceWatcher.ReadDigests(out ADigests: TStringList): Boolean;
var
  Watched: TStringList;
  I: Integer;
  Contents: string;
begin
  ADigests := TStringList.Create;
  Watched := Files;
  try
    for I := 0 to Watched.Count - 1 do
    begin
      if not ReadFileContents(Watched[I], Contents) or (Contents = '') then
      begin
        FreeAndNil(ADigests);
        Exit(False);
      end;
      ADigests.Add(Watched[I] + '=' + IntToHex(ContentDigest(Contents), DigestWidth));
    end;
  finally
    Watched.Free;
  end;
  Result := True;
end;


// ---------------------------------------------------------------- interface layouts (ppudump)
{ The check of interface layouts. A field that moved or changed its type without changing a
  size is invisible in the object file, so hotfpc reads the interface of each changed unit
  with ppudump (JSON output) and compares it with the one of the unit that is running.  A
  layout is the interface of one unit as the compiler wrote it down: name=text for the layout
  of each record or class type and the type of each variable. Two texts differ exactly when a
  field was added, removed, moved or retyped, or a variable changed its type. }

type
  TLayout = TStringList;

  { Runs ppudump and turns its output into layouts. }
  TLayoutReader = class
  private
    FPPUDump: string;
  protected
    { The text ppudump prints for a unit file, errors included. }
    function Dump(const APPUPath: string): string; virtual;
  public
    constructor Create(const APPUDump: string);
    { The ppudump next to the compiler (the named one's folder, or the first on PATH when the
      compiler is a bare name), or '' when there is none. AExecutableExtension is '.exe' on
      Windows. }
    class function Locate(const ACompiler, AExecutableExtension: string): string;
    { A ppudump that cannot read this compiler's units (another version: "Unsupported PPU
      version") would make every interface look unchanged. Tries it on one of the units in
      AUnitsDirectory; True when it works or there is no unit yet, otherwise False and
      AReason is the first line it printed. }
    function Probe(const AUnitsDirectory: string; out AReason: string): Boolean;
    { The layout of a unit file. Units of the program that it refers to are looked for in
      AOwnDirectory: their numbering moves between compiles, their names do not. The caller
      frees the layout. }
    function Read(const APPUPath, AOwnDirectory: string): TLayout;
    { Reads ppudump's JSON, as Dump returns it, as a layout; AOwnDirectory as for Read. }
    function ReadJSON(const AJSON, AOwnDirectory: string): TLayout;
    property PPUDump: string read FPPUDump;
  end;

  { The layouts of the units in the running program, and the ones a swap would bring. }
  TLayoutHistory = class
  private
    FReader: TLayoutReader;
    FLiveDirectory: string;
    FUnitsDirectory: string;
    FLive: TStringList;
    FPending: TStringList;
    procedure DropPending(const APPUName: string);
  public
    constructor Create(const AReader: TLayoutReader; const ALiveDirectory, AUnitsDirectory: string);
    destructor Destroy; override;
    { The declarations of a unit whose layout or type the new compile changed, as
      "variable Name" or "type Name"; empty when none did. When none did, the new layout is
      kept until Accept. The unit is named by its file, such as "foo.ppu". The caller frees the
      list. }
    function Differences(const APPUName: string): TStringList;
    { The swap happened: the new layout of the unit is the running one. }
    procedure Accept(const APPUName: string);
    { The declarations (names as in a layout) that ANew has with other text than AOld. A
      declaration only one of them has is not a difference: adding one is a restart only
      when the object file says so. }
    class function DifferingDeclarations(const AOld, ANew: TStrings): TStringList;
  end;

const
  JSONDumpOption = '-Fj';
  PPUDumpName = 'ppudump';
  PPUExtension = '.ppu';
  MaximumDepth = 6;
  DepthLimitMarker = '...';
  UnknownType = '?';
  VariablePrefix = 'variable ';
  TypePrefix = 'type ';
  { Keys that differ between compiles or say nothing about the layout. }
  IgnoredKeys: array[0..5] of string = ('Pos', 'SymId', 'Id', 'Name', 'Fields', 'Visibility');

type
  { One reading of one unit file, with the definitions of the unit and of the units of the
    program it refers to. }
  TLayoutBuilder = class
  private
    FReader: TLayoutReader;
    FOwnDirectory: string;
    FRoot: TJSONObject;
    FDefinitions: TStringList;
    FOthers: TStringList;
    FHolders: TObjectList;
    function Load(const APPUPath: string; const ADefinitions: TStringList): TJSONObject;
    function Parse(const AJSON: string; const ADefinitions: TStringList): TJSONObject;
    procedure Collect(const AItems: TJSONArray; const ADefinitions: TStringList);
    function Reference(const AType: TJSONData; const ADepth: Integer): string;
    function Canonical(const AObject: TJSONObject; const ADepth: Integer): string;
  public
    constructor Create(const AReader: TLayoutReader; const AOwnDirectory: string);
    destructor Destroy; override;
    function Build(const AJSON: string): TLayout;
  end;

{ A JSON value as text: strings as they are, numbers and the rest as JSON. }
function JSONText(const AObject: TJSONObject; const AName: string): string;
var
  Data: TJSONData;
begin
  Data := AObject.Find(AName);
  if Data = nil then
    Result := ''
  else if Data is TJSONString then
    Result := Data.AsString
  else
    Result := Data.AsJSON;
end;

{ The unit ppudump describes: the first object of the array it prints. }
function UnitObject(const AData: TJSONData): TJSONObject;
begin
  Result := nil;
  if (AData is TJSONArray) and (TJSONArray(AData).Count > 0) and (TJSONArray(AData).Items[0] is TJSONObject) then
    Result := TJSONObject(TJSONArray(AData).Items[0]);
end;

constructor TLayoutBuilder.Create(const AReader: TLayoutReader; const AOwnDirectory: string);
begin
  inherited Create;
  FReader := AReader;
  FOwnDirectory := AOwnDirectory;
  FDefinitions := TStringList.Create;
  FDefinitions.Sorted := True;
  FDefinitions.Duplicates := dupIgnore;
  FOthers := TStringList.Create;
  FHolders := TObjectList.Create(True);
end;

destructor TLayoutBuilder.Destroy;
var
  I: Integer;
begin
  FDefinitions.Free;
  for I := 0 to FOthers.Count - 1 do
    FOthers.Objects[I].Free;
  FOthers.Free;
  FHolders.Free;
  inherited Destroy;
end;

procedure TLayoutBuilder.Collect(const AItems: TJSONArray; const ADefinitions: TStringList);
var
  I: Integer;
  Item: TJSONObject;
begin
  for I := 0 to AItems.Count - 1 do
    if AItems.Items[I] is TJSONObject then
    begin
      Item := TJSONObject(AItems.Items[I]);
      if Item.Find('Id') <> nil then
        ADefinitions.AddObject(JSONText(Item, 'Id'), Item);
      if Item.Find('Fields') is TJSONArray then
        Collect(TJSONArray(Item.Find('Fields')), ADefinitions);
    end;
end;

function TLayoutBuilder.Parse(const AJSON: string; const ADefinitions: TStringList): TJSONObject;
var
  Data: TJSONData;
begin
  Result := nil;
  try
    Data := GetJSON(AJSON);
  except
    on Exception do
      Data := nil;
  end;
  if Data = nil then
    Exit;
  FHolders.Add(Data);
  Result := UnitObject(Data);
  if (Result <> nil) and (Result.Find('Interface') is TJSONArray) then
    Collect(TJSONArray(Result.Find('Interface')), ADefinitions);
end;

function TLayoutBuilder.Load(const APPUPath: string; const ADefinitions: TStringList): TJSONObject;
begin
  Result := Parse(FReader.Dump(APPUPath), ADefinitions);
end;

function TLayoutBuilder.Reference(const AType: TJSONData; const ADepth: Integer): string;
var
  TypeObject, Definition: TJSONObject;
  UnitName, Identifier, UnitRecord: string;
  Index: Integer;
  OtherDefinitions: TStringList;
begin
  if not (AType is TJSONObject) or (TJSONObject(AType).Find('Id') = nil) then
    Exit(UnknownType);
  TypeObject := TJSONObject(AType);
  Identifier := JSONText(TypeObject, 'Id');
  if TypeObject.Find('Unit') <> nil then
  begin
    UnitName := TJSONArray(FRoot.Find('Units')).Strings[StrToIntDef(JSONText(TypeObject, 'Unit'), 0)];
    { a unit of the program: its numbering moves, its names do not }
    UnitRecord := FindFileIgnoringCase(FOwnDirectory, UnitName + PPUExtension);
    if UnitRecord <> '' then
    begin
      Index := FOthers.IndexOf(UnitName);
      if Index < 0 then
      begin
        OtherDefinitions := TStringList.Create;
        OtherDefinitions.Sorted := True;
        OtherDefinitions.Duplicates := dupIgnore;
        Load(UnitRecord, OtherDefinitions);
        Index := FOthers.AddObject(UnitName, OtherDefinitions);
      end;
      OtherDefinitions := TStringList(FOthers.Objects[Index]);
      Index := OtherDefinitions.IndexOf(Identifier);
      if (Index >= 0) and (JSONText(TJSONObject(OtherDefinitions.Objects[Index]), 'Name') <> '') then
        Exit(UnitName + '.' + JSONText(TJSONObject(OtherDefinitions.Objects[Index]), 'Name'));
    end;
    Exit(UnitName + '#' + Identifier);
  end;
  Index := FDefinitions.IndexOf(Identifier);
  if Index < 0 then
    Exit('#' + Identifier);
  Definition := TJSONObject(FDefinitions.Objects[Index]);
  if (JSONText(Definition, 'Name') <> '') and (JSONText(Definition, 'Name')[1] <> '$') then
    Exit(JSONText(Definition, 'Name'));
  Result := Canonical(Definition, ADepth + 1);
end;

function TLayoutBuilder.Canonical(const AObject: TJSONObject; const ADepth: Integer): string;
var
  Keys: TStringList;
  I, K: Integer;
  Value: TJSONData;
  Field: TJSONObject;
  Fields: TJSONArray;
  Skip: Boolean;
begin
  if ADepth > MaximumDepth then
    Exit(DepthLimitMarker);
  Keys := TStringList.Create;
  try
    Keys.CaseSensitive := True;
    for I := 0 to AObject.Count - 1 do
      Keys.Add(AObject.Names[I]);
    Keys.Sort;
    Result := '{';
    for I := 0 to Keys.Count - 1 do
    begin
      Skip := False;
      for K := 0 to High(IgnoredKeys) do
        if Keys[I] = IgnoredKeys[K] then
          Skip := True;
      if Skip then
        Continue;
      Value := AObject.Find(Keys[I]);
      if Value is TJSONObject then
        Result := Result + Keys[I] + '=' + Reference(Value, ADepth) + ' '
      else
        Result := Result + Keys[I] + '=' + Value.AsJSON + ' ';
    end;
    if AObject.Find('Fields') is TJSONArray then
    begin
      Fields := TJSONArray(AObject.Find('Fields'));
      for I := 0 to Fields.Count - 1 do
        if Fields.Items[I] is TJSONObject then
        begin
          Field := TJSONObject(Fields.Items[I]);
          if JSONText(Field, 'Type') = 'field' then
            Result := Result + JSONText(Field, 'Name') + ':' + Reference(Field.Find('VarType'), ADepth) + ' ';
        end;
    end;
    Result := Result + '}';
  finally
    Keys.Free;
  end;
end;

function TLayoutBuilder.Build(const AJSON: string): TLayout;
var
  I: Integer;
  Item: TJSONObject;
  Declarations: TJSONArray;
  Kind: string;
begin
  Result := TLayout.Create;
  FRoot := Parse(AJSON, FDefinitions);
  if (FRoot <> nil) and (FRoot.Find('Interface') is TJSONArray) then
  begin
    Declarations := TJSONArray(FRoot.Find('Interface'));
    for I := 0 to Declarations.Count - 1 do
    begin
      if not (Declarations.Items[I] is TJSONObject) then
        Continue;
      Item := TJSONObject(Declarations.Items[I]);
      { the compiler's own types ($vmtdef$TFoo in fpc 3.2) are not declarations of the program }
      if (JSONText(Item, 'Name') = '') or (JSONText(Item, 'Name')[1] = '$') then
        Continue;
      Kind := JSONText(Item, 'Type');
      if Kind = 'var' then
        Result.Values[VariablePrefix + JSONText(Item, 'Name')] := Reference(Item.Find('VarType'), 0)
      else if (Kind = 'rec') or (Kind = 'obj') then
        Result.Values[TypePrefix + JSONText(Item, 'Name')] := Canonical(Item, 0);
    end;
  end;
end;

constructor TLayoutReader.Create(const APPUDump: string);
begin
  inherited Create;
  FPPUDump := APPUDump;
end;

function TLayoutReader.Dump(const APPUPath: string): string;
begin
  Result := '';
  RunCommand(FPPUDump, [JSONDumpOption, APPUPath], Result, [poStderrToOutPut]);
end;

class function TLayoutReader.Locate(const ACompiler, AExecutableExtension: string): string;
var
  Directory: string;
begin
  Result := '';
  Directory := ExtractFilePath(ACompiler);
  if Directory = '' then
    Directory := ExtractFilePath(ExeSearch(ACompiler, GetEnvironmentVariable('PATH')));
  if FileExists(Directory + PPUDumpName + AExecutableExtension) then
    Result := Directory + PPUDumpName + AExecutableExtension;
end;

function TLayoutReader.Probe(const AUnitsDirectory: string; out AReason: string): Boolean;
var
  Search: TSearchRec;
  Output: string;
  Data: TJSONData;
begin
  AReason := '';
  if FindFirst(AUnitsDirectory + '*' + PPUExtension, faAnyFile, Search) <> 0 then
    Exit(True);
  Output := Dump(AUnitsDirectory + Search.Name);
  FindClose(Search);
  Result := False;
  try
    Data := GetJSON(Output);
    Result := (UnitObject(Data) <> nil) and (UnitObject(Data).Find('Interface') <> nil);
    Data.Free;
  except
    on Exception do
      Result := False;
  end;
  if not Result then
    AReason := Trim(Copy(Output, 1, Pos(#10, Output + #10) - 1));
end;

function TLayoutReader.Read(const APPUPath, AOwnDirectory: string): TLayout;
begin
  Result := ReadJSON(Dump(APPUPath), AOwnDirectory);
end;

function TLayoutReader.ReadJSON(const AJSON, AOwnDirectory: string): TLayout;
var
  Builder: TLayoutBuilder;
begin
  Builder := TLayoutBuilder.Create(Self, AOwnDirectory);
  try
    Result := Builder.Build(AJSON);
  finally
    Builder.Free;
  end;
end;

constructor TLayoutHistory.Create(const AReader: TLayoutReader; const ALiveDirectory, AUnitsDirectory: string);
begin
  inherited Create;
  FReader := AReader;
  FLiveDirectory := ALiveDirectory;
  FUnitsDirectory := AUnitsDirectory;
  FLive := TStringList.Create;
  FPending := TStringList.Create;
end;

destructor TLayoutHistory.Destroy;
var
  I: Integer;
begin
  for I := 0 to FLive.Count - 1 do
    FLive.Objects[I].Free;
  FLive.Free;
  for I := 0 to FPending.Count - 1 do
    FPending.Objects[I].Free;
  FPending.Free;
  inherited Destroy;
end;

procedure TLayoutHistory.DropPending(const APPUName: string);
var
  Index: Integer;
begin
  Index := FPending.IndexOf(APPUName);
  if Index >= 0 then
  begin
    FPending.Objects[Index].Free;
    FPending.Delete(Index);
  end;
end;

class function TLayoutHistory.DifferingDeclarations(const AOld, ANew: TStrings): TStringList;
var
  I: Integer;
  Key, Value: string;
begin
  Result := TStringList.Create;
  for I := 0 to ANew.Count - 1 do
  begin
    Key := ANew.Names[I];
    Value := ANew.ValueFromIndex[I];
    if (AOld.IndexOfName(Key) >= 0) and (AOld.Values[Key] <> Value) then
      Result.Add(Key);
  end;
end;

function TLayoutHistory.Differences(const APPUName: string): TStringList;
var
  Index: Integer;
  Fresh: TLayout;
begin
  Index := FLive.IndexOf(APPUName);
  if Index < 0 then
    Index := FLive.AddObject(APPUName, FReader.Read(FLiveDirectory + APPUName, FLiveDirectory));
  Fresh := FReader.Read(FUnitsDirectory + APPUName, FUnitsDirectory);
  Result := DifferingDeclarations(TLayout(FLive.Objects[Index]), Fresh);
  if Result.Count > 0 then
    Fresh.Free
  else
  begin
    DropPending(APPUName);
    FPending.AddObject(APPUName, Fresh);
  end;
end;

procedure TLayoutHistory.Accept(const APPUName: string);
var
  Pending, Live: Integer;
begin
  Pending := FPending.IndexOf(APPUName);
  Live := FLive.IndexOf(APPUName);
  if (Pending >= 0) and (Live >= 0) then
  begin
    FLive.Objects[Live].Free;
    FLive.Objects[Live] := FPending.Objects[Pending];
    FPending.Delete(Pending);
  end;
end;


// ---------------------------------------------------------------- the agent connection
{ The connection between the driver and the agent inside the program, and the protocol on it.
  The driver listens on 127.0.0.1 on a port the system picks; the program connects and greets
  with "hello <token>", the token being the one the driver put into the program's
  environment. A command is one line of tab-separated fields; the reply is lines ended by a
  line with a single dot. The commands are base (remember a unit's code before its first
  change) and load (apply object files). TCP works the same on every system, including
  between a program under Wine and a driver outside it. }

type
  TAgentLink = class
  private
    FListener: TSocket;
    FConnection: TSocket;
    FPort: Word;
    FToken: string;
    FReceived: string;
    FWinePaths: Boolean;
    function Ask(const AFields: array of string): TStringList;
  public
    { AWinePaths: the program runs under Wine, so paths sent to it are Windows paths. }
    constructor Create(const AWinePaths: Boolean);
    destructor Destroy; override;
    { Starts listening, without blocking, on a port the system picks. False when that is
      not possible. }
    function Listen: Boolean;
    { Takes one waiting connection and keeps it when it greets with the token; anything else
      that connects (a program the program started, or something else) is closed. True once
      the agent is connected. }
    function TryAccept: Boolean;
    { Tells the agent to remember the code of a unit's object file as the base of later swaps. }
    procedure Base(const APath: string);
    { Asks the agent to apply object files; the reply's lines, without the closing dot. The
      caller frees the list. }
    function Load(const APaths: TStrings): TStringList;
    { The command as it goes on the wire. }
    class function EncodeCommand(const AFields: array of string): string;
    { Takes the first complete line out of ABuffer. False when there is none yet. }
    class function TakeLine(var ABuffer: string; out ALine: string): Boolean;
    { From "stat a=1 b=2" among the lines: the value of a key, or ''. }
    class function ReplyField(const ALines: TStrings; const APrefix, AKey: string): string;
    { True when the line starts with the prefix, and then what follows it. }
    class function ReplyDetail(const ALine, APrefix: string; out ADetail: string): Boolean;
    { A program under Wine sees the host's root as drive Z:. }
    class function TranslatePath(const APath: string; const AWinePaths: Boolean): string;
    class function NewToken: string;
    class function Greeting(const AToken: string): string;
    property Port: Word read FPort;
    property Token: string read FToken;
  end;

const
  InvalidSocket = TSocket(-1);
  LoopbackAddress = $7f000001;
  ListenBacklog = 8;
  MaximumGreetingLength = 200;
  ReceiveBufferSize = 65536;
  TokenRange = $7fffffff;
  TokenPartDigits = 8;
  FieldSeparator = #9;
  LineEnd = #10;
  ReplyEnd = '.';
  GreetingPrefix = 'hello ';
  BaseCommand = 'base';
  LoadCommand = 'load';

constructor TAgentLink.Create(const AWinePaths: Boolean);
begin
  inherited Create;
  FWinePaths := AWinePaths;
  FListener := InvalidSocket;
  FConnection := InvalidSocket;
  StartNetwork;
end;

destructor TAgentLink.Destroy;
begin
  if FConnection <> InvalidSocket then
    CloseSocketHandle(FConnection);
  if FListener <> InvalidSocket then
    CloseSocketHandle(FListener);
  inherited Destroy;
end;

class function TAgentLink.NewToken: string;
begin
  Randomize;
  Result := IntToHex(Random(TokenRange), TokenPartDigits) + IntToHex(Random(TokenRange), TokenPartDigits);
end;

class function TAgentLink.Greeting(const AToken: string): string;
begin
  Result := GreetingPrefix + AToken;
end;

class function TAgentLink.TranslatePath(const APath: string; const AWinePaths: Boolean): string;
begin
  if AWinePaths then
    Result := 'Z:' + StringReplace(APath, '/', '\', [rfReplaceAll])
  else
    Result := APath;
end;

class function TAgentLink.EncodeCommand(const AFields: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AFields) do
  begin
    if I > 0 then
      Result := Result + FieldSeparator;
    Result := Result + AFields[I];
  end;
  Result := Result + LineEnd;
end;

class function TAgentLink.TakeLine(var ABuffer: string; out ALine: string): Boolean;
var
  Separator: Integer;
begin
  Separator := Pos(LineEnd, ABuffer);
  if Separator = 0 then
    Exit(False);
  ALine := Copy(ABuffer, 1, Separator - 1);
  Delete(ABuffer, 1, Separator);
  Result := True;
end;

class function TAgentLink.ReplyField(const ALines: TStrings; const APrefix, AKey: string): string;
var
  I, Separator: Integer;
  Rest, Item: string;
begin
  Result := '';
  for I := 0 to ALines.Count - 1 do
    if Copy(ALines[I], 1, Length(APrefix) + 1) = APrefix + ' ' then
    begin
      Rest := ALines[I] + ' ';
      repeat
        Separator := Pos(' ', Rest);
        if Separator = 0 then
          Break;
        Item := Copy(Rest, 1, Separator - 1);
        Delete(Rest, 1, Separator);
        if Copy(Item, 1, Length(AKey) + 1) = AKey + '=' then
          Exit(Copy(Item, Length(AKey) + 2, MaxInt));
      until Rest = '';
    end;
end;

class function TAgentLink.ReplyDetail(const ALine, APrefix: string; out ADetail: string): Boolean;
begin
  Result := Copy(ALine, 1, Length(APrefix)) = APrefix;
  if Result then
    ADetail := Copy(ALine, Length(APrefix) + 1, MaxInt)
  else
    ADetail := '';
end;

function TAgentLink.Listen: Boolean;
var
  Address: TInetSockAddr;
  AddressLength: TSockLen;
begin
  FListener := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := 0;
  Address.sin_addr.s_addr := htonl(LoopbackAddress);
  if fpBind(FListener, @Address, SizeOf(Address)) <> 0 then
    Exit(False);
  fpListen(FListener, ListenBacklog);
  AddressLength := SizeOf(Address);
  fpGetSockName(FListener, @Address, @AddressLength);
  FPort := ntohs(Address.sin_port);
  FToken := NewToken;
  { macOS checks a newly linked program on its first start, which can take seconds: the
    driver polls instead of waiting here. }
  SetBlocking(FListener, False);
  Result := True;
end;

function TAgentLink.TryAccept: Boolean;
var
  Connection: TSocket;
  Received: Integer;
  Character: Char;
  Hello: string;
begin
  Result := False;
  Connection := fpAccept(FListener, nil, nil);
  if Connection = InvalidSocket then
    Exit;
  SetBlocking(Connection, True);
  Hello := '';
  repeat
    Received := fpRecv(Connection, @Character, 1, 0);
    if (Received <= 0) or (Character = LineEnd) then
      Break;
    Hello := Hello + Character;
  until Length(Hello) > MaximumGreetingLength;
  if Hello = Greeting(FToken) then
  begin
    FConnection := Connection;
    Result := True;
  end
  else
    CloseSocketHandle(Connection);
end;

function TAgentLink.Ask(const AFields: array of string): TStringList;
var
  Command, Line, Chunk: string;
  Sent, Transferred: Integer;
  Buffer: array[0..ReceiveBufferSize - 1] of Char;
begin
  Command := EncodeCommand(AFields);
  Sent := 1;
  while Sent <= Length(Command) do
  begin
    Transferred := fpSend(FConnection, @Command[Sent], Length(Command) - Sent + 1, 0);
    if Transferred <= 0 then
      Break;
    Inc(Sent, Transferred);
  end;
  Result := TStringList.Create;
  repeat
    if TakeLine(FReceived, Line) then
    begin
      if Line = ReplyEnd then
        Exit;
      Result.Add(Line);
      Continue;
    end;
    Transferred := fpRecv(FConnection, @Buffer[0], SizeOf(Buffer), 0);
    if Transferred <= 0 then
      Exit;
    SetLength(Chunk, Transferred);
    Move(Buffer[0], Chunk[1], Transferred);
    FReceived := FReceived + Chunk;
  until False;
end;

procedure TAgentLink.Base(const APath: string);
begin
  Ask([BaseCommand, TranslatePath(APath, FWinePaths)]).Free;
end;

function TAgentLink.Load(const APaths: TStrings): TStringList;
var
  Fields: array of string;
  I: Integer;
begin
  SetLength(Fields, APaths.Count + 1);
  Fields[0] := LoadCommand;
  for I := 0 to APaths.Count - 1 do
    Fields[I + 1] := TranslatePath(APaths[I], FWinePaths);
  Result := Ask(Fields);
end;


// ---------------------------------------------------------------- compiling
{ Everything hotfpc asks of the user's fpc. It checks the compiler's version, builds the agent
  unit, compiles the program (with linking or without), reads the errors out of the output,
  makes fpc recompile the units whose source changed, and removes the leftovers fpc makes in its
  working directory. fpc runs in the current directory, as the user would run it: relative paths
  in options and response files, and a fpc.cfg there, mean what they mean to fpc. }

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

{$I HotFPC.AgentSource.inc}

const
  AgentSourceFileName = 'HotFPC.Agent.pas';
  { fpc names the unit's files after its source file; some builds write them in lower case. }
  AgentRecordFileName = 'HotFPC.Agent.ppu';
  AgentRecordFileNameLower = 'hotfpc.agent.ppu';
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
      and (FileExists(FWorkspace.AgentDirectory + AgentRecordFileName)
        or FileExists(FWorkspace.AgentDirectory + AgentRecordFileNameLower));
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


// ---------------------------------------------------------------- the driver
{ One run of hotfpc. It builds the program with the agent, starts it, waits for its agent to
  connect, and then polls the sources: on every save it compiles, checks the interfaces, hands
  the changed object files to the agent, and prints what happened as [hot] lines. It owns the
  order of these steps and the wording of what it prints; the work is in the units it asks. }

const
  PortVariable = 'HOT_PORT';
  TokenVariable = 'HOT_TOKEN';
  PollIntervalMilliseconds = 10;
  AcceptIntervalMilliseconds = 5;
  SettleSlackMilliseconds = 2;
  DigestIntervalSeconds = 0.5;
  { macOS checks a newly linked executable on its first start (seconds, more under load); Wine
    starts its server the first time. }
  ConnectTimeoutSeconds = 60;
  MaximumShownErrors = 6;
  ObjectExtension = '.o';
  VerdictOK = 'ok';
  VerdictRefused = 'refused';
  VerdictFailed = 'failed';
  NotePrefix = 'note ';
  RestartPrefix = 'restart ';
  ReplyErrorPrefix = 'error ';

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

{ Runs hotfpc with the options until the program ends; the exit code for hotfpc. }
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
    else if (AVerdict <> VerdictRefused) and TAgentLink.ReplyDetail(AReply[I], ReplyErrorPrefix, Detail) then
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

// ---------------------------------------------------------------- main

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

{$ifdef HOTFPC_TESTS}
{$I HotFPC.Test.inc}
{$endif}

begin
  {$ifdef HOTFPC_TESTS}
  Halt(RunTests);
  {$else}
  Halt(RunHotFPC);
  {$endif}
end.
