unit hotagent;
{ hotagent: the in-process agent for hot reloading Free Pascal programs, as a unit.

  The wrapper adds it to the program with fpc's -Fa option (load these units before the
  program's uses clause), precompiled into a directory that does not hold this source:
  -Fa cannot load a unit the compiler decides to recompile (ctask.pas, internal error
  2026032615). It is initialised before every unit of the program and needs no change to
  it. When the environment names a driver (HOT_PORT, HOT_TOKEN) it starts a thread that
  connects to 127.0.0.1:HOT_PORT, says "hello HOT_TOKEN", and takes commands:

    base <unit.o>            the object file the running program was linked from
    load <unit.o> [...]      load freshly compiled object files as one transaction
    ping

  The rules:
    * a named variable that already exists keeps its address (state survives);
    * a function keeps its first address as its value (@Proc, VMT slots, method
      pointers); that entry is overwritten once with a branch to an island that jumps
      through a slot, and a reload stores the newest address in the slot;
    * a VMT keeps its address and is updated in place when its shape is unchanged;
    * nothing is ever unmapped.

  What differs per target is kept apart:
    object files    Mach-O (Darwin), ELF (Linux) and COFF (Windows) are read into one
                    neutral form
    instructions    aarch64 and x86-64: branches, islands, relocations
    the system      executable memory, rewriting the program's code, stopping threads

  On aarch64 an entry is redirected by one aligned 4-byte store. On x86-64 the jump is 5
  bytes and covers the start of more than one instruction, so the commit also checks that no
  stopped thread is between the first and the fifth byte of an entry, and retries if one is.

  On Unix it uses cthreads (its own thread needs it; on Linux that links libc), sockets
  and baseunix; on Windows only the system unit and calls it declares itself. Never
  sysutils, which would change how a program without it reports runtime errors. It is
  written for the language every fpc since 3.2 accepts, because the driver compiles it
  with whatever compiler builds the program. }
{$mode objfpc}{$H+}{$Q-}{$R-}{$pointermath on}
// Without optimisation, whatever the command line says: fpc 3.3.1+3 for x86-64 at -O1 and
// -O2 gave a loop counter and a temporary string the same register, here and in other
// code (docs/how-it-works.md, "A compiler bug"). Neither the driver nor the agent needs the speed.
{$optimization off}
interface

{$ifdef unix}
uses cthreads;
{$endif}

procedure HotAnchor;

implementation

{$ifdef unix}
uses baseunix, sockets;
{$endif}

{$if not (defined(darwin) and defined(cpuaarch64)) and not (defined(linux) and (defined(cpuaarch64) or defined(cpux86_64))) and not (defined(win64) and defined(cpux86_64))}
  {$error hotagent: Darwin on aarch64, Linux on aarch64 or x86-64, Windows on x86-64 so far}
{$endif}

const
  K_CODE = 1;
  K_DATA = 2;
  K_TLS = 3;    // a thread variable of the system's own kind (ELF TLS): never placed, only bound
  ISLAND_AREA = QWord(2) shl 20;   // redirect islands: must be within reach of a branch from the program's text
  JIT_SIZE = QWord(96) shl 20;     // new code, with its own veneers at the start
{$ifdef cpuaarch64}
  BRANCH_REACH = Int64(1) shl 27;  // b, bl: +-128 MiB
  ISLAND_REACH = Int64(127) shl 20;
  REGION_REACH = Int64(3) shl 30;  // adrp: +-4 GiB
{$else}
  BRANCH_REACH = Int64(1) shl 31;  // jmp, call rel32: +-2 GiB
  ISLAND_REACH = (Int64(2) shl 30) - (Int64(64) shl 20);
  REGION_REACH = (Int64(2) shl 30) - (Int64(64) shl 20);   // rip-relative data: +-2 GiB
{$endif}
  VENEER_AREA = QWord(2) shl 20;
  DATA_SIZE = QWord(256) shl 20;
  SLOT_AREA = QWord(2) shl 20;
  FNV0 = QWord(1469598103934665603);
  PROT_R = 1;
  PROT_W = 2;
  PROT_X = 4;
  MAP_PRIV = 2;
{$if defined(darwin)}
  MAP_ANONYM = $1000;
  MAP_JIT = $800;
  LOW_BOUND = QWord(4) shl 30;     // __PAGEZERO
  CLOCK_MONO = 6;
  SIG_BLOCK_HOW = 1;
{$elseif defined(linux)}
  MAP_ANONYM = $20;
  MAP_JIT = 0;
  LOW_BOUND = QWord(1) shl 20;
  CLOCK_MONO = 1;
  SIG_BLOCK_HOW = 0;
  PARK_SIG = 40;                   // a real-time signal glibc does not reserve
{$endif}

{$ifdef unix}
type
  TTimeSpec = record sec, nsec: Int64; end;

function clock_gettime(clk: LongInt; var ts: TTimeSpec): LongInt; cdecl; external 'c';
function mprotect(addr: Pointer; len: PtrUInt; prot: LongInt): LongInt; cdecl; external 'c';
function unsetenv(name: PChar): LongInt; cdecl; external 'c';
function dlsym(handle: Pointer; name: PChar): Pointer; cdecl; external 'c';
function pthread_sigmask(how: LongInt; newset, oldset: Pointer): LongInt; cdecl; external 'c';
function getpagesize: LongInt; cdecl; external 'c';
{$endif}

{$ifdef windows}
// The few Windows calls the agent makes, declared here so that it needs no unit but system.
type
  THandle_ = PtrUInt;
  TThreadEntry32 = record
    dwSize, cntUsage, th32ThreadID, th32OwnerProcessID: LongWord;
    tpBasePri, tpDeltaPri: LongInt;
    dwFlags: LongWord;
  end;
  TSockAddrIn = packed record
    sin_family, sin_port: Word;
    sin_addr: LongWord;
    sin_zero: array[0..7] of Byte;
  end;
const
  MEM_COMMIT = $1000;
  MEM_RESERVE = $2000;
  PAGE_READWRITE = $04;
  PAGE_EXECUTE_READWRITE = $40;
  TH32CS_SNAPTHREAD = 4;
  THREAD_SUSPEND_RESUME = 2;
  THREAD_GET_CONTEXT = 8;
  CONTEXT_CONTROL_AMD64 = $100001;
  GENERIC_READ = $80000000;
  FILE_SHARE_READ = 1;
  FILE_SHARE_WRITE = 2;
  OPEN_EXISTING = 3;
  INVALID_HANDLE = THandle_(-1);
function VirtualAlloc(addr: Pointer; size: PtrUInt; typ, prot: LongWord): Pointer; stdcall; external 'kernel32' name 'VirtualAlloc';
function VirtualProtect(addr: Pointer; size: PtrUInt; prot: LongWord; out old: LongWord): LongBool; stdcall; external 'kernel32' name 'VirtualProtect';
function FlushInstructionCache(process: THandle_; addr: Pointer; size: PtrUInt): LongBool; stdcall; external 'kernel32' name 'FlushInstructionCache';
function GetCurrentProcess: THandle_; stdcall; external 'kernel32' name 'GetCurrentProcess';
function GetCurrentProcessId: LongWord; stdcall; external 'kernel32' name 'GetCurrentProcessId';
function GetCurrentThreadId: LongWord; stdcall; external 'kernel32' name 'GetCurrentThreadId';
function CreateToolhelp32Snapshot(flags, pid: LongWord): THandle_; stdcall; external 'kernel32' name 'CreateToolhelp32Snapshot';
function Thread32First(snap: THandle_; var te: TThreadEntry32): LongBool; stdcall; external 'kernel32' name 'Thread32First';
function Thread32Next(snap: THandle_; var te: TThreadEntry32): LongBool; stdcall; external 'kernel32' name 'Thread32Next';
function OpenThread(access: LongWord; inherit: LongBool; id: LongWord): THandle_; stdcall; external 'kernel32' name 'OpenThread';
function SuspendThread(h: THandle_): LongWord; stdcall; external 'kernel32' name 'SuspendThread';
function ResumeThread(h: THandle_): LongWord; stdcall; external 'kernel32' name 'ResumeThread';
function GetThreadContext(h: THandle_; ctx: Pointer): LongBool; stdcall; external 'kernel32' name 'GetThreadContext';
function CloseHandle(h: THandle_): LongBool; stdcall; external 'kernel32' name 'CloseHandle';
function GetModuleHandleA(name: PChar): PtrUInt; stdcall; external 'kernel32' name 'GetModuleHandleA';
function GetModuleFileNameA(module: PtrUInt; buf: PChar; size: LongWord): LongWord; stdcall; external 'kernel32' name 'GetModuleFileNameA';
function CreateFileA(name: PChar; access, share: LongWord; sec: Pointer; disp, flags: LongWord; tmpl: THandle_): THandle_; stdcall; external 'kernel32' name 'CreateFileA';
function GetFileSize(h: THandle_; high: PLongWord): LongWord; stdcall; external 'kernel32' name 'GetFileSize';
function ReadFile(h: THandle_; buf: Pointer; n: LongWord; out got: LongWord; ov: Pointer): LongBool; stdcall; external 'kernel32' name 'ReadFile';
function GetEnvironmentVariableA(name, buf: PChar; size: LongWord): LongWord; stdcall; external 'kernel32' name 'GetEnvironmentVariableA';
function SetEnvironmentVariableA(name, value: PChar): LongBool; stdcall; external 'kernel32' name 'SetEnvironmentVariableA';
function QueryPerformanceCounter(out c: Int64): LongBool; stdcall; external 'kernel32' name 'QueryPerformanceCounter';
function QueryPerformanceFrequency(out f: Int64): LongBool; stdcall; external 'kernel32' name 'QueryPerformanceFrequency';
procedure WinSleep(ms: LongWord); stdcall; external 'kernel32' name 'Sleep';
function RtlAddFunctionTable(table: Pointer; count: LongWord; base: QWord): ByteBool; stdcall; external 'kernel32' name 'RtlAddFunctionTable';
function RtlDeleteFunctionTable(table: Pointer): ByteBool; stdcall; external 'kernel32' name 'RtlDeleteFunctionTable';
function WSAStartup(version: Word; data: Pointer): LongInt; stdcall; external 'ws2_32' name 'WSAStartup';
function ws_socket(af, typ, proto: LongInt): PtrUInt; stdcall; external 'ws2_32' name 'socket';
function ws_connect(s: PtrUInt; addr: Pointer; len: LongInt): LongInt; stdcall; external 'ws2_32' name 'connect';
function ws_send(s: PtrUInt; buf: Pointer; len, flags: LongInt): LongInt; stdcall; external 'ws2_32' name 'send';
function ws_recv(s: PtrUInt; buf: Pointer; len, flags: LongInt): LongInt; stdcall; external 'ws2_32' name 'recv';
function ws_shutdown(s: PtrUInt; how: LongInt): LongInt; stdcall; external 'ws2_32' name 'shutdown';
{$endif}

{$ifdef darwin}
type
  mach_port_t = LongWord;
  kern_return_t = LongInt;
var
  mach_task_self_: mach_port_t; cvar; external;
function mach_vm_remap(target: mach_port_t; var addr: QWord; size, mask: QWord; flags: LongInt; src_task: mach_port_t; src_addr: QWord; copy: LongInt; var cur, max: LongInt; inherit: LongWord): kern_return_t; cdecl; external 'c';
function mach_vm_protect(task: mach_port_t; addr, size: QWord; set_max: LongInt; prot: LongInt): kern_return_t; cdecl; external 'c';
function mach_vm_deallocate(task: mach_port_t; addr, size: QWord): kern_return_t; cdecl; external 'c';
function mach_thread_self: mach_port_t; cdecl; external 'c';
function task_threads(task: mach_port_t; var list: PLongWord; var count: LongWord): kern_return_t; cdecl; external 'c';
function thread_suspend(t: mach_port_t): kern_return_t; cdecl; external 'c';
function thread_resume(t: mach_port_t): kern_return_t; cdecl; external 'c';
function mach_port_deallocate(task, name: mach_port_t): kern_return_t; cdecl; external 'c';
function vm_deallocate(task: mach_port_t; addr, size: PtrUInt): kern_return_t; cdecl; external 'c';
function mach_error_string(kr: kern_return_t): PChar; cdecl; external 'c';
procedure sys_icache_invalidate(start: Pointer; len: PtrUInt); cdecl; external 'c';
procedure pthread_jit_write_protect_np(enabled: LongInt); cdecl; external 'c';
function _dyld_image_count: LongWord; cdecl; external 'c';
function _dyld_get_image_header(i: LongWord): Pointer; cdecl; external 'c';
function _dyld_get_image_vmaddr_slide(i: LongWord): PtrInt; cdecl; external 'c';
const
  RTLD_DEFAULT = Pointer(-2);
{$endif}
{$ifdef linux}
function gettid: LongInt; cdecl; external 'c';
function tgkill(tgid, tid, sig: LongInt): LongInt; cdecl; external 'c';
const
  RTLD_DEFAULT = nil;
{$endif}

procedure HotAnchor;
begin
end;

// ---------------------------------------------------------------- small helpers
function IStr(v: Int64): AnsiString;
begin
  Str(v, Result);
end;

function UStr(v: QWord): AnsiString;
begin
  Str(v, Result);
end;

function FStr(v: Double): AnsiString;
begin
  Str(v: 0: 3, Result);
end;

function HStr(v: QWord): AnsiString;
begin
  Result := '0x' + HexStr(v, 16);
end;

{$ifdef windows}
function NowMs: Double;
var
  c, f: Int64;
begin
  QueryPerformanceCounter(c);
  QueryPerformanceFrequency(f);
  Result := Double(c) * Double(1000) / Double(f);
end;
{$else}
function NowMs: Double;
var
  ts: TTimeSpec;
begin
  clock_gettime(CLOCK_MONO, ts);
  Result := Double(ts.sec) * Double(1000) + Double(ts.nsec) / Double(1000000);   // a bare 1000.0 is a Single here
end;
{$endif}

procedure Nap(ms: LongInt);
{$ifdef windows}
begin
  WinSleep(ms);
end;
{$else}
var
  t: timespec;
begin
  t.tv_sec := ms div 1000;
  t.tv_nsec := (ms mod 1000) * 1000000;
  FpNanoSleep(@t, nil);   // FpSleep refers to an undefined "sleep" on Darwin with fpc 3.3.1
end;
{$endif}

// The value of an environment variable, or False when it is not set.
function EnvVar(const name: AnsiString; out value: AnsiString): Boolean;
{$ifdef windows}
var
  buf: array[0..4095] of Char;
  n: LongWord;
begin
  n := GetEnvironmentVariableA(PChar(name), @buf[0], SizeOf(buf));
  Result := (n > 0) and (n < SizeOf(buf));
  if Result then SetString(value, PChar(@buf[0]), n) else value := '';
end;
{$else}
var
  p: PChar;
begin
  p := FpGetEnv(PChar(name));
  Result := p <> nil;
  if Result then value := p else value := '';
end;
{$endif}

procedure UnsetEnv(const name: AnsiString);
begin
{$ifdef windows}
  SetEnvironmentVariableA(PChar(name), nil);
{$else}
  unsetenv(PChar(name));
{$endif}
end;

function Fnv(p: PByte; n: PtrUInt; h: QWord): QWord;
var
  i: PtrUInt;
begin
  i := 0;
  while i < n do
  begin
    h := (h xor p[i]) * QWord(1099511628211);
    Inc(i);
  end;
  Result := h;
end;

function FnvStr(const s: AnsiString): QWord;
begin
  Result := Fnv(PByte(PChar(s)), Length(s), FNV0);
end;

function StartsWith(const s, prefix: AnsiString): Boolean;
begin
  Result := (Length(s) >= Length(prefix)) and (CompareByte(PChar(s)^, PChar(prefix)^, Length(prefix)) = 0);
end;

function EndsWith(const s, suffix: AnsiString): Boolean;
begin
  Result := (Length(s) >= Length(suffix)) and (Copy(s, Length(s) - Length(suffix) + 1, Length(suffix)) = suffix);
end;

function Contains(const s, part: AnsiString): Boolean;
begin
  Result := Pos(part, s) > 0;
end;

// ---------------------------------------------------------------- reply
var
  g_reply: AnsiString;

procedure Say(const s: AnsiString);
begin
  g_reply := g_reply + s + #10;
end;

// ---------------------------------------------------------------- string hash map
type
  TMap = record
    Keys: array of AnsiString;
    Vals: array of Pointer;
    N: SizeInt;
  end;

procedure MapPut(var m: TMap; const k: AnsiString; v: Pointer); forward;

procedure MapGrow(var m: TMap);
var
  ok: array of AnsiString;
  ov: array of Pointer;
  i: SizeInt;
begin
  ok := m.Keys;
  ov := m.Vals;
  m.Keys := nil;
  m.Vals := nil;
  if Length(ok) = 0 then SetLength(m.Keys, 1024) else SetLength(m.Keys, Length(ok) * 2);
  SetLength(m.Vals, Length(m.Keys));
  m.N := 0;
  for i := 0 to High(ok) do
    if ok[i] <> '' then MapPut(m, ok[i], ov[i]);
end;

procedure MapPut(var m: TMap; const k: AnsiString; v: Pointer);
var
  i, mask: SizeInt;
begin
  if (m.N + 1) * 2 > Length(m.Keys) then MapGrow(m);
  mask := Length(m.Keys) - 1;
  i := SizeInt(FnvStr(k) and QWord(mask));
  while (m.Keys[i] <> '') and (m.Keys[i] <> k) do i := (i + 1) and mask;
  if m.Keys[i] = '' then
  begin
    m.Keys[i] := k;
    Inc(m.N);
  end;
  m.Vals[i] := v;
end;

function MapGet(const m: TMap; const k: AnsiString): Pointer;
var
  i, mask: SizeInt;
begin
  Result := nil;
  if (Length(m.Keys) = 0) or (k = '') then Exit;
  mask := Length(m.Keys) - 1;
  i := SizeInt(FnvStr(k) and QWord(mask));
  while m.Keys[i] <> '' do
  begin
    if m.Keys[i] = k then Exit(m.Vals[i]);
    i := (i + 1) and mask;
  end;
end;

// ---------------------------------------------------------------- files
{$ifdef windows}
function ReadWholeFile(const path: AnsiString; out buf: PByte; out size: PtrUInt): Boolean;
var
  h: THandle_;
  got: LongWord;
begin
  Result := False;
  buf := nil;
  size := 0;
  h := CreateFileA(PChar(path), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if h = INVALID_HANDLE then Exit;
  size := GetFileSize(h, nil);
  buf := GetMem(size + 16);
  if not ReadFile(h, buf, size, got, nil) or (got <> size) then
  begin
    CloseHandle(h);
    FreeMem(buf);
    buf := nil;
    Exit;
  end;
  CloseHandle(h);
  Result := True;
end;
{$else}
function ReadWholeFile(const path: AnsiString; out buf: PByte; out size: PtrUInt): Boolean;
var
  fd: cint;
  st: Stat;
  got, n: TSsize;
begin
  Result := False;
  buf := nil;
  size := 0;
  fd := FpOpen(PChar(path), O_RDONLY);
  if fd < 0 then Exit;
  if FpFStat(fd, st) <> 0 then
  begin
    FpClose(fd);
    Exit;
  end;
  size := st.st_size;
  buf := GetMem(size + 16);
  got := 0;
  while PtrUInt(got) < size do
  begin
    n := FpRead(fd, buf[got], size - PtrUInt(got));
    if n <= 0 then Break;
    Inc(got, n);
  end;
  FpClose(fd);
  if PtrUInt(got) <> size then
  begin
    FreeMem(buf);
    buf := nil;
    Exit;
  end;
  Result := True;
end;
{$endif}

// ================================================================ object files: the neutral form
type
  TRelKind = (rkAbs64, rkAbs32, rkSub64, rkSub32, rkPrel32, rkPrel64, rkBranch26, rkPage21, rkPageOff12,
              rkGotPage21, rkGotPageOff12, rkGotPcrel32, rkGotAbs64,
              rkAbs32S, rkBranch32,   // x86-64: sign-extended absolute; rel32 of a call, jmp or jcc
              rkTpOff32, rkTpOff64,   // x86-64: offset of a thread variable from the thread pointer
              rkTprelHi12, rkTprelLo12,   // aarch64: the same, in two add instructions
              rkRva32,                // Windows: 32-bit offset from the image base (unwind tables)
              rkUnsupported);
  TReloc = record
    Off: QWord;        // in its section
    Kind: TRelKind;
    Sym: LongInt;      // the target symbol, or -1: the start of section Sect
    Sect: LongInt;
    Sym2: LongInt;     // subtractor: the symbol the target is subtracted from; unsupported: the raw type
    Addend: Int64;
    TOff: Int64;       // with HasTOff: the target's exact offset in section Sect (Addend may add a pc bias)
    HasTOff: Boolean;
  end;
  PSect = ^TSect;
  TSect = record
    Name: AnsiString;
    Kind: Byte;        // K_CODE, K_DATA, 0 = not loaded
    Zerofill: Boolean;
    Size, Align: QWord;
    Data: PByte;
    Rel: array of TReloc;
    Base: PByte;       // where it was placed
    Live: Boolean;     // reachable from what the program has (MarkLive)
  end;
  POSym = ^TOSym;
  TOSym = record
    Name: AnsiString;
    Sect: LongInt;
    Value, Size: QWord;   // value: offset in its section
    Ext, Defined, BoundOld, Resolved: Boolean;
    Kind: Byte;
    Tls: Boolean;         // resolved to a thread variable: AValue is its offset in the TLS segment
    AValue, ACall: QWord;
    Got: PQWord;
  end;
  PObj = ^TObj;
  TObj = record
    UnitName, Path: AnsiString;
    Buf: PByte;
    BufSize: PtrUInt;
    Sect: array of TSect;
    Sym: array of TOSym;
    ByName: TMap;
    Prev: PObj;
    Order: array of LongInt;   // defined symbols sorted by (section, value)
  end;

procedure ObjFree(o: PObj);
begin
  if o = nil then Exit;
  if o^.Buf <> nil then FreeMem(o^.Buf);
  Dispose(o);
end;

procedure SortOrder(o: PObj);
  function Less(a, b: LongInt): Boolean;
  begin
    if o^.Sym[a].Sect <> o^.Sym[b].Sect then Exit(o^.Sym[a].Sect < o^.Sym[b].Sect);
    Result := o^.Sym[a].Value < o^.Sym[b].Value;
  end;
  procedure QSort(lo, hi: LongInt);
  var
    i, j, p, t: LongInt;
  begin
    while lo < hi do
    begin
      i := lo;
      j := hi;
      p := o^.Order[(lo + hi) shr 1];
      repeat
        while Less(o^.Order[i], p) do Inc(i);
        while Less(p, o^.Order[j]) do Dec(j);
        if i <= j then
        begin
          t := o^.Order[i];
          o^.Order[i] := o^.Order[j];
          o^.Order[j] := t;
          Inc(i);
          Dec(j);
        end;
      until i > j;
      if j - lo < hi - i then
      begin
        QSort(lo, j);
        lo := i;
      end
      else
      begin
        QSort(i, hi);
        hi := j;
      end;
    end;
  end;
begin
  if Length(o^.Order) > 1 then QSort(0, High(o^.Order));
end;

// Relocations of a section in offset order (stable: equal offsets keep their order).
procedure SortRelocs(var r: array of TReloc);
var
  i, j: SizeInt;
  t: TReloc;
begin
  for i := 1 to High(r) do
  begin
    t := r[i];
    j := i - 1;
    if r[j].Off <= t.Off then Continue;
    while (j >= 0) and (r[j].Off > t.Off) do
    begin
      r[j + 1] := r[j];
      Dec(j);
    end;
    r[j + 1] := t;
  end;
end;

// Sizes: up to the next symbol at another address in the same section, or its end.
procedure FinishObj(o: PObj);
var
  i, j: SizeInt;
  s, n: POSym;
  e: QWord;
begin
  SortOrder(o);
  for i := 0 to High(o^.Order) do
  begin
    s := @o^.Sym[o^.Order[i]];
    e := o^.Sect[s^.Sect].Size;
    for j := i + 1 to High(o^.Order) do
    begin
      n := @o^.Sym[o^.Order[j]];
      if n^.Sect <> s^.Sect then Break;
      if n^.Value <> s^.Value then
      begin
        e := n^.Value;
        Break;
      end;
    end;
    s^.Size := e - s^.Value;
  end;
  for i := 0 to High(o^.Sect) do
    if Length(o^.Sect[i].Rel) > 1 then SortRelocs(o^.Sect[i].Rel);
end;

function IsAnon(const n: AnsiString): Boolean; forward;

// A local symbol with a name fpc made (unit and routine or variable, always with a $) is as
// stable across versions, and as present in the program's symbol table, as an external
// one: fpc 3.2 makes implementation-section variables local where 3.3.1 makes them private
// external.
function NamedLocal(const n: AnsiString): Boolean;
begin
  Result := (n <> '') and (Pos('$', n) > 0) and not IsAnon(n);
end;

procedure AddDefined(o: PObj; i: LongInt);
begin
  if not o^.Sym[i].Ext and NamedLocal(o^.Sym[i].Name) then o^.Sym[i].Ext := True;
  SetLength(o^.Order, Length(o^.Order) + 1);
  o^.Order[High(o^.Order)] := i;
  if o^.Sym[i].Ext then MapPut(o^.ByName, o^.Sym[i].Name, @o^.Sym[i]);
end;

procedure AddReloc(var t: TSect; const r: TReloc);
begin
  SetLength(t.Rel, Length(t.Rel) + 1);
  t.Rel[High(t.Rel)] := r;
end;

function CStr16(p: PChar): AnsiString;
var
  n: SizeInt;
begin
  n := 0;
  while (n < 16) and (p[n] <> #0) do Inc(n);
  SetString(Result, p, n);
end;

// ---------------------------------------------------------------- Mach-O
{$ifdef darwin}
type
  TMachHeader64 = packed record magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved: LongWord; end;
  PMachHeader64 = ^TMachHeader64;
  TLoadCmd = packed record cmd, cmdsize: LongWord; end;
  PLoadCmd = ^TLoadCmd;
  TSegCmd64 = packed record
    cmd, cmdsize: LongWord;
    segname: array[0..15] of Char;
    vmaddr, vmsize, fileoff, filesize: QWord;
    maxprot, initprot, nsects, flags: LongWord;
  end;
  PSegCmd64 = ^TSegCmd64;
  TSection64 = packed record
    sectname, segname: array[0..15] of Char;
    addr, size: QWord;
    offset, align, reloff, nreloc, flags, reserved1, reserved2, reserved3: LongWord;
  end;
  PSection64 = ^TSection64;
  TSymtabCmd = packed record cmd, cmdsize, symoff, nsyms, stroff, strsize: LongWord; end;
  PSymtabCmd = ^TSymtabCmd;
  TNList64 = packed record n_strx: LongWord; n_type, n_sect: Byte; n_desc: Word; n_value: QWord; end;
  PNList64 = ^TNList64;
  TRelInfo = packed record r_address: LongInt; w: LongWord; end;
  PRelInfo = ^TRelInfo;
const
  MH_MAGIC_64 = $feedfacf;
  MH_OBJECT = 1;
  MH_EXECUTE = 2;
  CPU_TYPE_ARM64 = $0100000C;
  LC_SEGMENT_64 = $19;
  LC_SYMTAB = 2;
  N_STAB = $e0;
  N_TYPE = $0e;
  N_SECT = $0e;
  N_EXT = $01;
  N_PEXT = $10;
  S_ATTR_PURE_INSTRUCTIONS = $80000000;
  S_ATTR_DEBUG = $02000000;
  SECTION_TYPE = $ff;
  S_ZEROFILL = 1;
  S_GB_ZEROFILL = $c;
  S_THREAD_LOCAL_ZEROFILL = $12;

function MachName(p: PChar): AnsiString;
begin
  if p^ = '_' then Inc(p);   // the platform's prefix; names are kept without it
  Result := p;
end;

function ParseMachO(o: PObj): Boolean;
var
  mh: PMachHeader64;
  lc: PLoadCmd;
  sg: PSegCmd64;
  s: PSection64;
  st: PSymtabCmd;
  nl: PNList64;
  strs: PChar;
  i, j, k, nraw: LongWord;
  addrs: array of QWord;
  relInfo: array of record off, n: LongWord; end;
  t: PSect;
  ty: LongWord;
  raw: PRelInfo;
  w, symnum, len, ext, rty: LongWord;
  pending: Int64;
  r: TReloc;
  stored: Int64;
  sym: POSym;
begin
  Result := False;
  mh := PMachHeader64(o^.Buf);
  if (o^.BufSize < SizeOf(TMachHeader64)) or (mh^.magic <> MH_MAGIC_64) or (mh^.filetype <> MH_OBJECT) or (mh^.cputype <> CPU_TYPE_ARM64) then
  begin
    Say('error ' + o^.Path + ' is not an arm64 Mach-O object');
    Exit;
  end;
  st := nil;
  lc := PLoadCmd(o^.Buf + SizeOf(TMachHeader64));
  for i := 1 to mh^.ncmds do
  begin
    if lc^.cmd = LC_SYMTAB then st := PSymtabCmd(lc);
    if lc^.cmd = LC_SEGMENT_64 then
    begin
      sg := PSegCmd64(lc);
      s := PSection64(PByte(sg) + SizeOf(TSegCmd64));
      for j := 1 to sg^.nsects do
      begin
        SetLength(o^.Sect, Length(o^.Sect) + 1);
        SetLength(addrs, Length(o^.Sect));
        SetLength(relInfo, Length(o^.Sect));
        t := @o^.Sect[High(o^.Sect)];
        t^.Name := CStr16(s^.segname) + ',' + CStr16(s^.sectname);
        t^.Size := s^.size;
        t^.Align := QWord(1) shl s^.align;
        ty := s^.flags and SECTION_TYPE;
        t^.Zerofill := (ty = S_ZEROFILL) or (ty = S_GB_ZEROFILL) or (ty = S_THREAD_LOCAL_ZEROFILL);
        if not t^.Zerofill then t^.Data := o^.Buf + s^.offset;
        if ((s^.flags and S_ATTR_DEBUG) <> 0) or (CStr16(s^.segname) = '__DWARF') or (CStr16(s^.segname) = '__LD') or (CStr16(s^.sectname) = '__eh_frame') then t^.Kind := 0
        else if (s^.flags and S_ATTR_PURE_INSTRUCTIONS) <> 0 then t^.Kind := K_CODE
        else t^.Kind := K_DATA;
        addrs[High(addrs)] := s^.addr;
        relInfo[High(relInfo)].off := s^.reloff;
        relInfo[High(relInfo)].n := s^.nreloc;
        Inc(s);
      end;
    end;
    lc := PLoadCmd(PByte(lc) + lc^.cmdsize);
  end;
  if st = nil then
  begin
    Say('error ' + o^.Path + ' has no symbol table');
    Exit;
  end;
  nl := PNList64(o^.Buf + st^.symoff);
  strs := PChar(o^.Buf + st^.stroff);
  SetLength(o^.Sym, st^.nsyms);
  for i := 0 to st^.nsyms - 1 do
  begin
    sym := @o^.Sym[i];
    sym^.Name := MachName(strs + nl[i].n_strx);
    sym^.Sect := -1;
    if (nl[i].n_type and N_STAB) <> 0 then Continue;
    sym^.Ext := (nl[i].n_type and (N_EXT or N_PEXT)) <> 0;
    if ((nl[i].n_type and N_TYPE) = N_SECT) and (nl[i].n_sect >= 1) and (nl[i].n_sect <= Length(o^.Sect)) then
    begin
      sym^.Defined := True;
      sym^.Sect := nl[i].n_sect - 1;
      sym^.Value := nl[i].n_value - addrs[sym^.Sect];
      sym^.Kind := o^.Sect[sym^.Sect].Kind;
      AddDefined(o, i);
    end;
  end;
  for i := 0 to High(o^.Sect) do
  begin
    t := @o^.Sect[i];
    if (t^.Kind = 0) or (relInfo[i].n = 0) then Continue;
    raw := PRelInfo(o^.Buf + relInfo[i].off);
    nraw := relInfo[i].n;
    pending := 0;
    k := 0;
    while k < nraw do
    begin
      w := raw[k].w;
      symnum := w and $ffffff;
      len := (w shr 25) and 3;
      ext := (w shr 27) and 1;
      rty := w shr 28;
      FillChar(r, SizeOf(r), 0);
      r.Off := LongWord(raw[k].r_address);
      r.Sym := -1;
      r.Sect := -1;
      if rty = 10 then   // ARM64_RELOC_ADDEND: for the relocation that follows
      begin
        pending := SarLongint(LongInt(symnum shl 8), 8);
        Inc(k);
        Continue;
      end;
      if ext = 1 then r.Sym := symnum else r.Sect := LongInt(symnum) - 1;
      case rty of
        0, 1:   // UNSIGNED, SUBTRACTOR: the addend is in the bytes
          begin
            if t^.Zerofill then stored := 0
            else if len = 3 then stored := PInt64(t^.Data + r.Off)^
            else stored := PLongInt(t^.Data + r.Off)^;
            if rty = 0 then
            begin
              if len = 3 then r.Kind := rkAbs64 else r.Kind := rkAbs32;
              if ext = 1 then r.Addend := stored
              else if (r.Sect >= 0) and (r.Sect < Length(addrs)) then
              begin
                r.Addend := stored - Int64(addrs[r.Sect]);
                r.TOff := r.Addend;
                r.HasTOff := True;
              end
              else r.Kind := rkUnsupported;
            end
            else
            begin
              if (k + 1 >= nraw) or ((raw[k + 1].w shr 28) <> 0) or (((raw[k + 1].w shr 27) and 1) = 0) or (ext = 0) then
              begin
                Say('error ' + o^.UnitName + ': malformed subtractor relocation');
                Exit;
              end;
              if len = 3 then r.Kind := rkSub64 else r.Kind := rkSub32;
              r.Sym2 := raw[k + 1].w and $ffffff;
              r.Addend := stored;
              Inc(k);
            end;
          end;
        2: r.Kind := rkBranch26;
        3: r.Kind := rkPage21;
        4: r.Kind := rkPageOff12;
        5: r.Kind := rkGotPage21;
        6: r.Kind := rkGotPageOff12;
        7: if ((w shr 24) and 1) = 1 then r.Kind := rkGotPcrel32 else r.Kind := rkGotAbs64;
      else
        r.Kind := rkUnsupported;
      end;
      if (rty >= 2) then
      begin
        r.Addend := pending;
        if ext = 0 then r.Kind := rkUnsupported;
      end;
      if r.Kind = rkUnsupported then r.Sym2 := rty;
      pending := 0;
      AddReloc(t^, r);
      Inc(k);
    end;
  end;
  FinishObj(o);
  Result := True;
end;
{$endif}

// ---------------------------------------------------------------- ELF
type
  TElfEhdr = packed record
    e_ident: array[0..15] of Byte;
    e_type, e_machine: Word;
    e_version: LongWord;
    e_entry, e_phoff, e_shoff: QWord;
    e_flags: LongWord;
    e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx: Word;
  end;
  PElfEhdr = ^TElfEhdr;
  TElfShdr = packed record
    sh_name, sh_type: LongWord;
    sh_flags, sh_addr, sh_offset, sh_size: QWord;
    sh_link, sh_info: LongWord;
    sh_addralign, sh_entsize: QWord;
  end;
  PElfShdr = ^TElfShdr;
  TElfPhdr = packed record
    p_type, p_flags: LongWord;
    p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align: QWord;
  end;
  PElfPhdr = ^TElfPhdr;
  TElfSym = packed record
    st_name: LongWord;
    st_info, st_other: Byte;
    st_shndx: Word;
    st_value, st_size: QWord;
  end;
  PElfSym = ^TElfSym;
  TElfRela = packed record r_offset, r_info: QWord; r_addend: Int64; end;
  PElfRela = ^TElfRela;
const
  ET_REL = 1;
  ET_EXEC = 2;
  ET_DYN = 3;
  EM_AARCH64 = 183;
  EM_X86_64 = 62;
{$ifdef cpuaarch64}
  EM_HOST = EM_AARCH64;
{$else}
  EM_HOST = EM_X86_64;
{$endif}
  SHT_SYMTAB = 2;
  SHT_RELA = 4;
  SHT_NOBITS = 8;
  SHT_REL = 9;
  SHF_ALLOC = 2;
  SHF_EXECINSTR = 4;
  SHF_TLS = $400;
  STT_SECTION = 3;
  STT_FILE = 4;
  STB_GLOBAL = 1;
  STB_WEAK = 2;
  SHN_LORESERVE = $ff00;
  PT_LOAD = 1;
  PT_TLS = 7;
  PF_X = 1;

function ElfOk(o: PObj; want: Word): Boolean;
var
  eh: PElfEhdr;
begin
  eh := PElfEhdr(o^.Buf);
  Result := (o^.BufSize >= SizeOf(TElfEhdr)) and (eh^.e_ident[0] = $7f) and (eh^.e_ident[1] = Ord('E')) and (eh^.e_ident[2] = Ord('L')) and (eh^.e_ident[3] = Ord('F'))
    and (eh^.e_ident[4] = 2) and (eh^.e_ident[5] = 1) and (eh^.e_machine = EM_HOST) and ((want = 0) or (eh^.e_type = want));
end;

// $x and $d mark where code and data start inside a section (aarch64 mapping symbols).
function IsMappingSymbol(const n: AnsiString): Boolean;
begin
  Result := (Length(n) >= 2) and (n[1] = '$') and (n[2] in ['x', 'd']) and ((Length(n) = 2) or (n[3] = '.'));
end;

{$ifdef cpux86_64}
// data: the section's bytes, to tell a branch's rel32 from a rip-relative operand: a call or
// jmp (e8, e9) or a jcc (0f 80..8f) comes right before it, and no ModRM byte of a
// rip-relative operand has those values.
function ElfRelKind(ty: LongWord; data: PByte; off: QWord): TRelKind;
var
  isBranch: Boolean;
begin
  isBranch := (data <> nil) and (off >= 1) and ((data[off - 1] in [$e8, $e9]) or ((off >= 2) and (data[off - 2] = $0f) and (data[off - 1] in [$80..$8f])));
  case ty of
    1: Result := rkAbs64;            // R_X86_64_64
    2, 4: if isBranch then Result := rkBranch32 else Result := rkPrel32;   // PC32, PLT32
    9, 41, 42: Result := rkGotPcrel32;   // GOTPCREL, GOTPCRELX, REX_GOTPCRELX
    10: Result := rkAbs32;           // 32
    11: Result := rkAbs32S;          // 32S
    24: Result := rkPrel64;          // PC64
    23: Result := rkTpOff32;         // TPOFF32 (local exec)
    18: Result := rkTpOff64;         // TPOFF64
  else
    Result := rkUnsupported;
  end;
end;
{$else}
function ElfRelKind(ty: LongWord; data: PByte; off: QWord): TRelKind;
begin
  case ty of
    257: Result := rkAbs64;          // R_AARCH64_ABS64
    258: Result := rkAbs32;          // ABS32
    260: Result := rkPrel64;         // PREL64
    261: Result := rkPrel32;         // PREL32
    282, 283: Result := rkBranch26;  // JUMP26, CALL26
    275, 276: Result := rkPage21;    // ADR_PREL_PG_HI21(_NC)
    277, 278, 284, 285, 286, 299: Result := rkPageOff12;   // ADD_ABS_LO12_NC, LDST{8,16,32,64,128}_ABS_LO12_NC
    311: Result := rkGotPage21;      // ADR_GOT_PAGE
    312: Result := rkGotPageOff12;   // LD64_GOT_LO12_NC
    549: Result := rkTprelHi12;      // TLSLE_ADD_TPREL_HI12
    550, 551: Result := rkTprelLo12; // TLSLE_ADD_TPREL_LO12(_NC)
  else
    Result := rkUnsupported;
  end;
end;
{$endif}

function ParseElfObject(o: PObj): Boolean;
var
  eh: PElfEhdr;
  sh: PElfShdr;
  shstr: PChar;
  i, j, n: SizeInt;
  t: PSect;
  name: AnsiString;
  symtab: PElfShdr;
  syms: PElfSym;
  strs: PChar;
  nsym: SizeInt;
  sym: POSym;
  isSect: array of LongInt;   // a section symbol: the section it stands for, else -1
  ra: PElfRela;
  r: TReloc;
  si: QWord;
  typ, bind: Byte;
begin
  Result := False;
  if not ElfOk(o, ET_REL) then
  begin
    Say('error ' + o^.Path + ' is not an aarch64 ELF object');
    Exit;
  end;
  eh := PElfEhdr(o^.Buf);
  sh := PElfShdr(o^.Buf + eh^.e_shoff);
  shstr := PChar(o^.Buf + sh[eh^.e_shstrndx].sh_offset);
  SetLength(o^.Sect, eh^.e_shnum);
  symtab := nil;
  for i := 0 to eh^.e_shnum - 1 do
  begin
    t := @o^.Sect[i];
    name := PChar(shstr + sh[i].sh_name);
    t^.Name := name;
    t^.Size := sh[i].sh_size;
    t^.Align := sh[i].sh_addralign;
    if t^.Align = 0 then t^.Align := 1;
    t^.Zerofill := sh[i].sh_type = SHT_NOBITS;
    if not t^.Zerofill then t^.Data := o^.Buf + sh[i].sh_offset;
    if sh[i].sh_type = SHT_SYMTAB then symtab := @sh[i];
    if ((sh[i].sh_flags and SHF_ALLOC) = 0) or StartsWith(name, '.debug') or (name = '.eh_frame') then t^.Kind := 0
    else if (sh[i].sh_flags and SHF_TLS) <> 0 then t^.Kind := K_TLS
    else if (sh[i].sh_flags and SHF_EXECINSTR) <> 0 then t^.Kind := K_CODE
    else t^.Kind := K_DATA;
  end;
  if symtab = nil then
  begin
    Say('error ' + o^.Path + ' has no symbol table');
    Exit;
  end;
  syms := PElfSym(o^.Buf + symtab^.sh_offset);
  strs := PChar(o^.Buf + sh[symtab^.sh_link].sh_offset);
  nsym := symtab^.sh_size div SizeOf(TElfSym);
  SetLength(o^.Sym, nsym);
  SetLength(isSect, nsym);
  for i := 0 to nsym - 1 do
  begin
    sym := @o^.Sym[i];
    sym^.Name := PChar(strs + syms[i].st_name);
    sym^.Sect := -1;
    isSect[i] := -1;
    typ := syms[i].st_info and 15;
    bind := syms[i].st_info shr 4;
    if typ = STT_SECTION then
    begin
      isSect[i] := syms[i].st_shndx;
      Continue;
    end;
    if (typ = STT_FILE) or IsMappingSymbol(sym^.Name) then Continue;
    sym^.Ext := (bind = STB_GLOBAL) or (bind = STB_WEAK);
    if (syms[i].st_shndx <> 0) and (syms[i].st_shndx < SHN_LORESERVE) and (syms[i].st_shndx < eh^.e_shnum) then
    begin
      if (o^.Sect[syms[i].st_shndx].Kind = 0) or (sym^.Name = '') then Continue;
      sym^.Defined := True;
      sym^.Sect := syms[i].st_shndx;
      sym^.Value := syms[i].st_value;
      sym^.Kind := o^.Sect[sym^.Sect].Kind;
      AddDefined(o, i);
    end;
  end;
  for i := 0 to eh^.e_shnum - 1 do
  begin
    if (sh[i].sh_type <> SHT_RELA) and (sh[i].sh_type <> SHT_REL) then Continue;
    j := sh[i].sh_info;
    if (j <= 0) or (j >= eh^.e_shnum) or (o^.Sect[j].Kind = 0) then Continue;
    if sh[i].sh_type = SHT_REL then
    begin
      Say('error ' + o^.UnitName + ': relocations without addends (REL) are not handled');
      Exit;
    end;
    ra := PElfRela(o^.Buf + sh[i].sh_offset);
    for n := 0 to sh[i].sh_size div SizeOf(TElfRela) - 1 do
    begin
      FillChar(r, SizeOf(r), 0);
      r.Off := ra[n].r_offset;
      r.Kind := ElfRelKind(ra[n].r_info and $ffffffff, o^.Sect[j].Data, ra[n].r_offset);
      if r.Kind = rkUnsupported then r.Sym2 := LongInt(ra[n].r_info and $ffffffff);
      r.Addend := ra[n].r_addend;
      si := ra[n].r_info shr 32;
      r.Sym := -1;
      r.Sect := -1;
      if (si < QWord(nsym)) and (isSect[si] >= 0) then r.Sect := isSect[si]
      else r.Sym := LongInt(si);
      if (r.Sym < 0) and (r.Kind in [rkAbs64, rkAbs32, rkAbs32S]) then
      begin
        r.TOff := r.Addend;
        r.HasTOff := True;
      end;
      AddReloc(o^.Sect[j], r);
    end;
  end;
  FinishObj(o);
  Result := True;
end;

// ---------------------------------------------------------------- COFF (Windows)
{$ifdef windows}
type
  TCoffHeader = packed record
    Machine, NumberOfSections: Word;
    TimeDateStamp, PointerToSymbolTable, NumberOfSymbols: LongWord;
    SizeOfOptionalHeader, Characteristics: Word;
  end;
  PCoffHeader = ^TCoffHeader;
  TCoffSection = packed record
    Name: array[0..7] of Char;
    VirtualSize, VirtualAddress, SizeOfRawData, PointerToRawData, PointerToRelocations, PointerToLinenumbers: LongWord;
    NumberOfRelocations, NumberOfLinenumbers: Word;
    Characteristics: LongWord;
  end;
  PCoffSection = ^TCoffSection;
  TCoffSymbol = packed record
    Name: array[0..7] of Char;
    Value: LongWord;
    SectionNumber: SmallInt;
    Typ: Word;
    StorageClass, NumberOfAuxSymbols: Byte;
  end;
  PCoffSymbol = ^TCoffSymbol;
  TCoffReloc = packed record
    VirtualAddress, SymbolTableIndex: LongWord;
    Typ: Word;
  end;
  PCoffReloc = ^TCoffReloc;
const
  IMAGE_FILE_MACHINE_AMD64 = $8664;
  IMAGE_SCN_CNT_CODE = $20;
  IMAGE_SCN_CNT_UNINITIALIZED_DATA = $80;
  IMAGE_SCN_LNK_INFO = $200;
  IMAGE_SCN_LNK_REMOVE = $800;
  IMAGE_SCN_LNK_NRELOC_OVFL = $01000000;
  IMAGE_SCN_MEM_DISCARDABLE = $02000000;
  IMAGE_SCN_MEM_EXECUTE = $20000000;
  IMAGE_SYM_CLASS_EXTERNAL = 2;
  IMAGE_SYM_CLASS_STATIC = 3;
  IMAGE_SYM_CLASS_FILE = 103;
  IMAGE_SYM_CLASS_WEAK_EXTERNAL = 105;

// The name a section without symbols stands under (see ParseCoff), in objects and in the map.
function SectionSymbolName(const sect: AnsiString): AnsiString;
var
  i: SizeInt;
begin
  Result := sect;
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then Result[i] := Chr(Ord(Result[i]) + 32);
  Result := '@sect:' + Result;
end;

// A name of 8 characters or fewer is in place; a longer one is in the string table.
function CoffSymName(sym: PCoffSymbol; strtab: PChar): AnsiString;
begin
  if PLongWord(@sym^.Name[0])^ = 0 then Result := PChar(strtab + PLongWord(@sym^.Name[4])^)
  else
  begin
    Result := '';
    SetString(Result, PChar(@sym^.Name[0]), 8);
    Result := PChar(Result);   // up to the first #0
  end;
end;

function CoffSectName(sec: PCoffSection; strtab: PChar): AnsiString;
var
  n, code: LongInt;
begin
  SetString(Result, PChar(@sec^.Name[0]), 8);
  Result := PChar(Result);
  if (Length(Result) > 1) and (Result[1] = '/') then
  begin
    Val(Copy(Result, 2, 7), n, code);
    if code = 0 then Result := PChar(strtab + n);
  end;
end;

function ParseCoff(o: PObj): Boolean;
var
  hdr: PCoffHeader;
  secs: PCoffSection;
  syms: PCoffSymbol;
  strtab: PChar;
  i, k, nrel, first: LongInt;
  t: PSect;
  ch, al: LongWord;
  isSect: array of LongInt;
  sym: POSym;
  cs: PCoffSymbol;
  rl: PCoffReloc;
  r: TReloc;
  stored: Int64;
begin
  Result := False;
  hdr := PCoffHeader(o^.Buf);
  if (o^.BufSize < SizeOf(TCoffHeader)) or (hdr^.Machine <> IMAGE_FILE_MACHINE_AMD64) or (hdr^.SizeOfOptionalHeader <> 0) then
  begin
    Say('error ' + o^.Path + ' is not an x86-64 COFF object');
    Exit;
  end;
  secs := PCoffSection(o^.Buf + SizeOf(TCoffHeader));
  syms := PCoffSymbol(o^.Buf + hdr^.PointerToSymbolTable);
  strtab := PChar(o^.Buf + hdr^.PointerToSymbolTable + hdr^.NumberOfSymbols * SizeOf(TCoffSymbol));
  SetLength(o^.Sect, hdr^.NumberOfSections);
  for i := 0 to hdr^.NumberOfSections - 1 do
  begin
    t := @o^.Sect[i];
    ch := secs[i].Characteristics;
    t^.Name := CoffSectName(@secs[i], strtab);
    t^.Size := secs[i].SizeOfRawData;
    al := (ch shr 20) and $f;
    if al = 0 then t^.Align := 16 else t^.Align := QWord(1) shl (al - 1);
    t^.Zerofill := (ch and IMAGE_SCN_CNT_UNINITIALIZED_DATA) <> 0;
    if not t^.Zerofill and (secs[i].PointerToRawData <> 0) then t^.Data := o^.Buf + secs[i].PointerToRawData;
    if ((ch and (IMAGE_SCN_LNK_REMOVE or IMAGE_SCN_LNK_INFO or IMAGE_SCN_MEM_DISCARDABLE)) <> 0) or StartsWith(t^.Name, '.debug') then t^.Kind := 0
    else if (ch and (IMAGE_SCN_MEM_EXECUTE or IMAGE_SCN_CNT_CODE)) <> 0 then t^.Kind := K_CODE
    else t^.Kind := K_DATA;
  end;
  // room for one stand-in symbol per section (below): the array must not move once the
  // name map points into it
  SetLength(o^.Sym, hdr^.NumberOfSymbols + hdr^.NumberOfSections);
  SetLength(isSect, hdr^.NumberOfSymbols);
  for i := 0 to High(isSect) do isSect[i] := -1;
  i := 0;
  while i < LongInt(hdr^.NumberOfSymbols) do
  begin
    cs := @syms[i];
    sym := @o^.Sym[i];
    sym^.Sect := -1;
    if cs^.StorageClass <> IMAGE_SYM_CLASS_FILE then
    begin
      sym^.Name := CoffSymName(cs, strtab);
      if (cs^.StorageClass = IMAGE_SYM_CLASS_STATIC) and (cs^.Value = 0) and (cs^.NumberOfAuxSymbols > 0) and (cs^.SectionNumber > 0)
        and (cs^.SectionNumber <= hdr^.NumberOfSections) and (sym^.Name = CoffSectName(@secs[cs^.SectionNumber - 1], strtab)) then
      begin
        isSect[i] := cs^.SectionNumber - 1;   // the section itself
        sym^.Name := '';
      end
      else if (cs^.SectionNumber > 0) and (cs^.SectionNumber <= hdr^.NumberOfSections) then
      begin
        if (o^.Sect[cs^.SectionNumber - 1].Kind <> 0) and (sym^.Name <> '') then
        begin
          sym^.Defined := True;
          sym^.Ext := cs^.StorageClass = IMAGE_SYM_CLASS_EXTERNAL;
          sym^.Sect := cs^.SectionNumber - 1;
          sym^.Value := cs^.Value;
          sym^.Kind := o^.Sect[sym^.Sect].Kind;
          AddDefined(o, i);
        end;
      end
      else if cs^.SectionNumber = 0 then sym^.Ext := True   // undefined
      else sym^.Name := '';   // absolute or debugging
    end;
    Inc(i, 1 + cs^.NumberOfAuxSymbols);
  end;
  // fpc 3.2 gives an implementation-section variable no symbol at all, only a section of its
  // own named after it (.bss.n_u_$u_$$_hidden). Such a section stands for a variable named
  // after the section; the program's map file says where the linker put it.
  for i := 0 to hdr^.NumberOfSections - 1 do
  begin
    t := @o^.Sect[i];
    if (t^.Kind <> K_DATA) or (t^.Size = 0) or (Pos('$', t^.Name) = 0) then Continue;
    k := 0;
    while (k < LongInt(hdr^.NumberOfSymbols)) and not (o^.Sym[k].Defined and (o^.Sym[k].Sect = i)) do Inc(k);
    if k < LongInt(hdr^.NumberOfSymbols) then Continue;   // it has symbols of its own
    sym := @o^.Sym[hdr^.NumberOfSymbols + i];
    sym^.Name := SectionSymbolName(t^.Name);
    sym^.Defined := True;
    sym^.Ext := True;
    sym^.Sect := i;
    sym^.Value := 0;
    sym^.Kind := K_DATA;
    AddDefined(o, hdr^.NumberOfSymbols + i);
  end;
  for i := 0 to hdr^.NumberOfSections - 1 do
  begin
    t := @o^.Sect[i];
    if (t^.Kind = 0) or (secs[i].NumberOfRelocations = 0) or (t^.Data = nil) then Continue;
    rl := PCoffReloc(o^.Buf + secs[i].PointerToRelocations);
    nrel := secs[i].NumberOfRelocations;
    first := 0;
    if (secs[i].Characteristics and IMAGE_SCN_LNK_NRELOC_OVFL) <> 0 then
    begin
      nrel := rl[0].VirtualAddress;   // more than 65535: the count is in the first entry
      first := 1;
    end;
    for k := first to nrel - 1 do
    begin
      if rl[k].Typ = 0 then Continue;   // IMAGE_REL_AMD64_ABSOLUTE: nothing to do
      FillChar(r, SizeOf(r), 0);
      r.Off := rl[k].VirtualAddress;
      r.Sym := -1;
      r.Sect := -1;
      // COFF keeps the addend in the bytes
      if rl[k].Typ = 1 then stored := PInt64(t^.Data + r.Off)^ else stored := PLongInt(t^.Data + r.Off)^;
      if (rl[k].SymbolTableIndex < hdr^.NumberOfSymbols) and (isSect[rl[k].SymbolTableIndex] >= 0) then
      begin
        r.Sect := isSect[rl[k].SymbolTableIndex];
        r.TOff := stored;
        r.HasTOff := True;
      end
      else r.Sym := rl[k].SymbolTableIndex;
      case rl[k].Typ of
        1: begin r.Kind := rkAbs64; r.Addend := stored; end;    // ADDR64
        2: begin r.Kind := rkAbs32; r.Addend := stored; end;    // ADDR32
        3: begin r.Kind := rkRva32; r.Addend := stored; end;    // ADDR32NB
        4..9:                                                    // REL32, REL32_1 .. REL32_5
          begin
            // field = target - (end of the field + k): the bias folds into the addend
            r.Addend := stored - 4 - (rl[k].Typ - 4);
            if (r.Off >= 1) and ((t^.Data[r.Off - 1] in [$e8, $e9]) or ((r.Off >= 2) and (t^.Data[r.Off - 2] = $0f) and (t^.Data[r.Off - 1] in [$80..$8f]))) then
              r.Kind := rkBranch32
            else r.Kind := rkPrel32;
          end;
      else
        r.Kind := rkUnsupported;
        r.Sym2 := rl[k].Typ;
      end;
      AddReloc(t^, r);
    end;
  end;
  FinishObj(o);
  Result := True;
end;
{$endif}

function ObjParse(const path: AnsiString): PObj;
var
  o: PObj;
  b, e: SizeInt;
  ok: Boolean;
begin
  Result := nil;
  New(o);
  FillChar(o^, SizeOf(TObj), 0);
  o^.Path := path;
  if not ReadWholeFile(path, o^.Buf, o^.BufSize) then
  begin
    Say('error cannot read ' + path);
    Dispose(o);
    Exit;
  end;
  b := Length(path);
  while (b > 0) and not (path[b] in ['/', '\']) do Dec(b);
  o^.UnitName := Copy(path, b + 1, Length(path));
  e := Length(o^.UnitName);
  while (e > 0) and (o^.UnitName[e] <> '.') do Dec(e);
  if e > 0 then SetLength(o^.UnitName, e - 1);
{$if defined(darwin)}
  ok := ParseMachO(o);
{$elseif defined(windows)}
  ok := ParseCoff(o);
{$else}
  ok := ParseElfObject(o);
{$endif}
  if not ok then
  begin
    ObjFree(o);
    Exit;
  end;
  Result := o;
end;

// ================================================================ comparing versions
function SymBytes(o: PObj; s: POSym): PByte;
begin
  if o^.Sect[s^.Sect].Zerofill then Result := nil
  else Result := o^.Sect[s^.Sect].Data + s^.Value;
end;

// First relocation of section t at or after offset off.
function FirstRel(const t: TSect; off: QWord): SizeInt;
var
  lo, hi, mid: SizeInt;
begin
  lo := 0;
  hi := Length(t.Rel);
  while lo < hi do
  begin
    mid := (lo + hi) shr 1;
    if t.Rel[mid].Off < off then lo := mid + 1 else hi := mid;
  end;
  Result := lo;
end;

function HasRelocs(o: PObj; s: POSym): Boolean;
var
  i: SizeInt;
begin
  i := FirstRel(o^.Sect[s^.Sect], s^.Value);
  Result := (i < Length(o^.Sect[s^.Sect].Rel)) and (o^.Sect[s^.Sect].Rel[i].Off < s^.Value + s^.Size);
end;

// Unwind tables describe one version of the code: the new code needs its own, never the
// program's.
function IsUnwindSection(const name: AnsiString): Boolean;
begin
  Result := StartsWith(name, '.pdata') or StartsWith(name, '.xdata') or (name = '.eh_frame');
end;

function IsAnon(const n: AnsiString): Boolean;
begin
  Result := Contains(n, '_$$_def0') or Contains(n, '$$fpclocal$') or Contains(n, '_$$_Ld') or StartsWith(n, '.L');
end;

function IsAnonTarget(o: PObj; i: LongInt): Boolean;
begin
  Result := o^.Sym[i].Defined and ((not o^.Sym[i].Ext) or IsAnon(o^.Sym[i].Name));
end;

// For a pc-relative reference: the symbol it means. fpc's COFF writer folds the length of an
// immediate that follows the address into the stored offset (add dword [rip+X], 1 stores
// X-1 with a plain REL32), so an offset just before a symbol means that symbol.
function CoveringRel(o: PObj; const r: TReloc; off: Int64): LongInt; forward;

// The defined symbol that covers an offset of a section, or -1. Sizes run up to the next
// symbol, so it is the last one in (section, value) order at or before the offset.
function Covering(o: PObj; sect: LongInt; off: Int64): LongInt;
var
  lo, hi, mid: SizeInt;
  s: POSym;
begin
  Result := -1;
  lo := 0;
  hi := Length(o^.Order);
  while lo < hi do
  begin
    mid := (lo + hi) shr 1;
    s := @o^.Sym[o^.Order[mid]];
    if (s^.Sect < sect) or ((s^.Sect = sect) and (Int64(s^.Value) <= off)) then lo := mid + 1 else hi := mid;
  end;
  if lo = 0 then Exit;
  s := @o^.Sym[o^.Order[lo - 1]];
  if (s^.Sect = sect) and ((off < Int64(s^.Value + s^.Size)) or ((s^.Size = 0) and (off = Int64(s^.Value)))) then Result := o^.Order[lo - 1];
end;

function CoveringRel(o: PObj; const r: TReloc; off: Int64): LongInt;
var
  d: LongInt;
begin
  Result := Covering(o, r.Sect, off);
  if (Result < 0) and (r.Kind in [rkPrel32, rkBranch32]) then
    for d := 1 to 4 do
    begin
      Result := Covering(o, r.Sect, off + d);
      if Result >= 0 then Exit;
    end;
end;

function SymDigest(o: PObj; s: POSym; depth: LongInt): QWord; forward;

function TargetKey(o: PObj; symnum: LongInt; addend: Int64; depth: LongInt): QWord;
var
  t, bs: POSym;
  b: PByte;
  len: Int64;
  n: AnsiString;
begin
  t := @o^.Sym[symnum];
  n := t^.Name;
  if IsAnonTarget(o, symnum) and (depth < 3) then
  begin
    // A string constant is referenced 16 bytes into its header; its length is the word before.
    // Several constants can share one symbol, so hash the one that is meant.
    b := SymBytes(o, t);
    if (b <> nil) and not HasRelocs(o, t) then
    begin
      if (addend >= 16) and (QWord(addend) <= t^.Size) then
      begin
        len := PInt64(b + addend - 8)^;
        if (len >= 0) and (QWord(addend + len) <= t^.Size) then Exit(Fnv(b + addend - 16, 16 + len, FNV0) xor QWord($9e3779b97f4a7c15));
      end;
      if (addend >= 0) and (QWord(addend) < t^.Size) then Exit(Fnv(b + addend, t^.Size - QWord(addend), FNV0) xor QWord($3c6ef372fe94f82b));
    end;
    Exit(SymDigest(o, t, depth + 1) xor QWord($9e3779b97f4a7c15) xor QWord(addend));
  end;
  if EndsWith(n, '$indirect') and Contains(n, '_$$_def0') and (depth < 3) then
  begin
    bs := MapGet(o^.ByName, Copy(n, 1, Length(n) - 9));
    if bs <> nil then Exit(SymDigest(o, bs, depth + 1) xor QWord($51ed270b35ae1f3b));
  end;
  Result := FnvStr(n);
end;

// What a relocation refers to, as a key that does not depend on how the compiler numbered
// anonymous things; named tells whether its addend is part of the identity.
function RelKey(o: PObj; const r: TReloc; depth: LongInt; out named: Boolean; out addend: Int64): QWord;
var
  c: LongInt;
  t: PSect;
  off: Int64;
begin
  addend := r.Addend;
  if r.Sym >= 0 then
  begin
    named := not IsAnonTarget(o, r.Sym);
    Exit(TargetKey(o, r.Sym, r.Addend, depth));
  end;
  named := False;
  if (r.Sect < 0) or (r.Sect > High(o^.Sect)) then Exit(QWord(r.Sect) xor QWord(r.Addend));
  off := r.Addend;
  if r.HasTOff then off := r.TOff;
  c := CoveringRel(o, r, off);
  if c >= 0 then
  begin
    addend := off - Int64(o^.Sym[c].Value);
    named := not IsAnonTarget(o, c);
    Exit(TargetKey(o, c, addend, depth));
  end;
  t := @o^.Sect[r.Sect];
  if (t^.Data <> nil) and (Length(t^.Rel) = 0) and (off >= 0) and (QWord(off) < t^.Size) then
    Exit(Fnv(t^.Data + off, t^.Size - QWord(off), FNV0) xor QWord($3c6ef372fe94f82b));
  Result := FnvStr(t^.Name) xor QWord(off);
end;

function RelWidth(k: TRelKind): QWord;
begin
  case k of
    rkAbs64, rkSub64, rkGotAbs64: Result := 8;
    rkAbs32, rkSub32, rkAbs32S, rkRva32, rkPrel32, rkBranch32: Result := 4;   // COFF keeps addends in these bytes
  else
    Result := 0;
  end;
end;

// A digest of a symbol's bytes and of what its relocations refer to. Names the compiler
// numbers (anonymous types, local constants) are replaced by a digest of their content,
// so that an unrelated edit that renumbers or moves them does not look like a change.
// Bytes a pointer relocation fills are left out: one object format keeps the addend there.
function SymDigest(o: PObj; s: POSym; depth: LongInt): QWord;
var
  t: PSect;
  h, k, lo, hi, at, w: QWord;
  b: PByte;
  i: SizeInt;
  off, ty: LongWord;
  named, named2: Boolean;
  a, a2: Int64;
  r2: TReloc;
begin
  t := @o^.Sect[s^.Sect];
  h := Fnv(PByte(@s^.Size), 8, FNV0);
  b := SymBytes(o, s);
  lo := s^.Value;
  hi := lo + s^.Size;
  at := lo;
  i := FirstRel(t^, lo);
  while (i < Length(t^.Rel)) and (t^.Rel[i].Off < hi) do
  begin
    off := LongWord(t^.Rel[i].Off - lo);
    ty := LongWord(Ord(t^.Rel[i].Kind));
    w := RelWidth(t^.Rel[i].Kind);
    if (w > 0) and (b <> nil) and (t^.Rel[i].Off >= at) then
    begin
      if t^.Rel[i].Off > at then h := Fnv(b + (at - lo), t^.Rel[i].Off - at, h);
      at := t^.Rel[i].Off + w;
      if at > hi then at := hi;
    end;
    h := Fnv(PByte(@off), 4, h);
    h := Fnv(PByte(@ty), 4, h);
    k := RelKey(o, t^.Rel[i], depth, named, a);
    if named then h := Fnv(PByte(@a), 8, h);
    h := Fnv(PByte(@k), 8, h);
    if t^.Rel[i].Kind in [rkSub64, rkSub32] then
    begin
      r2 := t^.Rel[i];
      r2.Sym := r2.Sym2;
      r2.Addend := 0;
      k := RelKey(o, r2, depth, named2, a2);
      h := Fnv(PByte(@k), 8, h);
    end;
    Inc(i);
  end;
  if (b <> nil) and (hi > at) then h := Fnv(b + (at - lo), hi - at, h);
  Result := h;
end;

// The name of the pointer target at an offset inside a symbol.
function RelocTargetAt(o: PObj; s: POSym; off: QWord): AnsiString;
var
  t: PSect;
  i: SizeInt;
  c: LongInt;
begin
  Result := '';
  t := @o^.Sect[s^.Sect];
  i := FirstRel(t^, s^.Value + off);
  while (i < Length(t^.Rel)) and (t^.Rel[i].Off = s^.Value + off) do
  begin
    if t^.Rel[i].Kind = rkAbs64 then
    begin
      if t^.Rel[i].Sym >= 0 then Exit(o^.Sym[t^.Rel[i].Sym].Name);
      c := Covering(o, t^.Rel[i].Sect, t^.Rel[i].Addend);
      if c >= 0 then Exit(o^.Sym[c].Name);
    end;
    Inc(i);
  end;
end;

// WORKER_$$_STEP$LONGINT$$ANSISTRING -> WORKER.STEP(LONGINT):ANSISTRING (good enough to read)
function Pretty(const name: AnsiString): AnsiString;
const
  Pre: array[0..6] of AnsiString = ('VMT_$', 'RTTI_$', 'INIT_$', 'U_$', 'TC_$', 'RESSTR_$', 'THREADVARLIST_$');
var
  p: AnsiString;
  i: LongInt;
  seen: Boolean;
begin
  p := name;
  if StartsWith(p, '@sect:') then
  begin
    // @sect:.bss.n_u_$u_$$_hidden -> U_$U_$$_HIDDEN
    i := Pos('.n_', p);
    if i > 0 then Delete(p, 1, i + 2) else Delete(p, 1, 6);
    p := UpCase(p);
  end;
  for i := 0 to High(Pre) do
    if StartsWith(p, Pre[i]) and (Length(p) > Length(Pre[i])) and (p[Length(Pre[i]) + 1] <> '$') then
    begin
      Delete(p, 1, Length(Pre[i]));
      Break;
    end;
  if StartsWith(p, 'P$') then Delete(p, 1, 2);
  Result := '';
  seen := False;
  i := 1;
  while i <= Length(p) do
  begin
    if Copy(p, i, 4) = '_$$_' then begin Result := Result + '.'; Inc(i, 4); Continue; end;
    if Copy(p, i, 3) = '$_$' then begin Result := Result + '.'; Inc(i, 3); Continue; end;
    if Copy(p, i, 4) = '_$__' then begin Inc(i, 4); Continue; end;
    if Copy(p, i, 2) = '$$' then
    begin
      if seen then Result := Result + ')';
      Result := Result + ':';
      seen := False;
      Inc(i, 2);
      Continue;
    end;
    if p[i] = '$' then
    begin
      if seen then Result := Result + ',' else Result := Result + '(';
      seen := True;
      Inc(i);
      Continue;
    end;
    Result := Result + p[i];
    Inc(i);
  end;
  if seen then Result := Result + ')';
end;

// ================================================================ the running program
type
  PHostSym = ^THostSym;
  THostSym = record Addr: QWord; Code, Tls: Boolean; end;   // Tls: Addr is the offset in the TLS segment
var
  g_slide: PtrInt;
  g_text_lo, g_text_hi, g_image_hi: QWord;
  g_host: TMap;
  g_host_pool: array of THostSym;
  g_host_built: Boolean;
  g_host_ms: Double;
  g_tls_memsz, g_tls_align: QWord;   // the executable's TLS segment
  g_page: QWord;

{$if defined(darwin)}
var
  g_mh: PMachHeader64;

procedure FindProgram;
var
  i: LongWord;
  mh: PMachHeader64;
  lc: PLoadCmd;
  sg: PSegCmd64;
  lo, hi: QWord;
begin
  for i := 0 to _dyld_image_count - 1 do
  begin
    mh := _dyld_get_image_header(i);
    if mh^.filetype = MH_EXECUTE then
    begin
      g_mh := mh;
      g_slide := _dyld_get_image_vmaddr_slide(i);
      Break;
    end;
  end;
  lc := PLoadCmd(PByte(g_mh) + SizeOf(TMachHeader64));
  for i := 1 to g_mh^.ncmds do
  begin
    if lc^.cmd = LC_SEGMENT_64 then
    begin
      sg := PSegCmd64(lc);
      if CStr16(sg^.segname) <> '__PAGEZERO' then
      begin
        lo := sg^.vmaddr + QWord(g_slide);
        hi := lo + sg^.vmsize;
        if CStr16(sg^.segname) = '__TEXT' then
        begin
          g_text_lo := lo;
          g_text_hi := hi;
        end;
        if hi > g_image_hi then g_image_hi := hi;
      end;
    end;
    lc := PLoadCmd(PByte(lc) + lc^.cmdsize);
  end;
end;

procedure BuildHostSymbols;
var
  t0: Double;
  lc: PLoadCmd;
  st: PSymtabCmd;
  sg: PSegCmd64;
  s: PSection64;
  linkedit_vm, linkedit_off: QWord;
  nsect: LongInt;
  code: array[0..255] of Boolean;
  i, j: LongWord;
  base: PByte;
  nl: PNList64;
  strs: PChar;
  name: AnsiString;
begin
  if g_host_built then Exit;
  t0 := NowMs;
  st := nil;
  linkedit_vm := 0;
  linkedit_off := 0;
  nsect := 0;
  FillChar(code, SizeOf(code), 0);
  lc := PLoadCmd(PByte(g_mh) + SizeOf(TMachHeader64));
  for i := 1 to g_mh^.ncmds do
  begin
    if lc^.cmd = LC_SYMTAB then st := PSymtabCmd(lc);
    if lc^.cmd = LC_SEGMENT_64 then
    begin
      sg := PSegCmd64(lc);
      if CStr16(sg^.segname) = '__LINKEDIT' then
      begin
        linkedit_vm := sg^.vmaddr;
        linkedit_off := sg^.fileoff;
      end;
      s := PSection64(PByte(sg) + SizeOf(TSegCmd64));
      for j := 1 to sg^.nsects do
      begin
        Inc(nsect);
        if nsect < 256 then code[nsect] := (s^.flags and S_ATTR_PURE_INSTRUCTIONS) <> 0;
        Inc(s);
      end;
    end;
    lc := PLoadCmd(PByte(lc) + lc^.cmdsize);
  end;
  if st <> nil then
  begin
    base := PByte(PtrUInt(linkedit_vm - linkedit_off + QWord(g_slide)));
    nl := PNList64(base + st^.symoff);
    strs := PChar(base + st^.stroff);
    SetLength(g_host_pool, st^.nsyms);
    for i := 0 to st^.nsyms - 1 do
    begin
      if (nl[i].n_type and N_STAB) <> 0 then Continue;
      if (nl[i].n_type and N_TYPE) <> N_SECT then Continue;
      name := MachName(strs + nl[i].n_strx);
      if name = '' then Continue;
      g_host_pool[i].Addr := nl[i].n_value + QWord(g_slide);
      g_host_pool[i].Code := code[nl[i].n_sect];
      MapPut(g_host, name, @g_host_pool[i]);
    end;
  end;
  g_host_built := True;
  g_host_ms := NowMs - t0;
end;
{$elseif defined(linux)}
var
  g_exe: TObj;   // the executable's file, read once

procedure FindProgram;
var
  eh: PElfEhdr;
  ph: PElfPhdr;
  sh: PElfShdr;
  syms: PElfSym;
  strs: PChar;
  i, n: SizeInt;
  lo, hi: QWord;
begin
  FillChar(g_exe, SizeOf(g_exe), 0);
  g_exe.Path := '/proc/self/exe';
  if not ReadWholeFile(g_exe.Path, g_exe.Buf, g_exe.BufSize) or not ElfOk(@g_exe, 0) then Exit;
  eh := PElfEhdr(g_exe.Buf);
  g_slide := 0;
  if eh^.e_type = ET_DYN then
  begin
    // position independent: the distance between where this unit's anchor is and where
    // the file says it is
    sh := PElfShdr(g_exe.Buf + eh^.e_shoff);
    for i := 0 to eh^.e_shnum - 1 do
      if sh[i].sh_type = SHT_SYMTAB then
      begin
        syms := PElfSym(g_exe.Buf + sh[i].sh_offset);
        strs := PChar(g_exe.Buf + sh[sh[i].sh_link].sh_offset);
        for n := 0 to sh[i].sh_size div SizeOf(TElfSym) - 1 do
          if AnsiString(PChar(strs + syms[n].st_name)) = 'HOTAGENT_$$_HOTANCHOR' then g_slide := PtrInt(PtrUInt(@HotAnchor)) - PtrInt(syms[n].st_value);
      end;
  end;
  ph := PElfPhdr(g_exe.Buf + eh^.e_phoff);
  for i := 0 to eh^.e_phnum - 1 do
  begin
    if ph[i].p_type = PT_TLS then
    begin
      g_tls_memsz := ph[i].p_memsz;
      g_tls_align := ph[i].p_align;
      if g_tls_align = 0 then g_tls_align := 1;
    end;
    if ph[i].p_type <> PT_LOAD then Continue;
    lo := ph[i].p_vaddr + QWord(g_slide);
    hi := lo + ph[i].p_memsz;
    if (ph[i].p_flags and PF_X) <> 0 then
    begin
      if (g_text_lo = 0) or (lo < g_text_lo) then g_text_lo := lo;
      if hi > g_text_hi then g_text_hi := hi;
    end;
    if hi > g_image_hi then g_image_hi := hi;
  end;
end;

procedure BuildHostSymbols;
var
  t0: Double;
  eh: PElfEhdr;
  sh: PElfShdr;
  syms: PElfSym;
  strs: PChar;
  i, n, cnt: SizeInt;
  name: AnsiString;
  typ: Byte;
begin
  if g_host_built then Exit;
  t0 := NowMs;
  if g_exe.Buf <> nil then
  begin
    eh := PElfEhdr(g_exe.Buf);
    sh := PElfShdr(g_exe.Buf + eh^.e_shoff);
    for i := 0 to eh^.e_shnum - 1 do
    begin
      if sh[i].sh_type <> SHT_SYMTAB then Continue;
      syms := PElfSym(g_exe.Buf + sh[i].sh_offset);
      strs := PChar(g_exe.Buf + sh[sh[i].sh_link].sh_offset);
      cnt := sh[i].sh_size div SizeOf(TElfSym);
      SetLength(g_host_pool, cnt);
      for n := 0 to cnt - 1 do
      begin
        typ := syms[n].st_info and 15;
        if (typ = STT_SECTION) or (typ = STT_FILE) or (syms[n].st_shndx = 0) or (syms[n].st_shndx >= SHN_LORESERVE) then Continue;
        name := PChar(strs + syms[n].st_name);
        if (name = '') or IsMappingSymbol(name) then Continue;
        g_host_pool[n].Addr := syms[n].st_value + QWord(g_slide);
        g_host_pool[n].Code := (sh[syms[n].st_shndx].sh_flags and SHF_EXECINSTR) <> 0;
        g_host_pool[n].Tls := (sh[syms[n].st_shndx].sh_flags and SHF_TLS) <> 0;
        if g_host_pool[n].Tls then g_host_pool[n].Addr := syms[n].st_value;   // an offset, not an address
        MapPut(g_host, name, @g_host_pool[n]);
      end;
    end;
    FreeMem(g_exe.Buf);
    g_exe.Buf := nil;
  end;
  g_host_built := True;
  g_host_ms := NowMs - t0;
end;
{$else}
// Windows: the image's headers are mapped at its base; the COFF symbol table that a link
// with -Xs- keeps is only in the file. Symbol values are offsets in their sections.
var
  g_image_base: QWord;
  g_mapnames: TMap;

procedure FindProgram;
var
  base, opt: PByte;
  pe: LongWord;
  fh: PCoffHeader;
  secs: PCoffSection;
  i: LongInt;
  lo, hi: QWord;
begin
  g_image_base := GetModuleHandleA(nil);
  base := PByte(PtrUInt(g_image_base));
  pe := PLongWord(base + $3c)^;
  fh := PCoffHeader(base + pe + 4);
  opt := base + pe + 24;
  g_slide := PtrInt(g_image_base) - PtrInt(PQWord(opt + 24)^);   // PE32+ ImageBase
  g_image_hi := g_image_base + PLongWord(opt + 56)^;              // SizeOfImage
  secs := PCoffSection(opt + fh^.SizeOfOptionalHeader);
  for i := 0 to fh^.NumberOfSections - 1 do
    if (secs[i].Characteristics and IMAGE_SCN_MEM_EXECUTE) <> 0 then
    begin
      lo := g_image_base + secs[i].VirtualAddress;
      hi := lo + secs[i].VirtualSize;
      if (g_text_lo = 0) or (lo < g_text_lo) then g_text_lo := lo;
      if hi > g_text_hi then g_text_hi := hi;
    end;
end;

// The linker's map (hotfpc links Windows programs with -Xm) lists every input section with
// its address: "<name> 0x<address> 0x<size> <object>", the name alone on the line before
// when it is long. Sections named after a variable (with a $ in the name) become host names.
var
  g_map_pool: array of THostSym;

procedure ReadMapFile(const exe: AnsiString);
var
  buf: PByte;
  size: PtrUInt;
  i, ls, le, n, k: SizeInt;
  line, prev, name, a: AnsiString;
  addr: QWord;
  code: Word;

  function Fields(const l: AnsiString; out f1, f2: AnsiString): LongInt;
  var
    j, c: SizeInt;
    parts: array[0..3] of AnsiString;
  begin
    c := 0;
    j := 1;
    while (j <= Length(l)) and (c < 4) do
    begin
      while (j <= Length(l)) and (l[j] = ' ') do Inc(j);
      if j > Length(l) then Break;
      parts[c] := '';
      while (j <= Length(l)) and (l[j] <> ' ') do
      begin
        parts[c] := parts[c] + l[j];
        Inc(j);
      end;
      Inc(c);
    end;
    Result := c;
    f1 := '';
    f2 := '';
    if c > 0 then f1 := parts[0];
    if c > 1 then f2 := parts[1];
    if (c = 4) then
    begin
      f1 := parts[0];
      f2 := parts[1];
    end;
  end;

begin
  name := exe;
  k := Length(name);
  while (k > 0) and (name[k] <> '.') and not (name[k] in ['/', '\']) do Dec(k);
  if (k > 0) and (name[k] = '.') then SetLength(name, k - 1);
  if not ReadWholeFile(name + '.map', buf, size) then Exit;
  SetLength(g_map_pool, 1024);
  n := 0;
  prev := '';
  ls := 0;
  for i := 0 to PtrInt(size) do
  begin
    if (i < PtrInt(size)) and (buf[i] <> 10) then Continue;
    le := i;
    if (le > ls) and (buf[le - 1] = 13) then Dec(le);
    SetString(line, PChar(buf + ls), le - ls);
    ls := i + 1;
    // " <name>" alone, or " <name> 0x.. 0x.. obj", or "    0x.. 0x.. obj" after a name line
    if (Length(line) > 2) and (line[1] = ' ') and (line[2] <> ' ') then
    begin
      Fields(line, name, a);
      if (Copy(a, 1, 2) = '0x') then
      begin
        prev := '';
        Val('$' + Copy(a, 3, 16), addr, code);
      end
      else
      begin
        prev := name;
        Continue;
      end;
    end
    else if (prev <> '') and (Length(line) > 2) and (line[1] = ' ') then
    begin
      Fields(line, a, name);
      name := prev;
      prev := '';
      if Copy(a, 1, 2) <> '0x' then Continue;
      Val('$' + Copy(a, 3, 16), addr, code);
    end
    else
    begin
      prev := '';
      Continue;
    end;
    if (code <> 0) or (Pos('$', name) = 0) or (addr = 0) then Continue;
    if n = Length(g_map_pool) then SetLength(g_map_pool, n * 2);
    // the pool only grows before any pointer into it is taken: pointers are taken below
    g_map_pool[n].Addr := addr + QWord(g_slide);
    g_map_pool[n].Code := False;
    g_map_pool[n].Tls := False;
    Inc(n);
    MapPut(g_mapnames, SectionSymbolName(name), Pointer(PtrUInt(n)));   // index + 1 for now
  end;
  FreeMem(buf);
  // now that the pool no longer moves: the names point at their entries
  for i := 0 to High(g_mapnames.Keys) do
    if g_mapnames.Keys[i] <> '' then
      MapPut(g_host, g_mapnames.Keys[i], @g_map_pool[PtrUInt(g_mapnames.Vals[i]) - 1]);
end;

procedure BuildHostSymbols;
var
  t0: Double;
  path: array[0..1023] of Char;
  buf: PByte;
  size: PtrUInt;
  pe: LongWord;
  fh: PCoffHeader;
  secs: PCoffSection;
  syms, cs: PCoffSymbol;
  strtab: PChar;
  i, n: LongInt;
  name: AnsiString;
begin
  if g_host_built then Exit;
  t0 := NowMs;
  n := GetModuleFileNameA(0, @path[0], SizeOf(path));
  if (n > 0) and ReadWholeFile(AnsiString(PChar(@path[0])), buf, size) then
  begin
    pe := PLongWord(buf + $3c)^;
    fh := PCoffHeader(buf + pe + 4);
    secs := PCoffSection(buf + pe + 24 + fh^.SizeOfOptionalHeader);
    if (fh^.PointerToSymbolTable <> 0) and (fh^.NumberOfSymbols > 0) then
    begin
      syms := PCoffSymbol(buf + fh^.PointerToSymbolTable);
      strtab := PChar(buf + fh^.PointerToSymbolTable + fh^.NumberOfSymbols * SizeOf(TCoffSymbol));
      SetLength(g_host_pool, fh^.NumberOfSymbols);
      i := 0;
      while i < LongInt(fh^.NumberOfSymbols) do
      begin
        cs := @syms[i];
        if ((cs^.StorageClass = IMAGE_SYM_CLASS_EXTERNAL) or (cs^.StorageClass = IMAGE_SYM_CLASS_STATIC))
          and (cs^.SectionNumber > 0) and (cs^.SectionNumber <= fh^.NumberOfSections)
          and not ((cs^.StorageClass = IMAGE_SYM_CLASS_STATIC) and (cs^.NumberOfAuxSymbols > 0)) then
        begin
          name := CoffSymName(cs, strtab);
          if name <> '' then
          begin
            g_host_pool[i].Addr := g_image_base + secs[cs^.SectionNumber - 1].VirtualAddress + cs^.Value;
            g_host_pool[i].Code := (secs[cs^.SectionNumber - 1].Characteristics and IMAGE_SCN_MEM_EXECUTE) <> 0;
            // an external name wins over a local one of another unit
            if (cs^.StorageClass = IMAGE_SYM_CLASS_EXTERNAL) or (MapGet(g_host, name) = nil) then MapPut(g_host, name, @g_host_pool[i]);
          end;
        end;
        Inc(i, 1 + cs^.NumberOfAuxSymbols);
      end;
    end;
    FreeMem(buf);
  end;
  ReadMapFile(AnsiString(PChar(@path[0])));
  g_host_built := True;
  g_host_ms := NowMs - t0;
end;
{$endif}

// ================================================================ the system: memory and code
procedure JitWritable(on: Boolean);
begin
{$ifdef darwin}
  if on then pthread_jit_write_protect_np(0) else pthread_jit_write_protect_np(1);
{$endif}
end;

{$if defined(linux) and defined(cpuaarch64)}
function ReadCtr: QWord; assembler; nostackframe;
asm
  .long 0xd53b0020   // mrs x0, ctr_el0
end;
procedure DcCvau(a: QWord); assembler; nostackframe;
asm
  .long 0xd50b7b20   // dc cvau, x0
end;
procedure IcIvau(a: QWord); assembler; nostackframe;
asm
  .long 0xd50b7520   // ic ivau, x0
end;
procedure DsbIsh; assembler; nostackframe;
asm
  .long 0xd5033b9f   // dsb ish
end;
procedure Isb; assembler; nostackframe;
asm
  .long 0xd5033fdf   // isb
end;
{$endif}

// After writing instructions: make the instruction cache see them.
procedure ClearCache(p: Pointer; len: PtrUInt);
{$if defined(darwin)}
begin
  if len > 0 then sys_icache_invalidate(p, len);
end;
{$elseif defined(windows)}
begin
  FlushInstructionCache(GetCurrentProcess, p, len);
end;
{$elseif defined(cpux86_64)}
begin
  // x86-64 keeps instruction fetch coherent with stores
end;
{$else}
var
  ctr, dline, iline, a, e: QWord;
begin
  if len = 0 then Exit;
  ctr := ReadCtr;
  dline := QWord(4) shl ((ctr shr 16) and 15);
  iline := QWord(4) shl (ctr and 15);
  e := QWord(PtrUInt(p)) + len;
  a := QWord(PtrUInt(p)) and not (dline - 1);
  while a < e do
  begin
    DcCvau(a);
    Inc(a, dline);
  end;
  DsbIsh;
  a := QWord(PtrUInt(p)) and not (iline - 1);
  while a < e do
  begin
    IcIvau(a);
    Inc(a, iline);
  end;
  DsbIsh;
  Isb;
end;
{$endif}

var
  g_isl, g_island_next: PByte;                  // island region, near the program
  g_jit, g_jit_next, g_veneer_next: PByte;      // code region
  g_data, g_data_next: PByte;
  g_slot_next: PQWord;
  g_regions_failed: Boolean;

function IslandInReach(start: QWord): Boolean;
begin
  Result := (Int64(start + ISLAND_AREA - g_text_lo) < ISLAND_REACH) and (Int64(g_text_hi - start) < ISLAND_REACH);
end;

function RegionOk(kind: LongInt; start, size: QWord; reach: Int64): Boolean;
begin
  if kind = 1 then Result := IslandInReach(start)
  else Result := (Int64(start + size - g_text_lo) < reach) and (Int64(g_text_hi - start) < reach);
{$if defined(linux) and defined(cpux86_64)}
  // fpc's x86-64 code is not position independent: it reaches variables and tables through
  // sign-extended 32-bit addresses (R_X86_64_32S), so a program loaded low needs its new
  // code and data below 2 GiB too.
  if g_text_hi < (QWord(2) shl 30) then Result := Result and (start + size <= (QWord(2) shl 30));
{$endif}
end;

// A region of memory within reach of the program's code. A hint to mmap is honoured when
// the place is free on Linux and is a lower bound on Darwin; either way, try places from
// the bottom of the window upwards and keep the first mapping that lands in reach.
// kind: 0 data, 1 islands, 2 code.
{$ifdef windows}
// Windows: VirtualAlloc at an address either gives exactly that address or nothing. Start
// above the image, because unwind tables hold 32-bit offsets from the image's base.
function ReserveNear(size: QWord; kind: LongInt; reach: Int64): PByte;
var
  cand: QWord;
  m: Pointer;
begin
  Result := nil;
  cand := (g_image_hi + $ffff) and not QWord($ffff);
  while Int64(cand - g_text_hi) < reach do
  begin
    if RegionOk(kind, cand, size, reach) then
    begin
      m := VirtualAlloc(Pointer(PtrUInt(cand)), size, MEM_RESERVE or MEM_COMMIT, PAGE_EXECUTE_READWRITE);
      if m <> nil then Exit(PByte(m));
    end;
    Inc(cand, QWord(4) shl 20);
  end;
end;
{$else}
function ReserveNear(size: QWord; kind: LongInt; reach: Int64): PByte;
var
  cand, got: QWord;
  prot, flags: LongInt;
  m: Pointer;
begin
  Result := nil;
  if g_text_lo > QWord(reach) + LOW_BOUND then cand := g_text_lo - QWord(reach) else cand := LOW_BOUND;
  cand := (cand + $3fff) and not QWord($3fff);
  prot := PROT_R or PROT_W;
  flags := MAP_PRIV or MAP_ANONYM;
  if kind <> 0 then
  begin
    prot := prot or PROT_X;
    flags := flags or MAP_JIT;
  end;
  while Int64(cand - g_text_hi) < reach do
  begin
    if RegionOk(kind, cand, size, reach) then
    begin
      m := Fpmmap(Pointer(PtrUInt(cand)), size, prot, flags, -1, 0);
      if m <> MAP_FAILED then
      begin
        got := QWord(PtrUInt(m));
        if RegionOk(kind, got, size, reach) then Exit(PByte(m));
        Fpmunmap(m, size);
      end;
    end;
    Inc(cand, QWord(4) shl 20);
  end;
end;
{$endif}

function RegionsInit: Boolean;
var
  isl, jit, data: PByte;
  tb: PChar;
  at, sz: QWord;
  code: Word;
  m: Pointer;
begin
  if g_jit <> nil then Exit(True);
  // Test only: HOT_TEST_BLOCK=<MiB> puts an obstacle right above the program first, to
  // reproduce the layout in which the allocator's zone took the neighbourhood.
{$ifdef unix}
  tb := FpGetEnv('HOT_TEST_BLOCK');
  if (tb <> nil) and not g_regions_failed then
  begin
    at := (g_image_hi + (QWord(1) shl 20)) and not QWord($3fff);
    Val(AnsiString(tb), sz, code);
    m := Fpmmap(Pointer(PtrUInt(at)), sz shl 20, 0, MAP_PRIV or MAP_ANONYM, -1, 0);
    WriteLn(StdErr, '[hotagent] test obstacle of ', tb, ' MiB at ', HStr(QWord(PtrUInt(m))), ' (asked ', HStr(at), ')');
  end;
{$else}
  tb := nil;
{$endif}
  if g_regions_failed then
  begin
    Say('restart hot reloading is off in this process: no free memory within reach of the program''s code');
    Exit(False);
  end;
{$ifdef cpux86_64}
  // One block for islands, code and data: an island reaches its slot, and new code the
  // program's variables, through 32-bit offsets, so everything must be within 2 GiB of
  // everything else. (Linux does not stop a mapping from being writable and executable.)
  isl := ReserveNear(ISLAND_AREA + JIT_SIZE + DATA_SIZE, 2, REGION_REACH);
  jit := nil;
  data := nil;
  if isl <> nil then
  begin
    jit := isl + ISLAND_AREA;
    data := jit + JIT_SIZE;
  end;
{$else}
  isl := ReserveNear(ISLAND_AREA, 1, ISLAND_REACH);
  jit := nil;
  data := nil;
  if isl <> nil then jit := ReserveNear(JIT_SIZE, 2, REGION_REACH);
  if jit <> nil then data := ReserveNear(DATA_SIZE, 0, REGION_REACH);
{$endif}
  if (isl = nil) or (jit = nil) or (data = nil) then
  begin
{$if defined(unix) and not defined(cpux86_64)}
    if isl <> nil then Fpmunmap(isl, ISLAND_AREA);
    if jit <> nil then Fpmunmap(jit, JIT_SIZE);
{$endif}
    g_regions_failed := True;
    Say('restart hot reloading is off in this process: no free memory within reach of the program''s code');
    Exit(False);
  end;
  g_isl := isl;
  g_jit := jit;
  g_data := data;
  if tb <> nil then
    WriteLn(StdErr, '[hotagent] islands ', HStr(QWord(PtrUInt(isl))), ' (', (Int64(PtrUInt(isl)) - Int64(g_text_lo)) div (1 shl 20), ' MiB from the start of the program''s text), code ',
      HStr(QWord(PtrUInt(jit))), ' (', (Int64(PtrUInt(jit)) - Int64(g_text_lo)) div (1 shl 20), ' MiB), data ', HStr(QWord(PtrUInt(data))));
  g_island_next := g_isl;
  g_veneer_next := g_jit;
  g_jit_next := g_jit + VENEER_AREA;
  g_slot_next := PQWord(g_data);
  g_data_next := g_data + SLOT_AREA;
  Result := True;
end;

function InJit(a: QWord): Boolean;
begin
  Result := ((g_jit <> nil) and (a >= QWord(PtrUInt(g_jit))) and (a < QWord(PtrUInt(g_jit)) + JIT_SIZE))
    or ((g_isl <> nil) and (a >= QWord(PtrUInt(g_isl))) and (a < QWord(PtrUInt(g_isl)) + ISLAND_AREA));
end;

function Bump(var next: PByte; limit: PByte; size, align: QWord): PByte;
var
  a: QWord;
begin
  a := (QWord(PtrUInt(next)) + align - 1) and not (align - 1);
  if a + size > QWord(PtrUInt(limit)) then Exit(nil);
  next := PByte(PtrUInt(a + size));
  Result := PByte(PtrUInt(a));
end;

// ---------------------------------------------------------------- instructions: islands and branches
type
  TPatch = record
    Addr: QWord;
    Len: LongInt;
    B: array[0..7] of Byte;
  end;

{$ifdef cpuaarch64}
// An island: adrp x16, slot ; ldr x16, [x16, off] ; br x16. The slot is ordinary memory.
function WriteIsland(var next: PByte; limit: PByte; slot: PQWord): QWord;
var
  isn: PLongWord;
  pd: Int64;
begin
  isn := PLongWord(next);
  if PByte(isn + 3) > limit then Exit(0);
  Inc(next, 12);
  pd := SarInt64(Int64((QWord(PtrUInt(slot)) and not QWord($fff)) - (QWord(PtrUInt(isn)) and not QWord($fff))), 12);
  isn[0] := $90000010 or (LongWord(pd and 3) shl 29) or (LongWord((pd shr 2) and $7ffff) shl 5);
  isn[1] := $f9400210 or (LongWord((QWord(PtrUInt(slot)) and $fff) shr 3) shl 10);
  isn[2] := $d61f0200;
  Result := QWord(PtrUInt(isn));
end;

// The entry of a function, overwritten: b island.
function RedirectPatch(from, target: QWord): TPatch;
var
  w: LongWord;
begin
  w := $14000000 or (LongWord(SarInt64(Int64(target - from), 2)) and $03ffffff);
  Result.Addr := from;
  Result.Len := 4;
  Move(w, Result.B[0], 4);
end;
{$else}
// An island: jmp qword ptr [rip + slot]. The slot is ordinary memory within 2 GiB.
function WriteIsland(var next: PByte; limit: PByte; slot: PQWord): QWord;
var
  isn: PByte;
  d: Int64;
begin
  isn := PByte((PtrUInt(next) + 7) and not PtrUInt(7));
  if isn + 6 > limit then Exit(0);
  d := Int64(QWord(PtrUInt(slot)) - QWord(PtrUInt(isn + 6)));
  if (d >= BRANCH_REACH) or (d < -BRANCH_REACH) then Exit(0);
  next := isn + 8;
  isn[0] := $ff;
  isn[1] := $25;
  PLongInt(isn + 2)^ := LongInt(d);
  Result := QWord(PtrUInt(isn));
end;

// The entry of a function, overwritten: jmp rel32 island (5 bytes).
function RedirectPatch(from, target: QWord): TPatch;
begin
  Result.Addr := from;
  Result.Len := 5;
  Result.B[0] := $e9;
  PLongInt(@Result.B[1])^ := LongInt(Int64(target - (from + 5)));
end;
{$endif}

// Next to the program: what an overwritten entry branches to.
function MakeIsland(slot: PQWord): QWord;
begin
  Result := WriteIsland(g_island_next, g_isl + ISLAND_AREA, slot);
end;

// Next to the new code: what a call out of reach of bl goes through.
function MakeVeneer(slot: PQWord): QWord;
begin
  Result := WriteIsland(g_veneer_next, g_jit + VENEER_AREA, slot);
end;

function NewSlot(v: QWord): PQWord;
begin
  if PByte(g_slot_next + 1) > g_data + SLOT_AREA then Exit(nil);
  g_slot_next^ := v;
  Result := g_slot_next;
  Inc(g_slot_next);
end;

// ================================================================ registry of what the agent manages
type
  PSym = ^TSym;
  TSym = record
    Name: AnsiString;
    Kind: Byte;
    Canon: QWord;       // the address the symbol has as a value, for the life of the process
    Cur: QWord;         // newest code (functions)
    Slot: PQWord;       // functions: what the islands jump through
    Island: QWord;      // next to the program: for the entry in the program's text
    IslandFar: QWord;   // next to the new code: for entries of superseded versions there
    Pending: Boolean;
    PCanon, PCur: QWord;
  end;
  TStore = record Dst: PQWord; Val: QWord; end;
  TVmtUpdate = record O: PObj; S: POSym; OldAddr: QWord; end;
  TDataCopy = record Dst: QWord; Src: PByte; Size: QWord; end;
var
  g_reg: TMap;
  g_units: TMap;      // unit name -> PObj, the live version
  g_veneers: TMap;    // target address -> veneer, for calls out of reach of bl
  g_indirects: TMap;  // X$indirect the program does not have -> the pointer to X made for it
  g_pending: array of PSym;
  g_npending: SizeInt;
  g_patches: array of TPatch;
  g_npatch: SizeInt;
  g_stores: array of TStore;
  g_nstore: SizeInt;
  g_vmts: array of TVmtUpdate;
  g_nvmt: SizeInt;
  g_copies: array of TDataCopy;
  g_ncopy: SizeInt;
  g_restart: LongInt;
  g_poisoned: Boolean;
  g_patched: LongInt;
  g_suspend: Boolean = True;

procedure AddPatch(const pt: TPatch);
begin
  if g_npatch = Length(g_patches) then SetLength(g_patches, 256 + 2 * Length(g_patches));
  g_patches[g_npatch] := pt;
  Inc(g_npatch);
end;

procedure AddStore(dst: PQWord; val: QWord);
begin
  if g_nstore = Length(g_stores) then SetLength(g_stores, 256 + 2 * Length(g_stores));
  g_stores[g_nstore].Dst := dst;
  g_stores[g_nstore].Val := val;
  Inc(g_nstore);
end;

procedure Restart(const why: AnsiString);
begin
  Say('restart ' + why);
  Inc(g_restart);
end;

function RegGet(const name: AnsiString): PSym;
begin
  Result := MapGet(g_reg, name);
end;

function RegStage(const name: AnsiString; kind: Byte): PSym;
var
  s: PSym;
begin
  s := RegGet(name);
  if s = nil then
  begin
    New(s);
    FillChar(s^, SizeOf(TSym), 0);
    s^.Name := name;
    s^.Kind := kind;
    MapPut(g_reg, s^.Name, s);
  end;
  if not s^.Pending then
  begin
    s^.Pending := True;
    s^.PCanon := s^.Canon;
    s^.PCur := s^.Cur;
    if g_npending = Length(g_pending) then SetLength(g_pending, 256 + 2 * Length(g_pending));
    g_pending[g_npending] := s;
    Inc(g_npending);
  end;
  Result := s;
end;

// The address a name has in the process before this transaction: 0 when it has none.
function Existing(const name: AnsiString; out kind: Byte): QWord;
var
  s: PSym;
  h: PHostSym;
begin
  kind := 0;
  s := RegGet(name);
  if (s <> nil) and (s^.Canon <> 0) then
  begin
    kind := s^.Kind;
    Exit(s^.Canon);
  end;
  h := MapGet(g_host, name);
  if h <> nil then
  begin
    if h^.Tls then kind := K_TLS else if h^.Code then kind := K_CODE else kind := K_DATA;
    Exit(h^.Addr);
  end;
  Result := 0;
end;

function Placed(o: PObj; s: POSym): QWord;
begin
  Result := QWord(PtrUInt(o^.Sect[s^.Sect].Base)) + s^.Value;
end;

function KindName(k: Byte): AnsiString;
begin
  if k = K_CODE then Result := 'code' else Result := 'data';
end;

function PlaceSections(o: PObj): Boolean;
var
  i: SizeInt;
  t: PSect;
  al: QWord;
begin
  for i := 0 to High(o^.Sect) do
  begin
    t := @o^.Sect[i];
    if (t^.Kind in [0, K_TLS]) or (t^.Size = 0) then Continue;
    al := t^.Align;
    if al > 16384 then al := 16384;
    if al < 8 then al := 8;
    if t^.Kind = K_CODE then
    begin
      if al < 16 then al := 16;
      t^.Base := Bump(g_jit_next, g_jit + JIT_SIZE, t^.Size, al);
    end
    else t^.Base := Bump(g_data_next, g_data + DATA_SIZE, t^.Size, al);
    if t^.Base = nil then
    begin
      Restart('no room left for new code or data');
      Exit(False);
    end;
  end;
  Result := True;
end;

procedure CopySections(o: PObj);
var
  i: SizeInt;
  t: PSect;
begin
  for i := 0 to High(o^.Sect) do
  begin
    t := @o^.Sect[i];
    if (t^.Kind in [0, K_TLS]) or (t^.Size = 0) then Continue;
    if t^.Zerofill then FillChar(t^.Base^, t^.Size, 0)
    else Move(t^.Data^, t^.Base^, t^.Size);
  end;
end;

type
  TCounts = record Func, Changed, Added, Kept, NewData, Notes: LongInt; end;

// Decide, for every named symbol the object defines, which address it has from now on.
procedure BindSymbols(o: PObj; var c: TCounts);
var
  p: PObj;
  i: SizeInt;
  s, ps: POSym;
  here, e: QWord;
  ekind: Byte;
  r: PSym;
  anon, same: Boolean;
  n: AnsiString;
  nb, ob: PByte;
  ni, oi: Int64;
  removed: LongInt;
  hs: PHostSym;
begin
  p := o^.Prev;
  for i := 0 to High(o^.Sym) do
  begin
    s := @o^.Sym[i];
    if not s^.Defined or (s^.Kind = 0) then Continue;
    here := Placed(o, s);
    if not s^.Ext then
    begin
      s^.AValue := here;
      s^.ACall := here;
      s^.Resolved := True;
      Continue;
    end;
    ps := nil;
    if p <> nil then ps := MapGet(p^.ByName, s^.Name);
    if s^.Kind = K_TLS then
    begin
      // The system lays out every thread's copy when the thread starts: a thread variable
      // keeps its offset, and a new one cannot be given room.
      hs := MapGet(g_host, s^.Name);
      if (hs = nil) or not hs^.Tls then Restart('unit ' + o^.UnitName + ' gained the thread variable ' + Pretty(s^.Name))
      else if (ps <> nil) and (ps^.Size <> s^.Size) then Restart('the thread variable ' + Pretty(s^.Name) + ' changed size from ' + UStr(ps^.Size) + ' to ' + UStr(s^.Size) + ' bytes')
      else
      begin
        s^.AValue := hs^.Addr;
        s^.ACall := hs^.Addr;
        s^.Tls := True;
        s^.Resolved := True;
        s^.BoundOld := True;
        Inc(c.Kept);
      end;
      Continue;
    end;
    e := Existing(s^.Name, ekind);
    if (e <> 0) and (ekind <> s^.Kind) then
    begin
      Restart(Pretty(s^.Name) + ' was ' + KindName(ekind) + ' and is now ' + KindName(s^.Kind));
      Continue;
    end;
    if s^.Kind = K_CODE then
    begin
      if s^.Size = 0 then
      begin
        if e <> 0 then s^.AValue := e else s^.AValue := here;
        s^.ACall := s^.AValue;
        s^.Resolved := True;
        Continue;
      end;
      r := RegStage(s^.Name, K_CODE);
      s^.BoundOld := e <> 0;   // the program has it: it will be redirected
      if e <> 0 then
      begin
        if r^.PCanon = 0 then
        begin
          r^.PCanon := e;
          r^.PCur := e;
        end;
      end
      else r^.PCanon := here;
      r^.PCur := here;
      s^.AValue := r^.PCanon;
      s^.ACall := here;
      s^.Resolved := True;
      Inc(c.Func);
      if ps = nil then
      begin
        if p <> nil then Inc(c.Added);
      end
      else if SymDigest(o, s, 0) <> SymDigest(p, ps, 0) then
      begin
        Inc(c.Changed);
        if StartsWith(s^.Name, 'INIT$_$') then
        begin
          Say('note the initialization section of ' + o^.UnitName + ' changed; it is not run again');
          Inc(c.Notes);
        end;
        if (s^.Name = 'PASCALMAIN') or (s^.Name = 'main') then
        begin
          Say('note the main block changed; the frame that is running keeps its old code');
          Inc(c.Notes);
        end;
      end;
      Continue;
    end;
    // data
    anon := IsAnon(s^.Name) or IsUnwindSection(o^.Sect[s^.Sect].Name);
    if (e = 0) or anon then
    begin
      r := RegStage(s^.Name, K_DATA);
      r^.PCanon := here;
      r^.PCur := here;
      s^.AValue := here;
      s^.ACall := here;
      s^.Resolved := True;
      Inc(c.NewData);
      if not anon and StartsWith(s^.Name, 'THREADVARLIST_$') then Restart('unit ' + o^.UnitName + ' gained its first thread variable');
      Continue;
    end;
    s^.BoundOld := True;
    s^.AValue := e;
    s^.ACall := e;
    s^.Resolved := True;
    Inc(c.Kept);
    if ps = nil then
    begin
      Say('note ' + Pretty(s^.Name) + ' exists in the program but not in the version of ' + o^.UnitName + ' the agent knows; kept without a check');
      Inc(c.Notes);
      Continue;
    end;
    n := s^.Name;
    if StartsWith(n, 'VMT_$') and not Contains(n, '$indirect') then
    begin
      nb := SymBytes(o, s);
      ob := SymBytes(p, ps);
      ni := 0;
      oi := 0;
      if nb <> nil then ni := PInt64(nb)^;
      if ob <> nil then oi := PInt64(ob)^;
      if ni <> oi then
      begin
        Restart('class ' + Pretty(n) + ': instance size changed from ' + IStr(oi) + ' to ' + IStr(ni) + ' bytes');
        Continue;
      end;
      if s^.Size <> ps^.Size then
      begin
        Restart('class ' + Pretty(n) + ': the virtual method table changed from ' + UStr(ps^.Size div 8) + ' to ' + UStr(s^.Size div 8) + ' slots');
        Continue;
      end;
      if RelocTargetAt(o, s, 16) <> RelocTargetAt(p, ps, 16) then
      begin
        Restart('class ' + Pretty(n) + ': the parent class changed');
        Continue;
      end;
      if g_nvmt = Length(g_vmts) then SetLength(g_vmts, 64 + 2 * Length(g_vmts));
      g_vmts[g_nvmt].O := o;
      g_vmts[g_nvmt].S := s;
      g_vmts[g_nvmt].OldAddr := e;
      Inc(g_nvmt);
      Continue;
    end;
    if s^.Size <> ps^.Size then
    begin
      if StartsWith(n, 'U_$') or StartsWith(n, 'TC_$') then
        Restart('variable ' + Pretty(n) + ' changed size from ' + UStr(ps^.Size) + ' to ' + UStr(s^.Size) + ' bytes')
      else if StartsWith(n, 'THREADVARLIST_$') then Restart('the thread variables of unit ' + o^.UnitName + ' changed')
      else Restart(Pretty(n) + ' changed size from ' + UStr(ps^.Size) + ' to ' + UStr(s^.Size) + ' bytes');
      Continue;
    end;
    if Contains(n, '$indirect') then Continue;
    same := SymDigest(o, s, 0) = SymDigest(p, ps, 0);
    if same then Continue;
    if StartsWith(n, 'INIT_$') or StartsWith(n, 'RTTI_$') then
    begin
      Restart('type ' + Pretty(n) + ': its layout or type information changed');
      Continue;
    end;
    if StartsWith(n, 'THREADVARLIST_$') then
    begin
      Restart('the thread variables of unit ' + o^.UnitName + ' changed');
      Continue;
    end;
    if StartsWith(n, 'TC_$') then
    begin
      // An initialised variable or typed constant whose initial value was edited. If the
      // running value is still the old initial value, nothing has written it: take the new one.
      nb := SymBytes(o, s);
      ob := SymBytes(p, ps);
      if (nb <> nil) and (ob <> nil) and not HasRelocs(o, s) and not HasRelocs(p, ps) and (CompareByte(PByte(PtrUInt(e))^, ob^, s^.Size) = 0) then
      begin
        if g_ncopy = Length(g_copies) then SetLength(g_copies, 64 + 2 * Length(g_copies));
        g_copies[g_ncopy].Dst := e;
        g_copies[g_ncopy].Src := nb;
        g_copies[g_ncopy].Size := s^.Size;
        Inc(g_ncopy);
        Say('note ' + Pretty(n) + ' still had its initial value; set to the new one');
      end
      else Say('note the initial value of ' + Pretty(n) + ' changed; the running value is kept');
      Inc(c.Notes);
      Continue;
    end;
    if StartsWith(n, 'RESSTR_$') then
    begin
      Say('note resource string ' + Pretty(n) + ' changed; the running text is kept');
      Inc(c.Notes);
      Continue;
    end;
    Say('note ' + Pretty(n) + ' changed; the running copy is kept');
    Inc(c.Notes);
  end;
  if p <> nil then
  begin
    removed := 0;
    for i := 0 to High(p^.Sym) do
    begin
      ps := @p^.Sym[i];
      if ps^.Defined and ps^.Ext and (ps^.Kind = K_CODE) and (ps^.Size <> 0) and (MapGet(o^.ByName, ps^.Name) = nil) then
      begin
        if removed < 4 then Say('note ' + Pretty(ps^.Name) + ' is gone from the source; its old code stays for callers that were not recompiled');
        Inc(removed);
      end;
    end;
    if removed > 4 then Say('note ... and ' + IStr(removed - 4) + ' more functions gone from the source');
    if removed > 0 then Inc(c.Notes);
  end;
end;

// What a load needs: the sections of what the program already has (functions to redirect,
// variables and tables it keeps), and what their relocations reach, as a linker would,
// across all the objects of the load. The rest, such as type information no code uses, is
// never read; a linker that drops unused sections (Windows) may have dropped what it refers
// to. Unwind tables are live when the code they describe is.
procedure MarkLive(const objs: array of PObj);
var
  i, k, oi: SizeInt;
  changed, reach: Boolean;
  o, to_: PObj;
  t: PSect;
  tgt: LongInt;

  // The section a relocation reaches, in this object or in another one of the load.
  function Target(o: PObj; const r: TReloc; out tobj: PObj): LongInt;
  var
    j: SizeInt;
    d: POSym;
  begin
    Result := -1;
    tobj := o;
    if r.Sym < 0 then
    begin
      Result := r.Sect;
      if Result > High(o^.Sect) then Result := -1;
      Exit;
    end;
    if o^.Sym[r.Sym].Defined then
    begin
      Result := o^.Sym[r.Sym].Sect;
      Exit;
    end;
    for j := 0 to High(objs) do
      if objs[j] <> o then
      begin
        d := MapGet(objs[j]^.ByName, o^.Sym[r.Sym].Name);
        if (d <> nil) and d^.Defined then
        begin
          tobj := objs[j];
          Exit(d^.Sect);
        end;
      end;
  end;

begin
  for oi := 0 to High(objs) do
  begin
    o := objs[oi];
    for i := 0 to High(o^.Sect) do o^.Sect[i].Live := False;
    for i := 0 to High(o^.Sym) do
      if o^.Sym[i].Defined and o^.Sym[i].BoundOld and (o^.Sym[i].Sect >= 0) then o^.Sect[o^.Sym[i].Sect].Live := True;
  end;
  repeat
    changed := False;
    for oi := 0 to High(objs) do
    begin
      o := objs[oi];
      for i := 0 to High(o^.Sect) do
      begin
        t := @o^.Sect[i];
        if t^.Kind in [0, K_TLS] then Continue;
        if t^.Live then
        begin
          for k := 0 to High(t^.Rel) do
          begin
            tgt := Target(o, t^.Rel[k], to_);
            if (tgt >= 0) and not to_^.Sect[tgt].Live then
            begin
              to_^.Sect[tgt].Live := True;
              changed := True;
            end;
          end;
        end
        else if IsUnwindSection(t^.Name) then
        begin
          reach := False;
          for k := 0 to High(t^.Rel) do
          begin
            tgt := Target(o, t^.Rel[k], to_);
            if (tgt >= 0) and (to_ = o) and o^.Sect[tgt].Live and (o^.Sect[tgt].Kind = K_CODE) then reach := True;
          end;
          if reach then
          begin
            t^.Live := True;
            changed := True;
          end;
        end;
      end;
    end;
  until not changed;
end;

// What is not live is placed but never relocated: it must not become a name the program
// has, or a later load would bind to code that was never made runnable. Names this load
// would have created for it are taken back.
procedure Unregister(o: PObj);
var
  i: SizeInt;
  r: PSym;
begin
  for i := 0 to High(o^.Sym) do
    if o^.Sym[i].Defined and o^.Sym[i].Ext and (o^.Sym[i].Sect >= 0) and not o^.Sect[o^.Sym[i].Sect].Live then
    begin
      r := RegGet(o^.Sym[i].Name);
      if (r <> nil) and r^.Pending and (r^.Canon = 0) then
      begin
        r^.PCanon := 0;
        r^.PCur := 0;
      end;
    end;
end;

procedure ResolveUndefined(o: PObj);
var
  i, k: SizeInt;
  s: POSym;
  r: PSym;
  h: PHostSym;
  d: Pointer;
  slot: PQWord;
  e: QWord;
  ek: Byte;
begin
  for i := 0 to High(o^.Sym) do
  begin
    s := @o^.Sym[i];
    if s^.Resolved or s^.Defined or (s^.Name = '') then Continue;
    r := RegGet(s^.Name);
    if (r <> nil) and (((r^.Pending) and (r^.PCanon <> 0)) or ((not r^.Pending) and (r^.Canon <> 0))) then
    begin
      if r^.Pending then s^.AValue := r^.PCanon else s^.AValue := r^.Canon;
      if r^.Kind = K_CODE then
      begin
        if r^.Pending then s^.ACall := r^.PCur else s^.ACall := r^.Cur;
      end
      else s^.ACall := s^.AValue;
      s^.Resolved := True;
      Continue;
    end;
    h := MapGet(g_host, s^.Name);
    if h <> nil then
    begin
      s^.AValue := h^.Addr;
      s^.ACall := h^.Addr;
      s^.Tls := h^.Tls;
      s^.Resolved := True;
      Continue;
    end;
    // X$indirect is only a pointer to X, and a linker that leaves out what the program
    // does not use (Windows) keeps it only when old code needed it: make one.
    if EndsWith(s^.Name, '$indirect') then
    begin
      slot := MapGet(g_indirects, s^.Name);
      if slot = nil then
      begin
        e := Existing(Copy(s^.Name, 1, Length(s^.Name) - 9), ek);
        if e <> 0 then
        begin
          slot := NewSlot(e);
          if slot <> nil then MapPut(g_indirects, s^.Name, slot);
        end;
      end;
      if slot <> nil then
      begin
        s^.AValue := QWord(PtrUInt(slot));
        s^.ACall := s^.AValue;
        s^.Resolved := True;
        Continue;
      end;
    end;
{$ifdef unix}
    d := dlsym(RTLD_DEFAULT, PChar(s^.Name));
    if d <> nil then
    begin
      s^.AValue := QWord(PtrUInt(d));
      s^.ACall := s^.AValue;
      s^.Resolved := True;
    end;
{$else}
    d := nil;
    if d <> nil then;
{$endif}
  end;
  // Only symbols that a relocation uses must exist.
  for i := 0 to High(o^.Sect) do
  begin
    if (o^.Sect[i].Kind in [0, K_TLS]) or not o^.Sect[i].Live then Continue;
    for k := 0 to High(o^.Sect[i].Rel) do
    begin
      if o^.Sect[i].Rel[k].Sym < 0 then Continue;
      s := @o^.Sym[o^.Sect[i].Rel[k].Sym];
      if not s^.Resolved then
      begin
        Restart(o^.UnitName + ' uses ' + Pretty(s^.Name) + ', which the running program does not contain');
        s^.Resolved := True;
      end;
    end;
  end;
end;

function Veneer(target: QWord): QWord;
var
  key: AnsiString;
  v: Pointer;
  slot: PQWord;
begin
  key := HexStr(target, 16);
  v := MapGet(g_veneers, key);
  if v <> nil then Exit(QWord(PtrUInt(v)));
  slot := NewSlot(target);
  Result := 0;
  if slot <> nil then Result := MakeVeneer(slot);
  if Result <> 0 then MapPut(g_veneers, key, Pointer(PtrUInt(Result)));
end;

function GotFor(s: POSym; S0: QWord): PQWord;
begin
  if s^.Got = nil then
  begin
    s^.Got := PQWord(Bump(g_data_next, g_data + DATA_SIZE, 8, 8));
    if s^.Got <> nil then s^.Got^ := S0;
  end;
  Result := s^.Got;
end;

function Relocate(o: PObj): Boolean;
var
  si, i: SizeInt;
  t, ts: PSect;
  r: ^TReloc;
  P: PByte;
  Pv, S0, Scall, T0, B: QWord;
  s: POSym;
  d, pd: Int64;
  insn, off, shift: LongWord;
  g: PQWord;
  what: AnsiString;
  c: LongInt;
  cs: POSym;
begin
  Result := False;
  for si := 0 to High(o^.Sect) do
  begin
    t := @o^.Sect[si];
    if (t^.Kind in [0, K_TLS]) or t^.Zerofill or not t^.Live then Continue;
    for i := 0 to High(t^.Rel) do
    begin
      r := @t^.Rel[i];
      P := t^.Base + r^.Off;
      Pv := QWord(PtrUInt(P));
      s := nil;
      if r^.Sym >= 0 then
      begin
        s := @o^.Sym[r^.Sym];
        S0 := s^.AValue;
        Scall := s^.ACall;
        what := Pretty(s^.Name);
      end
      else
      begin
        if (r^.Sect < 0) or (r^.Sect > High(o^.Sect)) or (o^.Sect[r^.Sect].Base = nil) then
        begin
          Say('error ' + o^.UnitName + ': a relocation refers to a section that is not loaded');
          Exit;
        end;
        ts := @o^.Sect[r^.Sect];
        S0 := QWord(PtrUInt(ts^.Base));
        Scall := S0;
        what := ts^.Name;
        // Where the format gives the target's exact offset, refer through the symbol that
        // covers it: a variable of this unit that the program already has keeps its address
        // even when code reaches it as section + offset, which COFF does for everything in
        // the same object. A function's start as a value is its first address, as for a
        // named reference; a branch, unwind data and places inside a function mean the new code.
        if r^.HasTOff then
        begin
          c := CoveringRel(o, r^, r^.TOff);
          if (c >= 0) and o^.Sym[c].Resolved then
          begin
            cs := @o^.Sym[c];
            if (cs^.Kind = K_DATA) or ((cs^.Kind = K_CODE) and (r^.TOff = Int64(cs^.Value))
              and not (r^.Kind in [rkBranch32, rkBranch26]) and not IsUnwindSection(t^.Name)) then
              S0 := cs^.AValue - cs^.Value;
            Scall := S0;
            what := Pretty(cs^.Name);
          end;
        end;
      end;
      case r^.Kind of
        rkAbs64: PQWord(P)^ := S0 + QWord(r^.Addend);
        rkAbs32:
          begin
{$ifdef cpux86_64}
            if S0 + QWord(r^.Addend) > $ffffffff then
            begin
              Say('error ' + o^.UnitName + ': ' + what + ' is above 4 GiB, out of reach of a 32-bit address');
              Exit;
            end;
{$endif}
            PLongWord(P)^ := LongWord(S0 + QWord(r^.Addend));
          end;
        rkSub64, rkSub32:
          begin
            B := o^.Sym[r^.Sym2].AValue;
            if r^.Kind = rkSub64 then PQWord(P)^ := B - S0 + QWord(r^.Addend)
            else PLongWord(P)^ := LongWord(B - S0 + QWord(r^.Addend));
          end;
        rkPrel32:
          begin
            d := Int64(S0 + QWord(r^.Addend) - Pv);
            if (d >= (Int64(1) shl 31)) or (d < -(Int64(1) shl 31)) then
            begin
              Say('error ' + o^.UnitName + ': ' + what + ' is out of reach of a 32-bit offset');
              Exit;
            end;
            PLongInt(P)^ := LongInt(d);
          end;
        rkAbs32S:
          begin
            d := Int64(S0 + QWord(r^.Addend));
            if (d >= (Int64(1) shl 31)) or (d < -(Int64(1) shl 31)) then
            begin
              Say('error ' + o^.UnitName + ': ' + what + ' is above 2 GiB, out of reach of a 32-bit address');
              Exit;
            end;
            PLongInt(P)^ := LongInt(d);
          end;
        rkBranch32:
          begin
            // field = target - end of the instruction; the addend is -4 for a plain call
            T0 := Scall + QWord(r^.Addend);
            d := Int64(T0 - Pv);
            if (d >= (Int64(1) shl 31)) or (d < -(Int64(1) shl 31)) then
            begin
              if r^.Addend <> -4 then
              begin
                Say('error ' + o^.UnitName + ': a branch into the middle of ' + what + ' is out of reach');
                Exit;
              end;
              T0 := Veneer(Scall);
              if T0 = 0 then
              begin
                Restart('no room left for call islands');
                Exit;
              end;
              d := Int64(T0 - 4 - Pv);
            end;
            PLongInt(P)^ := LongInt(d);
          end;
        rkPrel64: PQWord(P)^ := S0 + QWord(r^.Addend) - Pv;
        rkBranch26:
          begin
            T0 := Scall + QWord(r^.Addend);
            d := Int64(T0 - Pv);
            if (d >= (Int64(1) shl 27)) or (d < -(Int64(1) shl 27)) then
            begin
              T0 := Veneer(T0);
              if T0 = 0 then
              begin
                Restart('no room left for call islands');
                Exit;
              end;
              d := Int64(T0 - Pv);
            end;
            insn := PLongWord(P)^;
            PLongWord(P)^ := (insn and $fc000000) or (LongWord(SarInt64(d, 2)) and $03ffffff);
          end;
        rkPage21, rkGotPage21:
          begin
            T0 := S0 + QWord(r^.Addend);
            if r^.Kind = rkGotPage21 then
            begin
              if s = nil then begin Say('error ' + o^.UnitName + ': a GOT relocation without a symbol'); Exit; end;
              g := GotFor(s, S0);
              if g = nil then begin Restart('no room left for data'); Exit; end;
              T0 := QWord(PtrUInt(g)) + QWord(r^.Addend);
            end;
            pd := SarInt64(Int64(T0 and not QWord($fff)) - Int64(Pv and not QWord($fff)), 12);
            if (pd >= (Int64(1) shl 20)) or (pd < -(Int64(1) shl 20)) then
            begin
              Say('error ' + o^.UnitName + ': ' + what + ' is out of reach of adrp');
              Exit;
            end;
            insn := PLongWord(P)^;
            PLongWord(P)^ := (insn and $9f00001f) or (LongWord(pd and 3) shl 29) or (LongWord((pd shr 2) and $7ffff) shl 5);
          end;
        rkPageOff12, rkGotPageOff12:
          begin
            T0 := S0 + QWord(r^.Addend);
            if r^.Kind = rkGotPageOff12 then
            begin
              if s = nil then begin Say('error ' + o^.UnitName + ': a GOT relocation without a symbol'); Exit; end;
              g := GotFor(s, S0);
              if g = nil then begin Restart('no room left for data'); Exit; end;
              T0 := QWord(PtrUInt(g)) + QWord(r^.Addend);
            end;
            insn := PLongWord(P)^;
            off := LongWord(T0 and $fff);
            shift := 0;
            if (insn and $3b000000) = $39000000 then   // load or store: the offset is scaled
            begin
              shift := insn shr 30;
              if (shift = 0) and ((insn and $04800000) = $04800000) then shift := 4;
              if (off and ((LongWord(1) shl shift) - 1)) <> 0 then
              begin
                Say('error ' + o^.UnitName + ': misaligned load of ' + what);
                Exit;
              end;
            end;
            PLongWord(P)^ := (insn and $ffc003ff) or ((off shr shift) shl 10);
          end;
        rkGotPcrel32, rkGotAbs64:
          begin
            if s = nil then begin Say('error ' + o^.UnitName + ': a GOT relocation without a symbol'); Exit; end;
            g := GotFor(s, S0);
            if g = nil then begin Restart('no room left for data'); Exit; end;
            if r^.Kind = rkGotPcrel32 then PLongInt(P)^ := LongInt(Int64(QWord(PtrUInt(g)) + QWord(r^.Addend) - Pv))
            else PQWord(P)^ := QWord(PtrUInt(g));
          end;
{$ifdef windows}
        rkRva32:
          begin
            d := Int64(S0 + QWord(r^.Addend) - g_image_base);
            if (d < 0) or (d > $ffffffff) then
            begin
              Say('error ' + o^.UnitName + ': ' + what + ' is out of reach of a 32-bit offset from the image base');
              Exit;
            end;
            PLongWord(P)^ := LongWord(d);
          end;
{$endif}
        rkTpOff32, rkTpOff64, rkTprelHi12, rkTprelLo12:
          begin
            if (s = nil) or not s^.Tls then
            begin
              Say('error ' + o^.UnitName + ': a thread-variable relocation to ' + what + ', which is not a thread variable of the program');
              Exit;
            end;
{$ifdef cpux86_64}
            // variant II: the thread pointer is at the end of the executable's TLS block
            d := Int64(S0) + r^.Addend - Int64((g_tls_memsz + g_tls_align - 1) and not (g_tls_align - 1));
{$else}
            // variant I: the block follows a 16-byte thread control block
            d := Int64((16 + g_tls_align - 1) and not (g_tls_align - 1)) + Int64(S0) + r^.Addend;
{$endif}
            case r^.Kind of
              rkTpOff32:
                begin
                  if (d >= (Int64(1) shl 31)) or (d < -(Int64(1) shl 31)) then begin Say('error ' + o^.UnitName + ': thread variable ' + what + ' out of reach'); Exit; end;
                  PLongInt(P)^ := LongInt(d);
                end;
              rkTpOff64: PInt64(P)^ := d;
              rkTprelHi12:
                begin
                  if (d < 0) or (d >= (Int64(1) shl 24)) then begin Say('error ' + o^.UnitName + ': thread variable ' + what + ' out of reach'); Exit; end;
                  insn := PLongWord(P)^;
                  PLongWord(P)^ := (insn and $ffc003ff) or (LongWord((d shr 12) and $fff) shl 10);
                end;
              rkTprelLo12:
                begin
                  insn := PLongWord(P)^;
                  PLongWord(P)^ := (insn and $ffc003ff) or (LongWord(d and $fff) shl 10);
                end;
            else
            end;
          end;
      else
        Say('error ' + o^.UnitName + ': unsupported relocation type ' + IStr(r^.Sym2) + ' (thread-local variables of the system are not handled)');
        Exit;
      end;
    end;
  end;
  Result := True;
end;

// ================================================================ the system: rewriting the program's code
procedure SortPatches;
var
  i, j: SizeInt;
  t: TPatch;
begin
  for i := 1 to g_npatch - 1 do
  begin
    t := g_patches[i];
    j := i - 1;
    while (j >= 0) and (g_patches[j].Addr > t.Addr) do
    begin
      g_patches[j + 1] := g_patches[j];
      Dec(j);
    end;
    g_patches[j + 1] := t;
  end;
end;

var
  g_patch_err: AnsiString;   // set while other threads are stopped (a constant: no allocation), reported after
  g_patch_kr: LongInt;

// Overwrite one instruction each at a set of addresses, with the other threads stopped
// and without allocating.
{$if defined(darwin)}
// Pages of the program's __TEXT are replaced atomically: copy the page elsewhere, write the
// copy, map it back over the original. The copy with VM_PROT_COPY is what code signing allows.
function ApplyPatches: Boolean;
var
  task: mach_port_t;
  i, first: SizeInt;
  a, page, copy, dst: QWord;
  cur, max: LongInt;
  kr: kern_return_t;
begin
  Result := True;
  if g_npatch = 0 then Exit;
  task := mach_task_self_;
  i := 0;
  while i < g_npatch do
  begin
    a := g_patches[i].Addr;
    if InJit(a) then
    begin
      Move(g_patches[i].B[0], PByte(PtrUInt(a))^, g_patches[i].Len);
      ClearCache(Pointer(PtrUInt(a)), g_patches[i].Len);
      Inc(i);
      Inc(g_patched);
      Continue;
    end;
    page := a and not (g_page - 1);
    first := i;
    copy := 0;
    kr := mach_vm_remap(task, copy, g_page, 0, 1 {VM_FLAGS_ANYWHERE}, task, page, 1, cur, max, 2 {VM_INHERIT_NONE});
    if kr = 0 then kr := mach_vm_protect(task, copy, g_page, 0, 1 or 2 or $10 {READ, WRITE, COPY});
    if kr <> 0 then
    begin
      g_patch_kr := kr;
      g_patch_err := 'cannot copy a code page of the program';
      Exit(False);
    end;
    while (i < g_npatch) and ((g_patches[i].Addr and not (g_page - 1)) = page) do
    begin
      Move(g_patches[i].B[0], PByte(PtrUInt(copy + (g_patches[i].Addr - page)))^, g_patches[i].Len);
      Inc(i);
    end;
    kr := mach_vm_protect(task, copy, g_page, 0, 1 or 4 {READ, EXECUTE});
    dst := page;
    if kr = 0 then kr := mach_vm_remap(task, dst, g_page, 0, $4000 {VM_FLAGS_FIXED or VM_FLAGS_OVERWRITE}, task, copy, 0, cur, max, 2);
    if kr <> 0 then
    begin
      g_patch_kr := kr;
      g_patch_err := 'cannot replace a code page of the program';
      Exit(False);
    end;
    Inc(g_patched, i - first);
    mach_vm_deallocate(task, copy, g_page);
    ClearCache(Pointer(PtrUInt(page)), g_page);
  end;
end;

procedure MakeWritable(a: QWord);
begin
  mach_vm_protect(mach_task_self_, a and not (g_page - 1), g_page, 0, 1 or 2);
end;

var
  g_threads: PLongWord;
  g_nthreads: LongWord;

procedure WorldStop;
var
  me: mach_port_t;
  i: LongWord;
begin
  if not g_suspend then Exit;
  me := mach_thread_self;
  if task_threads(mach_task_self_, g_threads, g_nthreads) <> 0 then
  begin
    g_nthreads := 0;
    Exit;
  end;
  for i := 0 to g_nthreads - 1 do
    if g_threads[i] <> me then thread_suspend(g_threads[i]);
  mach_port_deallocate(mach_task_self_, me);
end;

procedure WorldStart;
var
  me: mach_port_t;
  i: LongWord;
begin
  if not g_suspend or (g_nthreads = 0) then Exit;
  me := mach_thread_self;
  for i := 0 to g_nthreads - 1 do
  begin
    if g_threads[i] <> me then thread_resume(g_threads[i]);
    mach_port_deallocate(mach_task_self_, g_threads[i]);
  end;
  mach_port_deallocate(mach_task_self_, me);
  vm_deallocate(mach_task_self_, PtrUInt(g_threads), g_nthreads * SizeOf(LongWord));
  g_nthreads := 0;
end;

procedure SetupWorldStop;
begin
end;

function StoppedInsidePatch: Boolean;
begin
  Result := False;   // aarch64: a patch is one instruction
end;
{$elseif defined(linux)}
// Linux: make the pages writable, write, make them executable again. The other threads are
// stopped; on x86-64 none of them is inside the bytes written (StoppedInsidePatch).
function ApplyPatches: Boolean;
var
  i: SizeInt;
  a, lo, hi: QWord;
begin
  Result := True;
  for i := 0 to g_npatch - 1 do
  begin
    a := g_patches[i].Addr;
    if InJit(a) then
    begin
      Move(g_patches[i].B[0], PByte(PtrUInt(a))^, g_patches[i].Len);
      ClearCache(Pointer(PtrUInt(a)), g_patches[i].Len);
      Inc(g_patched);
      Continue;
    end;
    lo := a and not (g_page - 1);
    hi := (a + QWord(g_patches[i].Len) + g_page - 1) and not (g_page - 1);   // a patch can cross a page
    if mprotect(Pointer(PtrUInt(lo)), hi - lo, PROT_R or PROT_W or PROT_X) <> 0 then
    begin
      g_patch_err := 'cannot make a code page of the program writable';
      Exit(False);
    end;
    Move(g_patches[i].B[0], PByte(PtrUInt(a))^, g_patches[i].Len);
    mprotect(Pointer(PtrUInt(lo)), hi - lo, PROT_R or PROT_X);
    ClearCache(Pointer(PtrUInt(a)), g_patches[i].Len);
    Inc(g_patched);
  end;
end;

procedure MakeWritable(a: QWord);
begin
  mprotect(Pointer(PtrUInt(a and not (g_page - 1))), g_page, PROT_R or PROT_W);
end;

// Linux has no call that suspends another thread: send each one a signal whose handler
// waits until the agent lets it go. The thread list is read before the first signal, so
// that nothing is allocated while a stopped thread may hold a lock.
var
  g_hold, g_parked, g_arrived: LongInt;
  g_tids: array[0..4095] of LongInt;
  g_ntids: LongInt;
  g_pcs: array[0..4095] of QWord;   // where each stopped thread was

procedure ParkHandler(sig: LongInt; info: PSigInfo; ctx: PSigContext); cdecl;
var
  k: LongInt;
begin
  k := InterLockedIncrement(g_arrived) - 1;
{$ifdef cpux86_64}
  // ucontext_t: uc_flags, uc_link, uc_stack (24 bytes), then the registers; rip is the 17th
  if (k >= 0) and (k <= High(g_pcs)) and (ctx <> nil) then g_pcs[k] := PQWord(PByte(ctx) + 40 + 16 * 8)^;
{$endif}
  InterLockedIncrement(g_parked);
  while InterlockedCompareExchange(g_hold, 0, 0) <> 0 do ;
  InterLockedDecrement(g_parked);
end;

// A thread stopped after the first byte of an entry about to be overwritten would resume in
// the middle of the new jump.
function StoppedInsidePatch: Boolean;
var
  k, n: LongInt;
  i: SizeInt;
begin
  Result := False;
{$ifdef cpux86_64}
  n := InterlockedCompareExchange(g_arrived, 0, 0);
  if n > Length(g_pcs) then n := Length(g_pcs);
  for k := 0 to n - 1 do
    for i := 0 to g_npatch - 1 do
      if (g_pcs[k] > g_patches[i].Addr) and (g_pcs[k] < g_patches[i].Addr + QWord(g_patches[i].Len)) then Exit(True);
{$endif}
end;

procedure SetupWorldStop;
var
  act: SigActionRec;
begin
  FillChar(act, SizeOf(act), 0);
  act.sa_handler := SigActionHandler(@ParkHandler);
  act.sa_flags := SA_SIGINFO or SA_RESTART;
  FpSigAction(PARK_SIG, @act, nil);
end;

procedure ListThreads;
var
  d: pDir;
  e: pDirent;
  v, code: LongInt;
begin
  g_ntids := 0;
  d := FpOpendir('/proc/self/task');
  if d = nil then Exit;
  repeat
    e := FpReaddir(d^);
    if e = nil then Break;
    Val(AnsiString(PChar(@e^.d_name[0])), v, code);
    if (code = 0) and (g_ntids <= High(g_tids)) then
    begin
      g_tids[g_ntids] := v;
      Inc(g_ntids);
    end;
  until False;
  FpClosedir(d^);
end;

procedure WorldStop;
var
  me, pid, i, sent: LongInt;
  t0: Double;
begin
  if not g_suspend then Exit;
  ListThreads;
  me := gettid;
  pid := FpGetpid;
  InterLockedExchange(g_hold, 1);
  InterLockedExchange(g_arrived, 0);
  sent := 0;
  for i := 0 to g_ntids - 1 do
    if (g_tids[i] <> me) and (tgkill(pid, g_tids[i], PARK_SIG) = 0) then Inc(sent);
  t0 := NowMs;
  while (InterlockedCompareExchange(g_parked, 0, 0) < sent) and (NowMs - t0 < 2000) do ;
end;

procedure WorldStart;
var
  t0: Double;
begin
  if not g_suspend then Exit;
  InterLockedExchange(g_hold, 0);
  t0 := NowMs;
  while (InterlockedCompareExchange(g_parked, 0, 0) > 0) and (NowMs - t0 < 2000) do ;
end;
{$else}
// Windows: VirtualProtect around each write. The other threads are stopped, and none of
// them is inside the bytes written (StoppedInsidePatch).
function ApplyPatches: Boolean;
var
  i: SizeInt;
  a: QWord;
  old, dummy: LongWord;
begin
  Result := True;
  for i := 0 to g_npatch - 1 do
  begin
    a := g_patches[i].Addr;
    if InJit(a) then
    begin
      Move(g_patches[i].B[0], PByte(PtrUInt(a))^, g_patches[i].Len);
      Inc(g_patched);
      Continue;
    end;
    if not VirtualProtect(Pointer(PtrUInt(a)), g_patches[i].Len, PAGE_EXECUTE_READWRITE, old) then
    begin
      g_patch_err := 'cannot make a code page of the program writable';
      Exit(False);
    end;
    Move(g_patches[i].B[0], PByte(PtrUInt(a))^, g_patches[i].Len);
    VirtualProtect(Pointer(PtrUInt(a)), g_patches[i].Len, old, dummy);
    Inc(g_patched);
  end;
  FlushInstructionCache(GetCurrentProcess, nil, 0);
end;

procedure MakeWritable(a: QWord);
var
  old: LongWord;
begin
  VirtualProtect(Pointer(PtrUInt(a)), 8, PAGE_READWRITE, old);
end;

// SuspendThread for every other thread of the process; GetThreadContext waits until a
// thread has really stopped and says where. The list and handles are made first, so that
// nothing is allocated while a stopped thread may hold a lock.
var
  g_thr: array[0..4095] of THandle_;
  g_nthr: LongInt;
  g_pcs: array[0..4095] of QWord;
  g_npcs: LongInt;
  g_ctxbuf: array[0..1232 + 64] of Byte;   // CONTEXT, 16-byte aligned inside

procedure WorldStop;
var
  snap, h: THandle_;
  te: TThreadEntry32;
  me, pid: LongWord;
  ctx: PByte;
  i: LongInt;
begin
  g_nthr := 0;
  g_npcs := 0;
  if not g_suspend then Exit;
  me := GetCurrentThreadId;
  pid := GetCurrentProcessId;
  snap := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if snap = INVALID_HANDLE then Exit;
  te.dwSize := SizeOf(te);
  if Thread32First(snap, te) then
    repeat
      if (te.th32OwnerProcessID = pid) and (te.th32ThreadID <> me) and (g_nthr <= High(g_thr)) then
      begin
        h := OpenThread(THREAD_SUSPEND_RESUME or THREAD_GET_CONTEXT, False, te.th32ThreadID);
        if h <> 0 then
        begin
          g_thr[g_nthr] := h;
          Inc(g_nthr);
        end;
      end;
      te.dwSize := SizeOf(te);
    until not Thread32Next(snap, te);
  CloseHandle(snap);
  ctx := PByte((PtrUInt(@g_ctxbuf[0]) + 15) and not PtrUInt(15));
  for i := 0 to g_nthr - 1 do
    if SuspendThread(g_thr[i]) <> LongWord(-1) then
    begin
      FillChar(ctx^, 1232, 0);
      PLongWord(ctx + $30)^ := CONTEXT_CONTROL_AMD64;   // ContextFlags
      if GetThreadContext(g_thr[i], ctx) and (g_npcs <= High(g_pcs)) then
      begin
        g_pcs[g_npcs] := PQWord(ctx + $f8)^;            // Rip
        Inc(g_npcs);
      end;
    end;
end;

procedure WorldStart;
var
  i: LongInt;
begin
  for i := 0 to g_nthr - 1 do
  begin
    ResumeThread(g_thr[i]);
    CloseHandle(g_thr[i]);
  end;
  g_nthr := 0;
end;

procedure SetupWorldStop;
begin
end;

// A thread stopped after the first byte of an entry about to be overwritten would resume in
// the middle of the new jump.
function StoppedInsidePatch: Boolean;
var
  k: LongInt;
  i: SizeInt;
begin
  Result := False;
  for k := 0 to g_npcs - 1 do
    for i := 0 to g_npatch - 1 do
      if (g_pcs[k] > g_patches[i].Addr) and (g_pcs[k] < g_patches[i].Addr + QWord(g_patches[i].Len)) then Exit(True);
end;
{$endif}

{$ifdef windows}
// Win64 exceptions unwind through tables: code without an entry would be taken for a leaf
// function and the unwinder would lose its way. The entries of the loaded .pdata sections
// (begin, end, unwind info; offsets from the image base after relocation) go into one sorted
// table per load, registered with the system. table: nil when there were none.
function RegisterUnwind(const objs: array of PObj; out table: Pointer): Boolean;
var
  n, i, k, j, m: SizeInt;
  t: PSect;
  tab: PLongWord;
  e: array[0..2] of LongWord;
begin
  Result := True;
  table := nil;
  n := 0;
  for i := 0 to High(objs) do
    for k := 0 to High(objs[i]^.Sect) do
      if (objs[i]^.Sect[k].Base <> nil) and objs[i]^.Sect[k].Live and StartsWith(objs[i]^.Sect[k].Name, '.pdata') then Inc(n, objs[i]^.Sect[k].Size div 12);
  if n = 0 then Exit;
  tab := PLongWord(Bump(g_data_next, g_data + DATA_SIZE, n * 12, 8));
  if tab = nil then Exit(False);
  m := 0;
  for i := 0 to High(objs) do
    for k := 0 to High(objs[i]^.Sect) do
    begin
      t := @objs[i]^.Sect[k];
      if (t^.Base = nil) or not t^.Live or not StartsWith(t^.Name, '.pdata') then Continue;
      Move(t^.Base^, tab[m * 3], (t^.Size div 12) * 12);
      Inc(m, t^.Size div 12);
    end;
  for i := 1 to n - 1 do   // by begin address
  begin
    Move(tab[i * 3], e[0], 12);
    j := i - 1;
    while (j >= 0) and (tab[j * 3] > e[0]) do
    begin
      Move(tab[j * 3], tab[(j + 1) * 3], 12);
      Dec(j);
    end;
    Move(e[0], tab[(j + 1) * 3], 12);
  end;
  Result := RtlAddFunctionTable(tab, n, g_image_base);
  if Result then table := tab;
end;
{$endif}

// ================================================================ one load transaction
procedure CmdLoad(const paths: array of AnsiString);
var
  t0, t1, t2, t3: Double;
  objs: array of PObj;
  save_jit, save_data, save_island, save_veneer: PByte;
  ok, pr: Boolean;
  i, k: SizeInt;
  c: TCounts;
  bytes: QWord;
  vmt_words, n_redirect: LongInt;
  s: PSym;
  old_cur, via: QWord;
  d: Int64;
  nw, ow: PQWord;
  old: PObj;
  a: QWord;
  clear: Boolean;
  attempt: LongInt;
  unwind: Pointer;
begin
  unwind := nil;
  t0 := NowMs;
  BuildHostSymbols;
  if not RegionsInit then
  begin
    Say('refused');
    Exit;
  end;
  if g_poisoned then
  begin
    Say('restart an earlier reload failed after some functions were already redirected');
    Say('refused');
    Exit;
  end;
  SetLength(objs, Length(paths));
  // Code and data of a load that is not applied are given back. Slots, islands and veneers
  // are not: the veneer cache and the records of functions keep pointing at them, and
  // handing one out twice would send a call to the wrong function.
  save_jit := g_jit_next;
  save_data := g_data_next;
  save_island := g_island_next;
  save_veneer := g_veneer_next;
  g_restart := 0;
  g_npending := 0;
  g_npatch := 0;
  g_nstore := 0;
  g_nvmt := 0;
  g_ncopy := 0;
  g_patch_err := '';
  g_patch_kr := 0;
  ok := True;
  for i := 0 to High(paths) do
  begin
    objs[i] := ObjParse(paths[i]);
    if objs[i] = nil then
    begin
      ok := False;
      Break;
    end;
    objs[i]^.Prev := MapGet(g_units, objs[i]^.UnitName);
  end;
  t1 := NowMs;
  FillChar(c, SizeOf(c), 0);
  bytes := 0;
  if ok then
  begin
    JitWritable(True);
    for i := 0 to High(objs) do
      if ok and not PlaceSections(objs[i]) then ok := False;
    if ok then for i := 0 to High(objs) do BindSymbols(objs[i], c);
    if ok then
    begin
      MarkLive(objs);
      for i := 0 to High(objs) do Unregister(objs[i]);
    end;
    if ok then for i := 0 to High(objs) do ResolveUndefined(objs[i]);
    if g_restart > 0 then ok := False;
    if ok then for i := 0 to High(objs) do CopySections(objs[i]);
    if ok then for i := 0 to High(objs) do
      if ok and not Relocate(objs[i]) then ok := False;
{$ifdef windows}
    if ok and not RegisterUnwind(objs, unwind) then
    begin
      Say('error the system did not take the unwind tables of the new code');
      ok := False;
    end;
{$endif}
    if ok then ClearCache(save_jit, g_jit_next - save_jit);
    if g_veneer_next > save_veneer then ClearCache(save_veneer, g_veneer_next - save_veneer);
  end;
  t2 := NowMs;
  vmt_words := 0;
  n_redirect := 0;
  if ok then
  begin
    // Everything below is the commit. Collect the writes first, then stop the other
    // threads for the few microseconds the writes take.
    for i := 0 to g_npending - 1 do
    begin
      s := g_pending[i];
      if s^.Kind <> K_CODE then Continue;
      if s^.Cur <> 0 then old_cur := s^.Cur
      else if s^.PCanon <> s^.PCur then old_cur := s^.PCanon
      else old_cur := 0;
      if old_cur = 0 then Continue;   // a new function: nothing to redirect
      if s^.Slot = nil then
      begin
        s^.Slot := NewSlot(s^.PCur);
        if s^.Slot <> nil then s^.Island := MakeIsland(s^.Slot) else s^.Island := 0;
        if s^.Island = 0 then
        begin
          Restart('no room left for call islands');
          ok := False;
          Break;
        end;
      end
      else AddStore(s^.Slot, s^.PCur);
      // The entry being retired is in the program's text the first time and in the code
      // region afterwards; the two can be more than a branch apart, so each has its island.
      via := s^.Island;
      if (old_cur >= QWord(PtrUInt(g_jit))) and (old_cur < QWord(PtrUInt(g_jit)) + JIT_SIZE) then
      begin
        if s^.IslandFar = 0 then s^.IslandFar := MakeVeneer(s^.Slot);
        if s^.IslandFar = 0 then
        begin
          Restart('no room left for call islands');
          ok := False;
          Break;
        end;
        via := s^.IslandFar;
      end;
      d := Int64(via - old_cur);
      if (d >= BRANCH_REACH) or (d < -BRANCH_REACH) then
      begin
        Say('error ' + Pretty(s^.Name) + ' is out of reach of its island');
        ok := False;
        Break;
      end;
      AddPatch(RedirectPatch(old_cur, via));
      Inc(n_redirect);
    end;
    if g_island_next > save_island then ClearCache(save_island, g_island_next - save_island);
    if g_veneer_next > save_veneer then ClearCache(save_veneer, g_veneer_next - save_veneer);
  end;
  if ok then
  begin
    for i := 0 to g_nvmt - 1 do
    begin
      nw := PQWord(PtrUInt(Placed(g_vmts[i].O, g_vmts[i].S)));
      ow := PQWord(PtrUInt(g_vmts[i].OldAddr));
      for k := 0 to SizeInt(g_vmts[i].S^.Size div 8) - 1 do
      begin
        if k = 3 then Continue;   // the class name: equal text, another address
        if nw[k] <> ow[k] then
        begin
          AddStore(@ow[k], nw[k]);
          Inc(vmt_words);
        end;
      end;
    end;
    // Tables of the program (VMTs) may sit in a segment that is read-only.
    for i := 0 to g_nstore - 1 do
    begin
      a := QWord(PtrUInt(g_stores[i].Dst));
      if (a < QWord(PtrUInt(g_data))) or (a >= QWord(PtrUInt(g_data)) + DATA_SIZE) then MakeWritable(a);
    end;
    SortPatches;
    g_patched := 0;
    clear := False;
    for attempt := 1 to 200 do
    begin
      WorldStop;
      if not StoppedInsidePatch then
      begin
        clear := True;
        Break;
      end;
      WorldStart;
      Nap(1);
    end;
    if not clear then
    begin
      g_patch_err := 'a thread stayed inside the first bytes of a function being redirected';
      pr := False;   // nothing written; the threads already run again
    end
    else pr := ApplyPatches;
    if pr then
    begin
      for i := 0 to g_nstore - 1 do InterLockedExchange64(PInt64(g_stores[i].Dst)^, Int64(g_stores[i].Val));
      for i := 0 to g_ncopy - 1 do Move(g_copies[i].Src^, PByte(PtrUInt(g_copies[i].Dst))^, g_copies[i].Size);
    end;
    WorldStart;
    if not pr then
    begin
      ok := False;
{$ifdef darwin}
      if g_patch_kr <> 0 then g_patch_err := g_patch_err + ': ' + AnsiString(mach_error_string(g_patch_kr));
{$endif}
      Say('error ' + g_patch_err);
      // Some entries already branch to islands whose slots name the new code: that code
      // must stay where it is, and nothing more can be trusted to apply cleanly.
      if g_patched > 0 then
      begin
        g_poisoned := True;
        save_jit := g_jit_next;
        save_data := g_data_next;
        Say('error the reload stopped halfway: ' + IStr(g_patched) + ' functions are redirected and the rest are not; restart the program');
      end;
    end;
  end;
  JitWritable(False);
  t3 := NowMs;
  if ok then
  begin
    for i := 0 to g_npending - 1 do
    begin
      s := g_pending[i];
      s^.Canon := s^.PCanon;
      s^.Cur := s^.PCur;
      s^.Pending := False;
    end;
    for i := 0 to High(objs) do
    begin
      for k := 0 to High(objs[i]^.Sect) do
        if objs[i]^.Sect[k].Kind in [K_CODE, K_DATA] then Inc(bytes, objs[i]^.Sect[k].Size);
      old := objs[i]^.Prev;
      objs[i]^.Prev := nil;
      MapPut(g_units, objs[i]^.UnitName, objs[i]);
      ObjFree(old);
    end;
    Say('stat units=' + IStr(Length(objs)) + ' functions=' + IStr(c.Func) + ' changed=' + IStr(c.Changed) + ' added=' + IStr(c.Added)
      + ' redirected=' + IStr(n_redirect) + ' kept=' + IStr(c.Kept) + ' newdata=' + IStr(c.NewData) + ' vmtwords=' + IStr(vmt_words) + ' bytes=' + UStr(bytes));
    Say('time parse=' + FStr(t1 - t0) + ' place=' + FStr(t2 - t1) + ' commit=' + FStr(t3 - t2) + ' total=' + FStr(t3 - t0) + ' hostsyms=' + FStr(g_host_ms));
    g_host_ms := 0;
    Say('ok');
  end
  else
  begin
    for i := 0 to g_npending - 1 do g_pending[i]^.Pending := False;
{$ifdef windows}
    if unwind <> nil then RtlDeleteFunctionTable(unwind);
{$endif}
    if unwind <> nil then;
    g_jit_next := save_jit;
    g_data_next := save_data;
    for i := 0 to High(objs) do ObjFree(objs[i]);
    Say('time total=' + FStr(NowMs - t0));
    if g_restart > 0 then Say('refused') else Say('failed');
  end;
end;

procedure CmdBase(const path: AnsiString);
var
  o, old: PObj;
begin
  o := ObjParse(path);
  if o = nil then
  begin
    Say('failed');
    Exit;
  end;
  old := MapGet(g_units, o^.UnitName);
  MapPut(g_units, o^.UnitName, o);
  ObjFree(old);
  Say('ok');
end;

// ================================================================ the agent's thread
// The driver listens on 127.0.0.1 (TCP works the same on every system, and between a
// program under Wine and a driver outside it). The token tells it that this is the program
// it started, not one that program started in turn.
//
// The program can end while the agent's thread works: then the units' finalization frees
// what the agent's globals refer to. The thread is busy except while it waits for a
// command; this unit's finalization, which runs after every unit of the program, waits for
// it to be idle, and the thread does nothing more once it sees g_exiting.
var
  g_token: array[0..255] of Char;   // not managed: valid during finalization too
  g_port: Word;
  g_busy, g_exiting: LongInt;
  g_connected: Boolean;

{$ifdef windows}
var
  g_sock: PtrUInt;

function SockConnect(port: Word): Boolean;
var
  wsa: array[0..1023] of Byte;
  a: TSockAddrIn;
begin
  Result := False;
  if WSAStartup($0202, @wsa[0]) <> 0 then Exit;
  g_sock := ws_socket(2 {AF_INET}, 1 {SOCK_STREAM}, 6 {IPPROTO_TCP});
  if g_sock = PtrUInt(-1) then Exit;
  FillChar(a, SizeOf(a), 0);
  a.sin_family := 2;
  a.sin_port := Swap(port);
  a.sin_addr := $0100007f;   // 127.0.0.1 in network order
  Result := ws_connect(g_sock, @a, SizeOf(a)) = 0;
end;

function SockSend(p: PChar; n: LongInt): LongInt;
begin
  Result := ws_send(g_sock, p, n, 0);
end;

function SockRecv(p: PChar; n: LongInt): LongInt;
begin
  Result := ws_recv(g_sock, p, n, 0);
end;

procedure SockShutdown;
begin
  ws_shutdown(g_sock, 2);
end;
{$else}
var
  g_sock: cint;

function SockConnect(port: Word): Boolean;
var
  a: TInetSockAddr;
begin
  g_sock := FpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(a, SizeOf(a), 0);
  a.sin_family := AF_INET;
  a.sin_port := htons(port);
  a.sin_addr.s_addr := htonl($7f000001);
  Result := (g_sock >= 0) and (FpConnect(g_sock, @a, SizeOf(a)) = 0);
end;

function SockSend(p: PChar; n: LongInt): LongInt;
begin
  Result := FpSend(g_sock, p, n, 0);
end;

function SockRecv(p: PChar; n: LongInt): LongInt;
begin
  Result := FpRecv(g_sock, p, n, 0);
end;

procedure SockShutdown;
begin
  FpShutdown(g_sock, 2);
end;
{$endif}

// Busy from here on, unless the program is ending: then wait for the process to go.
procedure EnterBusy;
begin
  InterLockedExchange(g_busy, 1);
  if InterlockedCompareExchange(g_exiting, 0, 0) <> 0 then
  begin
    InterLockedExchange(g_busy, 0);
    repeat
      Nap(3600000);
    until False;
  end;
end;

function SendAll(const s: AnsiString): Boolean;
var
  off, n: SizeInt;
begin
  off := 0;
  while off < Length(s) do
  begin
    n := SockSend(PChar(s) + off, Length(s) - off);
    if n <= 0 then Exit(False);
    Inc(off, n);
  end;
  Result := True;
end;

function AgentMain(arg: Pointer): PtrInt;
var
{$ifdef unix}
  all: array[0..127] of Byte;
{$endif}
  buf: array[0..65535] of Char;
  pending, line: AnsiString;
  n, nl: SizeInt;
  argv: array of AnsiString;
  tok: AnsiString;
  i: SizeInt;
begin
  Result := 0;
  EnterBusy;
{$ifdef unix}
  FillChar(all, SizeOf(all), $ff);
  pthread_sigmask(SIG_BLOCK_HOW, @all, nil);   // the program's signals are not for this thread
{$endif}
  if not SockConnect(g_port) then
  begin
    WriteLn(StdErr, '[hotagent] cannot reach the driver at 127.0.0.1:', g_port);
    InterLockedExchange(g_busy, 0);
    Exit;
  end;
  g_connected := True;
  FindProgram;
  SetupWorldStop;
  g_reply := '';
  RegionsInit;   // early: before the program's allocator claims the neighbourhood
  g_reply := '';
  if not SendAll('hello ' + AnsiString(PChar(@g_token[0])) + #10) then
  begin
    InterLockedExchange(g_busy, 0);
    Exit;
  end;
  pending := '';
  repeat
    InterLockedExchange(g_busy, 0);
    n := SockRecv(@buf[0], SizeOf(buf));
    EnterBusy;
    if n <= 0 then Break;
    SetLength(line, n);
    Move(buf, line[1], n);
    pending := pending + line;
    repeat
      nl := Pos(#10, pending);
      if nl = 0 then Break;
      line := Copy(pending, 1, nl - 1);
      Delete(pending, 1, nl);
      while (line <> '') and (line[Length(line)] = #13) do SetLength(line, Length(line) - 1);
      SetLength(argv, 0);
      while line <> '' do
      begin
        i := Pos(#9, line);
        if i = 0 then i := Length(line) + 1;
        tok := Copy(line, 1, i - 1);
        Delete(line, 1, i);
        if tok <> '' then
        begin
          SetLength(argv, Length(argv) + 1);
          argv[High(argv)] := tok;
        end;
      end;
      if Length(argv) = 0 then Continue;
      g_reply := '';
      if argv[0] = 'ping' then Say('pong')
      else if (argv[0] = 'base') and (Length(argv) = 2) then CmdBase(argv[1])
      else if (argv[0] = 'load') and (Length(argv) >= 2) then CmdLoad(Copy(argv, 1, Length(argv) - 1))
      else
      begin
        Say('error unknown command');
        Say('failed');
      end;
      Say('.');
      if not SendAll(g_reply) then Break;
    until False;
  until False;
  InterLockedExchange(g_busy, 0);
end;

procedure StartAgent;
var
  v: AnsiString;
  port, code: LongInt;
  n: SizeInt;
begin
  if not EnvVar('HOT_PORT', v) then Exit;
  Val(v, port, code);
  if (code <> 0) or (port <= 0) or (port > 65535) then Exit;
  g_port := port;
  EnvVar('HOT_TOKEN', v);
  n := Length(v);
  if n > High(g_token) then n := High(g_token);
  if n > 0 then Move(v[1], g_token[0], n);
  g_token[n] := #0;
  if EnvVar('HOT_NOSUSPEND', v) then g_suspend := False;
{$ifdef unix}
  g_page := PtrUInt(getpagesize);
{$else}
  g_page := 4096;
{$endif}
  // A program this one starts must not take the driver for its own.
  UnsetEnv('HOT_PORT');
  UnsetEnv('HOT_TOKEN');
  BeginThread(@AgentMain, nil);
end;

procedure StopAgent;
var
  t0: Double;
begin
  InterLockedExchange(g_exiting, 1);
  t0 := NowMs;
  while (InterlockedCompareExchange(g_busy, 0, 0) <> 0) and (NowMs - t0 < 2000) do Nap(1);
  if g_connected then SockShutdown;
end;

initialization
  StartAgent;

finalization
  StopAgent;
end.
