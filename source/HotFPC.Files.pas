unit HotFPC.Files;
{ HotFPC.Files: the whole-file and directory operations the driver needs, none of which
  keeps state. }
{$mode delphi}{$H+}

interface

{ False when the file cannot be read; AContents is then empty or partial. }
function ReadFileContents(const APath: string; out AContents: string): Boolean;
procedure CopyFileContents(const ASource, ADestination: string);
function SameFileContents(const AFirst, ASecond: string): Boolean;
{ Removes the directory and everything in it; nothing happens when it does not exist. }
procedure RemoveTree(const ADirectory: string);

implementation

uses
  Classes,
  SysUtils;

function ReadFileContents(const APath: string; out AContents: string): Boolean;
var
  Stream: TFileStream;
begin
  AContents := '';
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(AContents, Stream.Size);
      if Stream.Size > 0 then
        Stream.ReadBuffer(AContents[1], Stream.Size);
      Result := True;
    finally
      Stream.Free;
    end;
  except
    Result := False;
  end;
end;

procedure CopyFileContents(const ASource, ADestination: string);
var
  Source, Destination: TFileStream;
begin
  Source := TFileStream.Create(ASource, fmOpenRead or fmShareDenyNone);
  try
    Destination := TFileStream.Create(ADestination, fmCreate);
    try
      Destination.CopyFrom(Source, 0);
    finally
      Destination.Free;
    end;
  finally
    Source.Free;
  end;
end;

function SameFileContents(const AFirst, ASecond: string): Boolean;
var
  FirstContents, SecondContents: string;
begin
  Result := ReadFileContents(AFirst, FirstContents) and ReadFileContents(ASecond, SecondContents)
    and (FirstContents = SecondContents);
end;

procedure RemoveTree(const ADirectory: string);
var
  Search: TSearchRec;
  Prefix: string;
begin
  if not DirectoryExists(ADirectory) then
    Exit;
  Prefix := IncludeTrailingPathDelimiter(ADirectory);
  if FindFirst(Prefix + '*', faAnyFile, Search) = 0 then
  begin
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      if (Search.Attr and faDirectory) <> 0 then
        RemoveTree(Prefix + Search.Name)
      else
        DeleteFile(Prefix + Search.Name);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
  RemoveDir(ADirectory);
end;

end.
