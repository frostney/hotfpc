#!/usr/bin/env python3
"""State across a reload: one program per case, and the edits saved into it while it runs.

  scenario.py                 run every case
  scenario.py classes heap    run the named cases
"""
import os, platform, shlex, re, shutil, subprocess, sys, threading, time

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
  while (Count < StrToInt(ParamStr(1))) and not FileExists(ParamStr(2)) do
  begin
    Inc(Count);
    WriteLn('tick ', Count, ': ', Tick(Count));
    Flush(Output);
    Sleep(300);
  end;
end.
'''

CASES = {}
# An edit (path, None, BLOCKED) puts a directory where the driver writes a file, such as the
# compile to assembler's .hot/asm/main.s, so that fpc cannot write it; (path, None, None)
# removes it again.
BLOCKED = object()


# A step's files after the first are written once the driver has started to compile the first:
# it then removes the compiler's record of that unit, .hot/units/<unit>.ppu
WHILE_COMPILING = "while compiling"
# A step whose first file is emptied first, as by an editor that empties a file before it
# writes it: the step's other files are written 0.1 s later, and the first file's text 0.3 s
# after it was emptied
EMPTIED_FIRST = "emptied first"
# A step saved while the driver builds the program to start it: once fpc has written the
# program's object file, .hot/units/main.o, so fpc has read main.pas and is linking. It comes
# first, and has no outcome of its own: the program starts with it. A second such step waits
# for the main.o of the next build, which the save before makes the driver do: one newer
# than the program the build before linked after the main.o it waited for. Such a step may
# also be EMPTIED_FIRST: (description, edits, AT_START, EMPTIED_FIRST).
AT_START = "at the start"


def case(name, files, steps, opts=(), restart=False, env=None):
    """steps: (description, edits) or (description, edits, WHILE_COMPILING, EMPTIED_FIRST or AT_START), or
    (description, edits, AT_START, EMPTIED_FIRST). restart: the driver
    starts the program over when an edit needs a restart; the other cases pass --no-restart, so
    that the program they check keeps running. env: variables to add to the driver's
    environment, which the program inherits, such as one of the agent's test variables."""
    CASES[name] = (files, steps, tuple(opts) + (() if restart else ("--no-restart",)), dict(env or {}))


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
  while (Count < StrToInt(ParamStr(1))) and not FileExists(ParamStr(2)) do
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
var
  Speed: Integer = 5;
function Tick(n: Integer): string;
begin
  Result := Format('text one speed %d', [Speed]);
end;
initialization
  Quiet := TQuiet.Create(False);
finalization
  Quiet.Terminate;
  Quiet.WaitFor;
  Quiet.Free;
end.
'''}, [
    ("another text, and Speed = 5 becomes Speed = 50, while a thread blocks every signal",
     [("u.pas", "'text one speed", "'text two speed"), ("u.pas", "Speed: Integer = 5;", "Speed: Integer = 50;")]),
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
])

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
  while (Count < StrToInt(ParamStr(1))) and not FileExists(ParamStr(2)) do
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
  while (Count < StrToInt(ParamStr(1))) and not FileExists(ParamStr(2)) do
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
], ("-Si",))

# ---------------------------------------------------------------------------- signature
SIGNATURE = {
    "main.pas": r'''program main;
{$mode objfpc}{$H+}
uses SysUtils, u;
var
  Count: Integer = 0;
begin
  while (Count < StrToInt(ParamStr(1))) and not FileExists(ParamStr(2)) do
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
'''}
# Area's signature and both callers; u.pas alone does not compile
SIGNATURE_EDITS = [
    ("u.pas", "function Area(w: Integer): Integer;\nfunction Tick", "function Area(w, h: Integer): Integer;\nfunction Tick"),
    ("u.pas", "function Area(w: Integer): Integer;\nbegin\n  Result := w * w;", "function Area(w, h: Integer): Integer;\nbegin\n  Result := w * h;"),
    ("u.pas", "IntToStr(Area(n))", "IntToStr(Area(n, 100))"),
    ("main.pas", "Area(Count), ', '", "Area(Count, 100), ', '")]

case("signature", SIGNATURE, [
    ("Area(w) becomes Area(w, h); Tick and the main block are edited to pass two arguments", SIGNATURE_EDITS),
])

# ---------------------------------------------------------------------------- a save that takes a moment
# An editor or a tool may write the files of one save further apart than hotfpc waits for a
# save to settle. Here main.pas is written once hotfpc has started to compile u.pas alone, so
# fpc reads main.pas before or after its change: the tool must compile again once the sources
# settle, not report or swap what that compile made. u.pas includes 5000 functions nothing
# calls, so that compile lasts a while on a fast machine too.
SLOWSAVE = dict(SIGNATURE)
SLOWSAVE["u.pas"] = SIGNATURE["u.pas"].replace("implementation\nuses SysUtils;\n", "implementation\nuses SysUtils;\n{$I bulk.inc}\n")
SLOWSAVE["bulk.inc"] = "".join("function Bulk%d(x: Integer): Integer; begin Result := x * %d + %d; end;\n" % (i, i % 7 + 1, i)
                               for i in range(5000))
case("slowsave", SLOWSAVE, [
    ("the same edit, with main.pas written while hotfpc compiles u.pas", SIGNATURE_EDITS, WHILE_COMPILING),
])

# ---------------------------------------------------------------------------- procedure variables
case("procvars", {
    "main.pas": r'''program main;
{$mode objfpc}{$H+}
uses SysUtils, u;
var
  Count: Integer = 0;
  Plain, Hidden: TPlain;
  Event: TEvent;
  Target: TTarget;
begin
  Plain := @OnPlain;
  Hidden := HiddenRoutine;
  Target := TTarget.Create;
  Event := @Target.OnEvent;
  while (Count < StrToInt(ParamStr(1))) and not FileExists(ParamStr(2)) do
  begin
    Inc(Count);
    WriteLn('tick ', Count, ': ', Plain(Count), ', ', Event(Count), ', ', Hidden(Count),
      ', same address: ', Pointer(Plain) = Pointer(@OnPlain), ' ', Pointer(Hidden) = Pointer(HiddenRoutine));
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
function HiddenRoutine: TPlain;
implementation
uses SysUtils;
function OnPlain(n: Integer): string;
begin
  Result := 'plain v1 ' + IntToStr(n);
end;
// declared only here: fpc 3.2 gives it no symbol in a Windows object file
function OnHidden(n: Integer): string;
begin
  Result := 'hidden v1 ' + IntToStr(n);
end;
function HiddenRoutine: TPlain;
begin
  Result := @OnHidden;
end;
function TTarget.OnEvent(n: Integer): string;
begin
  Result := 'method v1 ' + IntToStr(n);
end;
end.
'''}, [
    ("three bodies; the main block holds procedure variables and a method pointer taken before the reload, one of a routine of the implementation section",
     [("u.pas", "'plain v1 '", "'PLAIN V2 '"), ("u.pas", "'method v1 '", "'METHOD V2 '"), ("u.pas", "'hidden v1 '", "'HIDDEN V2 '")]),
    ("the routine of the implementation section is declared in the interface too, with another body",
     [("u.pas", "function HiddenRoutine: TPlain;\nimplementation", "function HiddenRoutine: TPlain;\nfunction OnHidden(n: Integer): string;\nimplementation"),
      ("u.pas", "'HIDDEN V2 '", "'HIDDEN V3 '")]),
    ("its declaration in the interface is removed again, with another body",
     [("u.pas", "function HiddenRoutine: TPlain;\nfunction OnHidden(n: Integer): string;\nimplementation", "function HiddenRoutine: TPlain;\nimplementation"),
      ("u.pas", "'HIDDEN V3 '", "'HIDDEN V4 '")]),
])

# ---------------------------------------------------------------------------- a nested routine of a running frame
# Run's frame runs across the swap, and calls its nested Show, which reads Run's locals. The
# save puts locals around them, so the new Show would read the old frame in the wrong
# places: the old frame must keep the old Show. The save also gives Done the initial value
# True, which the swap applies: the old frame, which sees Done only after the swap, sets
# Text to 'last', shows once more and returns, and the main block then calls the new Run,
# whose fresh frame calls the new Show. The main block keeps running across the swap too,
# and ends with its old frame's finally.
case("nestedframe", {
    "main.pas": r"""program main;
{$mode objfpc}{$H+}
uses SysUtils, u;
begin
  while (Ticks < StrToInt(ParamStr(1))) and not FileExists(ParamStr(2)) do Run(ParamStr(2));
end.
""",
    "u.pas": r"""unit u;
{$mode objfpc}{$H+}
interface
var
  Ticks: Integer;
  Done: Boolean = False;
procedure Run(const AStop: string);
implementation
uses SysUtils;
procedure Run(const AStop: string);
var
  Base: Integer;
  Text: string;
  procedure Show;
  begin
    WriteLn('tick ', Ticks, ': ', Text, ' ', Base, ' v1');
    Flush(Output);
  end;
begin
  Base := 42; Text := 'base';
  while not FileExists(AStop) do
  begin
    Sleep(300);
    if Done then Break;
    Inc(Ticks); Show;
  end;
  if Done then
  begin
    Text := 'last';
    Inc(Ticks); Show;
  end;
end;
end.
"""}, [
    ("locals around Run's, another text for Show, Done becomes True, and managed temporaries in the main block, while Run's frame and the main block keep running",
     [("u.pas", "var\n  Base: Integer;\n  Text: string;", "var\n  Before: array[0..31] of Integer;\n  Base: Integer;\n  Text: string;\n  After: array[0..31] of Integer;"),
      ("u.pas", "' v1'", "' v2'"),
      ("u.pas", "Done: Boolean = False;", "Done: Boolean = True;"),
      ("u.pas", "    if Done then Break;\n    Inc(Ticks); Show;\n  end;\n  if Done then\n  begin\n    Text := 'last';\n    Inc(Ticks); Show;\n  end;", "    Inc(Ticks);\n    if Done then Show;\n  end;"),
      ("main.pas", "begin\n  while", "begin\n  if ParamStr(3) <> '' then WriteLn('more ' + IntToStr(Length(ParamStr(0))) + ' ' + ParamStr(1) + ' ' + ParamStr(2));\n  while")]),
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
    "shared.inc": SHARED_INC,
    # an empty include file nothing uses: an empty file that no save changed holds no save back
    "unused.inc": ""}, [
    ("shared.inc (included by u and v): the body of Scale",
     [("shared.inc", "Result := n * 2;", "Result := n * 10;")]),
    ("shared.inc: the constant Prefix",
     [("shared.inc", "Prefix = 'one';", "Prefix = 'two';")]),
    # u.pas is saved while v.pas is still empty: the save waits for v.pas, and is compiled
    # once, with both
    ("v.pas and u.pas: other texts, v.pas emptied first and written 0.3 s later",
     [("v.pas", "Prefix + '/'", "Prefix + ':'"), ("u.pas", "hits %d", "HITS %d")], EMPTIED_FIRST),
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

# ---------------------------------------------------------------------------- the implementation section
# ppudump's JSON describes only the interface; the implementation section's declarations come
# from its text
case("hidden", {
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
    ("undone; Calls: Integer in the implementation section becomes Calls: Single (same size)",
     [("u.pas", "    B: Integer;\n    A: Integer;", "    A: Integer;\n    B: Integer;"),
      ("u.pas", "  Calls: Integer;", "  Calls: Single;"), ("u.pas", "  Inc(Calls);", "  Calls := Calls + 1;"), ("u.pas", "calls %d'", "calls %g'")]),
    ("undone, with another text",
     [("u.pas", "  Calls: Single;", "  Calls: Integer;"), ("u.pas", "  Calls := Calls + 1;", "  Inc(Calls);"), ("u.pas", "calls %g'", "calls %d'"),
      ("u.pas", "'pair %d", "'PAIR %d")]),
])

# ---------------------------------------------------------------------------- a variable with an initial value
# fpc gives it a section of its own, padded to 16 bytes, so the object file's section looks the
# same when it grows: the size ELF states for the symbol shows it, and on Windows, where COFF
# states none, the unit file and fpc's assembler output
case("initvar", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
var
  Calls: Integer = 0;
  Next: Integer = 100;
function Tick(n: Integer): string;
begin
  Inc(Calls);
  Inc(Next);
  Result := Format('one calls %d next %d', [Calls, Next]);
end;
end.
'''}, [
    ("another text", [("u.pas", "'one calls", "'two calls")]),
    ("Calls: Integer = 0 becomes Calls: Int64 = 0", [("u.pas", "Calls: Integer = 0;", "Calls: Int64 = 0;")]),
])

# ---------------------------------------------------------------------------- an initial value written during the load
# HOT_TEST_DATA_WRITE writes each variable whose initial value a save changes after the agent
# binds the save and before the commit, as a thread of the program could while the swap loads:
# the commit finds it written, so it keeps the value the program has, and the note says so.
# Speed fits in one aligned word, which the commit compares and writes in one step; Pair, of 16
# bytes, it compares and copies when every other thread is stopped, and keeps as it is when
# one isn't (on Linux, a thread that blocks the agent's signal and sleeps).
case("initrace", {
    "main.pas": MAIN,
    "u.pas": r"""unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
type
  TPair = record A, B: Int64; end;
var
  Speed: Integer = 5;
  Pair: TPair = (A: 1; B: 2);
function Tick(n: Integer): string;
begin
  Result := Format('speed %d pair %d %d', [Speed, Pair.A, Pair.B]);
end;
end.
"""}, [
    ("Speed = 5 becomes Speed = 50 and Pair = (1, 2) becomes (10, 20), and both are written during the load",
     [("u.pas", "Speed: Integer = 5;", "Speed: Integer = 50;"), ("u.pas", "Pair: TPair = (A: 1; B: 2);", "Pair: TPair = (A: 10; B: 20);")]),
], env={"HOT_TEST_DATA_WRITE": "1"})

# ---------------------------------------------------------------------------- a typed constant
# like a variable with an initial value, but fpc 3.2 leaves an implementation section's typed
# constant out of the unit file
case("typedconst", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}{$J+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
const
  Calls: Integer = 0;
function Tick(n: Integer): string;
begin
  Inc(Calls);
  Result := Format('one calls %d', [Calls]);
end;
end.
'''}, [
    ("another text", [("u.pas", "'one calls", "'two calls")]),
    ("Calls: Integer = 0 becomes Calls: Int64 = 0", [("u.pas", "Calls: Integer = 0;", "Calls: Int64 = 0;")]),
])

# ---------------------------------------------------------------------------- a variable of the program
# like initvar, but in the program file, for which fpc writes no unit file. The second save
# lands while fpc cannot write the program's assembler: on Windows its sizes are then unknown,
# so it needs a restart, and the running program's sizes stay what they were for the third
PROGVAR_MAIN = r'''program main;
{$mode objfpc}{$H+}
uses SysUtils, u;
var
  Count: Integer = 0;
  Calls: Integer = 0;
function Line(n: Integer): string;
begin
  Inc(Calls);
  Result := Tick(n) + Format(' main one %d', [Calls]);
end;
begin
  while (Count < StrToInt(ParamStr(1))) and not FileExists(ParamStr(2)) do
  begin
    Inc(Count);
    WriteLn('tick ', Count, ': ', Line(Count));
    Flush(Output);
    Sleep(300);
  end;
end.
'''

PROGVAR_U = r'''unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
function Tick(n: Integer): string;
begin
  Result := Format('n %d', [n]);
end;
end.
'''

case("progvar", {
    "main.pas": PROGVAR_MAIN,
    "u.pas": PROGVAR_U}, [
    ("another text", [("main.pas", "' main one", "' main two")]),
    ("another text, while fpc cannot write the program's assembler",
     [(".hot/asm/main.s", None, BLOCKED), ("main.pas", "' main two", "' main three")]),
    ("Calls: Integer = 0 in the program becomes Calls: Int64 = 0",
     [(".hot/asm/main.s", None, None), ("main.pas", "  Calls: Integer = 0;", "  Calls: Int64 = 0;")]),
])

# ---------------------------------------------------------------------------- a variable removed and added again
# progvar's program. A save removes Calls and the next brings it back as an Int64: the agent
# keeps a variable at its first address, also when a save removed it, so the variable that
# comes back larger needs a restart, though the version of main before it has no Calls. Back
# as an Integer, it is swapped and counts on from the value it had
case("readdvar", {
    "main.pas": PROGVAR_MAIN,
    "u.pas": PROGVAR_U}, [
    ("Calls and its uses are removed",
     [("main.pas", "  Calls: Integer = 0;\n", ""), ("main.pas", "  Inc(Calls);\n", ""),
      ("main.pas", "Format(' main one %d', [Calls])", "' main two'")]),
    ("Calls comes back as Calls: Int64 = 0, with its uses",
     [("main.pas", "  Count: Integer = 0;\n", "  Count: Integer = 0;\n  Calls: Int64 = 0;\n"),
      ("main.pas", "begin\n  Result := Tick(n)", "begin\n  Inc(Calls);\n  Result := Tick(n)"),
      ("main.pas", "' main two'", "Format(' main three %d', [Calls])")]),
    ("Calls: Int64 = 0 becomes Calls: Integer = 0, its first type", [("main.pas", "  Calls: Int64 = 0;", "  Calls: Integer = 0;")]),
])

# ---------------------------------------------------------------------------- a unit's variables removed and added again
# like readdvar, in a unit: a save removes a variable of its interface and one of its
# implementation section, and the next brings both back as a Single, of the same size. The
# check of layouts keeps the type each had, so they need a restart; back as an Integer, they
# are swapped
case("readdtype", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
var
  Hits: Integer;
function Tick(n: Integer): string;
implementation
uses SysUtils;
var
  Calls: Integer;
function Tick(n: Integer): string;
begin
  Inc(Calls);
  Inc(Hits);
  Result := Format('one calls %d hits %d', [Calls, Hits]);
end;
end.
'''}, [
    ("Hits, Calls and their uses are removed",
     [("u.pas", "var\n  Hits: Integer;\n", ""), ("u.pas", "var\n  Calls: Integer;\n", ""),
      ("u.pas", "  Inc(Calls);\n  Inc(Hits);\n", ""), ("u.pas", "Format('one calls %d hits %d', [Calls, Hits])", "'two'")]),
    ("Hits and Calls come back as Single, with their uses",
     [("u.pas", "interface\n", "interface\nvar\n  Hits: Single;\n"), ("u.pas", "uses SysUtils;\n", "uses SysUtils;\nvar\n  Calls: Single;\n"),
      ("u.pas", "begin\n  Result", "begin\n  Calls := Calls + 1;\n  Hits := Hits + 1;\n  Result"),
      ("u.pas", "'two'", "Format('three calls %g hits %g', [Calls, Hits])")]),
    ("Hits and Calls become Integer, their first type",
     [("u.pas", "Hits: Single;", "Hits: Integer;"), ("u.pas", "Calls: Single;", "Calls: Integer;"),
      ("u.pas", "Format('three calls %g hits %g', [Calls, Hits])", "Format('four calls %d hits %d', [Calls, Hits])")]),
])

# ---------------------------------------------------------------------------- a save during the start
# progvar's program; the first save lands while the driver builds the program to start it, after
# fpc has read main.pas. The program must start from what was saved, and on Windows its sizes
# must come from the same sources, so that the save after it swaps
case("startsave", {
    "main.pas": PROGVAR_MAIN,
    "u.pas": PROGVAR_U}, [
    ("Calls: Integer = 0 becomes Calls: Int64 = 0, and another text, while hotfpc builds the program to start it",
     [("main.pas", "  Calls: Integer = 0;", "  Calls: Int64 = 0;"), ("main.pas", "' main one", "' main two")], AT_START),
    ("another text", [("main.pas", "' main two", "' main three")]),
])

# ---------------------------------------------------------------------------- a start whose compile to assembler fails
# progvar's program. A save lands during the first build while .hot/asm/main.s is a directory,
# so fpc cannot write the program's assembler; the next save, during the build that follows,
# lets it again. Only the build the program starts from decides: on Windows the check of
# sizes stays on, and the variable that grows needs a restart
case("startblock", {
    "main.pas": PROGVAR_MAIN,
    "u.pas": PROGVAR_U}, [
    ("another text, while hotfpc builds the program to start it and fpc cannot write its assembler",
     [(".hot/asm/main.s", None, BLOCKED), ("main.pas", "' main one", "' main two")], AT_START),
    ("another text, while hotfpc builds the program again and fpc can write its assembler",
     [(".hot/asm/main.s", None, None), ("main.pas", "' main two", "' main three")], AT_START),
    ("Calls: Integer = 0 becomes Calls: Int64 = 0", [("main.pas", "  Calls: Integer = 0;", "  Calls: Int64 = 0;")]),
])

# ---------------------------------------------------------------------------- saves during four builds at the start
# progvar's program. A save lands during each of the first four builds, so the fourth is used
# as it is: the program runs the third save, while the fourth, which grows Calls, may be what
# its compile to assembler read. On Windows the program's sizes are then unknown, and every
# save that needs them, such as the fourth once the program runs, needs a restart
case("startcap", {
    "main.pas": PROGVAR_MAIN,
    "u.pas": PROGVAR_U}, [
    ("another text, while hotfpc builds the program to start it",
     [("main.pas", "' main one", "' main two")], AT_START),
    ("another text, while hotfpc builds it again", [("main.pas", "' main two", "' main three")], AT_START),
    ("another text, while hotfpc builds it a third time", [("main.pas", "' main three", "' main four")], AT_START),
    ("Calls: Integer = 0 becomes Calls: Int64 = 0, while hotfpc builds it a fourth time and uses that build",
     [("main.pas", "  Calls: Integer = 0;", "  Calls: Int64 = 0;")], AT_START),
    ("another text", [("main.pas", "' main four", "' main five")]),
])

# ---------------------------------------------------------------------------- the build the program starts from without assembler
# startcap's saves, but fpc cannot write the program's assembler for the fourth build, the one
# the program starts from, used as it is. On Windows the program's sizes are then unknown, and
# the check stays on: every save that needs them, such as the fourth once the program runs,
# needs a restart
case("startnoasm", {
    "main.pas": PROGVAR_MAIN,
    "u.pas": PROGVAR_U}, [
    ("another text, while hotfpc builds the program to start it",
     [("main.pas", "' main one", "' main two")], AT_START),
    ("another text, while hotfpc builds it again", [("main.pas", "' main two", "' main three")], AT_START),
    ("another text, while hotfpc builds it a third time", [("main.pas", "' main three", "' main four")], AT_START),
    ("Calls: Integer = 0 becomes Calls: Int64 = 0, while hotfpc builds it a fourth time, uses that build and fpc cannot write its assembler",
     [(".hot/asm/main.s", None, BLOCKED), ("main.pas", "  Calls: Integer = 0;", "  Calls: Int64 = 0;")], AT_START),
    ("another text, while fpc can write the program's assembler again",
     [(".hot/asm/main.s", None, None), ("main.pas", "' main four", "' main five")]),
])

# ---------------------------------------------------------------------------- a file emptied during the start
# progvar's program; a save during the first build empties main.pas and writes it 0.3 s later,
# as an editor that empties a file before it writes it. The build after it waits for the file
# as a save does once the program runs, and the program starts with the saved text
case("startempty", {
    "main.pas": PROGVAR_MAIN,
    "u.pas": PROGVAR_U}, [
    ("another text, emptied first, while hotfpc builds the program to start it",
     [("main.pas", "' main one", "' main two")], AT_START, EMPTIED_FIRST),
    ("another text", [("main.pas", "' main two", "' main three")]),
])

# ---------------------------------------------------------------------------- a unit left out during the start
# progvar's program, which also uses w, a unit with an initialization section. A save during
# the first build leaves w out, so the program starts without it: when main uses it again, w
# is a unit the running program does not have, and its initialization has never run
W_STARTED = r'''unit w;
{$mode objfpc}{$H+}
interface
var
  Started: Integer;
function WText: string;
implementation
uses SysUtils;
function WText: string;
begin
  Result := Format(' w started %d', [Started]);
end;
initialization
  Started := 42;
end.
'''

case("startunit", {
    "main.pas": PROGVAR_MAIN.replace("uses SysUtils, u;", "uses SysUtils, u, w;"),
    "u.pas": PROGVAR_U,
    "w.pas": W_STARTED}, [
    ("main no longer uses w, while hotfpc builds the program to start it",
     [("main.pas", "uses SysUtils, u, w;", "uses SysUtils, u;")], AT_START),
    ("main uses w again and prints what w's initialization set",
     [("main.pas", "uses SysUtils, u;", "uses SysUtils, u, w;"),
      ("main.pas", "Format(' main one %d', [Calls])", "Format(' main one %d', [Calls]) + WText")]),
])

# ---------------------------------------------------------------------------- a new unit's typed constant
# The program has no variable with an initial value of its own until u uses a new unit, w,
# which has a typed constant: the restart that adds w must take its size, so that the save
# that grows it starts the program over again
NEWCONST_MAIN = r'''program main;
{$mode objfpc}{$H+}
uses SysUtils, u;
var
  Count: Integer;
begin
  Count := 0;
  while (Count < StrToInt(ParamStr(1))) and not FileExists(ParamStr(2)) do
  begin
    Inc(Count);
    WriteLn('tick ', Count, ': ', Tick(Count));
    Flush(Output);
    Sleep(300);
  end;
end.
'''

W_LIMIT = r'''unit w;
{$mode objfpc}{$H+}
interface
function WText: string;
implementation
uses SysUtils;
const
  Limit: Integer = 7;
function WText: string;
begin
  Result := Format(' limit %d', [Limit]);
end;
end.
'''

case("newconst", {"main.pas": NEWCONST_MAIN, "u.pas": PROGVAR_U}, [
    ("u uses a new unit, w, with the typed constant Limit: Integer = 7: the program starts over",
     [("w.pas", None, W_LIMIT), ("u.pas", "uses SysUtils;", "uses SysUtils, w;"),
      ("u.pas", "Format('n %d', [n])", "Format('n %d', [n]) + WText")]),
    ("Limit: Integer = 7 becomes Limit: Int64 = 8: the program starts over again",
     [("w.pas", "Limit: Integer = 7;", "Limit: Int64 = 8;")]),
], restart=True)

# ---------------------------------------------------------------------------- a routine's typed constant
# like typedconst, but declared in a routine, which no unit file has with any fpc
case("localconst", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}{$J+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
function Tick(n: Integer): string;
const
  Calls: Integer = 0;
begin
  Inc(Calls);
  Result := Format('one calls %d', [Calls]);
end;
end.
'''}, [
    ("another text", [("u.pas", "'one calls", "'two calls")]),
    ("Calls: Integer = 0 in Tick becomes Calls: Int64 = 0", [("u.pas", "Calls: Integer = 0;", "Calls: Int64 = 0;")]),
])

# ---------------------------------------------------------------------------- a variable that grows inside its alignment padding
# Small (a Word) and Flag (a Byte) are each followed by an Int64, which starts at the next
# multiple of 8, so a Mach-O object (macOS), which states no symbol sizes, has 8 bytes from each
# to the next symbol before and after they grow. Each grows, and needs a restart; a new Byte
# after Flag, which leaves every variable its size, is swapped. Then a save removes Small and
# the next brings it back larger: the agent keeps it at its first address, with its first size
PADVAR_MAIN = r"""program main;
{$mode objfpc}{$H+}
uses SysUtils, u;
var
  Count: Integer = 0;
  Small: Word = 1;
  Big: Int64 = 2;
  Flag: Byte;
  Wide: Int64;
function Line(n: Integer): string;
begin
  Inc(Small);
  Inc(Flag);
  Inc(Wide);
  Result := Tick(n) + Format(' main one %d %d %d %d', [Small, Big, Flag, Wide]);
end;
begin
  while (Count < StrToInt(ParamStr(1))) and not FileExists(ParamStr(2)) do
  begin
    Inc(Count);
    WriteLn('tick ', Count, ': ', Line(Count));
    Flush(Output);
    Sleep(300);
  end;
end.
"""

case("padvar", {
    "main.pas": PADVAR_MAIN,
    "u.pas": PROGVAR_U}, [
    ("Small: Word = 1 in the program becomes Small: LongInt = 1", [("main.pas", "  Small: Word = 1;", "  Small: LongInt = 1;")]),
    ("Small is a Word again, and Flag: Byte becomes Flag: Word",
     [("main.pas", "  Small: LongInt = 1;", "  Small: Word = 1;"), ("main.pas", "  Flag: Byte;", "  Flag: Word;")]),
    ("Flag is a Byte again, a new Flag2: Byte after it, and another text",
     [("main.pas", "  Flag: Word;", "  Flag: Byte;\n  Flag2: Byte;"), ("main.pas", "' main one", "' main two")]),
    ("Small and its uses are removed",
     [("main.pas", "  Small: Word = 1;\n", ""), ("main.pas", "  Inc(Small);\n", ""),
      ("main.pas", "' main two %d %d %d %d', [Small, Big,", "' main three %d %d %d', [Big,")]),
    ("Small comes back as Small: LongInt = 1, with its uses",
     [("main.pas", "  Count: Integer = 0;\n", "  Count: Integer = 0;\n  Small: LongInt = 1;\n"),
      ("main.pas", "begin\n  Inc(Flag);", "begin\n  Inc(Small);\n  Inc(Flag);"),
      ("main.pas", "' main three %d %d %d', [Big,", "' main four %d %d %d %d', [Small, Big,")]),
])

# padvar's first three saves in a unit, without the check of layouts (no ppudump), which
# would find the change of type first
PADUNIT_U = r"""unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
var
  Small: Word = 1;
  Big: Int64 = 2;
  Flag: Byte;
  Wide: Int64;
function Tick(n: Integer): string;
begin
  Inc(Small);
  Inc(Flag);
  Inc(Wide);
  Result := Format('one %d %d %d %d', [Small, Big, Flag, Wide]);
end;
end.
"""

case("padunit", {
    "main.pas": MAIN,
    "u.pas": PADUNIT_U}, [
    ("Small: Word = 1 in the unit becomes Small: LongInt = 1", [("u.pas", "  Small: Word = 1;", "  Small: LongInt = 1;")]),
    ("Small is a Word again, and Flag: Byte becomes Flag: Word",
     [("u.pas", "  Small: LongInt = 1;", "  Small: Word = 1;"), ("u.pas", "  Flag: Byte;", "  Flag: Word;")]),
    ("Flag is a Byte again, a new Flag2: Byte after it, and another text",
     [("u.pas", "  Flag: Word;", "  Flag: Byte;\n  Flag2: Byte;"), ("u.pas", "'one %d", "'two %d")]),
], opts=("--ppudump", "no-such-ppudump"))

# ---------------------------------------------------------------------------- restarts
# One unit whose text and call count the program prints. A restart starts the count over.
# Calls has no initial value: with fpc 3.2.2 on Linux and Windows, a variable with one that
# changes from Integer to Int64 was swapped instead of refused.
U_COUNTED = r'''unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
var
  Calls: Integer;
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
     [("u.pas", "Calls: Integer;", "Calls: Int64;"), ("u.pas", "'two calls", "'three calls")]),
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
     [("u.pas", "Calls: Integer;", "Calls: Int64;"), ("u.pas", "'one calls", "'two calls"),
      ("u.pas", "\nend.", "\ninitialization\n  Halt(3);\nend.")]),
    ("the initialization no longer ends it: the next save starts the program again",
     [("u.pas", "initialization\n  Halt(3);\n", ""), ("u.pas", "'two calls", "'three calls")]),
], restart=True)

# ---------------------------------------------------------------------------- a short entry
# A swap writes a jump at the entry of every routine of the unit, 5 bytes on x86-64. With
# {$codealign proc=1} fpc packs routines where the assembler doesn't pad their sections (on
# macOS, and on Linux with the external assembler, -Aas): Small is 3 bytes long and Next
# starts right after it. The jump at Small would overwrite Next, so on x86-64 the save needs
# a restart. Tick calls both through their first addresses, as old code and pointers do.
SHORT_ENTRY_OPTS = ("-Aas",) if sys.platform.startswith("linux") and platform.machine() == "x86_64" \
    and "-Twin" not in os.environ.get("HOT_DRIVER_OPTS", "") else ()
case("shortentry", {
    "main.pas": MAIN,
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
{$codealign proc=1}
interface
function Tick(n: Integer): string;
implementation
uses SysUtils;
type
  TValue = function: LongInt;
{$if defined(cpux86_64)}
{$asmmode intel}
function Small: LongInt; assembler; nostackframe;
asm
  xor eax, eax
end;
function Next: LongInt; assembler; nostackframe;
asm
  mov eax, 7
end;
{$else}
function Small: LongInt;
begin
  Result := 0;
end;
function Next: LongInt;
begin
  Result := 7;
end;
{$endif}
function Tick(n: Integer): string;
var
  First, Second: TValue;
begin
  First := @Small;
  Second := @Next;
  Result := Format('small %d next %d', [First(), Second()]);
end;
end.
'''}, [
    ("Small returns 3", [("u.pas", "  xor eax, eax\n", "  mov eax, 3\n"), ("u.pas", "Result := 0;", "Result := 3;")]),
], opts=SHORT_ENTRY_OPTS, restart=True)

# ---------------------------------------------------------------------------- a call at the entry
# A thread waits in a routine that Relay calls with its first instruction. On x86-64 that
# call is 2 bytes long, so the return address is inside the 5 bytes of the jump a swap
# writes at Relay's entry, and the thread would return into the middle of it: the save needs
# a restart. On arm64 the call is one instruction, as long as the branch a swap writes, so
# the thread returns after it, into the old code, and the save is swapped. Through calls Wait
# with the stack aligned for it; on arm64, Enter passes Relay where to return in x3, since
# Relay's call overwrites x30. Relay is in the interface: fpc 3.2 gives a routine of the
# implementation section no symbol in a Windows object, so a swap there would not redirect it.
case("shortcall", {
    "main.pas": MAIN.replace("uses SysUtils, u;", "uses {$ifdef unix}cthreads,{$endif} SysUtils, u;"),
    "u.pas": r'''unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
function Relay(AThrough, ATarget: Pointer): LongInt;
implementation
uses Classes, SysUtils;
type
  TWaiter = class(TThread)
    procedure Execute; override;
  end;
var
  Waiter: TWaiter;
  Seen: LongInt;
procedure Wait;
begin
  Sleep(100);
end;
{$if defined(cpux86_64)}
{$asmmode intel}
function Relay(AThrough, ATarget: Pointer): LongInt; assembler; nostackframe;
asm
{$ifdef windows}
  call rcx
{$else}
  call rdi
{$endif}
  mov eax, 1
end;
procedure Through; assembler; nostackframe;
asm
{$ifdef windows}
  sub rsp, 32
  call rdx
  add rsp, 32
{$else}
  call rsi
{$endif}
end;
function Outer(AThrough, ATarget: Pointer): LongInt;
begin
  Result := Relay(AThrough, ATarget);
end;
{$else}
function Relay(AThrough, ATarget: Pointer): LongInt; assembler; nostackframe;
asm
  blr x0
  mov w0, #1
  br x3
end;
procedure Enter; assembler; nostackframe;
asm
  mov x3, x30
  b Relay
end;
function Outer(AThrough, ATarget: Pointer): LongInt; assembler; nostackframe;
asm
  stp x29, x30, [sp, #-16]!
  mov x29, sp
  bl Enter
  ldp x29, x30, [sp], #16
end;
procedure Through; assembler; nostackframe;
asm
  stp x29, x30, [sp, #-32]!
  str x3, [sp, #16]
  mov x29, sp
  blr x1
  ldr x3, [sp, #16]
  ldp x29, x30, [sp], #32
end;
{$endif}
procedure TWaiter.Execute;
begin
  while not Terminated do Seen := Outer(@Through, @Wait);
end;
function Tick(n: Integer): string;
begin
  Result := Format('relay %d', [Seen]);
  if Waiter.FatalException <> nil then Result := Result + ', the waiting thread failed: ' + Exception(Waiter.FatalException).Message;
end;
initialization
  Waiter := TWaiter.Create(False);
finalization
  Waiter.Terminate;
  Waiter.WaitFor;
  Waiter.Free;
end.
'''}, [
    ("Relay returns 2", [("u.pas", "  mov eax, 1\n", "  mov eax, 2\n"), ("u.pas", "  mov w0, #1\n", "  mov w0, #2\n")]),
], restart=True)

# ---------------------------------------------------------------------------- a signal handler at the entry
# A thread traps in Entry's first bytes, and its handler waits until the new code of a save
# has run. The system keeps where the thread is to resume in the handler's frame: on x86-64
# at Entry + 3, inside the 5 bytes of the jump a swap writes there, so the save needs a
# restart. The thread itself is in the handler, and on Linux so it is when the signal that
# stops it arrives. In sigmasked the handler blocks every signal, so on Linux the agent can't
# stop the thread and finds it asleep. On arm64 the trap is the second instruction, after
# the one-instruction branch, and the save is swapped: the thread resumes in the old code,
# and its next call runs the new code. The handler is in a unit of its own, which no save
# changes: on Windows new code can't call a routine of a library the program never called
# from code of its own, as AddVectoredExceptionHandler is.
SIG_TRAP_UNIT = r'''unit trap;
{$mode objfpc}{$H+}
interface
var
  Resume: LongInt = 0;
procedure Install;
implementation
uses {$ifdef unix}BaseUnix,{$endif} SysUtils;
procedure Await;
begin
  while InterLockedCompareExchange(Resume, 0, 0) = 0 do Sleep(10);
end;
{$ifdef windows}
const
  BreakpointCode = LongWord($80000003);
  ContextRIPOffset = $f8;
type
  TExceptionPointers = record
    ExceptionRecord: PLongWord;   // the exception code comes first
    ContextRecord: PByte;
  end;
  PExceptionPointers = ^TExceptionPointers;
function AddVectoredExceptionHandler(AFirst: LongWord; AHandler: Pointer): Pointer; stdcall; external 'kernel32' name 'AddVectoredExceptionHandler';
// Windows reports a breakpoint at the int3: the thread resumes after it
function Trapped(AInfo: PExceptionPointers): LongInt; stdcall;
var
  RIP: PQWord;
begin
  if AInfo^.ExceptionRecord^ <> BreakpointCode then Exit(0);   // EXCEPTION_CONTINUE_SEARCH
  Await;
  RIP := PQWord(AInfo^.ContextRecord + ContextRIPOffset);
  if PByte(PtrUInt(RIP^))^ = $cc then Inc(RIP^);
  Result := -1;   // EXCEPTION_CONTINUE_EXECUTION
end;
procedure Install;
begin
  AddVectoredExceptionHandler(1, @Trapped);
end;
{$else}
// x86-64 resumes after the int3; on arm64 the handler moves the thread past the brk
procedure Trapped(ASignal: cint; AInfo: PSigInfo; AContext: Pointer); cdecl;
begin
  Await;
{$if defined(cpuaarch64) and defined(darwin)}
  Inc(PQWord(PPointer(PByte(AContext) + 48)^ + 272)^, 4);   // uc_mcontext^.__ss.__pc
{$elseif defined(cpuaarch64)}
  Inc(PQWord(PByte(AContext) + 440)^, 4);   // uc_mcontext.pc
{$endif}
end;
procedure Install;
var
  Action: SigActionRec;
begin
  FillChar(Action, SizeOf(Action), 0);
  Action.sa_handler := SigActionHandler(@Trapped);
  Action.sa_flags := SA_SIGINFO;
  BLOCK_ALL
  FpSigAction(SIGTRAP, @Action, nil);
end;
{$endif}
end.
'''
SIG_HANDLER_UNIT = r'''unit u;
{$mode objfpc}{$H+}
interface
function Tick(n: Integer): string;
function Entry: LongInt;
implementation
uses Classes, SysUtils, trap;
type
  TCaller = class(TThread)
    procedure Execute; override;
  end;
var
  Caller: TCaller;
  Seen: LongInt;
{$if defined(cpux86_64)}
{$asmmode intel}
function Entry: LongInt; assembler; nostackframe;
asm
  xor eax, eax
  int3
  mov eax, 1
end;
{$else}
function Entry: LongInt; assembler; nostackframe;
asm
  mov w0, #0
  brk #0
  mov w0, #1
end;
{$endif}
procedure TCaller.Execute;
begin
  while not Terminated do
  begin
    Seen := Entry;
    Sleep(20);
  end;
end;
function Tick(n: Integer): string;
begin
  Result := Format('entry %d', [Seen]);
  if Caller.FatalException <> nil then Result := Result + ', the trapped thread failed: ' + Exception(Caller.FatalException).Message;
end;
initialization
  Install;
  Caller := TCaller.Create(False);
finalization
  InterLockedExchange(Resume, 1);
  Caller.Terminate;
  Caller.WaitFor;
  Caller.Free;
end.
'''
SIG_HANDLER_STEPS = [
    ("the new Tick lets the handler return, and Entry returns 2",
     [("u.pas", "  Result := Format('entry %d', [Seen]);", "  InterLockedExchange(Resume, 1);\n  Result := Format('entry %d, resumed', [Seen]);"),
      ("u.pas", "  mov eax, 1\n", "  mov eax, 2\n"), ("u.pas", "  mov w0, #1\n", "  mov w0, #2\n")]),
]
SIG_HANDLER_MAIN = MAIN.replace("uses SysUtils, u;", "uses {$ifdef unix}cthreads,{$endif} SysUtils, u;")
case("sighandler", {"main.pas": SIG_HANDLER_MAIN, "u.pas": SIG_HANDLER_UNIT,
                    "trap.pas": SIG_TRAP_UNIT.replace("  BLOCK_ALL\n", "")}, SIG_HANDLER_STEPS, restart=True)
case("sigmasked", {"main.pas": SIG_HANDLER_MAIN, "u.pas": SIG_HANDLER_UNIT,
                   "trap.pas": SIG_TRAP_UNIT.replace("  BLOCK_ALL\n", "  FpSigFillSet(Action.sa_mask);\n")}, SIG_HANDLER_STEPS, restart=True)


# The driver's line that ends its work on a save: the swap, the code that came out the same, a
# compile or link that failed, or a restart done or given up. A refusal ends it too, unless the
# case lets the driver restart the program.
DONE = re.compile(r"\[hot\] (v\d+ swapped|not swapped|error: |v\d+ restarted|the next save that builds starts|the program ended with)")
REFUSED = re.compile(r"\[hot\] restart needed")
# A swap says how long after it saw the save it was made. After a quick save ("+"), a swap
# of a save the driver saw more than SEEN_MARGIN s before it is the outcome of the save
# before, not of this one. The driver's clock counts whole ms, so a swap of this save can
# seem to have seen it a ms or two before it was written.
SEEN = re.compile(r"; ([\d.]+) ms after the save was seen")
SEEN_MARGIN = 0.02
QUICK_TIMEOUT = 10
# The longest the driver may take for a save: a restart waits up to 60 s for a new program to
# start (macOS checks a new executable on its first start).
OUTCOME_TIMEOUT = 150
# The most ticks a program runs if the script never tells it to end
MAX_TICKS = 1000


def run(name):
    files, steps, opts, env = CASES[name]
    work = os.path.join(HERE, "work", name)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    for f, text in files.items():
        with open(os.path.join(work, f), "w") as fh:
            fh.write(text)
    # the program ends when this file exists (its name is no source the driver watches)
    stop = os.path.join(work, "stop")
    restarts = "--no-restart" not in opts
    t0 = time.time()
    lock = threading.Lock()
    lines = []   # what the driver printed, in order
    arrived = []   # when each line arrived
    changed = threading.Condition(lock)

    def out(line):
        with lock:
            print("%6.2fs  %s" % (time.time() - t0, line), flush=True)

    print("=== %s" % name, flush=True)
    p = subprocess.Popen(driver_cmd() + list(opts) + [os.path.join(work, "main.pas"), "--", str(MAX_TICKS), stop],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                         env=dict(os.environ, **env))
    ended = threading.Event()

    def pump():
        for line in p.stdout:
            line = line.rstrip("\n")
            with changed:
                print("%6.2fs  %s" % (time.time() - t0, line), flush=True)
                lines.append(line)
                arrived.append(time.time())
                changed.notify_all()
        with changed:
            ended.set()
            changed.notify_all()

    def wait(test, timeout=OUTCOME_TIMEOUT):
        """Waits until a line the driver printed passes test, or it ends; False after the
        timeout."""
        deadline = time.time() + timeout
        with changed:
            while not ended.is_set() and not test():
                if time.time() > deadline:
                    return False
                changed.wait(deadline - time.time())
        return True

    def outcome(since, saved=None):
        """The driver is done with what was saved after its first `since` lines; with saved, the
        time of a quick save, not with a swap of an earlier one."""
        for line, at in zip(lines[since:], arrived[since:]):
            seen = SEEN.search(line)
            if saved is not None and seen and at - float(seen.group(1)) / 1000 < saved - SEEN_MARGIN:
                continue
            if DONE.match(line) or (not restarts and REFUSED.match(line)):
                return True
        return False

    def write(path, text):
        """Saves a file of a step: its text; None removes it, or the directory BLOCKED put there."""
        if text is None:
            if os.path.isdir(path):
                os.rmdir(path)
            elif os.path.exists(path):
                os.remove(path)
        elif text is BLOCKED:
            if os.path.exists(path):
                os.remove(path)
            os.makedirs(path)
        else:
            with open(path, "w") as fh:
                fh.write(text)

    def write_emptied_first(texts):
        """Saves a step's files as an editor that empties the first before it writes it: the
        others 0.1 s after it emptied it, and its text 0.3 s after."""
        first = next(iter(texts))
        open(first, "w").close()
        emptied = time.time()
        time.sleep(0.1)
        for path, text in list(texts.items())[1:]:
            write(path, text)
        time.sleep(max(0.0, emptied + 0.3 - time.time()))
        with open(first, "w") as fh:
            fh.write(texts[first])

    def texts_of(edits):
        """The files the edits make, by path, in the order the edits name them."""
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
        return texts

    th = threading.Thread(target=pump)
    th.start()
    # a step at the start is saved once fpc has written the program's object file, of the
    # first build, or of a build after the program was linked
    def written(path):
        try:
            return os.stat(os.path.join(work, ".hot", path)).st_mtime_ns
        except OSError:
            return None

    def built(before):
        made = written(os.path.join("units", "main.o"))
        linked = max(written("main") or 0, written("main.exe") or 0)
        # fpc may still be writing the main.o the step before saw: only a link after it ends
        # that build
        return made is not None and (before is None or before < linked < made)
    before = None
    while steps and len(steps[0]) > 2 and steps[0][2] == AT_START:
        desc, edits = steps[0][:2]
        emptied_first = EMPTIED_FIRST in steps[0][3:]
        steps = steps[1:]
        deadline = time.time() + OUTCOME_TIMEOUT
        while not built(before) and p.poll() is None and time.time() < deadline \
                and not any("] v1: built" in line for line in lines):
            time.sleep(0.001)
        if not built(before):
            out("!!! the driver did not build main.pas %sbefore it started the program" % ("again " if before else ""))
        before = written(os.path.join("units", "main.o"))
        out("--- the script saves: " + desc)
        texts = texts_of(edits)
        if emptied_first:
            write_emptied_first(texts)
        else:
            for path, text in texts.items():
                write(path, text)
    # Wait until the driver watches the files and the program runs: the steps must not depend
    # on how long the build or the start took. (Waiting for the build's object file was not
    # enough: under load a new executable took up to 9 s to start, and early saves merged.)
    if not wait(lambda: any("] v1: built" in line for line in lines)):
        out("!!! the driver did not start the program within %d s" % OUTCOME_TIMEOUT)
    time.sleep(0.9)
    for i, step in enumerate(steps):
        desc, edits = step[:2]
        while_compiling = len(step) > 2 and step[2] == WHILE_COMPILING
        emptied_first = len(step) > 2 and step[2] == EMPTIED_FIRST
        # a "+" marks a step that follows the one before it after 0.12 s, while the driver is
        # still busy with that one; every other step waits for the driver's outcome of the
        # one before, as someone who saves, looks at the result and edits again
        quick_next = i + 1 < len(steps) and steps[i + 1][0].startswith("+")
        out("--- the script saves: " + desc.lstrip("+"))
        texts = texts_of(edits)
        with lock:
            since = len(lines)
        saved = time.time()
        first = next(iter(texts))
        if emptied_first:
            write_emptied_first(texts)
        else:
            for k, (path, text) in enumerate(texts.items()):
                if k == 1 and while_compiling:
                    record = os.path.join(work, ".hot", "units", os.path.splitext(os.path.basename(first))[0] + ".ppu")
                    deadline = time.time() + OUTCOME_TIMEOUT
                    while os.path.exists(record) and time.time() < deadline:
                        time.sleep(0.001)
                    if os.path.exists(record):
                        out("!!! the driver did not start to compile %s within %d s" % (os.path.basename(first), OUTCOME_TIMEOUT))
                write(path, text)
        if quick_next:
            time.sleep(0.12)
            continue
        # after a quick save, a swap of the save before is not its outcome; but a swap that
        # merged the two can carry the earlier save's time when the driver read the files
        # late, so after QUICK_TIMEOUT s any outcome counts
        if not (desc.startswith("+") and wait(lambda: outcome(since, saved), QUICK_TIMEOUT)) \
                and not wait(lambda: outcome(since)):
            out("!!! the driver gave no outcome within %d s of the save" % OUTCOME_TIMEOUT)
        # the program runs a few ticks with what the driver made of the save
        time.sleep(1.2)
    with open(stop, "w"):
        pass
    p.wait()
    th.join()
    print(flush=True)


if __name__ == "__main__":
    names = sys.argv[1:] or list(CASES)
    for n in names:
        run(n)
