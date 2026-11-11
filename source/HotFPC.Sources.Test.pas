program SourcesTest;
{ Tests of HotFPC.Sources: the directories options and response files name, which files are
  watched, the content digest, and which files changed. }
{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  HotFPC.Sources,
  HotFPC.Testing;

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

begin
  TestSourceExtensions;
  TestContentDigest;
  TestSameStamps;
  TestChangedFiles;
  TestOptionDirectories;
  TestResponseFile;
  TestWatchedFiles;
  FinishTests;
end.
