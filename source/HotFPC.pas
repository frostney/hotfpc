program HotFPC;
{ hotfpc: hot reloading for Free Pascal programs, as a wrapper around fpc.

    hotfpc [--version] [--fpc FPC] [--ppudump PPUDUMP] [--run LAUNCHER] [--quiet]
           [--no-restart] [--settle MS] [--log FILE] [fpc options] program.pas
           [-- program arguments]

  Builds the program with the given fpc and two additions: its symbols are kept (-Xs-) and
  the agent unit is loaded first (-FaHotFPC.Agent). Starts it, watches the sources, and on
  every save recompiles and hands the changed object files to the agent inside the
  program, which swaps the code in and keeps the program's state, or says why it needs a
  restart. Then hotfpc links the program again and starts it over, without its state.

  The agent's source is part of this program. It is written out and compiled by the same
  fpc as the program, so hotfpc does not depend on the compiler's version. hotfpc needs
  fpc 3.2.2 or later.

  --fpc       the compiler (default: fpc)
  --ppudump   ppudump of the same compiler, for the check of layouts
              (default: next to the compiler; without one the check is off)
  --run       a program to start the built program with, such as wine (default: wine
              when the target is Windows and this is not)
  --settle    how long a save must stay unchanged before it is compiled (default 2 ms)
  --log       a copy of every line this program prints, with times
  --quiet     leave out the start line and the closing summary
  --no-restart  when an edit needs a restart, leave the program running its old code
              instead of starting it over
  --version   print hotfpc's version

  This file is the whole of hotfpc apart from the agent. HotFPC.Agent.pas is the agent's
  source, and HotFPC.rc makes it a resource of this program: fpcres compiles HotFPC.rc into
  HotFPC.res, which fpc links in. Compiled with -dHOTFPC_TESTS, the program runs its unit
  tests, at the end of this file, instead. }
{$mode delphi}{$H+}

uses
  {$ifdef unix}
  cthreads,
  BaseUnix,
  Unix,
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

{ False when the file cannot be read; AContents is then empty or partial. A file that a save
  is writing meanwhile gives what was there when it was opened, at most. }
function ReadFileContents(const APath: string; out AContents: string): Boolean;
var
  Stream: TFileStream;
  Size: Int64;
begin
  AContents := '';
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      { the size once: the file may grow before the read, and must not overflow the string }
      Size := Stream.Size;
      SetLength(AContents, Size);
      if Size > 0 then
        SetLength(AContents, Stream.Read(AContents[1], Size));
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

function StartsWith(const AText, APrefix: string): Boolean; inline;
begin
  Result := Copy(AText, 1, Length(APrefix)) = APrefix;
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
  HotFPCVersion = '1.1.0';
  UsageText = 'usage: hotfpc [--version] [--fpc FPC] [--ppudump PPUDUMP] [--run LAUNCHER] [--quiet] '
    + '[--no-restart] [--settle MS] [--log FILE] [fpc options] program.pas [-- program arguments]';
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
    FRestart: Boolean;
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
    { Whether an edit that needs a restart starts the program over (false with --no-restart). }
    property Restart: Boolean read FRestart;
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
  FRestart := True;
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
    else if Argument = '--no-restart' then
      FRestart := False
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
    FNextDirectory: string;
    FAssemblyDirectory: string;
    FExecutable: string;
    FNextExecutable: string;
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
    { Where a restart links the program, so that the running program and its file stay as
      they are until the link has worked. }
    property NextDirectory: string read FNextDirectory;
    { Where a Windows program is also compiled to assembler, for the sizes of its variables
      with initial values (see "sizes of initialised data"). }
    property AssemblyDirectory: string read FAssemblyDirectory;
    { The built program (no trailing delimiter). }
    property Executable: string read FExecutable;
    { The program a restart links, in NextDirectory. }
    property NextExecutable: string read FNextExecutable;
  end;

const
  HotDirectoryName = '.hot';
  UnitsDirectoryName = 'units';
  LiveDirectoryName = 'live';
  AgentDirectoryName = 'agent';
  AgentSourceDirectoryName = 'agent-src';
  NextDirectoryName = 'next';
  AssemblyDirectoryName = 'asm';
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
  FNextDirectory := FHotDirectory + NextDirectoryName + PathDelim;
  FAssemblyDirectory := FHotDirectory + AssemblyDirectoryName + PathDelim;
  FExecutable := FHotDirectory + FName;
  if ATargetWindows then
    FExecutable := FExecutable + WindowsExecutableExtension;
  FNextExecutable := FNextDirectory + ExtractFileName(FExecutable);
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
    { When the file was last written, in StampUnitsPerSecond since the system's epoch, as
      finely as the file system keeps it }
    Time: Int64;
  end;

  TFileStamps = array of TFileStamp;

  TSourceWatcher = class
  private
    FDirectories: TStringList;
    FStampedAt: Int64;
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
    { The system's clock, in the units and from the epoch of a stamp's time. }
    class function Clock: Int64;
    { Whether a write to one of the files after AAt (Clock) gives it another time, so that its
      stamp shows the write even when the content and the size are back to what they were:
      the time of each is older than AAt by more than the tick of the clock behind file times
      (StampGranuleSeconds), or two seconds for a time in whole seconds, as file systems
      such as FAT and HFS+ keep them. }
    class function TimesShowWrites(const AStamps: TFileStamps; const AAt: Int64): Boolean;
    { The files of ANew whose size or time differs from AOld's or that AOld lacks, and the
      files of AOld that ANew lacks. The caller frees the list. }
    class function ChangedStamps(const AOld, ANew: TFileStamps): TStringList;
    { Keeps AEmptied as the files a save emptied, ms=path, with the time ANow they were first
      seen so: a file of ANew that is empty and changed since AOld (another size or time, or
      new). A file with content again, or gone, leaves it. Each is kept by its whole path,
      with its case, as the stamps are: a path may have = in it. True while one of them was
      seen less than AWaitSeconds before ANow: an editor that empties a file before it writes
      it may have got only that far. }
    class function AwaitEmptied(const AOld, ANew: TFileStamps; const ANow, AWaitSeconds: Double;
      const AEmptied: TStrings): Boolean;
    { When the first of the waits of AEmptied (AwaitEmptied) that are not over at ANow ends,
      in seconds; 0 when there is none. }
    class function EmptiedDeadline(const AEmptied: TStrings; const ANow, AWaitSeconds: Double): Double;
    { The files whose digest differs between the two lists of path=digest, or that are new
      in ACurrent. APrevious may be nil: then every file is a change. Each file is kept by
      its whole path, with its case: a path may have = in it, and the digest has none. }
    class function ChangedFiles(const APrevious, ACurrent: TStrings): TStringList;
    { The paths of every watched source file, sorted, each with its case: two files whose
      names differ only in case are two files where the file system keeps both. The caller
      frees the list. }
    function Files: TStringList;
    { Names, sizes and times of the watched files, the times as finely as the file system
      keeps them; StampedAt is then the Clock before they were read. }
    function Stamps: TFileStamps;
    { The content of every watched file as path=digest, an empty file's too. False while a file
      is missing (a save in progress); ADigests is then nil. Otherwise the caller frees the
      list. }
    function ReadDigests(out ADigests: TStringList): Boolean;
    { The files that changed since the sources had AStamps and ADigests: another size or time,
      new or gone, or, for an edit of the same size within the same second, other content.
      ADigests may be nil; then only the sizes and times count. The caller frees the list. }
    function ChangedSince(const AStamps: TFileStamps; const ADigests: TStrings): TStringList;
    property Directories: TStringList read FDirectories;
    property StampedAt: Int64 read FStampedAt;
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
  {$ifdef windows}
  { a FILETIME counts 100 ns }
  StampUnitsPerSecond = 10000000;
  {$else}
  StampUnitsPerSecond = 1000000000;
  {$endif}
  { The clock behind file times ticks every 15.6 ms on Windows and every 1 to 10 ms on Linux:
    two writes within one tick give a file the same time. }
  StampGranuleSeconds = 0.02;
  { FAT keeps the time a file was written in steps of two seconds. }
  WholeSecondGranule = 2;

{$ifdef windows}
procedure GetSystemTimeAsFileTime(out ATime: Int64); stdcall; external 'kernel32' name 'GetSystemTimeAsFileTime';
{$endif}

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

class function TSourceWatcher.Clock: Int64;
{$ifdef unix}
var
  Now: TTimeVal;
{$endif}
begin
  {$ifdef windows}
  GetSystemTimeAsFileTime(Result);
  {$else}
  fpgettimeofday(@Now, nil);
  Result := Int64(Now.tv_sec) * StampUnitsPerSecond + Int64(Now.tv_usec) * (StampUnitsPerSecond div 1000000);
  {$endif}
end;

class function TSourceWatcher.TimesShowWrites(const AStamps: TFileStamps; const AAt: Int64): Boolean;
var
  I: Integer;
  Granule: Int64;
begin
  for I := 0 to High(AStamps) do
  begin
    if AStamps[I].Time mod StampUnitsPerSecond = 0 then
      Granule := WholeSecondGranule * StampUnitsPerSecond
    else
      Granule := Round(StampGranuleSeconds * StampUnitsPerSecond);
    if AStamps[I].Time > AAt - Granule then
      Exit(False);
  end;
  Result := True;
end;

class function TSourceWatcher.ChangedStamps(const AOld, ANew: TFileStamps): TStringList;
var
  Old: TStringList;
  I, K, Index: Integer;
begin
  Result := TStringList.Create;
  Old := TStringList.Create;
  try
    Old.CaseSensitive := True;
    Old.Sorted := True;
    for I := 0 to High(AOld) do
      Old.AddObject(AOld[I].Path, TObject(PtrInt(I)));
    for I := 0 to High(ANew) do
      if not Old.Find(ANew[I].Path, K) then
        Result.Add(ANew[I].Path)
      else
      begin
        Index := PtrInt(Old.Objects[K]);
        if (AOld[Index].Size <> ANew[I].Size) or (AOld[Index].Time <> ANew[I].Time) then
          Result.Add(ANew[I].Path);
        Old.Delete(K);
      end;
    for K := 0 to Old.Count - 1 do
      Result.Add(Old[K]);
  finally
    Old.Free;
  end;
end;

{ An entry of AwaitEmptied's list: the time, which has no =, then the path, which may. }
function EmptiedPath(const AEntry: string): string;
begin
  Result := Copy(AEntry, Pos('=', AEntry) + 1, MaxInt);
end;

function EmptiedTime(const AEntry: string): Int64;
begin
  Result := StrToInt64(Copy(AEntry, 1, Pos('=', AEntry) - 1));
end;

class function TSourceWatcher.AwaitEmptied(const AOld, ANew: TFileStamps; const ANow, AWaitSeconds: Double;
  const AEmptied: TStrings): Boolean;
var
  Changed, Empty, Paths: TStringList;
  I: Integer;
  Now: Int64;
begin
  { whole ms, rounded down: the next look AWaitSeconds after ANow finds the wait over }
  Now := Trunc(ANow * MillisecondsPerSecond);
  Changed := ChangedStamps(AOld, ANew);
  Empty := TStringList.Create;
  Paths := TStringList.Create;
  try
    Changed.CaseSensitive := True;
    Empty.CaseSensitive := True;
    Paths.CaseSensitive := True;
    for I := 0 to AEmptied.Count - 1 do
      Paths.Add(EmptiedPath(AEmptied[I]));
    for I := 0 to High(ANew) do
      if ANew[I].Size = 0 then
      begin
        Empty.Add(ANew[I].Path);
        if (Changed.IndexOf(ANew[I].Path) >= 0) and (Paths.IndexOf(ANew[I].Path) < 0) then
          AEmptied.Add(IntToStr(Now) + '=' + ANew[I].Path);
      end;
    for I := AEmptied.Count - 1 downto 0 do
      if Empty.IndexOf(EmptiedPath(AEmptied[I])) < 0 then
        AEmptied.Delete(I);
    Result := False;
    for I := 0 to AEmptied.Count - 1 do
      if Now - EmptiedTime(AEmptied[I]) < Round(AWaitSeconds * MillisecondsPerSecond) then
        Result := True;
  finally
    Paths.Free;
    Empty.Free;
    Changed.Free;
  end;
end;

class function TSourceWatcher.EmptiedDeadline(const AEmptied: TStrings; const ANow, AWaitSeconds: Double): Double;
var
  I: Integer;
  Now, Deadline: Int64;
  Seconds: Double;
begin
  { in whole ms, as AwaitEmptied counts }
  Now := Trunc(ANow * MillisecondsPerSecond);
  Result := 0;
  for I := 0 to AEmptied.Count - 1 do
  begin
    Deadline := EmptiedTime(AEmptied[I]) + Round(AWaitSeconds * MillisecondsPerSecond);
    { a Double first: an Int64 over MillisecondsPerSecond, a constant fpc gives the type
      Single, is a Single, too coarse for the clock }
    Seconds := Deadline;
    Seconds := Seconds / MillisecondsPerSecond;
    if (Deadline > Now) and ((Result = 0) or (Seconds < Result)) then
      Result := Seconds;
  end;
end;

{ An entry of a list of digests: the path, which may have =, then the digest, which has none. }
function DigestPath(const AEntry: string): string;
begin
  Result := Copy(AEntry, 1, LastDelimiter('=', AEntry) - 1);
end;

function DigestValue(const AEntry: string): string;
begin
  Result := Copy(AEntry, LastDelimiter('=', AEntry) + 1, MaxInt);
end;

class function TSourceWatcher.ChangedFiles(const APrevious, ACurrent: TStrings): TStringList;
var
  Previous: TStringList;
  I, K: Integer;
  Path, Value: string;
begin
  Result := TStringList.Create;
  Previous := TStringList.Create;
  try
    Previous.CaseSensitive := True;
    Previous.Sorted := True;
    if APrevious <> nil then
      for I := 0 to APrevious.Count - 1 do
        Previous.AddObject(DigestPath(APrevious[I]), TObject(PtrInt(I)));
    { Each value goes into a variable of its own first: fpc 3.3.1+3 for x86-64 gave the loop
      counter and the temporary result of ValueFromIndex the same register when this was one
      expression (docs/internals/how-it-works.md, "A compiler bug"). }
    for I := 0 to ACurrent.Count - 1 do
    begin
      Path := DigestPath(ACurrent[I]);
      Value := DigestValue(ACurrent[I]);
      if not Previous.Find(Path, K) or (DigestValue(APrevious[PtrInt(Previous.Objects[K])]) <> Value) then
        Result.Add(Path);
    end;
  finally
    Previous.Free;
  end;
end;

function TSourceWatcher.Files: TStringList;
var
  I: Integer;
  Search: TSearchRec;
  Prefix: string;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := True;
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
  {$ifdef windows}
  Search: TSearchRec;
  {$else}
  Info: TStat;
  {$endif}
begin
  Result := nil;
  FStampedAt := Clock;
  Watched := Files;
  try
    SetLength(Result, Watched.Count);
    for I := 0 to Watched.Count - 1 do
    begin
      Result[I].Path := Watched[I];
      Result[I].Size := -1;
      Result[I].Time := 0;
      {$ifdef windows}
      if FindFirst(Watched[I], faAnyFile, Search) = 0 then
      begin
        Result[I].Size := Search.Size;
        Result[I].Time := Int64(Search.FindData.ftLastWriteTime.dwHighDateTime) shl 32
          or Search.FindData.ftLastWriteTime.dwLowDateTime;
        FindClose(Search);
      end;
      {$else}
      if FpStat(Watched[I], Info) = 0 then
      begin
        Result[I].Size := Info.st_size;
        Result[I].Time := Int64(Info.st_mtime) * StampUnitsPerSecond
          {$if defined(linux)}
          + Int64(Info.st_mtime_nsec);
          {$elseif defined(darwin) or defined(bsd)}
          + Int64(Info.st_mtimensec);
          {$else}
          ;
          {$endif}
      end;
      {$endif}
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
      if not ReadFileContents(Watched[I], Contents) then
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

function TSourceWatcher.ChangedSince(const AStamps: TFileStamps; const ADigests: TStrings): TStringList;
var
  Digests, Changed: TStringList;
begin
  Result := ChangedStamps(AStamps, Stamps);
  { a file that is missing has already shown in the stamps }
  if (Result.Count > 0) or (ADigests = nil) or not ReadDigests(Digests) then
    Exit;
  try
    Changed := ChangedFiles(ADigests, Digests);
    try
      Result.AddStrings(Changed);
    finally
      Changed.Free;
    end;
  finally
    Digests.Free;
  end;
end;


// ---------------------------------------------------------------- layouts (ppudump)
{ The check of layouts. A field that moved or changed its type without changing a
  size is invisible in the object file, so hotfpc reads each changed unit with ppudump and
  compares it with the unit that is running. A layout is one unit as the compiler wrote it
  down: name=text for the layout of each record or class type and the type of each variable,
  of the interface (ppudump's JSON) and of the implementation section (its text, as the JSON
  leaves the section out). Two texts differ exactly when a field was added, removed, moved
  or retyped, or a variable changed its type. On Windows, where a COFF object states no
  sizes, the type also shows a variable with an initial value that grows inside the 16 bytes
  fpc pads its section to; the check of sizes covers the ones no unit file has (see "sizes
  of initialised data"). }

type
  TLayout = TStringList;

  { Runs ppudump and turns its output into layouts. }
  TLayoutReader = class
  private
    FPPUDump: string;
  protected
    { The JSON ppudump prints for a unit file, errors included. }
    function Dump(const APPUPath: string): string; virtual;
    { The text ppudump prints for a unit file by default, errors included. }
    function DumpText(const APPUPath: string): string; virtual;
  public
    constructor Create(const APPUDump: string);
    { The ppudump next to the compiler (the named one's folder, or the first in ASearchPath
      when the compiler is a bare name), or '' when there is none. AExecutableExtension is
      '.exe' on Windows, where a bare name such as fpc is found as fpc.exe. }
    class function Locate(const ACompiler, AExecutableExtension, ASearchPath: string): string;
    { A ppudump that cannot read this compiler's units (another version: "Unsupported PPU
      version") would make every interface look unchanged. Tries it on one of the units in
      AUnitsDirectory; True when it works or there is no unit yet, otherwise False and
      AReason is the first line it printed. }
    function Probe(const AUnitsDirectory: string; out AReason: string): Boolean;
    { The layout of a unit file, its interface and its implementation section. Units of the
      program that it refers to are looked for in AOwnDirectory: their numbering moves
      between compiles, their names do not. The caller frees the layout. }
    function Read(const APPUPath, AOwnDirectory: string): TLayout;
    { Reads ppudump's JSON, as Dump returns it, as the layout of the interface; AOwnDirectory
      as for Read. }
    function ReadJSON(const AJSON, AOwnDirectory: string): TLayout;
    { Reads ppudump's text, as DumpText returns it, as the layout of the implementation
      section; AOwnDirectory as for Read. }
    function ReadText(const AText, AOwnDirectory: string): TLayout;
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

{ ppudump's text is a list of blocks: "** Definition Id 5 **" or "** Symbol Id 8 **", a line
  that says what it is ("Record definition", "Global Variable symbol Calls") and "key : value"
  lines. A block indented by four more is inside the one before it, as a record's fields are.
  A reference is "(offset) DefId 5" for a definition of the unit and "(offset) Unit 0, DefId
  8" for one of the unit that the DerefMap numbers 0. The numbers move between compiles. }

const
  DefinitionHeader = '** Definition Id ';
  SymbolHeader = '** Symbol Id ';
  HeaderEnd = ' **';
  DerefMapEntry = 'DerefMap[';
  StaticSymbolsTitle = 'Static Symbols';
  NestingIndent = 4;
  MaximumNesting = 8;
  UnitReference = 'Unit ';
  DefinitionReference = 'DefId ';
  NilReference = 'Nil';
  SymbolReferenceText = 'symbol';
  VariableKind = 'Global Variable symbol ';
  TypeKind = 'Type symbol ';
  FieldKind = 'Field Variable symbol ';
  RecordKind = 'Record definition';
  ClassKind = 'Object/Class definition';
  VariableTypeKey = 'Var Type';
  ResultTypeKey = 'Result Type';
  AddressKey = 'Address';
  RecordNameKey = 'Name of Record';
  ClassNameKey = 'Name of Class';
  { Keys that differ between compiles, follow from how the code uses a type, or are names. }
  IgnoredTextKeys: array[0..18] of string = ('Type symbol', 'DefOptions', 'DefStates', 'File Pos',
    'Visibility', 'SymOptions', 'Procsym', 'Class', 'VmtField', 'Import Nr', 'Number', 'Level',
    'Mangled name', 'Alias names', 'Symtable options', 'Symtable count', 'Symtable level',
    RecordNameKey, ClassNameKey);

type
  { One block of ppudump's text. }
  TDumpBlock = class
  private
    FKind: string;
    FValues: TStringList;
    FChildren: TList;
  public
    constructor Create;
    destructor Destroy; override;
    property Kind: string read FKind write FKind;
    { The "key : value" lines as key=value, in their order. }
    property Values: TStringList read FValues;
    { The blocks inside this one. }
    property Children: TList read FChildren;
  end;

  { One unit file as ppudump's text describes it. }
  TUnitText = class
  private
    FBlocks: TObjectList;
    FUnits: TStringList;
    FDefinitions: TStringList;
    FStaticSymbols: TList;
    procedure Parse(const AText: string);
  public
    constructor Create(const AText: string);
    destructor Destroy; override;
    { The unit's definition with that number, or nil. }
    function Definition(const AIdentifier: string): TDumpBlock;
    { The units that references number, from the DerefMap. }
    property Units: TStringList read FUnits;
    { The symbols of the implementation section. }
    property StaticSymbols: TList read FStaticSymbols;
  end;

  { One reading of the implementation section of one unit file, with the units of the
    program it refers to. }
  TImplementationBuilder = class
  private
    FReader: TLayoutReader;
    FOwnDirectory: string;
    FOthers: TStringList;
    function Other(const AUnitName: string): TUnitText;
    function Reference(const AText: TUnitText; const AValue: string; const ADepth: Integer): string;
    function Describe(const AText: TUnitText; const AIdentifier, APrefix: string; const ADepth: Integer): string;
    function Canonical(const AText: TUnitText; const ABlock: TDumpBlock; const ADepth: Integer): string;
  public
    constructor Create(const AReader: TLayoutReader; const AOwnDirectory: string);
    destructor Destroy; override;
    function Build(const AText: string): TLayout;
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

{ A value without the offset that ppudump puts in front of a reference. }
function WithoutOffset(const AValue: string): string;
begin
  Result := Trim(AValue);
  if (Result <> '') and (Result[1] = '(') and (Pos(')', Result) > 0) then
    Result := Trim(Copy(Result, Pos(')', Result) + 1, MaxInt));
end;

function IsIgnoredTextKey(const AKey: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(IgnoredTextKeys) do
    if AKey = IgnoredTextKeys[I] then
      Exit(True);
end;

constructor TDumpBlock.Create;
begin
  inherited Create;
  FValues := TStringList.Create;
  FChildren := TList.Create;
end;

destructor TDumpBlock.Destroy;
begin
  FChildren.Free;
  FValues.Free;
  inherited Destroy;
end;

constructor TUnitText.Create(const AText: string);
begin
  inherited Create;
  FBlocks := TObjectList.Create(True);
  FUnits := TStringList.Create;
  FDefinitions := TStringList.Create;
  FDefinitions.Sorted := True;
  FDefinitions.Duplicates := dupIgnore;
  FStaticSymbols := TList.Create;
  Parse(AText);
end;

destructor TUnitText.Destroy;
begin
  FStaticSymbols.Free;
  FDefinitions.Free;
  FUnits.Free;
  FBlocks.Free;
  inherited Destroy;
end;

procedure TUnitText.Parse(const AText: string);
var
  Lines: TStringList;
  I, K, Depth, Separator, UnitIndex: Integer;
  Line, Trimmed, Section, Identifier: string;
  Block: TDumpBlock;
  Open: array[0..MaximumNesting] of TDumpBlock;
  KindNext: Boolean;
begin
  for K := 0 to MaximumNesting do
    Open[K] := nil;
  Section := '';
  Block := nil;
  KindNext := False;
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      Trimmed := Trim(Line);
      if Trimmed = '' then
        Continue;
      { a title is underlined from the start of the line; it ends the block before it }
      if (Line[1] = '-') and (Trimmed = StringOfChar('-', Length(Trimmed))) then
      begin
        if I > 0 then
          Section := Trim(Lines[I - 1]);
        Block := nil;
        Continue;
      end;
      if StartsWith(Trimmed, DefinitionHeader) or StartsWith(Trimmed, SymbolHeader) then
      begin
        Depth := (Length(Line) - Length(TrimLeft(Line))) div NestingIndent;
        if Depth > MaximumNesting then
          Depth := MaximumNesting;
        Block := TDumpBlock.Create;
        FBlocks.Add(Block);
        Open[Depth] := Block;
        for K := Depth + 1 to MaximumNesting do
          Open[K] := nil;
        if (Depth > 0) and (Open[Depth - 1] <> nil) then
          Open[Depth - 1].Children.Add(Block);
        if StartsWith(Trimmed, DefinitionHeader) then
        begin
          Identifier := Copy(Trimmed, Length(DefinitionHeader) + 1,
            Length(Trimmed) - Length(DefinitionHeader) - Length(HeaderEnd));
          FDefinitions.AddObject(Identifier, Block);
        end
        else if (Depth = 0) and (Section = StaticSymbolsTitle) then
          FStaticSymbols.Add(Block);
        KindNext := True;
        Continue;
      end;
      if Block = nil then
      begin
        if StartsWith(Trimmed, DerefMapEntry) then
        begin
          UnitIndex := StrToIntDef(Copy(Trimmed, Length(DerefMapEntry) + 1,
            Pos(']', Trimmed) - Length(DerefMapEntry) - 1), -1);
          if UnitIndex >= 0 then
          begin
            while FUnits.Count <= UnitIndex do
              FUnits.Add('');
            FUnits[UnitIndex] := Trim(Copy(Trimmed, Pos('=', Trimmed) + 1, MaxInt));
          end;
        end;
        Continue;
      end;
      if KindNext then
      begin
        Block.Kind := Trimmed;
        KindNext := False;
        Continue;
      end;
      Separator := Pos(':', Trimmed);
      if Separator > 0 then
        Block.Values.Add(Trim(Copy(Trimmed, 1, Separator - 1)) + '=' + Trim(Copy(Trimmed, Separator + 1, MaxInt)));
    end;
  finally
    Lines.Free;
  end;
end;

function TUnitText.Definition(const AIdentifier: string): TDumpBlock;
var
  Index: Integer;
begin
  Index := FDefinitions.IndexOf(AIdentifier);
  if Index < 0 then
    Result := nil
  else
    Result := TDumpBlock(FDefinitions.Objects[Index]);
end;

constructor TImplementationBuilder.Create(const AReader: TLayoutReader; const AOwnDirectory: string);
begin
  inherited Create;
  FReader := AReader;
  FOwnDirectory := AOwnDirectory;
  FOthers := TStringList.Create;
end;

destructor TImplementationBuilder.Destroy;
var
  I: Integer;
begin
  for I := 0 to FOthers.Count - 1 do
    FOthers.Objects[I].Free;
  FOthers.Free;
  inherited Destroy;
end;

{ The text of a unit of the program, or nil for a unit that is not the program's (the
  runtime's units don't change while it runs). }
function TImplementationBuilder.Other(const AUnitName: string): TUnitText;
var
  Index: Integer;
  UnitRecord: string;
begin
  Index := FOthers.IndexOf(AUnitName);
  if Index < 0 then
  begin
    UnitRecord := FindFileIgnoringCase(FOwnDirectory, AUnitName + PPUExtension);
    if UnitRecord = '' then
      Index := FOthers.AddObject(AUnitName, nil)
    else
      Index := FOthers.AddObject(AUnitName, TUnitText.Create(FReader.DumpText(UnitRecord)));
  end;
  Result := TUnitText(FOthers.Objects[Index]);
end;

function TImplementationBuilder.Reference(const AText: TUnitText; const AValue: string;
  const ADepth: Integer): string;
var
  Value, UnitName: string;
  Comma, UnitIndex: Integer;
  OtherText: TUnitText;
begin
  Value := WithoutOffset(AValue);
  if Value = NilReference then
    Exit(NilReference);
  if StartsWith(Value, UnitReference) then
  begin
    Comma := Pos(',', Value);
    UnitIndex := StrToIntDef(Copy(Value, Length(UnitReference) + 1, Comma - Length(UnitReference) - 1), -1);
    if (Comma = 0) or (UnitIndex < 0) or (UnitIndex >= AText.Units.Count) then
      Exit(UnknownType);
    UnitName := AText.Units[UnitIndex];
    Value := Trim(Copy(Value, Comma + 1, MaxInt));
    if not StartsWith(Value, DefinitionReference) then
      Exit(SymbolReferenceText);
    Value := Copy(Value, Length(DefinitionReference) + 1, MaxInt);
    OtherText := Other(UnitName);
    if OtherText = nil then
      Exit(UnitName + '#' + Value);
    Exit(Describe(OtherText, Value, UnitName + '.', ADepth));
  end;
  if StartsWith(Value, DefinitionReference) then
    Exit(Describe(AText, Copy(Value, Length(DefinitionReference) + 1, MaxInt), '', ADepth));
  Result := SymbolReferenceText;
end;

{ A definition as its name when it is a named record or class, which has a layout of its
  own, and as its whole text otherwise: an array's or a set's size is in its text. }
function TImplementationBuilder.Describe(const AText: TUnitText; const AIdentifier, APrefix: string;
  const ADepth: Integer): string;
var
  Block: TDumpBlock;
  Name: string;
begin
  Block := AText.Definition(AIdentifier);
  if Block = nil then
    Exit(APrefix + '#' + AIdentifier);
  Name := Block.Values.Values[RecordNameKey];
  if Name = '' then
    Name := Block.Values.Values[ClassNameKey];
  if (Name <> '') and (Name[1] <> '$') then
    Exit(APrefix + Name);
  Result := Canonical(AText, Block, ADepth + 1);
end;

function TImplementationBuilder.Canonical(const AText: TUnitText; const ABlock: TDumpBlock;
  const ADepth: Integer): string;
var
  Lines: TStringList;
  I: Integer;
  Key, Value: string;
  Field: TDumpBlock;
begin
  if ADepth > MaximumDepth then
    Exit(DepthLimitMarker);
  Lines := TStringList.Create;
  try
    { ppudump prints some keys twice in different case (RecordAlignMin, recordalignmin) }
    Lines.CaseSensitive := True;
    for I := 0 to ABlock.Values.Count - 1 do
    begin
      Key := ABlock.Values.Names[I];
      if IsIgnoredTextKey(Key) then
        Continue;
      Value := ABlock.Values.ValueFromIndex[I];
      if (Value <> '') and (Value[1] = '(') then
        Value := Reference(AText, Value, ADepth);
      Lines.Add(Key + '=' + Value);
    end;
    Lines.Sort;
    Result := '{' + ABlock.Kind;
    for I := 0 to Lines.Count - 1 do
      Result := Result + ' ' + Lines[I];
    for I := 0 to ABlock.Children.Count - 1 do
    begin
      Field := TDumpBlock(ABlock.Children[I]);
      if StartsWith(Field.Kind, FieldKind) then
        Result := Result + ' ' + Copy(Field.Kind, Length(FieldKind) + 1, MaxInt) + ':'
          + Reference(AText, Field.Values.Values[VariableTypeKey], ADepth) + '@' + Field.Values.Values[AddressKey];
    end;
    Result := Result + ' }';
  finally
    Lines.Free;
  end;
end;

function TImplementationBuilder.Build(const AText: string): TLayout;
var
  Text: TUnitText;
  I: Integer;
  Symbol, Definition: TDumpBlock;
  Name, Value: string;
begin
  Result := TLayout.Create;
  Text := TUnitText.Create(AText);
  try
    for I := 0 to Text.StaticSymbols.Count - 1 do
    begin
      Symbol := TDumpBlock(Text.StaticSymbols[I]);
      if StartsWith(Symbol.Kind, VariableKind) then
      begin
        Name := Copy(Symbol.Kind, Length(VariableKind) + 1, MaxInt);
        if (Name <> '') and (Name[1] <> '$') then
          Result.Values[VariablePrefix + Name] := Reference(Text, Symbol.Values.Values[VariableTypeKey], 0);
      end
      else if StartsWith(Symbol.Kind, TypeKind) then
      begin
        Name := Copy(Symbol.Kind, Length(TypeKind) + 1, MaxInt);
        Value := WithoutOffset(Symbol.Values.Values[ResultTypeKey]);
        if (Name = '') or (Name[1] = '$') or not StartsWith(Value, DefinitionReference) then
          Continue;
        Definition := Text.Definition(Copy(Value, Length(DefinitionReference) + 1, MaxInt));
        if (Definition <> nil) and ((Definition.Kind = RecordKind) or (Definition.Kind = ClassKind)) then
          Result.Values[TypePrefix + Name] := Canonical(Text, Definition, 0);
      end;
    end;
  finally
    Text.Free;
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

function TLayoutReader.DumpText(const APPUPath: string): string;
begin
  Result := '';
  RunCommand(FPPUDump, [APPUPath], Result, [poStderrToOutPut]);
end;

class function TLayoutReader.Locate(const ACompiler, AExecutableExtension, ASearchPath: string): string;
var
  Directory, Found: string;
begin
  Result := '';
  Directory := ExtractFilePath(ACompiler);
  if Directory = '' then
  begin
    Found := ExeSearch(ACompiler, ASearchPath);
    if (Found = '') and (ExtractFileExt(ACompiler) = '') then
      Found := ExeSearch(ACompiler + AExecutableExtension, ASearchPath);
    Directory := ExtractFilePath(Found);
  end;
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
var
  Section: TLayout;
begin
  Result := ReadJSON(Dump(APPUPath), AOwnDirectory);
  Section := ReadText(DumpText(APPUPath), AOwnDirectory);
  try
    Result.AddStrings(Section);
  finally
    Section.Free;
  end;
end;

function TLayoutReader.ReadText(const AText, AOwnDirectory: string): TLayout;
var
  Builder: TImplementationBuilder;
begin
  Builder := TImplementationBuilder.Create(Self, AOwnDirectory);
  try
    Result := Builder.Build(AText);
  finally
    Builder.Free;
  end;
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


// ---------------------------------------------------------------- sizes of initialised data (assembler)
{ The check of sizes for a Windows program. fpc gives every variable with an initial value
  and every typed constant a section of its own and pads it to 16 bytes, and a COFF object
  states no symbol sizes, so one that grows inside the padding (Integer = 0 to Int64 = 0)
  looks the same in the object file. On the other systems the agent finds the size in the
  object file. The unit file names the type, but fpc writes none for the program, a
  routine's typed constant is never in it, and fpc 3.2 leaves out an implementation
  section's typed constant too. fpc's assembler output (-s -Aas) has every one of them as a
  label followed by its data, so for a Windows program hotfpc also compiles to assembler,
  into .hot/asm, and compares the sizes it counts there with the running program's. A size
  is name=bytes, under the label's name (TC_$U_$$_CALLS). The running program's sizes are
  those it started with, and those of the labels that swaps added, each as the program first
  had it: the agent keeps a variable at its first address, also when a save removed it and a
  later one brings it back. The object file names the data the assembler must give a size
  for: a section of its own for each (.data.n_TC_$U_$$_CALLS). A datum it names that the
  assembler has no size for has an unknown size (name=?), and a save that changes a unit
  with one needs a restart: an unknown size is never taken as the same. }

type
  TDataSizes = class
  public
    { Whether an object file has a variable with an initial value or a typed constant: fpc
      names each one TC_$..., in COFF as a section's name or a symbol's. }
    class function HasInitialisedData(const AObjectPath: string): Boolean;
    { Adds to ANames the variables with an initial value and the typed constants a COFF
      object defines, by fpc's TC_$ names: each section of one (.data.n_TC_$U_$$_CALLS) and
      each symbol of one it defines. False when the file cannot be read or is no COFF object
      that has them; ANames is then incomplete. }
    class function ObjectNames(const AObjectPath: string; const ANames: TStrings): Boolean;
    { name=bytes for every TC_$ label of fpc's assembler text, name=? (UnknownSize) for one
      followed by a directive it does not know. The caller frees the list. }
    class function Read(const AAssembler: string): TStringList;
    { The bytes of the string of a .ascii line. }
    class function StringBytes(const ALine: string): Integer;
    { The restart reasons between two lists of sizes: "variable U.CALLS changed size from 4
      to 8 bytes" for each name both have, and one for each name of ANew whose size either
      list has as unknown. A name only AOld has, or only ANew with a known size, is no change.
      The caller frees the list. }
    class function Changes(const AOld, ANew: TStrings): TStringList;
    { Adds to ASizes the sizes in AAdded of the names ASizes doesn't have; a name it has keeps
      its size. }
    class procedure Keep(const ASizes, AAdded: TStrings);
    { A label as the agent prints names: TC_$U_$$_CALLS is U.CALLS, and
      TC_$U$_$TICK$LONGINT$$LONGINT_$$_N is U.TICK(LONGINT):LONGINT.N. }
    class function Pretty(const AName: string): string;
  end;

const
  AssemblerExtension = '.s';
  InitialisedDataPrefix = 'TC_$';
  { a size the assembler does not give }
  UnknownSize = '?';
  UnknownSizes = 'the sizes of variables with initial values are unknown: ';
  UnseenSaves = 'the times of the sources may not show a save while fpc compiled them';
  { fpc's section of a datum: its kind, this, and the datum's name (.data.n_TC_$U_$$_CALLS) }
  DatumSectionInfix = '.n_';
  { the parts of a COFF object (the PE/COFF specification) the names are read from }
  COFFHeaderBytes = 20;
  COFFSectionCountOffset = 2;
  COFFSymbolTableOffset = 8;
  COFFSymbolCountOffset = 12;
  COFFOptionalHeaderOffset = 16;
  COFFSectionBytes = 40;
  COFFSymbolBytes = 18;
  COFFShortNameBytes = 8;
  COFFSymbolSectionOffset = 12;
  COFFSymbolAuxiliaryOffset = 17;
  { a section name longer than 8 bytes: / and its offset in the string table, in decimal }
  COFFLongSectionName = '/';
  ProgramPrefix = 'P$';
  SectionDirective = '.section';
  GlobalDirective = '.globl';
  StringDirective = '.ascii';
  { the data directives fpc writes, and the bytes of each value they list }
  DataDirectives: array[0..6] of string = ('.byte', '.short', '.word', '.long', '.rva', '.secrel32', '.quad');
  DataWidths: array[0..6] of Integer = (1, 2, 2, 4, 4, 4, 8);
  { directives for a number of zero bytes }
  FillDirectives: array[0..1] of string = ('.zero', '.skip');
  AssemblerComment = '#';
  LabelEnd = ':';
  OperandSeparator = ',';
  StringQuote = '"';
  StringEscape = '\';
  OctalDigits = ['0'..'7'];
  OctalEscapeLength = 3;

class function TDataSizes.HasInitialisedData(const AObjectPath: string): Boolean;
var
  Contents: string;
begin
  Result := ReadFileContents(AObjectPath, Contents) and (Pos(InitialisedDataPrefix, Contents) > 0);
end;

class function TDataSizes.ObjectNames(const AObjectPath: string; const ANames: TStrings): Boolean;
var
  Contents, Name: string;
  Sections, OptionalBytes, SymbolTable, Symbols, Strings, Offset, Section, Auxiliary, StringOffset: Int64;
  I: Integer;

  { the little-endian number of ABytes bytes at AOffset; False past the end of the file }
  function Field(const AOffset, ABytes: Int64; out AValue: Int64): Boolean;
  var
    K: Integer;
  begin
    AValue := 0;
    Result := (AOffset >= 0) and (AOffset + ABytes <= Length(Contents));
    if Result then
      for K := ABytes - 1 downto 0 do
        AValue := (AValue shl 8) or Ord(Contents[AOffset + 1 + K]);
  end;

  { the string at AOffset of the string table, up to its NUL }
  function LongName(const AOffset: Int64; out AName: string): Boolean;
  var
    Last: Int64;
  begin
    AName := '';
    Result := (Strings >= 0) and (AOffset >= 0) and (Strings + AOffset < Length(Contents));
    if not Result then
      Exit;
    Last := Strings + AOffset;
    while (Last < Length(Contents)) and (Contents[Last + 1] <> #0) do
      Inc(Last);
    Result := Last < Length(Contents);
    AName := Copy(Contents, Strings + AOffset + 1, Last - Strings - AOffset);
  end;

  function ShortName(const AOffset: Int64): string;
  begin
    Result := Copy(Contents, AOffset + 1, COFFShortNameBytes);
    if Pos(#0, Result) > 0 then
      SetLength(Result, Pos(#0, Result) - 1);
  end;

  procedure Add(const AName: string);
  begin
    if ANames.IndexOf(AName) < 0 then
      ANames.Add(AName);
  end;

begin
  Result := False;
  if not ReadFileContents(AObjectPath, Contents) then
    Exit;
  Result := True;
  if Pos(InitialisedDataPrefix, Contents) = 0 then
    Exit;
  Result := False;
  if not (Field(COFFSectionCountOffset, 2, Sections) and Field(COFFSymbolTableOffset, 4, SymbolTable)
    and Field(COFFSymbolCountOffset, 4, Symbols) and Field(COFFOptionalHeaderOffset, 2, OptionalBytes)) then
    Exit;
  { the string table follows the symbols }
  Strings := SymbolTable + Symbols * COFFSymbolBytes;
  if (SymbolTable = 0) or (Strings + 4 > Length(Contents)) then
    Strings := -1;
  for I := 0 to Sections - 1 do
  begin
    Offset := COFFHeaderBytes + OptionalBytes + Int64(I) * COFFSectionBytes;
    if Offset + COFFSectionBytes > Length(Contents) then
      Exit;
    Name := ShortName(Offset);
    if (Copy(Name, 1, Length(COFFLongSectionName)) = COFFLongSectionName) then
    begin
      StringOffset := StrToInt64Def(Copy(Name, Length(COFFLongSectionName) + 1, MaxInt), -1);
      if not LongName(StringOffset, Name) then
        Exit;
    end;
    if Pos(DatumSectionInfix + InitialisedDataPrefix, Name) > 0 then
      Add(Copy(Name, Pos(DatumSectionInfix + InitialisedDataPrefix, Name) + Length(DatumSectionInfix), MaxInt));
  end;
  I := 0;
  while I < Symbols do
  begin
    Offset := SymbolTable + Int64(I) * COFFSymbolBytes;
    if not (Field(Offset + COFFSymbolSectionOffset, 2, Section) and Field(Offset + COFFSymbolAuxiliaryOffset, 1, Auxiliary)) then
      Exit;
    { the first four bytes zero: the name is in the string table, at the next four }
    if Field(Offset, 4, StringOffset) and (StringOffset = 0) then
    begin
      if not (Field(Offset + 4, 4, StringOffset) and LongName(StringOffset, Name)) then
        Exit;
    end
    else
      Name := ShortName(Offset);
    { a section number of 1 or more (signed): defined here; 0 is an undefined reference to
      another unit's }
    if StartsWith(Name, InitialisedDataPrefix) and (Section > 0) and (Section < $8000) then
      Add(Name);
    Inc(I, 1 + Auxiliary);
  end;
  Result := True;
end;

class function TDataSizes.StringBytes(const ALine: string): Integer;
var
  First, Last, Index, Digits: Integer;
begin
  Result := 0;
  First := Pos(StringQuote, ALine);
  Last := Length(ALine);
  while (Last > First) and (ALine[Last] <> StringQuote) do
    Dec(Last);
  Index := First + 1;
  while Index < Last do
  begin
    if ALine[Index] = StringEscape then
    begin
      { \000 is one byte in octal; \" and \\ are one character }
      Digits := 0;
      while (Digits < OctalEscapeLength) and (Index + 1 + Digits < Last) and (ALine[Index + 1 + Digits] in OctalDigits) do
        Inc(Digits);
      if Digits > 0 then
        Inc(Index, 1 + Digits)
      else
        Inc(Index, 2);
    end
    else
      Inc(Index);
    Inc(Result);
  end;
end;

class function TDataSizes.Read(const AAssembler: string): TStringList;
var
  Lines: TStringList;
  I, K, Space, Bytes: Integer;
  Line, Directive, Operands, Current: string;
  Size: Int64;
  Known, Counted: Boolean;
  Sizes: TStringList;

  procedure Finish;
  begin
    if (Current <> '') and Known then
      Sizes.Add(Current + '=' + IntToStr(Size))
    else if Current <> '' then
      Sizes.Add(Current + '=' + UnknownSize);
    Current := '';
  end;

begin
  Sizes := TStringList.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := AAssembler;
    Current := '';
    Size := 0;
    Known := False;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if (Line = '') or StartsWith(Line, AssemblerComment) then
        Continue;
      Space := Pos(' ', StringReplace(Line, #9, ' ', [rfReplaceAll]));
      { a label: one word that ends in a colon }
      if (Space = 0) and (Line[Length(Line)] = LabelEnd) then
      begin
        Finish;
        if StartsWith(Line, InitialisedDataPrefix) then
        begin
          Current := Copy(Line, 1, Length(Line) - 1);
          Size := 0;
          Known := True;
        end;
        Continue;
      end;
      if Space = 0 then
      begin
        Directive := Line;
        Operands := '';
      end
      else
      begin
        Directive := Copy(Line, 1, Space - 1);
        Operands := Trim(Copy(Line, Space + 1, MaxInt));
      end;
      if Directive = SectionDirective then
      begin
        Finish;
        Continue;
      end;
      if (Current = '') or (Directive = GlobalDirective) then
        Continue;
      Counted := False;
      for K := 0 to High(DataDirectives) do
        if (Directive = DataDirectives[K]) and (Operands <> '') then
        begin
          Inc(Size, Int64(DataWidths[K])
            * (1 + Length(Operands) - Length(StringReplace(Operands, OperandSeparator, '', [rfReplaceAll]))));
          Counted := True;
        end;
      for K := 0 to High(FillDirectives) do
        if Directive = FillDirectives[K] then
        begin
          Bytes := StrToIntDef(Trim(Copy(Operands, 1, Pos(OperandSeparator, Operands + OperandSeparator) - 1)), -1);
          if Bytes >= 0 then
          begin
            Inc(Size, Bytes);
            Counted := True;
          end;
        end;
      if Directive = StringDirective then
      begin
        Inc(Size, StringBytes(Line));
        Counted := True;
      end;
      if not Counted then
        Known := False;
    end;
    Finish;
  finally
    Lines.Free;
  end;
  Result := Sizes;
end;

class function TDataSizes.Changes(const AOld, ANew: TStrings): TStringList;
var
  I: Integer;
  Name: string;
begin
  Result := TStringList.Create;
  for I := 0 to ANew.Count - 1 do
  begin
    Name := ANew.Names[I];
    if ANew.ValueFromIndex[I] = UnknownSize then
      Result.Add(UnknownSizes + 'fpc''s assembler has no size for ' + Pretty(Name))
    else if AOld.IndexOfName(Name) < 0 then
      Continue
    else if AOld.Values[Name] = UnknownSize then
      Result.Add(UnknownSizes + 'the assembler the program started from had no size for ' + Pretty(Name))
    else if AOld.Values[Name] <> ANew.ValueFromIndex[I] then
      Result.Add('variable ' + Pretty(Name) + ' changed size from ' + AOld.Values[Name] + ' to '
        + ANew.ValueFromIndex[I] + ' bytes');
  end;
end;

class procedure TDataSizes.Keep(const ASizes, AAdded: TStrings);
var
  I: Integer;
begin
  for I := 0 to AAdded.Count - 1 do
    if ASizes.IndexOfName(AAdded.Names[I]) < 0 then
      ASizes.Add(AAdded[I]);
end;

class function TDataSizes.Pretty(const AName: string): string;
var
  Text: string;
  Index: Integer;
  Open: Boolean;
begin
  Text := AName;
  if StartsWith(Text, InitialisedDataPrefix) then
    Delete(Text, 1, Length(InitialisedDataPrefix));
  if StartsWith(Text, ProgramPrefix) then
    Delete(Text, 1, Length(ProgramPrefix));
  Result := '';
  Open := False;
  Index := 1;
  while Index <= Length(Text) do
  begin
    if Copy(Text, Index, 4) = '_$$_' then
    begin
      { the routine's parameters end where the constant's name begins }
      if Open then
        Result := Result + ')';
      Open := False;
      Result := Result + '.';
      Inc(Index, 4);
    end
    else if Copy(Text, Index, 3) = '$_$' then
    begin
      Result := Result + '.';
      Inc(Index, 3);
    end
    else if Copy(Text, Index, 4) = '_$__' then
      Inc(Index, 4)
    else if Copy(Text, Index, 2) = '$$' then
    begin
      if Open then
        Result := Result + ')';
      Result := Result + ':';
      Open := False;
      Inc(Index, 2);
    end
    else if Text[Index] = '$' then
    begin
      if Open then
        Result := Result + ','
      else
        Result := Result + '(';
      Open := True;
      Inc(Index);
    end
    else
    begin
      Result := Result + Text[Index];
      Inc(Index);
    end;
  end;
  if Open then
    Result := Result + ')';
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
    { Closes the connection of a program that has ended. The driver keeps listening, so a
      restarted program connects with the same port and token. }
    procedure Disconnect;
    { Waits up to ATimeoutSeconds for the program's end of the connection to close, which it
      does when the program's process has ended. True once it has, or without a connection. }
    function AwaitClosed(const ATimeoutSeconds: Double): Boolean;
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
  CloseIntervalMilliseconds = 5;

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

procedure TAgentLink.Disconnect;
begin
  if FConnection <> InvalidSocket then
    CloseSocketHandle(FConnection);
  FConnection := InvalidSocket;
  FReceived := '';
end;

function TAgentLink.AwaitClosed(const ATimeoutSeconds: Double): Boolean;
var
  Deadline: Double;
  Received: Integer;
  Character: Char;
begin
  if FConnection = InvalidSocket then
    Exit(True);
  SetBlocking(FConnection, False);
  Deadline := NowSeconds + ATimeoutSeconds;
  repeat
    Received := fpRecv(FConnection, @Character, 1, 0);
    { 0: closed; an error other than "nothing yet": reset }
    if (Received = 0) or ((Received < 0) and (Sockets.SocketError <> Sockets.EsockEWOULDBLOCK)) then
      Exit(True);
    if (Received < 0) and (NowSeconds > Deadline) then
      Exit(False);
    if Received < 0 then
      Sleep(CloseIntervalMilliseconds);
  until False;
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
    { The options every compile of the program starts with, then the user's: symbols kept, the
      agent loaded, the units built into AUnitsDirectory, and AExecutable as the program. }
    function StartArguments(const AUnitsDirectory, AExecutable: string): TStringList;
    procedure ForgetUnitsIn(const ADirectory: string; const AChangedFiles: TStrings);
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
      or the closing lines when there are none; the caller frees the list. AExecutable is
      the program's file, the workspace's Executable when empty. }
    function Compile(const ALink: Boolean; out AErrors: TStringList; out ASeconds: Double;
      const AExecutable: string = ''): Boolean;
    { Makes the compiler recompile the units whose source changed, whatever it thinks. Its own
      check compares times of one-second granularity: an edit saved in the same second as its
      previous compile of the unit goes unnoticed. The driver knows from the content which
      files changed, so it removes the compiler's record of those units from its own unit
      directory, and for a Windows program from the assembly directory too.
      HOT_TRUST_TIMESTAMPS=1 turns this off. }
    procedure ForgetUnits(const AChangedFiles: TStrings);
    { The arguments of the program's compile; AExecutable as for Compile. }
    function CompileArguments(const ALink: Boolean; const AExecutable: string = ''): TStringList;
    { The arguments of the compile that writes the program's assembler (-s -Aas) instead of its
      object files, into the workspace's assembly directory, which keeps units of its own. }
    function AssemblerArguments: TStringList;
    { Compiles the program to assembler (see "sizes of initialised data"). False when fpc
      failed; AProblem is then its first error. Removes the scripts fpc writes next to the
      program there, as it links nothing. Every assembler file in the assembly directory
      afterwards comes from this compile or from the one that wrote its unit's file there:
      first the units of AChanged (object files, such as foo.o; may be nil) are made to
      compile again, and the assembler of every unit without its unit file there, the
      program's included, is removed. One that fpc does not write again is then missing,
      and its sizes are unknown, not those of an earlier compile. }
    function WriteAssembler(const AChanged: TStrings; out AProblem: string; out ASeconds: Double): Boolean;
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

{ The agent's source, HotFPC.Agent.pas, as a resource. HotFPC.rc names it, and fpcres turns
  that into HotFPC.res before this program is compiled (build.sh and build.bat do it). }
{$R HotFPC.res}

const
  AgentResourceName = 'HOTFPCAGENT';
  { RT_RCDATA, which the system unit declares on every target but Windows. }
  RawDataResourceType = MAKEINTRESOURCE(10);
  AgentSourceFileName = 'HotFPC.Agent.pas';
  { fpc names the unit's files after its source file; some builds write them in lower case. }
  AgentRecordFileName = 'HotFPC.Agent.ppu';
  AgentRecordFileNameLower = 'hotfpc.agent.ppu';
  AgentUnitOption = '-FaHotFPC.Agent';
  KeepSymbolsOption = '-Xs-';
  NoLinkOption = '-Cn';
  LinkMapOption = '-Xm';
  { write assembler and stop, and write it for the GNU assembler: fpc 3.2.2 for Windows
    otherwise keeps writing object files with its internal one }
  AssemblerOnlyOption = '-s';
  GNUAssemblerOption = '-Aas';
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
  Source: TResourceStream;
  Arguments: TStringList;
begin
  ForceDirectories(FWorkspace.AgentDirectory);
  ForceDirectories(FWorkspace.AgentSourceDirectory);
  Source := TResourceStream.Create(HInstance, AgentResourceName, RawDataResourceType);
  try
    Source.SaveToFile(FWorkspace.AgentSourceDirectory + AgentSourceFileName);
  finally
    Source.Free;
  end;
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

function TCompiler.StartArguments(const AUnitsDirectory, AExecutable: string): TStringList;
var
  I: Integer;
begin
  Result := TStringList.Create;
  Result.Add(KeepSymbolsOption);
  Result.Add(AgentUnitOption);
  Result.Add(UnitPathOption + ExcludeTrailingPathDelimiter(FWorkspace.AgentDirectory));
  Result.Add(UnitDirectoryOption + ExcludeTrailingPathDelimiter(AUnitsDirectory));
  Result.Add(OutputOption + AExecutable);
  for I := 0 to FOptions.Count - 1 do
    Result.Add(FOptions[I]);
end;

function TCompiler.CompileArguments(const ALink: Boolean; const AExecutable: string): TStringList;
begin
  if AExecutable <> '' then
    Result := StartArguments(FWorkspace.UnitsDirectory, AExecutable)
  else
    Result := StartArguments(FWorkspace.UnitsDirectory, FWorkspace.Executable);
  if not ALink then
    Result.Add(NoLinkOption)
  { the linker's map: where it put sections that fpc 3.2 gives no symbol (the agent reads it) }
  else if FTargetWindows then
    Result.Add(LinkMapOption);
  Result.Add(FWorkspace.Source);
end;

function TCompiler.AssemblerArguments: TStringList;
begin
  { the program's name in the assembly directory: fpc writes its link scripts next to it }
  Result := StartArguments(FWorkspace.AssemblyDirectory,
    FWorkspace.AssemblyDirectory + ExtractFileName(FWorkspace.Executable));
  Result.Add(AssemblerOnlyOption);
  Result.Add(GNUAssemblerOption);
  Result.Add(FWorkspace.Source);
end;

function TCompiler.WriteAssembler(const AChanged: TStrings; out AProblem: string; out ASeconds: Double): Boolean;
var
  Arguments, Before, Errors: TStringList;
  Output: string;
  Start: Double;
  I: Integer;
  Search: TSearchRec;
begin
  AProblem := '';
  ForceDirectories(FWorkspace.AssemblyDirectory);
  if AChanged <> nil then
    for I := 0 to AChanged.Count - 1 do
      DeleteFile(FWorkspace.AssemblyDirectory + ChangeFileExt(AChanged[I], RecordExtension));
  if FindFirst(FWorkspace.AssemblyDirectory + '*' + AssemblerExtension, faAnyFile, Search) = 0 then
  begin
    repeat
      if not FileExists(FWorkspace.AssemblyDirectory + ChangeFileExt(Search.Name, RecordExtension)) then
        DeleteFile(FWorkspace.AssemblyDirectory + Search.Name);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  Before := FindLeftovers(FWorkspace.AssemblyDirectory);
  Arguments := AssemblerArguments;
  try
    Start := NowSeconds;
    Result := Execute(Arguments.ToStringArray, Output) = 0;
    ASeconds := NowSeconds - Start;
    RemoveNewLeftovers(FWorkspace.AssemblyDirectory, Before);
  finally
    Arguments.Free;
    Before.Free;
  end;
  if not Result then
  begin
    Errors := ExtractErrors(Output);
    try
      if Errors.Count > 0 then
        AProblem := Errors[0]
      else
        AProblem := Trim(Output);
    finally
      Errors.Free;
    end;
  end;
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

function TCompiler.Compile(const ALink: Boolean; out AErrors: TStringList; out ASeconds: Double;
  const AExecutable: string): Boolean;
var
  Arguments: TStringList;
  Output: string;
  Status: Integer;
  Start: Double;
begin
  Arguments := CompileArguments(ALink, AExecutable);
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
begin
  if GetEnvironmentVariable(TrustTimestampsVariable) <> '' then
    Exit;
  ForgetUnitsIn(FWorkspace.UnitsDirectory, AChangedFiles);
  if FTargetWindows then
    ForgetUnitsIn(FWorkspace.AssemblyDirectory, AChangedFiles);
end;

procedure TCompiler.ForgetUnitsIn(const ADirectory: string; const AChangedFiles: TStrings);
var
  I, K: Integer;
  Records: TStringList;
  Search: TSearchRec;
begin
  Records := TStringList.Create;
  try
    if FindFirst(ADirectory + '*' + RecordExtension, faAnyFile, Search) = 0 then
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
            WriteLn('[hot debug] forget ', ADirectory + Records[K], ' for ', AChangedFiles[I]);
          DeleteFile(ADirectory + Records[K]);
        end;
  finally
    Records.Free;
  end;
end;


// ---------------------------------------------------------------- the driver
{ One run of hotfpc. It builds the program with the agent, starts it, waits for its agent to
  connect, and then polls the sources: on every save it compiles, checks the interfaces, hands
  the changed object files to the agent, and prints what happened as [hot] lines. A save that
  needs a restart links the program again and starts it over, unless --no-restart. It owns the
  order of these steps and the wording of what it prints; the work is in the units it asks. }

const
  PortVariable = 'HOT_PORT';
  TokenVariable = 'HOT_TOKEN';
  PollIntervalMilliseconds = 10;
  AcceptIntervalMilliseconds = 5;
  SettleSlackMilliseconds = 2;
  DigestIntervalSeconds = 0.5;
  { How many compiles in a row hotfpc leaves unused because the sources changed meanwhile.
    A source that changes faster than fpc compiles, such as a file a generator keeps
    rewriting, would otherwise hold back every save; the next compile is then used as it is,
    and the changes still to come are compiled after it. }
  MaximumUnusedCompiles = 3;
  { The longest hotfpc waits for the files to stop changing. A file that changes all the time
    is then compiled as it is, and that compile sees the change: the limit above applies. }
  MaximumSettleSeconds = 1.0;
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
  { How long a restart tries to put the new program in the old one's place: Windows keeps a
    program's file locked for a moment after the program has ended. }
  ReplaceTimeoutSeconds = 5;
  ReplaceIntervalMilliseconds = 20;
  { How long a stopped program's connection may stay open: with --run, the process hotfpc
    stops may be a launcher, and the program its child. }
  CloseTimeoutSeconds = 2;
  { The exit code TerminateProcess gives a program a restart stops on Windows. }
  StoppedExitCode = 1;
  MapExtension = '.map';

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
    { The sizes and times of the sources when FDigests was read: the state the compile of a
      save starts from. }
    FSettled: TFileStamps;
    { The clock before FSettled was read (TSourceWatcher.StampedAt) }
    FSettledAt: Int64;
    { The sources changed while fpc read them, so the compile was not acted on: Watch compiles
      them again. }
    FStale: Boolean;
    { Compiles, links and compiles to assembler in a row that were not acted on (FStale);
      Watch sets it back once a save has been handled. }
    FUnusedCompiles: Integer;
    { A compile, link or compile to assembler of this save was acted on although the sources
      changed while fpc read them (after MaximumUnusedCompiles), so it and the others may come
      from different sources. }
    FUnsettled: Boolean;
    FBased: TStringList;
    { The check of sizes of initialised data is on (a Windows program). }
    FCheckSizes: Boolean;
    { This save compiled the program to assembler. }
    FAssemblyWritten: Boolean;
    { The sizes of the running program's initialised data (see "sizes of initialised data"),
      name=bytes, or name=? for a datum the assembler had no size for; nil while they are
      unknown, FSizesProblem then says why. }
    FSizes: TStringList;
    FSizesProblem: string;
    { The running program; nil while hotfpc waits for a save that builds to start it again. }
    FProgram: TProcess;
    { FProgram was started by a restart. }
    FRestartedProgram: Boolean;
    FStart: TDateTime;
    FStartedAt: Double;
    FBuildSeconds: Double;
    FVersion: Integer;
    FApplied: Integer;
    FRefused: Integer;
    FFailed: Integer;
    FUnchanged: Integer;
    FRestarted: Integer;
    function BuildToStart: Boolean;
    procedure CopyObjectsToLive;
    procedure ProbeLayouts;
    function StartProgram: TProcess;
    function AwaitAgent(const AProgram: TProcess; out AExitCode: Integer): Boolean;
    procedure Watch;
    function ProgramHasEnded: Boolean;
    function Settle(const AStamps: TFileStamps): TFileStamps;
    procedure SayErrors(const AErrors: TStringList; const AFallback: string);
    function SourcesChangedDuringCompile: Boolean;
    procedure ForgetNewUnits;
    function CompileSources(out ACompileSeconds: Double): Boolean;
    function CollectChangedObjects(const AChanged: TStrings; const ACompileSeconds: Double): Boolean;
    function LayoutsAllowSwap(const AChanged: TStrings; const ACompileSeconds: Double;
      out AInterfaceSeconds: Double): Boolean;
    function HasInitialisedData(const AObjects: TStrings): Boolean;
    function ReadAssembly(const AObjects: TStrings; out AProblem: string): TStringList;
    function WriteLiveAssembly(out AProblem: string): Boolean;
    procedure KeepLiveSizes(const ASizesKnown: Boolean; const AProblem: string);
    function NotAssembled(const AProblem: string): string;
    procedure RefuseUncheckedSizes(const AReason: string; const ACompileSeconds: Double);
    function SizesAllowSwap(const AChanged: TStrings; const ACompileSeconds: Double;
      var AInterfaceSeconds: Double): Boolean;
    function Swap(const AChanged: TStrings; const ASeen, ASettled, ACompileSeconds, AInterfaceSeconds: Double): Boolean;
    procedure Accept(const AChanged: TStrings; const AStage: string);
    procedure Reject(const AReply: TStrings; const AVerdict, AStage: string; const ACompileSeconds: Double);
    function Reload(const ASeen, ASettled: Double): Boolean;
    function ReplaceExecutable: Boolean;
    procedure Restart(const ASeen: Double);
    procedure SayStart;
    procedure SayEnd(const AExitCode: Integer);
    { The program's exit code; -1 when a signal ended it. }
    class function ExitCodeOf(const AProgram: TProcess): Integer;
    { When the wait of Settle that starts at ANow ends, for a settle that started at AStart and
      waits AWait between looks: AWait later, but never past MaximumSettleSeconds after AStart,
      or one AWait after AStart when that is later. A file that keeps changing is then compiled
      as it is. }
    class function SettleWaitEnd(const AStart, ANow, AWait: Double): Double;
    { How long Settle sleeps before it looks again when ARemaining seconds of its wait are
      left: one poll interval at most, and 0, no sleep, once the wait is over. ARemaining
      comes from one reading of the clock, which may already be past the wait's end. }
    class function SettlePause(const ARemaining: Double): Integer;
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
    FPPUDump := TLayoutReader.Locate(AOptions.Compiler, ExtractFileExt(ParamStr(0)),
      GetEnvironmentVariable('PATH'));
  FVersion := 1;
  FStart := Now;
end;

destructor TDriver.Destroy;
begin
  FProgram.Free;
  FSizes.Free;
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

{ Builds the program to start it, and for a Windows program compiles it to assembler for the
  sizes of its initialised data (FCheckSizes). The same check of the sources covers both: a
  save that fpc read only in part, or after it read the file, would start a program that is no
  state anybody saved, or one whose sizes come from other sources than its code. The program
  is then built again once the sources settle; after MaximumUnusedCompiles such builds in a
  row, the next one is used as it is, and Watch compiles the sources as they are then. A
  build or a compile to assembler that failed counts only once the check of the sources has
  passed: it may have failed on a save fpc read in part. False when the build failed; fpc's
  errors are then printed. }
function TDriver.BuildToStart: Boolean;
var
  Errors: TStringList;
  Problem: string;
  SizesKnown: Boolean;
  I: Integer;
begin
  FCheckSizes := FOptions.TargetWindows;
  FSettled := FWatcher.Stamps;
  FSettledAt := FWatcher.StampedAt;
  FWatcher.ReadDigests(FDigests);
  repeat
    Result := FCompiler.Compile(True, Errors, FBuildSeconds);
    { before the check of the sources, which may remove the records ppudump is probed with }
    if Result and (FReader = nil) then
      ProbeLayouts;
    FAssemblyWritten := False;
    SizesKnown := not Result or not FCheckSizes or WriteLiveAssembly(Problem);
    if not SourcesChangedDuringCompile then
      Break;
    FreeAndNil(Errors);
    FStale := False;
    FSettled := Settle(FWatcher.Stamps);
    FSettledAt := FWatcher.StampedAt;
    FreeAndNil(FDigests);
    FWatcher.ReadDigests(FDigests);
  until False;
  FUnusedCompiles := 0;
  try
    if not Result then
      for I := 0 to Errors.Count - 1 do
        WriteLn(Errors[I]);
  finally
    Errors.Free;
  end;
  if not Result then
    Exit;
  { the units of this build only: while the program is not running, the check of the sources
    (ForgetNewUnits) removed every object file of a build that was set aside, such as one of
    a unit the program no longer uses }
  CopyObjectsToLive;
  if not SizesKnown then
  begin
    FCheckSizes := False;
    FReporter.Say(FOptions.Compiler + ' did not compile the program to assembler (' + Problem
      + '): the check of sizes of variables with initial values is off');
  end;
  if FCheckSizes then
    KeepLiveSizes(True, '');
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
      AExitCode := ExitCodeOf(AProgram);
      WriteLn('[hot] the program ended (exit code ', AExitCode, ') before hot reloading could start');
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

{ A compile or link that failed: its first errors, or AFallback when fpc named none. }
procedure TDriver.SayErrors(const AErrors: TStringList; const AFallback: string);
var
  I: Integer;
begin
  Inc(FFailed);
  if AErrors.Count = 0 then
    AErrors.Add(AFallback);
  for I := 0 to AErrors.Count - 1 do
    if I < MaximumShownErrors then
      FReporter.Say('error: ' + AErrors[I] + ' (nothing changed)');
end;

{ Whether a source changed after the compile, link or assembler compile of a save started
  (FSettled, FDigests). fpc reads one file after the other, so it may have read some of a save
  that was still being written, or of the next one: what it made is then no state the sources
  were in, and acting on it would apply, refuse or report a state nobody saved. The units of
  the changed files, and of units the running program does not have, are then compiled again
  by the next compile, which Watch starts once the sources have settled (FStale). After
  MaximumUnusedCompiles such compiles in a row, the next one is acted on all the same
  (FUnsettled). }
function TDriver.SourcesChangedDuringCompile: Boolean;
var
  Changed: TStringList;
begin
  Changed := FWatcher.ChangedSince(FSettled, FDigests);
  try
    Result := (Changed.Count > 0) and (FUnusedCompiles < MaximumUnusedCompiles);
    if (Changed.Count > 0) and not Result then
      FUnsettled := True;
    if Result then
    begin
      Inc(FUnusedCompiles);
      if GetEnvironmentVariable(DebugVariable) <> '' then
        WriteLn('[hot debug] changed during the compile: ', Changed.CommaText);
      FCompiler.ForgetUnits(Changed);
      ForgetNewUnits;
      FStale := True;
    end;
  finally
    Changed.Free;
  end;
end;

{ Removes the object files and records of units the running program does not have, so that
  a compile that leaves such a unit out doesn't find them: before the program first starts,
  every unit's. }
procedure TDriver.ForgetNewUnits;
var
  Objects: TStringList;
  I: Integer;
begin
  Objects := FWorkspace.UnitObjects;
  try
    for I := 0 to Objects.Count - 1 do
      if not FileExists(FWorkspace.LiveDirectory + Objects[I]) then
      begin
        DeleteFile(FWorkspace.UnitsDirectory + Objects[I]);
        DeleteFile(FWorkspace.UnitsDirectory + ChangeFileExt(Objects[I], RecordExtension));
      end;
  finally
    Objects.Free;
  end;
end;

{ Compiles the sources without linking. False when fpc failed, which it says with fpc's
  errors, or when the sources changed meanwhile (FStale), which it doesn't. }
function TDriver.CompileSources(out ACompileSeconds: Double): Boolean;
var
  Errors: TStringList;
begin
  Result := FCompiler.Compile(False, Errors, ACompileSeconds);
  try
    if SourcesChangedDuringCompile then
      Exit(False);
    if not Result then
      SayErrors(Errors, 'the compiler failed');
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

{ Each changed unit as the compiler wrote it down: a field that moved or a variable that
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

{ Whether a unit's object file (a name in the units directory) has a variable with an initial
  value or a typed constant. }
function TDriver.HasInitialisedData(const AObjects: TStrings): Boolean;
var
  I: Integer;
begin
  for I := 0 to AObjects.Count - 1 do
    if TDataSizes.HasInitialisedData(FWorkspace.UnitsDirectory + AObjects[I]) then
      Exit(True);
  Result := False;
end;

{ The sizes in this save's assembler of the initialised data of the units (named by their
  object files), each datum the object file names: name=? (UnknownSize) for one the
  assembler has no size for, as when fpc wrote no assembler for the unit or a directive it
  does not know follows the label. nil when an object file cannot be read; AProblem then
  says why. Otherwise the caller frees the list. }
function TDriver.ReadAssembly(const AObjects: TStrings; out AProblem: string): TStringList;
var
  I, K: Integer;
  Text: string;
  Names, Sizes: TStringList;
begin
  AProblem := '';
  Result := TStringList.Create;
  Names := TStringList.Create;
  try
    for I := 0 to AObjects.Count - 1 do
    begin
      Names.Clear;
      if not TDataSizes.ObjectNames(FWorkspace.UnitsDirectory + AObjects[I], Names) then
      begin
        AProblem := 'hotfpc could not read the object file ' + AObjects[I];
        FreeAndNil(Result);
        Exit;
      end;
      if Names.Count = 0 then
        Continue;
      Sizes := nil;
      if FAssemblyWritten
        and ReadFileContents(FWorkspace.AssemblyDirectory + ChangeFileExt(AObjects[I], AssemblerExtension), Text) then
        Sizes := TDataSizes.Read(Text);
      try
        for K := 0 to Names.Count - 1 do
          if (Sizes <> nil) and (Sizes.IndexOfName(Names[K]) >= 0) then
            Result.Add(Names[K] + '=' + Sizes.Values[Names[K]])
          else
            Result.Add(Names[K] + '=' + UnknownSize);
      finally
        Sizes.Free;
      end;
    end;
  finally
    Names.Free;
  end;
end;

{ Compiles the program to assembler for the sizes of the program that is about to start, from
  the sources it is built or linked from, unless this save already did or no unit has
  initialised data. After the build or link, which may add the object file of a unit new to
  the program, and before the check of the sources that covers both
  (SourcesChangedDuringCompile). False when fpc failed; AProblem then says why. }
function TDriver.WriteLiveAssembly(out AProblem: string): Boolean;
var
  Objects: TStringList;
  Seconds: Double;
begin
  AProblem := '';
  Result := True;
  if FAssemblyWritten then
    Exit;
  Objects := FWorkspace.UnitObjects;
  try
    if HasInitialisedData(Objects) then
    begin
      FAssemblyWritten := FCompiler.WriteAssembler(nil, AProblem, Seconds);
      Result := FAssemblyWritten;
      if GetEnvironmentVariable(DebugVariable) <> '' then
        WriteLn('[hot debug] assembler of the running program in ', FormatMilliseconds(Seconds), ' ms');
    end;
  finally
    Objects.Free;
  end;
end;

{ The sizes of the units the program starts with become the running program's (FSizes), from
  the assembler WriteLiveAssembly wrote, or are unknown when it failed or an object file
  cannot be read (FSizesProblem). After a compile to assembler, every unit's file in the
  assembly directory is current: the units whose source changed since were made to recompile
  there too. }
procedure TDriver.KeepLiveSizes(const ASizesKnown: Boolean; const AProblem: string);
var
  Objects: TStringList;
begin
  FreeAndNil(FSizes);
  if not ASizesKnown then
  begin
    FSizesProblem := NotAssembled(AProblem);
    Exit;
  end;
  Objects := FWorkspace.UnitObjects;
  try
    FSizes := ReadAssembly(Objects, FSizesProblem);
  finally
    Objects.Free;
  end;
end;

function TDriver.NotAssembled(const AProblem: string): string;
begin
  Result := FOptions.Compiler + ' did not compile the program to assembler (' + AProblem + ')';
end;

{ A save whose sizes cannot be checked is not swapped: one of them may have grown. }
procedure TDriver.RefuseUncheckedSizes(const AReason: string; const ACompileSeconds: Double);
begin
  Inc(FRefused);
  FReporter.Say('restart needed: ' + UnknownSizes + AReason
    + ' (not applied; compile ' + FormatMilliseconds(ACompileSeconds) + ' ms)');
end;

{ Each changed unit's variables with initial values and typed constants, by the sizes in
  fpc's assembler: on Windows the object file does not show one that grows inside the
  padding of its section. Compiles to assembler only when a changed unit has such data. A
  save whose sizes cannot be compared, because fpc did not write the assembler, the running
  program's sizes are unknown, either has no size for a datum a changed object file names,
  or the sources kept changing during the compiles (FUnsettled), needs a restart too, and so
  does one whose sources' times could not show a save that came and was put back during the
  compiles (TSourceWatcher.TimesShowWrites). }
function TDriver.SizesAllowSwap(const AChanged: TStrings; const ACompileSeconds: Double;
  var AInterfaceSeconds: Double): Boolean;
var
  Start, Seconds: Double;
  K: Integer;
  Problem: string;
  Compiled, Changes: TStringList;
begin
  Result := True;
  if not FCheckSizes or not HasInitialisedData(AChanged) then
    Exit;
  if FSizes = nil then
  begin
    RefuseUncheckedSizes(FSizesProblem, ACompileSeconds);
    Exit(False);
  end;
  Start := NowSeconds;
  FAssemblyWritten := FCompiler.WriteAssembler(AChanged, Problem, Seconds);
  if GetEnvironmentVariable(DebugVariable) <> '' then
    WriteLn('[hot debug] assembler in ', FormatMilliseconds(Seconds), ' ms');
  { Reload sees FStale }
  if SourcesChangedDuringCompile then
    Exit;
  if not FAssemblyWritten then
  begin
    RefuseUncheckedSizes(NotAssembled(Problem), ACompileSeconds);
    Exit(False);
  end;
  { the object files and the assembler may come from different sources: a size the object
    files have may not be the one counted }
  if FUnsettled then
  begin
    RefuseUncheckedSizes('the sources changed while fpc compiled them', ACompileSeconds);
    Exit(False);
  end;
  { nor can the stamps show that no save came and was put back during the compiles (Settle
    waits long enough for a save it saw) }
  if not TSourceWatcher.TimesShowWrites(FSettled, FSettledAt) then
  begin
    RefuseUncheckedSizes(UnseenSaves, ACompileSeconds);
    Exit(False);
  end;
  Compiled := ReadAssembly(AChanged, Problem);
  if Compiled = nil then
  begin
    RefuseUncheckedSizes(Problem, ACompileSeconds);
    Exit(False);
  end;
  Changes := TDataSizes.Changes(FSizes, Compiled);
  try
    if Changes.Count > 0 then
    begin
      Inc(FRefused);
      for K := 0 to Changes.Count - 1 do
        FReporter.Say('restart needed: ' + Changes[K] + ' (not applied; compile '
          + FormatMilliseconds(ACompileSeconds) + ' ms)');
      Exit(False);
    end;
  finally
    Changes.Free;
    Compiled.Free;
  end;
  AInterfaceSeconds := AInterfaceSeconds + NowSeconds - Start;
end;

{ The swap is applied: the staged files become the running program's, and so do the layouts
  and the sizes of the initialised data the new code adds. }
procedure TDriver.Accept(const AChanged: TStrings; const AStage: string);
var
  I: Integer;
  RecordName: string;
  Added: TStringList;
  Problem: string;
begin
  if FCheckSizes and (FSizes <> nil) then
  begin
    Added := ReadAssembly(AChanged, Problem);
    try
      if Added <> nil then
        TDataSizes.Keep(FSizes, Added);
    finally
      Added.Free;
    end;
  end;
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

{ True when the agent refused the swap: the edit needs a restart. }
function TDriver.Swap(const AChanged: TStrings; const ASeen, ASettled, ACompileSeconds, AInterfaceSeconds: Double): Boolean;
var
  Start, LoadSeconds: Double;
  I: Integer;
  Stage, Verdict, Units, Detail: string;
  Staged, Reply: TStringList;
begin
  Result := False;
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
      Exit(Verdict = VerdictRefused);
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

{ One save: compile, then swap what changed in the running program or say why not. True when
  the save needs a restart; False also when the sources changed during a compile (FStale). }
function TDriver.Reload(const ASeen, ASettled: Double): Boolean;
var
  Changed: TStringList;
  CompileSeconds, InterfaceSeconds: Double;
begin
  Result := False;
  if not CompileSources(CompileSeconds) then
    Exit;
  Changed := TStringList.Create;
  try
    if not CollectChangedObjects(Changed, CompileSeconds) then
      Exit(True);
    if not LayoutsAllowSwap(Changed, CompileSeconds, InterfaceSeconds) then
      Exit(True);
    if not SizesAllowSwap(Changed, CompileSeconds, InterfaceSeconds) then
      Exit(True);
    if FStale then
      Exit;
    if Changed.Count = 0 then
    begin
      Inc(FUnchanged);
      FReporter.Say('not swapped: the generated code is the same (compile ' + FormatMilliseconds(CompileSeconds) + ' ms)');
      Exit;
    end;
    Result := Swap(Changed, ASeen, ASettled, CompileSeconds, InterfaceSeconds);
  finally
    Changed.Free;
  end;
end;

{ Puts the program a restart linked in the place of the one that ran, with the linker's map
  on Windows, where the agent looks for it. Windows keeps a program's file locked for a moment
  after the program has ended. }
function TDriver.ReplaceExecutable: Boolean;
var
  Deadline: Double;
  NextMap, Map: string;
begin
  NextMap := ChangeFileExt(FWorkspace.NextExecutable, MapExtension);
  Map := ChangeFileExt(FWorkspace.Executable, MapExtension);
  Deadline := NowSeconds + ReplaceTimeoutSeconds;
  repeat
    if FileExists(FWorkspace.NextExecutable) then
    begin
      if FileExists(FWorkspace.Executable) then
        DeleteFile(FWorkspace.Executable);
      RenameFile(FWorkspace.NextExecutable, FWorkspace.Executable);
    end;
    { a stale map would make the agent bind later swaps wrongly }
    if FileExists(NextMap) then
    begin
      if FileExists(Map) then
        DeleteFile(Map);
      RenameFile(NextMap, Map);
    end;
    Result := not FileExists(FWorkspace.NextExecutable) and not FileExists(NextMap);
    if Result or (NowSeconds > Deadline) then
      Break;
    Sleep(ReplaceIntervalMilliseconds);
  until False;
end;

{ Starts the program over with the units of the last compile. The program is linked into
  NextDirectory first, so a link that fails leaves the running program as it is. A restart
  stops the program the way the system ends a process (SIGTERM, then SIGKILL; TerminateProcess
  on Windows): its state is gone and its finalization sections don't run. A restarted program
  that ends before its agent connects leaves hotfpc waiting for the next save that builds. }
procedure TDriver.Restart(const ASeen: Double);
var
  Errors: TStringList;
  Problem: string;
  Linked, SizesKnown: Boolean;
  ProgramExitCode: Integer;
  LinkSeconds, StopStart, StopSeconds: Double;
begin
  RemoveTree(ExcludeTrailingPathDelimiter(FWorkspace.NextDirectory));
  ForceDirectories(FWorkspace.NextDirectory);
  Linked := FCompiler.Compile(True, Errors, LinkSeconds, FWorkspace.NextExecutable);
  SizesKnown := not Linked or not FCheckSizes or WriteLiveAssembly(Problem);
  try
    { the program keeps running; the next compile decides again. This covers the compile to
      assembler too. }
    if SourcesChangedDuringCompile then
      Exit;
    if not Linked then
      SayErrors(Errors, 'the program did not link');
  finally
    Errors.Free;
  end;
  if not Linked then
    Exit;
  StopStart := NowSeconds;
  if FProgram <> nil then
  begin
    { it ended on its own during the link: Watch sees to that }
    if not FProgram.Running then
      Exit;
    FProgram.Terminate(StoppedExitCode);
    FProgram.WaitOnExit;
    FreeAndNil(FProgram);
    if not FLink.AwaitClosed(CloseTimeoutSeconds) then
      FReporter.Say('the stopped program''s connection is still open: a launcher (--run) that starts the '
        + 'program as its child has to end it too, or the old program keeps running');
  end;
  FLink.Disconnect;
  StopSeconds := NowSeconds - StopStart;
  if not ReplaceExecutable then
  begin
    FReporter.Say('error: cannot replace ' + FWorkspace.Executable
      + ' (the program is not running; the next save that builds starts it again)');
    Exit;
  end;
  { the new program's units are the running ones now }
  RemoveTree(ExcludeTrailingPathDelimiter(FWorkspace.LiveDirectory));
  ForceDirectories(FWorkspace.LiveDirectory);
  CopyObjectsToLive;
  if FCheckSizes then
    KeepLiveSizes(SizesKnown, Problem);
  FBased.Clear;
  if FLayouts <> nil then
  begin
    FLayouts.Free;
    FLayouts := TLayoutHistory.Create(FReader, FWorkspace.LiveDirectory, FWorkspace.UnitsDirectory);
  end;
  Inc(FVersion);
  Inc(FRestarted);
  FProgram := StartProgram;
  FRestartedProgram := True;
  if not AwaitAgent(FProgram, ProgramExitCode) then
  begin
    FReporter.Say('the next save that builds starts the program again');
    FreeAndNil(FProgram);
    Exit;
  end;
  FReporter.Say(Format('v%d restarted: the program starts over; %s ms after the save was seen (link %s, stop %s, start %s)',
    [FVersion, FormatMilliseconds(NowSeconds - ASeen), FormatMilliseconds(LinkSeconds), FormatMilliseconds(StopSeconds),
     FormatMilliseconds(NowSeconds - FStartedAt)]));
end;

{ Waits for the save to stop changing the files, for MaximumSettleSeconds at most, or for
  one --settle wait when that is longer (SettleWaitEnd). Stops as soon as the program has
  ended, also during a long wait (Watch then ends with it). The files as they are then. With
  the check of sizes, each wait is longer than a tick of the clock behind file times. }
function TDriver.Settle(const AStamps: TFileStamps): TFileStamps;
var
  Again: TFileStamps;
  Start, Wait, WaitEnd: Double;
  Pause: Integer;
begin
  Result := AStamps;
  Wait := FOptions.SettleSeconds + SettleSlackMilliseconds / MillisecondsPerSecond;
  { a write after the files settled then gives them another time: the check of sizes needs
    that (TSourceWatcher.TimesShowWrites) }
  if FCheckSizes and (Wait < StampGranuleSeconds + SettleSlackMilliseconds / MillisecondsPerSecond) then
    Wait := StampGranuleSeconds + SettleSlackMilliseconds / MillisecondsPerSecond;
  Start := NowSeconds;
  repeat
    WaitEnd := SettleWaitEnd(Start, NowSeconds, Wait);
    { in steps, to see the program end }
    repeat
      if (FProgram <> nil) and not FProgram.Running then
        Exit;
      Pause := SettlePause(WaitEnd - NowSeconds);
      if Pause > 0 then
        Sleep(Pause);
    until Pause = 0;
    Again := FWatcher.Stamps;
    if TSourceWatcher.SameStamps(Again, Result) then
      Break;
    Result := Again;
  until (SettleWaitEnd(Start, NowSeconds, Wait) <= NowSeconds) or ((FProgram <> nil) and not FProgram.Running);
end;

class function TDriver.SettleWaitEnd(const AStart, ANow, AWait: Double): Double;
var
  Deadline: Double;
begin
  Deadline := AStart + MaximumSettleSeconds;
  if AStart + AWait > Deadline then
    Deadline := AStart + AWait;
  Result := ANow + AWait;
  if Result > Deadline then
    Result := Deadline;
end;

class function TDriver.SettlePause(const ARemaining: Double): Integer;
begin
  if ARemaining <= 0 then
    Result := 0
  else if ARemaining * MillisecondsPerSecond >= PollIntervalMilliseconds then
    Result := PollIntervalMilliseconds
  else
    Result := Trunc(ARemaining * MillisecondsPerSecond) + 1;
end;

{ True when the program has ended and hotfpc ends with it. A program that a restart started
  and that then failed (a runtime error in an initialization section, say) does not end
  hotfpc: the next save that builds starts it again. }
function TDriver.ProgramHasEnded: Boolean;
var
  ProgramExitCode: Integer;
begin
  Result := False;
  if (FProgram = nil) or FProgram.Running then
    Exit;
  ProgramExitCode := ExitCodeOf(FProgram);
  if not FRestartedProgram or (ProgramExitCode = 0) then
    Exit(True);
  FReporter.Say(Format('the program ended with %d; the next save that builds starts it again', [ProgramExitCode]));
  FreeAndNil(FProgram);
  FLink.Disconnect;
end;

{ Polls the sizes and times of the sources every few milliseconds and their contents twice a
  second: the content check catches an edit of the same size within the same second. A save
  whose files changed again while fpc compiled them is compiled again once they settle
  (FStale), even when their content is back to what it was. A file that a save left empty
  holds every save back until the next look at the contents, half a second later, and is
  compiled then if it is still empty: an editor that empties a file before it writes it may
  not have written it yet. }
procedure TDriver.Watch;
var
  Seen, Known, Current: TFileStamps;
  Digests, Changed, Emptied: TStringList;
  LastDigest, SeenAt, CompileSeconds, EmptiedUntil: Double;
  Waiting: Boolean;
begin
  Seen := FWatcher.Stamps;
  Waiting := False;
  EmptiedUntil := 0;
  { the stamps of the last look, for the files a save empties: Seen starts over when the
    sources changed during a compile, Known doesn't }
  Known := Seen;
  Emptied := TStringList.Create;
  try
    LastDigest := NowSeconds;
    while True do
    begin
      Sleep(PollIntervalMilliseconds);
      if ProgramHasEnded then
        Break;
      Current := FWatcher.Stamps;
      { the next look: when a file changes, at the next look at the contents, or when the
        wait for a file a save emptied ends, whichever comes first }
      if TSourceWatcher.SameStamps(Current, Seen) and (NowSeconds - LastDigest < DigestIntervalSeconds)
        and not (Waiting and (NowSeconds >= EmptiedUntil)) then
        Continue;
      SeenAt := NowSeconds;
      if not TSourceWatcher.SameStamps(Current, Seen) then
        Current := Settle(Current);
      if ProgramHasEnded then
        Break;
      Seen := Current;
      LastDigest := NowSeconds;
      Waiting := TSourceWatcher.AwaitEmptied(Known, Current, LastDigest, DigestIntervalSeconds, Emptied);
      EmptiedUntil := TSourceWatcher.EmptiedDeadline(Emptied, LastDigest, DigestIntervalSeconds);
      Known := Current;
      { a file a save emptied, or a missing file: a save in progress }
      if Waiting or not FWatcher.ReadDigests(Digests) then
        Continue;
      if not FStale and (FDigests <> nil) and (Digests.Text = FDigests.Text) then
      begin
        Digests.Free;
        Continue;
      end;
      FStale := False;
      FSettled := Current;
      FSettledAt := FWatcher.StampedAt;
      FUnsettled := False;
      Changed := TSourceWatcher.ChangedFiles(FDigests, Digests);
      if GetEnvironmentVariable(DebugVariable) <> '' then
        WriteLn('[hot debug] seen at ', FormatFloat('0.000', SeenAt - LastDigest), ' changed ', Changed.CommaText);
      FCompiler.ForgetUnits(Changed);
      FAssemblyWritten := False;
      Changed.Free;
      FDigests.Free;
      FDigests := Digests;
      if FProgram = nil then
      begin
        if CompileSources(CompileSeconds) then
          Restart(SeenAt);
      end
      else if Reload(SeenAt, NowSeconds) and FOptions.Restart then
        Restart(SeenAt);
      { settle first: the save that changed them may still be in progress }
      if FStale then
        Seen := nil
      else
        FUnusedCompiles := 0;
      if ProgramHasEnded then
        Break;
    end;
  finally
    Emptied.Free;
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
    FReporter.Say(Format('the program ended with %d after %s s; %d reloads applied, %d refused, %d failed to compile, %d without a change in code, %d restarts',
      [AExitCode, FormatSeconds(SecondsSince(FStart)), FApplied, FRefused, FFailed, FUnchanged, FRestarted]));
end;

class function TDriver.ExitCodeOf(const AProgram: TProcess): Integer;
begin
  Result := AProgram.ExitCode;
  if (Result = 0) and (AProgram.ExitStatus <> 0) then
    Result := -1;
end;

function TDriver.Run: Integer;
var
  Problem, Output: string;
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
  if not BuildToStart then
    Exit(1);
  if not FLink.Listen then
  begin
    WriteLn('[hot] cannot listen on 127.0.0.1');
    Exit(1);
  end;
  FProgram := StartProgram;
  if not AwaitAgent(FProgram, Result) then
    Exit;
  SayStart;
  Watch;
  FProgram.WaitOnExit;
  Result := ExitCodeOf(FProgram);
  SayEnd(Result);
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
// ---------------------------------------------------------------- tests
{ hotfpc's unit tests, compiled in instead of hotfpc when HOTFPC_TESTS is defined;
  `./build.sh tests` (build.bat on Windows) builds and runs them. No framework: a failed
  check is printed and counted, and the program ends with exit code 1 when any failed. }

// ---------------------------------------------------------------- tests: checks

var
  CheckCount: Integer = 0;
  FailureCount: Integer = 0;
  Directories: TStringList;

procedure Expect(const ACondition: Boolean; const ADescription: string);
begin
  Inc(CheckCount);
  if not ACondition then
  begin
    Inc(FailureCount);
    WriteLn('FAIL: ', ADescription);
  end;
end;

procedure ExpectEqual(const AActual, AExpected: string; const ADescription: string); overload;
begin
  Inc(CheckCount);
  if AActual <> AExpected then
  begin
    Inc(FailureCount);
    WriteLn('FAIL: ', ADescription, ': expected "', AExpected, '", got "', AActual, '"');
  end;
end;

procedure ExpectEqual(const AActual, AExpected: Int64; const ADescription: string); overload;
begin
  Inc(CheckCount);
  if AActual <> AExpected then
  begin
    Inc(FailureCount);
    WriteLn('FAIL: ', ADescription, ': expected ', AExpected, ', got ', AActual);
  end;
end;

{ A fresh empty directory for a test, next to the test program and removed again by
  FinishTests. }
function MakeTestDirectory(const AName: string): string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0))) + 'work-' + AName + '-' + IntToStr(GetProcessID)
    + PathDelim;
  RemoveTree(ExcludeTrailingPathDelimiter(Result));
  ForceDirectories(Result);
  Directories.Add(Result);
end;

procedure WriteTestFile(const APath, AContents: string);
var
  Stream: TFileStream;
begin
  ForceDirectories(ExtractFilePath(APath));
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if AContents <> '' then
      Stream.WriteBuffer(AContents[1], Length(AContents));
  finally
    Stream.Free;
  end;
end;

{ Removes the test directories, prints the totals, and returns the exit code: 1 when a
  check failed. }
function FinishTests: Integer;
var
  I: Integer;
begin
  for I := 0 to Directories.Count - 1 do
    RemoveTree(ExcludeTrailingPathDelimiter(Directories[I]));
  WriteLn(CheckCount, ' checks, ', FailureCount, ' failed');
  if FailureCount > 0 then
    Result := 1
  else
    Result := 0;
end;

// ---------------------------------------------------------------- tests: timing
{ How durations print in the [hot] lines. }

procedure TestFormats;
begin
  ExpectEqual(FormatMilliseconds(0.0), '0.0', 'no time');
  ExpectEqual(FormatMilliseconds(0.0123), '12.3', 'milliseconds with one decimal');
  ExpectEqual(FormatMilliseconds(0.002), '2.0', 'a whole number of milliseconds keeps its decimal');
  ExpectEqual(FormatMilliseconds(1.5), '1500.0', 'a second and a half');
  ExpectEqual(FormatSeconds(12.34), '12.3', 'seconds with one decimal');
  ExpectEqual(FormatSeconds(0.04), '0.0', 'under a tenth of a second');
end;

procedure TestClock;
var
  Start: TDateTime;
  First, Second: Double;
begin
  First := NowSeconds;
  Sleep(20);
  Second := NowSeconds;
  Expect(Second > First, 'time passes');
  Expect(Second - First < 5.0, 'at the pace of seconds');
  Start := Now - 2.0 / 86400.0;
  Expect(Abs(SecondsSince(Start) - 2.0) < 0.5, 'seconds since two seconds ago');
end;

// ---------------------------------------------------------------- tests: files
{ Reading, copying and comparing files, and removing a tree. }

procedure TestReadAndCopy;
var
  Root, Contents: string;
begin
  Root := MakeTestDirectory('files');
  WriteTestFile(Root + 'a.txt', 'hello' + #0 + 'world');
  Expect(ReadFileContents(Root + 'a.txt', Contents), 'a file is read');
  ExpectEqual(Contents, 'hello' + #0 + 'world', 'byte for byte');
  WriteTestFile(Root + 'empty.txt', '');
  Expect(ReadFileContents(Root + 'empty.txt', Contents), 'an empty file is read');
  ExpectEqual(Contents, '', 'as nothing');
  Contents := 'stale';
  Expect(not ReadFileContents(Root + 'missing.txt', Contents), 'a file that is not there');
  ExpectEqual(Contents, '', 'leaves nothing');
  CopyFileContents(Root + 'a.txt', Root + 'b.txt');
  Expect(SameFileContents(Root + 'a.txt', Root + 'b.txt'), 'a copy is the same');
  WriteTestFile(Root + 'b.txt', 'hello');
  Expect(not SameFileContents(Root + 'a.txt', Root + 'b.txt'), 'another content is not');
  Expect(not SameFileContents(Root + 'a.txt', Root + 'missing.txt'), 'a missing file is not the same as anything');
  Expect(not SameFileContents(Root + 'missing.txt', Root + 'also-missing.txt'), 'nor as another missing one');
end;

procedure TestRemoveTree;
var
  Root: string;
begin
  Root := MakeTestDirectory('tree');
  WriteTestFile(Root + 'top' + PathDelim + 'one.txt', '1');
  WriteTestFile(Root + 'top' + PathDelim + 'deeper' + PathDelim + 'two.txt', '2');
  RemoveTree(Root + 'top');
  Expect(not DirectoryExists(Root + 'top'), 'the directory and what is in it go');
  Expect(DirectoryExists(Root), 'its parent stays');
  RemoveTree(Root + 'top');
  Expect(DirectoryExists(Root), 'removing what is not there does nothing');
end;

procedure TestFindFileIgnoringCase;
var
  Root: string;
begin
  Root := MakeTestDirectory('case');
  WriteTestFile(Root + 'Greeting.ppu', 'x');
  ExpectEqual(ExtractFileName(FindFileIgnoringCase(Root, 'GREETING.ppu')), 'Greeting.ppu',
    'a unit name in capitals finds the file named after its source');
  ExpectEqual(ExtractFileName(FindFileIgnoringCase(Root, 'Greeting.ppu')), 'Greeting.ppu', 'and the exact name');
  ExpectEqual(FindFileIgnoringCase(Root, 'other.ppu'), '', 'another name finds nothing');
end;

// ---------------------------------------------------------------- tests: command line
{ The command line, option by option, and what is derived from it for a Windows target on
  either kind of host. }

function ParseArguments(const AArguments: array of string; const AHostIsWindows: Boolean;
  out AAction: TCommandAction): TOptions;
begin
  Result := TOptions.Create;
  AAction := Result.Parse(AArguments, AHostIsWindows);
end;

procedure TestDefaults;
var
  Options: TOptions;
  Action: TCommandAction;
begin
  Options := ParseArguments(['program.pas'], False, Action);
  try
    Expect(Action = caRun, 'a source file alone runs');
    ExpectEqual(Options.Source, ExpandFileName('program.pas'), 'the source is a full path');
    ExpectEqual(Options.Compiler, 'fpc', 'the default compiler');
    ExpectEqual(Options.PPUDump, '', 'no ppudump named');
    ExpectEqual(Options.Launcher, '', 'no launcher');
    ExpectEqual(Options.LogPath, '', 'no log');
    Expect(not Options.Quiet, 'not quiet');
    Expect(Options.Restart, 'an edit that needs a restart starts the program over');
    Expect(not Options.TargetWindows, 'not a Windows target');
    Expect(not Options.WinePaths, 'no Wine paths');
    Expect(Abs(Options.SettleSeconds - 0.002) < 1E-9, 'the default settle time is 2 ms');
    ExpectEqual(Options.CompilerOptions.Count, 0, 'no compiler options');
    ExpectEqual(Options.ProgramArguments.Count, 0, 'no program arguments');
  finally
    Options.Free;
  end;
end;

procedure TestValues;
var
  Options: TOptions;
  Action: TCommandAction;
begin
  Options := ParseArguments(['--fpc', '/opt/fpc/bin/fpc', '--ppudump', '/opt/fpc/bin/ppudump', '--run', 'wrapper',
    '--quiet', '--no-restart', '--settle', '50', '--log', 'hot.log', 'demo.pas'], False, Action);
  try
    Expect(Action = caRun, 'every option with a value runs');
    ExpectEqual(Options.Compiler, '/opt/fpc/bin/fpc', '--fpc');
    ExpectEqual(Options.PPUDump, '/opt/fpc/bin/ppudump', '--ppudump');
    ExpectEqual(Options.Launcher, 'wrapper', '--run');
    ExpectEqual(Options.LogPath, 'hot.log', '--log');
    Expect(Options.Quiet, '--quiet');
    Expect(not Options.Restart, '--no-restart');
    Expect(Abs(Options.SettleSeconds - 0.05) < 1E-9, '--settle takes milliseconds');
    ExpectEqual(Options.CompilerOptions.Count, 0, 'hotfpc options are not fpc options');
    ExpectEqual(Options.Source, ExpandFileName('demo.pas'), 'the source');
  finally
    Options.Free;
  end;
end;

procedure TestSettleFallback;
var
  Options: TOptions;
  Action: TCommandAction;
begin
  Options := ParseArguments(['--settle', 'soon', 'a.pas'], False, Action);
  try
    Expect(Abs(Options.SettleSeconds - 0.002) < 1E-9, 'an unreadable --settle is 2 ms');
  finally
    Options.Free;
  end;
end;

{ A file that keeps changing is compiled after a second, or after one --settle wait when that
  is longer: no wait goes past that. }
procedure TestSettleWaitEnd;
begin
  Expect(Abs(TDriver.SettleWaitEnd(10.0, 10.0, 0.002) - 10.002) < 1E-9, 'the first wait is one --settle');
  Expect(Abs(TDriver.SettleWaitEnd(10.0, 10.6, 0.6) - 11.0) < 1E-9,
    'a later wait ends a second after the settle started, not a whole --settle later');
  Expect(Abs(TDriver.SettleWaitEnd(10.0, 10.9995, 0.002) - 11.0) < 1E-9, 'nor a few milliseconds later');
  Expect(Abs(TDriver.SettleWaitEnd(10.0, 10.0, 5.0) - 15.0) < 1E-9, 'a --settle longer than a second waits once');
  Expect(TDriver.SettleWaitEnd(10.0, 15.0, 5.0) <= 15.0, 'and no more after it');
end;

{ Each pause of a settle wait is a poll interval at most and ends with the wait, also when
  the clock is read past its end. }
procedure TestSettlePause;
begin
  ExpectEqual(TDriver.SettlePause(1.0), PollIntervalMilliseconds, 'a long wait sleeps one poll interval at a time');
  ExpectEqual(TDriver.SettlePause(PollIntervalMilliseconds / MillisecondsPerSecond), PollIntervalMilliseconds,
    'a poll interval left is one poll interval');
  ExpectEqual(TDriver.SettlePause(0.0034), 4, 'the rest of a wait shorter than that, to the next millisecond');
  ExpectEqual(TDriver.SettlePause(0.0000001), 1, 'a millisecond for a moment left');
  ExpectEqual(TDriver.SettlePause(0), 0, 'no sleep once the wait is over');
  ExpectEqual(TDriver.SettlePause(-0.002), 0, 'nor when the clock was read past its end');
  ExpectEqual(TDriver.SettlePause(-86400.0), 0, 'by however much');
end;

procedure TestCompilerOptionsAndProgramArguments;
var
  Options: TOptions;
  Action: TCommandAction;
begin
  Options := ParseArguments(['-Fu../lib;../more', '-O2', '@lwpt.cfg', 'a.pas', '--', '--quiet', 'b.pas', '-x'],
    False, Action);
  try
    Expect(Action = caRun, 'options before and arguments after the separator');
    ExpectEqual(Options.CompilerOptions.Count, 3, 'three options for fpc');
    ExpectEqual(Options.CompilerOptions[0], '-Fu../lib;../more', 'first option kept whole');
    ExpectEqual(Options.CompilerOptions[1], '-O2', 'second option');
    ExpectEqual(Options.CompilerOptions[2], '@lwpt.cfg', 'a response file is an option');
    ExpectEqual(Options.ProgramArguments.Count, 3, 'three arguments for the program');
    ExpectEqual(Options.ProgramArguments[0], '--quiet', 'after the separator hotfpc leaves options alone');
    ExpectEqual(Options.ProgramArguments[1], 'b.pas', 'a source-like argument');
    ExpectEqual(Options.ProgramArguments[2], '-x', 'the last argument');
    Expect(not Options.Quiet, '--quiet after the separator is the program''s');
    ExpectEqual(Options.Source, ExpandFileName('a.pas'), 'the source before the separator');
  finally
    Options.Free;
  end;
end;

procedure TestMissingValue;
var
  Options: TOptions;
  Action: TCommandAction;
begin
  Options := ParseArguments(['a.pas', '--fpc'], False, Action);
  try
    Expect(Action = caRun, 'an option without a value still runs');
    ExpectEqual(Options.Compiler, 'fpc', 'the compiler stays the default');
    ExpectEqual(Options.CompilerOptions.Count, 1, 'the lone option goes to fpc');
    ExpectEqual(Options.CompilerOptions[0], '--fpc', 'as it was written');
  finally
    Options.Free;
  end;
end;

procedure TestLastSourceWins;
var
  Options: TOptions;
  Action: TCommandAction;
begin
  Options := ParseArguments(['first.pas', 'second.pas'], False, Action);
  try
    ExpectEqual(Options.Source, ExpandFileName('second.pas'), 'the last source file');
  finally
    Options.Free;
  end;
end;

procedure TestVersionAndUsage;
var
  Options: TOptions;
  Action: TCommandAction;
begin
  Options := ParseArguments(['--version'], False, Action);
  Options.Free;
  Expect(Action = caShowVersion, '--version');
  Options := ParseArguments(['--quiet', 'a.pas', '--version'], False, Action);
  Options.Free;
  Expect(Action = caShowVersion, '--version wins over a source');
  Options := ParseArguments([], False, Action);
  Options.Free;
  Expect(Action = caShowUsage, 'no arguments');
  Options := ParseArguments(['--quiet', '-O2'], False, Action);
  Options.Free;
  Expect(Action = caShowUsage, 'options without a source');
  Options := ParseArguments(['--', 'a.pas'], False, Action);
  Options.Free;
  Expect(Action = caShowUsage, 'a source after the separator is the program''s');
  ExpectEqual(HotFPCVersion, '1.1.0', 'the version');
  Expect(Pos('usage: hotfpc [--version]', UsageText) = 1, 'the usage line starts as before');
end;

procedure TestWindowsTarget;
var
  Options: TOptions;
  Action: TCommandAction;
begin
  Options := ParseArguments(['-Twin64', '-Px86_64', 'a.pas'], False, Action);
  try
    Expect(Options.TargetWindows, '-Twin64 targets Windows');
    ExpectEqual(Options.Launcher, 'wine', 'a Windows target on another host runs under wine');
    Expect(Options.WinePaths, 'and its paths are Wine paths');
  finally
    Options.Free;
  end;
  Options := ParseArguments(['-TWin32', 'a.pas'], False, Action);
  try
    Expect(Options.TargetWindows, 'the target name is not case-sensitive');
  finally
    Options.Free;
  end;
  Options := ParseArguments(['-Tlinux', 'a.pas'], False, Action);
  try
    Expect(not Options.TargetWindows, '-Tlinux is not Windows');
    ExpectEqual(Options.Launcher, '', 'and needs no launcher');
  finally
    Options.Free;
  end;
  Options := ParseArguments(['-Twin64', '--run', '/usr/bin/wine64', 'a.pas'], False, Action);
  try
    ExpectEqual(Options.Launcher, '/usr/bin/wine64', 'a given launcher is kept');
    Expect(Options.WinePaths, 'a launcher named wine64 means Wine paths');
  finally
    Options.Free;
  end;
  Options := ParseArguments(['-Twin64', '--run', './runner', 'a.pas'], False, Action);
  try
    Expect(not Options.WinePaths, 'another launcher means native paths');
  finally
    Options.Free;
  end;
  Options := ParseArguments(['a.pas'], True, Action);
  try
    Expect(Options.TargetWindows, 'a Windows host builds a Windows program');
    ExpectEqual(Options.Launcher, '', 'and starts it itself');
    Expect(not Options.WinePaths, 'with native paths');
  finally
    Options.Free;
  end;
end;

// ---------------------------------------------------------------- tests: the .hot directory
{ The paths of the .hot/ directory and its object files. }

procedure TestPaths;
var
  Workspace: TWorkspace;
  Hot: string;
begin
  Workspace := TWorkspace.Create(PathDelim + 'work' + PathDelim + 'demo' + PathDelim + 'scene.pas', False);
  try
    Hot := PathDelim + 'work' + PathDelim + 'demo' + PathDelim + '.hot' + PathDelim;
    ExpectEqual(Workspace.Name, 'scene', 'the program is named after its source');
    ExpectEqual(Workspace.SourceDirectory, PathDelim + 'work' + PathDelim + 'demo' + PathDelim, 'the source directory');
    ExpectEqual(Workspace.HotDirectory, Hot, '.hot is next to the source');
    ExpectEqual(Workspace.UnitsDirectory, Hot + 'units' + PathDelim, 'units');
    ExpectEqual(Workspace.LiveDirectory, Hot + 'live' + PathDelim, 'live');
    ExpectEqual(Workspace.AgentDirectory, Hot + 'agent' + PathDelim, 'agent');
    ExpectEqual(Workspace.AgentSourceDirectory, Hot + 'agent-src' + PathDelim, 'agent-src');
    ExpectEqual(Workspace.Executable, Hot + 'scene', 'the program without an extension');
    ExpectEqual(Workspace.NextDirectory, Hot + 'next' + PathDelim, 'where a restart links');
    ExpectEqual(Workspace.NextExecutable, Hot + 'next' + PathDelim + 'scene', 'the program a restart links');
    ExpectEqual(Workspace.AssemblyDirectory, Hot + 'asm' + PathDelim, 'where a Windows program is compiled to assembler');
    ExpectEqual(Workspace.StageDirectory(2), Hot + 'v2' + PathDelim, 'the stage of a swap');
    ExpectEqual(Workspace.StageDirectory(13), Hot + 'v13' + PathDelim, 'by version');
  finally
    Workspace.Free;
  end;
  Workspace := TWorkspace.Create(PathDelim + 'work' + PathDelim + 'Main.lpr', True);
  try
    ExpectEqual(Workspace.Name, 'Main', 'a .lpr source');
    ExpectEqual(Workspace.Executable, PathDelim + 'work' + PathDelim + '.hot' + PathDelim + 'Main.exe',
      'a Windows program has its extension');
    ExpectEqual(Workspace.NextExecutable, PathDelim + 'work' + PathDelim + '.hot' + PathDelim + 'next' + PathDelim + 'Main.exe',
      'and so does the one a restart links');
  finally
    Workspace.Free;
  end;
end;

procedure TestUnitObjects;
var
  Workspace: TWorkspace;
  Root: string;
  Objects: TStringList;
begin
  Root := MakeTestDirectory('workspace');
  Workspace := TWorkspace.Create(Root + 'demo.pas', False);
  try
    Objects := Workspace.UnitObjects;
    try
      ExpectEqual(Objects.Count, 0, 'no units directory yet');
    finally
      Objects.Free;
    end;
    WriteTestFile(Workspace.UnitsDirectory + 'scene.o', '');
    WriteTestFile(Workspace.UnitsDirectory + 'scene.ppu', '');
    WriteTestFile(Workspace.UnitsDirectory + 'demo.o', '');
    WriteTestFile(Workspace.UnitsDirectory + 'hotfpc.agent.o', '');
    Objects := Workspace.UnitObjects;
    try
      ExpectEqual(Objects.CommaText, 'demo.o,hotfpc.agent.o,scene.o', 'the object files, sorted');
    finally
      Objects.Free;
    end;
  finally
    Workspace.Free;
  end;
end;

// ---------------------------------------------------------------- tests: [hot] lines
{ The copy of every line, with its time, in the log file. }

procedure TestLog;
var
  Reporter: TReporter;
  Log: TStringList;
  Root: string;
  Space: Integer;
begin
  Root := MakeTestDirectory('reporter');
  Reporter := TReporter.Create(Root + 'hot.log');
  try
    Reporter.Say('first line');
    Reporter.Say('v2 swapped: scene');
  finally
    Reporter.Free;
  end;
  Log := TStringList.Create;
  try
    Log.LoadFromFile(Root + 'hot.log');
    ExpectEqual(Log.Count, 2, 'a line in the log for each line said');
    Space := Pos(' ', Log[0]);
    Expect(StrToFloatDef(Copy(Log[0], 1, Space - 1), -1) > 0, 'each starts with the time');
    ExpectEqual(Copy(Log[0], Space + 1, MaxInt), '[hot] first line', 'then the line as it was printed');
    ExpectEqual(Copy(Log[1], Pos(' ', Log[1]) + 1, MaxInt), '[hot] v2 swapped: scene', 'the second line');
    ExpectEqual(Length(Copy(Log[0], 1, Space - 1)), Length(Copy(Log[1], 1, Pos(' ', Log[1]) - 1)),
      'times have the same width');
  finally
    Log.Free;
  end;
end;

procedure TestWithoutLog;
var
  Reporter: TReporter;
begin
  Reporter := TReporter.Create('');
  try
    Reporter.Say('printed only');
  finally
    Reporter.Free;
  end;
  Expect(True, 'a reporter without a log file says its line');
end;

// ---------------------------------------------------------------- tests: watching
{ The directories options and response files name, which files are watched, the content
  digest, and which files changed. }

procedure TestSourceExtensions;
begin
  Expect(TSourceWatcher.HasSourceExtension('unit.pas'), '.pas');
  Expect(TSourceWatcher.HasSourceExtension('unit.pp'), '.pp');
  Expect(TSourceWatcher.HasSourceExtension('shared.inc'), '.inc');
  Expect(TSourceWatcher.HasSourceExtension('main.lpr'), '.lpr');
  Expect(TSourceWatcher.HasSourceExtension('main.dpr'), '.dpr');
  Expect(TSourceWatcher.HasSourceExtension('UNIT.PAS'), 'the extension is not case-sensitive');
  Expect(not TSourceWatcher.HasSourceExtension('unit.ppu'), '.ppu is not a source');
  Expect(not TSourceWatcher.HasSourceExtension('notes.txt'), '.txt is not a source');
  Expect(not TSourceWatcher.HasSourceExtension('pas'), 'a name without an extension');
end;

procedure TestContentDigest;
begin
  { computed by hand with the same seed and prime }
  ExpectEqual(IntToHex(TSourceWatcher.ContentDigest(''), 16), '14650FB0739D0383', 'the digest of nothing is the seed');
  ExpectEqual(IntToHex(TSourceWatcher.ContentDigest('a'), 16), '44BD8AD473CD9906', 'the digest of "a"');
  ExpectEqual(IntToHex(TSourceWatcher.ContentDigest('foobar'), 16), '88FAD7C0A8FF07F2', 'the digest of "foobar"');
  Expect(TSourceWatcher.ContentDigest('unit A;') <> TSourceWatcher.ContentDigest('unit B;'), 'other text, other digest');
end;

procedure TestSameStamps;
var
  First, Second: TFileStamps;
begin
  SetLength(First, 1);
  First[0].Path := 'a.pas';
  First[0].Size := 10;
  First[0].Time := 100;
  SetLength(Second, 1);
  Second[0] := First[0];
  Expect(TSourceWatcher.SameStamps(First, Second), 'equal stamps');
  Second[0].Size := 11;
  Expect(not TSourceWatcher.SameStamps(First, Second), 'another size');
  Second[0] := First[0];
  Second[0].Time := 101;
  Expect(not TSourceWatcher.SameStamps(First, Second), 'another time');
  Second[0] := First[0];
  Second[0].Path := 'b.pas';
  Expect(not TSourceWatcher.SameStamps(First, Second), 'another file');
  SetLength(Second, 2);
  Expect(not TSourceWatcher.SameStamps(First, Second), 'another number of files');
  SetLength(First, 0);
  SetLength(Second, 0);
  Expect(TSourceWatcher.SameStamps(First, Second), 'no files at all');
end;

procedure TestChangedFiles;
var
  Previous, Current, Changed: TStringList;
begin
  Previous := TStringList.Create;
  Current := TStringList.Create;
  try
    Previous.Add('/src/a.pas=0000000000000001');
    Previous.Add('/src/b.pas=0000000000000002');
    Current.Add('/src/a.pas=0000000000000001');
    Current.Add('/src/b.pas=00000000000000FF');
    Current.Add('/src/c.pas=0000000000000003');
    Changed := TSourceWatcher.ChangedFiles(Previous, Current);
    try
      ExpectEqual(Changed.Count, 2, 'a changed and a new file');
      ExpectEqual(Changed[0], '/src/b.pas', 'the changed file');
      ExpectEqual(Changed[1], '/src/c.pas', 'the new file');
    finally
      Changed.Free;
    end;
    Changed := TSourceWatcher.ChangedFiles(nil, Current);
    try
      ExpectEqual(Changed.Count, 3, 'without a previous state every file changed');
    finally
      Changed.Free;
    end;
    Changed := TSourceWatcher.ChangedFiles(Current, Current);
    try
      ExpectEqual(Changed.Count, 0, 'nothing changed');
    finally
      Changed.Free;
    end;
    { a path may have = in it, and differ from another only in case }
    Previous.Clear;
    Current.Clear;
    Previous.Add('/a=b/one.pas=0000000000000001');
    Previous.Add('/a=b/two.pas=0000000000000002');
    Previous.Add('/a=b/A.inc=0000000000000003');
    Previous.Add('/a=b/a.inc=0000000000000004');
    Current.Assign(Previous);
    Changed := TSourceWatcher.ChangedFiles(Previous, Current);
    try
      ExpectEqual(Changed.Count, 0, 'files under a directory with = in its name, as they were');
    finally
      Changed.Free;
    end;
    Current[3] := '/a=b/a.inc=00000000000000FF';
    Changed := TSourceWatcher.ChangedFiles(Previous, Current);
    try
      ExpectEqual(Changed.CommaText, '/a=b/a.inc', 'the one of two files that differ in case that changed');
    finally
      Changed.Free;
    end;
  finally
    Previous.Free;
    Current.Free;
  end;
end;

function Stamp(const APath: string; const ASize: Int64; const ATime: Int64): TFileStamp;
begin
  Result.Path := APath;
  Result.Size := ASize;
  Result.Time := ATime;
end;

procedure TestChangedStamps;
var
  Old, New: TFileStamps;
  Changed: TStringList;
begin
  SetLength(Old, 4);
  Old[0] := Stamp('/src/a.pas', 10, 100);
  Old[1] := Stamp('/src/b.pas', 20, 100);
  Old[2] := Stamp('/src/c.pas', 30, 100);
  Old[3] := Stamp('/src/gone.pas', 40, 100);
  SetLength(New, 4);
  New[0] := Stamp('/src/a.pas', 10, 100);
  New[1] := Stamp('/src/b.pas', 21, 100);
  New[2] := Stamp('/src/c.pas', 30, 101);
  New[3] := Stamp('/src/new.pas', 50, 101);
  Changed := TSourceWatcher.ChangedStamps(Old, New);
  try
    ExpectEqual(Changed.CommaText, '/src/b.pas,/src/c.pas,/src/new.pas,/src/gone.pas',
      'another size, another time, a new file and a file that is gone, but not a file as it was');
  finally
    Changed.Free;
  end;
  Changed := TSourceWatcher.ChangedStamps(New, New);
  try
    ExpectEqual(Changed.Count, 0, 'nothing changed');
  finally
    Changed.Free;
  end;
end;

{ An empty file is a save in progress only when a save made it empty, and only until the next
  look at the contents: an empty file that stays as it was holds nothing back, and another
  file saved meanwhile doesn't end the wait. }
procedure TestAwaitEmptied;
var
  Old, New, Peer: TFileStamps;
  Emptied: TStringList;
begin
  SetLength(Old, 2);
  Old[0] := Stamp('/src/a.pas', 10, 100);
  Old[1] := Stamp('/src/unused.inc', 0, 90);
  SetLength(New, 2);
  New[0] := Stamp('/src/a.pas', 12, 101);
  New[1] := Stamp('/src/unused.inc', 0, 90);
  Emptied := TStringList.Create;
  try
    Expect(not TSourceWatcher.AwaitEmptied(Old, New, 10.0, 0.5, Emptied), 'an empty file that did not change');
    New[0] := Stamp('/src/a.pas', 0, 101);
    Expect(TSourceWatcher.AwaitEmptied(Old, New, 10.0, 0.5, Emptied), 'a file the save emptied');
    Expect(TSourceWatcher.AwaitEmptied(New, New, 10.2, 0.5, Emptied), 'still, at a look before the wait is over');
    SetLength(Peer, 3);
    Peer[0] := New[0];
    Peer[1] := New[1];
    Peer[2] := Stamp('/src/b.pas', 30, 101);
    Expect(TSourceWatcher.AwaitEmptied(New, Peer, 10.3, 0.5, Emptied),
      'still, when another file is saved meanwhile and the emptied one has not changed again');
    Expect(not TSourceWatcher.AwaitEmptied(Peer, Peer, 10.5, 0.5, Emptied), 'no longer half a second after it was seen');
    Expect(not TSourceWatcher.AwaitEmptied(Peer, Peer, 12.0, 0.5, Emptied), 'nor later, while it stays empty');
    Peer[0] := Stamp('/src/a.pas', 12, 102);
    Expect(not TSourceWatcher.AwaitEmptied(Peer, Peer, 12.1, 0.5, Emptied), 'a file written again');
    ExpectEqual(Emptied.Count, 0, 'is no longer an emptied file');
    New[0] := Stamp('/src/a.pas', 0, 103);
    Expect(TSourceWatcher.AwaitEmptied(Peer, New, 13.0, 0.5, Emptied), 'until a save empties it again');
    Emptied.Clear;
    SetLength(New, 3);
    New[0] := Stamp('/src/a.pas', 10, 100);
    New[2] := Stamp('/src/c.pas', 0, 101);
    Expect(TSourceWatcher.AwaitEmptied(Old, New, 20.0, 0.5, Emptied), 'a new file that is empty');
  finally
    Emptied.Free;
  end;
end;

{ A file is kept by its whole path: one with = in it, and two whose names differ in case only,
  each wait for their own save. }
procedure TestAwaitEmptiedPaths;
var
  Old, New: TFileStamps;
  Emptied: TStringList;
begin
  SetLength(Old, 3);
  Old[0] := Stamp('/src/a=b.inc', 10, 100);
  Old[1] := Stamp('/src/A.pas', 10, 100);
  Old[2] := Stamp('/src/a.pas', 10, 100);
  New := Copy(Old);
  New[0] := Stamp('/src/a=b.inc', 0, 101);
  Emptied := TStringList.Create;
  try
    Expect(TSourceWatcher.AwaitEmptied(Old, New, 10.0, 0.5, Emptied), 'a path with = that a save emptied');
    Expect(TSourceWatcher.AwaitEmptied(New, New, 10.25, 0.5, Emptied), 'still, at a look before its wait is over');
    Expect(Abs(TSourceWatcher.EmptiedDeadline(Emptied, 10.25, 0.5) - 10.5) < 1E-9, 'until half a second after it was seen');
    Old := Copy(New);
    New[0] := Stamp('/src/a=b.inc', 12, 102);
    New[1] := Stamp('/src/A.pas', 0, 102);
    Expect(TSourceWatcher.AwaitEmptied(Old, New, 11.0, 0.5, Emptied), 'A.pas emptied');
    Old := Copy(New);
    New[2] := Stamp('/src/a.pas', 0, 103);
    Expect(TSourceWatcher.AwaitEmptied(Old, New, 11.25, 0.5, Emptied), 'and a.pas after it');
    Expect(Abs(TSourceWatcher.EmptiedDeadline(Emptied, 11.25, 0.5) - 11.5) < 1E-9, 'the first of the two waits ends first');
    Expect(TSourceWatcher.AwaitEmptied(New, New, 11.5, 0.5, Emptied), 'a.pas still waits once A.pas no longer does');
    Expect(Abs(TSourceWatcher.EmptiedDeadline(Emptied, 11.5, 0.5) - 11.75) < 1E-9, 'until half a second after a.pas was seen');
    Expect(not TSourceWatcher.AwaitEmptied(New, New, 11.75, 0.5, Emptied), 'and no longer then');
    New[1] := Stamp('/src/A.pas', 5, 104);
    New[2] := Stamp('/src/a.pas', 5, 104);
    Expect(not TSourceWatcher.AwaitEmptied(New, New, 12.0, 0.5, Emptied), 'both written again');
    Expect(TSourceWatcher.EmptiedDeadline(Emptied, 12.0, 0.5) = 0, 'no wait is left');
    { at the clock's time of day, as NowSeconds gives it }
    Old := Copy(New);
    New[2] := Stamp('/src/a.pas', 0, 105);
    Expect(TSourceWatcher.AwaitEmptied(Old, New, 4004736912.25, 0.5, Emptied), 'a file emptied now');
    Expect(Abs(TSourceWatcher.EmptiedDeadline(Emptied, 4004736912.25, 0.5) - 4004736912.75) < 1E-6,
      'waits half a second, to the millisecond');
  finally
    Emptied.Free;
  end;
end;

{ Two include files whose names differ only in case, where the file system keeps both: the
  watcher's stamps have both, so a save that empties either holds the next compile back,
  also while the other is saved. }
procedure TestAwaitEmptiedThroughTheWatcher;
var
  Root, Contents: string;
  Watcher: TSourceWatcher;
  Options, Emptied: TStringList;
  Old, New: TFileStamps;
begin
  Root := MakeTestDirectory('await-emptied-case');
  WriteTestFile(Root + 'u.pas', 'unit U;');
  WriteTestFile(Root + 'A.inc', '{ upper }');
  WriteTestFile(Root + 'a.inc', '{ lower }');
  if not (ReadFileContents(Root + 'A.inc', Contents) and (Contents = '{ upper }')) then
    Exit;
  Options := TStringList.Create;
  Emptied := TStringList.Create;
  Watcher := TSourceWatcher.Create(Root, Options);
  try
    Old := Watcher.Stamps;
    WriteTestFile(Root + 'a.inc', '');
    WriteTestFile(Root + 'A.inc', '{ UPPER, saved }');
    New := Watcher.Stamps;
    Expect(TSourceWatcher.AwaitEmptied(Old, New, 10.0, 0.5, Emptied), 'a.inc emptied while A.inc is saved');
    ExpectEqual(Emptied.Count, 1, 'one file waits');
    if Emptied.Count = 1 then
      ExpectEqual(EmptiedPath(Emptied[0]), Root + 'a.inc', 'a.inc');
    Old := New;
    WriteTestFile(Root + 'a.inc', '{ lower, saved }');
    WriteTestFile(Root + 'A.inc', '');
    New := Watcher.Stamps;
    Expect(TSourceWatcher.AwaitEmptied(Old, New, 10.25, 0.5, Emptied), 'A.inc emptied once a.inc has content again');
    ExpectEqual(Emptied.Count, 1, 'one file waits then too');
    if Emptied.Count = 1 then
      ExpectEqual(EmptiedPath(Emptied[0]), Root + 'A.inc', 'A.inc');
  finally
    Watcher.Free;
    Emptied.Free;
    Options.Free;
  end;
end;

{ What a compile checks when it is done: whether the sources it started from changed
  meanwhile. }
procedure TestChangedSince;
var
  Root: string;
  Watcher: TSourceWatcher;
  Options, Digests, Changed: TStringList;
  Stamps: TFileStamps;
begin
  Root := MakeTestDirectory('changed-since');
  WriteTestFile(Root + 'main.pas', 'program Main;');
  WriteTestFile(Root + 'u.pas', 'unit U; { one }');
  Options := TStringList.Create;
  Watcher := TSourceWatcher.Create(Root, Options);
  try
    Stamps := Watcher.Stamps;
    Expect(Watcher.ReadDigests(Digests), 'digests of the sources');
    try
      Changed := Watcher.ChangedSince(Stamps, Digests);
      try
        ExpectEqual(Changed.Count, 0, 'sources as they were');
      finally
        Changed.Free;
      end;
      { the same size; the stamps taken after it stand for an edit within the same second }
      WriteTestFile(Root + 'u.pas', 'unit U; { two }');
      Stamps := Watcher.Stamps;
      Changed := Watcher.ChangedSince(Stamps, Digests);
      try
        ExpectEqual(Changed.Count, 1, 'an edit that only the content shows');
        if Changed.Count = 1 then
          ExpectEqual(Changed[0], Root + 'u.pas', 'names the file');
      finally
        Changed.Free;
      end;
      Changed := Watcher.ChangedSince(Stamps, nil);
      try
        ExpectEqual(Changed.Count, 0, 'without digests only the sizes and times count');
      finally
        Changed.Free;
      end;
      WriteTestFile(Root + 'w.pas', 'unit W;');
      DeleteFile(Root + 'u.pas');
      Changed := Watcher.ChangedSince(Stamps, Digests);
      try
        ExpectEqual(Changed.Count, 2, 'a new file and a file that is gone');
        if Changed.Count = 2 then
        begin
          ExpectEqual(Changed[0], Root + 'w.pas', 'the new file');
          ExpectEqual(Changed[1], Root + 'u.pas', 'the file that is gone');
        end;
      finally
        Changed.Free;
      end;
    finally
      Digests.Free;
    end;
  finally
    Watcher.Free;
    Options.Free;
  end;
end;

{ The sources of a program whose directory has = in its name, two of them differing only in
  case where the file system keeps both: the watcher keeps each by its whole path, so it
  sees them as they were and names the one that changed. }
procedure TestWatchedPaths;
var
  Root, Contents: string;
  Watcher: TSourceWatcher;
  Options, Files, Digests, Changed: TStringList;
  Stamps: TFileStamps;
  BothCases: Boolean;
begin
  Root := MakeTestDirectory('watched-paths') + 'p=q' + PathDelim;
  WriteTestFile(Root + 'main.pas', 'program Main;');
  WriteTestFile(Root + 'u.pas', 'unit U;');
  WriteTestFile(Root + 'A.inc', '{ upper }');
  WriteTestFile(Root + 'a.inc', '{ lower }');
  BothCases := ReadFileContents(Root + 'A.inc', Contents) and (Contents = '{ upper }');
  Options := TStringList.Create;
  Watcher := TSourceWatcher.Create(Root, Options);
  try
    Files := Watcher.Files;
    try
      if BothCases then
      begin
        ExpectEqual(Files.Count, 4, 'every file, also two whose names differ only in case');
        Expect((Files.IndexOf(Root + 'A.inc') >= 0) and (Files.IndexOf(Root + 'a.inc') >= 0), 'both of them');
      end
      else
        ExpectEqual(Files.Count, 3, 'every file');
    finally
      Files.Free;
    end;
    Stamps := Watcher.Stamps;
    Expect(Watcher.ReadDigests(Digests), 'digests of the sources');
    try
      Changed := Watcher.ChangedSince(Stamps, Digests);
      try
        ExpectEqual(Changed.CommaText, '', 'the sources as they were, under a directory with = in its name');
      finally
        Changed.Free;
      end;
      if BothCases then
      begin
        { the same size; the stamps taken after it stand for an edit within the same tick }
        WriteTestFile(Root + 'a.inc', '{ LOWER }');
        Stamps := Watcher.Stamps;
        Changed := Watcher.ChangedSince(Stamps, Digests);
        try
          ExpectEqual(Changed.CommaText, Root + 'a.inc', 'an edit of one of two files that differ in case names that one');
        finally
          Changed.Free;
        end;
      end;
    finally
      Digests.Free;
    end;
  finally
    Watcher.Free;
    Options.Free;
  end;
end;

{ A save that writes a file and then puts its content back, within one second and at the
  same size, as one during a compile may: the stamps show it, as file systems keep finer
  times than seconds. Each write waits out the tick of the clock behind file times. }
procedure TestStampsShowARevertedSave;
var
  Root: string;
  Watcher: TSourceWatcher;
  Options, Changed: TStringList;
  Before: TFileStamps;
begin
  Root := MakeTestDirectory('reverted-save');
  Options := TStringList.Create;
  Watcher := TSourceWatcher.Create(Root, Options);
  try
    { early in a second, so that the writes below share it }
    while Frac(NowSeconds) > 0.5 do
      Sleep(10);
    WriteTestFile(Root + 'u.pas', 'unit U; { one }');
    Sleep(25);
    Before := Watcher.Stamps;
    Sleep(25);
    WriteTestFile(Root + 'u.pas', 'unit U; { two }');
    Sleep(25);
    WriteTestFile(Root + 'u.pas', 'unit U; { one }');
    Changed := TSourceWatcher.ChangedStamps(Before, Watcher.Stamps);
    try
      ExpectEqual(Changed.CommaText, Root + 'u.pas', 'a save put back within a second shows in the stamps');
    finally
      Changed.Free;
    end;
  finally
    Watcher.Free;
    Options.Free;
  end;
end;

{ Whether the stamps can show a write after a moment: every file's time older than it by more
  than a tick of the clock behind file times, or by two seconds when the time is in whole
  seconds. }
procedure TestTimesShowWrites;
var
  Stamps: TFileStamps;
  At: Int64;
begin
  At := 1000 * Int64(StampUnitsPerSecond);
  SetLength(Stamps, 2);
  Stamps[0] := Stamp('/src/old.pas', 10, 900 * Int64(StampUnitsPerSecond) + 1);
  Stamps[1] := Stamp('/src/new.pas', 10, At - Round(0.03 * StampUnitsPerSecond));
  Expect(TSourceWatcher.TimesShowWrites(Stamps, At), 'times older than a tick');
  Stamps[1].Time := At - Round(0.01 * StampUnitsPerSecond);
  Expect(not TSourceWatcher.TimesShowWrites(Stamps, At), 'not a time within a tick of the moment');
  Stamps[1].Time := At + 1;
  Expect(not TSourceWatcher.TimesShowWrites(Stamps, At), 'nor a time after it');
  Stamps[1].Time := At - 3 * Int64(StampUnitsPerSecond);
  Expect(TSourceWatcher.TimesShowWrites(Stamps, At), 'a time in whole seconds older than two seconds');
  Stamps[1].Time := At - Int64(StampUnitsPerSecond);
  Expect(not TSourceWatcher.TimesShowWrites(Stamps, At), 'but not a time in whole seconds a second before');
  Stamps[1] := Stamp('/src/gone.pas', -1, 0);
  Expect(TSourceWatcher.TimesShowWrites(Stamps, At), 'a missing file has no time to show');
  SetLength(Stamps, 0);
  Expect(TSourceWatcher.TimesShowWrites(Stamps, At), 'no files');
end;

function Absolute(const APath: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(APath));
end;

procedure TestOptionDirectories;
var
  Directories: TStringList;
  Root: string;
begin
  Root := MakeTestDirectory('options');
  Directories := TStringList.Create;
  try
    TSourceWatcher.AddOptionDirectories('-O2', Directories);
    TSourceWatcher.AddOptionDirectories('-Fe/tmp/errors', Directories);
    TSourceWatcher.AddOptionDirectories('-FU/tmp/units', Directories);
    ExpectEqual(Directories.Count, 0, 'only -Fu and -Fi name source directories');
    TSourceWatcher.AddOptionDirectories('-Fulib', Directories);
    TSourceWatcher.AddOptionDirectories('-Fiinclude', Directories);
    ExpectEqual(Directories.Count, 2, '-Fu and -Fi');
    ExpectEqual(Directories[0], Absolute('lib'), 'a relative -Fu path is taken from the current directory');
    ExpectEqual(Directories[1], Absolute('include'), 'a relative -Fi path too');
    Directories.Clear;
    TSourceWatcher.AddOptionDirectories('-Fu' + Root + 'one;two;;' + Root + 'three' + PathDelim, Directories);
    ExpectEqual(Directories.Count, 3, 'several paths separated by ;, empty ones skipped');
    ExpectEqual(Directories[0], ExcludeTrailingPathDelimiter(Root + 'one'), 'first path');
    ExpectEqual(Directories[1], Absolute('two'), 'second path, relative');
    ExpectEqual(Directories[2], ExcludeTrailingPathDelimiter(Root + 'three'), 'a trailing path delimiter goes');
    Directories.Clear;
    TSourceWatcher.AddOptionDirectories('-Fuvendor' + PathDelim + '*;kept', Directories);
    ExpectEqual(Directories.Count, 1, 'a path with a wildcard is not watched');
    ExpectEqual(Directories[0], Absolute('kept'), 'the path without one is');
    Directories.Clear;
    TSourceWatcher.AddOptionDirectories('@' + Root + 'missing.cfg', Directories);
    ExpectEqual(Directories.Count, 0, 'a response file that does not exist');
  finally
    Directories.Free;
  end;
end;

procedure TestResponseFile;
var
  Directories: TStringList;
  Root: string;
begin
  Root := MakeTestDirectory('response');
  { Paths in a response file are separated by blanks, so these are relative ones. }
  WriteTestFile(Root + 'lwpt.cfg',
    '# a comment with -Fucomment' + LineEnding
    + '; another comment with -Fusemicolon' + LineEnding
    + LineEnding
    + '-Fuone;two  -Fithree' + LineEnding
    + '  -O2 -Fufour' + LineEnding
    + '@nested.cfg' + LineEnding
    + '-Fe/tmp/errors' + LineEnding);
  WriteTestFile(Root + 'nested.cfg', '-Funested' + LineEnding);
  Directories := TStringList.Create;
  try
    TSourceWatcher.AddOptionDirectories('@' + Root + 'lwpt.cfg', Directories);
    ExpectEqual(Directories.Count, 4, 'the directories of the response file');
    ExpectEqual(Directories[0], Absolute('one'), 'first path of a -Fu');
    ExpectEqual(Directories[1], Absolute('two'), 'second path of the same -Fu');
    ExpectEqual(Directories[2], Absolute('three'), '-Fi after a blank');
    ExpectEqual(Directories[3], Absolute('four'), 'an option after other options on a line');
  finally
    Directories.Free;
  end;
end;

procedure TestWatchedFiles;
var
  Root, Source, Extra: string;
  Watcher: TSourceWatcher;
  Options, Files, Digests, Changed, Before: TStringList;
  Stamps, Edited: TFileStamps;
begin
  Root := MakeTestDirectory('watch');
  Source := Root + 'program' + PathDelim;
  Extra := Root + 'extra' + PathDelim;
  WriteTestFile(Source + 'main.pas', 'program Main;');
  WriteTestFile(Source + 'shared.inc', '{ shared }');
  WriteTestFile(Source + 'notes.txt', 'not a source');
  WriteTestFile(Source + 'nested' + PathDelim + 'inner.pas', 'unit Inner;');
  WriteTestFile(Extra + 'helper.pp', 'unit Helper;');
  Options := TStringList.Create;
  Options.Add('-Fu' + Extra);
  Options.Add('-O2');
  Watcher := TSourceWatcher.Create(Source, Options);
  try
    ExpectEqual(Watcher.Directories.Count, 2, 'the source directory and the -Fu directory');
    ExpectEqual(Watcher.Directories[0], ExcludeTrailingPathDelimiter(Source), 'the source directory comes first');
    Files := Watcher.Files;
    try
      ExpectEqual(Files.Count, 3, 'sources of both directories, none of the others');
      Expect(Files.IndexOf(Source + 'main.pas') >= 0, 'the program');
      Expect(Files.IndexOf(Source + 'shared.inc') >= 0, 'an include file');
      Expect(Files.IndexOf(Extra + 'helper.pp') >= 0, 'a unit of the other directory');
      Expect(Files.IndexOf(Source + 'notes.txt') < 0, 'not a text file');
    finally
      Files.Free;
    end;
    Stamps := Watcher.Stamps;
    ExpectEqual(Length(Stamps), 3, 'a stamp for each file');
    Expect(Stamps[0].Size > 0, 'a stamp has the size');
    Before := nil;
    Expect(Watcher.ReadDigests(Before), 'digests of files that all have content');
    Digests := nil;
    WriteTestFile(Source + 'main.pas', 'program Main; { edited }');
    Expect(Watcher.ReadDigests(Digests), 'digests after an edit');
    Changed := TSourceWatcher.ChangedFiles(Before, Digests);
    try
      ExpectEqual(Changed.Count, 1, 'one file changed');
      ExpectEqual(Changed[0], Source + 'main.pas', 'the edited file');
    finally
      Changed.Free;
      Digests.Free;
      Before.Free;
    end;
    Edited := Watcher.Stamps;
    Expect(not TSourceWatcher.SameStamps(Stamps, Edited), 'an edit that changes the size changes the stamps');
    WriteTestFile(Extra + 'helper.pp', '');
    Digests := nil;
    Expect(Watcher.ReadDigests(Digests), 'an empty file has a digest too');
    Expect((Digests <> nil) and (Digests.IndexOfName(Extra + 'helper.pp') >= 0), 'of no content');
    Digests.Free;
  finally
    Watcher.Free;
    Options.Free;
  end;
end;

// ---------------------------------------------------------------- tests: layouts (ppudump)
{ The check of layouts on ppudump's JSON and text output as text: what a layout holds, what
  makes two layouts differ and what does not, how the units of the program are referred to,
  the probe of a ppudump, and the history of layouts across swaps. ppudump itself is not run: a
  reader that answers from a table takes its place. }

type
  { A reader whose ppudump output is the text registered for the file's path. }
  TTableReader = class(TLayoutReader)
  private
    FPaths: TStringList;
    FOutputs: TStringList;
  protected
    function Dump(const APPUPath: string): string; override;
    function DumpText(const APPUPath: string): string; override;
  public
    constructor Create;
    destructor Destroy; override;
    { The JSON for the file. }
    procedure Register(const APath, AOutput: string);
    { The text for the file. }
    procedure RegisterText(const APath, AOutput: string);
  end;

const
  TextDumpSuffix = '#text';

constructor TTableReader.Create;
begin
  inherited Create('ppudump');
  FPaths := TStringList.Create;
  FOutputs := TStringList.Create;
end;

destructor TTableReader.Destroy;
begin
  FOutputs.Free;
  FPaths.Free;
  inherited Destroy;
end;

procedure TTableReader.Register(const APath, AOutput: string);
var
  Index: Integer;
begin
  Index := FPaths.IndexOf(APath);
  if Index < 0 then
  begin
    FPaths.Add(APath);
    FOutputs.Add(AOutput);
  end
  else
    FOutputs[Index] := AOutput;
end;

function TTableReader.Dump(const APPUPath: string): string;
var
  Index: Integer;
begin
  Index := FPaths.IndexOf(APPUPath);
  if Index < 0 then
    Result := 'Error: no such unit'
  else
    Result := FOutputs[Index];
end;

function TTableReader.DumpText(const APPUPath: string): string;
begin
  Result := Dump(APPUPath + TextDumpSuffix);
end;

procedure TTableReader.RegisterText(const APath, AOutput: string);
begin
  Register(APath + TextDumpSuffix, AOutput);
end;

{ A unit with a record of two fields, a class that has one of them and an integer, a compiler
  type, and a variable. AFirst and ASecond name the record's fields; AType is the type id of
  the first. }
function UnitJSON(const AFirst, ASecond: string; const AType: Integer; const AVariableType: Integer = 10): string;
begin
  Result :=
    '[{"Type":"unit","Name":"a","Units":["system"],"Interface":['
    + '{"Type":"rec","Name":"TPoint","Id":0,"SymId":6,"Pos":{"File":1,"Line":5,"Col":13},"Size":8,"Fields":['
    + '{"Type":"field","Name":"' + AFirst + '","SymId":0,"Pos":{"File":1,"Line":5,"Col":20},'
    + '"VarType":{"Unit":0,"Id":' + IntToStr(AType) + '}},'
    + '{"Type":"field","Name":"' + ASecond + '","SymId":1,"Pos":{"File":1,"Line":5,"Col":23},'
    + '"VarType":{"Unit":0,"Id":10}}]},'
    + '{"Type":"obj","Name":"TThing","Id":1,"SymId":7,"ObjType":"class","Ancestor":{"Unit":0,"Id":690},"Size":24,"Fields":['
    + '{"Type":"field","Name":"FCount","SymId":2,"VarType":{"Unit":0,"Id":10}},'
    + '{"Type":"field","Name":"FPoint","SymId":3,"VarType":{"Id":0}}]},'
    + '{"Type":"rec","Name":"$vmtdef$TTHING","Id":2,"SymId":8,"Size":208,"Fields":[]},'
    + '{"Type":"var","Name":"Counter","Id":3,"SymId":9,"VarType":{"Unit":0,"Id":' + IntToStr(AVariableType) + '}}'
    + ']}]';
end;

{ A unit with a variable of a type of another unit of the program, which numbers that type
  AOtherId. }
function ReferringJSON(const AOtherId: Integer): string;
begin
  Result :=
    '[{"Type":"unit","Name":"a","Units":["system","other"],"Interface":['
    + '{"Type":"var","Name":"Shared","Id":0,"VarType":{"Unit":1,"Id":' + IntToStr(AOtherId) + '}}]}]';
end;

function OtherJSON(const AOtherId: Integer): string;
begin
  Result :=
    '[{"Type":"unit","Name":"other","Units":["system"],"Interface":['
    + '{"Type":"rec","Name":"TShared","Id":' + IntToStr(AOtherId) + ',"Size":4,"Fields":[]}]}]';
end;

procedure TestLayoutContent;
var
  Reader: TLayoutReader;
  Layout: TLayout;
begin
  Reader := TLayoutReader.Create('ppudump');
  try
    Layout := Reader.ReadJSON(UnitJSON('X', 'Y', 10), '');
    try
      ExpectEqual(Layout.Count, 3, 'two types and a variable; the compiler''s own type is left out');
      ExpectEqual(Layout.Values['type TPoint'], '{Size=8 Type="rec" X:system#10 Y:system#10 }', 'a record');
      ExpectEqual(Layout.Values['type TThing'],
        '{Ancestor=system#690 ObjType="class" Size=24 Type="obj" FCount:system#10 FPoint:TPoint }',
        'a class; a field of a named type of the unit is that name');
      ExpectEqual(Layout.Values['variable Counter'], 'system#10', 'a variable is its type');
    finally
      Layout.Free;
    end;
    Layout := Reader.ReadJSON('this is not JSON', '');
    try
      ExpectEqual(Layout.Count, 0, 'text that is no JSON is an empty layout');
    finally
      Layout.Free;
    end;
    Layout := Reader.ReadJSON('Error: Unsupported PPU version', '');
    try
      ExpectEqual(Layout.Count, 0, 'so is an error message');
    finally
      Layout.Free;
    end;
    Layout := Reader.ReadJSON('[]', '');
    try
      ExpectEqual(Layout.Count, 0, 'and an empty array');
    finally
      Layout.Free;
    end;
  finally
    Reader.Free;
  end;
end;

procedure TestDifferences;
var
  Reader: TLayoutReader;
  Original, Changed: TLayout;
  Differing: TStringList;
begin
  Reader := TLayoutReader.Create('ppudump');
  Original := Reader.ReadJSON(UnitJSON('X', 'Y', 10), '');
  try
    Changed := Reader.ReadJSON(UnitJSON('X', 'Y', 10), '');
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.Count, 0, 'the same unit again');
    Differing.Free;
    Changed.Free;
    Changed := Reader.ReadJSON(UnitJSON('Y', 'X', 10), '');
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.CommaText, '"type TPoint"', 'fields that swapped places');
    Differing.Free;
    Changed.Free;
    Changed := Reader.ReadJSON(UnitJSON('X', 'Y', 11), '');
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.CommaText, '"type TPoint"', 'a field of another type');
    Differing.Free;
    Changed.Free;
    Changed := Reader.ReadJSON(UnitJSON('X', 'Y', 10, 11), '');
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.CommaText, '"variable Counter"', 'a variable of another type');
    Differing.Free;
    Changed.Free;
    Changed := Reader.ReadJSON(UnitJSON('X', 'Renamed', 10), '');
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.CommaText, '"type TPoint"', 'a field that was renamed');
    Differing.Free;
    Changed.Free;
    { a declaration only one of them has is the object file's business }
    Changed := TLayout.Create;
    Changed.Values['type TNew'] := '{}';
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.Count, 0, 'a new declaration');
    Differing.Free;
    Differing := TLayoutHistory.DifferingDeclarations(Changed, Original);
    ExpectEqual(Differing.Count, 0, 'a removed declaration');
    Differing.Free;
    Changed.Free;
  finally
    Original.Free;
    Reader.Free;
  end;
end;

procedure TestPositionsDoNotMatter;
var
  Reader: TLayoutReader;
  Original, Moved: TLayout;
  Differing: TStringList;
  Shifted: string;
begin
  Reader := TLayoutReader.Create('ppudump');
  Original := Reader.ReadJSON(UnitJSON('X', 'Y', 10), '');
  { the same unit after an edit above it: lines, columns and symbol numbers moved }
  Shifted := StringReplace(UnitJSON('X', 'Y', 10), '"Line":5', '"Line":50', [rfReplaceAll]);
  Shifted := StringReplace(Shifted, '"SymId":6', '"SymId":60', [rfReplaceAll]);
  Moved := Reader.ReadJSON(Shifted, '');
  try
    Differing := TLayoutHistory.DifferingDeclarations(Original, Moved);
    try
      ExpectEqual(Differing.Count, 0, 'positions and symbol numbers are not part of a layout');
    finally
      Differing.Free;
    end;
  finally
    Moved.Free;
    Original.Free;
    Reader.Free;
  end;
end;

procedure TestUnitsOfTheProgram;
var
  Reader: TTableReader;
  Root: string;
  First, Second, Missing, Elsewhere: TLayout;
begin
  Root := MakeTestDirectory('layout');
  WriteTestFile(Root + 'other.ppu', '');
  Reader := TTableReader.Create;
  try
    Reader.Register(Root + 'other.ppu', OtherJSON(5));
    First := Reader.ReadJSON(ReferringJSON(5), Root);
    try
      ExpectEqual(First.Values['variable Shared'], 'other.TShared', 'a type of another unit of the program is named');
    finally
      First.Free;
    end;
    { the next compile numbers the other unit's types differently; the name is the same }
    Reader.Register(Root + 'other.ppu', OtherJSON(9));
    Second := Reader.ReadJSON(ReferringJSON(9), Root);
    try
      ExpectEqual(Second.Values['variable Shared'], 'other.TShared', 'whatever its number');
    finally
      Second.Free;
    end;
    Missing := Reader.ReadJSON(ReferringJSON(5), Root);
    try
      ExpectEqual(Missing.Values['variable Shared'], 'other#5', 'a number the other unit does not have stays a number');
    finally
      Missing.Free;
    end;
    Elsewhere := Reader.ReadJSON(ReferringJSON(9), Root + 'nowhere' + PathDelim);
    try
      ExpectEqual(Elsewhere.Values['variable Shared'], 'other#9',
        'a unit that is not among the program''s is referred to by number');
    finally
      Elsewhere.Free;
    end;
  finally
    Reader.Free;
  end;
end;

procedure TestProbe;
var
  Reader: TTableReader;
  Root, Reason: string;
begin
  Root := MakeTestDirectory('probe');
  Reader := TTableReader.Create;
  try
    Expect(Reader.Probe(Root, Reason), 'with no unit yet there is nothing to try');
    ExpectEqual(Reason, '', 'and no reason');
    WriteTestFile(Root + 'a.ppu', '');
    Reader.Register(Root + 'a.ppu', UnitJSON('X', 'Y', 10));
    Expect(Reader.Probe(Root, Reason), 'a ppudump that reads the unit');
    Reader.Register(Root + 'a.ppu', 'Error: Unsupported PPU version 207 (expected 208)' + LineEnding + 'more' + LineEnding);
    Expect(not Reader.Probe(Root, Reason), 'a ppudump that does not');
    ExpectEqual(Reason, 'Error: Unsupported PPU version 207 (expected 208)', 'is explained by the first line it printed');
    Reader.Register(Root + 'a.ppu', '[{"Type":"unit","Name":"a"}]');
    Expect(not Reader.Probe(Root, Reason), 'JSON without an interface is not a unit''s');
    Reader.Register(Root + 'a.ppu', '');
    Expect(not Reader.Probe(Root, Reason), 'no output');
    ExpectEqual(Reason, '', 'has no first line to show');
  finally
    Reader.Free;
  end;
end;

procedure TestLocate;
var
  Root: string;
begin
  Root := MakeTestDirectory('locate');
  ExpectEqual(TLayoutReader.Locate(Root + 'fpc', '', ''), '', 'no ppudump next to the compiler');
  WriteTestFile(Root + 'ppudump', '');
  ExpectEqual(TLayoutReader.Locate(Root + 'fpc', '', ''), Root + 'ppudump', 'a ppudump next to it');
  ExpectEqual(TLayoutReader.Locate(Root + 'fpc', '.exe', ''), '', 'on Windows it is ppudump.exe');
  WriteTestFile(Root + 'ppudump.exe', '');
  ExpectEqual(TLayoutReader.Locate(Root + 'fpc.exe', '.exe', ''), Root + 'ppudump.exe', 'and found by that name');
  WriteTestFile(Root + 'fpc.exe', '');
  ExpectEqual(TLayoutReader.Locate('fpc', '.exe', ExcludeTrailingPathDelimiter(Root)), Root + 'ppudump.exe',
    'a bare fpc on the search path is fpc.exe on Windows');
end;

{ The lines of a text, each ended. }
function TextOfLines(const ALines: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ALines) do
    Result := Result + ALines[I] + LineEnding;
end;

{ ppudump's text for a unit whose implementation section has a record TR with the fields
  AFirst and ASecond, and the variables Calls (of the system unit's type ACallsType), Rec (a
  TR), Table (an array of TR) and the compiler's $hidden. ARecord numbers TR and the array
  comes after it: a definition added above them renumbers both. }
function UnitText(const AFirst, ASecond: string; const ACallsType: Integer; const ARecord: Integer = 2): string;
begin
  Result := TextOfLines([
    'PPU-Analyser Version 3.2.2',
    '',
    'Interface section',
    '------------------',
    'Module Name: a',
    'DerefMapsize: 1',
    'DerefMap[0] = SYSTEM',
    '',
    'Implementation symtable',
    '----------------------',
    'Symtable options: none',
    '',
    'Static definitions',
    '----------------------',
    '** Definition Id ' + IntToStr(ARecord) + ' **',
    'Record definition',
    '      Type symbol : (48) SymId 9',
    '        DefStates : ',
    '   Name of Record : TR',
    '         DataSize : 8',
    '    ------ fields ------',
    '    Symtable count: 2',
    '    ** Symbol Id 4 **',
    '    Field Variable symbol ' + AFirst,
    '         File Pos : 1 (5,18)',
    '         Var Type : (56) Unit 0, DefId 8',
    '          Address : 0',
    '    ** Symbol Id 5 **',
    '    Field Variable symbol ' + ASecond,
    '         File Pos : 1 (5,21)',
    '         Var Type : (65) Unit 0, DefId 8',
    '          Address : 4',
    '** Definition Id ' + IntToStr(ARecord + 1) + ' **',
    'Array definition',
    '      Type symbol : (649) Nil',
    '     Element type : (653) DefId ' + IntToStr(ARecord),
    '            Range : 0 to 3',
    'Symtable options: none',
    '',
    'Static Symbols',
    '------------------',
    'Symtable count: 5',
    '** Symbol Id 6 **',
    'Global Variable symbol Calls',
    '     File Pos : 1 (7,3)',
    '     Var Type : (86) Unit 0, DefId ' + IntToStr(ACallsType),
    '      Options : TypedConst',
    '** Symbol Id 7 **',
    'Global Variable symbol Rec',
    '     Var Type : (99) DefId ' + IntToStr(ARecord),
    '** Symbol Id 8 **',
    'Global Variable symbol Table',
    '     Var Type : (112) DefId ' + IntToStr(ARecord + 1),
    '** Symbol Id 9 **',
    'Type symbol TR',
    '  Result Type : (80) DefId ' + IntToStr(ARecord),
    '** Symbol Id 10 **',
    'Global Variable symbol $hidden',
    '     Var Type : (120) Unit 0, DefId 8',
    '',
    'WPO info',
    '--------']);
end;

{ ppudump's text for a unit whose implementation section has a variable of a record type of
  another unit of the program, which numbers that type AOtherId; the other unit comes second
  in the DerefMap. }
function ReferringText(const AOtherId: Integer): string;
begin
  Result := TextOfLines([
    'Interface section',
    '------------------',
    'DerefMap[0] = SYSTEM',
    'DerefMap[1] = OTHER',
    'Static Symbols',
    '------------------',
    '** Symbol Id 3 **',
    'Global Variable symbol Shared',
    '     Var Type : (40) Unit 1, DefId ' + IntToStr(AOtherId)]);
end;

function OtherText(const AOtherId: Integer): string;
begin
  Result := TextOfLines([
    'Interface definitions',
    '----------------------',
    '** Definition Id ' + IntToStr(AOtherId) + ' **',
    'Record definition',
    '   Name of Record : TShared',
    '         DataSize : 4']);
end;

procedure TestImplementationContent;
var
  Reader: TLayoutReader;
  Layout: TLayout;
begin
  Reader := TLayoutReader.Create('ppudump');
  try
    Layout := Reader.ReadText(UnitText('X', 'Y', 8), '');
    try
      ExpectEqual(Layout.Count, 4, 'three variables and a record; the compiler''s own variable is left out');
      ExpectEqual(Layout.Values['variable Calls'], 'SYSTEM#8', 'a variable of a type of the runtime');
      ExpectEqual(Layout.Values['variable Rec'], 'TR', 'a variable of a record of the unit is its name');
      ExpectEqual(Layout.Values['variable Table'], '{Array definition Element type=TR Range=0 to 3 }',
        'a variable of another type is that type''s text');
      ExpectEqual(Layout.Values['type TR'], '{Record definition DataSize=8 X:SYSTEM#8@0 Y:SYSTEM#8@4 }',
        'a record is its size and its fields with their types and places');
    finally
      Layout.Free;
    end;
    Layout := Reader.ReadText('Error: Unsupported PPU version', '');
    try
      ExpectEqual(Layout.Count, 0, 'an error message is an empty layout');
    finally
      Layout.Free;
    end;
  finally
    Reader.Free;
  end;
end;

procedure TestImplementationDifferences;
var
  Reader: TLayoutReader;
  Original, Changed: TLayout;
  Differing: TStringList;
  Shifted: string;
begin
  Reader := TLayoutReader.Create('ppudump');
  Original := Reader.ReadText(UnitText('X', 'Y', 8), '');
  try
    Changed := Reader.ReadText(UnitText('X', 'Y', 8, 5), '');
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.Count, 0, 'definitions that were numbered again');
    Differing.Free;
    Changed.Free;
    { the same unit after an edit above it: positions, offsets and symbol numbers moved }
    Shifted := StringReplace(UnitText('X', 'Y', 8), '(5,', '(50,', [rfReplaceAll]);
    Shifted := StringReplace(Shifted, '(56)', '(156)', [rfReplaceAll]);
    Shifted := StringReplace(Shifted, 'SymId 9', 'SymId 19', [rfReplaceAll]);
    Changed := Reader.ReadText(Shifted, '');
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.Count, 0, 'positions, offsets and symbol numbers are not part of a layout');
    Differing.Free;
    Changed.Free;
    Changed := Reader.ReadText(UnitText('X', 'Y', 9), '');
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.CommaText, '"variable Calls"', 'a variable of another type, such as Integer to Int64');
    Differing.Free;
    Changed.Free;
    Changed := Reader.ReadText(UnitText('Y', 'X', 8), '');
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.CommaText, '"type TR"', 'fields that swapped places');
    Differing.Free;
    Changed.Free;
    Changed := Reader.ReadText(StringReplace(UnitText('X', 'Y', 8), '0 to 3', '0 to 7', []), '');
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.CommaText, '"variable Table"', 'an array that grew');
    Differing.Free;
    Changed.Free;
  finally
    Original.Free;
  end;
  { ppudump prints a record's minimum alignment twice, as RecordAlignMin and recordalignmin }
  Original := Reader.ReadText(StringReplace(UnitText('X', 'Y', 8), '         DataSize : 8',
    '         DataSize : 8' + LineEnding + '   RecordAlignMin : 0' + LineEnding + '     recordalignmin: 0', []), '');
  Changed := Reader.ReadText(StringReplace(UnitText('X', 'Y', 8), '         DataSize : 8',
    '         DataSize : 8' + LineEnding + '     recordalignmin: 0' + LineEnding + '   RecordAlignMin : 0', []), '');
  try
    Differing := TLayoutHistory.DifferingDeclarations(Original, Changed);
    ExpectEqual(Differing.Count, 0, 'keys that differ only in case are in the same order whatever order ppudump prints them in');
    Differing.Free;
  finally
    Changed.Free;
    Original.Free;
    Reader.Free;
  end;
end;

procedure TestImplementationUnitsOfTheProgram;
var
  Reader: TTableReader;
  Root: string;
  Layout: TLayout;
begin
  Root := MakeTestDirectory('implementation');
  WriteTestFile(Root + 'other.ppu', '');
  Reader := TTableReader.Create;
  try
    Reader.RegisterText(Root + 'other.ppu', OtherText(5));
    Layout := Reader.ReadText(ReferringText(5), Root);
    try
      ExpectEqual(Layout.Values['variable Shared'], 'OTHER.TShared', 'a record of another unit of the program is named');
    finally
      Layout.Free;
    end;
    Reader.RegisterText(Root + 'other.ppu', OtherText(9));
    Layout := Reader.ReadText(ReferringText(9), Root);
    try
      ExpectEqual(Layout.Values['variable Shared'], 'OTHER.TShared', 'whatever its number');
    finally
      Layout.Free;
    end;
    Layout := Reader.ReadText(ReferringText(9), Root + 'nowhere' + PathDelim);
    try
      ExpectEqual(Layout.Values['variable Shared'], 'OTHER#9',
        'a unit that is not among the program''s is referred to by number');
    finally
      Layout.Free;
    end;
  finally
    Reader.Free;
  end;
end;

procedure TestHistory;
var
  Reader: TTableReader;
  History: TLayoutHistory;
  Root, Live, Units: string;
  Differing: TStringList;
begin
  Root := MakeTestDirectory('history');
  Live := Root + 'live' + PathDelim;
  Units := Root + 'units' + PathDelim;
  Reader := TTableReader.Create;
  History := TLayoutHistory.Create(Reader, Live, Units);
  try
    Reader.Register(Live + 'a.ppu', UnitJSON('X', 'Y', 10));
    Reader.Register(Units + 'a.ppu', UnitJSON('X', 'Y', 10));
    Differing := History.Differences('a.ppu');
    ExpectEqual(Differing.Count, 0, 'an unchanged interface');
    Differing.Free;
    { the program keeps what it has until a swap is accepted }
    Reader.Register(Live + 'a.ppu', 'Error: the running unit is not read again');
    Reader.Register(Units + 'a.ppu', UnitJSON('Y', 'X', 10));
    Differing := History.Differences('a.ppu');
    ExpectEqual(Differing.CommaText, '"type TPoint"', 'fields that swapped places are found against the running unit');
    Differing.Free;
    Reader.Register(Units + 'a.ppu', UnitJSON('X', 'Y', 10, 11));
    Differing := History.Differences('a.ppu');
    ExpectEqual(Differing.CommaText, '"variable Counter"', 'a refused change does not become the running one');
    Differing.Free;
    Reader.Register(Units + 'a.ppu', UnitJSON('X', 'Y', 10));
    Differing := History.Differences('a.ppu');
    ExpectEqual(Differing.Count, 0, 'the original interface again');
    Differing.Free;
    History.Accept('a.ppu');
    { the accepted layout is what later saves are compared with }
    Reader.Register(Units + 'a.ppu', UnitJSON('X', 'Y', 11));
    Differing := History.Differences('a.ppu');
    ExpectEqual(Differing.CommaText, '"type TPoint"', 'after a swap the next change is compared with it');
    Differing.Free;
    History.Accept('b.ppu');
    { the implementation section is part of the layout }
    Reader.Register(Live + 'c.ppu', UnitJSON('X', 'Y', 10));
    Reader.RegisterText(Live + 'c.ppu', UnitText('X', 'Y', 8));
    Reader.Register(Units + 'c.ppu', UnitJSON('X', 'Y', 10));
    Reader.RegisterText(Units + 'c.ppu', UnitText('X', 'Y', 9));
    Differing := History.Differences('c.ppu');
    ExpectEqual(Differing.CommaText, '"variable Calls"', 'a variable of the implementation section that changed its type');
    Differing.Free;
  finally
    History.Free;
    Reader.Free;
  end;
end;

// ---------------------------------------------------------------- tests: sizes of initialised data (assembler)
{ The sizes read from fpc's assembler output, what counts as a change, how the names print,
  and which object files have initialised data. The texts are cut from what fpc 3.2.2 and
  3.3.1 write for win64 with -s -Aas; fpc itself is not run. }

const
  { fpc 3.2.2: a program's two variables with an initial value, the second an Int64, then
    the start of the next list }
  ProgramAssembler322 =
    '# Begin asmlist al_typedconsts' + LineEnding +
    '' + LineEnding +
    '.section .data.n_TC_$P$PROG_$$_COUNT,"d"' + LineEnding +
    #9'.balign 4' + LineEnding +
    'TC_$P$PROG_$$_COUNT:' + LineEnding +
    #9'.long'#9'0' + LineEnding +
    '' + LineEnding +
    '.section .data.n_TC_$P$PROG_$$_CALLS,"d"' + LineEnding +
    #9'.balign 8' + LineEnding +
    'TC_$P$PROG_$$_CALLS:' + LineEnding +
    #9'.quad'#9'0' + LineEnding +
    '# End asmlist al_typedconsts' + LineEnding +
    '# Begin asmlist al_dwarf_frame' + LineEnding +
    '' + LineEnding +
    '.section .debug_frame' + LineEnding +
    '.Lc6:' + LineEnding +
    #9'.long'#9'.Lc8-.Lc7' + LineEnding;
  { fpc 3.3.1: a unit's typed constants, each with .globl before its label: a record with its
    padding, a shortstring, a pointer to a literal, and one more variable }
  UnitAssembler331 =
    '.section .data.n_TC_$SHAPES_$$_CREC,"aw"' + LineEnding +
    #9'.balign 8' + LineEnding +
    '.globl'#9'TC_$SHAPES_$$_CREC' + LineEnding +
    'TC_$SHAPES_$$_CREC:' + LineEnding +
    #9'.byte'#9'1,0,0,0,0,0,0,0' + LineEnding +
    #9'.quad'#9'2' + LineEnding +
    '' + LineEnding +
    '.section .data.n_TC_$SHAPES_$$_CSHORT255,"aw"' + LineEnding +
    '.globl'#9'TC_$SHAPES_$$_CSHORT255' + LineEnding +
    'TC_$SHAPES_$$_CSHORT255:' + LineEnding +
    #9'.byte'#9'19' + LineEnding +
    #9'.ascii'#9'"hello \"world\" \\ end\000                         "' + LineEnding +
    #9'.ascii'#9'"                                                   "' + LineEnding +
    #9'.ascii'#9'"                                                   "' + LineEnding +
    #9'.ascii'#9'"                                                   "' + LineEnding +
    #9'.ascii'#9'"                                                   "' + LineEnding +
    #9'.ascii'#9'"      "' + LineEnding +
    '' + LineEnding +
    '.section .data.n_TC_$SHAPES_$$_CGUID,"aw"' + LineEnding +
    #9'.balign 4' + LineEnding +
    '.globl'#9'TC_$SHAPES_$$_CGUID' + LineEnding +
    'TC_$SHAPES_$$_CGUID:' + LineEnding +
    #9'.long'#9'19088743' + LineEnding +
    #9'.short'#9'35243,52719' + LineEnding +
    #9'.byte'#9'1,35,69,103,137,171,205,239' + LineEnding +
    '' + LineEnding +
    '.section .data.n_TC_$SHAPES_$$_CANSI,"aw"' + LineEnding +
    #9'.balign 8' + LineEnding +
    '.globl'#9'TC_$SHAPES_$$_CANSI' + LineEnding +
    'TC_$SHAPES_$$_CANSI:' + LineEnding +
    #9'.quad'#9'.Ld1' + LineEnding +
    '' + LineEnding +
    '.section .data.n_TC_$SHAPES$_$LOCAL$$LONGINT_$$_LCOUNT,"aw"' + LineEnding +
    #9'.balign 4' + LineEnding +
    'TC_$SHAPES$_$LOCAL$$LONGINT_$$_LCOUNT:' + LineEnding +
    #9'.long'#9'0' + LineEnding;

procedure TestReadDataSizes;
var
  Sizes: TStringList;
begin
  Sizes := TDataSizes.Read(ProgramAssembler322);
  try
    ExpectEqual(Sizes.Count, 2, 'the program''s two variables with an initial value');
    ExpectEqual(Sizes.Values['TC_$P$PROG_$$_COUNT'], '4', 'an Integer');
    ExpectEqual(Sizes.Values['TC_$P$PROG_$$_CALLS'], '8', 'an Int64, up to the next section');
  finally
    Sizes.Free;
  end;
  Sizes := TDataSizes.Read(UnitAssembler331);
  try
    ExpectEqual(Sizes.Count, 5, 'every typed constant');
    ExpectEqual(Sizes.Values['TC_$SHAPES_$$_CREC'], '16', 'a record with its padding');
    ExpectEqual(Sizes.Values['TC_$SHAPES_$$_CSHORT255'], '256', 'a ShortString, its escapes as one byte each');
    ExpectEqual(Sizes.Values['TC_$SHAPES_$$_CGUID'], '16', 'values of several widths');
    ExpectEqual(Sizes.Values['TC_$SHAPES_$$_CANSI'], '8', 'a pointer to a literal');
    ExpectEqual(Sizes.Values['TC_$SHAPES$_$LOCAL$$LONGINT_$$_LCOUNT'], '4', 'a routine''s typed constant');
  finally
    Sizes.Free;
  end;
  Sizes := TDataSizes.Read('.section .data.n_TC_$U_$$_A,"d"' + LineEnding + 'TC_$U_$$_A:' + LineEnding
    + #9'.zero'#9'24' + LineEnding + 'TC_$U_$$_B:' + LineEnding + #9'.sleb128'#9'3' + LineEnding
    + 'U_$U_$$_C:' + LineEnding + #9'.long'#9'5' + LineEnding);
  try
    ExpectEqual(Sizes.Values['TC_$U_$$_A'], '24', 'zero bytes, up to the next label');
    ExpectEqual(Sizes.Values['TC_$U_$$_B'], UnknownSize, 'data it cannot count gives an unknown size');
    Expect(Sizes.IndexOfName('U_$U_$$_C') < 0, 'only initialised data counts');
  finally
    Sizes.Free;
  end;
  Sizes := TDataSizes.Read('.section .data.n_TC_$Z_$$_E,"d"' + LineEnding + 'TC_$Z_$$_E:' + LineEnding
    + LineEnding + '.section .data.n_TC_$Z_$$_F,"d"' + LineEnding + 'TC_$Z_$$_F:' + LineEnding);
  try
    ExpectEqual(Sizes.CommaText, 'TC_$Z_$$_E=0,TC_$Z_$$_F=0', 'an empty record has a size too: none');
  finally
    Sizes.Free;
  end;
  Sizes := TDataSizes.Read('');
  try
    ExpectEqual(Sizes.Count, 0, 'nothing in nothing');
  finally
    Sizes.Free;
  end;
end;

procedure TestStringBytes;
begin
  ExpectEqual(TDataSizes.StringBytes(#9'.ascii'#9'"abc"'), 3, 'plain characters');
  ExpectEqual(TDataSizes.StringBytes(#9'.ascii'#9'"abc\000      "'), 10, 'an octal escape is one byte');
  ExpectEqual(TDataSizes.StringBytes(#9'.ascii'#9'"\"x\\"'), 3, 'an escaped quote and backslash');
  ExpectEqual(TDataSizes.StringBytes(#9'.ascii'#9'"a,b: c"'), 6, 'commas and colons are characters');
  ExpectEqual(TDataSizes.StringBytes(#9'.ascii'#9'""'), 0, 'an empty string');
end;

procedure TestDataSizeChanges;
var
  Running, Compiled, Changes: TStringList;
begin
  Running := TStringList.Create;
  Compiled := TStringList.Create;
  try
    Running.Add('TC_$P$MAIN_$$_CALLS=4');
    Running.Add('TC_$P$MAIN_$$_COUNT=4');
    Running.Add('TC_$P$MAIN_$$_GONE=8');
    Compiled.Add('TC_$P$MAIN_$$_COUNT=4');
    Compiled.Add('TC_$P$MAIN_$$_CALLS=8');
    Compiled.Add('TC_$P$MAIN_$$_ADDED=2');
    Changes := TDataSizes.Changes(Running, Compiled);
    try
      ExpectEqual(Changes.Count, 1, 'one variable changed its size');
      ExpectEqual(Changes.Text, 'variable MAIN.CALLS changed size from 4 to 8 bytes' + LineEnding,
        'and is named as the agent names it');
    finally
      Changes.Free;
    end;
    Compiled.Values['TC_$P$MAIN_$$_CALLS'] := '4';
    Changes := TDataSizes.Changes(Running, Compiled);
    try
      ExpectEqual(Changes.Count, 0, 'a variable added or removed is no change of size');
    finally
      Changes.Free;
    end;
    { a size the check needs and does not have is never taken as the same }
    Compiled.Values['TC_$P$MAIN_$$_CALLS'] := UnknownSize;
    Compiled.Values['TC_$P$MAIN_$$_ADDED'] := UnknownSize;
    Running.Values['TC_$P$MAIN_$$_COUNT'] := UnknownSize;
    Changes := TDataSizes.Changes(Running, Compiled);
    try
      ExpectEqual(Changes.Text,
        UnknownSizes + 'the assembler the program started from had no size for MAIN.COUNT' + LineEnding
        + UnknownSizes + 'fpc''s assembler has no size for MAIN.CALLS' + LineEnding
        + UnknownSizes + 'fpc''s assembler has no size for MAIN.ADDED' + LineEnding,
        'an unknown size of the running program or of the save, also of a new variable, needs a restart');
    finally
      Changes.Free;
    end;
  finally
    Compiled.Free;
    Running.Free;
  end;
end;

{ The running program's sizes keep a variable that a save removed: the agent keeps it at its
  first address, so a later save that brings it back larger needs a restart. }
procedure TestKeepDataSizes;
var
  Running, Removed, Back, Changes: TStringList;
begin
  Running := TStringList.Create;
  Removed := TStringList.Create;
  Back := TStringList.Create;
  try
    Running.Add('TC_$P$MAIN_$$_COUNT=4');
    Running.Add('TC_$P$MAIN_$$_CALLS=4');
    Removed.Add('TC_$P$MAIN_$$_COUNT=4');
    Removed.Add('TC_$P$MAIN_$$_ADDED=2');
    TDataSizes.Keep(Running, Removed);
    ExpectEqual(Running.CommaText, 'TC_$P$MAIN_$$_COUNT=4,TC_$P$MAIN_$$_CALLS=4,TC_$P$MAIN_$$_ADDED=2',
      'a swap that removes CALLS and adds ADDED keeps CALLS and adds ADDED');
    Back.Add('TC_$P$MAIN_$$_CALLS=8');
    Back.Add('TC_$P$MAIN_$$_ADDED=4');
    Changes := TDataSizes.Changes(Running, Back);
    try
      ExpectEqual(Changes.Text, 'variable MAIN.CALLS changed size from 4 to 8 bytes' + LineEnding
        + 'variable MAIN.ADDED changed size from 2 to 4 bytes' + LineEnding,
        'CALLS back with another size, and ADDED with another size, each need a restart');
    finally
      Changes.Free;
    end;
    TDataSizes.Keep(Running, Back);
    ExpectEqual(Running.Values['TC_$P$MAIN_$$_CALLS'], '4', 'a size the program has is not replaced');
  finally
    Back.Free;
    Removed.Free;
    Running.Free;
  end;
end;

procedure TestPrettyDataNames;
begin
  ExpectEqual(TDataSizes.Pretty('TC_$P$MAIN_$$_CALLS'), 'MAIN.CALLS', 'the program''s variable');
  ExpectEqual(TDataSizes.Pretty('TC_$U_$$_CALLS'), 'U.CALLS', 'a unit''s');
  ExpectEqual(TDataSizes.Pretty('TC_$SHAPES$_$LOCAL$$LONGINT_$$_LCOUNT'), 'SHAPES.LOCAL:LONGINT.LCOUNT',
    'a routine''s');
  ExpectEqual(TDataSizes.Pretty('TC_$U$_$TICK$LONGINT$$LONGINT_$$_N'), 'U.TICK(LONGINT):LONGINT.N',
    'a routine''s with a parameter');
  ExpectEqual(TDataSizes.Pretty('TC_$U$_$TICK$LONGINT_$$_CALLS'), 'U.TICK(LONGINT).CALLS',
    'a procedure''s with a parameter');
  ExpectEqual(TDataSizes.Pretty('TC_$U$_$MOVE$LONGINT$SMALLINT_$$_STEPS'), 'U.MOVE(LONGINT,SMALLINT).STEPS',
    'a procedure''s with two parameters');
end;

{ A COFF object as fpc writes one, with the parts ObjectNames reads: the header, the section
  table, the symbols and the string table. }
function TestCOFFObject: string;

  function Bytes(const AValue: Int64; const ACount: Integer): string;
  var
    K: Integer;
  begin
    Result := '';
    for K := 0 to ACount - 1 do
      Result := Result + Chr((AValue shr (8 * K)) and $FF);
  end;

  function Padded(const AText: string; const ACount: Integer): string;
  begin
    Result := AText + StringOfChar(#0, ACount - Length(AText));
  end;

  function Symbol(const AName: string; const ASection, AClass, AAuxiliary: Integer): string;
  begin
    Result := AName + Bytes(0, 4) + Bytes(ASection, 2) + Bytes(0, 2) + Bytes(AClass, 1) + Bytes(AAuxiliary, 1);
  end;

const
  SectionA = '.data.n_TC_$U_$$_A';
  SymbolB = 'TC_$U_$$_B';
  SymbolC = 'TC_$V_$$_C';
var
  Strings: string;
begin
  Strings := SectionA + #0 + SymbolB + #0 + SymbolC + #0;
  { two sections, four symbols (one of them an auxiliary record) from offset 100 }
  Result := Bytes($8664, 2) + Bytes(2, 2) + Bytes(0, 4) + Bytes(100, 4) + Bytes(4, 4) + Bytes(0, 2) + Bytes(0, 2)
    + Padded('/4', 8) + StringOfChar(#0, 32)
    + Padded('.text', 8) + StringOfChar(#0, 32)
    { TC_$U_$$_B, defined in section 1, with an auxiliary record that names nothing }
    + Symbol(Bytes(0, 4) + Bytes(4 + Length(SectionA) + 1, 4), 1, 2, 1) + StringOfChar(#0, 18)
    { TC_$V_$$_C, another unit's, used here: undefined }
    + Symbol(Bytes(0, 4) + Bytes(4 + Length(SectionA) + 1 + Length(SymbolB) + 1, 4), 0, 2, 0)
    + Symbol(Padded('.text', 8), 2, 3, 0)
    + Bytes(4 + Length(Strings), 4) + Strings;
end;

procedure TestObjectNames;
var
  Root: string;
  Names: TStringList;
begin
  Root := MakeTestDirectory('objectnames');
  WriteTestFile(Root + 'u.o', TestCOFFObject);
  WriteTestFile(Root + 'v.o', 'no COFF object, but TC_$U_$$_A');
  WriteTestFile(Root + 'w.o', 'd'#0#0'.bss.n_u_$w_$$_x'#0);
  Names := TStringList.Create;
  try
    Expect(TDataSizes.ObjectNames(Root + 'u.o', Names), 'a COFF object');
    ExpectEqual(Names.CommaText, 'TC_$U_$$_A,TC_$U_$$_B',
      'the datum of a section, and one of a symbol defined there, not one used from another unit');
    Names.Clear;
    Expect(not TDataSizes.ObjectNames(Root + 'v.o', Names), 'a file that names one but cannot be read as COFF');
    Expect(TDataSizes.ObjectNames(Root + 'w.o', Names) and (Names.Count = 0), 'a file without initialised data');
    Expect(not TDataSizes.ObjectNames(Root + 'x.o', Names), 'no file');
  finally
    Names.Free;
  end;
end;

procedure TestHasInitialisedData;
var
  Root: string;
begin
  Root := MakeTestDirectory('initialised');
  WriteTestFile(Root + 'u.o', 'd'#0#0'.data.n_TC_$U_$$_CALLS'#0'.bss.n_u_$u_$$_x'#0);
  WriteTestFile(Root + 'v.o', 'd'#0#0'.bss.n_u_$v_$$_x'#0'U_$V_$$_X'#0);
  Expect(TDataSizes.HasInitialisedData(Root + 'u.o'), 'a section named after a typed constant');
  Expect(not TDataSizes.HasInitialisedData(Root + 'v.o'), 'variables without an initial value');
  Expect(not TDataSizes.HasInitialisedData(Root + 'w.o'), 'no file');
end;

// ---------------------------------------------------------------- tests: the agent connection
{ The lines of the protocol, how a reply is read, and a real connection on 127.0.0.1 inside
  this process, with the test as the program's side of it. }

const
  AttemptLimit = 50;
  AttemptPause = 5;

procedure TestEncodeCommand;
begin
  ExpectEqual(TAgentLink.EncodeCommand(['ping']), 'ping' + #10, 'a command without arguments');
  ExpectEqual(TAgentLink.EncodeCommand(['base', '/a/b.o']), 'base' + #9 + '/a/b.o' + #10, 'base');
  ExpectEqual(TAgentLink.EncodeCommand(['load', '/a/b.o', '/a/c.o']), 'load' + #9 + '/a/b.o' + #9 + '/a/c.o' + #10,
    'load with two files');
end;

procedure TestTakeLine;
var
  Buffer, Line: string;
begin
  Buffer := 'ok';
  Line := '';
  Expect(not TAgentLink.TakeLine(Buffer, Line), 'a line that is not complete');
  ExpectEqual(Buffer, 'ok', 'stays in the buffer');
  Buffer := 'stat a=1' + #10 + 'ok' + #10 + '.' + #10 + 'next';
  Expect(TAgentLink.TakeLine(Buffer, Line), 'the first line');
  ExpectEqual(Line, 'stat a=1', 'is taken without its end');
  Expect(TAgentLink.TakeLine(Buffer, Line), 'the second line');
  ExpectEqual(Line, 'ok', 'is next');
  Expect(TAgentLink.TakeLine(Buffer, Line), 'the closing dot');
  ExpectEqual(Line, '.', 'is a line');
  ExpectEqual(Buffer, 'next', 'what follows stays');
  Buffer := #10;
  Expect(TAgentLink.TakeLine(Buffer, Line), 'an empty line');
  ExpectEqual(Line, '', 'is empty');
end;

procedure TestReplyField;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('note something happened');
    Lines.Add('stat redirected=3 changed=1 added=2 kept=7 newdata=0 bytes=4096');
    Lines.Add('time total=0.42');
    Lines.Add('ok');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'redirected'), '3', 'the first field');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'bytes'), '4096', 'the last field');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'time', 'total'), '0.42', 'a field of another line');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'total'), '', 'a field of another line is not found here');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'redirect'), '', 'a key is whole');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'missing', 'bytes'), '', 'a line that is not there');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'stat'), '', 'the line''s own name is no field');
    Lines.Add('stat extra=a=b');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'extra'), 'a=b', 'a value keeps its own equals signs');
  finally
    Lines.Free;
  end;
end;

procedure TestReplyDetail;
var
  Detail: string;
begin
  Expect(TAgentLink.ReplyDetail('note unit moved', 'note ', Detail), 'a note');
  ExpectEqual(Detail, 'unit moved', 'its text');
  Expect(TAgentLink.ReplyDetail('restart TFoo: a new field', 'restart ', Detail), 'a restart');
  ExpectEqual(Detail, 'TFoo: a new field', 'its text');
  Expect(not TAgentLink.ReplyDetail('ok', 'note ', Detail), 'another line');
  ExpectEqual(Detail, '', 'has no text');
  Expect(not TAgentLink.ReplyDetail('note', 'note ', Detail), 'a prefix needs its blank');
  Expect(TAgentLink.ReplyDetail('error ', 'error ', Detail), 'an error without text');
  ExpectEqual(Detail, '', 'has none');
end;

procedure TestPathsAndToken;
var
  Token: string;
  I: Integer;
begin
  ExpectEqual(TAgentLink.TranslatePath('/tmp/p/.hot/live/a.o', False), '/tmp/p/.hot/live/a.o', 'a native path as it is');
  ExpectEqual(TAgentLink.TranslatePath('/tmp/p/.hot/live/a.o', True), 'Z:\tmp\p\.hot\live\a.o', 'a path under Wine');
  Token := TAgentLink.NewToken;
  ExpectEqual(Length(Token), 16, 'a token has sixteen digits');
  for I := 1 to Length(Token) do
    Expect(Token[I] in ['0'..'9', 'A'..'F'], 'and they are hexadecimal');
  ExpectEqual(TAgentLink.Greeting('0123456789ABCDEF'), 'hello 0123456789ABCDEF', 'the greeting of the agent');
end;

function ConnectClient(const APort: Word): TSocket;
var
  Address: TInetSockAddr;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := htons(APort);
  Address.sin_addr := StrToNetAddr('127.0.0.1');
  Expect(fpConnect(Result, @Address, SizeOf(Address)) = 0, 'the client connects');
end;

procedure SendText(const ASocket: TSocket; const AText: string);
begin
  Expect(fpSend(ASocket, @AText[1], Length(AText), 0) = Length(AText), 'the client sends');
end;

function ReceiveText(const ASocket: TSocket; const ALength: Integer): string;
var
  Received, Count: Integer;
begin
  Result := '';
  SetLength(Result, ALength);
  Received := 0;
  while Received < ALength do
  begin
    Count := fpRecv(ASocket, @Result[Received + 1], ALength - Received, 0);
    if Count <= 0 then
      Break;
    Inc(Received, Count);
  end;
  SetLength(Result, Received);
end;

function AcceptWithin(const ALink: TAgentLink): Boolean;
var
  Attempt: Integer;
begin
  Result := False;
  for Attempt := 1 to AttemptLimit do
  begin
    Result := ALink.TryAccept;
    if Result then
      Exit;
    Sleep(AttemptPause);
  end;
end;

procedure TestConnection;
var
  Link: TAgentLink;
  Client: TSocket;
  Paths, Reply: TStringList;
  Command: string;
  Character: Char;
begin
  Link := TAgentLink.Create(False);
  try
    Expect(Link.Listen, 'the link listens');
    Expect(Link.Port <> 0, 'on a port the system picked');
    ExpectEqual(Length(Link.Token), 16, 'with a token');
    Expect(not Link.TryAccept, 'nobody is connecting');
    { something that connects without the token is not the program }
    Client := ConnectClient(Link.Port);
    SendText(Client, 'hello not-the-token' + #10);
    Expect(not AcceptWithin(Link), 'a greeting with another token is refused');
    SetBlocking(Client, False);
    ExpectEqual(fpRecv(Client, @Character, 1, 0), 0, 'and the connection is closed');
    CloseSocketHandle(Client);
    Client := ConnectClient(Link.Port);
    SendText(Client, 'hello ' + Link.Token + #10);
    Expect(AcceptWithin(Link), 'the greeting with the token is accepted');
    SetBlocking(Client, True);
    { the program's side: the replies are sent ahead, in pieces the driver has to put together }
    SendText(Client, 'ok' + #10 + '.' + #10);
    Link.Base('/p/.hot/live/a.o');
    Command := 'base' + #9 + '/p/.hot/live/a.o' + #10;
    ExpectEqual(ReceiveText(Client, Length(Command)), Command, 'base reaches the program');
    SendText(Client, 'note a thing' + #10 + 'stat redirected=2 bytes=64' + #10 + 'ok' + #10 + '.' + #10);
    Paths := TStringList.Create;
    try
      Paths.Add('/p/.hot/v2/a.o');
      Paths.Add('/p/.hot/v2/b.o');
      Reply := Link.Load(Paths);
    finally
      Paths.Free;
    end;
    try
      Command := 'load' + #9 + '/p/.hot/v2/a.o' + #9 + '/p/.hot/v2/b.o' + #10;
      ExpectEqual(ReceiveText(Client, Length(Command)), Command, 'load reaches the program');
      ExpectEqual(Reply.Count, 3, 'the reply has its lines without the dot');
      ExpectEqual(Reply[2], 'ok', 'the verdict is the last');
      ExpectEqual(TAgentLink.ReplyField(Reply, 'stat', 'bytes'), '64', 'with its statistics');
    finally
      Reply.Free;
    end;
    Expect(not Link.AwaitClosed(0.05), 'a connection whose program runs stays open');
    CloseSocketHandle(Client);
    Expect(Link.AwaitClosed(2), 'and closes when the program has ended');
    { a restart: the program that ended is gone, and the new one connects to the same port }
    Link.Disconnect;
    Expect(Link.AwaitClosed(0), 'without a connection there is nothing to wait for');
    Client := ConnectClient(Link.Port);
    SendText(Client, 'hello ' + Link.Token + #10);
    Expect(AcceptWithin(Link), 'a restarted program connects again');
    SetBlocking(Client, True);
    SendText(Client, 'ok' + #10 + '.' + #10);
    Link.Base('/p/.hot/live/c.o');
    Command := 'base' + #9 + '/p/.hot/live/c.o' + #10;
    ExpectEqual(ReceiveText(Client, Length(Command)), Command, 'and gets the commands');
    CloseSocketHandle(Client);
  finally
    Link.Free;
  end;
end;

// ---------------------------------------------------------------- tests: compiling
{ Reading and comparing compiler versions, the version check, the diagnostics fpc prints,
  the leftovers it makes, the arguments of the compiles, and which units are made to
  recompile. fpc itself is not run; the version check runs small scripts that stand in for
  it, where the system can run scripts. }

procedure TestParseVersion;
var
  Version: TCompilerVersion;
begin
  Expect(TCompilerVersion.TryParse('3.2.2', Version), '3.2.2 parses');
  ExpectEqual(Version.ToString, '3.2.2', '3.2.2 prints as it was');
  Expect(TCompilerVersion.TryParse('3.3.1', Version), '3.3.1 parses');
  ExpectEqual(Version.Patch, 1, 'its patch');
  Expect(TCompilerVersion.TryParse('3.3.1+3' + LineEnding, Version), 'a toolchain build number after the version');
  ExpectEqual(Version.ToString, '3.3.1', 'is dropped');
  Expect(TCompilerVersion.TryParse('3.2.2-r1', Version), 'a revision after the version');
  ExpectEqual(Version.ToString, '3.2.2', 'is dropped');
  Expect(TCompilerVersion.TryParse('  3.0.4  ', Version), 'blanks around the version');
  ExpectEqual(Version.ToString, '3.0.4', 'are dropped');
  Expect(TCompilerVersion.TryParse('3.2', Version), 'a version without a patch');
  ExpectEqual(Version.ToString, '3.2.0', 'has patch 0');
  Expect(TCompilerVersion.TryParse('10.12.14', Version), 'several digits');
  ExpectEqual(Version.Major, 10, 'in the major version');
  Expect(not TCompilerVersion.TryParse('', Version), 'nothing');
  Expect(not TCompilerVersion.TryParse('3', Version), 'a major version alone');
  Expect(not TCompilerVersion.TryParse('fpc 3.2.2', Version), 'a version that does not start the text');
  Expect(not TCompilerVersion.TryParse('v3.2.2', Version), 'a version with a prefix');
  Expect(not TCompilerVersion.TryParse('3.x', Version), 'a minor version that is no number');
  Expect(not TCompilerVersion.TryParse('.2.2', Version), 'a missing major version');
end;

procedure TestCompareVersion;
var
  Older, Newer: TCompilerVersion;
begin
  TCompilerVersion.TryParse('3.2.1', Older);
  TCompilerVersion.TryParse('3.2.2', Newer);
  Expect(Older.CompareTo(Newer) < 0, '3.2.1 is before 3.2.2');
  Expect(Newer.CompareTo(Older) > 0, '3.2.2 is after 3.2.1');
  Expect(Newer.CompareTo(Newer) = 0, '3.2.2 is 3.2.2');
  TCompilerVersion.TryParse('3.10.0', Newer);
  TCompilerVersion.TryParse('3.9.9', Older);
  Expect(Older.CompareTo(Newer) < 0, 'minor versions compare as numbers');
  TCompilerVersion.TryParse('4.0.0', Newer);
  TCompilerVersion.TryParse('3.99.99', Older);
  Expect(Older.CompareTo(Newer) < 0, 'the major version decides first');
  ExpectEqual(MinimumVersion.ToString, '3.2.2', 'the minimum version');
end;

procedure TestJudgeVersion;
var
  Problem: string;
begin
  Expect(TCompiler.JudgeVersion('fpc', '3.2.2' + LineEnding, Problem), '3.2.2 is enough');
  ExpectEqual(Problem, '', 'and there is no problem');
  Expect(TCompiler.JudgeVersion('fpc', '3.3.1' + LineEnding, Problem), '3.3.1 is enough');
  Expect(TCompiler.JudgeVersion('fpc', '3.2.4', Problem), '3.2.4 is enough');
  Expect(TCompiler.JudgeVersion('fpc', '4.0.0', Problem), '4.0.0 is enough');
  Expect(TCompiler.JudgeVersion('fpc', 'warning: something' + LineEnding + '3.2.2' + LineEnding, Problem),
    'a version after another line is found');
  Expect(not TCompiler.JudgeVersion('build/old', '3.0.4' + LineEnding, Problem), '3.0.4 is too old');
  ExpectEqual(Problem, 'build/old is version 3.0.4; hotfpc requires 3.2.2 or later', 'and says so');
  Expect(not TCompiler.JudgeVersion('fpc', '3.2.0', Problem), '3.2.0 is too old');
  Expect(not TCompiler.JudgeVersion('fpc', '3.2.1', Problem), '3.2.1 is too old');
  Expect(not TCompiler.JudgeVersion('fpc', '2.6.4', Problem), '2.6.4 is too old');
  Expect(not TCompiler.JudgeVersion('wrapper', '', Problem), 'no output');
  ExpectEqual(Problem, 'cannot tell which version wrapper is (-iV printed nothing); hotfpc requires 3.2.2 or later',
    'is reported');
  Expect(not TCompiler.JudgeVersion('wrapper', LineEnding + 'sh: fpc: command not found' + LineEnding, Problem),
    'output that is no version');
  ExpectEqual(Problem,
    'cannot tell which version wrapper is (-iV printed "sh: fpc: command not found"); hotfpc requires 3.2.2 or later',
    'is quoted');
end;

procedure TestLeftovers;
var
  Root: string;
  Before, After: TStringList;
begin
  Expect(TCompiler.IsLeftover('link.res'), 'link.res');
  Expect(TCompiler.IsLeftover('link12345.res'), 'link<number>.res');
  Expect(TCompiler.IsLeftover('symbol_order.fpc'), 'symbol_order.fpc');
  Expect(TCompiler.IsLeftover('ppas.sh'), 'ppas.sh');
  Expect(TCompiler.IsLeftover('ppas.bat'), 'ppas.bat');
  Expect(not TCompiler.IsLeftover('link.txt'), 'link.txt is the user''s');
  Expect(not TCompiler.IsLeftover('linker.pas'), 'a source that starts with link');
  Expect(not TCompiler.IsLeftover('main.pas'), 'main.pas');
  Expect(not TCompiler.IsLeftover('ppas.cfg'), 'ppas.cfg');
  Root := MakeTestDirectory('leftovers');
  WriteTestFile(Root + 'link.res', 'older');
  WriteTestFile(Root + 'main.pas', 'program Main;');
  Before := TCompiler.FindLeftovers(Root);
  try
    ExpectEqual(Before.Count, 1, 'one leftover to begin with');
    WriteTestFile(Root + 'ppas.sh', 'new');
    WriteTestFile(Root + 'symbol_order.fpc', 'new');
    TCompiler.RemoveNewLeftovers(Root, Before);
    After := TCompiler.FindLeftovers(Root);
    try
      ExpectEqual(After.Count, 1, 'only the one that was there is left');
      ExpectEqual(After[0], 'link.res', 'the one from before');
    finally
      After.Free;
    end;
    Expect(FileExists(Root + 'main.pas'), 'the user''s files stay');
    Expect(not FileExists(Root + 'ppas.sh'), 'a new script goes');
  finally
    Before.Free;
  end;
end;

procedure TestDiagnostics;
var
  Errors: TStringList;
begin
  Expect(TCompiler.IsPlaced('demo.pas(12,5) Error: Identifier not found "Foo"'), 'line and column');
  Expect(TCompiler.IsPlaced('demo.pas(12) Fatal: Syntax error'), 'line only');
  Expect(not TCompiler.IsPlaced('Fatal: Compilation aborted'), 'no place');
  Expect(not TCompiler.IsPlaced('Error: /usr/bin/ppcx64 returned an error exitcode'), 'no place in a closing line');
  Expect(not TCompiler.IsPlaced('a demo.pas(12) Error: x'), 'a blank before the parenthesis');
  Expect(not TCompiler.IsPlaced('(12) Error: x'), 'no file name');
  Expect(not TCompiler.IsPlaced('demo.pas(x) Error: x'), 'no line number');
  Expect(not TCompiler.IsPlaced('demo.pas(12)'), 'nothing after the place');
  Errors := TCompiler.ExtractErrors(
    'Free Pascal Compiler version 3.2.2' + LineEnding
    + 'demo.pas(3,1) Warning: something' + LineEnding
    + 'demo.pas(12,5) Error: Identifier not found "Foo"' + LineEnding
    + 'demo.pas(14) Fatal: Syntax error, ";" expected' + LineEnding
    + 'Fatal: Compilation aborted' + LineEnding
    + 'Error: /usr/bin/ppcx64 returned an error exitcode' + LineEnding);
  try
    ExpectEqual(Errors.Count, 2, 'the diagnostics with a place');
    ExpectEqual(Errors[0], 'demo.pas(12,5) Error: Identifier not found "Foo"', 'the first');
    ExpectEqual(Errors[1], 'demo.pas(14) Fatal: Syntax error, ";" expected', 'the second');
  finally
    Errors.Free;
  end;
  Errors := TCompiler.ExtractErrors(
    'Fatal: Can''t find unit Missing used by Main' + LineEnding
    + 'Fatal: Compilation aborted' + LineEnding
    + 'Error: /usr/bin/ppcx64 returned an error exitcode' + LineEnding);
  try
    ExpectEqual(Errors.Count, 3, 'the closing lines when none has a place');
    ExpectEqual(Errors[0], 'Fatal: Can''t find unit Missing used by Main', 'in order');
  finally
    Errors.Free;
  end;
  Errors := TCompiler.ExtractErrors('Free Pascal Compiler version 3.2.2' + LineEnding + '10 lines compiled' + LineEnding);
  try
    ExpectEqual(Errors.Count, 0, 'no errors');
  finally
    Errors.Free;
  end;
  Errors := TCompiler.ExtractErrors('x.pas(1,1) Error: a' + LineEnding + 'lib.pas(2,3) Fatal: b' + LineEnding);
  try
    ExpectEqual(Errors.Count, 2, ' Error: and  Fatal: in the middle of a line');
  finally
    Errors.Free;
  end;
end;

procedure TestAffectsUnit;
begin
  Expect(TCompiler.AffectsUnit('/src/Foo.pas', 'foo.ppu'), 'a source and the record of its unit');
  Expect(TCompiler.AffectsUnit('/src/foo.pp', 'Foo.ppu'), 'whatever the case');
  Expect(not TCompiler.AffectsUnit('/src/foo.pas', 'bar.ppu'), 'another unit');
  Expect(not TCompiler.AffectsUnit('/src/foobar.pas', 'foo.ppu'), 'a longer name');
  Expect(TCompiler.AffectsUnit('/src/shared.inc', 'bar.ppu'), 'an include file can be part of any unit');
  Expect(TCompiler.AffectsUnit('/src/SHARED.INC', 'bar.ppu'), 'whatever its case');
end;

procedure TestAgentOptions;
var
  Options, Agent: TStringList;
begin
  Options := TStringList.Create;
  try
    Options.Add('-Twin64');
    Options.Add('-O2');
    Options.Add('-Px86_64');
    Options.Add('-Fu../lib');
    Options.Add('-Fi../inc');
    Options.Add('@lwpt.cfg');
    Options.Add('-Cparmv8');
    Options.Add('-gl');
    Options.Add('-Fl/usr/lib');
    Options.Add('-Vsuffix');
    Options.Add('-dFOO');
    Agent := TCompiler.AgentOptions(Options);
    try
      ExpectEqual(Agent.CommaText, '-Twin64,-Px86_64,-Fu../lib,@lwpt.cfg,-Cparmv8,-Fl/usr/lib,-Vsuffix',
        'target, code generation and unit options, in order');
    finally
      Agent.Free;
    end;
  finally
    Options.Free;
  end;
end;

function ParseOptions(const AArguments: array of string; const AHostIsWindows: Boolean): TOptions;
begin
  Result := TOptions.Create;
  Result.Parse(AArguments, AHostIsWindows);
end;

procedure TestCompileArguments;
var
  Options: TOptions;
  Workspace: TWorkspace;
  Compiler: TCompiler;
  Arguments: TStringList;
  Root: string;
begin
  Root := MakeTestDirectory('arguments');
  Options := ParseOptions(['-O2', '-Fulib', Root + 'demo.pas'], False);
  Workspace := TWorkspace.Create(Options.Source, Options.TargetWindows);
  Compiler := TCompiler.Create(Options, Workspace);
  try
    Arguments := Compiler.CompileArguments(True);
    try
      ExpectEqual(Arguments.Count, 8, 'a linking compile');
      ExpectEqual(Arguments[0], '-Xs-', 'keeps symbols');
      ExpectEqual(Arguments[1], '-FaHotFPC.Agent', 'loads the agent first');
      ExpectEqual(Arguments[2], '-Fu' + ExcludeTrailingPathDelimiter(Workspace.AgentDirectory), 'finds the agent');
      ExpectEqual(Arguments[3], '-FU' + ExcludeTrailingPathDelimiter(Workspace.UnitsDirectory), 'builds into .hot');
      ExpectEqual(Arguments[4], '-o' + Workspace.Executable, 'names the program');
      ExpectEqual(Arguments[5], '-O2', 'then the user''s options');
      ExpectEqual(Arguments[6], '-Fulib', 'in their order');
      ExpectEqual(Arguments[7], Options.Source, 'ends with the source');
    finally
      Arguments.Free;
    end;
    Arguments := Compiler.CompileArguments(True, Workspace.NextExecutable);
    try
      ExpectEqual(Arguments[4], '-o' + Workspace.NextExecutable, 'a restart names another program file');
      ExpectEqual(Arguments.Count, 8, 'and passes nothing else');
    finally
      Arguments.Free;
    end;
  finally
    Compiler.Free;
    Workspace.Free;
    Options.Free;
  end;
end;

procedure TestCompileArgumentsLinking;
var
  Options: TOptions;
  Workspace: TWorkspace;
  Compiler: TCompiler;
  Arguments: TStringList;
begin
  Options := ParseOptions(['demo.pas'], False);
  Workspace := TWorkspace.Create(Options.Source, Options.TargetWindows);
  Compiler := TCompiler.Create(Options, Workspace);
  try
    Arguments := Compiler.CompileArguments(False);
    try
      Expect(Arguments.IndexOf('-Cn') = Arguments.Count - 2, 'a compile for the object files does not link');
      Expect(Arguments.IndexOf('-Xm') < 0, 'and needs no map file');
    finally
      Arguments.Free;
    end;
    Arguments := Compiler.CompileArguments(True);
    try
      Expect(Arguments.IndexOf('-Cn') < 0, 'a linking compile does not skip the link');
      Expect(Arguments.IndexOf('-Xm') < 0, 'and a native one needs no map file');
    finally
      Arguments.Free;
    end;
  finally
    Compiler.Free;
    Workspace.Free;
    Options.Free;
  end;
  Options := ParseOptions(['-Twin64', 'demo.pas'], False);
  Workspace := TWorkspace.Create(Options.Source, Options.TargetWindows);
  Compiler := TCompiler.Create(Options, Workspace);
  try
    Arguments := Compiler.CompileArguments(True);
    try
      Expect(Arguments.IndexOf('-Xm') >= 0, 'a Windows program is linked with a map file');
      ExpectEqual(Arguments[4], '-o' + Workspace.Executable, 'under its .exe name');
      Expect(Pos('.exe', Arguments[4]) > 0, 'with the extension');
    finally
      Arguments.Free;
    end;
    Arguments := Compiler.CompileArguments(False);
    try
      Expect(Arguments.IndexOf('-Xm') < 0, 'but not when it is not linked');
    finally
      Arguments.Free;
    end;
  finally
    Compiler.Free;
    Workspace.Free;
    Options.Free;
  end;
end;

procedure TestAssemblerArguments;
var
  Options: TOptions;
  Workspace: TWorkspace;
  Compiler: TCompiler;
  Arguments: TStringList;
  Root: string;
begin
  Root := MakeTestDirectory('assembler-arguments');
  Options := ParseOptions(['-Twin64', '-O2', Root + 'demo.pas'], False);
  Workspace := TWorkspace.Create(Options.Source, Options.TargetWindows);
  Compiler := TCompiler.Create(Options, Workspace);
  try
    Arguments := Compiler.AssemblerArguments;
    try
      ExpectEqual(Arguments[0], '-Xs-', 'the same start as the program''s compile');
      ExpectEqual(Arguments[1], '-FaHotFPC.Agent', 'with the agent');
      ExpectEqual(Arguments[3], '-FU' + ExcludeTrailingPathDelimiter(Workspace.AssemblyDirectory),
        'but units of its own');
      ExpectEqual(Arguments[4], '-o' + Workspace.AssemblyDirectory + 'demo.exe',
        'and the program''s name there, so that fpc''s scripts go there');
      ExpectEqual(Arguments[5], '-Twin64', 'then the user''s options');
      ExpectEqual(Arguments[6], '-O2', 'in their order');
      ExpectEqual(Arguments[7], '-s', 'then only assembler');
      ExpectEqual(Arguments[8], '-Aas', 'for the GNU assembler');
      ExpectEqual(Arguments[9], Options.Source, 'and the source');
      ExpectEqual(Arguments.Count, 10, 'nothing else');
    finally
      Arguments.Free;
    end;
  finally
    Compiler.Free;
    Workspace.Free;
    Options.Free;
  end;
end;

{ A script that stands in for fpc compiling to assembler: it writes the link scripts fpc
  leaves next to the program into ADirectory, prints AOutput and ends with AExitCode. }
function WriteFakeAssembler(const AScriptDirectory, AName, ADirectory, AOutput: string;
  const AExitCode: Integer): string;
begin
  {$ifdef windows}
  Result := AScriptDirectory + AName + '.bat';
  WriteTestFile(Result, '@echo off' + LineEnding
    + 'echo script> "' + ADirectory + 'ppas.bat"' + LineEnding
    + 'echo script> "' + ADirectory + 'link1.res"' + LineEnding
    + 'echo ' + AOutput + LineEnding
    + 'exit /b ' + IntToStr(AExitCode) + LineEnding);
  {$else}
  Result := AScriptDirectory + AName;
  WriteTestFile(Result, '#!/bin/sh' + LineEnding
    + 'echo script > ''' + ADirectory + 'ppas.sh''' + LineEnding
    + 'echo script > ''' + ADirectory + 'link1.res''' + LineEnding
    + 'printf ''%s\n'' ''' + AOutput + '''' + LineEnding
    + 'exit ' + IntToStr(AExitCode) + LineEnding);
  FpChmod(Result, &755);
  {$endif}
end;

function AssemblerResult(const ACompiler, ASource: string; out AProblem: string;
  const AChanged: TStrings = nil): Boolean;
var
  Options: TOptions;
  Workspace: TWorkspace;
  Compiler: TCompiler;
  Seconds: Double;
begin
  Options := ParseOptions(['--fpc', ACompiler, '-Twin64', ASource], False);
  Workspace := TWorkspace.Create(Options.Source, Options.TargetWindows);
  Compiler := TCompiler.Create(Options, Workspace);
  try
    Result := Compiler.WriteAssembler(AChanged, AProblem, Seconds);
  finally
    Compiler.Free;
    Workspace.Free;
    Options.Free;
  end;
end;

procedure TestWriteAssembler;
var
  Root, Assembly, Problem: string;
begin
  Root := MakeTestDirectory('assembler');
  Assembly := Root + '.hot' + PathDelim + 'asm' + PathDelim;
  Expect(AssemblerResult(WriteFakeAssembler(Root, 'works', Assembly, 'Compiling demo.pas', 0), Root + 'demo.pas', Problem),
    'a compile that works');
  ExpectEqual(Problem, '', 'has no problem');
  Expect(DirectoryExists(Assembly), 'it has a directory of its own');
  Expect(not FileExists(Assembly + 'ppas.sh') and not FileExists(Assembly + 'ppas.bat'), 'without the link script fpc wrote');
  Expect(not FileExists(Assembly + 'link1.res'), 'or its linker''s script');
  Expect(not AssemblerResult(WriteFakeAssembler(Root, 'fails', Assembly, 'demo.pas(3,1) Error: Illegal expression', 1),
    Root + 'demo.pas', Problem), 'a compile that fails');
  ExpectEqual(Problem, 'demo.pas(3,1) Error: Illegal expression', 'says why');
end;

{ A compile to assembler that writes no file leaves no assembler of an earlier compile for
  the program or a changed unit, only for a unit fpc had no reason to compile again. }
procedure TestWriteAssemblerAnew;
var
  Root, Assembly, Problem: string;
  Changed: TStringList;
begin
  Root := MakeTestDirectory('assembler-anew');
  Assembly := Root + '.hot' + PathDelim + 'asm' + PathDelim;
  WriteTestFile(Assembly + 'demo.s', 'the program''s earlier assembler');
  WriteTestFile(Assembly + 'gone.s', 'a unit''s whose unit file fpc removed');
  WriteTestFile(Assembly + 'changed.s', 'a changed unit''s');
  WriteTestFile(Assembly + 'changed.ppu', 'record');
  WriteTestFile(Assembly + 'kept.s', 'an unchanged unit''s');
  WriteTestFile(Assembly + 'kept.ppu', 'record');
  Changed := TStringList.Create;
  try
    Changed.Add('changed.o');
    Expect(AssemblerResult(WriteFakeAssembler(Root, 'silent', Assembly, 'Compiling demo.pas', 0), Root + 'demo.pas',
      Problem, Changed), 'a compile to assembler that writes nothing');
  finally
    Changed.Free;
  end;
  Expect(not FileExists(Assembly + 'demo.s'), 'leaves no assembler of the program from before');
  Expect(not FileExists(Assembly + 'gone.s'), 'or of a unit that has no unit file there');
  Expect(not FileExists(Assembly + 'changed.s') and not FileExists(Assembly + 'changed.ppu'),
    'or of a changed unit, which compiles again');
  Expect(FileExists(Assembly + 'kept.s') and FileExists(Assembly + 'kept.ppu'), 'but keeps an unchanged unit''s');
end;

procedure TestForgetAssemblyUnits;
var
  Options: TOptions;
  Workspace: TWorkspace;
  Compiler: TCompiler;
  Changed: TStringList;
  Root: string;
begin
  if GetEnvironmentVariable(TrustTimestampsVariable) <> '' then
    Exit;
  Root := MakeTestDirectory('forget-assembly');
  Options := ParseOptions(['-Twin64', Root + 'demo.pas'], False);
  Workspace := TWorkspace.Create(Options.Source, Options.TargetWindows);
  Compiler := TCompiler.Create(Options, Workspace);
  Changed := TStringList.Create;
  try
    WriteTestFile(Workspace.UnitsDirectory + 'foo.ppu', 'record');
    WriteTestFile(Workspace.AssemblyDirectory + 'foo.ppu', 'record');
    WriteTestFile(Workspace.AssemblyDirectory + 'bar.ppu', 'record');
    Changed.Add(Root + 'foo.pas');
    Compiler.ForgetUnits(Changed);
    Expect(not FileExists(Workspace.UnitsDirectory + 'foo.ppu'), 'a Windows program''s changed unit is recompiled');
    Expect(not FileExists(Workspace.AssemblyDirectory + 'foo.ppu'), 'to assembler too');
    Expect(FileExists(Workspace.AssemblyDirectory + 'bar.ppu'), 'and another unit is not');
  finally
    Changed.Free;
    Compiler.Free;
    Workspace.Free;
    Options.Free;
  end;
end;

{ The resource is the whole of HotFPC.Agent.pas: its first line and its last. }
procedure TestAgentResource;
var
  Resource: TResourceStream;
  Source: TStringList;
begin
  Resource := TResourceStream.Create(HInstance, AgentResourceName, RawDataResourceType);
  Source := TStringList.Create;
  try
    Source.LoadFromStream(Resource);
    Expect(Source.Count > 0, 'the agent resource has lines');
    if Source.Count > 0 then
    begin
      ExpectEqual(Source[0], 'unit HotFPC.Agent;', 'the agent resource starts with the unit');
      ExpectEqual(Source[Source.Count - 1], 'end.', 'and ends with its end');
    end;
  finally
    Source.Free;
    Resource.Free;
  end;
end;

procedure TestForgetUnits;
var
  Options: TOptions;
  Workspace: TWorkspace;
  Compiler: TCompiler;
  Changed: TStringList;
  Root: string;
begin
  if GetEnvironmentVariable(TrustTimestampsVariable) <> '' then
    Exit;
  Root := MakeTestDirectory('forget');
  Options := ParseOptions([Root + 'demo.pas'], False);
  Workspace := TWorkspace.Create(Options.Source, Options.TargetWindows);
  Compiler := TCompiler.Create(Options, Workspace);
  Changed := TStringList.Create;
  try
    WriteTestFile(Workspace.UnitsDirectory + 'foo.ppu', 'record');
    WriteTestFile(Workspace.UnitsDirectory + 'foo.o', 'object');
    WriteTestFile(Workspace.UnitsDirectory + 'bar.ppu', 'record');
    Changed.Add(Root + 'Foo.pas');
    Compiler.ForgetUnits(Changed);
    Expect(not FileExists(Workspace.UnitsDirectory + 'foo.ppu'), 'the record of the changed unit goes');
    Expect(FileExists(Workspace.UnitsDirectory + 'foo.o'), 'its object file stays');
    Expect(FileExists(Workspace.UnitsDirectory + 'bar.ppu'), 'the record of another unit stays');
    Changed.Clear;
    Changed.Add(Root + 'shared.inc');
    Compiler.ForgetUnits(Changed);
    Expect(not FileExists(Workspace.UnitsDirectory + 'bar.ppu'), 'a changed include file makes every unit recompile');
  finally
    Changed.Free;
    Compiler.Free;
    Workspace.Free;
    Options.Free;
  end;
end;

{ A script that stands in for fpc and prints the given text, whatever its arguments: a
  shell script, or a batch file on Windows. }
function WriteFakeCompiler(const ADirectory, AName, AOutput: string): string;
begin
  {$ifdef windows}
  Result := ADirectory + AName + '.bat';
  WriteTestFile(Result, '@echo ' + AOutput + LineEnding);
  {$else}
  Result := ADirectory + AName;
  WriteTestFile(Result, '#!/bin/sh' + LineEnding + 'printf ''%s'' ''' + AOutput + '''' + LineEnding);
  FpChmod(Result, &755);
  {$endif}
end;

function VersionProblem(const ACompiler: string; out AProblem: string): Boolean;
var
  Options: TOptions;
  Workspace: TWorkspace;
  Compiler: TCompiler;
begin
  Options := ParseOptions(['--fpc', ACompiler, 'demo.pas'], False);
  Workspace := TWorkspace.Create(Options.Source, Options.TargetWindows);
  Compiler := TCompiler.Create(Options, Workspace);
  try
    Result := Compiler.VerifyVersion(AProblem);
  finally
    Compiler.Free;
    Workspace.Free;
    Options.Free;
  end;
end;

procedure TestVerifyVersion;
var
  Root, Old, Problem: string;
begin
  Root := MakeTestDirectory('verify');
  Expect(VersionProblem(WriteFakeCompiler(Root, 'fpc322', '3.2.2'), Problem), 'a compiler of 3.2.2 passes');
  Expect(VersionProblem(WriteFakeCompiler(Root, 'fpc331', '3.3.1'), Problem), 'a compiler of 3.3.1 passes');
  Old := WriteFakeCompiler(Root, 'fpc304', '3.0.4');
  Expect(not VersionProblem(Old, Problem), 'a compiler of 3.0.4 does not');
  ExpectEqual(Problem, Old + ' is version 3.0.4; hotfpc requires 3.2.2 or later', 'and the problem names it');
  Expect(not VersionProblem(WriteFakeCompiler(Root, 'fpcjunk', 'hello'), Problem), 'a compiler that prints no version does not');
  Expect(Pos('hotfpc requires 3.2.2 or later', Problem) > 0, 'and the problem gives the requirement');
  Expect(not VersionProblem(Root + 'missing' + PathDelim + 'fpc', Problem), 'a compiler that does not exist does not');
  Expect(Pos('cannot run ' + Root + 'missing', Problem) = 1, 'and the problem says it cannot be run');
end;

// ---------------------------------------------------------------- tests: the driver
{ What the driver says about a program that ends before its agent connects. The program is a
  shell command that stands in for one. }

{ Starts the shell command as the program and waits for its agent as the driver does; the
  exit code the driver takes from it. }
function ExitCodeBeforeConnecting(const AName, ACommand: string): Integer;
var
  Options: TOptions;
  Driver: TDriver;
  Process: TProcess;
begin
  Options := ParseOptions([MakeTestDirectory(AName) + 'demo.pas'], False);
  Driver := TDriver.Create(Options);
  Process := TProcess.Create(nil);
  try
    Expect(Driver.FLink.Listen, 'the driver listens');
    {$ifdef windows}
    Process.Executable := 'cmd.exe';
    Process.Parameters.Add('/c');
    {$else}
    Process.Executable := '/bin/sh';
    Process.Parameters.Add('-c');
    {$endif}
    Process.Parameters.Add(ACommand);
    Process.Execute;
    Expect(not Driver.AwaitAgent(Process, Result), 'a program that ends has no agent to connect');
  finally
    Process.Free;
    Driver.Free;
    Options.Free;
  end;
end;

procedure TestEndedBeforeConnecting;
begin
  ExpectEqual(ExitCodeBeforeConnecting('ended', 'exit 3'), 3, 'a program that ends before its agent connects gives its exit code');
  {$ifdef unix}
  ExpectEqual(ExitCodeBeforeConnecting('killed', 'kill -KILL $$'), -1,
    'one that a signal ended gives -1, as when it ends later');
  {$endif}
end;

// ---------------------------------------------------------------- tests: all tests

{ Runs every test and returns the exit code: 1 when a check failed. }
function RunTests: Integer;
begin
  Directories := TStringList.Create;
  try
    TestFormats;
    TestClock;
    TestReadAndCopy;
    TestRemoveTree;
    TestFindFileIgnoringCase;
    TestDefaults;
    TestValues;
    TestSettleFallback;
    TestSettleWaitEnd;
    TestSettlePause;
    TestCompilerOptionsAndProgramArguments;
    TestMissingValue;
    TestLastSourceWins;
    TestVersionAndUsage;
    TestWindowsTarget;
    TestPaths;
    TestUnitObjects;
    TestLog;
    TestWithoutLog;
    TestSourceExtensions;
    TestContentDigest;
    TestSameStamps;
    TestChangedFiles;
    TestChangedStamps;
    TestAwaitEmptied;
    TestAwaitEmptiedPaths;
    TestAwaitEmptiedThroughTheWatcher;
    TestChangedSince;
    TestWatchedPaths;
    TestStampsShowARevertedSave;
    TestTimesShowWrites;
    TestOptionDirectories;
    TestResponseFile;
    TestWatchedFiles;
    TestLayoutContent;
    TestDifferences;
    TestPositionsDoNotMatter;
    TestUnitsOfTheProgram;
    TestImplementationContent;
    TestImplementationDifferences;
    TestImplementationUnitsOfTheProgram;
    TestProbe;
    TestLocate;
    TestHistory;
    TestReadDataSizes;
    TestStringBytes;
    TestDataSizeChanges;
    TestKeepDataSizes;
    TestPrettyDataNames;
    TestHasInitialisedData;
    TestObjectNames;
    TestEncodeCommand;
    TestTakeLine;
    TestReplyField;
    TestReplyDetail;
    TestPathsAndToken;
    TestConnection;
    TestParseVersion;
    TestCompareVersion;
    TestJudgeVersion;
    TestLeftovers;
    TestDiagnostics;
    TestAffectsUnit;
    TestAgentOptions;
    TestCompileArguments;
    TestCompileArgumentsLinking;
    TestAgentResource;
    TestForgetUnits;
    TestForgetAssemblyUnits;
    TestAssemblerArguments;
    TestWriteAssembler;
    TestWriteAssemblerAnew;
    TestVerifyVersion;
    TestEndedBeforeConnecting;
    Result := FinishTests;
  finally
    Directories.Free;
  end;
end;
{$endif}

begin
  {$ifdef HOTFPC_TESTS}
  Halt(RunTests);
  {$else}
  Halt(RunHotFPC);
  {$endif}
end.
