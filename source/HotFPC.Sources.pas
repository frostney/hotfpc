unit HotFPC.Sources;
{ HotFPC.Sources: which source files hotfpc watches (the program's directory and the -Fu and
  -Fi directories fpc will search, also those of response files), how it notices a change (sizes
  and times, then content digests) and which files changed. }
{$mode delphi}{$H+}
{ fpc 3.3.1 before fpc-toolchain release 3.3.1+4 miscompiles loops at -O1 and above
  (docs/how-it-works.md, "A compiler bug"); fpc -iV cannot tell those builds from fixed ones. }
{$IF FPC_FULLVERSION >= 30301}{$optimization off}{$ENDIF}

interface

uses
  Classes;

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

implementation

uses
  SysUtils,

  HotFPC.Files;

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

end.
