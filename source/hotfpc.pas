program hotfpc;
{ hotfpc: hot reloading for Free Pascal programs, as a wrapper around fpc.

    hotfpc [--fpc FPC] [--ppudump PPUDUMP] [--run LAUNCHER] [--quiet] [--settle MS]
           [--log FILE] [fpc options] program.pas [-- program arguments]

  Builds the program with the given fpc and two additions: its symbols are kept (-Xs-) and
  the agent unit is loaded first (-Fahotagent). Starts it, watches the sources, and on
  every save recompiles and hands the changed object files to the agent inside the
  program, which swaps the code in and keeps the program's state, or says why it needs a
  restart.

  The agent's source is part of this program. It is written out and compiled by the same
  fpc as the program, so hotfpc does not depend on the compiler's version.

  --fpc       the compiler (default: fpc)
  --ppudump   ppudump of the same compiler, for the check of interface layouts
              (default: next to the compiler; without one the check is off)
  --run       a program to start the built program with, such as wine (default: wine
              when the target is Windows and this is not)
  --settle    how long a save must stay unchanged before it is compiled (default 2 ms)
  --log       a copy of every line this program prints, with times }
{$mode objfpc}{$H+}
// Without optimisation, whatever the command line says: fpc 3.3.1+3 for x86-64 at -O1 and
// -O2 gave a loop counter and a temporary string the same register, here and in other
// code (docs/how-it-works.md, "A compiler bug"). Neither the driver nor the agent needs the speed.
{$optimization off}

uses
  {$ifdef unix}cthreads, baseunix,{$endif}
  {$ifdef windows}windows, winsock2,{$endif}
  Classes, SysUtils, Process, Sockets, fpjson, jsonparser;

{$I agentsource.inc}

const
  SOURCE_EXT: array[0..4] of string = ('.pas', '.pp', '.inc', '.lpr', '.dpr');
  // Options that decide the target, how code is generated and where units are: the agent
  // is built with them too.
  AGENT_OPTS: array[0..13] of string = ('-T', '-P', '-Cp', '-Cf', '-Ca', '-XP', '-Fl', '-Fu', '-k', '-XR', '-Xd', '-n', '@', '-V');
  SKIP_KEYS: array[0..5] of string = ('Pos', 'SymId', 'Id', 'Name', 'Fields', 'Visibility');

type
  TStamp = record
    Path: string;
    Size: Int64;
    Time: LongInt;
  end;
  TStamps = array of TStamp;

  { The interface of one unit as the compiler wrote it down, read with ppudump: name=text
    for the layout of each record or class type and the type of each variable. Two texts
    differ exactly when a field was added, removed, moved or retyped, or a variable
    changed its type. }
  TLayout = TStringList;

  THot = class
  private
    FFpc, FPpuDump, FLauncher: string;
    FOpts, FProgArgs, FWatchDirs, FBased, FLayoutNames, FPending: TStringList;
    FLayouts: array of TLayout;
    FSource, FSrcDir, FName, FHot, FUnits, FLive, FAgentDir, FAgentSrc, FExe, FCwd: string;
    FTargetWindows, FWinePaths, FQuiet: Boolean;
    FSettle: Double;
    FLog: TextFile;
    FHasLog: Boolean;
    FVersion: Integer;
    FApplied, FRefused, FFailed, FUnchanged: Integer;
    FListen, FConn: TSocket;
    FToken: string;
    FRecvBuf: string;
    FT0: TDateTime;
    procedure SayLine(const s: string);
    function Compile(link: Boolean; out errors: TStringList; out dt: Double): Boolean;
    function Objects: TStringList;
    function Sources: TStringList;
    function Stamps: TStamps;
    function Digest(out d: TStringList): Boolean;
    procedure ForgetUnits(changed: TStringList);
    function Ask(const fields: array of string): TStringList;
    function AgentPath(const path: string): string;
    procedure BuildAgent;
    procedure Reload(tSeen, tSettled: Double);
    function PpuLayout(const ppu, ownDir: string): TLayout;
    procedure CheckPpuDump;
    procedure WatchOption(const opt: string);
    function RunFpc(const args: array of string; out output: string): Integer;
  public
    constructor Create;
    function Run: Integer;
  end;

// ---------------------------------------------------------------- small helpers
function NowS: Double;
begin
  Result := Now * 86400.0;
end;

function Ms(t: Double): string;
begin
  Result := FormatFloat('0.0', t * 1000.0);
end;

function Fnv64(const s: string): QWord;
var
  i: SizeInt;
begin
{$push}{$Q-}{$R-}
  Result := QWord(1469598103934665603);
  for i := 1 to Length(s) do
    Result := (Result xor Ord(s[i])) * QWord(1099511628211);
{$pop}
end;

function ReadAll(const path: string; out data: string): Boolean;
var
  f: TFileStream;
begin
  data := '';
  try
    f := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
    try
      SetLength(data, f.Size);
      if f.Size > 0 then f.ReadBuffer(data[1], f.Size);
      Result := True;
    finally
      f.Free;
    end;
  except
    Result := False;
  end;
end;

procedure CopyFileTo(const src, dst: string);
var
  a, b: TFileStream;
begin
  a := TFileStream.Create(src, fmOpenRead or fmShareDenyNone);
  try
    b := TFileStream.Create(dst, fmCreate);
    try
      b.CopyFrom(a, 0);
    finally
      b.Free;
    end;
  finally
    a.Free;
  end;
end;

procedure RemoveTree(const dir: string);
var
  sr: TSearchRec;
begin
  if not DirectoryExists(dir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(dir) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      if (sr.Attr and faDirectory) <> 0 then RemoveTree(IncludeTrailingPathDelimiter(dir) + sr.Name)
      else DeleteFile(IncludeTrailingPathDelimiter(dir) + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  RemoveDir(dir);
end;

function SameBytes(const a, b: string): Boolean;
var
  x, y: string;
begin
  Result := ReadAll(a, x) and ReadAll(b, y) and (x = y);
end;

function HasSourceExt(const name: string): Boolean;
var
  e: string;
  i: Integer;
begin
  e := LowerCase(ExtractFileExt(name));
  for i := 0 to High(SOURCE_EXT) do
    if e = SOURCE_EXT[i] then Exit(True);
  Result := False;
end;

function StartsWithAny(const s: string; const prefixes: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(prefixes) do
    if Copy(s, 1, Length(prefixes[i])) = prefixes[i] then Exit(True);
  Result := False;
end;

// A diagnostic that names a place in a source file: "name(12) " or "name(12,5) ".
function IsPlaced(const line: string): Boolean;
var
  i, j: Integer;
begin
  Result := False;
  i := Pos('(', line);
  if (i < 2) or (Pos(' ', Copy(line, 1, i)) > 0) then Exit;
  j := i + 1;
  if (j > Length(line)) or not (line[j] in ['0'..'9']) then Exit;
  while (j <= Length(line)) and (line[j] in ['0'..'9', ',']) do Inc(j);
  Result := (j < Length(line)) and (line[j] = ')') and (line[j + 1] = ' ');
end;

// From "stat a=1 b=2" among the lines: the value of a key, or ''.
function Field(lines: TStringList; const prefix, key: string): string;
var
  i, j: Integer;
  rest, f: string;
begin
  Result := '';
  for i := 0 to lines.Count - 1 do
    if Copy(lines[i], 1, Length(prefix) + 1) = prefix + ' ' then
    begin
      rest := lines[i] + ' ';
      repeat
        j := Pos(' ', rest);
        if j = 0 then Break;
        f := Copy(rest, 1, j - 1);
        Delete(rest, 1, j);
        if Copy(f, 1, Length(key) + 1) = key + '=' then Exit(Copy(f, Length(key) + 2, MaxInt));
      until rest = '';
    end;
end;

// A JSON value as text: strings as they are, numbers and the rest as JSON.
function JStr(o: TJSONObject; const name: string): string;
var
  d: TJSONData;
begin
  d := o.Find(name);
  if d = nil then Result := ''
  else if d is TJSONString then Result := d.AsString
  else Result := d.AsJSON;
end;

// ---------------------------------------------------------------- sockets
procedure SetBlocking(s: TSocket; blocking: Boolean);
{$ifdef windows}
var
  arg: u_long;
begin
  if blocking then arg := 0 else arg := 1;
  ioctlsocket(s, LongInt(FIONBIO), arg);
end;
{$else}
var
  fl: cint;
begin
  fl := FpFcntl(s, F_GETFL);
  if blocking then fl := fl and not O_NONBLOCK else fl := fl or O_NONBLOCK;
  FpFcntl(s, F_SETFL, fl);
end;
{$endif}

procedure CloseSock(s: TSocket);
begin
{$ifdef windows}
  closesocket(s);
{$else}
  FpClose(s);
{$endif}
end;

// ---------------------------------------------------------------- the driver
constructor THot.Create;
var
  i: Integer;
  a, opt: string;
  inArgs: Boolean;
begin
  FFpc := 'fpc';
  FCwd := GetCurrentDir;
  FSettle := 0.002;
  FOpts := TStringList.Create;
  FProgArgs := TStringList.Create;
  FWatchDirs := TStringList.Create;
  FBased := TStringList.Create;
  FLayoutNames := TStringList.Create;
  FPending := TStringList.Create;
  FVersion := 1;
  inArgs := False;
  i := 1;
  while i <= ParamCount do
  begin
    a := ParamStr(i);
    if inArgs then FProgArgs.Add(a)
    else if a = '--' then inArgs := True
    else if (a = '--fpc') and (i < ParamCount) then begin Inc(i); FFpc := ParamStr(i); end
    else if (a = '--ppudump') and (i < ParamCount) then begin Inc(i); FPpuDump := ParamStr(i); end
    else if (a = '--run') and (i < ParamCount) then begin Inc(i); FLauncher := ParamStr(i); end
    else if a = '--quiet' then FQuiet := True
    else if (a = '--settle') and (i < ParamCount) then begin Inc(i); FSettle := StrToFloatDef(ParamStr(i), 2) / 1000.0; end
    else if (a = '--log') and (i < ParamCount) then
    begin
      Inc(i);
      AssignFile(FLog, ParamStr(i));
      Rewrite(FLog);
      FHasLog := True;
    end
    else if (a <> '') and (a[1] in ['-', '@']) then FOpts.Add(a)
    else FSource := ExpandFileName(a);
    Inc(i);
  end;
  if FSource = '' then
  begin
    WriteLn('usage: hotfpc [--fpc FPC] [--ppudump PPUDUMP] [--run LAUNCHER] [--quiet] [--settle MS] [--log FILE] [fpc options] program.pas [-- program arguments]');
    Halt(2);
  end;
  for i := 0 to FOpts.Count - 1 do
  begin
    opt := FOpts[i];
    if (Copy(opt, 1, 2) = '-T') and (LowerCase(Copy(opt, 3, 3)) = 'win') then FTargetWindows := True;
  end;
{$ifdef windows}
  FTargetWindows := True;
{$else}
  if FTargetWindows and (FLauncher = '') then FLauncher := 'wine';
{$endif}
  FWinePaths := Pos('wine', LowerCase(ExtractFileName(FLauncher))) > 0;
  if FPpuDump = '' then
  begin
    a := ExtractFilePath(FFpc);
    if a = '' then a := ExtractFilePath(ExeSearch(FFpc, GetEnvironmentVariable('PATH')));
    if FileExists(a + 'ppudump' + ExtractFileExt(ParamStr(0))) then FPpuDump := a + 'ppudump' + ExtractFileExt(ParamStr(0));
  end;
  FSrcDir := ExtractFilePath(FSource);
  FName := ChangeFileExt(ExtractFileName(FSource), '');
  FHot := FSrcDir + '.hot' + PathDelim;
  FUnits := FHot + 'units' + PathDelim;
  FLive := FHot + 'live' + PathDelim;
  FAgentDir := FHot + 'agent' + PathDelim;
  FAgentSrc := FHot + 'agent-src' + PathDelim;
  FExe := FHot + FName;
  if FTargetWindows then FExe := FExe + '.exe';
  FWatchDirs.Add(ExcludeTrailingPathDelimiter(FSrcDir));
  for i := 0 to FOpts.Count - 1 do WatchOption(FOpts[i]);
  FT0 := Now;
end;

// The directories an option makes fpc search for sources: -Fu and -Fi (several separated by
// ;), also inside a response file (@lwpt.cfg). Relative paths are taken from the current
// directory, as fpc takes them.
procedure THot.WatchOption(const opt: string);
var
  rest, part: string;
  lines: TStringList;
  i, k: Integer;
begin
  if Copy(opt, 1, 1) = '@' then
  begin
    if not FileExists(Copy(opt, 2, MaxInt)) then Exit;
    lines := TStringList.Create;
    try
      lines.LoadFromFile(Copy(opt, 2, MaxInt));
      for i := 0 to lines.Count - 1 do
      begin
        rest := Trim(lines[i]);
        if (rest = '') or (rest[1] in ['#', ';']) then Continue;
        // options on a line are separated by blanks
        while rest <> '' do
        begin
          k := Pos(' ', rest);
          if k = 0 then k := Length(rest) + 1;
          part := Copy(rest, 1, k - 1);
          Delete(rest, 1, k);
          rest := TrimLeft(rest);
          if (part <> '') and (part[1] <> '@') then WatchOption(part);
        end;
      end;
    finally
      lines.Free;
    end;
    Exit;
  end;
  if (Copy(opt, 1, 3) <> '-Fu') and (Copy(opt, 1, 3) <> '-Fi') then Exit;
  rest := Copy(opt, 4, MaxInt);
  while rest <> '' do
  begin
    k := Pos(';', rest);
    if k = 0 then k := Length(rest) + 1;
    part := Copy(rest, 1, k - 1);
    Delete(rest, 1, k);
    if (part <> '') and (Pos('*', part) = 0) then FWatchDirs.Add(ExcludeTrailingPathDelimiter(ExpandFileName(part)));
  end;
end;

// The files fpc leaves in its working directory when it does not link (-Cn) or links
// through a script: they are removed after each compile, if they were not there before.
function IsCompilerLeftover(const name: string): Boolean;
begin
  Result := ((Copy(name, 1, 4) = 'link') and (ExtractFileExt(name) = '.res')) or (Copy(name, 1, 12) = 'symbol_order')
    or (name = 'ppas.sh') or (name = 'ppas.bat');
end;

function Leftovers(const dir: string): TStringList;
var
  sr: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if FindFirst(IncludeTrailingPathDelimiter(dir) + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if IsCompilerLeftover(sr.Name) then Result.Add(sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

// fpc, run in the current directory, as the user would run it: relative paths in options and
// response files, and a fpc.cfg there, mean what they mean to fpc.
function THot.RunFpc(const args: array of string; out output: string): Integer;
var
  before, after: TStringList;
  i: Integer;
begin
  before := Leftovers(FCwd);
  output := '';
  Result := 0;
  RunCommandInDir(FCwd, FFpc, args, output, Result, [poStderrToOutPut]);
  after := Leftovers(FCwd);
  for i := 0 to after.Count - 1 do
    if before.IndexOf(after[i]) < 0 then DeleteFile(IncludeTrailingPathDelimiter(FCwd) + after[i]);
  before.Free;
  after.Free;
end;

procedure THot.SayLine(const s: string);
var
  line: string;
begin
  line := '[hot] ' + s;
  WriteLn(line);
  Flush(Output);
  if FHasLog then
  begin
    WriteLn(FLog, FormatFloat('0.000000', NowS), ' ', line);
    Flush(FLog);
  end;
end;

// ---------------------------------------------------------------- compiling
function THot.Compile(link: Boolean; out errors: TStringList; out dt: Double): Boolean;
var
  args: array of string;
  i, status: Integer;
  output, l: string;
  lines, all: TStringList;
  sr: TSearchRec;
  t: Double;

  procedure Add(const a: string);
  begin
    SetLength(args, Length(args) + 1);
    args[High(args)] := a;
  end;

begin
  SetLength(args, 0);
  Add('-Xs-');
  Add('-Fahotagent');
  Add('-Fu' + ExcludeTrailingPathDelimiter(FAgentDir));
  Add('-FU' + ExcludeTrailingPathDelimiter(FUnits));
  Add('-o' + FExe);
  for i := 0 to FOpts.Count - 1 do Add(FOpts[i]);
  if not link then Add('-Cn')
  // the linker's map: where it put sections that fpc 3.2 gives no symbol (the agent reads it)
  else if FTargetWindows then Add('-Xm');
  Add(FSource);
  t := NowS;
  status := RunFpc(args, output);
  dt := NowS - t;
  lines := TStringList.Create;
  all := TStringList.Create;
  errors := TStringList.Create;
  try
    lines.Text := output;
    for i := 0 to lines.Count - 1 do
    begin
      l := lines[i];
      if (Pos(' Error: ', l) > 0) or (Pos(' Fatal: ', l) > 0) or (Copy(l, 1, 6) = 'Fatal:') or (Copy(l, 1, 6) = 'Error:') then
      begin
        all.Add(l);
        if IsPlaced(l) then errors.Add(l);
      end;
    end;
    // the diagnostics that name a place in a source file; the closing lines only when there is nothing else
    if errors.Count = 0 then errors.Assign(all);
  finally
    lines.Free;
    all.Free;
  end;
  Result := status = 0;
end;

function THot.Objects: TStringList;
var
  sr: TSearchRec;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if FindFirst(FUnits + '*.o', faAnyFile, sr) = 0 then
  begin
    repeat
      Result.Add(sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

// The agent unit, written out and compiled once into a directory of its own. fpc 3.3.1's -Fa
// cannot load a unit it would recompile, so the source is not on the program's search path.
procedure THot.BuildAgent;
var
  f: TextFile;
  i, status: Integer;
  args: array of string;
  output: string;
begin
  ForceDirectories(FAgentDir);
  ForceDirectories(FAgentSrc);
  AssignFile(f, FAgentSrc + 'hotagent.pas');
  Rewrite(f);
  for i := 0 to High(AgentSourceLines) do WriteLn(f, AgentSourceLines[i]);
  CloseFile(f);
  SetLength(args, 0);
  for i := 0 to FOpts.Count - 1 do
    if StartsWithAny(FOpts[i], AGENT_OPTS) then
    begin
      SetLength(args, Length(args) + 1);
      args[High(args)] := FOpts[i];
    end;
  SetLength(args, Length(args) + 2);
  args[High(args) - 1] := '-FU' + ExcludeTrailingPathDelimiter(FAgentDir);
  args[High(args)] := FAgentSrc + 'hotagent.pas';
  status := RunFpc(args, output);
  if (status <> 0) or not FileExists(FAgentDir + 'hotagent.ppu') then
  begin
    WriteLn('[hot] the agent did not compile:');
    WriteLn(output);
    Halt(1);
  end;
end;

// ---------------------------------------------------------------- the agent
function THot.AgentPath(const path: string): string;
begin
  // a program under Wine sees the host's root as drive Z:
  if FWinePaths then Result := 'Z:' + StringReplace(path, '/', '\', [rfReplaceAll])
  else Result := path;
end;

function THot.Ask(const fields: array of string): TStringList;
var
  line: string;
  i, n: Integer;
  buf: array[0..65535] of Char;
begin
  line := '';
  for i := 0 to High(fields) do
  begin
    if i > 0 then line := line + #9;
    line := line + fields[i];
  end;
  line := line + #10;
  i := 1;
  while i <= Length(line) do
  begin
    n := fpSend(FConn, @line[i], Length(line) - i + 1, 0);
    if n <= 0 then Break;
    Inc(i, n);
  end;
  Result := TStringList.Create;
  repeat
    n := Pos(#10, FRecvBuf);
    if n > 0 then
    begin
      line := Copy(FRecvBuf, 1, n - 1);
      Delete(FRecvBuf, 1, n);
      if line = '.' then Exit;
      Result.Add(line);
      Continue;
    end;
    n := fpRecv(FConn, @buf[0], SizeOf(buf), 0);
    if n <= 0 then Exit;
    SetLength(line, n);
    Move(buf[0], line[1], n);
    FRecvBuf := FRecvBuf + line;
  until False;
end;

// ---------------------------------------------------------------- watching
function THot.Sources: TStringList;
var
  i: Integer;
  sr: TSearchRec;
  d: string;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  for i := 0 to FWatchDirs.Count - 1 do
  begin
    d := IncludeTrailingPathDelimiter(FWatchDirs[i]);
    if FindFirst(d + '*', faAnyFile, sr) = 0 then
    begin
      repeat
        if ((sr.Attr and faDirectory) = 0) and HasSourceExt(sr.Name) then Result.Add(d + sr.Name);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
  end;
end;

// What polling compares: names, sizes and times of the watched files. Times have whole
// seconds only; the loop also compares contents twice a second, which catches an edit of
// the same size within the same second.
function THot.Stamps: TStamps;
var
  src: TStringList;
  i: Integer;
  sr: TSearchRec;
begin
  src := Sources;
  try
    SetLength(Result, src.Count);
    for i := 0 to src.Count - 1 do
    begin
      Result[i].Path := src[i];
      Result[i].Size := -1;
      Result[i].Time := 0;
      if FindFirst(src[i], faAnyFile, sr) = 0 then
      begin
        Result[i].Size := sr.Size;
        Result[i].Time := sr.Time;
        FindClose(sr);
      end;
    end;
  finally
    src.Free;
  end;
end;

function SameStamps(const a, b: TStamps): Boolean;
var
  i: Integer;
begin
  if Length(a) <> Length(b) then Exit(False);
  for i := 0 to High(a) do
    if (a[i].Path <> b[i].Path) or (a[i].Size <> b[i].Size) or (a[i].Time <> b[i].Time) then Exit(False);
  Result := True;
end;

// The content of every source file as path=digest; False while a file is missing or empty
// (a save in progress).
function THot.Digest(out d: TStringList): Boolean;
var
  src: TStringList;
  i: Integer;
  data: string;
begin
  d := TStringList.Create;
  src := Sources;
  try
    for i := 0 to src.Count - 1 do
    begin
      if not ReadAll(src[i], data) or (data = '') then
      begin
        FreeAndNil(d);
        Exit(False);
      end;
      d.Add(src[i] + '=' + IntToHex(Fnv64(data), 16));
    end;
  finally
    src.Free;
  end;
  Result := True;
end;

// Make the compiler recompile the units whose source changed, whatever it thinks. Its own
// check compares times of one-second granularity: an edit saved in the same second as its
// previous compile of the unit goes unnoticed. The driver knows from the content which files
// changed, so it removes the compiler's record of those units from its own unit directory.
// HOT_TRUST_TIMESTAMPS=1 turns this off.
procedure THot.ForgetUnits(changed: TStringList);
var
  i, k: Integer;
  ppus: TStringList;
  sr: TSearchRec;
  base: string;
begin
  if GetEnvironmentVariable('HOT_TRUST_TIMESTAMPS') <> '' then Exit;
  ppus := TStringList.Create;
  try
    if FindFirst(FUnits + '*.ppu', faAnyFile, sr) = 0 then
    begin
      repeat
        ppus.Add(sr.Name);
      until FindNext(sr) <> 0;
      FindClose(sr);
    end;
    for i := 0 to changed.Count - 1 do
    begin
      base := LowerCase(ChangeFileExt(ExtractFileName(changed[i]), ''));
      for k := 0 to ppus.Count - 1 do
        // an include file can be part of any unit
        if (LowerCase(ExtractFileExt(changed[i])) = '.inc') or (LowerCase(ChangeFileExt(ppus[k], '')) = base) then
        begin
          if GetEnvironmentVariable('HOT_DEBUG') <> '' then WriteLn('[hot debug] forget ', ppus[k], ' for ', changed[i]);
          DeleteFile(FUnits + ppus[k]);
        end;
    end;
  finally
    ppus.Free;
  end;
end;

// ---------------------------------------------------------------- interface layouts (ppudump)
function THot.PpuLayout(const ppu, ownDir: string): TLayout;
var
  root: TJSONObject;
  defs, others: TStringList;
  holders: TList;

  function Load(const path: string; d: TStringList): TJSONObject;
  var
    output: string;
    data: TJSONData;

    procedure Collect(items: TJSONArray);
    var
      i: Integer;
      x: TJSONObject;
    begin
      for i := 0 to items.Count - 1 do
        if items.Items[i] is TJSONObject then
        begin
          x := TJSONObject(items.Items[i]);
          if x.Find('Id') <> nil then d.AddObject(JStr(x, 'Id'), x);
          if x.Find('Fields') is TJSONArray then Collect(TJSONArray(x.Find('Fields')));
        end;
    end;

  begin
    Result := nil;
    output := '';
    RunCommand(FPpuDump, ['-Fj', path], output, [poStderrToOutPut]);
    try
      data := GetJSON(output);
    except
      data := nil;
    end;
    if data = nil then Exit;
    holders.Add(data);
    if (data is TJSONArray) and (TJSONArray(data).Count > 0) and (TJSONArray(data).Items[0] is TJSONObject) then
      Result := TJSONObject(TJSONArray(data).Items[0]);
    if (Result <> nil) and (Result.Find('Interface') is TJSONArray) then Collect(TJSONArray(Result.Find('Interface')));
  end;

  function Canon(x: TJSONObject; depth: Integer): string; forward;

  function Ref(t: TJSONData; depth: Integer): string;
  var
    o, x: TJSONObject;
    u, id: string;
    i: Integer;
    od: TStringList;
  begin
    if not (t is TJSONObject) or (TJSONObject(t).Find('Id') = nil) then Exit('?');
    o := TJSONObject(t);
    id := JStr(o, 'Id');
    if o.Find('Unit') <> nil then
    begin
      u := TJSONArray(root.Find('Units')).Strings[StrToIntDef(JStr(o, 'Unit'), 0)];
      if FileExists(ownDir + LowerCase(u) + '.ppu') then   // a unit of the program: its numbering moves, its names do not
      begin
        i := others.IndexOf(u);
        if i < 0 then
        begin
          od := TStringList.Create;
          od.Sorted := True;
          od.Duplicates := dupIgnore;
          Load(ownDir + LowerCase(u) + '.ppu', od);
          i := others.AddObject(u, od);
        end;
        od := TStringList(others.Objects[i]);
        i := od.IndexOf(id);
        if (i >= 0) and (JStr(TJSONObject(od.Objects[i]), 'Name') <> '') then Exit(u + '.' + JStr(TJSONObject(od.Objects[i]), 'Name'));
      end;
      Exit(u + '#' + id);
    end;
    i := defs.IndexOf(id);
    if i < 0 then Exit('#' + id);
    x := TJSONObject(defs.Objects[i]);
    if (JStr(x, 'Name') <> '') and (JStr(x, 'Name')[1] <> '$') then Exit(JStr(x, 'Name'));
    Result := Canon(x, depth + 1);
  end;

  function Canon(x: TJSONObject; depth: Integer): string;
  var
    keys: TStringList;
    i, k: Integer;
    v: TJSONData;
    f: TJSONObject;
    fl: TJSONArray;
    skip: Boolean;
  begin
    if depth > 6 then Exit('...');
    keys := TStringList.Create;
    try
      keys.CaseSensitive := True;
      for i := 0 to x.Count - 1 do keys.Add(x.Names[i]);
      keys.Sort;
      Result := '{';
      for i := 0 to keys.Count - 1 do
      begin
        skip := False;
        for k := 0 to High(SKIP_KEYS) do
          if keys[i] = SKIP_KEYS[k] then skip := True;
        if skip then Continue;
        v := x.Find(keys[i]);
        if v is TJSONObject then Result := Result + keys[i] + '=' + Ref(v, depth) + ' '
        else Result := Result + keys[i] + '=' + v.AsJSON + ' ';
      end;
      if x.Find('Fields') is TJSONArray then
      begin
        fl := TJSONArray(x.Find('Fields'));
        for i := 0 to fl.Count - 1 do
          if fl.Items[i] is TJSONObject then
          begin
            f := TJSONObject(fl.Items[i]);
            if JStr(f, 'Type') = 'field' then Result := Result + JStr(f, 'Name') + ':' + Ref(f.Find('VarType'), depth) + ' ';
          end;
      end;
      Result := Result + '}';
    finally
      keys.Free;
    end;
  end;

var
  i: Integer;
  x: TJSONObject;
  intf: TJSONArray;
  typ: string;
begin
  Result := TLayout.Create;
  holders := TList.Create;
  defs := TStringList.Create;
  defs.Sorted := True;
  defs.Duplicates := dupIgnore;
  others := TStringList.Create;
  try
    root := Load(ppu, defs);
    if (root <> nil) and (root.Find('Interface') is TJSONArray) then
    begin
      intf := TJSONArray(root.Find('Interface'));
      for i := 0 to intf.Count - 1 do
      begin
        if not (intf.Items[i] is TJSONObject) then Continue;
        x := TJSONObject(intf.Items[i]);
        // the compiler's own types ($vmtdef$TFoo in fpc 3.2) are not declarations of the program
        if (JStr(x, 'Name') = '') or (JStr(x, 'Name')[1] = '$') then Continue;
        typ := JStr(x, 'Type');
        if typ = 'var' then Result.Values['variable ' + JStr(x, 'Name')] := Ref(x.Find('VarType'), 0)
        else if (typ = 'rec') or (typ = 'obj') then Result.Values['type ' + JStr(x, 'Name')] := Canon(x, 0);
      end;
    end;
  finally
    defs.Free;
    for i := 0 to others.Count - 1 do others.Objects[i].Free;
    others.Free;
    for i := 0 to holders.Count - 1 do TJSONData(holders[i]).Free;
    holders.Free;
  end;
end;

// A ppudump that cannot read this compiler's units (another version: "Unsupported PPU
// version") would make every interface look unchanged. Try it on one of the program's units
// and turn the check off, saying why, when it does not work.
procedure THot.CheckPpuDump;
var
  sr: TSearchRec;
  output, first: string;
  data: TJSONData;
  ok: Boolean;
begin
  if FPpuDump = '' then Exit;
  if FindFirst(FUnits + '*.ppu', faAnyFile, sr) <> 0 then Exit;
  output := '';
  RunCommand(FPpuDump, ['-Fj', FUnits + sr.Name], output, [poStderrToOutPut]);
  FindClose(sr);
  ok := False;
  try
    data := GetJSON(output);
    ok := (data is TJSONArray) and (TJSONArray(data).Count > 0) and (TJSONArray(data).Items[0] is TJSONObject)
      and (TJSONObject(TJSONArray(data).Items[0]).Find('Interface') <> nil);
    data.Free;
  except
    ok := False;
  end;
  if ok then Exit;
  first := Trim(Copy(output, 1, Pos(#10, output + #10) - 1));
  WriteLn('[hot] ', FPpuDump, ' cannot read this compiler''s units (', first, '): the check of interface layouts is off; --ppudump names one that can');
  FPpuDump := '';
end;

// ---------------------------------------------------------------- one save
procedure THot.Reload(tSeen, tSettled: Double);
var
  errors, objs, changed, reply, newLayout, bad: TStringList;
  tCompile, t, tIface, tLoad: Double;
  i, k, li: Integer;
  o, ppu, stage, verdict, units, key: string;
  fields: array of string;
begin
  if not Compile(False, errors, tCompile) then
  begin
    Inc(FFailed);
    if errors.Count = 0 then errors.Add('the compiler failed');
    for i := 0 to errors.Count - 1 do
      if i < 6 then SayLine('error: ' + errors[i] + ' (nothing changed)');
    errors.Free;
    Exit;
  end;
  errors.Free;
  changed := TStringList.Create;
  objs := Objects;
  bad := TStringList.Create;
  try
    for i := 0 to objs.Count - 1 do
    begin
      o := objs[i];
      if not FileExists(FLive + o) then
      begin
        // Its initialization section has never run and cannot run on the agent's thread.
        Inc(FRefused);
        SayLine('restart needed: unit ' + ChangeFileExt(o, '') + ' is not part of the running program (not applied; compile ' + Ms(tCompile) + ' ms)');
        DeleteFile(FUnits + o);
        DeleteFile(FUnits + ChangeFileExt(o, '.ppu'));
        Exit;
      end;
      if not SameBytes(FUnits + o, FLive + o) then changed.Add(o);
    end;
    // The interface of each changed unit, as the compiler wrote it down: a field that moved or
    // changed its type without changing a size is invisible in the object file.
    t := NowS;
    if FPpuDump <> '' then
      for i := 0 to changed.Count - 1 do
      begin
        ppu := ChangeFileExt(changed[i], '.ppu');
        if not (FileExists(FLive + ppu) and FileExists(FUnits + ppu)) then Continue;
        li := FLayoutNames.IndexOf(ppu);
        if li < 0 then
        begin
          SetLength(FLayouts, Length(FLayouts) + 1);
          FLayouts[High(FLayouts)] := PpuLayout(FLive + ppu, FLive);
          li := FLayoutNames.Add(ppu);
        end;
        newLayout := PpuLayout(FUnits + ppu, FUnits);
        for k := 0 to newLayout.Count - 1 do
        begin
          key := newLayout.Names[k];
          if (FLayouts[li].IndexOfName(key) >= 0) and (FLayouts[li].Values[key] <> newLayout.ValueFromIndex[k]) then bad.Add(key);
        end;
        if bad.Count > 0 then
        begin
          Inc(FRefused);
          for k := 0 to bad.Count - 1 do
            SayLine('restart needed: ' + ChangeFileExt(changed[i], '') + '.' + Copy(bad[k], Pos(' ', bad[k]) + 1, MaxInt)
              + ': the declaration changed its layout or type (not applied; compile ' + Ms(tCompile) + ' ms)');
          newLayout.Free;
          Exit;
        end;
        k := FPending.IndexOf(ppu);
        if k >= 0 then
        begin
          FPending.Objects[k].Free;
          FPending.Delete(k);
        end;
        FPending.AddObject(ppu, newLayout);
      end;
    tIface := NowS - t;
    if changed.Count = 0 then
    begin
      Inc(FUnchanged);
      SayLine('not swapped: the generated code is the same (compile ' + Ms(tCompile) + ' ms)');
      Exit;
    end;
    t := NowS;
    for i := 0 to changed.Count - 1 do
      if (FBased.IndexOf(changed[i]) < 0) and FileExists(FLive + changed[i]) then
      begin
        Ask(['base', AgentPath(FLive + changed[i])]).Free;
        FBased.Add(changed[i]);
      end;
    stage := FHot + 'v' + IntToStr(FVersion + 1) + PathDelim;
    ForceDirectories(stage);
    SetLength(fields, 1);
    fields[0] := 'load';
    for i := 0 to changed.Count - 1 do
    begin
      CopyFileTo(FUnits + changed[i], stage + changed[i]);
      SetLength(fields, Length(fields) + 1);
      fields[High(fields)] := AgentPath(stage + changed[i]);
    end;
    reply := Ask(fields);
    try
      tLoad := NowS - t;
      if reply.Count > 0 then verdict := reply[reply.Count - 1] else verdict := 'failed';
      units := '';
      for i := 0 to changed.Count - 1 do
      begin
        if i > 0 then units := units + ', ';
        units := units + ChangeFileExt(changed[i], '');
      end;
      if verdict = 'ok' then
      begin
        Inc(FVersion);
        Inc(FApplied);
        for i := 0 to changed.Count - 1 do
        begin
          CopyFileTo(stage + changed[i], FLive + changed[i]);
          ppu := ChangeFileExt(changed[i], '.ppu');
          if FileExists(FUnits + ppu) then CopyFileTo(FUnits + ppu, FLive + ppu);
          k := FPending.IndexOf(ppu);
          li := FLayoutNames.IndexOf(ppu);
          if (k >= 0) and (li >= 0) then
          begin
            FLayouts[li].Free;
            FLayouts[li] := TLayout(FPending.Objects[k]);
            FPending.Delete(k);
          end;
          if FBased.IndexOf(changed[i]) < 0 then FBased.Add(changed[i]);
        end;
        SayLine(Format('v%d swapped: %s: %s functions redirected (%s with other code, %s new), %s variables and tables kept, %s new, %s bytes; '
          + '%s ms after the save was seen (settle %s, compile %s, interface check %s, load %s of which in the program %s)',
          [FVersion, units, Field(reply, 'stat', 'redirected'), Field(reply, 'stat', 'changed'), Field(reply, 'stat', 'added'),
           Field(reply, 'stat', 'kept'), Field(reply, 'stat', 'newdata'), Field(reply, 'stat', 'bytes'),
           Ms(NowS - tSeen), Ms(tSettled - tSeen), Ms(tCompile), Ms(tIface), Ms(tLoad), Field(reply, 'time', 'total')]));
        for i := 0 to reply.Count - 1 do
          if Copy(reply[i], 1, 5) = 'note ' then SayLine('  note: ' + Copy(reply[i], 6, MaxInt));
      end
      else
      begin
        if verdict = 'refused' then Inc(FRefused) else Inc(FFailed);
        RemoveTree(ExcludeTrailingPathDelimiter(stage));
        for i := 0 to reply.Count - 1 do
          if (verdict = 'refused') and (Copy(reply[i], 1, 8) = 'restart ') then
            SayLine('restart needed: ' + Copy(reply[i], 9, MaxInt) + ' (not applied; compile ' + Ms(tCompile) + ' ms)')
          else if (verdict <> 'refused') and (Copy(reply[i], 1, 6) = 'error ') then
            SayLine('error: ' + Copy(reply[i], 7, MaxInt) + ' (nothing changed)');
        if reply.Count = 0 then SayLine('error: the program did not answer (nothing changed)');
      end;
    finally
      reply.Free;
    end;
  finally
    changed.Free;
    objs.Free;
    bad.Free;
  end;
end;

// ---------------------------------------------------------------- main
function THot.Run: Integer;
var
  errors, objs, last, d, changedFiles: TStringList;
  dt, tStart, tSeen, lastDigest: Double;
  i, n: Integer;
  sr: TSearchRec;
  addr: TInetSockAddr;
  alen: TSockLen;
  child: TProcess;
  seen, cur, again: TStamps;
  hello, name, value: string;
  c: Char;
  deadline: Double;
  conn: TSocket;
  found: Boolean;
{$ifdef windows}
  wsa: TWSAData;
{$endif}
begin
{$ifdef windows}
  WSAStartup($0202, wsa);
{$endif}
  RemoveTree(ExcludeTrailingPathDelimiter(FHot));
  ForceDirectories(FUnits);
  ForceDirectories(FLive);
  if FPpuDump = '' then WriteLn('[hot] no ppudump next to the compiler (--ppudump): the check of interface layouts is off');
  BuildAgent;
  if not Compile(True, errors, dt) then
  begin
    for i := 0 to errors.Count - 1 do WriteLn(errors[i]);
    Halt(1);
  end;
  errors.Free;
  if FindFirst(FUnits + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (ExtractFileExt(sr.Name) = '.o') or (ExtractFileExt(sr.Name) = '.ppu') then CopyFileTo(FUnits + sr.Name, FLive + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  CheckPpuDump;
  // listen on 127.0.0.1, on a port the system picks
  FListen := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := 0;
  addr.sin_addr.s_addr := htonl($7f000001);
  if fpBind(FListen, @addr, SizeOf(addr)) <> 0 then
  begin
    WriteLn('[hot] cannot listen on 127.0.0.1');
    Halt(1);
  end;
  fpListen(FListen, 8);
  alen := SizeOf(addr);
  fpGetSockName(FListen, @addr, @alen);
  Randomize;
  FToken := IntToHex(Random($7fffffff), 8) + IntToHex(Random($7fffffff), 8);
  last := nil;
  Digest(last);
  child := TProcess.Create(nil);
  if FLauncher <> '' then
  begin
    child.Executable := FLauncher;
    child.Parameters.Add(FExe);
  end
  else child.Executable := FExe;
  for i := 0 to FProgArgs.Count - 1 do child.Parameters.Add(FProgArgs[i]);
  for i := 1 to GetEnvironmentVariableCount do child.Environment.Add(GetEnvironmentString(i));
  child.Environment.Add('HOT_PORT=' + IntToStr(ntohs(addr.sin_port)));
  child.Environment.Add('HOT_TOKEN=' + FToken);
  child.Options := [];
  tStart := NowS;
  child.Execute;
  // macOS checks a newly linked executable on its first start (seconds, more under load);
  // Wine starts its server the first time. Wait up to 60 s.
  SetBlocking(FListen, False);
  deadline := NowS + 60;
  found := False;
  repeat
    conn := fpAccept(FListen, nil, nil);
    if conn <> TSocket(-1) then
    begin
      SetBlocking(conn, True);
      hello := '';
      repeat
        n := fpRecv(conn, @c, 1, 0);
        if (n <= 0) or (c = #10) then Break;
        hello := hello + c;
      until Length(hello) > 200;
      if hello = 'hello ' + FToken then
      begin
        FConn := conn;
        found := True;
      end
      else CloseSock(conn);   // a program the program started, or something else: not ours
    end;
    if not found then
    begin
      if not child.Running then
      begin
        // too short for its agent to connect, or it did not start
        WriteLn('[hot] the program ended (exit code ', child.ExitCode, ') before hot reloading could start');
        Halt(child.ExitCode);
      end;
      if NowS > deadline then
      begin
        WriteLn('[hot] the program did not connect within 60 s');
        child.Terminate(1);
        Halt(1);
      end;
      Sleep(5);
    end;
  until found;
  objs := Objects;
  if not FQuiet then
  begin
    d := Sources;
    SayLine(Format('v1: built in %s ms, started in %s ms, %d units of its own, watching %d files', [Ms(dt), Ms(NowS - tStart), objs.Count, d.Count]));
    d.Free;
  end;
  objs.Free;
  seen := Stamps;
  lastDigest := NowS;
  while True do
  begin
    Sleep(10);
    if not child.Running then Break;
    cur := Stamps;
    if SameStamps(cur, seen) and (NowS - lastDigest < 0.5) then Continue;
    tSeen := NowS;
    if not SameStamps(cur, seen) then
      repeat   // wait for the save to stop changing the files
        Sleep(Trunc(FSettle * 1000) + 2);
        again := Stamps;
        if SameStamps(again, cur) then Break;
        cur := again;
      until False;
    seen := cur;
    lastDigest := NowS;
    if not Digest(d) then Continue;   // a missing or empty file
    if (last <> nil) and (d.Text = last.Text) then
    begin
      d.Free;
      Continue;
    end;
    changedFiles := TStringList.Create;
    // Each value into a variable of its own first: fpc 3.3.1+3 for x86-64 gave the loop
    // counter and the temporary result of ValueFromIndex the same register when this was
    // one expression (README, "A compiler bug").
    for i := 0 to d.Count - 1 do
    begin
      name := d.Names[i];
      value := d.ValueFromIndex[i];
      if (last = nil) or (last.Values[name] <> value) then changedFiles.Add(name);
    end;
    if GetEnvironmentVariable('HOT_DEBUG') <> '' then WriteLn('[hot debug] seen at ', FormatFloat('0.000', tSeen - lastDigest), ' changed ', changedFiles.CommaText);
    ForgetUnits(changedFiles);
    changedFiles.Free;
    last.Free;
    last := d;
    Reload(tSeen, NowS);
    if not child.Running then Break;
  end;
  child.WaitOnExit;
  Result := child.ExitCode;
  if (Result = 0) and (child.ExitStatus <> 0) then Result := -1;   // ended by a signal
  CloseSock(FConn);
  CloseSock(FListen);
  if not FQuiet then
    SayLine(Format('the program ended with %d after %s s; %d reloads applied, %d refused, %d failed to compile, %d without a change in code',
      [Result, FormatFloat('0.0', (Now - FT0) * 86400.0), FApplied, FRefused, FFailed, FUnchanged]));
  child.Free;
end;

var
  hot: THot;
begin
  hot := THot.Create;
  Halt(hot.Run);
end.
