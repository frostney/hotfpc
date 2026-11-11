program FilesTest;
{ Tests of HotFPC.Files: reading, copying and comparing files, and removing a tree. }
{$mode delphi}{$H+}

uses
  SysUtils,

  HotFPC.Files,
  HotFPC.Testing;

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

begin
  TestReadAndCopy;
  TestRemoveTree;
  TestFindFileIgnoringCase;
  FinishTests;
end.
