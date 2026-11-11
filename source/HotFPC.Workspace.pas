unit HotFPC.Workspace;
{ HotFPC.Workspace: the .hot/ directory next to the program's source, where hotfpc builds
  and keeps what it needs: every path in it, and the object files it holds. }
{$mode delphi}{$H+}
{ fpc 3.3.1 before fpc-toolchain release 3.3.1+4 miscompiles loops at -O1 and above
  (docs/how-it-works.md, "A compiler bug"); fpc -iV cannot tell those builds from fixed ones. }
{$IF FPC_FULLVERSION >= 30301}{$optimization off}{$ENDIF}

interface

uses
  Classes;

type
  TWorkspace = class
  private
    FSource: string;
    FName: string;
    FSourceDirectory: string;
    FHotDirectory: string;
    FUnitsDirectory: string;
    FLiveDirectory: string;
    FAgentDirectory: string;
    FAgentSourceDirectory: string;
    FExecutable: string;
  public
    constructor Create(const ASource: string; const ATargetWindows: Boolean);
    { The directory a swap's object files are staged in before the agent loads them. }
    function StageDirectory(const AVersion: Integer): string;
    { The names of the object files the last compile left in UnitsDirectory, sorted. The caller
      frees the list. }
    function UnitObjects: TStringList;
    { The full path of the program's source file. }
    property Source: string read FSource;
    { The program's name: the source file without its extension. }
    property Name: string read FName;
    { The source file's directory, with a trailing path delimiter. }
    property SourceDirectory: string read FSourceDirectory;
    { The following directories all end in a path delimiter. }
    property HotDirectory: string read FHotDirectory;
    { Where fpc puts the program's units and object files. }
    property UnitsDirectory: string read FUnitsDirectory;
    { The units as the running program has them. }
    property LiveDirectory: string read FLiveDirectory;
    { The compiled agent unit. }
    property AgentDirectory: string read FAgentDirectory;
    { The agent's source, written out for the compile; kept away from the program's search
      path. }
    property AgentSourceDirectory: string read FAgentSourceDirectory;
    { The built program (no trailing delimiter). }
    property Executable: string read FExecutable;
  end;

implementation

uses
  SysUtils;

const
  HotDirectoryName = '.hot';
  UnitsDirectoryName = 'units';
  LiveDirectoryName = 'live';
  AgentDirectoryName = 'agent';
  AgentSourceDirectoryName = 'agent-src';
  StageDirectoryPrefix = 'v';
  ObjectPattern = '*.o';
  WindowsExecutableExtension = '.exe';

constructor TWorkspace.Create(const ASource: string; const ATargetWindows: Boolean);
begin
  inherited Create;
  FSource := ASource;
  FSourceDirectory := ExtractFilePath(ASource);
  FName := ChangeFileExt(ExtractFileName(ASource), '');
  FHotDirectory := FSourceDirectory + HotDirectoryName + PathDelim;
  FUnitsDirectory := FHotDirectory + UnitsDirectoryName + PathDelim;
  FLiveDirectory := FHotDirectory + LiveDirectoryName + PathDelim;
  FAgentDirectory := FHotDirectory + AgentDirectoryName + PathDelim;
  FAgentSourceDirectory := FHotDirectory + AgentSourceDirectoryName + PathDelim;
  FExecutable := FHotDirectory + FName;
  if ATargetWindows then
    FExecutable := FExecutable + WindowsExecutableExtension;
end;

function TWorkspace.StageDirectory(const AVersion: Integer): string;
begin
  Result := FHotDirectory + StageDirectoryPrefix + IntToStr(AVersion) + PathDelim;
end;

function TWorkspace.UnitObjects: TStringList;
var
  Search: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if FindFirst(FUnitsDirectory + ObjectPattern, faAnyFile, Search) = 0 then
  begin
    repeat
      Result.Add(Search.Name);
    until FindNext(Search) <> 0;
    FindClose(Search);
  end;
end;

end.
