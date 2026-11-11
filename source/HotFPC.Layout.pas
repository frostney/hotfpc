unit HotFPC.Layout;
{ HotFPC.Layout: the check of interface layouts. A field that moved or changed its type
  without changing a size is invisible in the object file, so hotfpc reads the interface of
  each changed unit with ppudump (JSON output) and compares it with the one of the unit
  that is running.

  A layout is the interface of one unit as the compiler wrote it down: name=text for the
  layout of each record or class type and the type of each variable. Two texts differ exactly
  when a field was added, removed, moved or retyped, or a variable changed its type. }
{$mode delphi}{$H+}
{ fpc 3.3.1 before fpc-toolchain release 3.3.1+4 miscompiles loops at -O1 and above
  (docs/how-it-works.md, "A compiler bug"); fpc -iV cannot tell those builds from fixed ones. }
{$IF FPC_FULLVERSION >= 30301}{$optimization off}{$ENDIF}

interface

uses
  Classes;

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

implementation

uses
  Contnrs,
  fpjson,
  jsonparser,
  Process,
  SysUtils;

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
  UnitName, Identifier: string;
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
    if FileExists(FOwnDirectory + LowerCase(UnitName) + PPUExtension) then
    begin
      Index := FOthers.IndexOf(UnitName);
      if Index < 0 then
      begin
        OtherDefinitions := TStringList.Create;
        OtherDefinitions.Sorted := True;
        OtherDefinitions.Duplicates := dupIgnore;
        Load(FOwnDirectory + LowerCase(UnitName) + PPUExtension, OtherDefinitions);
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

end.
