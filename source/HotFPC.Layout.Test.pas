program LayoutTest;
{ Tests of HotFPC.Layout on ppudump's JSON as text: what a layout holds, what makes two layouts
  differ and what does not, how the units of the program are referred to, the probe of a
  ppudump, and the history of layouts across swaps. ppudump itself is not run: a reader that
  answers from a table takes its place. }
{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  HotFPC.Layout,
  HotFPC.Testing;

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

begin
  TestLayoutContent;
  TestDifferences;
  TestPositionsDoNotMatter;
  TestUnitsOfTheProgram;
  TestProbe;
  TestLocate;
  TestHistory;
  FinishTests;
end.
