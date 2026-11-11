program ReporterTest;
{ Tests of HotFPC.Reporter: the copy of every line, with its time, in the log file. }
{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  HotFPC.Reporter,
  HotFPC.Testing;

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

begin
  TestLog;
  TestWithoutLog;
  FinishTests;
end.
