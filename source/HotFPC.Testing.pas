unit HotFPC.Testing;
{ HotFPC.Testing: the checks of hotfpc's test programs. No framework: a failed check is
  printed and counted, and FinishTests ends the program with a non-zero exit code when any
  failed. }
{$mode delphi}{$H+}

interface

procedure Expect(const ACondition: Boolean; const ADescription: string);
procedure ExpectEqual(const AActual, AExpected: string; const ADescription: string); overload;
procedure ExpectEqual(const AActual, AExpected: Int64; const ADescription: string); overload;
{ A fresh empty directory for a test, next to the test program and removed again by
  FinishTests. }
function MakeTestDirectory(const AName: string): string;
procedure WriteTestFile(const APath, AContents: string);
{ Prints the totals and halts with exit code 1 when a check failed. }
procedure FinishTests;

implementation

uses
  Classes,
  SysUtils,

  HotFPC.Files;

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

procedure ExpectEqual(const AActual, AExpected: string; const ADescription: string);
begin
  Inc(CheckCount);
  if AActual <> AExpected then
  begin
    Inc(FailureCount);
    WriteLn('FAIL: ', ADescription, ': expected "', AExpected, '", got "', AActual, '"');
  end;
end;

procedure ExpectEqual(const AActual, AExpected: Int64; const ADescription: string);
begin
  Inc(CheckCount);
  if AActual <> AExpected then
  begin
    Inc(FailureCount);
    WriteLn('FAIL: ', ADescription, ': expected ', AExpected, ', got ', AActual);
  end;
end;

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

procedure FinishTests;
var
  I: Integer;
begin
  for I := 0 to Directories.Count - 1 do
    RemoveTree(ExcludeTrailingPathDelimiter(Directories[I]));
  WriteLn(ExtractFileName(ParamStr(0)), ': ', CheckCount, ' checks, ', FailureCount, ' failed');
  if FailureCount > 0 then
    Halt(1);
end;

initialization
  Directories := TStringList.Create;

finalization
  Directories.Free;

end.
