#!/usr/bin/env python3
"""State across a reload: one program per case, and the edits saved into it while it runs.

  scenario.py                 run every case
  scenario.py classes heap    run the named cases
"""
import os, shlex, re, shutil, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
HOTRUN = os.environ.get("HOT_DRIVER") or os.path.join(HERE, "..", "..", "build", "hotfpc")


def driver_cmd():
    """The driver: a Python script or a program; HOT_DRIVER_OPTS go before everything else."""
    extra = shlex.split(os.environ.get("HOT_DRIVER_OPTS", ""))
    if HOTRUN.endswith(".py"):
        return [sys.executable, HOTRUN] + extra
    return [HOTRUN] + extra

MAIN = r'''program main;
{$mode objfpc}{$H+}
uses SysUtils, u;
var
  Count: Integer = 0;
begin
  while Count < StrToInt(ParamStr(1)) do
  begin
    Inc(Count);
    WriteLn('tick ', Count, ': ', Tick(Count));
    Flush(Output);
    Sleep(300);
  end;
end.
'''

CASES = {}


def case(name, files, steps, ticks=None, opts=(), restart=False):
    """restart: the driver starts the program over when an edit needs a restart; the other
    cases pass --no-restart, so that the program they check keeps running."""
    CASES[name] = (files, steps, ticks, tuple(opts) + (() if restart else ("--no-restart",)))


# ---------------------------------------------------------------------------- globals
case("globals", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
var
  Total: Integer = 0;
function Tick(n: Integer): string;
implementation
uses SysUtils;
var
  Hidden: Integer;
  Speed: Integer = 5;
function Tick(n: Integer): string;
begin
  Inc(Total, Speed);
  Inc(Hidden);
  Result := Format('total %d hidden %d speed %d', [Total, Hidden, Speed]);
end;
end.
'''}, [
    ("a new variable with an initial value, and another text",
     [("u.pas", "  Speed: Integer = 5;", "  Speed: Integer = 5;\n  Extra: Integer = 100;"),
      ("u.pas", "Format('total %d hidden %d speed %d', [Total, Hidden, Speed])", "Format('TOTAL %d hidden %d speed %d extra %d', [Total, Hidden, Speed, Extra])")]),
    ("Speed = 5 becomes Speed = 50 (nothing has written Speed)", [("u.pas", "Speed: Integer = 5;", "Speed: Integer = 50;")]),
    ("Total = 0 becomes Total = 1000 (the program has written Total)", [("u.pas", "Total: Integer = 0;", "Total: Integer = 1000;")]),
    ("Hidden: Integer becomes Hidden: Int64", [("u.pas", "Hidden: Integer;", "Hidden: Int64;")]),
    ("back to Integer, another text", [("u.pas", "Hidden: Int64;", "Hidden: Integer;"), ("u.pas", "'TOTAL %d", "'total again %d")]),
])

# ---------------------------------------------------------------------------- classes
case("classes", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
type
  TAnimal = class
  private
    FName: string;
    FLegs: Integer;
  public
    constructor Create(const AName: string; ALegs: Integer);
    function Speak: string; virtual;
    function Describe: string;
  end;
  TDog = class(TAnimal)
    function Speak: string; override;
  end;
  TCat = class(TAnimal)
  end;
var
  Zoo: array of TAnimal;
function Tick(n: Integer): string;
implementation
uses SysUtils;
constructor TAnimal.Create(const AName: string; ALegs: Integer);
begin
  FName := AName;
  FLegs := ALegs;
end;
function TAnimal.Speak: string;
begin
  Result := '...';
end;
function TAnimal.Describe: string;
begin
  Result := FName + ' says ' + Speak;
end;
function TDog.Speak: string;
begin
  Result := 'woof';
end;
function Tick(n: Integer): string;
var
  a: TAnimal;
begin
  if Length(Zoo) = 0 then
  begin
    SetLength(Zoo, 2);
    Zoo[0] := TDog.Create('Rex', 4);
    Zoo[1] := TCat.Create('Tom', 4);
  end;
  Result := '';
  for a in Zoo do
    Result := Result + a.Describe + '; ';
end;
end.
'''}, [
    ("the body of a virtual method (TDog.Speak)", [("u.pas", "Result := 'woof';", "Result := 'WOOF WOOF';")]),
    ("TCat gains an override of Speak: its VMT slot changes",
     [("u.pas", "  TCat = class(TAnimal)\n  end;", "  TCat = class(TAnimal)\n    function Speak: string; override;\n  end;"),
      ("u.pas", "function Tick(n: Integer): string;\nvar", "function TCat.Speak: string;\nbegin\n  Result := 'meow';\nend;\nfunction Tick(n: Integer): string;\nvar")]),
    ("new code tests the class of objects made by old code (is)",
     [("u.pas", "    Result := Result + a.Describe + '; ';", "    if a is TDog then Result := Result + '[dog] ' + a.Describe + '; ' else Result := Result + '[' + a.ClassName + '] ' + a.Describe + '; ';")]),
    ("TAnimal gains a field", [("u.pas", "    FLegs: Integer;", "    FLegs: Integer;\n    FAge: Int64;")]),
    ("the field goes again; TAnimal gains a virtual method",
     [("u.pas", "    FLegs: Integer;\n    FAge: Int64;", "    FLegs: Integer;"),
      ("u.pas", "    function Describe: string;", "    function Describe: string;\n    function Weight: Integer; virtual;"),
      ("u.pas", "function TDog.Speak: string;", "function TAnimal.Weight: Integer;\nbegin\n  Result := 1;\nend;\nfunction TDog.Speak: string;")]),
])

# ---------------------------------------------------------------------------- heap
case("heap", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
uses Classes;
var
  Names: array of string;
  Joined: string;
  List: TStringList;
function Tick(n: Integer): string;
implementation
uses SysUtils;
function Tick(n: Integer): string;
begin
  if List = nil then List := TStringList.Create;
  SetLength(Names, Length(Names) + 1);
  Names[High(Names)] := 'name' + IntToStr(n);
  Joined := Joined + IntToStr(n) + ',';
  List.Add('item' + IntToStr(n));
  Result := Format('%d names, joined "%s", list %d, heap used %d', [Length(Names), Joined, List.Count, GetFPCHeapStatus.CurrHeapUsed]);
end;
end.
'''}, [
    ("new code shrinks the array, cuts the string and frees the list that old code allocated",
     [("u.pas", "  if List = nil then List := TStringList.Create;\n  SetLength(Names, Length(Names) + 1);\n  Names[High(Names)] := 'name' + IntToStr(n);\n  Joined := Joined + IntToStr(n) + ',';\n  List.Add('item' + IntToStr(n));",
       "  if (List <> nil) and (List.Count > 3) then FreeAndNil(List);\n  if List = nil then List := TStringList.Create;\n  if Length(Names) > 2 then SetLength(Names, 2);\n  Names[High(Names)] := Names[High(Names)] + '!';\n  if Length(Joined) > 4 then SetLength(Joined, 4);\n  Joined := Joined + '|';\n  List.Add('item' + IntToStr(n));"),
      ("u.pas", "'%d names, joined", "'last name ' + Names[High(Names)] + ', %d names, joined")]),
])

# ---------------------------------------------------------------------------- interfaces
case("interfaces", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
type
  IGreeter = interface
    ['{7A1C3D52-0B1E-4F0A-9C55-2D5B8E0F1A11}']
    function Greet(n: Integer): string;
  end;
  TGreeter = class(TInterfacedObject, IGreeter)
    function Greet(n: Integer): string;
    destructor Destroy; override;
  end;
var
  G: IGreeter;
function Tick(n: Integer): string;
implementation
uses SysUtils;
function TGreeter.Greet(n: Integer): string;
begin
  Result := 'hello ' + IntToStr(n);
end;
destructor TGreeter.Destroy;
begin
  WriteLn('  (a TGreeter was destroyed by version 1 code)');
  inherited;
end;
function Tick(n: Integer): string;
begin
  if G = nil then G := TGreeter.Create;
  Result := G.Greet(n);
end;
end.
'''}, [
    ("the body of a method called through an interface reference held since version 1", [("u.pas", "Result := 'hello ' + IntToStr(n);", "Result := 'HELLO ' + IntToStr(n * 10);")]),
    ("new code queries the old object for the interface (Supports) and drops the reference: the destructor runs",
     [("u.pas", "  if G = nil then G := TGreeter.Create;\n  Result := G.Greet(n);",
       "  if G = nil then G := TGreeter.Create;\n  Result := G.Greet(n) + ' supports: ' + BoolToStr(Supports(G, IGreeter), True);\n  if n mod 2 = 0 then G := nil;"),
      ("u.pas", "destroyed by version 1 code", "destroyed by version 3 code")]),
    ("the interface gains a method",
     [("u.pas", "    function Greet(n: Integer): string;\n  end;\n  TGreeter", "    function Greet(n: Integer): string;\n    function Bye: string;\n  end;\n  TGreeter"),
      ("u.pas", "    function Greet(n: Integer): string;\n    destructor", "    function Greet(n: Integer): string;\n    function Bye: string;\n    destructor"),
      ("u.pas", "destructor TGreeter.Destroy;", "function TGreeter.Bye: string;\nbegin\n  Result := 'bye';\nend;\ndestructor TGreeter.Destroy;")]),
])

# ---------------------------------------------------------------------------- exceptions
case("exceptions", {
    "main.pas": r'''program main;
{$mode objfpc}{$H+}
uses SysUtils, u;
var
  Count: Integer = 0;
begin
  while Count < StrToInt(ParamStr(1)) do
  begin
    Inc(Count);
    try
      WriteLn('tick ', Count, ': ', Tick(Count));
    except
      on E: EBoom do WriteLn('tick ', Count, ': main caught EBoom: ', E.Message);
      on E: EConvertError do WriteLn('tick ', Count, ': main caught EConvertError: ', E.Message);
      on E: Exception do WriteLn('tick ', Count, ': main caught ', E.ClassName, ': ', E.Message);
    end;
    Flush(Output);
    Sleep(300);
  end;
end.
''',
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
uses SysUtils;
type
  EBoom = class(Exception);
var
  Cleanups: Integer;
function Tick(n: Integer): string;
implementation
function Tick(n: Integer): string;
begin
  Result := 'quiet, cleanups ' + IntToStr(Cleanups);
end;
end.
'''}, [
    ("new code raises EBoom; the handler is in the old main block",
     [("u.pas", "  Result := 'quiet, cleanups ' + IntToStr(Cleanups);",
       "  Result := '';\n  try\n    if n mod 2 = 0 then raise EBoom.CreateFmt('boom at %d', [n]);\n    Result := 'no boom, cleanups ' + IntToStr(Cleanups);\n  finally\n    Inc(Cleanups);\n  end;")]),
    ("new code makes the runtime raise (StrToInt of a word), and catches EBoom itself",
     [("u.pas", "    if n mod 2 = 0 then raise EBoom.CreateFmt('boom at %d', [n]);",
       "    try\n      if n mod 2 = 0 then raise EBoom.CreateFmt('boom at %d', [n]);\n    except\n      on E: EBoom do Result := 'caught in the unit: ' + E.Message;\n    end;\n    if n mod 3 = 0 then Inc(Cleanups, StrToInt('three'));"),
      ("u.pas", "    Result := 'no boom, cleanups ' + IntToStr(Cleanups);", "    if Result = '' then Result := 'no boom, cleanups ' + IntToStr(Cleanups);")]),
])

# ---------------------------------------------------------------------------- threadvars
case("threadvars", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
threadvar
  Calls: Integer;
function Tick(n: Integer): string;
implementation
uses SysUtils;
function Tick(n: Integer): string;
begin
  Inc(Calls);
  Result := 'calls on this thread ' + IntToStr(Calls);
end;
end.
'''}, [
    ("another text; the thread variable is untouched", [("u.pas", "'calls on this thread '", "'CALLS ON THIS THREAD '")]),
    ("a second thread variable", [("u.pas", "  Calls: Integer;", "  Calls: Integer;\n  Other: Integer;"), ("u.pas", "  Inc(Calls);", "  Inc(Calls); Inc(Other);")]),
])

# ---------------------------------------------------------------------------- a thread that blocks signals
# Libraries start threads that block every signal, such as the workers of Mesa's software
# renderer. On Linux the agent stops threads with a signal, so it must not wait for these.
case("signals", {
    "main.pas": MAIN.replace("uses SysUtils, u;", "uses {$ifdef unix}cthreads,{$endif} SysUtils, u;"),
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses {$ifdef linux}BaseUnix,{$endif} Classes, SysUtils;
type
  TQuiet = class(TThread)
    procedure Execute; override;
  end;
var
  Quiet: TQuiet;
procedure TQuiet.Execute;
{$ifdef linux}
var
  All: TSigSet;
{$endif}
begin
  {$ifdef linux}
  FpSigFillSet(All);
  FpSigProcMask(SIG_BLOCK, @All, nil);
  {$endif}
  while not Terminated do Sleep(20);
end;
function Tick(n: Integer): string;
begin
  Result := 'text one';
end;
initialization
  Quiet := TQuiet.Create(False);
finalization
  Quiet.Terminate;
  Quiet.WaitFor;
  Quiet.Free;
end.
'''}, [
    ("another text, while a thread blocks every signal", [("u.pas", "'text one'", "'text two'")]),
])

# ---------------------------------------------------------------------------- initialization and finalization
case("initfinal", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
var
  Greeting: string;
function Tick(n: Integer): string;
implementation
function Tick(n: Integer): string;
begin
  Result := Greeting;
end;
initialization
  Greeting := 'set by initialization, version 1';
finalization
  WriteLn('finalization, version 1');
end.
'''}, [
    ("the initialization section assigns another text", [("u.pas", "set by initialization, version 1", "set by initialization, version 2")]),
    ("the finalization section prints another text", [("u.pas", "finalization, version 1", "finalization, version 3")]),
], 9)

# ---------------------------------------------------------------------------- generics
case("generics", {
    "main.pas": r'''program main;
{$mode objfpc}{$H+}
uses SysUtils, g, u;
type
  TStrBox = specialize TBox<string>;
var
  Count: Integer = 0;
  B: TStrBox;
begin
  B := TStrBox.Create;
  B.Value := 'text';
  while Count < StrToInt(ParamStr(1)) do
  begin
    Inc(Count);
    WriteLn('tick ', Count, ': ', Tick(Count), ' | main: ', B.Show);
    Flush(Output);
    Sleep(300);
  end;
end.
''',
    "g.pas": r'''unit g;
{$mode objfpc}{$H+}
interface
type
  generic TBox<T> = class
    Value: T;
    function Show: string;
  end;
implementation
uses SysUtils;
function TBox.Show: string;
begin
  Result := 'box of ' + IntToStr(SizeOf(T)) + ' bytes';
end;
end.
''',
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
uses g;
type
  TIntBox = specialize TBox<Integer>;
var
  Box: TIntBox;
function Tick(n: Integer): string;
implementation
function Tick(n: Integer): string;
begin
  if Box = nil then Box := TIntBox.Create;
  Box.Value := n;
  Result := 'unit: ' + Box.Show;
end;
end.
'''}, [
    ("the body of the generic method, instantiated in unit u and in the main program", [("g.pas", "'box of '", "'BOX OF '")]),
])

# ---------------------------------------------------------------------------- inline
case("inline", {
    "main.pas": r'''program main;
{$mode objfpc}{$H+}
uses SysUtils, u;
var
  Count: Integer = 0;
begin
  while Count < StrToInt(ParamStr(1)) do
  begin
    Inc(Count);
    WriteLn('tick ', Count, ': main inlines Scale = ', Scale(Count), ', ', Tick(Count));
    Flush(Output);
    Sleep(300);
  end;
end.
''',
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
function Scale(x: Integer): Integer; inline;
function Tick(n: Integer): string;
implementation
uses SysUtils;
function Scale(x: Integer): Integer; inline;
begin
  Result := x * 10;
end;
function Tick(n: Integer): string;
begin
  Result := 'Tick inlines Scale = ' + IntToStr(Scale(n));
end;
end.
'''}, [
    ("the body of an inline function that the running main block and Tick both inlined", [("u.pas", "Result := x * 10;", "Result := x * 1000;")]),
], None, ("-Si",))

# ---------------------------------------------------------------------------- signature
case("signature", {
    "main.pas": r'''program main;
{$mode objfpc}{$H+}
uses SysUtils, u;
var
  Count: Integer = 0;
begin
  while Count < StrToInt(ParamStr(1)) do
  begin
    Inc(Count);
    WriteLn('tick ', Count, ': main calls Area = ', Area(Count), ', ', Tick(Count));
    Flush(Output);
    Sleep(300);
  end;
end.
''',
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
function Area(w: Integer): Integer;
function Tick(n: Integer): string;
implementation
uses SysUtils;
function Area(w: Integer): Integer;
begin
  Result := w * w;
end;
function Tick(n: Integer): string;
begin
  Result := 'Tick calls Area = ' + IntToStr(Area(n));
end;
end.
'''}, [
    ("Area(w) becomes Area(w, h); Tick and the main block are edited to pass two arguments",
     [("u.pas", "function Area(w: Integer): Integer;\nfunction Tick", "function Area(w, h: Integer): Integer;\nfunction Tick"),
      ("u.pas", "function Area(w: Integer): Integer;\nbegin\n  Result := w * w;", "function Area(w, h: Integer): Integer;\nbegin\n  Result := w * h;"),
      ("u.pas", "IntToStr(Area(n))", "IntToStr(Area(n, 100))"),
      ("main.pas", "Area(Count), ', '", "Area(Count, 100), ', '")]),
])

# ---------------------------------------------------------------------------- procedure variables
case("procvars", {
    "main.pas": r'''program main;
{$mode objfpc}{$H+}
uses SysUtils, u;
var
  Count: Integer = 0;
  Plain: TPlain;
  Event: TEvent;
  Target: TTarget;
begin
  Plain := @OnPlain;
  Target := TTarget.Create;
  Event := @Target.OnEvent;
  while Count < StrToInt(ParamStr(1)) do
  begin
    Inc(Count);
    WriteLn('tick ', Count, ': ', Plain(Count), ', ', Event(Count), ', same address: ', Pointer(Plain) = Pointer(@OnPlain));
    Flush(Output);
    Sleep(300);
  end;
end.
''',
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
type
  TPlain = function(n: Integer): string;
  TEvent = function(n: Integer): string of object;
  TTarget = class
    function OnEvent(n: Integer): string;
  end;
function OnPlain(n: Integer): string;
implementation
uses SysUtils;
function OnPlain(n: Integer): string;
begin
  Result := 'plain v1 ' + IntToStr(n);
end;
function TTarget.OnEvent(n: Integer): string;
begin
  Result := 'method v1 ' + IntToStr(n);
end;
end.
'''}, [
    ("both bodies; the main block holds a procedure variable and a method pointer taken before the reload",
     [("u.pas", "'plain v1 '", "'PLAIN V2 '"), ("u.pas", "'method v1 '", "'METHOD V2 '")]),
])

# ---------------------------------------------------------------------------- records
case("records", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
type
  TPos = record
    x, y: Integer;
  end;
var
  P: TPos;
function Tick(n: Integer): string;
implementation
uses SysUtils;
function Tick(n: Integer): string;
begin
  Inc(P.x); Inc(P.y, 2);
  Result := Format('x %d y %d', [P.x, P.y]);
end;
end.
'''}, [
    ("y: Integer becomes y: Single (the record keeps its size)",
     [("u.pas", "    x, y: Integer;", "    x: Integer;\n    y: Single;"), ("u.pas", "Inc(P.y, 2);", "P.y := P.y + 2;"), ("u.pas", "Format('x %d y %d', [P.x, P.y])", "Format('x %d y %f', [P.x, P.y])")]),
    ("back, and the record gains a field",
     [("u.pas", "    x: Integer;\n    y: Single;", "    x, y, z: Integer;"), ("u.pas", "P.y := P.y + 2;", "Inc(P.y, 2);"), ("u.pas", "Format('x %d y %f', [P.x, P.y])", "Format('x %d y %d', [P.x, P.y])")]),
    ("back to the first layout, another text", [("u.pas", "    x, y, z: Integer;", "    x, y: Integer;"), ("u.pas", "'x %d y %d'", "'X %d Y %d'")]),
])

# ---------------------------------------------------------------------------- constants
# fpc puts floating point constants in the unit's data as numbered literals (_$U$_Ld1 with
# fpc 3.2, local .Ld1 labels with 3.3.1). New code needs its own copies: an edited value
# must show, and a new literal shifts the numbers of the ones after it.
case("constants", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
const
  Rate = 1.5;
  Scale = 0.25;
function Tick(n: Integer): string;
begin
  Result := Format('rate %.2f scale %.2f', [Rate, Scale]);
end;
end.
'''}, [
    ("Rate = 1.5 becomes Rate = 2.5", [("u.pas", "Rate = 1.5;", "Rate = 2.5;")]),
    ("a new constant Offset, used before the others",
     [("u.pas", "  Rate = 2.5;", "  Offset = 9.75;\n  Rate = 2.5;"),
      ("u.pas", "Format('rate %.2f scale %.2f', [Rate, Scale])", "Format('offset %.2f rate %.2f scale %.2f', [Offset, Rate, Scale])")]),
])

# ---------------------------------------------------------------------------- units the program does not contain
case("newunit", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
function Tick(n: Integer): string;
begin
  Result := 'n ' + IntToStr(n);
end;
end.
'''}, [
    ("uses Math, a unit of the runtime the program was not linked with",
     [("u.pas", "uses SysUtils;", "uses SysUtils, Math;"), ("u.pas", "'n ' + IntToStr(n)", "'n ' + IntToStr(n) + ' power ' + FloatToStr(Power(n, 2))")]),
    ("back; uses a new unit of the program's own",
     [("u.pas", "uses SysUtils, Math;", "uses SysUtils, extra;"), ("u.pas", "' power ' + FloatToStr(Power(n, 2))", "' extra ' + IntToStr(Extra1(n))"),
      ("extra.pas", None, "unit extra;\n{$mode objfpc}{$H+}\ninterface\nfunction Extra1(n: Integer): Integer;\nimplementation\nfunction Extra1(n: Integer): Integer;\nbegin\n  Result := n + 1;\nend;\nend.\n")]),
    ("back to what can be swapped: a function of SysUtils the program never called",
     [("u.pas", "uses SysUtils, extra;", "uses SysUtils;"), ("u.pas", "' extra ' + IntToStr(Extra1(n))", "' hex ' + IntToHex(n, 4) + ' ' + UpperCase(BoolToStr(Odd(n), True))")]),
])

# ---------------------------------------------------------------------------- two saves in quick succession
# A step whose description starts with "+" is saved 0.12 s after the step before it, while
# the tool is still busy with that one: the second compile then starts in the same second
# as the first, where the compiler's own check would miss the edit.
case("rapid", {
    "main.pas": MAIN,
    "u.pas": r"""unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
function Tick(n: Integer): string;
begin
  Result := 'text one ' + IntToStr(n);
end;
end.
"""}, [
    ("the text becomes 'text two'", [("u.pas", "'text one '", "'text two '")]),
    ("+the text becomes 'text three', saved 0.12 s later", [("u.pas", "'text two '", "'text three '")]),
    ("the text becomes 'text four'", [("u.pas", "'text three '", "'text four '")]),
    ("+the text becomes 'text five', saved 0.12 s later", [("u.pas", "'text four '", "'text five '")]),
])

# ---------------------------------------------------------------------------- include files
SHARED_INC = r'''const
  Prefix = 'one';
function Scale(n: Integer): Integer;
begin
  Result := n * 2;
end;
'''

case("include", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils, v;
{$I shared.inc}
var
  Hits: Integer = 0;
function Tick(n: Integer): string;
begin
  Inc(Hits);
  Result := Format('%s hits %d scaled %s', [Prefix, Hits, VText(n)]);
end;
end.
''',
    "v.pas": r'''unit v;
{$mode objfpc}{$H+}
interface
function VText(n: Integer): string;
implementation
uses SysUtils;
{$I shared.inc}
function VText(n: Integer): string;
begin
  Result := Prefix + '/' + IntToStr(Scale(n));
end;
end.
''',
    "shared.inc": SHARED_INC}, [
    ("shared.inc (included by u and v): the body of Scale",
     [("shared.inc", "Result := n * 2;", "Result := n * 10;")]),
    ("shared.inc: the constant Prefix",
     [("shared.inc", "Prefix = 'one';", "Prefix = 'two';")]),
])

# ---------------------------------------------------------------------------- a unit renamed
U_RENAMED = r'''{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
var
  Calls: Integer = 0;
function Tick(n: Integer): string;
begin
  Inc(Calls);
  Result := Format('first text, calls %d', [Calls]);
end;
end.
'''

case("rename", {
    "main.pas": MAIN,
    "u.pas": "unit u;\n" + U_RENAMED}, [
    ("u.pas becomes w.pas (unit w), and main uses w",
     [("w.pas", None, "unit w;\n" + U_RENAMED), ("main.pas", "uses SysUtils, u;", "uses SysUtils, w;"), ("u.pas", None, None)]),
    ("back to u.pas (unit u), with another text",
     [("u.pas", None, "unit u;\n" + U_RENAMED.replace("first text", "second text")), ("main.pas", "uses SysUtils, w;", "uses SysUtils, u;"), ("w.pas", None, None)]),
])

# ---------------------------------------------------------------------------- what the rule cannot see
case("limits", {
    "main.pas": MAIN,
    "u.pas": r"""unit u;
{$mode objfpc}{$H+}
interface
type
  TPair = class
    First: Integer;
    Second: Integer;
  end;
var
  Pair: TPair;
function Tick(n: Integer): string;
implementation
uses SysUtils;
type
  THidden = class
    A: Integer;
    B: Integer;
  end;
var
  Calls: Integer;
  H: THidden;
function Tick(n: Integer): string;
begin
  if Pair = nil then begin Pair := TPair.Create; Pair.First := 1; Pair.Second := 1000; H := THidden.Create; H.A := 1; H.B := 1000; end;
  Inc(Pair.First); Inc(H.A);
  Inc(Calls);
  Result := Format('pair %d/%d hidden %d/%d calls %d', [Pair.First, Pair.Second, H.A, H.B, Calls]);
end;
end.
"""}, [
    ("two fields of a class in the interface section swap places (same instance size)",
     [("u.pas", "    First: Integer;\n    Second: Integer;", "    Second: Integer;\n    First: Integer;")]),
    ("undone; two fields of a class in the implementation section swap places",
     [("u.pas", "    Second: Integer;\n    First: Integer;", "    First: Integer;\n    Second: Integer;"), ("u.pas", "    A: Integer;\n    B: Integer;", "    B: Integer;\n    A: Integer;")]),
    ("Calls: Integer in the implementation section becomes Calls: Single (same size)",
     [("u.pas", "  Calls: Integer;", "  Calls: Single;"), ("u.pas", "  Inc(Calls);", "  Calls := Calls + 1;"), ("u.pas", "calls %d'", "calls %g'")]),
])

# ---------------------------------------------------------------------------- restarts
# One unit whose text and call count the program prints. A restart starts the count over.
U_COUNTED = r'''unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
var
  Calls: Integer = 0;
function Tick(n: Integer): string;
begin
  Inc(Calls);
  Result := Format('one calls %d', [Calls]);
end;
end.
'''

case("restart", {"main.pas": MAIN, "u.pas": U_COUNTED}, [
    ("another text", [("u.pas", "'one calls", "'two calls")]),
    ("Calls: Integer becomes Calls: Int64, and another text: the program starts over",
     [("u.pas", "Calls: Integer = 0;", "Calls: Int64 = 0;"), ("u.pas", "'two calls", "'three calls")]),
    ("another text, swapped into the restarted program", [("u.pas", "'three calls", "'four calls")]),
], restart=True)

# a routine no library has: the compile works, the link does not
V_MISSING = r'''unit v;
{$mode objfpc}{$H+}
interface
function Extra: Integer;
implementation
procedure Missing; external name 'hotfpc_missing';
function Extra: Integer;
begin
  Missing;
  Result := 1;
end;
end.
'''

case("linkfail", {"main.pas": MAIN, "u.pas": U_COUNTED}, [
    ("another text", [("u.pas", "'one calls", "'two calls")]),
    ("u uses a new unit whose code calls a routine no library has: the restart does not link, and the program carries on",
     [("v.pas", None, V_MISSING), ("u.pas", "uses SysUtils;", "uses SysUtils, v;"),
      ("u.pas", "Format('two calls %d', [Calls])", "Format('three calls %d extra %d', [Calls, Extra])")]),
    ("the new unit no longer calls it: the program starts over", [("v.pas", "  Missing;\n", "")]),
    ("another text, swapped into the restarted program", [("u.pas", "'three calls", "'four calls")]),
], restart=True)

case("crash", {"main.pas": MAIN, "u.pas": U_COUNTED}, [
    ("Calls becomes Int64, and u's initialization ends the program with exit code 3: the restarted program fails",
     [("u.pas", "Calls: Integer = 0;", "Calls: Int64 = 0;"), ("u.pas", "'one calls", "'two calls"),
      ("u.pas", "\nend.", "\ninitialization\n  Halt(3);\nend.")]),
    ("the initialization no longer ends it: the next save starts the program again",
     [("u.pas", "initialization\n  Halt(3);\n", ""), ("u.pas", "'two calls", "'three calls")]),
], restart=True)


def run(name):
    files, steps, ticks, opts = CASES[name]
    work = os.path.join(HERE, "work", name)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    for f, text in files.items():
        with open(os.path.join(work, f), "w") as fh:
            fh.write(text)
    n = ticks or (len(steps) + 1) * 4 + 1
    t0 = time.time()
    lock = threading.Lock()

    def out(line):
        with lock:
            print("%6.2fs  %s" % (time.time() - t0, line), flush=True)

    print("=== %s" % name, flush=True)
    p = subprocess.Popen(driver_cmd() + list(opts) + [os.path.join(work, "main.pas"), "--", str(n)],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

    started = threading.Event()

    def pump():
        for line in p.stdout:
            if "] v1: built" in line:
                started.set()
            out(line.rstrip("\n"))
        started.set()
    th = threading.Thread(target=pump)
    th.start()
    # Wait until the driver watches the files and the program runs: the steps must not depend
    # on how long the build or the start took. (Waiting for the build's object file was not
    # enough: under load a new executable took up to 9 s to start, and early saves merged.)
    started.wait()
    time.sleep(0.9)
    for i, (desc, edits) in enumerate(steps):
        # a "+" marks a step that follows the one before it after 0.12 s instead of 1.2 s
        quick_next = i + 1 < len(steps) and steps[i + 1][0].startswith("+")
        out("--- the script saves: " + desc.lstrip("+"))
        texts = {}
        for f, old, new in edits:
            path = os.path.join(work, f)
            if old is None:
                texts[path] = new
                continue
            if path not in texts:
                with open(path) as fh:
                    texts[path] = fh.read()
            if old not in texts[path]:
                out("!!! the edit does not apply: %r" % old)
            texts[path] = texts[path].replace(old, new)
        for path, text in texts.items():
            if text is None:   # (file, None, None): the file goes away
                if os.path.exists(path):
                    os.remove(path)
                continue
            with open(path, "w") as fh:
                fh.write(text)
        time.sleep(0.12 if quick_next else 1.2)
    p.wait()
    th.join()
    print(flush=True)


if __name__ == "__main__":
    names = sys.argv[1:] or list(CASES)
    for n in names:
        run(n)
