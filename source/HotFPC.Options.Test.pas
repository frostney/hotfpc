program OptionsTest;
{ Tests of HotFPC.Options: the command line, option by option, and what is derived from it for
  a Windows target on either kind of host. }
{$mode delphi}{$H+}

uses
  SysUtils,

  HotFPC.Options,
  HotFPC.Testing;

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

begin
  TestDefaults;
  TestValues;
  TestSettleFallback;
  TestCompilerOptionsAndProgramArguments;
  TestMissingValue;
  TestLastSourceWins;
  TestVersionAndUsage;
  TestWindowsTarget;
  FinishTests;
end.
