program WorkspaceTest;
{ Tests of HotFPC.Workspace: the paths of the .hot/ directory and its object files. }
{$mode delphi}{$H+}

uses
  Classes,
  SysUtils,

  HotFPC.Testing,
  HotFPC.Workspace;

procedure TestPaths;
var
  Workspace: TWorkspace;
  Hot: string;
begin
  Workspace := TWorkspace.Create(PathDelim + 'work' + PathDelim + 'demo' + PathDelim + 'scene.pas', False);
  try
    Hot := PathDelim + 'work' + PathDelim + 'demo' + PathDelim + '.hot' + PathDelim;
    ExpectEqual(Workspace.Name, 'scene', 'the program is named after its source');
    ExpectEqual(Workspace.SourceDirectory, PathDelim + 'work' + PathDelim + 'demo' + PathDelim, 'the source directory');
    ExpectEqual(Workspace.HotDirectory, Hot, '.hot is next to the source');
    ExpectEqual(Workspace.UnitsDirectory, Hot + 'units' + PathDelim, 'units');
    ExpectEqual(Workspace.LiveDirectory, Hot + 'live' + PathDelim, 'live');
    ExpectEqual(Workspace.AgentDirectory, Hot + 'agent' + PathDelim, 'agent');
    ExpectEqual(Workspace.AgentSourceDirectory, Hot + 'agent-src' + PathDelim, 'agent-src');
    ExpectEqual(Workspace.Executable, Hot + 'scene', 'the program without an extension');
    ExpectEqual(Workspace.StageDirectory(2), Hot + 'v2' + PathDelim, 'the stage of a swap');
    ExpectEqual(Workspace.StageDirectory(13), Hot + 'v13' + PathDelim, 'by version');
  finally
    Workspace.Free;
  end;
  Workspace := TWorkspace.Create(PathDelim + 'work' + PathDelim + 'Main.lpr', True);
  try
    ExpectEqual(Workspace.Name, 'Main', 'a .lpr source');
    ExpectEqual(Workspace.Executable, PathDelim + 'work' + PathDelim + '.hot' + PathDelim + 'Main.exe',
      'a Windows program has its extension');
  finally
    Workspace.Free;
  end;
end;

procedure TestUnitObjects;
var
  Workspace: TWorkspace;
  Root: string;
  Objects: TStringList;
begin
  Root := MakeTestDirectory('workspace');
  Workspace := TWorkspace.Create(Root + 'demo.pas', False);
  try
    Objects := Workspace.UnitObjects;
    try
      ExpectEqual(Objects.Count, 0, 'no units directory yet');
    finally
      Objects.Free;
    end;
    WriteTestFile(Workspace.UnitsDirectory + 'scene.o', '');
    WriteTestFile(Workspace.UnitsDirectory + 'scene.ppu', '');
    WriteTestFile(Workspace.UnitsDirectory + 'demo.o', '');
    WriteTestFile(Workspace.UnitsDirectory + 'hotfpc.agent.o', '');
    Objects := Workspace.UnitObjects;
    try
      ExpectEqual(Objects.CommaText, 'demo.o,hotfpc.agent.o,scene.o', 'the object files, sorted');
    finally
      Objects.Free;
    end;
  finally
    Workspace.Free;
  end;
end;

begin
  TestPaths;
  TestUnitObjects;
  FinishTests;
end.
