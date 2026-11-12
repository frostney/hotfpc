{ HotFPC.Test.inc: hotfpc's unit tests. HotFPC.pas includes this file when it is compiled
  with -dHOTFPC_TESTS, and then runs RunTests instead of hotfpc; `instantfpc build.pas tests`
  does both. No framework: a failed check is printed and counted, and the program ends with
  exit code 1 when any failed. }

// ---------------------------------------------------------------- checks

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

// ---------------------------------------------------------------- timing
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

// ---------------------------------------------------------------- files
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

// ---------------------------------------------------------------- command line
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
    '--quiet', '--settle', '50', '--log', 'hot.log', 'demo.pas'], False, Action);
  try
    Expect(Action = caRun, 'every option with a value runs');
    ExpectEqual(Options.Compiler, '/opt/fpc/bin/fpc', '--fpc');
    ExpectEqual(Options.PPUDump, '/opt/fpc/bin/ppudump', '--ppudump');
    ExpectEqual(Options.Launcher, 'wrapper', '--run');
    ExpectEqual(Options.LogPath, 'hot.log', '--log');
    Expect(Options.Quiet, '--quiet');
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
  ExpectEqual(HotFPCVersion, '1.0.0', 'the version');
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

// ---------------------------------------------------------------- the .hot directory
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

// ---------------------------------------------------------------- [hot] lines
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

// ---------------------------------------------------------------- watching
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
  finally
    Previous.Free;
    Current.Free;
  end;
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
    Expect(not Watcher.ReadDigests(Digests), 'an empty file is a save in progress');
    Expect(Digests = nil, 'and gives no digests');
  finally
    Watcher.Free;
    Options.Free;
  end;
end;

// ---------------------------------------------------------------- interface layouts (ppudump)
{ The check of interface layouts on ppudump's JSON as text: what a layout holds, what makes
  two layouts differ and what does not, how the units of the program are referred to, the
  probe of a ppudump, and the history of layouts across swaps. ppudump itself is not run: a
  reader that answers from a table takes its place. }

type
  { A reader whose ppudump output is the text registered for the file's path. }
  TTableReader = class(TLayoutReader)
  private
    FPaths: TStringList;
    FOutputs: TStringList;
  protected
    function Dump(const APPUPath: string): string; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Register(const APath, AOutput: string);
  end;

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
  ExpectEqual(TLayoutReader.Locate(Root + 'fpc', ''), '', 'no ppudump next to the compiler');
  WriteTestFile(Root + 'ppudump', '');
  ExpectEqual(TLayoutReader.Locate(Root + 'fpc', ''), Root + 'ppudump', 'a ppudump next to it');
  ExpectEqual(TLayoutReader.Locate(Root + 'fpc', '.exe'), '', 'on Windows it is ppudump.exe');
  WriteTestFile(Root + 'ppudump.exe', '');
  ExpectEqual(TLayoutReader.Locate(Root + 'fpc.exe', '.exe'), Root + 'ppudump.exe', 'and found by that name');
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
  finally
    History.Free;
    Reader.Free;
  end;
end;

// ---------------------------------------------------------------- the agent connection
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
    CloseSocketHandle(Client);
  finally
    Link.Free;
  end;
end;

// ---------------------------------------------------------------- compiling
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

{$ifdef unix}
{ A script that stands in for fpc and prints the given text, whatever its arguments. }
function WriteFakeCompiler(const ADirectory, AName, AOutput: string): string;
begin
  Result := ADirectory + AName;
  WriteTestFile(Result, '#!/bin/sh' + LineEnding + 'printf ''%s'' ''' + AOutput + '''' + LineEnding);
  FpChmod(Result, &755);
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
  Root, Problem: string;
begin
  Root := MakeTestDirectory('verify');
  Expect(VersionProblem(WriteFakeCompiler(Root, 'fpc322', '3.2.2'), Problem), 'a compiler of 3.2.2 passes');
  Expect(VersionProblem(WriteFakeCompiler(Root, 'fpc331', '3.3.1'), Problem), 'a compiler of 3.3.1 passes');
  Expect(not VersionProblem(WriteFakeCompiler(Root, 'fpc304', '3.0.4'), Problem), 'a compiler of 3.0.4 does not');
  ExpectEqual(Problem, Root + 'fpc304 is version 3.0.4; hotfpc requires 3.2.2 or later', 'and the problem names it');
  Expect(not VersionProblem(WriteFakeCompiler(Root, 'fpcjunk', 'hello'), Problem), 'a compiler that prints no version does not');
  Expect(Pos('hotfpc requires 3.2.2 or later', Problem) > 0, 'and the problem gives the requirement');
  Expect(not VersionProblem(Root + 'missing' + PathDelim + 'fpc', Problem), 'a compiler that does not exist does not');
  Expect(Pos('cannot run ' + Root + 'missing', Problem) = 1, 'and the problem says it cannot be run');
end;
{$endif}

// ---------------------------------------------------------------- all tests

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
    TestOptionDirectories;
    TestResponseFile;
    TestWatchedFiles;
    TestLayoutContent;
    TestDifferences;
    TestPositionsDoNotMatter;
    TestUnitsOfTheProgram;
    TestProbe;
    TestLocate;
    TestHistory;
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
    TestForgetUnits;
    {$ifdef unix}
    TestVerifyVersion;
    {$endif}
    Result := FinishTests;
  finally
    Directories.Free;
  end;
end;
