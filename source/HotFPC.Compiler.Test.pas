program CompilerTest;
{ Tests of HotFPC.Compiler: reading and comparing compiler versions, the version check, the
  diagnostics fpc prints, the leftovers it makes, the arguments of the compiles, and which
  units are made to recompile. fpc itself is not run; the version check runs small scripts
  that stand in for it, where the system can run scripts. }
{$mode delphi}{$H+}

uses
  {$ifdef unix}
  BaseUnix,
  {$endif}
  Classes,
  SysUtils,

  HotFPC.Compiler,
  HotFPC.Options,
  HotFPC.Testing,
  HotFPC.Workspace;

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

begin
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
  FinishTests;
end.
