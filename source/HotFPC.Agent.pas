unit HotFPC.Agent;
{ HotFPC.Agent: the in-process agent for hot reloading Free Pascal programs, as a unit.

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
{$mode delphi}{$H+}
{ Typed constants are read-only; Delphi mode would make them writable. }
{$J-}
{ The agent works on raw addresses and machine words inside the user's program: wrapping
  arithmetic is intended, and a failed check would end that program. }
{$overflowchecks off}
{$rangechecks off}
{ Addresses are added to typed pointers (PByte + offset) throughout. }
{$pointermath on}
{ fpc 3.3.1 from fpc-toolchain before release 3.3.1+4 gave a loop counter and a temporary
  string the same register on x86-64 at -O1 and above (docs/how-it-works.md, "A compiler
  bug"). fpc -iV cannot tell those builds from fixed ones, so every 3.3.1 compiles the agent
  without optimisation. It does not need the speed. }
{$IF FPC_FULLVERSION >= 30301}
  {$optimization off}
{$ENDIF}
interface

{$ifdef unix}
uses
  cthreads;
{$endif}

procedure HotAnchor;

implementation

{$ifdef unix}
uses
  baseunix,
  sockets;
{$endif}

{$if not (defined(darwin) and defined(cpuaarch64)) and not (defined(linux) and (defined(cpuaarch64) or defined(cpux86_64))) and not (defined(win64) and defined(cpux86_64))}
  {$error HotFPC.Agent: Darwin on aarch64, Linux on aarch64 or x86-64, Windows on x86-64 so far}
{$endif}

const
  KindCode = 1;
  KindData = 2;
  KindTLS = 3;    // a thread variable of the system's own kind (ELF TLS): never placed, only bound
  IslandAreaSize = QWord(2) shl 20;   // redirect islands: must be within reach of a branch from the program's text
  JITSize = QWord(96) shl 20;     // new code, with its own veneers at the start
{$ifdef cpuaarch64}
  BranchReach = Int64(1) shl 27;  // b, bl: +-128 MiB
  IslandReach = Int64(127) shl 20;
  RegionReach = Int64(3) shl 30;  // adrp: +-4 GiB
{$else}
  BranchReach = Int64(1) shl 31;  // jmp, call rel32: +-2 GiB
  IslandReach = (Int64(2) shl 30) - (Int64(64) shl 20);
  RegionReach = (Int64(2) shl 30) - (Int64(64) shl 20);   // rip-relative data: +-2 GiB
{$endif}
  VeneerAreaSize = QWord(2) shl 20;
  DataAreaSize = QWord(256) shl 20;
  SlotAreaSize = QWord(2) shl 20;
  FNVOffsetBasis = QWord(1469598103934665603);
  FNVPrime = QWord(1099511628211);
  SaltStringWithHeader = QWord($9e3779b97f4a7c15);
  SaltAnonymousSymbol = QWord($9e3779b97f4a7c15);
  SaltStringTail = QWord($3c6ef372fe94f82b);
  SaltIndirectPointer = QWord($51ed270b35ae1f3b);
  MaxDigestDepth = 3;
  StringHeaderSize = 16;     // an AnsiString constant: its characters start 16 bytes into it
  StringLengthSize = 8;      // and the word before them is its length
  VMTParentOffset = 16;
  VMTSlotSize = 8;
  VMTClassNameSlot = 3;
  FixedNameLength = 16;
  MaxLongWordValue = $ffffffff;
  Rel32Reach = Int64(1) shl 31;       // a 32-bit pc-relative or signed absolute field
  Branch26Reach = Int64(1) shl 27;
  Page21Reach = Int64(1) shl 20;      // pages, for adrp
  TPRelHi12Reach = Int64(1) shl 24;
  LowMemoryLimit = QWord(2) shl 30;
  HintAlignmentMask = $3fff;
  ReserveStep = QWord(4) shl 20;
  RegionKindData = 0;
  RegionKindIsland = 1;
  RegionKindCode = 2;
  MaxSectionAlignment = 16384;
  MinSectionAlignment = 8;
  CodeAlignment = 16;
  ListGrowthLarge = 256;
  ListGrowthSmall = 64;
  MapInitialSize = 1024;
  StopAttempts = 200;
  ParkTimeoutFailure = 'a thread of the program did not stop';
  BlockerRunningFailure = 'a thread that blocks signals kept running';
  TooManyThreadsFailure = 'the program has more threads than the agent can stop';
  SplitEntryFailure = 'an entry to rewrite could not be written in one store while a thread that blocks signals sleeps';
  StoreSize = 8;
  ParkTimeoutMilliseconds = 2000;
  IdleTimeoutMilliseconds = 2000;
  IdleNapMilliseconds = 3600000;
  MillisecondsPerSecond = 1000;
  NanosecondsPerMillisecond = 1000000;
  QWordHexDigits = 16;
  FloatDecimals = 3;
  FileBufferSlack = 16;
  ReceiveBufferSize = 65536;
  TokenCapacity = 256;
  SignalSetSize = 128;
  MaxPort = 65535;
  MaxThreads = 4096;
  StatusBufferSize = 4096;     // /proc/self/task/N/status
  TaskPathSize = 64;           // /proc/self/task/N/status and a terminating zero
  ShutdownBoth = 2;
  LoopbackAddress = $7f000001;
  UContextRegistersOffset = 40;     // ucontext_t: uc_flags, uc_link, uc_stack (24 bytes), then the registers
  UContextRIPIndex = 16;
  IndirectSuffix = '$indirect';
  IndirectSuffixLength = Length(IndirectSuffix);
  AnonymousDefinitionMarker = '_$$_def0';
  FPCLocalMarker = '$$fpclocal$';
  LocalDataMarker = '_$$_Ld';
  NumberedLiteralMarker = '$_Ld';
  LocalLabelPrefix = '.L';
  PrefixVMT = 'VMT_$';
  PrefixRTTI = 'RTTI_$';
  PrefixInitTable = 'INIT_$';
  PrefixThreadVarList = 'THREADVARLIST_$';
  PrefixTypedConstant = 'TC_$';
  PrefixVariable = 'U_$';
  PrefixResourceString = 'RESSTR_$';
  PrefixUnitInit = 'INIT$_$';
  MainBlockName = 'PASCALMAIN';
  MainSymbolName = 'main';
  SectionSymbolPrefix = '@sect:';
  AnchorSymbolName = 'HOTFPC.AGENT_$$_HOTANCHOR';
  DebugSectionPrefix = '.debug';
  PDataSectionPrefix = '.pdata';
  XDataSectionPrefix = '.xdata';
  EHFrameSectionName = '.eh_frame';
  ARM64IslandInstructions = 3;
  ARM64AdrpX16 = $90000010;
  ARM64LdrX16 = $f9400210;
  ARM64BrX16 = $d61f0200;
  ARM64Branch = $14000000;
  ARM64Imm26Mask = $03ffffff;
  ARM64OpcodeMask = $fc000000;
  ARM64Imm12Bits = 12;
  ARM64Imm12Mask = $fff;
  ARM64ImmHiMask = $7ffff;
  ARM64AdrpKeepMask = $9f00001f;
  ARM64Imm12KeepMask = $ffc003ff;
  ARM64LoadStoreMask = $3b000000;
  ARM64LoadStoreImmediate = $39000000;
  ARM64VectorLoadStore = $04800000;
  ARM64ThreadControlBlockSize = 16;
  ARM64CacheLineBase = 4;
  ARM64CTRDMinLineShift = 16;
  ARM64CTRLineMask = 15;
  X86IslandSize = 8;
  X86IndirectJumpSize = 6;
  X86JumpRel32Size = 5;
  X86OpcodeGroup5 = $ff;
  X86ModRMJumpRIP = $25;
  X86OpcodeJumpRel32 = $e9;
  X86OpcodeCallRel32 = $e8;
  X86OpcodeTwoByte = $0f;
  X86OpcodeJccFirst = $80;
  X86OpcodeJccLast = $8f;
  ProtectRead = 1;
  ProtectWrite = 2;
  ProtectExecute = 4;
  MapPrivate = 2;
{$if defined(darwin)}
  MapAnonymous = $1000;
  MapJIT = $800;
  LowBound = QWord(4) shl 30;     // __PAGEZERO
  ClockMonotonic = 6;
  SignalBlockHow = 1;
{$elseif defined(linux)}
  MapAnonymous = $20;
  MapJIT = 0;
  LowBound = QWord(1) shl 20;
  ClockMonotonic = 1;
  SignalBlockHow = 0;
  ParkSignal = 40;                   // a real-time signal glibc does not reserve
{$endif}

{$ifdef unix}
type
  TTimeSpec = record Seconds, Nanoseconds: Int64; end;

function LibCClockGetTime(AClock: LongInt; var ATimeSpec: TTimeSpec): LongInt; cdecl; external 'c' name 'clock_gettime';
function LibCMProtect(AAddress: Pointer; ASize: PtrUInt; AProtection: LongInt): LongInt; cdecl; external 'c' name 'mprotect';
function LibCUnsetEnv(AName: PChar): LongInt; cdecl; external 'c' name 'unsetenv';
function LibCDLSym(AHandle: Pointer; AName: PChar): Pointer; cdecl; external 'c' name 'dlsym';
function LibCPThreadSigMask(AHow: LongInt; ANewSet, AOldSet: Pointer): LongInt; cdecl; external 'c' name 'pthread_sigmask';
function LibCGetPageSize: LongInt; cdecl; external 'c' name 'getpagesize';
{$endif}

{$ifdef windows}
// The few Windows calls the agent makes, declared here so that it needs no unit but system.
type
  TWindowsHandle = PtrUInt;
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
  InvalidHandle = TWindowsHandle(-1);
  AF_INET = 2;
  SOCK_STREAM = 1;
  IPPROTO_TCP = 6;
  WinSockVersion = $0202;
  WinSockDataSize = 1024;
  LoopbackNetworkOrder = $0100007f;   // 127.0.0.1
  InvalidSocket = PtrUInt(-1);
  EnvironmentBufferSize = 4096;
  ContextSize = 1232;
  ContextSlack = 64;
  ContextAlignment = 16;
  ContextFlagsOffset = $30;
  ContextRIPOffset = $f8;
  SuspendFailed = LongWord(-1);
  RuntimeFunctionSize = 12;
  RuntimeFunctionWords = 3;
  WindowsPageSize = 4096;
  AllocationGranularityMask = $ffff;
function VirtualAlloc(AAddress: Pointer; ASize: PtrUInt; AAllocationType, AProtection: LongWord): Pointer; stdcall; external 'kernel32' name 'VirtualAlloc';
function VirtualProtect(AAddress: Pointer; ASize: PtrUInt; AProtection: LongWord; out AOldProtection: LongWord): LongBool; stdcall; external 'kernel32' name 'VirtualProtect';
function FlushInstructionCache(AProcess: TWindowsHandle; AAddress: Pointer; ASize: PtrUInt): LongBool; stdcall; external 'kernel32' name 'FlushInstructionCache';
function GetCurrentProcess: TWindowsHandle; stdcall; external 'kernel32' name 'GetCurrentProcess';
function GetCurrentProcessId: LongWord; stdcall; external 'kernel32' name 'GetCurrentProcessId';
function GetCurrentThreadId: LongWord; stdcall; external 'kernel32' name 'GetCurrentThreadId';
function CreateToolhelp32Snapshot(AFlags, AProcessID: LongWord): TWindowsHandle; stdcall; external 'kernel32' name 'CreateToolhelp32Snapshot';
function Thread32First(ASnapshot: TWindowsHandle; var AEntry: TThreadEntry32): LongBool; stdcall; external 'kernel32' name 'Thread32First';
function Thread32Next(ASnapshot: TWindowsHandle; var AEntry: TThreadEntry32): LongBool; stdcall; external 'kernel32' name 'Thread32Next';
function OpenThread(AAccess: LongWord; AInherit: LongBool; AThreadID: LongWord): TWindowsHandle; stdcall; external 'kernel32' name 'OpenThread';
function SuspendThread(AHandle: TWindowsHandle): LongWord; stdcall; external 'kernel32' name 'SuspendThread';
function ResumeThread(AHandle: TWindowsHandle): LongWord; stdcall; external 'kernel32' name 'ResumeThread';
function GetThreadContext(AHandle: TWindowsHandle; AContext: Pointer): LongBool; stdcall; external 'kernel32' name 'GetThreadContext';
function CloseHandle(AHandle: TWindowsHandle): LongBool; stdcall; external 'kernel32' name 'CloseHandle';
function GetModuleHandleA(AName: PChar): PtrUInt; stdcall; external 'kernel32' name 'GetModuleHandleA';
function GetModuleFileNameA(AModule: PtrUInt; ABuffer: PChar; ASize: LongWord): LongWord; stdcall; external 'kernel32' name 'GetModuleFileNameA';
function CreateFileA(AName: PChar; AAccess, AShare: LongWord; ASecurity: Pointer; ADisposition, AFlags: LongWord; ATemplate: TWindowsHandle): TWindowsHandle; stdcall; external 'kernel32' name 'CreateFileA';
function GetFileSize(AHandle: TWindowsHandle; AHigh: PLongWord): LongWord; stdcall; external 'kernel32' name 'GetFileSize';
function ReadFile(AHandle: TWindowsHandle; ABuffer: Pointer; ACount: LongWord; out ABytesRead: LongWord; AOverlapped: Pointer): LongBool; stdcall; external 'kernel32' name 'ReadFile';
function GetEnvironmentVariableA(AName, ABuffer: PChar; ASize: LongWord): LongWord; stdcall; external 'kernel32' name 'GetEnvironmentVariableA';
function SetEnvironmentVariableA(AName, AValue: PChar): LongBool; stdcall; external 'kernel32' name 'SetEnvironmentVariableA';
function QueryPerformanceCounter(out ACounter: Int64): LongBool; stdcall; external 'kernel32' name 'QueryPerformanceCounter';
function QueryPerformanceFrequency(out AFrequency: Int64): LongBool; stdcall; external 'kernel32' name 'QueryPerformanceFrequency';
procedure WinSleep(AMilliseconds: LongWord); stdcall; external 'kernel32' name 'Sleep';
function RtlAddFunctionTable(ATable: Pointer; ACount: LongWord; ABase: QWord): ByteBool; stdcall; external 'kernel32' name 'RtlAddFunctionTable';
function RtlDeleteFunctionTable(ATable: Pointer): ByteBool; stdcall; external 'kernel32' name 'RtlDeleteFunctionTable';
function WSAStartup(AVersion: Word; AData: Pointer): LongInt; stdcall; external 'ws2_32' name 'WSAStartup';
function WinSockSocket(AFamily, ASocketType, AProtocol: LongInt): PtrUInt; stdcall; external 'ws2_32' name 'socket';
function WinSockConnect(ASocket: PtrUInt; AAddress: Pointer; ALength: LongInt): LongInt; stdcall; external 'ws2_32' name 'connect';
function WinSockSend(ASocket: PtrUInt; ABuffer: Pointer; ALength, AFlags: LongInt): LongInt; stdcall; external 'ws2_32' name 'send';
function WinSockReceive(ASocket: PtrUInt; ABuffer: Pointer; ALength, AFlags: LongInt): LongInt; stdcall; external 'ws2_32' name 'recv';
function WinSockShutdown(ASocket: PtrUInt; AHow: LongInt): LongInt; stdcall; external 'ws2_32' name 'shutdown';
{$endif}

{$ifdef darwin}
type
  TMachPort = LongWord;
  TKernelReturn = LongInt;
var
  mach_task_self_: TMachPort cvar; external;
function MachVMRemap(ATarget: TMachPort; var AAddress: QWord; ASize, AMask: QWord; AFlags: LongInt; ASourceTask: TMachPort; ASourceAddress: QWord; ACopy: LongInt; var ACurrentProtection, AMaximumProtection: LongInt; AInheritance: LongWord): TKernelReturn; cdecl; external 'c' name 'mach_vm_remap';
function MachVMProtect(ATask: TMachPort; AAddress, ASize: QWord; ASetMaximum: LongInt; AProtection: LongInt): TKernelReturn; cdecl; external 'c' name 'mach_vm_protect';
function MachVMDeallocate(ATask: TMachPort; AAddress, ASize: QWord): TKernelReturn; cdecl; external 'c' name 'mach_vm_deallocate';
function MachThreadSelf: TMachPort; cdecl; external 'c' name 'mach_thread_self';
function TaskThreads(ATask: TMachPort; var AList: PLongWord; var ACount: LongWord): TKernelReturn; cdecl; external 'c' name 'task_threads';
function ThreadSuspend(AThread: TMachPort): TKernelReturn; cdecl; external 'c' name 'thread_suspend';
function ThreadResume(AThread: TMachPort): TKernelReturn; cdecl; external 'c' name 'thread_resume';
function MachPortDeallocate(ATask, AName: TMachPort): TKernelReturn; cdecl; external 'c' name 'mach_port_deallocate';
function VMDeallocate(ATask: TMachPort; AAddress, ASize: PtrUInt): TKernelReturn; cdecl; external 'c' name 'vm_deallocate';
function MachErrorString(AKernelResult: TKernelReturn): PChar; cdecl; external 'c' name 'mach_error_string';
procedure SysICacheInvalidate(AStart: Pointer; ASize: PtrUInt); cdecl; external 'c' name 'sys_icache_invalidate';
procedure PThreadJITWriteProtectNP(AEnabled: LongInt); cdecl; external 'c' name 'pthread_jit_write_protect_np';
function DyldImageCount: LongWord; cdecl; external 'c' name '_dyld_image_count';
function DyldGetImageHeader(AIndex: LongWord): Pointer; cdecl; external 'c' name '_dyld_get_image_header';
function DyldGetImageVMAddrSlide(AIndex: LongWord): PtrInt; cdecl; external 'c' name '_dyld_get_image_vmaddr_slide';
const
  RTLD_DEFAULT = Pointer(-2);
  VM_PROT_READ = 1;
  VM_PROT_WRITE = 2;
  VM_PROT_EXECUTE = 4;
  VM_PROT_COPY = $10;
  VM_FLAGS_FIXED = 0;
  VM_FLAGS_ANYWHERE = 1;
  VM_FLAGS_OVERWRITE = $4000;
  VM_INHERIT_NONE = 2;
{$endif}
{$ifdef linux}
function LibCGetTID: LongInt; cdecl; external 'c' name 'gettid';
function LibCTGKill(AThreadGroupID, AThreadID, ASignal: LongInt): LongInt; cdecl; external 'c' name 'tgkill';
const
  RTLD_DEFAULT = nil;
{$endif}

procedure HotAnchor;
begin
end;

// ---------------------------------------------------------------- small helpers
function SignedToString(AValue: Int64): AnsiString; inline;
begin
  Str(AValue, Result);
end;

function UnsignedToString(AValue: QWord): AnsiString; inline;
begin
  Str(AValue, Result);
end;

function FloatToString(AValue: Double): AnsiString; inline;
begin
  Str(AValue: 0: FloatDecimals, Result);
end;

function HexToString(AValue: QWord): AnsiString; inline;
begin
  Result := '0x' + HexStr(AValue, QWordHexDigits);
end;

{$ifdef windows}
function NowMilliseconds: Double;
var
  Counter, Frequency: Int64;
begin
  QueryPerformanceCounter(Counter);
  QueryPerformanceFrequency(Frequency);
  Result := Counter / Frequency * MillisecondsPerSecond;
end;
{$else}
function NowMilliseconds: Double;
var
  TimeSpec: TTimeSpec;
begin
  LibCClockGetTime(ClockMonotonic, TimeSpec);
  // Arithmetic, not Double(...): a typecast of an integer to Double reinterprets its bits.
  Result := TimeSpec.Seconds * MillisecondsPerSecond + TimeSpec.Nanoseconds / NanosecondsPerMillisecond;
end;
{$endif}

procedure Nap(AMilliseconds: LongInt);
{$ifdef windows}
begin
  WinSleep(AMilliseconds);
end;
{$else}
var
  Duration: timespec;
begin
  Duration.tv_sec := AMilliseconds div MillisecondsPerSecond;
  Duration.tv_nsec := (AMilliseconds mod MillisecondsPerSecond) * NanosecondsPerMillisecond;
  FpNanoSleep(@Duration, nil);   // FpSleep refers to an undefined "sleep" on Darwin with fpc 3.3.1
end;
{$endif}

// The value of an environment variable, or False when it is not set.
function TryGetEnvironmentVariable(const AName: AnsiString; out AValue: AnsiString): Boolean;
{$ifdef windows}
var
  Buffer: array[0..EnvironmentBufferSize - 1] of Char;
  Count: LongWord;
begin
  Count := GetEnvironmentVariableA(PChar(AName), @Buffer[0], SizeOf(Buffer));
  Result := (Count > 0) and (Count < SizeOf(Buffer));
  if Result then SetString(AValue, PChar(@Buffer[0]), Count) else AValue := '';
end;
{$else}
var
  Text: PChar;
begin
  Text := FpGetEnv(PChar(AName));
  Result := Text <> nil;
  if Result then AValue := Text else AValue := '';
end;
{$endif}

procedure UnsetEnvironmentVariable(const AName: AnsiString);
begin
{$ifdef windows}
  SetEnvironmentVariableA(PChar(AName), nil);
{$else}
  LibCUnsetEnv(PChar(AName));
{$endif}
end;

function FNVHash(AData: PByte; ASize: PtrUInt; AHash: QWord): QWord;
var
  Index: PtrUInt;
begin
  Index := 0;
  while Index < ASize do
  begin
    AHash := (AHash xor AData[Index]) * FNVPrime;
    Inc(Index);
  end;
  Result := AHash;
end;

function FNVHashString(const AText: AnsiString): QWord; inline;
begin
  Result := FNVHash(PByte(PChar(AText)), Length(AText), FNVOffsetBasis);
end;

function StartsWith(const AText, APrefix: AnsiString): Boolean; inline;
begin
  Result := (Length(AText) >= Length(APrefix)) and (CompareByte(PChar(AText)^, PChar(APrefix)^, Length(APrefix)) = 0);
end;

function EndsWith(const AText, ASuffix: AnsiString): Boolean; inline;
begin
  Result := (Length(AText) >= Length(ASuffix)) and (Copy(AText, Length(AText) - Length(ASuffix) + 1, Length(ASuffix)) = ASuffix);
end;

function Contains(const AText, APart: AnsiString): Boolean; inline;
begin
  Result := Pos(APart, AText) > 0;
end;

// ---------------------------------------------------------------- reply
var
  Reply: AnsiString;

procedure Say(const AText: AnsiString);
begin
  Reply := Reply + AText + #10;
end;

// ---------------------------------------------------------------- string hash map
type
  TMap = record
    Keys: array of AnsiString;
    Values: array of Pointer;
    Count: SizeInt;
  end;

procedure MapPut(var AMap: TMap; const AKey: AnsiString; AValue: Pointer); forward;

procedure MapGrow(var AMap: TMap);
var
  OldKeys: array of AnsiString;
  OldValues: array of Pointer;
  I: SizeInt;
begin
  OldKeys := AMap.Keys;
  OldValues := AMap.Values;
  AMap.Keys := nil;
  AMap.Values := nil;
  if Length(OldKeys) = 0 then SetLength(AMap.Keys, MapInitialSize) else SetLength(AMap.Keys, Length(OldKeys) * 2);
  SetLength(AMap.Values, Length(AMap.Keys));
  AMap.Count := 0;
  for I := 0 to High(OldKeys) do
    if OldKeys[I] <> '' then MapPut(AMap, OldKeys[I], OldValues[I]);
end;

procedure MapPut(var AMap: TMap; const AKey: AnsiString; AValue: Pointer);
var
  Index, Mask: SizeInt;
begin
  if (AMap.Count + 1) * 2 > Length(AMap.Keys) then MapGrow(AMap);
  Mask := Length(AMap.Keys) - 1;
  Index := SizeInt(FNVHashString(AKey) and QWord(Mask));
  while (AMap.Keys[Index] <> '') and (AMap.Keys[Index] <> AKey) do Index := (Index + 1) and Mask;
  if AMap.Keys[Index] = '' then
  begin
    AMap.Keys[Index] := AKey;
    Inc(AMap.Count);
  end;
  AMap.Values[Index] := AValue;
end;

function MapGet(const AMap: TMap; const AKey: AnsiString): Pointer;
var
  Index, Mask: SizeInt;
begin
  Result := nil;
  if (Length(AMap.Keys) = 0) or (AKey = '') then Exit;
  Mask := Length(AMap.Keys) - 1;
  Index := SizeInt(FNVHashString(AKey) and QWord(Mask));
  while AMap.Keys[Index] <> '' do
  begin
    if AMap.Keys[Index] = AKey then Exit(AMap.Values[Index]);
    Index := (Index + 1) and Mask;
  end;
end;

// ---------------------------------------------------------------- files
{$ifdef windows}
function ReadWholeFile(const APath: AnsiString; out ABuffer: PByte; out ASize: PtrUInt): Boolean;
var
  Handle: TWindowsHandle;
  BytesRead: LongWord;
begin
  Result := False;
  ABuffer := nil;
  ASize := 0;
  Handle := CreateFileA(PChar(APath), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
  if Handle = InvalidHandle then Exit;
  ASize := GetFileSize(Handle, nil);
  ABuffer := GetMem(ASize + FileBufferSlack);
  if not ReadFile(Handle, ABuffer, ASize, BytesRead, nil) or (BytesRead <> ASize) then
  begin
    CloseHandle(Handle);
    FreeMem(ABuffer);
    ABuffer := nil;
    Exit;
  end;
  CloseHandle(Handle);
  Result := True;
end;
{$else}
function ReadWholeFile(const APath: AnsiString; out ABuffer: PByte; out ASize: PtrUInt): Boolean;
var
  FileDescriptor: cint;
  FileStatus: Stat;
  BytesRead, ReadCount: TSsize;
begin
  Result := False;
  ABuffer := nil;
  ASize := 0;
  FileDescriptor := FpOpen(PChar(APath), O_RDONLY);
  if FileDescriptor < 0 then Exit;
  if FpFStat(FileDescriptor, FileStatus) <> 0 then
  begin
    FpClose(FileDescriptor);
    Exit;
  end;
  ASize := FileStatus.st_size;
  ABuffer := GetMem(ASize + FileBufferSlack);
  BytesRead := 0;
  while PtrUInt(BytesRead) < ASize do
  begin
    ReadCount := FpRead(FileDescriptor, ABuffer[BytesRead], ASize - PtrUInt(BytesRead));
    if ReadCount <= 0 then Break;
    Inc(BytesRead, ReadCount);
  end;
  FpClose(FileDescriptor);
  if PtrUInt(BytesRead) <> ASize then
  begin
    FreeMem(ABuffer);
    ABuffer := nil;
    Exit;
  end;
  Result := True;
end;
{$endif}

// ================================================================ object files: the neutral form
type
  TRelocationKind = (rkAbsolute64, rkAbsolute32, rkSubtract64, rkSubtract32, rkPCRelative32, rkPCRelative64, rkBranch26, rkPage21, rkPageOffset12,
              rkGOTPage21, rkGOTPageOffset12, rkGOTPCRelative32, rkGOTAbsolute64,
              rkAbsolute32Signed, rkBranch32,   // x86-64: sign-extended absolute; rel32 of a call, jmp or jcc
              rkTPOffset32, rkTPOffset64,   // x86-64: offset of a thread variable from the thread pointer
              rkTPRelativeHigh12, rkTPRelativeLow12,   // aarch64: the same, in two add instructions
              rkRVA32,                // Windows: 32-bit offset from the image base (unwind tables)
              rkUnsupported);
  TRelocation = record
    Offset: QWord;        // in its section
    Kind: TRelocationKind;
    Symbol: LongInt;      // the target symbol, or -1: the start of section Section
    Section: LongInt;
    SecondarySymbol: LongInt;     // subtractor: the symbol the target is subtracted from; unsupported: the raw type
    Addend: Int64;
    TargetOffset: Int64;       // with HasTargetOffset: the target's exact offset in section Section (Addend may add a pc bias)
    HasTargetOffset: Boolean;
  end;
  PSection = ^TSection;
  TSection = record
    Name: AnsiString;
    Kind: Byte;        // KindCode, KindData, 0 = not loaded
    ZeroFill: Boolean;
    Size, Alignment: QWord;
    Data: PByte;
    Relocations: array of TRelocation;
    Base: PByte;       // where it was placed
    Live: Boolean;     // reachable from what the program has (MarkLive)
  end;
  PObjectSymbol = ^TObjectSymbol;
  TObjectSymbol = record
    Name: AnsiString;
    Section: LongInt;
    Value, Size: QWord;   // value: offset in its section
    External, Defined, BoundToExisting, Resolved: Boolean;
    Kind: Byte;
    IsTLS: Boolean;         // resolved to a thread variable: ResolvedAddress is its offset in the TLS segment
    ResolvedAddress, CallAddress: QWord;
    GOTEntry: PQWord;
  end;
  PObjectFile = ^TObjectFile;
  TObjectFile = record
    UnitName, Path: AnsiString;
    Buffer: PByte;
    BufferSize: PtrUInt;
    Sections: array of TSection;
    Symbols: array of TObjectSymbol;
    ByName: TMap;
    Previous: PObjectFile;
    Order: array of LongInt;   // defined symbols sorted by (section, value)
  end;

procedure FreeObjectFile(AObjectFile: PObjectFile);
begin
  if AObjectFile = nil then Exit;
  if AObjectFile^.Buffer <> nil then FreeMem(AObjectFile^.Buffer);
  Dispose(AObjectFile);
end;

procedure SortOrder(AObjectFile: PObjectFile);
  function Less(AFirst, ASecond: LongInt): Boolean;
  begin
    if AObjectFile^.Symbols[AFirst].Section <> AObjectFile^.Symbols[ASecond].Section then Exit(AObjectFile^.Symbols[AFirst].Section < AObjectFile^.Symbols[ASecond].Section);
    Result := AObjectFile^.Symbols[AFirst].Value < AObjectFile^.Symbols[ASecond].Value;
  end;
  procedure QuickSort(ALow, AHigh: LongInt);
  var
    I, J, Pivot, Temporary: LongInt;
  begin
    while ALow < AHigh do
    begin
      I := ALow;
      J := AHigh;
      Pivot := AObjectFile^.Order[(ALow + AHigh) shr 1];
      repeat
        while Less(AObjectFile^.Order[I], Pivot) do Inc(I);
        while Less(Pivot, AObjectFile^.Order[J]) do Dec(J);
        if I <= J then
        begin
          Temporary := AObjectFile^.Order[I];
          AObjectFile^.Order[I] := AObjectFile^.Order[J];
          AObjectFile^.Order[J] := Temporary;
          Inc(I);
          Dec(J);
        end;
      until I > J;
      if J - ALow < AHigh - I then
      begin
        QuickSort(ALow, J);
        ALow := I;
      end
      else
      begin
        QuickSort(I, AHigh);
        AHigh := J;
      end;
    end;
  end;
begin
  if Length(AObjectFile^.Order) > 1 then QuickSort(0, High(AObjectFile^.Order));
end;

// Relocations of a section in offset order (stable: equal offsets keep their order).
procedure SortRelocations(var ARelocations: array of TRelocation);
var
  I, J: SizeInt;
  Temporary: TRelocation;
begin
  for I := 1 to High(ARelocations) do
  begin
    Temporary := ARelocations[I];
    J := I - 1;
    if ARelocations[J].Offset <= Temporary.Offset then Continue;
    while (J >= 0) and (ARelocations[J].Offset > Temporary.Offset) do
    begin
      ARelocations[J + 1] := ARelocations[J];
      Dec(J);
    end;
    ARelocations[J + 1] := Temporary;
  end;
end;

// Sizes: up to the next symbol at another address in the same section, or its end.
procedure FinishObjectFile(AObjectFile: PObjectFile);
var
  I, J: SizeInt;
  Symbol, NextSymbol: PObjectSymbol;
  EndOffset: QWord;
begin
  SortOrder(AObjectFile);
  for I := 0 to High(AObjectFile^.Order) do
  begin
    Symbol := @AObjectFile^.Symbols[AObjectFile^.Order[I]];
    EndOffset := AObjectFile^.Sections[Symbol^.Section].Size;
    for J := I + 1 to High(AObjectFile^.Order) do
    begin
      NextSymbol := @AObjectFile^.Symbols[AObjectFile^.Order[J]];
      if NextSymbol^.Section <> Symbol^.Section then Break;
      if NextSymbol^.Value <> Symbol^.Value then
      begin
        EndOffset := NextSymbol^.Value;
        Break;
      end;
    end;
    Symbol^.Size := EndOffset - Symbol^.Value;
  end;
  for I := 0 to High(AObjectFile^.Sections) do
    if Length(AObjectFile^.Sections[I].Relocations) > 1 then SortRelocations(AObjectFile^.Sections[I].Relocations);
end;

function IsAnonymous(const AName: AnsiString): Boolean; forward;

// A local symbol with a name fpc made (unit and routine or variable, always with a $) is as
// stable across versions, and as present in the program's symbol table, as an external
// one: fpc 3.2 makes implementation-section variables local where 3.3.1 makes them private
// external.
function NamedLocal(const AName: AnsiString): Boolean;
begin
  Result := (AName <> '') and (Pos('$', AName) > 0) and not IsAnonymous(AName);
end;

procedure AddDefined(AObjectFile: PObjectFile; AIndex: LongInt);
begin
  if not AObjectFile^.Symbols[AIndex].External and NamedLocal(AObjectFile^.Symbols[AIndex].Name) then AObjectFile^.Symbols[AIndex].External := True;
  SetLength(AObjectFile^.Order, Length(AObjectFile^.Order) + 1);
  AObjectFile^.Order[High(AObjectFile^.Order)] := AIndex;
  if AObjectFile^.Symbols[AIndex].External then MapPut(AObjectFile^.ByName, AObjectFile^.Symbols[AIndex].Name, @AObjectFile^.Symbols[AIndex]);
end;

procedure AddRelocation(var ASection: TSection; const ARelocation: TRelocation);
begin
  SetLength(ASection.Relocations, Length(ASection.Relocations) + 1);
  ASection.Relocations[High(ASection.Relocations)] := ARelocation;
end;

function FixedNameToString(AName: PChar): AnsiString;
var
  Count: SizeInt;
begin
  Count := 0;
  while (Count < FixedNameLength) and (AName[Count] <> #0) do Inc(Count);
  SetString(Result, AName, Count);
end;

// ---------------------------------------------------------------- Mach-O
{$ifdef darwin}
type
  TMachHeader64 = packed record magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved: LongWord; end;
  PMachHeader64 = ^TMachHeader64;
  TMachLoadCommand = packed record cmd, cmdsize: LongWord; end;
  PMachLoadCommand = ^TMachLoadCommand;
  TMachSegmentCommand64 = packed record
    cmd, cmdsize: LongWord;
    segname: array[0..FixedNameLength - 1] of Char;
    vmaddr, vmsize, fileoff, filesize: QWord;
    maxprot, initprot, nsects, flags: LongWord;
  end;
  PMachSegmentCommand64 = ^TMachSegmentCommand64;
  TMachSection64 = packed record
    sectname, segname: array[0..FixedNameLength - 1] of Char;
    Address, size: QWord;
    offset, Alignment, reloff, nreloc, flags, reserved1, reserved2, reserved3: LongWord;
  end;
  PMachSection64 = ^TMachSection64;
  TMachSymtabCommand = packed record cmd, cmdsize, symoff, nsyms, stroff, strsize: LongWord; end;
  PMachSymtabCommand = ^TMachSymtabCommand;
  TMachSymbol64 = packed record n_strx: LongWord; n_type, n_sect: Byte; n_desc: Word; n_value: QWord; end;
  PMachSymbol64 = ^TMachSymbol64;
  TMachRelocation = packed record r_address: LongInt; Bits: LongWord; end;
  PMachRelocation = ^TMachRelocation;
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
  ARM64_RELOC_UNSIGNED = 0;
  ARM64_RELOC_SUBTRACTOR = 1;
  ARM64_RELOC_BRANCH26 = 2;
  ARM64_RELOC_PAGE21 = 3;
  ARM64_RELOC_PAGEOFF12 = 4;
  ARM64_RELOC_GOT_LOAD_PAGE21 = 5;
  ARM64_RELOC_GOT_LOAD_PAGEOFF12 = 6;
  ARM64_RELOC_POINTER_TO_GOT = 7;
  ARM64_RELOC_ADDEND = 10;
  MachRelocSymbolMask = $ffffff;
  MachRelocPCRelativeShift = 24;
  MachRelocLengthShift = 25;
  MachRelocLengthMask = 3;
  MachRelocLengthQuad = 3;
  MachRelocExternalShift = 27;
  MachRelocTypeShift = 28;
  MachRelocAddendShift = 8;
  MachSectionLimit = 256;
  PageZeroSegmentName = '__PAGEZERO';
  TextSegmentName = '__TEXT';
  LinkeditSegmentName = '__LINKEDIT';
  DWARFSegmentName = '__DWARF';
  LinkerSegmentName = '__LD';
  MachEHFrameSectionName = '__eh_frame';

function MachSymbolName(AName: PChar): AnsiString;
begin
  if AName^ = '_' then Inc(AName);   // the platform's prefix; names are kept without it
  Result := AName;
end;

function ParseMachO(AObjectFile: PObjectFile): Boolean;
var
  Header: PMachHeader64;
  LoadCommand: PMachLoadCommand;
  SegmentCommand: PMachSegmentCommand64;
  SectionHeader: PMachSection64;
  SymtabCommand: PMachSymtabCommand;
  NameList: PMachSymbol64;
  Strings: PChar;
  I, J, RelocationIndex, RawCount: LongWord;
  SectionAddresses: array of QWord;
  RelocationInfo: array of record Offset, Count: LongWord; end;
  Section: PSection;
  SectionType: LongWord;
  RawRelocations: PMachRelocation;
  Bits, SymbolNumber, LengthCode, IsExternal, RelocationType: LongWord;
  PendingAddend: Int64;
  Relocation: TRelocation;
  StoredAddend: Int64;
  Symbol: PObjectSymbol;
begin
  Result := False;
  Header := PMachHeader64(AObjectFile^.Buffer);
  if (AObjectFile^.BufferSize < SizeOf(TMachHeader64)) or (Header^.magic <> MH_MAGIC_64) or (Header^.filetype <> MH_OBJECT) or (Header^.cputype <> CPU_TYPE_ARM64) then
  begin
    Say('error ' + AObjectFile^.Path + ' is not an arm64 Mach-O object');
    Exit;
  end;
  SymtabCommand := nil;
  LoadCommand := PMachLoadCommand(AObjectFile^.Buffer + SizeOf(TMachHeader64));
  for I := 1 to Header^.ncmds do
  begin
    if LoadCommand^.cmd = LC_SYMTAB then SymtabCommand := PMachSymtabCommand(LoadCommand);
    if LoadCommand^.cmd = LC_SEGMENT_64 then
    begin
      SegmentCommand := PMachSegmentCommand64(LoadCommand);
      SectionHeader := PMachSection64(PByte(SegmentCommand) + SizeOf(TMachSegmentCommand64));
      for J := 1 to SegmentCommand^.nsects do
      begin
        SetLength(AObjectFile^.Sections, Length(AObjectFile^.Sections) + 1);
        SetLength(SectionAddresses, Length(AObjectFile^.Sections));
        SetLength(RelocationInfo, Length(AObjectFile^.Sections));
        Section := @AObjectFile^.Sections[High(AObjectFile^.Sections)];
        Section^.Name := FixedNameToString(SectionHeader^.segname) + ',' + FixedNameToString(SectionHeader^.sectname);
        Section^.Size := SectionHeader^.size;
        Section^.Alignment := QWord(1) shl SectionHeader^.Alignment;
        SectionType := SectionHeader^.flags and SECTION_TYPE;
        Section^.ZeroFill := (SectionType = S_ZEROFILL) or (SectionType = S_GB_ZEROFILL) or (SectionType = S_THREAD_LOCAL_ZEROFILL);
        if not Section^.ZeroFill then Section^.Data := AObjectFile^.Buffer + SectionHeader^.offset;
        if ((SectionHeader^.flags and S_ATTR_DEBUG) <> 0) or (FixedNameToString(SectionHeader^.segname) = DWARFSegmentName) or (FixedNameToString(SectionHeader^.segname) = LinkerSegmentName) or (FixedNameToString(SectionHeader^.sectname) = MachEHFrameSectionName) then Section^.Kind := 0
        else if (SectionHeader^.flags and S_ATTR_PURE_INSTRUCTIONS) <> 0 then Section^.Kind := KindCode
        else Section^.Kind := KindData;
        SectionAddresses[High(SectionAddresses)] := SectionHeader^.Address;
        RelocationInfo[High(RelocationInfo)].Offset := SectionHeader^.reloff;
        RelocationInfo[High(RelocationInfo)].Count := SectionHeader^.nreloc;
        Inc(SectionHeader);
      end;
    end;
    LoadCommand := PMachLoadCommand(PByte(LoadCommand) + LoadCommand^.cmdsize);
  end;
  if SymtabCommand = nil then
  begin
    Say('error ' + AObjectFile^.Path + ' has no symbol table');
    Exit;
  end;
  NameList := PMachSymbol64(AObjectFile^.Buffer + SymtabCommand^.symoff);
  Strings := PChar(AObjectFile^.Buffer + SymtabCommand^.stroff);
  SetLength(AObjectFile^.Symbols, SymtabCommand^.nsyms);
  for I := 0 to SymtabCommand^.nsyms - 1 do
  begin
    Symbol := @AObjectFile^.Symbols[I];
    Symbol^.Name := MachSymbolName(Strings + NameList[I].n_strx);
    Symbol^.Section := -1;
    if (NameList[I].n_type and N_STAB) <> 0 then Continue;
    Symbol^.External := (NameList[I].n_type and (N_EXT or N_PEXT)) <> 0;
    if ((NameList[I].n_type and N_TYPE) = N_SECT) and (NameList[I].n_sect >= 1) and (NameList[I].n_sect <= Length(AObjectFile^.Sections)) then
    begin
      Symbol^.Defined := True;
      Symbol^.Section := NameList[I].n_sect - 1;
      Symbol^.Value := NameList[I].n_value - SectionAddresses[Symbol^.Section];
      Symbol^.Kind := AObjectFile^.Sections[Symbol^.Section].Kind;
      AddDefined(AObjectFile, I);
    end;
  end;
  for I := 0 to High(AObjectFile^.Sections) do
  begin
    Section := @AObjectFile^.Sections[I];
    if (Section^.Kind = 0) or (RelocationInfo[I].Count = 0) then Continue;
    RawRelocations := PMachRelocation(AObjectFile^.Buffer + RelocationInfo[I].Offset);
    RawCount := RelocationInfo[I].Count;
    PendingAddend := 0;
    RelocationIndex := 0;
    while RelocationIndex < RawCount do
    begin
      Bits := RawRelocations[RelocationIndex].Bits;
      SymbolNumber := Bits and MachRelocSymbolMask;
      LengthCode := (Bits shr MachRelocLengthShift) and MachRelocLengthMask;
      IsExternal := (Bits shr MachRelocExternalShift) and 1;
      RelocationType := Bits shr MachRelocTypeShift;
      FillChar(Relocation, SizeOf(Relocation), 0);
      Relocation.Offset := LongWord(RawRelocations[RelocationIndex].r_address);
      Relocation.Symbol := -1;
      Relocation.Section := -1;
      if RelocationType = ARM64_RELOC_ADDEND then   // for the relocation that follows
      begin
        PendingAddend := SarLongint(LongInt(SymbolNumber shl MachRelocAddendShift), MachRelocAddendShift);
        Inc(RelocationIndex);
        Continue;
      end;
      if IsExternal = 1 then Relocation.Symbol := SymbolNumber else Relocation.Section := LongInt(SymbolNumber) - 1;
      case RelocationType of
        ARM64_RELOC_UNSIGNED, ARM64_RELOC_SUBTRACTOR:   // the addend is in the bytes
          begin
            if Section^.ZeroFill then StoredAddend := 0
            else if LengthCode = MachRelocLengthQuad then StoredAddend := PInt64(Section^.Data + Relocation.Offset)^
            else StoredAddend := PLongInt(Section^.Data + Relocation.Offset)^;
            if RelocationType = ARM64_RELOC_UNSIGNED then
            begin
              if LengthCode = MachRelocLengthQuad then Relocation.Kind := rkAbsolute64 else Relocation.Kind := rkAbsolute32;
              if IsExternal = 1 then Relocation.Addend := StoredAddend
              else if (Relocation.Section >= 0) and (Relocation.Section < Length(SectionAddresses)) then
              begin
                Relocation.Addend := StoredAddend - Int64(SectionAddresses[Relocation.Section]);
                Relocation.TargetOffset := Relocation.Addend;
                Relocation.HasTargetOffset := True;
              end
              else Relocation.Kind := rkUnsupported;
            end
            else
            begin
              if (RelocationIndex + 1 >= RawCount) or ((RawRelocations[RelocationIndex + 1].Bits shr MachRelocTypeShift) <> ARM64_RELOC_UNSIGNED) or (((RawRelocations[RelocationIndex + 1].Bits shr MachRelocExternalShift) and 1) = 0) or (IsExternal = 0) then
              begin
                Say('error ' + AObjectFile^.UnitName + ': malformed subtractor relocation');
                Exit;
              end;
              if LengthCode = MachRelocLengthQuad then Relocation.Kind := rkSubtract64 else Relocation.Kind := rkSubtract32;
              Relocation.SecondarySymbol := RawRelocations[RelocationIndex + 1].Bits and MachRelocSymbolMask;
              Relocation.Addend := StoredAddend;
              Inc(RelocationIndex);
            end;
          end;
        ARM64_RELOC_BRANCH26: Relocation.Kind := rkBranch26;
        ARM64_RELOC_PAGE21: Relocation.Kind := rkPage21;
        ARM64_RELOC_PAGEOFF12: Relocation.Kind := rkPageOffset12;
        ARM64_RELOC_GOT_LOAD_PAGE21: Relocation.Kind := rkGOTPage21;
        ARM64_RELOC_GOT_LOAD_PAGEOFF12: Relocation.Kind := rkGOTPageOffset12;
        ARM64_RELOC_POINTER_TO_GOT: if ((Bits shr MachRelocPCRelativeShift) and 1) = 1 then Relocation.Kind := rkGOTPCRelative32 else Relocation.Kind := rkGOTAbsolute64;
      else
        Relocation.Kind := rkUnsupported;
      end;
      if (RelocationType >= ARM64_RELOC_BRANCH26) then
      begin
        Relocation.Addend := PendingAddend;
        if IsExternal = 0 then Relocation.Kind := rkUnsupported;
      end;
      if Relocation.Kind = rkUnsupported then Relocation.SecondarySymbol := RelocationType;
      PendingAddend := 0;
      AddRelocation(Section^, Relocation);
      Inc(RelocationIndex);
    end;
  end;
  FinishObjectFile(AObjectFile);
  Result := True;
end;
{$endif}

// ---------------------------------------------------------------- ELF
type
  TELFHeader = packed record
    e_ident: array[0..15] of Byte;
    e_type, e_machine: Word;
    e_version: LongWord;
    e_entry, e_phoff, e_shoff: QWord;
    e_flags: LongWord;
    e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx: Word;
  end;
  PELFHeader = ^TELFHeader;
  TELFSectionHeader = packed record
    sh_name, sh_type: LongWord;
    sh_flags, sh_addr, sh_offset, sh_size: QWord;
    sh_link, sh_info: LongWord;
    sh_addralign, sh_entsize: QWord;
  end;
  PELFSectionHeader = ^TELFSectionHeader;
  TELFProgramHeader = packed record
    p_type, p_flags: LongWord;
    p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align: QWord;
  end;
  PELFProgramHeader = ^TELFProgramHeader;
  TELFSymbol = packed record
    st_name: LongWord;
    st_info, st_other: Byte;
    st_shndx: Word;
    st_value, st_size: QWord;
  end;
  PELFSymbol = ^TELFSymbol;
  TELFRelocation = packed record r_offset, r_info: QWord; r_addend: Int64; end;
  PELFRelocation = ^TELFRelocation;
const
  ET_REL = 1;
  ET_EXEC = 2;
  ET_DYN = 3;
  EM_AARCH64 = 183;
  EM_X86_64 = 62;
{$ifdef cpuaarch64}
  HostMachine = EM_AARCH64;
{$else}
  HostMachine = EM_X86_64;
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
  EI_MAG0 = 0;
  EI_MAG1 = 1;
  EI_MAG2 = 2;
  EI_MAG3 = 3;
  EI_CLASS = 4;
  EI_DATA = 5;
  ELFMAG0 = $7f;
  ELFCLASS64 = 2;
  ELFDATA2LSB = 1;
  ELFSymbolTypeMask = 15;
  ELFSymbolBindShift = 4;
  ELFRelocationTypeMask = $ffffffff;
  ELFRelocationSymbolShift = 32;

function IsValidELF(AObjectFile: PObjectFile; AWantedType: Word): Boolean;
var
  Header: PELFHeader;
begin
  Header := PELFHeader(AObjectFile^.Buffer);
  Result := (AObjectFile^.BufferSize >= SizeOf(TELFHeader)) and (Header^.e_ident[EI_MAG0] = ELFMAG0) and (Header^.e_ident[EI_MAG1] = Ord('E')) and (Header^.e_ident[EI_MAG2] = Ord('L')) and (Header^.e_ident[EI_MAG3] = Ord('F'))
    and (Header^.e_ident[EI_CLASS] = ELFCLASS64) and (Header^.e_ident[EI_DATA] = ELFDATA2LSB) and (Header^.e_machine = HostMachine) and ((AWantedType = 0) or (Header^.e_type = AWantedType));
end;

// $x and $d mark where code and data start inside a section (aarch64 mapping symbols).
function IsMappingSymbol(const AName: AnsiString): Boolean;
begin
  Result := (Length(AName) >= 2) and (AName[1] = '$') and (AName[2] in ['x', 'd']) and ((Length(AName) = 2) or (AName[3] = '.'));
end;

{$ifdef cpux86_64}
const
  R_X86_64_64 = 1;
  R_X86_64_PC32 = 2;
  R_X86_64_PLT32 = 4;
  R_X86_64_GOTPCREL = 9;
  R_X86_64_32 = 10;
  R_X86_64_32S = 11;
  R_X86_64_TPOFF64 = 18;
  R_X86_64_TPOFF32 = 23;
  R_X86_64_PC64 = 24;
  R_X86_64_GOTPCRELX = 41;
  R_X86_64_REX_GOTPCRELX = 42;

// AData: the section's bytes, to tell a branch's rel32 from a rip-relative operand: a call or
// jmp (e8, e9) or a jcc (0f 80..8f) comes right before it, and no ModRM byte of a
// rip-relative operand has those values.
function ELFRelocationKind(AType: LongWord; AData: PByte; AOffset: QWord): TRelocationKind;
var
  IsBranch: Boolean;
begin
  IsBranch := (AData <> nil) and (AOffset >= 1) and ((AData[AOffset - 1] in [X86OpcodeCallRel32, X86OpcodeJumpRel32]) or ((AOffset >= 2) and (AData[AOffset - 2] = X86OpcodeTwoByte) and (AData[AOffset - 1] in [X86OpcodeJccFirst..X86OpcodeJccLast])));
  case AType of
    R_X86_64_64: Result := rkAbsolute64;
    R_X86_64_PC32, R_X86_64_PLT32: if IsBranch then Result := rkBranch32 else Result := rkPCRelative32;
    R_X86_64_GOTPCREL, R_X86_64_GOTPCRELX, R_X86_64_REX_GOTPCRELX: Result := rkGOTPCRelative32;
    R_X86_64_32: Result := rkAbsolute32;
    R_X86_64_32S: Result := rkAbsolute32Signed;
    R_X86_64_PC64: Result := rkPCRelative64;
    R_X86_64_TPOFF32: Result := rkTPOffset32;   // local exec
    R_X86_64_TPOFF64: Result := rkTPOffset64;
  else
    Result := rkUnsupported;
  end;
end;
{$else}
const
  R_AARCH64_ABS64 = 257;
  R_AARCH64_ABS32 = 258;
  R_AARCH64_PREL64 = 260;
  R_AARCH64_PREL32 = 261;
  R_AARCH64_ADR_PREL_PG_HI21 = 275;
  R_AARCH64_ADR_PREL_PG_HI21_NC = 276;
  R_AARCH64_ADD_ABS_LO12_NC = 277;
  R_AARCH64_LDST8_ABS_LO12_NC = 278;
  R_AARCH64_JUMP26 = 282;
  R_AARCH64_CALL26 = 283;
  R_AARCH64_LDST16_ABS_LO12_NC = 284;
  R_AARCH64_LDST32_ABS_LO12_NC = 285;
  R_AARCH64_LDST64_ABS_LO12_NC = 286;
  R_AARCH64_LDST128_ABS_LO12_NC = 299;
  R_AARCH64_ADR_GOT_PAGE = 311;
  R_AARCH64_LD64_GOT_LO12_NC = 312;
  R_AARCH64_TLSLE_ADD_TPREL_HI12 = 549;
  R_AARCH64_TLSLE_ADD_TPREL_LO12 = 550;
  R_AARCH64_TLSLE_ADD_TPREL_LO12_NC = 551;

function ELFRelocationKind(AType: LongWord; AData: PByte; AOffset: QWord): TRelocationKind;
begin
  case AType of
    R_AARCH64_ABS64: Result := rkAbsolute64;
    R_AARCH64_ABS32: Result := rkAbsolute32;
    R_AARCH64_PREL64: Result := rkPCRelative64;
    R_AARCH64_PREL32: Result := rkPCRelative32;
    R_AARCH64_JUMP26, R_AARCH64_CALL26: Result := rkBranch26;
    R_AARCH64_ADR_PREL_PG_HI21, R_AARCH64_ADR_PREL_PG_HI21_NC: Result := rkPage21;
    R_AARCH64_ADD_ABS_LO12_NC, R_AARCH64_LDST8_ABS_LO12_NC, R_AARCH64_LDST16_ABS_LO12_NC, R_AARCH64_LDST32_ABS_LO12_NC,
      R_AARCH64_LDST64_ABS_LO12_NC, R_AARCH64_LDST128_ABS_LO12_NC: Result := rkPageOffset12;
    R_AARCH64_ADR_GOT_PAGE: Result := rkGOTPage21;
    R_AARCH64_LD64_GOT_LO12_NC: Result := rkGOTPageOffset12;
    R_AARCH64_TLSLE_ADD_TPREL_HI12: Result := rkTPRelativeHigh12;
    R_AARCH64_TLSLE_ADD_TPREL_LO12, R_AARCH64_TLSLE_ADD_TPREL_LO12_NC: Result := rkTPRelativeLow12;
  else
    Result := rkUnsupported;
  end;
end;
{$endif}

function ParseELFObject(AObjectFile: PObjectFile): Boolean;
var
  Header: PELFHeader;
  SectionHeaders: PELFSectionHeader;
  SectionNames: PChar;
  I, TargetSection, K: SizeInt;
  Section: PSection;
  Name: AnsiString;
  SymbolTable: PELFSectionHeader;
  Symbols: PELFSymbol;
  Strings: PChar;
  SymbolCount: SizeInt;
  Symbol: PObjectSymbol;
  SectionOfSymbol: array of LongInt;   // a section symbol: the section it stands for, else -1
  RelocationEntries: PELFRelocation;
  Relocation: TRelocation;
  SymbolIndex: QWord;
  SymbolType, Binding: Byte;
begin
  Result := False;
  if not IsValidELF(AObjectFile, ET_REL) then
  begin
    Say('error ' + AObjectFile^.Path + ' is not an aarch64 ELF object');
    Exit;
  end;
  Header := PELFHeader(AObjectFile^.Buffer);
  SectionHeaders := PELFSectionHeader(AObjectFile^.Buffer + Header^.e_shoff);
  SectionNames := PChar(AObjectFile^.Buffer + SectionHeaders[Header^.e_shstrndx].sh_offset);
  SetLength(AObjectFile^.Sections, Header^.e_shnum);
  SymbolTable := nil;
  for I := 0 to Header^.e_shnum - 1 do
  begin
    Section := @AObjectFile^.Sections[I];
    Name := PChar(SectionNames + SectionHeaders[I].sh_name);
    Section^.Name := Name;
    Section^.Size := SectionHeaders[I].sh_size;
    Section^.Alignment := SectionHeaders[I].sh_addralign;
    if Section^.Alignment = 0 then Section^.Alignment := 1;
    Section^.ZeroFill := SectionHeaders[I].sh_type = SHT_NOBITS;
    if not Section^.ZeroFill then Section^.Data := AObjectFile^.Buffer + SectionHeaders[I].sh_offset;
    if SectionHeaders[I].sh_type = SHT_SYMTAB then SymbolTable := @SectionHeaders[I];
    if ((SectionHeaders[I].sh_flags and SHF_ALLOC) = 0) or StartsWith(Name, DebugSectionPrefix) or (Name = EHFrameSectionName) then Section^.Kind := 0
    else if (SectionHeaders[I].sh_flags and SHF_TLS) <> 0 then Section^.Kind := KindTLS
    else if (SectionHeaders[I].sh_flags and SHF_EXECINSTR) <> 0 then Section^.Kind := KindCode
    else Section^.Kind := KindData;
  end;
  if SymbolTable = nil then
  begin
    Say('error ' + AObjectFile^.Path + ' has no symbol table');
    Exit;
  end;
  Symbols := PELFSymbol(AObjectFile^.Buffer + SymbolTable^.sh_offset);
  Strings := PChar(AObjectFile^.Buffer + SectionHeaders[SymbolTable^.sh_link].sh_offset);
  SymbolCount := SymbolTable^.sh_size div SizeOf(TELFSymbol);
  SetLength(AObjectFile^.Symbols, SymbolCount);
  SetLength(SectionOfSymbol, SymbolCount);
  for I := 0 to SymbolCount - 1 do
  begin
    Symbol := @AObjectFile^.Symbols[I];
    Symbol^.Name := PChar(Strings + Symbols[I].st_name);
    Symbol^.Section := -1;
    SectionOfSymbol[I] := -1;
    SymbolType := Symbols[I].st_info and ELFSymbolTypeMask;
    Binding := Symbols[I].st_info shr ELFSymbolBindShift;
    if SymbolType = STT_SECTION then
    begin
      SectionOfSymbol[I] := Symbols[I].st_shndx;
      Continue;
    end;
    if (SymbolType = STT_FILE) or IsMappingSymbol(Symbol^.Name) then Continue;
    Symbol^.External := (Binding = STB_GLOBAL) or (Binding = STB_WEAK);
    if (Symbols[I].st_shndx <> 0) and (Symbols[I].st_shndx < SHN_LORESERVE) and (Symbols[I].st_shndx < Header^.e_shnum) then
    begin
      if (AObjectFile^.Sections[Symbols[I].st_shndx].Kind = 0) or (Symbol^.Name = '') then Continue;
      Symbol^.Defined := True;
      Symbol^.Section := Symbols[I].st_shndx;
      Symbol^.Value := Symbols[I].st_value;
      Symbol^.Kind := AObjectFile^.Sections[Symbol^.Section].Kind;
      AddDefined(AObjectFile, I);
    end;
  end;
  for I := 0 to Header^.e_shnum - 1 do
  begin
    if (SectionHeaders[I].sh_type <> SHT_RELA) and (SectionHeaders[I].sh_type <> SHT_REL) then Continue;
    TargetSection := SectionHeaders[I].sh_info;
    if (TargetSection <= 0) or (TargetSection >= Header^.e_shnum) or (AObjectFile^.Sections[TargetSection].Kind = 0) then Continue;
    if SectionHeaders[I].sh_type = SHT_REL then
    begin
      Say('error ' + AObjectFile^.UnitName + ': relocations without addends (REL) are not handled');
      Exit;
    end;
    RelocationEntries := PELFRelocation(AObjectFile^.Buffer + SectionHeaders[I].sh_offset);
    for K := 0 to SectionHeaders[I].sh_size div SizeOf(TELFRelocation) - 1 do
    begin
      FillChar(Relocation, SizeOf(Relocation), 0);
      Relocation.Offset := RelocationEntries[K].r_offset;
      Relocation.Kind := ELFRelocationKind(RelocationEntries[K].r_info and ELFRelocationTypeMask, AObjectFile^.Sections[TargetSection].Data, RelocationEntries[K].r_offset);
      if Relocation.Kind = rkUnsupported then Relocation.SecondarySymbol := LongInt(RelocationEntries[K].r_info and ELFRelocationTypeMask);
      Relocation.Addend := RelocationEntries[K].r_addend;
      SymbolIndex := RelocationEntries[K].r_info shr ELFRelocationSymbolShift;
      Relocation.Symbol := -1;
      Relocation.Section := -1;
      if (SymbolIndex < QWord(SymbolCount)) and (SectionOfSymbol[SymbolIndex] >= 0) then Relocation.Section := SectionOfSymbol[SymbolIndex]
      else Relocation.Symbol := LongInt(SymbolIndex);
      if (Relocation.Symbol < 0) and (Relocation.Kind in [rkAbsolute64, rkAbsolute32, rkAbsolute32Signed]) then
      begin
        Relocation.TargetOffset := Relocation.Addend;
        Relocation.HasTargetOffset := True;
      end;
      AddRelocation(AObjectFile^.Sections[TargetSection], Relocation);
    end;
  end;
  FinishObjectFile(AObjectFile);
  Result := True;
end;

// ---------------------------------------------------------------- COFF (Windows)
{$ifdef windows}
type
  TCOFFHeader = packed record
    Machine, NumberOfSections: Word;
    TimeDateStamp, PointerToSymbolTable, NumberOfSymbols: LongWord;
    SizeOfOptionalHeader, Characteristics: Word;
  end;
  PCOFFHeader = ^TCOFFHeader;
  TCOFFSection = packed record
    Name: array[0..7] of Char;
    VirtualSize, VirtualAddress, SizeOfRawData, PointerToRawData, PointerToRelocations, PointerToLinenumbers: LongWord;
    NumberOfRelocations, NumberOfLinenumbers: Word;
    Characteristics: LongWord;
  end;
  PCOFFSection = ^TCOFFSection;
  TCOFFSymbol = packed record
    Name: array[0..7] of Char;
    Value: LongWord;
    SectionNumber: SmallInt;
    SymbolType: Word;
    StorageClass, NumberOfAuxSymbols: Byte;
  end;
  PCOFFSymbol = ^TCOFFSymbol;
  TCOFFRelocation = packed record
    VirtualAddress, SymbolTableIndex: LongWord;
    RelocationType: Word;
  end;
  PCOFFRelocation = ^TCOFFRelocation;
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
  IMAGE_REL_AMD64_ABSOLUTE = 0;
  IMAGE_REL_AMD64_ADDR64 = 1;
  IMAGE_REL_AMD64_ADDR32 = 2;
  IMAGE_REL_AMD64_ADDR32NB = 3;
  IMAGE_REL_AMD64_REL32 = 4;
  IMAGE_REL_AMD64_REL32_5 = 9;
  COFFAlignmentShift = 20;
  COFFAlignmentMask = $f;
  COFFDefaultAlignment = 16;

// The name a section without symbols stands under (see ParseCOFF), in objects and in the map.
function SectionSymbolName(const ASection: AnsiString): AnsiString;
var
  I: SizeInt;
begin
  Result := ASection;
  for I := 1 to Length(Result) do
    if Result[I] in ['A'..'Z'] then Result[I] := Chr(Ord(Result[I]) + 32);
  Result := SectionSymbolPrefix + Result;
end;

// A name of 8 characters or fewer is in place; a longer one is in the string table.
function COFFSymbolName(ASymbol: PCOFFSymbol; AStringTable: PChar): AnsiString;
begin
  if PLongWord(@ASymbol^.Name[0])^ = 0 then Result := PChar(AStringTable + PLongWord(@ASymbol^.Name[4])^)
  else
  begin
    Result := '';
    SetString(Result, PChar(@ASymbol^.Name[0]), 8);
    Result := PChar(Result);   // up to the first #0
  end;
end;

function COFFSectionName(ASection: PCOFFSection; AStringTable: PChar): AnsiString;
var
  Offset, ErrorCode: LongInt;
begin
  SetString(Result, PChar(@ASection^.Name[0]), 8);
  Result := PChar(Result);
  if (Length(Result) > 1) and (Result[1] = '/') then
  begin
    Val(Copy(Result, 2, 7), Offset, ErrorCode);
    if ErrorCode = 0 then Result := PChar(AStringTable + Offset);
  end;
end;

function ParseCOFF(AObjectFile: PObjectFile): Boolean;
var
  Header: PCOFFHeader;
  SectionHeaders: PCOFFSection;
  Symbols: PCOFFSymbol;
  StringTable: PChar;
  I, K, RelocationCount, FirstRelocation: LongInt;
  Section: PSection;
  Characteristics, AlignmentCode: LongWord;
  SectionOfSymbol: array of LongInt;
  Symbol: PObjectSymbol;
  SymbolEntry: PCOFFSymbol;
  RelocationEntries: PCOFFRelocation;
  Relocation: TRelocation;
  StoredAddend: Int64;
begin
  Result := False;
  Header := PCOFFHeader(AObjectFile^.Buffer);
  if (AObjectFile^.BufferSize < SizeOf(TCOFFHeader)) or (Header^.Machine <> IMAGE_FILE_MACHINE_AMD64) or (Header^.SizeOfOptionalHeader <> 0) then
  begin
    Say('error ' + AObjectFile^.Path + ' is not an x86-64 COFF object');
    Exit;
  end;
  SectionHeaders := PCOFFSection(AObjectFile^.Buffer + SizeOf(TCOFFHeader));
  Symbols := PCOFFSymbol(AObjectFile^.Buffer + Header^.PointerToSymbolTable);
  StringTable := PChar(AObjectFile^.Buffer + Header^.PointerToSymbolTable + Header^.NumberOfSymbols * SizeOf(TCOFFSymbol));
  SetLength(AObjectFile^.Sections, Header^.NumberOfSections);
  for I := 0 to Header^.NumberOfSections - 1 do
  begin
    Section := @AObjectFile^.Sections[I];
    Characteristics := SectionHeaders[I].Characteristics;
    Section^.Name := COFFSectionName(@SectionHeaders[I], StringTable);
    Section^.Size := SectionHeaders[I].SizeOfRawData;
    AlignmentCode := (Characteristics shr COFFAlignmentShift) and COFFAlignmentMask;
    if AlignmentCode = 0 then Section^.Alignment := COFFDefaultAlignment else Section^.Alignment := QWord(1) shl (AlignmentCode - 1);
    Section^.ZeroFill := (Characteristics and IMAGE_SCN_CNT_UNINITIALIZED_DATA) <> 0;
    if not Section^.ZeroFill and (SectionHeaders[I].PointerToRawData <> 0) then Section^.Data := AObjectFile^.Buffer + SectionHeaders[I].PointerToRawData;
    if ((Characteristics and (IMAGE_SCN_LNK_REMOVE or IMAGE_SCN_LNK_INFO or IMAGE_SCN_MEM_DISCARDABLE)) <> 0) or StartsWith(Section^.Name, DebugSectionPrefix) then Section^.Kind := 0
    else if (Characteristics and (IMAGE_SCN_MEM_EXECUTE or IMAGE_SCN_CNT_CODE)) <> 0 then Section^.Kind := KindCode
    else Section^.Kind := KindData;
  end;
  // room for one stand-in symbol per section (below): the array must not move once the
  // name map points into it
  SetLength(AObjectFile^.Symbols, Header^.NumberOfSymbols + Header^.NumberOfSections);
  SetLength(SectionOfSymbol, Header^.NumberOfSymbols);
  for I := 0 to High(SectionOfSymbol) do SectionOfSymbol[I] := -1;
  I := 0;
  while I < LongInt(Header^.NumberOfSymbols) do
  begin
    SymbolEntry := @Symbols[I];
    Symbol := @AObjectFile^.Symbols[I];
    Symbol^.Section := -1;
    if SymbolEntry^.StorageClass <> IMAGE_SYM_CLASS_FILE then
    begin
      Symbol^.Name := COFFSymbolName(SymbolEntry, StringTable);
      if (SymbolEntry^.StorageClass = IMAGE_SYM_CLASS_STATIC) and (SymbolEntry^.Value = 0) and (SymbolEntry^.NumberOfAuxSymbols > 0) and (SymbolEntry^.SectionNumber > 0)
        and (SymbolEntry^.SectionNumber <= Header^.NumberOfSections) and (Symbol^.Name = COFFSectionName(@SectionHeaders[SymbolEntry^.SectionNumber - 1], StringTable)) then
      begin
        SectionOfSymbol[I] := SymbolEntry^.SectionNumber - 1;   // the section itself
        Symbol^.Name := '';
      end
      else if (SymbolEntry^.SectionNumber > 0) and (SymbolEntry^.SectionNumber <= Header^.NumberOfSections) then
      begin
        if (AObjectFile^.Sections[SymbolEntry^.SectionNumber - 1].Kind <> 0) and (Symbol^.Name <> '') then
        begin
          Symbol^.Defined := True;
          Symbol^.External := SymbolEntry^.StorageClass = IMAGE_SYM_CLASS_EXTERNAL;
          Symbol^.Section := SymbolEntry^.SectionNumber - 1;
          Symbol^.Value := SymbolEntry^.Value;
          Symbol^.Kind := AObjectFile^.Sections[Symbol^.Section].Kind;
          AddDefined(AObjectFile, I);
        end;
      end
      else if SymbolEntry^.SectionNumber = 0 then Symbol^.External := True   // undefined
      else Symbol^.Name := '';   // absolute or debugging
    end;
    Inc(I, 1 + SymbolEntry^.NumberOfAuxSymbols);
  end;
  // fpc 3.2 gives an implementation-section variable no symbol at all, only a section of its
  // own named after it (.bss.n_u_$u_$$_hidden). Such a section stands for a variable named
  // after the section; the program's map file says where the linker put it.
  for I := 0 to Header^.NumberOfSections - 1 do
  begin
    Section := @AObjectFile^.Sections[I];
    if (Section^.Kind <> KindData) or (Section^.Size = 0) or (Pos('$', Section^.Name) = 0) then Continue;
    K := 0;
    while (K < LongInt(Header^.NumberOfSymbols)) and not (AObjectFile^.Symbols[K].Defined and (AObjectFile^.Symbols[K].Section = I)) do Inc(K);
    if K < LongInt(Header^.NumberOfSymbols) then Continue;   // it has symbols of its own
    Symbol := @AObjectFile^.Symbols[Header^.NumberOfSymbols + I];
    Symbol^.Name := SectionSymbolName(Section^.Name);
    Symbol^.Defined := True;
    Symbol^.External := True;
    Symbol^.Section := I;
    Symbol^.Value := 0;
    Symbol^.Kind := KindData;
    AddDefined(AObjectFile, Header^.NumberOfSymbols + I);
  end;
  for I := 0 to Header^.NumberOfSections - 1 do
  begin
    Section := @AObjectFile^.Sections[I];
    if (Section^.Kind = 0) or (SectionHeaders[I].NumberOfRelocations = 0) or (Section^.Data = nil) then Continue;
    RelocationEntries := PCOFFRelocation(AObjectFile^.Buffer + SectionHeaders[I].PointerToRelocations);
    RelocationCount := SectionHeaders[I].NumberOfRelocations;
    FirstRelocation := 0;
    if (SectionHeaders[I].Characteristics and IMAGE_SCN_LNK_NRELOC_OVFL) <> 0 then
    begin
      RelocationCount := RelocationEntries[0].VirtualAddress;   // more than 65535: the count is in the first entry
      FirstRelocation := 1;
    end;
    for K := FirstRelocation to RelocationCount - 1 do
    begin
      if RelocationEntries[K].RelocationType = IMAGE_REL_AMD64_ABSOLUTE then Continue;
      FillChar(Relocation, SizeOf(Relocation), 0);
      Relocation.Offset := RelocationEntries[K].VirtualAddress;
      Relocation.Symbol := -1;
      Relocation.Section := -1;
      // COFF keeps the addend in the bytes
      if RelocationEntries[K].RelocationType = IMAGE_REL_AMD64_ADDR64 then StoredAddend := PInt64(Section^.Data + Relocation.Offset)^ else StoredAddend := PLongInt(Section^.Data + Relocation.Offset)^;
      if (RelocationEntries[K].SymbolTableIndex < Header^.NumberOfSymbols) and (SectionOfSymbol[RelocationEntries[K].SymbolTableIndex] >= 0) then
      begin
        Relocation.Section := SectionOfSymbol[RelocationEntries[K].SymbolTableIndex];
        Relocation.TargetOffset := StoredAddend;
        Relocation.HasTargetOffset := True;
      end
      else Relocation.Symbol := RelocationEntries[K].SymbolTableIndex;
      case RelocationEntries[K].RelocationType of
        IMAGE_REL_AMD64_ADDR64: begin Relocation.Kind := rkAbsolute64; Relocation.Addend := StoredAddend; end;
        IMAGE_REL_AMD64_ADDR32: begin Relocation.Kind := rkAbsolute32; Relocation.Addend := StoredAddend; end;
        IMAGE_REL_AMD64_ADDR32NB: begin Relocation.Kind := rkRVA32; Relocation.Addend := StoredAddend; end;
        IMAGE_REL_AMD64_REL32..IMAGE_REL_AMD64_REL32_5:   // REL32, then REL32_1 .. REL32_5
          begin
            // field = target - (end of the field + k): the bias folds into the addend
            Relocation.Addend := StoredAddend - 4 - (RelocationEntries[K].RelocationType - IMAGE_REL_AMD64_REL32);
            if (Relocation.Offset >= 1) and ((Section^.Data[Relocation.Offset - 1] in [X86OpcodeCallRel32, X86OpcodeJumpRel32]) or ((Relocation.Offset >= 2) and (Section^.Data[Relocation.Offset - 2] = X86OpcodeTwoByte) and (Section^.Data[Relocation.Offset - 1] in [X86OpcodeJccFirst..X86OpcodeJccLast]))) then
              Relocation.Kind := rkBranch32
            else Relocation.Kind := rkPCRelative32;
          end;
      else
        Relocation.Kind := rkUnsupported;
        Relocation.SecondarySymbol := RelocationEntries[K].RelocationType;
      end;
      AddRelocation(Section^, Relocation);
    end;
  end;
  FinishObjectFile(AObjectFile);
  Result := True;
end;
{$endif}

function ParseObjectFile(const APath: AnsiString): PObjectFile;
var
  ObjectFile: PObjectFile;
  SeparatorIndex, DotIndex: SizeInt;
  Parsed: Boolean;
begin
  Result := nil;
  New(ObjectFile);
  FillChar(ObjectFile^, SizeOf(TObjectFile), 0);
  ObjectFile^.Path := APath;
  if not ReadWholeFile(APath, ObjectFile^.Buffer, ObjectFile^.BufferSize) then
  begin
    Say('error cannot read ' + APath);
    Dispose(ObjectFile);
    Exit;
  end;
  SeparatorIndex := Length(APath);
  while (SeparatorIndex > 0) and not (APath[SeparatorIndex] in ['/', '\']) do Dec(SeparatorIndex);
  ObjectFile^.UnitName := Copy(APath, SeparatorIndex + 1, Length(APath));
  DotIndex := Length(ObjectFile^.UnitName);
  while (DotIndex > 0) and (ObjectFile^.UnitName[DotIndex] <> '.') do Dec(DotIndex);
  if DotIndex > 0 then SetLength(ObjectFile^.UnitName, DotIndex - 1);
{$if defined(darwin)}
  Parsed := ParseMachO(ObjectFile);
{$elseif defined(windows)}
  Parsed := ParseCOFF(ObjectFile);
{$else}
  Parsed := ParseELFObject(ObjectFile);
{$endif}
  if not Parsed then
  begin
    FreeObjectFile(ObjectFile);
    Exit;
  end;
  Result := ObjectFile;
end;

// ================================================================ comparing versions
function SymbolBytes(AObjectFile: PObjectFile; ASymbol: PObjectSymbol): PByte; inline;
begin
  if AObjectFile^.Sections[ASymbol^.Section].ZeroFill then Result := nil
  else Result := AObjectFile^.Sections[ASymbol^.Section].Data + ASymbol^.Value;
end;

// First relocation of ASection at or after AOffset.
function FirstRelocation(const ASection: TSection; AOffset: QWord): SizeInt;
var
  Lower, Upper, Middle: SizeInt;
begin
  Lower := 0;
  Upper := Length(ASection.Relocations);
  while Lower < Upper do
  begin
    Middle := (Lower + Upper) shr 1;
    if ASection.Relocations[Middle].Offset < AOffset then Lower := Middle + 1 else Upper := Middle;
  end;
  Result := Lower;
end;

function HasRelocations(AObjectFile: PObjectFile; ASymbol: PObjectSymbol): Boolean;
var
  Index: SizeInt;
begin
  Index := FirstRelocation(AObjectFile^.Sections[ASymbol^.Section], ASymbol^.Value);
  Result := (Index < Length(AObjectFile^.Sections[ASymbol^.Section].Relocations)) and (AObjectFile^.Sections[ASymbol^.Section].Relocations[Index].Offset < ASymbol^.Value + ASymbol^.Size);
end;

// Unwind tables describe one version of the code: the new code needs its own, never the
// program's.
function IsUnwindSection(const AName: AnsiString): Boolean; inline;
begin
  Result := StartsWith(AName, PDataSectionPrefix) or StartsWith(AName, XDataSectionPrefix) or (AName = EHFrameSectionName);
end;

// fpc 3.2 gives a unit's literals, such as its floating point constants, global names:
// _$U$_Ld1, _$U$_Ld2, numbered in the order the compiler made them (3.3.1 makes them local
// .Ld labels). The number says nothing about which constant it is, so new code gets its own.
function IsNumberedLiteral(const AName: AnsiString): Boolean;
var
  Index, MarkerStart: SizeInt;
begin
  Index := Length(AName);
  while (Index > 0) and (AName[Index] in ['0'..'9']) do Dec(Index);
  MarkerStart := Index - Length(NumberedLiteralMarker) + 1;
  Result := (Index < Length(AName)) and (MarkerStart >= 1) and (Copy(AName, MarkerStart, Length(NumberedLiteralMarker)) = NumberedLiteralMarker);
end;

function IsAnonymous(const AName: AnsiString): Boolean;
begin
  Result := Contains(AName, AnonymousDefinitionMarker) or Contains(AName, FPCLocalMarker) or Contains(AName, LocalDataMarker) or StartsWith(AName, LocalLabelPrefix) or IsNumberedLiteral(AName);
end;

function IsAnonymousTarget(AObjectFile: PObjectFile; AIndex: LongInt): Boolean;
begin
  Result := AObjectFile^.Symbols[AIndex].Defined and ((not AObjectFile^.Symbols[AIndex].External) or IsAnonymous(AObjectFile^.Symbols[AIndex].Name));
end;

// For a pc-relative reference: the symbol it means. fpc's COFF writer folds the length of an
// immediate that follows the address into the stored offset (add dword [rip+X], 1 stores
// X-1 with a plain REL32), so an offset just before a symbol means that symbol.
function CoveringForRelocation(AObjectFile: PObjectFile; const ARelocation: TRelocation; AOffset: Int64): LongInt; forward;

// The defined symbol that covers an offset of a section, or -1. Sizes run up to the next
// symbol, so it is the last one in (section, value) order at or before the offset.
function Covering(AObjectFile: PObjectFile; ASection: LongInt; AOffset: Int64): LongInt;
var
  Lower, Upper, Middle: SizeInt;
  Symbol: PObjectSymbol;
begin
  Result := -1;
  Lower := 0;
  Upper := Length(AObjectFile^.Order);
  while Lower < Upper do
  begin
    Middle := (Lower + Upper) shr 1;
    Symbol := @AObjectFile^.Symbols[AObjectFile^.Order[Middle]];
    if (Symbol^.Section < ASection) or ((Symbol^.Section = ASection) and (Int64(Symbol^.Value) <= AOffset)) then Lower := Middle + 1 else Upper := Middle;
  end;
  if Lower = 0 then Exit;
  Symbol := @AObjectFile^.Symbols[AObjectFile^.Order[Lower - 1]];
  if (Symbol^.Section = ASection) and ((AOffset < Int64(Symbol^.Value + Symbol^.Size)) or ((Symbol^.Size = 0) and (AOffset = Int64(Symbol^.Value)))) then Result := AObjectFile^.Order[Lower - 1];
end;

function CoveringForRelocation(AObjectFile: PObjectFile; const ARelocation: TRelocation; AOffset: Int64): LongInt;
var
  Delta: LongInt;
begin
  Result := Covering(AObjectFile, ARelocation.Section, AOffset);
  if (Result < 0) and (ARelocation.Kind in [rkPCRelative32, rkBranch32]) then
    for Delta := 1 to 4 do
    begin
      Result := Covering(AObjectFile, ARelocation.Section, AOffset + Delta);
      if Result >= 0 then Exit;
    end;
end;

function SymbolDigest(AObjectFile: PObjectFile; ASymbol: PObjectSymbol; ADepth: LongInt): QWord; forward;

function TargetKey(AObjectFile: PObjectFile; ASymbolNumber: LongInt; AAddend: Int64; ADepth: LongInt): QWord;
var
  Target, BaseSymbol: PObjectSymbol;
  Bytes: PByte;
  StringLength: Int64;
  Name: AnsiString;
begin
  Target := @AObjectFile^.Symbols[ASymbolNumber];
  Name := Target^.Name;
  if IsAnonymousTarget(AObjectFile, ASymbolNumber) and (ADepth < MaxDigestDepth) then
  begin
    // A string constant is referenced 16 bytes into its header; its length is the word before.
    // Several constants can share one symbol, so hash the one that is meant.
    Bytes := SymbolBytes(AObjectFile, Target);
    if (Bytes <> nil) and not HasRelocations(AObjectFile, Target) then
    begin
      if (AAddend >= StringHeaderSize) and (QWord(AAddend) <= Target^.Size) then
      begin
        StringLength := PInt64(Bytes + AAddend - StringLengthSize)^;
        if (StringLength >= 0) and (QWord(AAddend + StringLength) <= Target^.Size) then Exit(FNVHash(Bytes + AAddend - StringHeaderSize, StringHeaderSize + StringLength, FNVOffsetBasis) xor SaltStringWithHeader);
      end;
      if (AAddend >= 0) and (QWord(AAddend) < Target^.Size) then Exit(FNVHash(Bytes + AAddend, Target^.Size - QWord(AAddend), FNVOffsetBasis) xor SaltStringTail);
    end;
    Exit(SymbolDigest(AObjectFile, Target, ADepth + 1) xor SaltAnonymousSymbol xor QWord(AAddend));
  end;
  if EndsWith(Name, IndirectSuffix) and Contains(Name, AnonymousDefinitionMarker) and (ADepth < MaxDigestDepth) then
  begin
    BaseSymbol := MapGet(AObjectFile^.ByName, Copy(Name, 1, Length(Name) - IndirectSuffixLength));
    if BaseSymbol <> nil then Exit(SymbolDigest(AObjectFile, BaseSymbol, ADepth + 1) xor SaltIndirectPointer);
  end;
  Result := FNVHashString(Name);
end;

// What a relocation refers to, as a key that does not depend on how the compiler numbered
// anonymous things; ANamed tells whether its addend is part of the identity.
function RelocationKey(AObjectFile: PObjectFile; const ARelocation: TRelocation; ADepth: LongInt; out ANamed: Boolean; out AAddend: Int64): QWord;
var
  CoveringIndex: LongInt;
  Section: PSection;
  Offset: Int64;
begin
  AAddend := ARelocation.Addend;
  if ARelocation.Symbol >= 0 then
  begin
    ANamed := not IsAnonymousTarget(AObjectFile, ARelocation.Symbol);
    Exit(TargetKey(AObjectFile, ARelocation.Symbol, ARelocation.Addend, ADepth));
  end;
  ANamed := False;
  if (ARelocation.Section < 0) or (ARelocation.Section > High(AObjectFile^.Sections)) then Exit(QWord(ARelocation.Section) xor QWord(ARelocation.Addend));
  Offset := ARelocation.Addend;
  if ARelocation.HasTargetOffset then Offset := ARelocation.TargetOffset;
  CoveringIndex := CoveringForRelocation(AObjectFile, ARelocation, Offset);
  if CoveringIndex >= 0 then
  begin
    AAddend := Offset - Int64(AObjectFile^.Symbols[CoveringIndex].Value);
    ANamed := not IsAnonymousTarget(AObjectFile, CoveringIndex);
    Exit(TargetKey(AObjectFile, CoveringIndex, AAddend, ADepth));
  end;
  Section := @AObjectFile^.Sections[ARelocation.Section];
  if (Section^.Data <> nil) and (Length(Section^.Relocations) = 0) and (Offset >= 0) and (QWord(Offset) < Section^.Size) then
    Exit(FNVHash(Section^.Data + Offset, Section^.Size - QWord(Offset), FNVOffsetBasis) xor SaltStringTail);
  Result := FNVHashString(Section^.Name) xor QWord(Offset);
end;

function RelocationWidth(AKind: TRelocationKind): QWord;
begin
  case AKind of
    rkAbsolute64, rkSubtract64, rkGOTAbsolute64: Result := 8;
    rkAbsolute32, rkSubtract32, rkAbsolute32Signed, rkRVA32, rkPCRelative32, rkBranch32: Result := 4;   // COFF keeps addends in these bytes
  else
    Result := 0;
  end;
end;

// A digest of a symbol's bytes and of what its relocations refer to. Names the compiler
// numbers (anonymous types, local constants) are replaced by a digest of their content,
// so that an unrelated edit that renumbers or moves them does not look like a change.
// Bytes a pointer relocation fills are left out: one object format keeps the addend there.
function SymbolDigest(AObjectFile: PObjectFile; ASymbol: PObjectSymbol; ADepth: LongInt): QWord;
var
  Section: PSection;
  Hash, Key, LowOffset, HighOffset, Cursor, Width: QWord;
  Bytes: PByte;
  Index: SizeInt;
  Offset, KindValue: LongWord;
  Named, SecondNamed: Boolean;
  Addend, SecondAddend: Int64;
  SecondRelocation: TRelocation;
begin
  Section := @AObjectFile^.Sections[ASymbol^.Section];
  Hash := FNVHash(PByte(@ASymbol^.Size), 8, FNVOffsetBasis);
  Bytes := SymbolBytes(AObjectFile, ASymbol);
  LowOffset := ASymbol^.Value;
  HighOffset := LowOffset + ASymbol^.Size;
  Cursor := LowOffset;
  Index := FirstRelocation(Section^, LowOffset);
  while (Index < Length(Section^.Relocations)) and (Section^.Relocations[Index].Offset < HighOffset) do
  begin
    Offset := LongWord(Section^.Relocations[Index].Offset - LowOffset);
    KindValue := LongWord(Ord(Section^.Relocations[Index].Kind));
    Width := RelocationWidth(Section^.Relocations[Index].Kind);
    if (Width > 0) and (Bytes <> nil) and (Section^.Relocations[Index].Offset >= Cursor) then
    begin
      if Section^.Relocations[Index].Offset > Cursor then Hash := FNVHash(Bytes + (Cursor - LowOffset), Section^.Relocations[Index].Offset - Cursor, Hash);
      Cursor := Section^.Relocations[Index].Offset + Width;
      if Cursor > HighOffset then Cursor := HighOffset;
    end;
    Hash := FNVHash(PByte(@Offset), 4, Hash);
    Hash := FNVHash(PByte(@KindValue), 4, Hash);
    Key := RelocationKey(AObjectFile, Section^.Relocations[Index], ADepth, Named, Addend);
    if Named then Hash := FNVHash(PByte(@Addend), 8, Hash);
    Hash := FNVHash(PByte(@Key), 8, Hash);
    if Section^.Relocations[Index].Kind in [rkSubtract64, rkSubtract32] then
    begin
      SecondRelocation := Section^.Relocations[Index];
      SecondRelocation.Symbol := SecondRelocation.SecondarySymbol;
      SecondRelocation.Addend := 0;
      Key := RelocationKey(AObjectFile, SecondRelocation, ADepth, SecondNamed, SecondAddend);
      Hash := FNVHash(PByte(@Key), 8, Hash);
    end;
    Inc(Index);
  end;
  if (Bytes <> nil) and (HighOffset > Cursor) then Hash := FNVHash(Bytes + (Cursor - LowOffset), HighOffset - Cursor, Hash);
  Result := Hash;
end;

// The name of the pointer target at an offset inside a symbol.
function RelocationTargetAt(AObjectFile: PObjectFile; ASymbol: PObjectSymbol; AOffset: QWord): AnsiString;
var
  Section: PSection;
  Index: SizeInt;
  CoveringIndex: LongInt;
begin
  Result := '';
  Section := @AObjectFile^.Sections[ASymbol^.Section];
  Index := FirstRelocation(Section^, ASymbol^.Value + AOffset);
  while (Index < Length(Section^.Relocations)) and (Section^.Relocations[Index].Offset = ASymbol^.Value + AOffset) do
  begin
    if Section^.Relocations[Index].Kind = rkAbsolute64 then
    begin
      if Section^.Relocations[Index].Symbol >= 0 then Exit(AObjectFile^.Symbols[Section^.Relocations[Index].Symbol].Name);
      CoveringIndex := Covering(AObjectFile, Section^.Relocations[Index].Section, Section^.Relocations[Index].Addend);
      if CoveringIndex >= 0 then Exit(AObjectFile^.Symbols[CoveringIndex].Name);
    end;
    Inc(Index);
  end;
end;

// WORKER_$$_STEP$LONGINT$$ANSISTRING -> WORKER.STEP(LONGINT):ANSISTRING (good enough to read)
function Pretty(const AName: AnsiString): AnsiString;
const
  Prefixes: array[0..6] of AnsiString = (PrefixVMT, PrefixRTTI, PrefixInitTable, PrefixVariable, PrefixTypedConstant, PrefixResourceString, PrefixThreadVarList);
var
  Text: AnsiString;
  Index: LongInt;
  Seen: Boolean;
begin
  Text := AName;
  if StartsWith(Text, SectionSymbolPrefix) then
  begin
    // @sect:.bss.n_u_$u_$$_hidden -> U_$U_$$_HIDDEN
    Index := Pos('.n_', Text);
    if Index > 0 then Delete(Text, 1, Index + 2) else Delete(Text, 1, Length(SectionSymbolPrefix));
    Text := UpCase(Text);
  end;
  for Index := 0 to High(Prefixes) do
    if StartsWith(Text, Prefixes[Index]) and (Length(Text) > Length(Prefixes[Index])) and (Text[Length(Prefixes[Index]) + 1] <> '$') then
    begin
      Delete(Text, 1, Length(Prefixes[Index]));
      Break;
    end;
  if StartsWith(Text, 'P$') then Delete(Text, 1, 2);
  Result := '';
  Seen := False;
  Index := 1;
  while Index <= Length(Text) do
  begin
    if Copy(Text, Index, 4) = '_$$_' then begin Result := Result + '.'; Inc(Index, 4); Continue; end;
    if Copy(Text, Index, 3) = '$_$' then begin Result := Result + '.'; Inc(Index, 3); Continue; end;
    if Copy(Text, Index, 4) = '_$__' then begin Inc(Index, 4); Continue; end;
    if Copy(Text, Index, 2) = '$$' then
    begin
      if Seen then Result := Result + ')';
      Result := Result + ':';
      Seen := False;
      Inc(Index, 2);
      Continue;
    end;
    if Text[Index] = '$' then
    begin
      if Seen then Result := Result + ',' else Result := Result + '(';
      Seen := True;
      Inc(Index);
      Continue;
    end;
    Result := Result + Text[Index];
    Inc(Index);
  end;
  if Seen then Result := Result + ')';
end;

// ================================================================ the running program
type
  PHostSymbol = ^THostSymbol;
  THostSymbol = record Address: QWord; IsCode, IsTLS: Boolean; end;   // IsTLS: Address is the offset in the TLS segment
var
  Slide: PtrInt;
  TextLow, TextHigh, ImageHigh: QWord;
  HostSymbols: TMap;
  HostPool: array of THostSymbol;
  HostBuilt: Boolean;
  HostMilliseconds: Double;
  TLSMemorySize, TLSAlignment: QWord;   // the executable's TLS segment
  PageSize: QWord;

{$if defined(darwin)}
var
  MachHeader: PMachHeader64;

procedure FindProgram;
var
  I: LongWord;
  Header: PMachHeader64;
  LoadCommand: PMachLoadCommand;
  SegmentCommand: PMachSegmentCommand64;
  LowAddress, HighAddress: QWord;
begin
  for I := 0 to DyldImageCount - 1 do
  begin
    Header := DyldGetImageHeader(I);
    if Header^.filetype = MH_EXECUTE then
    begin
      MachHeader := Header;
      Slide := DyldGetImageVMAddrSlide(I);
      Break;
    end;
  end;
  LoadCommand := PMachLoadCommand(PByte(MachHeader) + SizeOf(TMachHeader64));
  for I := 1 to MachHeader^.ncmds do
  begin
    if LoadCommand^.cmd = LC_SEGMENT_64 then
    begin
      SegmentCommand := PMachSegmentCommand64(LoadCommand);
      if FixedNameToString(SegmentCommand^.segname) <> PageZeroSegmentName then
      begin
        LowAddress := SegmentCommand^.vmaddr + QWord(Slide);
        HighAddress := LowAddress + SegmentCommand^.vmsize;
        if FixedNameToString(SegmentCommand^.segname) = TextSegmentName then
        begin
          TextLow := LowAddress;
          TextHigh := HighAddress;
        end;
        if HighAddress > ImageHigh then ImageHigh := HighAddress;
      end;
    end;
    LoadCommand := PMachLoadCommand(PByte(LoadCommand) + LoadCommand^.cmdsize);
  end;
end;

procedure BuildHostSymbols;
var
  StartTime: Double;
  LoadCommand: PMachLoadCommand;
  SymtabCommand: PMachSymtabCommand;
  SegmentCommand: PMachSegmentCommand64;
  SectionHeader: PMachSection64;
  LinkeditVMAddress, LinkeditFileOffset: QWord;
  SectionCount: LongInt;
  SectionIsCode: array[0..MachSectionLimit - 1] of Boolean;
  I, J: LongWord;
  Base: PByte;
  NameList: PMachSymbol64;
  Strings: PChar;
  Name: AnsiString;
begin
  if HostBuilt then Exit;
  StartTime := NowMilliseconds;
  SymtabCommand := nil;
  LinkeditVMAddress := 0;
  LinkeditFileOffset := 0;
  SectionCount := 0;
  FillChar(SectionIsCode, SizeOf(SectionIsCode), 0);
  LoadCommand := PMachLoadCommand(PByte(MachHeader) + SizeOf(TMachHeader64));
  for I := 1 to MachHeader^.ncmds do
  begin
    if LoadCommand^.cmd = LC_SYMTAB then SymtabCommand := PMachSymtabCommand(LoadCommand);
    if LoadCommand^.cmd = LC_SEGMENT_64 then
    begin
      SegmentCommand := PMachSegmentCommand64(LoadCommand);
      if FixedNameToString(SegmentCommand^.segname) = LinkeditSegmentName then
      begin
        LinkeditVMAddress := SegmentCommand^.vmaddr;
        LinkeditFileOffset := SegmentCommand^.fileoff;
      end;
      SectionHeader := PMachSection64(PByte(SegmentCommand) + SizeOf(TMachSegmentCommand64));
      for J := 1 to SegmentCommand^.nsects do
      begin
        Inc(SectionCount);
        if SectionCount < MachSectionLimit then SectionIsCode[SectionCount] := (SectionHeader^.flags and S_ATTR_PURE_INSTRUCTIONS) <> 0;
        Inc(SectionHeader);
      end;
    end;
    LoadCommand := PMachLoadCommand(PByte(LoadCommand) + LoadCommand^.cmdsize);
  end;
  if SymtabCommand <> nil then
  begin
    Base := PByte(PtrUInt(LinkeditVMAddress - LinkeditFileOffset + QWord(Slide)));
    NameList := PMachSymbol64(Base + SymtabCommand^.symoff);
    Strings := PChar(Base + SymtabCommand^.stroff);
    SetLength(HostPool, SymtabCommand^.nsyms);
    for I := 0 to SymtabCommand^.nsyms - 1 do
    begin
      if (NameList[I].n_type and N_STAB) <> 0 then Continue;
      if (NameList[I].n_type and N_TYPE) <> N_SECT then Continue;
      Name := MachSymbolName(Strings + NameList[I].n_strx);
      if Name = '' then Continue;
      HostPool[I].Address := NameList[I].n_value + QWord(Slide);
      HostPool[I].IsCode := SectionIsCode[NameList[I].n_sect];
      MapPut(HostSymbols, Name, @HostPool[I]);
    end;
  end;
  HostBuilt := True;
  HostMilliseconds := NowMilliseconds - StartTime;
end;
{$elseif defined(linux)}
var
  Executable: TObjectFile;   // the executable's file, read once

procedure FindProgram;
var
  Header: PELFHeader;
  ProgramHeaders: PELFProgramHeader;
  SectionHeaders: PELFSectionHeader;
  Symbols: PELFSymbol;
  Strings: PChar;
  I, J: SizeInt;
  LowAddress, HighAddress: QWord;
begin
  FillChar(Executable, SizeOf(Executable), 0);
  Executable.Path := '/proc/self/exe';
  if not ReadWholeFile(Executable.Path, Executable.Buffer, Executable.BufferSize) or not IsValidELF(@Executable, 0) then Exit;
  Header := PELFHeader(Executable.Buffer);
  Slide := 0;
  if Header^.e_type = ET_DYN then
  begin
    // position independent: the distance between where this unit's anchor is and where
    // the file says it is
    SectionHeaders := PELFSectionHeader(Executable.Buffer + Header^.e_shoff);
    for I := 0 to Header^.e_shnum - 1 do
      if SectionHeaders[I].sh_type = SHT_SYMTAB then
      begin
        Symbols := PELFSymbol(Executable.Buffer + SectionHeaders[I].sh_offset);
        Strings := PChar(Executable.Buffer + SectionHeaders[SectionHeaders[I].sh_link].sh_offset);
        for J := 0 to SectionHeaders[I].sh_size div SizeOf(TELFSymbol) - 1 do
          if AnsiString(PChar(Strings + Symbols[J].st_name)) = AnchorSymbolName then Slide := PtrInt(PtrUInt(@HotAnchor)) - PtrInt(Symbols[J].st_value);
      end;
  end;
  ProgramHeaders := PELFProgramHeader(Executable.Buffer + Header^.e_phoff);
  for I := 0 to Header^.e_phnum - 1 do
  begin
    if ProgramHeaders[I].p_type = PT_TLS then
    begin
      TLSMemorySize := ProgramHeaders[I].p_memsz;
      TLSAlignment := ProgramHeaders[I].p_align;
      if TLSAlignment = 0 then TLSAlignment := 1;
    end;
    if ProgramHeaders[I].p_type <> PT_LOAD then Continue;
    LowAddress := ProgramHeaders[I].p_vaddr + QWord(Slide);
    HighAddress := LowAddress + ProgramHeaders[I].p_memsz;
    if (ProgramHeaders[I].p_flags and PF_X) <> 0 then
    begin
      if (TextLow = 0) or (LowAddress < TextLow) then TextLow := LowAddress;
      if HighAddress > TextHigh then TextHigh := HighAddress;
    end;
    if HighAddress > ImageHigh then ImageHigh := HighAddress;
  end;
end;

procedure BuildHostSymbols;
var
  StartTime: Double;
  Header: PELFHeader;
  SectionHeaders: PELFSectionHeader;
  Symbols: PELFSymbol;
  Strings: PChar;
  I, J, Count: SizeInt;
  Name: AnsiString;
  SymbolType: Byte;
begin
  if HostBuilt then Exit;
  StartTime := NowMilliseconds;
  if Executable.Buffer <> nil then
  begin
    Header := PELFHeader(Executable.Buffer);
    SectionHeaders := PELFSectionHeader(Executable.Buffer + Header^.e_shoff);
    for I := 0 to Header^.e_shnum - 1 do
    begin
      if SectionHeaders[I].sh_type <> SHT_SYMTAB then Continue;
      Symbols := PELFSymbol(Executable.Buffer + SectionHeaders[I].sh_offset);
      Strings := PChar(Executable.Buffer + SectionHeaders[SectionHeaders[I].sh_link].sh_offset);
      Count := SectionHeaders[I].sh_size div SizeOf(TELFSymbol);
      SetLength(HostPool, Count);
      for J := 0 to Count - 1 do
      begin
        SymbolType := Symbols[J].st_info and ELFSymbolTypeMask;
        if (SymbolType = STT_SECTION) or (SymbolType = STT_FILE) or (Symbols[J].st_shndx = 0) or (Symbols[J].st_shndx >= SHN_LORESERVE) then Continue;
        Name := PChar(Strings + Symbols[J].st_name);
        if (Name = '') or IsMappingSymbol(Name) then Continue;
        HostPool[J].Address := Symbols[J].st_value + QWord(Slide);
        HostPool[J].IsCode := (SectionHeaders[Symbols[J].st_shndx].sh_flags and SHF_EXECINSTR) <> 0;
        HostPool[J].IsTLS := (SectionHeaders[Symbols[J].st_shndx].sh_flags and SHF_TLS) <> 0;
        if HostPool[J].IsTLS then HostPool[J].Address := Symbols[J].st_value;   // an offset, not an address
        MapPut(HostSymbols, Name, @HostPool[J]);
      end;
    end;
    FreeMem(Executable.Buffer);
    Executable.Buffer := nil;
  end;
  HostBuilt := True;
  HostMilliseconds := NowMilliseconds - StartTime;
end;
{$else}
// Windows: the image's headers are mapped at its base; the COFF symbol table that a link
// with -Xs- keeps is only in the file. Symbol values are offsets in their sections.
const
  PEHeaderOffsetField = $3c;
  PESignatureSize = 4;
  PEOptionalHeaderOffset = 24;
  PEImageBaseOffset = 24;
  PESizeOfImageOffset = 56;
  PathBufferSize = 1024;
  MapPoolInitialSize = 1024;
  MapFieldCount = 4;
  LineFeed = 10;
  CarriageReturn = 13;

var
  ImageBase: QWord;
  MapNames: TMap;

procedure FindProgram;
var
  Base, OptionalHeader: PByte;
  PEOffset: LongWord;
  FileHeader: PCOFFHeader;
  SectionHeaders: PCOFFSection;
  I: LongInt;
  LowAddress, HighAddress: QWord;
begin
  ImageBase := GetModuleHandleA(nil);
  Base := PByte(PtrUInt(ImageBase));
  PEOffset := PLongWord(Base + PEHeaderOffsetField)^;
  FileHeader := PCOFFHeader(Base + PEOffset + PESignatureSize);
  OptionalHeader := Base + PEOffset + PEOptionalHeaderOffset;
  Slide := PtrInt(ImageBase) - PtrInt(PQWord(OptionalHeader + PEImageBaseOffset)^);   // PE32+ ImageBase
  ImageHigh := ImageBase + PLongWord(OptionalHeader + PESizeOfImageOffset)^;              // SizeOfImage
  SectionHeaders := PCOFFSection(OptionalHeader + FileHeader^.SizeOfOptionalHeader);
  for I := 0 to FileHeader^.NumberOfSections - 1 do
    if (SectionHeaders[I].Characteristics and IMAGE_SCN_MEM_EXECUTE) <> 0 then
    begin
      LowAddress := ImageBase + SectionHeaders[I].VirtualAddress;
      HighAddress := LowAddress + SectionHeaders[I].VirtualSize;
      if (TextLow = 0) or (LowAddress < TextLow) then TextLow := LowAddress;
      if HighAddress > TextHigh then TextHigh := HighAddress;
    end;
end;

// The linker's map (hotfpc links Windows programs with -Xm) lists every input section with
// its address: "<name> 0x<address> 0x<size> <object>", the name alone on the line before
// when it is long. Sections named after a variable (with a $ in the name) become host names.
var
  MapPool: array of THostSymbol;

procedure ReadMapFile(const AExecutablePath: AnsiString);
var
  Buffer: PByte;
  Size: PtrUInt;
  I, LineStart, LineEnd, Count, Cursor: SizeInt;
  Line, PreviousName, Name, AddressText: AnsiString;
  Address: QWord;
  ErrorCode: Word;

  function Fields(const ALine: AnsiString; out AFirst, ASecond: AnsiString): LongInt;
  var
    Index, PartCount: SizeInt;
    Parts: array[0..MapFieldCount - 1] of AnsiString;
  begin
    PartCount := 0;
    Index := 1;
    while (Index <= Length(ALine)) and (PartCount < MapFieldCount) do
    begin
      while (Index <= Length(ALine)) and (ALine[Index] = ' ') do Inc(Index);
      if Index > Length(ALine) then Break;
      Parts[PartCount] := '';
      while (Index <= Length(ALine)) and (ALine[Index] <> ' ') do
      begin
        Parts[PartCount] := Parts[PartCount] + ALine[Index];
        Inc(Index);
      end;
      Inc(PartCount);
    end;
    Result := PartCount;
    AFirst := '';
    ASecond := '';
    if PartCount > 0 then AFirst := Parts[0];
    if PartCount > 1 then ASecond := Parts[1];
    if (PartCount = MapFieldCount) then
    begin
      AFirst := Parts[0];
      ASecond := Parts[1];
    end;
  end;

begin
  Name := AExecutablePath;
  Cursor := Length(Name);
  while (Cursor > 0) and (Name[Cursor] <> '.') and not (Name[Cursor] in ['/', '\']) do Dec(Cursor);
  if (Cursor > 0) and (Name[Cursor] = '.') then SetLength(Name, Cursor - 1);
  if not ReadWholeFile(Name + '.map', Buffer, Size) then Exit;
  SetLength(MapPool, MapPoolInitialSize);
  Count := 0;
  PreviousName := '';
  LineStart := 0;
  for I := 0 to PtrInt(Size) do
  begin
    if (I < PtrInt(Size)) and (Buffer[I] <> LineFeed) then Continue;
    LineEnd := I;
    if (LineEnd > LineStart) and (Buffer[LineEnd - 1] = CarriageReturn) then Dec(LineEnd);
    SetString(Line, PChar(Buffer + LineStart), LineEnd - LineStart);
    LineStart := I + 1;
    // " <name>" alone, or " <name> 0x.. 0x.. obj", or "    0x.. 0x.. obj" after a name line
    if (Length(Line) > 2) and (Line[1] = ' ') and (Line[2] <> ' ') then
    begin
      Fields(Line, Name, AddressText);
      if (Copy(AddressText, 1, 2) = '0x') then
      begin
        PreviousName := '';
        Val('$' + Copy(AddressText, 3, 16), Address, ErrorCode);
      end
      else
      begin
        PreviousName := Name;
        Continue;
      end;
    end
    else if (PreviousName <> '') and (Length(Line) > 2) and (Line[1] = ' ') then
    begin
      Fields(Line, AddressText, Name);
      Name := PreviousName;
      PreviousName := '';
      if Copy(AddressText, 1, 2) <> '0x' then Continue;
      Val('$' + Copy(AddressText, 3, 16), Address, ErrorCode);
    end
    else
    begin
      PreviousName := '';
      Continue;
    end;
    if (ErrorCode <> 0) or (Pos('$', Name) = 0) or (Address = 0) then Continue;
    if Count = Length(MapPool) then SetLength(MapPool, Count * 2);
    // the pool only grows before any pointer into it is taken: pointers are taken below
    MapPool[Count].Address := Address + QWord(Slide);
    MapPool[Count].IsCode := False;
    MapPool[Count].IsTLS := False;
    Inc(Count);
    MapPut(MapNames, SectionSymbolName(Name), Pointer(PtrUInt(Count)));   // index + 1 for now
  end;
  FreeMem(Buffer);
  // now that the pool no longer moves: the names point at their entries
  for I := 0 to High(MapNames.Keys) do
    if MapNames.Keys[I] <> '' then
      MapPut(HostSymbols, MapNames.Keys[I], @MapPool[PtrUInt(MapNames.Values[I]) - 1]);
end;

procedure BuildHostSymbols;
var
  StartTime: Double;
  Path: array[0..PathBufferSize - 1] of Char;
  Buffer: PByte;
  Size: PtrUInt;
  PEOffset: LongWord;
  FileHeader: PCOFFHeader;
  SectionHeaders: PCOFFSection;
  Symbols, SymbolEntry: PCOFFSymbol;
  StringTable: PChar;
  I, PathLength: LongInt;
  Name: AnsiString;
begin
  if HostBuilt then Exit;
  StartTime := NowMilliseconds;
  PathLength := GetModuleFileNameA(0, @Path[0], SizeOf(Path));
  if (PathLength > 0) and ReadWholeFile(AnsiString(PChar(@Path[0])), Buffer, Size) then
  begin
    PEOffset := PLongWord(Buffer + PEHeaderOffsetField)^;
    FileHeader := PCOFFHeader(Buffer + PEOffset + PESignatureSize);
    SectionHeaders := PCOFFSection(Buffer + PEOffset + PEOptionalHeaderOffset + FileHeader^.SizeOfOptionalHeader);
    if (FileHeader^.PointerToSymbolTable <> 0) and (FileHeader^.NumberOfSymbols > 0) then
    begin
      Symbols := PCOFFSymbol(Buffer + FileHeader^.PointerToSymbolTable);
      StringTable := PChar(Buffer + FileHeader^.PointerToSymbolTable + FileHeader^.NumberOfSymbols * SizeOf(TCOFFSymbol));
      SetLength(HostPool, FileHeader^.NumberOfSymbols);
      I := 0;
      while I < LongInt(FileHeader^.NumberOfSymbols) do
      begin
        SymbolEntry := @Symbols[I];
        if ((SymbolEntry^.StorageClass = IMAGE_SYM_CLASS_EXTERNAL) or (SymbolEntry^.StorageClass = IMAGE_SYM_CLASS_STATIC))
          and (SymbolEntry^.SectionNumber > 0) and (SymbolEntry^.SectionNumber <= FileHeader^.NumberOfSections)
          and not ((SymbolEntry^.StorageClass = IMAGE_SYM_CLASS_STATIC) and (SymbolEntry^.NumberOfAuxSymbols > 0)) then
        begin
          Name := COFFSymbolName(SymbolEntry, StringTable);
          if Name <> '' then
          begin
            HostPool[I].Address := ImageBase + SectionHeaders[SymbolEntry^.SectionNumber - 1].VirtualAddress + SymbolEntry^.Value;
            HostPool[I].IsCode := (SectionHeaders[SymbolEntry^.SectionNumber - 1].Characteristics and IMAGE_SCN_MEM_EXECUTE) <> 0;
            // an external name wins over a local one of another unit
            if (SymbolEntry^.StorageClass = IMAGE_SYM_CLASS_EXTERNAL) or (MapGet(HostSymbols, Name) = nil) then MapPut(HostSymbols, Name, @HostPool[I]);
          end;
        end;
        Inc(I, 1 + SymbolEntry^.NumberOfAuxSymbols);
      end;
    end;
    FreeMem(Buffer);
  end;
  ReadMapFile(AnsiString(PChar(@Path[0])));
  HostBuilt := True;
  HostMilliseconds := NowMilliseconds - StartTime;
end;
{$endif}

// ================================================================ the system: memory and code
procedure JITWritable(AEnabled: Boolean);
begin
{$ifdef darwin}
  if AEnabled then PThreadJITWriteProtectNP(0) else PThreadJITWriteProtectNP(1);
{$endif}
end;

{$if defined(linux) and defined(cpuaarch64)}
function ReadCacheTypeRegister: QWord; assembler; nostackframe;
asm
  .long 0xd53b0020   // mrs x0, ctr_el0
end;
procedure CleanDataCacheLine(AAddress: QWord); assembler; nostackframe;
asm
  .long 0xd50b7b20   // dc cvau, x0
end;
procedure InvalidateInstructionCacheLine(AAddress: QWord); assembler; nostackframe;
asm
  .long 0xd50b7520   // ic ivau, x0
end;
procedure DataSynchronizationBarrier; assembler; nostackframe;
asm
  .long 0xd5033b9f   // dsb ish
end;
procedure InstructionSynchronizationBarrier; assembler; nostackframe;
asm
  .long 0xd5033fdf   // isb
end;
{$endif}

// After writing instructions: make the instruction cache see them.
procedure ClearCache(AStart: Pointer; ASize: PtrUInt);
{$if defined(darwin)}
begin
  if ASize > 0 then SysICacheInvalidate(AStart, ASize);
end;
{$elseif defined(windows)}
begin
  FlushInstructionCache(GetCurrentProcess, AStart, ASize);
end;
{$elseif defined(cpux86_64)}
begin
  // x86-64 keeps instruction fetch coherent with stores
end;
{$else}
var
  CacheType, DataLineSize, InstructionLineSize, Address, EndAddress: QWord;
begin
  if ASize = 0 then Exit;
  CacheType := ReadCacheTypeRegister;
  DataLineSize := QWord(ARM64CacheLineBase) shl ((CacheType shr ARM64CTRDMinLineShift) and ARM64CTRLineMask);
  InstructionLineSize := QWord(ARM64CacheLineBase) shl (CacheType and ARM64CTRLineMask);
  EndAddress := QWord(PtrUInt(AStart)) + ASize;
  Address := QWord(PtrUInt(AStart)) and not (DataLineSize - 1);
  while Address < EndAddress do
  begin
    CleanDataCacheLine(Address);
    Inc(Address, DataLineSize);
  end;
  DataSynchronizationBarrier;
  Address := QWord(PtrUInt(AStart)) and not (InstructionLineSize - 1);
  while Address < EndAddress do
  begin
    InvalidateInstructionCacheLine(Address);
    Inc(Address, InstructionLineSize);
  end;
  DataSynchronizationBarrier;
  InstructionSynchronizationBarrier;
end;
{$endif}

var
  IslandRegion, IslandNext: PByte;                  // island region, near the program
  JITRegion, JITNext, VeneerNext: PByte;      // code region
  DataRegion, DataNext: PByte;
  SlotNext: PQWord;
  RegionsFailed: Boolean;

function IslandInReach(AStart: QWord): Boolean;
begin
  Result := (Int64(AStart + IslandAreaSize - TextLow) < IslandReach) and (Int64(TextHigh - AStart) < IslandReach);
end;

function IsRegionInReach(AKind: LongInt; AStart, ASize: QWord; AReach: Int64): Boolean;
begin
  if AKind = RegionKindIsland then Result := IslandInReach(AStart)
  else Result := (Int64(AStart + ASize - TextLow) < AReach) and (Int64(TextHigh - AStart) < AReach);
{$if defined(linux) and defined(cpux86_64)}
  // fpc's x86-64 code is not position independent: it reaches variables and tables through
  // sign-extended 32-bit addresses (R_X86_64_32S), so a program loaded low needs its new
  // code and data below 2 GiB too.
  if TextHigh < LowMemoryLimit then Result := Result and (AStart + ASize <= LowMemoryLimit);
{$endif}
end;

// A region of memory within reach of the program's code. A hint to mmap is honoured when
// the place is free on Linux and is a lower bound on Darwin; either way, try places from
// the bottom of the window upwards and keep the first mapping that lands in reach.
{$ifdef windows}
// Windows: VirtualAlloc at an address either gives exactly that address or nothing. Start
// above the image, because unwind tables hold 32-bit offsets from the image's base.
function ReserveNear(ASize: QWord; AKind: LongInt; AReach: Int64): PByte;
var
  Candidate: QWord;
  Mapping: Pointer;
begin
  Result := nil;
  Candidate := (ImageHigh + AllocationGranularityMask) and not QWord(AllocationGranularityMask);
  while Int64(Candidate - TextHigh) < AReach do
  begin
    if IsRegionInReach(AKind, Candidate, ASize, AReach) then
    begin
      Mapping := VirtualAlloc(Pointer(PtrUInt(Candidate)), ASize, MEM_RESERVE or MEM_COMMIT, PAGE_EXECUTE_READWRITE);
      if Mapping <> nil then Exit(PByte(Mapping));
    end;
    Inc(Candidate, ReserveStep);
  end;
end;
{$else}
function ReserveNear(ASize: QWord; AKind: LongInt; AReach: Int64): PByte;
var
  Candidate, Mapped: QWord;
  Protection, Flags: LongInt;
  Mapping: Pointer;
begin
  Result := nil;
  if TextLow > QWord(AReach) + LowBound then Candidate := TextLow - QWord(AReach) else Candidate := LowBound;
  Candidate := (Candidate + HintAlignmentMask) and not QWord(HintAlignmentMask);
  Protection := ProtectRead or ProtectWrite;
  Flags := MapPrivate or MapAnonymous;
  if AKind <> RegionKindData then
  begin
    Protection := Protection or ProtectExecute;
    Flags := Flags or MapJIT;
  end;
  while Int64(Candidate - TextHigh) < AReach do
  begin
    if IsRegionInReach(AKind, Candidate, ASize, AReach) then
    begin
      Mapping := Fpmmap(Pointer(PtrUInt(Candidate)), ASize, Protection, Flags, -1, 0);
      if Mapping <> MAP_FAILED then
      begin
        Mapped := QWord(PtrUInt(Mapping));
        if IsRegionInReach(AKind, Mapped, ASize, AReach) then Exit(PByte(Mapping));
        Fpmunmap(Mapping, ASize);
      end;
    end;
    Inc(Candidate, ReserveStep);
  end;
end;
{$endif}

function InitializeRegions: Boolean;
var
  Islands, Code, Data: PByte;
  TestBlock: PChar;
  Address, Size: QWord;
  ErrorCode: Word;
  Mapping: Pointer;
begin
  if JITRegion <> nil then Exit(True);
  // Test only: HOT_TEST_BLOCK=<MiB> puts an obstacle right above the program first, to
  // reproduce the layout in which the allocator's zone took the neighbourhood.
{$ifdef unix}
  TestBlock := FpGetEnv('HOT_TEST_BLOCK');
  if (TestBlock <> nil) and not RegionsFailed then
  begin
    Address := (ImageHigh + (QWord(1) shl 20)) and not QWord(HintAlignmentMask);
    Val(AnsiString(TestBlock), Size, ErrorCode);
    Mapping := Fpmmap(Pointer(PtrUInt(Address)), Size shl 20, 0, MapPrivate or MapAnonymous, -1, 0);
    WriteLn(StdErr, '[hotfpc agent] test obstacle of ', TestBlock, ' MiB at ', HexToString(QWord(PtrUInt(Mapping))), ' (asked ', HexToString(Address), ')');
  end;
{$else}
  TestBlock := nil;
{$endif}
  if RegionsFailed then
  begin
    Say('restart hot reloading is off in this process: no free memory within reach of the program''s code');
    Exit(False);
  end;
{$ifdef cpux86_64}
  // One block for islands, code and data: an island reaches its slot, and new code the
  // program's variables, through 32-bit offsets, so everything must be within 2 GiB of
  // everything else. (Linux does not stop a mapping from being writable and executable.)
  Islands := ReserveNear(IslandAreaSize + JITSize + DataAreaSize, RegionKindCode, RegionReach);
  Code := nil;
  Data := nil;
  if Islands <> nil then
  begin
    Code := Islands + IslandAreaSize;
    Data := Code + JITSize;
  end;
{$else}
  Islands := ReserveNear(IslandAreaSize, RegionKindIsland, IslandReach);
  Code := nil;
  Data := nil;
  if Islands <> nil then Code := ReserveNear(JITSize, RegionKindCode, RegionReach);
  if Code <> nil then Data := ReserveNear(DataAreaSize, RegionKindData, RegionReach);
{$endif}
  if (Islands = nil) or (Code = nil) or (Data = nil) then
  begin
{$if defined(unix) and not defined(cpux86_64)}
    if Islands <> nil then Fpmunmap(Islands, IslandAreaSize);
    if Code <> nil then Fpmunmap(Code, JITSize);
{$endif}
    RegionsFailed := True;
    Say('restart hot reloading is off in this process: no free memory within reach of the program''s code');
    Exit(False);
  end;
  IslandRegion := Islands;
  JITRegion := Code;
  DataRegion := Data;
  if TestBlock <> nil then
    WriteLn(StdErr, '[hotfpc agent] islands ', HexToString(QWord(PtrUInt(Islands))), ' (', (Int64(PtrUInt(Islands)) - Int64(TextLow)) div (1 shl 20), ' MiB from the start of the program''s text), code ',
      HexToString(QWord(PtrUInt(Code))), ' (', (Int64(PtrUInt(Code)) - Int64(TextLow)) div (1 shl 20), ' MiB), data ', HexToString(QWord(PtrUInt(Data))));
  IslandNext := IslandRegion;
  VeneerNext := JITRegion;
  JITNext := JITRegion + VeneerAreaSize;
  SlotNext := PQWord(DataRegion);
  DataNext := DataRegion + SlotAreaSize;
  Result := True;
end;

function InJIT(AAddress: QWord): Boolean;
begin
  Result := ((JITRegion <> nil) and (AAddress >= QWord(PtrUInt(JITRegion))) and (AAddress < QWord(PtrUInt(JITRegion)) + JITSize))
    or ((IslandRegion <> nil) and (AAddress >= QWord(PtrUInt(IslandRegion))) and (AAddress < QWord(PtrUInt(IslandRegion)) + IslandAreaSize));
end;

function Bump(var ANext: PByte; ALimit: PByte; ASize, AAlignment: QWord): PByte;
var
  Aligned: QWord;
begin
  Aligned := (QWord(PtrUInt(ANext)) + AAlignment - 1) and not (AAlignment - 1);
  if Aligned + ASize > QWord(PtrUInt(ALimit)) then Exit(nil);
  ANext := PByte(PtrUInt(Aligned + ASize));
  Result := PByte(PtrUInt(Aligned));
end;

// ---------------------------------------------------------------- instructions: islands and branches
type
  TPatch = record
    Address: QWord;
    ByteCount: LongInt;
    Bytes: array[0..7] of Byte;
  end;

{$ifdef cpuaarch64}
// An island: adrp x16, slot ; ldr x16, [x16, off] ; br x16. The slot is ordinary memory.
function WriteIsland(var ANext: PByte; ALimit: PByte; ASlot: PQWord): QWord;
var
  Island: PLongWord;
  PageDistance: Int64;
begin
  Island := PLongWord(ANext);
  if PByte(Island + ARM64IslandInstructions) > ALimit then Exit(0);
  Inc(ANext, ARM64IslandInstructions * SizeOf(LongWord));
  PageDistance := SarInt64(Int64((QWord(PtrUInt(ASlot)) and not QWord(ARM64Imm12Mask)) - (QWord(PtrUInt(Island)) and not QWord(ARM64Imm12Mask))), ARM64Imm12Bits);
  Island[0] := ARM64AdrpX16 or (LongWord(PageDistance and 3) shl 29) or (LongWord((PageDistance shr 2) and ARM64ImmHiMask) shl 5);
  Island[1] := ARM64LdrX16 or (LongWord((QWord(PtrUInt(ASlot)) and ARM64Imm12Mask) shr 3) shl 10);
  Island[2] := ARM64BrX16;
  Result := QWord(PtrUInt(Island));
end;

// The entry of a function, overwritten: b island.
function RedirectPatch(AFrom, ATarget: QWord): TPatch;
var
  Instruction: LongWord;
begin
  Instruction := ARM64Branch or (LongWord(SarInt64(Int64(ATarget - AFrom), 2)) and ARM64Imm26Mask);
  Result.Address := AFrom;
  Result.ByteCount := 4;
  Move(Instruction, Result.Bytes[0], 4);
end;
{$else}
// An island: jmp qword ptr [rip + slot]. The slot is ordinary memory within 2 GiB.
function WriteIsland(var ANext: PByte; ALimit: PByte; ASlot: PQWord): QWord;
var
  Island: PByte;
  Distance: Int64;
begin
  Island := PByte((PtrUInt(ANext) + (X86IslandSize - 1)) and not PtrUInt(X86IslandSize - 1));
  if Island + X86IndirectJumpSize > ALimit then Exit(0);
  Distance := Int64(QWord(PtrUInt(ASlot)) - QWord(PtrUInt(Island + X86IndirectJumpSize)));
  if (Distance >= BranchReach) or (Distance < -BranchReach) then Exit(0);
  ANext := Island + X86IslandSize;
  Island[0] := X86OpcodeGroup5;
  Island[1] := X86ModRMJumpRIP;
  PLongInt(Island + 2)^ := LongInt(Distance);
  Result := QWord(PtrUInt(Island));
end;

// The entry of a function, overwritten: jmp rel32 island (5 bytes).
function RedirectPatch(AFrom, ATarget: QWord): TPatch;
begin
  Result.Address := AFrom;
  Result.ByteCount := X86JumpRel32Size;
  Result.Bytes[0] := X86OpcodeJumpRel32;
  PLongInt(@Result.Bytes[1])^ := LongInt(Int64(ATarget - (AFrom + X86JumpRel32Size)));
end;
{$endif}

// Next to the program: what an overwritten entry branches to.
function MakeIsland(ASlot: PQWord): QWord;
begin
  Result := WriteIsland(IslandNext, IslandRegion + IslandAreaSize, ASlot);
end;

// Next to the new code: what a call out of reach of bl goes through.
function MakeVeneer(ASlot: PQWord): QWord;
begin
  Result := WriteIsland(VeneerNext, JITRegion + VeneerAreaSize, ASlot);
end;

function NewSlot(AValue: QWord): PQWord;
begin
  if PByte(SlotNext + 1) > DataRegion + SlotAreaSize then Exit(nil);
  SlotNext^ := AValue;
  Result := SlotNext;
  Inc(SlotNext);
end;

// ================================================================ registry of what the agent manages
type
  PRegistrySymbol = ^TRegistrySymbol;
  TRegistrySymbol = record
    Name: AnsiString;
    Kind: Byte;
    CanonicalAddress: QWord;       // the address the symbol has as a value, for the life of the process
    CurrentAddress: QWord;         // newest code (functions)
    Slot: PQWord;       // functions: what the islands jump through
    Island: QWord;      // next to the program: for the entry in the program's text
    FarIsland: QWord;   // next to the new code: for entries of superseded versions there
    Pending: Boolean;
    PendingCanonicalAddress, PendingCurrentAddress: QWord;
  end;
  TStore = record Destination: PQWord; Value: QWord; end;
  TVMTUpdate = record ObjectFile: PObjectFile; Symbol: PObjectSymbol; OldAddress: QWord; end;
  TDataCopy = record Destination: QWord; Source: PByte; Size: QWord; end;
var
  Registry: TMap;
  Units: TMap;      // unit name -> PObjectFile, the live version
  Veneers: TMap;    // target address -> veneer, for calls out of reach of bl
  Indirects: TMap;  // X$indirect the program does not have -> the pointer to X made for it
  PendingSymbols: array of PRegistrySymbol;
  PendingCount: SizeInt;
  Patches: array of TPatch;
  PatchCount: SizeInt;
  Stores: array of TStore;
  StoreCount: SizeInt;
  VMTUpdates: array of TVMTUpdate;
  VMTUpdateCount: SizeInt;
  DataCopies: array of TDataCopy;
  DataCopyCount: SizeInt;
  RestartCount: LongInt;
  Poisoned: Boolean;
  PatchedCount: LongInt;
  SuspendThreads: Boolean = True;

procedure AddPatch(const APatch: TPatch);
begin
  if PatchCount = Length(Patches) then SetLength(Patches, ListGrowthLarge + 2 * Length(Patches));
  Patches[PatchCount] := APatch;
  Inc(PatchCount);
end;

procedure AddStore(ADestination: PQWord; AValue: QWord);
begin
  if StoreCount = Length(Stores) then SetLength(Stores, ListGrowthLarge + 2 * Length(Stores));
  Stores[StoreCount].Destination := ADestination;
  Stores[StoreCount].Value := AValue;
  Inc(StoreCount);
end;

procedure Restart(const AReason: AnsiString);
begin
  Say('restart ' + AReason);
  Inc(RestartCount);
end;

function RegistryGet(const AName: AnsiString): PRegistrySymbol; inline;
begin
  Result := MapGet(Registry, AName);
end;

function RegistryStage(const AName: AnsiString; AKind: Byte): PRegistrySymbol;
var
  Symbol: PRegistrySymbol;
begin
  Symbol := RegistryGet(AName);
  if Symbol = nil then
  begin
    New(Symbol);
    FillChar(Symbol^, SizeOf(TRegistrySymbol), 0);
    Symbol^.Name := AName;
    Symbol^.Kind := AKind;
    MapPut(Registry, Symbol^.Name, Symbol);
  end;
  if not Symbol^.Pending then
  begin
    Symbol^.Pending := True;
    Symbol^.PendingCanonicalAddress := Symbol^.CanonicalAddress;
    Symbol^.PendingCurrentAddress := Symbol^.CurrentAddress;
    if PendingCount = Length(PendingSymbols) then SetLength(PendingSymbols, ListGrowthLarge + 2 * Length(PendingSymbols));
    PendingSymbols[PendingCount] := Symbol;
    Inc(PendingCount);
  end;
  Result := Symbol;
end;

// The address a name has in the process before this transaction: 0 when it has none.
function ExistingAddressOf(const AName: AnsiString; out AKind: Byte): QWord;
var
  Registered: PRegistrySymbol;
  HostSymbol: PHostSymbol;
begin
  AKind := 0;
  Registered := RegistryGet(AName);
  if (Registered <> nil) and (Registered^.CanonicalAddress <> 0) then
  begin
    AKind := Registered^.Kind;
    Exit(Registered^.CanonicalAddress);
  end;
  HostSymbol := MapGet(HostSymbols, AName);
  if HostSymbol <> nil then
  begin
    if HostSymbol^.IsTLS then AKind := KindTLS else if HostSymbol^.IsCode then AKind := KindCode else AKind := KindData;
    Exit(HostSymbol^.Address);
  end;
  Result := 0;
end;

function PlacedAddress(AObjectFile: PObjectFile; ASymbol: PObjectSymbol): QWord; inline;
begin
  Result := QWord(PtrUInt(AObjectFile^.Sections[ASymbol^.Section].Base)) + ASymbol^.Value;
end;

function KindName(AKind: Byte): AnsiString; inline;
begin
  if AKind = KindCode then Result := 'code' else Result := 'data';
end;

function PlaceSections(AObjectFile: PObjectFile): Boolean;
var
  I: SizeInt;
  Section: PSection;
  Alignment: QWord;
begin
  for I := 0 to High(AObjectFile^.Sections) do
  begin
    Section := @AObjectFile^.Sections[I];
    if (Section^.Kind in [0, KindTLS]) or (Section^.Size = 0) then Continue;
    Alignment := Section^.Alignment;
    if Alignment > MaxSectionAlignment then Alignment := MaxSectionAlignment;
    if Alignment < MinSectionAlignment then Alignment := MinSectionAlignment;
    if Section^.Kind = KindCode then
    begin
      if Alignment < CodeAlignment then Alignment := CodeAlignment;
      Section^.Base := Bump(JITNext, JITRegion + JITSize, Section^.Size, Alignment);
    end
    else Section^.Base := Bump(DataNext, DataRegion + DataAreaSize, Section^.Size, Alignment);
    if Section^.Base = nil then
    begin
      Restart('no room left for new code or data');
      Exit(False);
    end;
  end;
  Result := True;
end;

procedure CopySections(AObjectFile: PObjectFile);
var
  I: SizeInt;
  Section: PSection;
begin
  for I := 0 to High(AObjectFile^.Sections) do
  begin
    Section := @AObjectFile^.Sections[I];
    if (Section^.Kind in [0, KindTLS]) or (Section^.Size = 0) then Continue;
    if Section^.ZeroFill then FillChar(Section^.Base^, Section^.Size, 0)
    else Move(Section^.Data^, Section^.Base^, Section^.Size);
  end;
end;

type
  TCounts = record Functions, Changed, Added, Kept, NewData, Notes: LongInt; end;

// Decide, for every named symbol the object defines, which address it has from now on.
procedure BindSymbols(AObjectFile: PObjectFile; var ACounts: TCounts);
var
  Previous: PObjectFile;
  I: SizeInt;
  Symbol, PreviousSymbol: PObjectSymbol;
  NewAddress, ExistingAddress: QWord;
  ExistingKind: Byte;
  Registered: PRegistrySymbol;
  Anonymous, Same: Boolean;
  Name: AnsiString;
  NewBytes, OldBytes: PByte;
  NewInstanceSize, OldInstanceSize: Int64;
  Removed: LongInt;
  HostSymbol: PHostSymbol;
begin
  Previous := AObjectFile^.Previous;
  for I := 0 to High(AObjectFile^.Symbols) do
  begin
    Symbol := @AObjectFile^.Symbols[I];
    if not Symbol^.Defined or (Symbol^.Kind = 0) then Continue;
    NewAddress := PlacedAddress(AObjectFile, Symbol);
    if not Symbol^.External then
    begin
      Symbol^.ResolvedAddress := NewAddress;
      Symbol^.CallAddress := NewAddress;
      Symbol^.Resolved := True;
      Continue;
    end;
    PreviousSymbol := nil;
    if Previous <> nil then PreviousSymbol := MapGet(Previous^.ByName, Symbol^.Name);
    if Symbol^.Kind = KindTLS then
    begin
      // The system lays out every thread's copy when the thread starts: a thread variable
      // keeps its offset, and a new one cannot be given room.
      HostSymbol := MapGet(HostSymbols, Symbol^.Name);
      if (HostSymbol = nil) or not HostSymbol^.IsTLS then Restart('unit ' + AObjectFile^.UnitName + ' gained the thread variable ' + Pretty(Symbol^.Name))
      else if (PreviousSymbol <> nil) and (PreviousSymbol^.Size <> Symbol^.Size) then Restart('the thread variable ' + Pretty(Symbol^.Name) + ' changed size from ' + UnsignedToString(PreviousSymbol^.Size) + ' to ' + UnsignedToString(Symbol^.Size) + ' bytes')
      else
      begin
        Symbol^.ResolvedAddress := HostSymbol^.Address;
        Symbol^.CallAddress := HostSymbol^.Address;
        Symbol^.IsTLS := True;
        Symbol^.Resolved := True;
        Symbol^.BoundToExisting := True;
        Inc(ACounts.Kept);
      end;
      Continue;
    end;
    ExistingAddress := ExistingAddressOf(Symbol^.Name, ExistingKind);
    if (ExistingAddress <> 0) and (ExistingKind <> Symbol^.Kind) then
    begin
      Restart(Pretty(Symbol^.Name) + ' was ' + KindName(ExistingKind) + ' and is now ' + KindName(Symbol^.Kind));
      Continue;
    end;
    if Symbol^.Kind = KindCode then
    begin
      if Symbol^.Size = 0 then
      begin
        if ExistingAddress <> 0 then Symbol^.ResolvedAddress := ExistingAddress else Symbol^.ResolvedAddress := NewAddress;
        Symbol^.CallAddress := Symbol^.ResolvedAddress;
        Symbol^.Resolved := True;
        Continue;
      end;
      Registered := RegistryStage(Symbol^.Name, KindCode);
      Symbol^.BoundToExisting := ExistingAddress <> 0;   // the program has it: it will be redirected
      if ExistingAddress <> 0 then
      begin
        if Registered^.PendingCanonicalAddress = 0 then
        begin
          Registered^.PendingCanonicalAddress := ExistingAddress;
          Registered^.PendingCurrentAddress := ExistingAddress;
        end;
      end
      else Registered^.PendingCanonicalAddress := NewAddress;
      Registered^.PendingCurrentAddress := NewAddress;
      Symbol^.ResolvedAddress := Registered^.PendingCanonicalAddress;
      Symbol^.CallAddress := NewAddress;
      Symbol^.Resolved := True;
      Inc(ACounts.Functions);
      if PreviousSymbol = nil then
      begin
        if Previous <> nil then Inc(ACounts.Added);
      end
      else if SymbolDigest(AObjectFile, Symbol, 0) <> SymbolDigest(Previous, PreviousSymbol, 0) then
      begin
        Inc(ACounts.Changed);
        if StartsWith(Symbol^.Name, PrefixUnitInit) then
        begin
          Say('note the initialization section of ' + AObjectFile^.UnitName + ' changed; it is not run again');
          Inc(ACounts.Notes);
        end;
        if (Symbol^.Name = MainBlockName) or (Symbol^.Name = MainSymbolName) then
        begin
          Say('note the main block changed; the frame that is running keeps its old code');
          Inc(ACounts.Notes);
        end;
      end;
      Continue;
    end;
    // data
    Anonymous := IsAnonymous(Symbol^.Name) or IsUnwindSection(AObjectFile^.Sections[Symbol^.Section].Name);
    if (ExistingAddress = 0) or Anonymous then
    begin
      Registered := RegistryStage(Symbol^.Name, KindData);
      Registered^.PendingCanonicalAddress := NewAddress;
      Registered^.PendingCurrentAddress := NewAddress;
      Symbol^.ResolvedAddress := NewAddress;
      Symbol^.CallAddress := NewAddress;
      Symbol^.Resolved := True;
      Inc(ACounts.NewData);
      if not Anonymous and StartsWith(Symbol^.Name, PrefixThreadVarList) then Restart('unit ' + AObjectFile^.UnitName + ' gained its first thread variable');
      Continue;
    end;
    Symbol^.BoundToExisting := True;
    Symbol^.ResolvedAddress := ExistingAddress;
    Symbol^.CallAddress := ExistingAddress;
    Symbol^.Resolved := True;
    Inc(ACounts.Kept);
    if PreviousSymbol = nil then
    begin
      Say('note ' + Pretty(Symbol^.Name) + ' exists in the program but not in the version of ' + AObjectFile^.UnitName + ' the agent knows; kept without a check');
      Inc(ACounts.Notes);
      Continue;
    end;
    Name := Symbol^.Name;
    if StartsWith(Name, PrefixVMT) and not Contains(Name, IndirectSuffix) then
    begin
      NewBytes := SymbolBytes(AObjectFile, Symbol);
      OldBytes := SymbolBytes(Previous, PreviousSymbol);
      NewInstanceSize := 0;
      OldInstanceSize := 0;
      if NewBytes <> nil then NewInstanceSize := PInt64(NewBytes)^;
      if OldBytes <> nil then OldInstanceSize := PInt64(OldBytes)^;
      if NewInstanceSize <> OldInstanceSize then
      begin
        Restart('class ' + Pretty(Name) + ': instance size changed from ' + SignedToString(OldInstanceSize) + ' to ' + SignedToString(NewInstanceSize) + ' bytes');
        Continue;
      end;
      if Symbol^.Size <> PreviousSymbol^.Size then
      begin
        Restart('class ' + Pretty(Name) + ': the virtual method table changed from ' + UnsignedToString(PreviousSymbol^.Size div VMTSlotSize) + ' to ' + UnsignedToString(Symbol^.Size div VMTSlotSize) + ' slots');
        Continue;
      end;
      if RelocationTargetAt(AObjectFile, Symbol, VMTParentOffset) <> RelocationTargetAt(Previous, PreviousSymbol, VMTParentOffset) then
      begin
        Restart('class ' + Pretty(Name) + ': the parent class changed');
        Continue;
      end;
      if VMTUpdateCount = Length(VMTUpdates) then SetLength(VMTUpdates, ListGrowthSmall + 2 * Length(VMTUpdates));
      VMTUpdates[VMTUpdateCount].ObjectFile := AObjectFile;
      VMTUpdates[VMTUpdateCount].Symbol := Symbol;
      VMTUpdates[VMTUpdateCount].OldAddress := ExistingAddress;
      Inc(VMTUpdateCount);
      Continue;
    end;
    if Symbol^.Size <> PreviousSymbol^.Size then
    begin
      if StartsWith(Name, PrefixVariable) or StartsWith(Name, PrefixTypedConstant) then
        Restart('variable ' + Pretty(Name) + ' changed size from ' + UnsignedToString(PreviousSymbol^.Size) + ' to ' + UnsignedToString(Symbol^.Size) + ' bytes')
      else if StartsWith(Name, PrefixThreadVarList) then Restart('the thread variables of unit ' + AObjectFile^.UnitName + ' changed')
      else Restart(Pretty(Name) + ' changed size from ' + UnsignedToString(PreviousSymbol^.Size) + ' to ' + UnsignedToString(Symbol^.Size) + ' bytes');
      Continue;
    end;
    if Contains(Name, IndirectSuffix) then Continue;
    Same := SymbolDigest(AObjectFile, Symbol, 0) = SymbolDigest(Previous, PreviousSymbol, 0);
    if Same then Continue;
    if StartsWith(Name, PrefixInitTable) or StartsWith(Name, PrefixRTTI) then
    begin
      Restart('type ' + Pretty(Name) + ': its layout or type information changed');
      Continue;
    end;
    if StartsWith(Name, PrefixThreadVarList) then
    begin
      Restart('the thread variables of unit ' + AObjectFile^.UnitName + ' changed');
      Continue;
    end;
    if StartsWith(Name, PrefixTypedConstant) then
    begin
      // An initialised variable or typed constant whose initial value was edited. If the
      // running value is still the old initial value, nothing has written it: take the new one.
      NewBytes := SymbolBytes(AObjectFile, Symbol);
      OldBytes := SymbolBytes(Previous, PreviousSymbol);
      if (NewBytes <> nil) and (OldBytes <> nil) and not HasRelocations(AObjectFile, Symbol) and not HasRelocations(Previous, PreviousSymbol) and (CompareByte(PByte(PtrUInt(ExistingAddress))^, OldBytes^, Symbol^.Size) = 0) then
      begin
        if DataCopyCount = Length(DataCopies) then SetLength(DataCopies, ListGrowthSmall + 2 * Length(DataCopies));
        DataCopies[DataCopyCount].Destination := ExistingAddress;
        DataCopies[DataCopyCount].Source := NewBytes;
        DataCopies[DataCopyCount].Size := Symbol^.Size;
        Inc(DataCopyCount);
        Say('note ' + Pretty(Name) + ' still had its initial value; set to the new one');
      end
      else Say('note the initial value of ' + Pretty(Name) + ' changed; the running value is kept');
      Inc(ACounts.Notes);
      Continue;
    end;
    if StartsWith(Name, PrefixResourceString) then
    begin
      Say('note resource string ' + Pretty(Name) + ' changed; the running text is kept');
      Inc(ACounts.Notes);
      Continue;
    end;
    Say('note ' + Pretty(Name) + ' changed; the running copy is kept');
    Inc(ACounts.Notes);
  end;
  if Previous <> nil then
  begin
    Removed := 0;
    for I := 0 to High(Previous^.Symbols) do
    begin
      PreviousSymbol := @Previous^.Symbols[I];
      if PreviousSymbol^.Defined and PreviousSymbol^.External and (PreviousSymbol^.Kind = KindCode) and (PreviousSymbol^.Size <> 0) and (MapGet(AObjectFile^.ByName, PreviousSymbol^.Name) = nil) then
      begin
        if Removed < 4 then Say('note ' + Pretty(PreviousSymbol^.Name) + ' is gone from the source; its old code stays for callers that were not recompiled');
        Inc(Removed);
      end;
    end;
    if Removed > 4 then Say('note ... and ' + SignedToString(Removed - 4) + ' more functions gone from the source');
    if Removed > 0 then Inc(ACounts.Notes);
  end;
end;

// What a load needs: the sections of what the program already has (functions to redirect,
// variables and tables it keeps), and what their relocations reach, as a linker would,
// across all the objects of the load. The rest, such as type information no code uses, is
// never read; a linker that drops unused sections (Windows) may have dropped what it refers
// to. Unwind tables are live when the code they describe is.
procedure MarkLive(const AObjectFiles: array of PObjectFile);
var
  I, K, ObjectIndex: SizeInt;
  Changed, Reached: Boolean;
  ObjectFile, TargetObject: PObjectFile;
  Section: PSection;
  TargetIndex: LongInt;

  // The section a relocation reaches, in this object or in another one of the load.
  function TargetSection(AObjectFile: PObjectFile; const ARelocation: TRelocation; out ATargetObject: PObjectFile): LongInt;
  var
    J: SizeInt;
    Definition: PObjectSymbol;
  begin
    Result := -1;
    ATargetObject := AObjectFile;
    if ARelocation.Symbol < 0 then
    begin
      Result := ARelocation.Section;
      if Result > High(AObjectFile^.Sections) then Result := -1;
      Exit;
    end;
    if AObjectFile^.Symbols[ARelocation.Symbol].Defined then
    begin
      Result := AObjectFile^.Symbols[ARelocation.Symbol].Section;
      Exit;
    end;
    for J := 0 to High(AObjectFiles) do
      if AObjectFiles[J] <> AObjectFile then
      begin
        Definition := MapGet(AObjectFiles[J]^.ByName, AObjectFile^.Symbols[ARelocation.Symbol].Name);
        if (Definition <> nil) and Definition^.Defined then
        begin
          ATargetObject := AObjectFiles[J];
          Exit(Definition^.Section);
        end;
      end;
  end;

begin
  for ObjectIndex := 0 to High(AObjectFiles) do
  begin
    ObjectFile := AObjectFiles[ObjectIndex];
    for I := 0 to High(ObjectFile^.Sections) do ObjectFile^.Sections[I].Live := False;
    for I := 0 to High(ObjectFile^.Symbols) do
      if ObjectFile^.Symbols[I].Defined and ObjectFile^.Symbols[I].BoundToExisting and (ObjectFile^.Symbols[I].Section >= 0) then ObjectFile^.Sections[ObjectFile^.Symbols[I].Section].Live := True;
  end;
  repeat
    Changed := False;
    for ObjectIndex := 0 to High(AObjectFiles) do
    begin
      ObjectFile := AObjectFiles[ObjectIndex];
      for I := 0 to High(ObjectFile^.Sections) do
      begin
        Section := @ObjectFile^.Sections[I];
        if Section^.Kind in [0, KindTLS] then Continue;
        if Section^.Live then
        begin
          for K := 0 to High(Section^.Relocations) do
          begin
            TargetIndex := TargetSection(ObjectFile, Section^.Relocations[K], TargetObject);
            if (TargetIndex >= 0) and not TargetObject^.Sections[TargetIndex].Live then
            begin
              TargetObject^.Sections[TargetIndex].Live := True;
              Changed := True;
            end;
          end;
        end
        else if IsUnwindSection(Section^.Name) then
        begin
          Reached := False;
          for K := 0 to High(Section^.Relocations) do
          begin
            TargetIndex := TargetSection(ObjectFile, Section^.Relocations[K], TargetObject);
            if (TargetIndex >= 0) and (TargetObject = ObjectFile) and ObjectFile^.Sections[TargetIndex].Live and (ObjectFile^.Sections[TargetIndex].Kind = KindCode) then Reached := True;
          end;
          if Reached then
          begin
            Section^.Live := True;
            Changed := True;
          end;
        end;
      end;
    end;
  until not Changed;
end;

// What is not live is placed but never relocated: it must not become a name the program
// has, or a later load would bind to code that was never made runnable. Names this load
// would have created for it are taken back.
procedure Unregister(AObjectFile: PObjectFile);
var
  I: SizeInt;
  Registered: PRegistrySymbol;
begin
  for I := 0 to High(AObjectFile^.Symbols) do
    if AObjectFile^.Symbols[I].Defined and AObjectFile^.Symbols[I].External and (AObjectFile^.Symbols[I].Section >= 0) and not AObjectFile^.Sections[AObjectFile^.Symbols[I].Section].Live then
    begin
      Registered := RegistryGet(AObjectFile^.Symbols[I].Name);
      if (Registered <> nil) and Registered^.Pending and (Registered^.CanonicalAddress = 0) then
      begin
        Registered^.PendingCanonicalAddress := 0;
        Registered^.PendingCurrentAddress := 0;
      end;
    end;
end;

procedure ResolveUndefined(AObjectFile: PObjectFile);
var
  I, K: SizeInt;
  Symbol: PObjectSymbol;
  Registered: PRegistrySymbol;
  HostSymbol: PHostSymbol;
  Found: Pointer;
  Slot: PQWord;
  ExistingAddress: QWord;
  ExistingKind: Byte;
begin
  for I := 0 to High(AObjectFile^.Symbols) do
  begin
    Symbol := @AObjectFile^.Symbols[I];
    if Symbol^.Resolved or Symbol^.Defined or (Symbol^.Name = '') then Continue;
    Registered := RegistryGet(Symbol^.Name);
    if (Registered <> nil) and (((Registered^.Pending) and (Registered^.PendingCanonicalAddress <> 0)) or ((not Registered^.Pending) and (Registered^.CanonicalAddress <> 0))) then
    begin
      if Registered^.Pending then Symbol^.ResolvedAddress := Registered^.PendingCanonicalAddress else Symbol^.ResolvedAddress := Registered^.CanonicalAddress;
      if Registered^.Kind = KindCode then
      begin
        if Registered^.Pending then Symbol^.CallAddress := Registered^.PendingCurrentAddress else Symbol^.CallAddress := Registered^.CurrentAddress;
      end
      else Symbol^.CallAddress := Symbol^.ResolvedAddress;
      Symbol^.Resolved := True;
      Continue;
    end;
    HostSymbol := MapGet(HostSymbols, Symbol^.Name);
    if HostSymbol <> nil then
    begin
      Symbol^.ResolvedAddress := HostSymbol^.Address;
      Symbol^.CallAddress := HostSymbol^.Address;
      Symbol^.IsTLS := HostSymbol^.IsTLS;
      Symbol^.Resolved := True;
      Continue;
    end;
    // X$indirect is only a pointer to X, and a linker that leaves out what the program
    // does not use (Windows) keeps it only when old code needed it: make one.
    if EndsWith(Symbol^.Name, IndirectSuffix) then
    begin
      Slot := MapGet(Indirects, Symbol^.Name);
      if Slot = nil then
      begin
        ExistingAddress := ExistingAddressOf(Copy(Symbol^.Name, 1, Length(Symbol^.Name) - IndirectSuffixLength), ExistingKind);
        if ExistingAddress <> 0 then
        begin
          Slot := NewSlot(ExistingAddress);
          if Slot <> nil then MapPut(Indirects, Symbol^.Name, Slot);
        end;
      end;
      if Slot <> nil then
      begin
        Symbol^.ResolvedAddress := QWord(PtrUInt(Slot));
        Symbol^.CallAddress := Symbol^.ResolvedAddress;
        Symbol^.Resolved := True;
        Continue;
      end;
    end;
{$ifdef unix}
    Found := LibCDLSym(RTLD_DEFAULT, PChar(Symbol^.Name));
    if Found <> nil then
    begin
      Symbol^.ResolvedAddress := QWord(PtrUInt(Found));
      Symbol^.CallAddress := Symbol^.ResolvedAddress;
      Symbol^.Resolved := True;
    end;
{$else}
    Found := nil;
    if Found <> nil then;
{$endif}
  end;
  // Only symbols that a relocation uses must exist.
  for I := 0 to High(AObjectFile^.Sections) do
  begin
    if (AObjectFile^.Sections[I].Kind in [0, KindTLS]) or not AObjectFile^.Sections[I].Live then Continue;
    for K := 0 to High(AObjectFile^.Sections[I].Relocations) do
    begin
      if AObjectFile^.Sections[I].Relocations[K].Symbol < 0 then Continue;
      Symbol := @AObjectFile^.Symbols[AObjectFile^.Sections[I].Relocations[K].Symbol];
      if not Symbol^.Resolved then
      begin
        Restart(AObjectFile^.UnitName + ' uses ' + Pretty(Symbol^.Name) + ', which the running program does not contain');
        Symbol^.Resolved := True;
      end;
    end;
  end;
end;

function Veneer(ATarget: QWord): QWord;
var
  Key: AnsiString;
  Existing: Pointer;
  Slot: PQWord;
begin
  Key := HexStr(ATarget, QWordHexDigits);
  Existing := MapGet(Veneers, Key);
  if Existing <> nil then Exit(QWord(PtrUInt(Existing)));
  Slot := NewSlot(ATarget);
  Result := 0;
  if Slot <> nil then Result := MakeVeneer(Slot);
  if Result <> 0 then MapPut(Veneers, Key, Pointer(PtrUInt(Result)));
end;

function GOTFor(ASymbol: PObjectSymbol; AAddress: QWord): PQWord;
begin
  if ASymbol^.GOTEntry = nil then
  begin
    ASymbol^.GOTEntry := PQWord(Bump(DataNext, DataRegion + DataAreaSize, SizeOf(QWord), SizeOf(QWord)));
    if ASymbol^.GOTEntry <> nil then ASymbol^.GOTEntry^ := AAddress;
  end;
  Result := ASymbol^.GOTEntry;
end;

function Relocate(AObjectFile: PObjectFile): Boolean;
var
  SectionIndex, I: SizeInt;
  Section, TargetSection: PSection;
  Relocation: ^TRelocation;
  Place: PByte;
  PlaceAddress, SymbolAddress, CallAddress, Target, Subtrahend: QWord;
  Symbol: PObjectSymbol;
  Distance, PageDistance: Int64;
  Instruction, Offset, Shift: LongWord;
  GOTEntry: PQWord;
  Description: AnsiString;
  CoveringIndex: LongInt;
  CoveringSymbol: PObjectSymbol;
begin
  Result := False;
  for SectionIndex := 0 to High(AObjectFile^.Sections) do
  begin
    Section := @AObjectFile^.Sections[SectionIndex];
    if (Section^.Kind in [0, KindTLS]) or Section^.ZeroFill or not Section^.Live then Continue;
    for I := 0 to High(Section^.Relocations) do
    begin
      Relocation := @Section^.Relocations[I];
      Place := Section^.Base + Relocation^.Offset;
      PlaceAddress := QWord(PtrUInt(Place));
      Symbol := nil;
      if Relocation^.Symbol >= 0 then
      begin
        Symbol := @AObjectFile^.Symbols[Relocation^.Symbol];
        SymbolAddress := Symbol^.ResolvedAddress;
        CallAddress := Symbol^.CallAddress;
        Description := Pretty(Symbol^.Name);
      end
      else
      begin
        if (Relocation^.Section < 0) or (Relocation^.Section > High(AObjectFile^.Sections)) or (AObjectFile^.Sections[Relocation^.Section].Base = nil) then
        begin
          Say('error ' + AObjectFile^.UnitName + ': a relocation refers to a section that is not loaded');
          Exit;
        end;
        TargetSection := @AObjectFile^.Sections[Relocation^.Section];
        SymbolAddress := QWord(PtrUInt(TargetSection^.Base));
        CallAddress := SymbolAddress;
        Description := TargetSection^.Name;
        // Where the format gives the target's exact offset, refer through the symbol that
        // covers it: a variable of this unit that the program already has keeps its address
        // even when code reaches it as section + offset, which COFF does for everything in
        // the same object. A function's start as a value is its first address, as for a
        // named reference; a branch, unwind data and places inside a function mean the new code.
        if Relocation^.HasTargetOffset then
        begin
          CoveringIndex := CoveringForRelocation(AObjectFile, Relocation^, Relocation^.TargetOffset);
          if (CoveringIndex >= 0) and AObjectFile^.Symbols[CoveringIndex].Resolved then
          begin
            CoveringSymbol := @AObjectFile^.Symbols[CoveringIndex];
            if (CoveringSymbol^.Kind = KindData) or ((CoveringSymbol^.Kind = KindCode) and (Relocation^.TargetOffset = Int64(CoveringSymbol^.Value))
              and not (Relocation^.Kind in [rkBranch32, rkBranch26]) and not IsUnwindSection(Section^.Name)) then
              SymbolAddress := CoveringSymbol^.ResolvedAddress - CoveringSymbol^.Value;
            CallAddress := SymbolAddress;
            Description := Pretty(CoveringSymbol^.Name);
          end;
        end;
      end;
      case Relocation^.Kind of
        rkAbsolute64: PQWord(Place)^ := SymbolAddress + QWord(Relocation^.Addend);
        rkAbsolute32:
          begin
{$ifdef cpux86_64}
            if SymbolAddress + QWord(Relocation^.Addend) > MaxLongWordValue then
            begin
              Say('error ' + AObjectFile^.UnitName + ': ' + Description + ' is above 4 GiB, out of reach of a 32-bit address');
              Exit;
            end;
{$endif}
            PLongWord(Place)^ := LongWord(SymbolAddress + QWord(Relocation^.Addend));
          end;
        rkSubtract64, rkSubtract32:
          begin
            Subtrahend := AObjectFile^.Symbols[Relocation^.SecondarySymbol].ResolvedAddress;
            if Relocation^.Kind = rkSubtract64 then PQWord(Place)^ := Subtrahend - SymbolAddress + QWord(Relocation^.Addend)
            else PLongWord(Place)^ := LongWord(Subtrahend - SymbolAddress + QWord(Relocation^.Addend));
          end;
        rkPCRelative32:
          begin
            Distance := Int64(SymbolAddress + QWord(Relocation^.Addend) - PlaceAddress);
            if (Distance >= Rel32Reach) or (Distance < -Rel32Reach) then
            begin
              Say('error ' + AObjectFile^.UnitName + ': ' + Description + ' is out of reach of a 32-bit offset');
              Exit;
            end;
            PLongInt(Place)^ := LongInt(Distance);
          end;
        rkAbsolute32Signed:
          begin
            Distance := Int64(SymbolAddress + QWord(Relocation^.Addend));
            if (Distance >= Rel32Reach) or (Distance < -Rel32Reach) then
            begin
              Say('error ' + AObjectFile^.UnitName + ': ' + Description + ' is above 2 GiB, out of reach of a 32-bit address');
              Exit;
            end;
            PLongInt(Place)^ := LongInt(Distance);
          end;
        rkBranch32:
          begin
            // field = target - end of the instruction; the addend is -4 for a plain call
            Target := CallAddress + QWord(Relocation^.Addend);
            Distance := Int64(Target - PlaceAddress);
            if (Distance >= Rel32Reach) or (Distance < -Rel32Reach) then
            begin
              if Relocation^.Addend <> -4 then
              begin
                Say('error ' + AObjectFile^.UnitName + ': a branch into the middle of ' + Description + ' is out of reach');
                Exit;
              end;
              Target := Veneer(CallAddress);
              if Target = 0 then
              begin
                Restart('no room left for call islands');
                Exit;
              end;
              Distance := Int64(Target - 4 - PlaceAddress);
            end;
            PLongInt(Place)^ := LongInt(Distance);
          end;
        rkPCRelative64: PQWord(Place)^ := SymbolAddress + QWord(Relocation^.Addend) - PlaceAddress;
        rkBranch26:
          begin
            Target := CallAddress + QWord(Relocation^.Addend);
            Distance := Int64(Target - PlaceAddress);
            if (Distance >= Branch26Reach) or (Distance < -Branch26Reach) then
            begin
              Target := Veneer(Target);
              if Target = 0 then
              begin
                Restart('no room left for call islands');
                Exit;
              end;
              Distance := Int64(Target - PlaceAddress);
            end;
            Instruction := PLongWord(Place)^;
            PLongWord(Place)^ := (Instruction and ARM64OpcodeMask) or (LongWord(SarInt64(Distance, 2)) and ARM64Imm26Mask);
          end;
        rkPage21, rkGOTPage21:
          begin
            Target := SymbolAddress + QWord(Relocation^.Addend);
            if Relocation^.Kind = rkGOTPage21 then
            begin
              if Symbol = nil then begin Say('error ' + AObjectFile^.UnitName + ': a GOT relocation without a symbol'); Exit; end;
              GOTEntry := GOTFor(Symbol, SymbolAddress);
              if GOTEntry = nil then begin Restart('no room left for data'); Exit; end;
              Target := QWord(PtrUInt(GOTEntry)) + QWord(Relocation^.Addend);
            end;
            PageDistance := SarInt64(Int64(Target and not QWord(ARM64Imm12Mask)) - Int64(PlaceAddress and not QWord(ARM64Imm12Mask)), ARM64Imm12Bits);
            if (PageDistance >= Page21Reach) or (PageDistance < -Page21Reach) then
            begin
              Say('error ' + AObjectFile^.UnitName + ': ' + Description + ' is out of reach of adrp');
              Exit;
            end;
            Instruction := PLongWord(Place)^;
            PLongWord(Place)^ := (Instruction and ARM64AdrpKeepMask) or (LongWord(PageDistance and 3) shl 29) or (LongWord((PageDistance shr 2) and ARM64ImmHiMask) shl 5);
          end;
        rkPageOffset12, rkGOTPageOffset12:
          begin
            Target := SymbolAddress + QWord(Relocation^.Addend);
            if Relocation^.Kind = rkGOTPageOffset12 then
            begin
              if Symbol = nil then begin Say('error ' + AObjectFile^.UnitName + ': a GOT relocation without a symbol'); Exit; end;
              GOTEntry := GOTFor(Symbol, SymbolAddress);
              if GOTEntry = nil then begin Restart('no room left for data'); Exit; end;
              Target := QWord(PtrUInt(GOTEntry)) + QWord(Relocation^.Addend);
            end;
            Instruction := PLongWord(Place)^;
            Offset := LongWord(Target and ARM64Imm12Mask);
            Shift := 0;
            if (Instruction and ARM64LoadStoreMask) = ARM64LoadStoreImmediate then   // load or store: the offset is scaled
            begin
              Shift := Instruction shr 30;
              if (Shift = 0) and ((Instruction and ARM64VectorLoadStore) = ARM64VectorLoadStore) then Shift := 4;
              if (Offset and ((LongWord(1) shl Shift) - 1)) <> 0 then
              begin
                Say('error ' + AObjectFile^.UnitName + ': misaligned load of ' + Description);
                Exit;
              end;
            end;
            PLongWord(Place)^ := (Instruction and ARM64Imm12KeepMask) or ((Offset shr Shift) shl 10);
          end;
        rkGOTPCRelative32, rkGOTAbsolute64:
          begin
            if Symbol = nil then begin Say('error ' + AObjectFile^.UnitName + ': a GOT relocation without a symbol'); Exit; end;
            GOTEntry := GOTFor(Symbol, SymbolAddress);
            if GOTEntry = nil then begin Restart('no room left for data'); Exit; end;
            if Relocation^.Kind = rkGOTPCRelative32 then PLongInt(Place)^ := LongInt(Int64(QWord(PtrUInt(GOTEntry)) + QWord(Relocation^.Addend) - PlaceAddress))
            else PQWord(Place)^ := QWord(PtrUInt(GOTEntry));
          end;
{$ifdef windows}
        rkRVA32:
          begin
            Distance := Int64(SymbolAddress + QWord(Relocation^.Addend) - ImageBase);
            if (Distance < 0) or (Distance > MaxLongWordValue) then
            begin
              Say('error ' + AObjectFile^.UnitName + ': ' + Description + ' is out of reach of a 32-bit offset from the image base');
              Exit;
            end;
            PLongWord(Place)^ := LongWord(Distance);
          end;
{$endif}
        rkTPOffset32, rkTPOffset64, rkTPRelativeHigh12, rkTPRelativeLow12:
          begin
            if (Symbol = nil) or not Symbol^.IsTLS then
            begin
              Say('error ' + AObjectFile^.UnitName + ': a thread-variable relocation to ' + Description + ', which is not a thread variable of the program');
              Exit;
            end;
{$ifdef cpux86_64}
            // variant II: the thread pointer is at the end of the executable's TLS block
            Distance := Int64(SymbolAddress) + Relocation^.Addend - Int64((TLSMemorySize + TLSAlignment - 1) and not (TLSAlignment - 1));
{$else}
            // variant I: the block follows a 16-byte thread control block
            Distance := Int64((ARM64ThreadControlBlockSize + TLSAlignment - 1) and not (TLSAlignment - 1)) + Int64(SymbolAddress) + Relocation^.Addend;
{$endif}
            case Relocation^.Kind of
              rkTPOffset32:
                begin
                  if (Distance >= Rel32Reach) or (Distance < -Rel32Reach) then begin Say('error ' + AObjectFile^.UnitName + ': thread variable ' + Description + ' out of reach'); Exit; end;
                  PLongInt(Place)^ := LongInt(Distance);
                end;
              rkTPOffset64: PInt64(Place)^ := Distance;
              rkTPRelativeHigh12:
                begin
                  if (Distance < 0) or (Distance >= TPRelHi12Reach) then begin Say('error ' + AObjectFile^.UnitName + ': thread variable ' + Description + ' out of reach'); Exit; end;
                  Instruction := PLongWord(Place)^;
                  PLongWord(Place)^ := (Instruction and ARM64Imm12KeepMask) or (LongWord((Distance shr ARM64Imm12Bits) and ARM64Imm12Mask) shl 10);
                end;
              rkTPRelativeLow12:
                begin
                  Instruction := PLongWord(Place)^;
                  PLongWord(Place)^ := (Instruction and ARM64Imm12KeepMask) or (LongWord(Distance and ARM64Imm12Mask) shl 10);
                end;
            else
            end;
          end;
      else
        Say('error ' + AObjectFile^.UnitName + ': unsupported relocation type ' + SignedToString(Relocation^.SecondarySymbol) + ' (thread-local variables of the system are not handled)');
        Exit;
      end;
    end;
  end;
  Result := True;
end;

// ================================================================ the system: rewriting the program's code
procedure SortPatches;
var
  I, J: SizeInt;
  Temporary: TPatch;
begin
  for I := 1 to PatchCount - 1 do
  begin
    Temporary := Patches[I];
    J := I - 1;
    while (J >= 0) and (Patches[J].Address > Temporary.Address) do
    begin
      Patches[J + 1] := Patches[J];
      Dec(J);
    end;
    Patches[J + 1] := Temporary;
  end;
end;

var
  PatchError: AnsiString;   // set while other threads are stopped (a constant: no allocation), reported after
  StopFailure: AnsiString;  // set by WorldStop when not every other thread stopped (a constant), '' otherwise
  PatchKernelResult: LongInt;

// Overwrite one instruction each at a set of addresses, with the other threads stopped
// and without allocating.
{$if defined(darwin)}
// Pages of the program's __TEXT are replaced atomically: copy the page elsewhere, write the
// copy, map it back over the original. The copy with VM_PROT_COPY is what code signing allows.
function ApplyPatches: Boolean;
var
  Task: TMachPort;
  Index, First: SizeInt;
  Address, Page, PageCopy, Destination: QWord;
  CurrentProtection, MaximumProtection: LongInt;
  KernelResult: TKernelReturn;
begin
  Result := True;
  if PatchCount = 0 then Exit;
  Task := mach_task_self_;
  Index := 0;
  while Index < PatchCount do
  begin
    Address := Patches[Index].Address;
    if InJIT(Address) then
    begin
      Move(Patches[Index].Bytes[0], PByte(PtrUInt(Address))^, Patches[Index].ByteCount);
      ClearCache(Pointer(PtrUInt(Address)), Patches[Index].ByteCount);
      Inc(Index);
      Inc(PatchedCount);
      Continue;
    end;
    Page := Address and not (PageSize - 1);
    First := Index;
    PageCopy := 0;
    KernelResult := MachVMRemap(Task, PageCopy, PageSize, 0, VM_FLAGS_ANYWHERE, Task, Page, 1, CurrentProtection, MaximumProtection, VM_INHERIT_NONE);
    if KernelResult = 0 then KernelResult := MachVMProtect(Task, PageCopy, PageSize, 0, VM_PROT_READ or VM_PROT_WRITE or VM_PROT_COPY);
    if KernelResult <> 0 then
    begin
      PatchKernelResult := KernelResult;
      PatchError := 'cannot copy a code page of the program';
      Exit(False);
    end;
    while (Index < PatchCount) and ((Patches[Index].Address and not (PageSize - 1)) = Page) do
    begin
      Move(Patches[Index].Bytes[0], PByte(PtrUInt(PageCopy + (Patches[Index].Address - Page)))^, Patches[Index].ByteCount);
      Inc(Index);
    end;
    KernelResult := MachVMProtect(Task, PageCopy, PageSize, 0, VM_PROT_READ or VM_PROT_EXECUTE);
    Destination := Page;
    if KernelResult = 0 then KernelResult := MachVMRemap(Task, Destination, PageSize, 0, VM_FLAGS_FIXED or VM_FLAGS_OVERWRITE, Task, PageCopy, 0, CurrentProtection, MaximumProtection, VM_INHERIT_NONE);
    if KernelResult <> 0 then
    begin
      PatchKernelResult := KernelResult;
      PatchError := 'cannot replace a code page of the program';
      Exit(False);
    end;
    Inc(PatchedCount, Index - First);
    MachVMDeallocate(Task, PageCopy, PageSize);
    ClearCache(Pointer(PtrUInt(Page)), PageSize);
  end;
end;

procedure MakeWritable(AAddress: QWord);
begin
  MachVMProtect(mach_task_self_, AAddress and not (PageSize - 1), PageSize, 0, VM_PROT_READ or VM_PROT_WRITE);
end;

var
  Threads: PLongWord;
  ThreadCount: LongWord;

procedure WorldStop;
var
  CurrentThread: TMachPort;
  I: LongWord;
begin
  if not SuspendThreads then Exit;
  CurrentThread := MachThreadSelf;
  if TaskThreads(mach_task_self_, Threads, ThreadCount) <> 0 then
  begin
    ThreadCount := 0;
    Exit;
  end;
  for I := 0 to ThreadCount - 1 do
    if Threads[I] <> CurrentThread then ThreadSuspend(Threads[I]);
  MachPortDeallocate(mach_task_self_, CurrentThread);
end;

procedure WorldStart;
var
  CurrentThread: TMachPort;
  I: LongWord;
begin
  if not SuspendThreads or (ThreadCount = 0) then Exit;
  CurrentThread := MachThreadSelf;
  for I := 0 to ThreadCount - 1 do
  begin
    if Threads[I] <> CurrentThread then ThreadResume(Threads[I]);
    MachPortDeallocate(mach_task_self_, Threads[I]);
  end;
  MachPortDeallocate(mach_task_self_, CurrentThread);
  VMDeallocate(mach_task_self_, PtrUInt(Threads), ThreadCount * SizeOf(LongWord));
  ThreadCount := 0;
end;

procedure SetupWorldStop;
begin
end;

function StoppedInsidePatch: Boolean;
begin
  Result := False;   // aarch64: a patch is one instruction
end;
{$elseif defined(linux)}
var
  SleepingBlockers: Boolean;   // WorldStop let threads that block the park signal sleep on

// Whether a patch lies inside one aligned 8-byte word, which one store replaces whole.
function FitsOneStore(const APatch: TPatch): Boolean;
begin
  Result := APatch.Address mod StoreSize + QWord(APatch.ByteCount) <= StoreSize;
end;

// A thread that blocks the park signal and sleeps in the kernel isn't stopped: it can wake
// while an entry is rewritten. Written in one store, the entry is either the old one or the
// new jump for it. fpc aligns functions, so every entry fits.
procedure WritePatch(const APatch: TPatch);
var
  Target: PInt64;
  Value: Int64;
begin
  if not FitsOneStore(APatch) then
  begin
    Move(APatch.Bytes[0], PByte(PtrUInt(APatch.Address))^, APatch.ByteCount);
    Exit;
  end;
  Target := PInt64(PtrUInt(APatch.Address - APatch.Address mod StoreSize));
  Value := Target^;
  Move(APatch.Bytes[0], (PByte(@Value) + APatch.Address mod StoreSize)^, APatch.ByteCount);
  InterLockedExchange64(Target^, Value);
end;

// Linux: make the pages writable, write, make them executable again. The other threads are
// stopped; on x86-64 none of them is inside the bytes written (StoppedInsidePatch).
function ApplyPatches: Boolean;
var
  I: SizeInt;
  Address, PageLow, PageHigh: QWord;
begin
  Result := True;
  if SleepingBlockers then
    for I := 0 to PatchCount - 1 do
      if not FitsOneStore(Patches[I]) then
      begin
        PatchError := SplitEntryFailure;
        Exit(False);
      end;
  for I := 0 to PatchCount - 1 do
  begin
    Address := Patches[I].Address;
    if InJIT(Address) then
    begin
      WritePatch(Patches[I]);
      ClearCache(Pointer(PtrUInt(Address)), Patches[I].ByteCount);
      Inc(PatchedCount);
      Continue;
    end;
    PageLow := Address and not (PageSize - 1);
    PageHigh := (Address + QWord(Patches[I].ByteCount) + PageSize - 1) and not (PageSize - 1);   // a patch can cross a page
    if LibCMProtect(Pointer(PtrUInt(PageLow)), PageHigh - PageLow, ProtectRead or ProtectWrite or ProtectExecute) <> 0 then
    begin
      PatchError := 'cannot make a code page of the program writable';
      Exit(False);
    end;
    WritePatch(Patches[I]);
    LibCMProtect(Pointer(PtrUInt(PageLow)), PageHigh - PageLow, ProtectRead or ProtectExecute);
    ClearCache(Pointer(PtrUInt(Address)), Patches[I].ByteCount);
    Inc(PatchedCount);
  end;
end;

procedure MakeWritable(AAddress: QWord);
begin
  LibCMProtect(Pointer(PtrUInt(AAddress and not (PageSize - 1))), PageSize, ProtectRead or ProtectWrite);
end;

// Linux has no call that suspends another thread: send each one a signal whose handler
// waits until the agent lets it go. The thread list is read before the first signal, so
// that nothing is allocated while a stopped thread may hold a lock.
var
  Hold, Parked, Arrived: LongInt;
  ThreadIDs: array[0..MaxThreads - 1] of LongInt;
  ThreadIDCount: LongInt;
  BlockerIDs: array[0..MaxThreads - 1] of LongInt;   // threads that blocked the park signal
  BlockerCount: LongInt;
  ProgramCounters: array[0..MaxThreads - 1] of QWord;   // where each stopped thread was

procedure ParkHandler(ASignal: LongInt; AInfo: PSigInfo; AContext: PSigContext); cdecl;
var
  ArrivalIndex: LongInt;
begin
  ArrivalIndex := InterLockedIncrement(Arrived) - 1;
{$ifdef cpux86_64}
  // ucontext_t: uc_flags, uc_link, uc_stack (24 bytes), then the registers; rip is the 17th
  if (ArrivalIndex >= 0) and (ArrivalIndex <= High(ProgramCounters)) and (AContext <> nil) then ProgramCounters[ArrivalIndex] := PQWord(PByte(AContext) + UContextRegistersOffset + UContextRIPIndex * SizeOf(QWord))^;
{$endif}
  InterLockedIncrement(Parked);
  while InterlockedCompareExchange(Hold, 0, 0) <> 0 do ;
  InterLockedDecrement(Parked);
end;

// A thread stopped after the first byte of an entry about to be overwritten would resume in
// the middle of the new jump.
function StoppedInsidePatch: Boolean;
var
  K, Count: LongInt;
  I: SizeInt;
begin
  Result := False;
{$ifdef cpux86_64}
  Count := InterlockedCompareExchange(Arrived, 0, 0);
  if Count > Length(ProgramCounters) then Count := Length(ProgramCounters);
  for K := 0 to Count - 1 do
    for I := 0 to PatchCount - 1 do
      if (ProgramCounters[K] > Patches[I].Address) and (ProgramCounters[K] < Patches[I].Address + QWord(Patches[I].ByteCount)) then Exit(True);
{$endif}
end;

procedure SetupWorldStop;
var
  Action: SigActionRec;
begin
  FillChar(Action, SizeOf(Action), 0);
  Action.sa_handler := SigActionHandler(@ParkHandler);
  Action.sa_flags := SA_SIGINFO or SA_RESTART;
  FpSigAction(ParkSignal, @Action, nil);
end;

type
  TStatusBuffer = array[0..StatusBufferSize - 1] of AnsiChar;

// /proc/self/task/<thread>/<file> into a buffer, with nothing allocated: these are read
// while other threads are stopped and may hold the heap's lock. The number of bytes read.
function ReadTaskFile(AThreadID: LongInt; const AFile: ShortString; var ABuffer: TStatusBuffer): TSsize;
var
  Path: array[0..TaskPathSize - 1] of AnsiChar;
  PathLength: SizeInt;
  Number: ShortString;
  FileDescriptor: cint;

  procedure Put(const AText: ShortString);
  begin
    Move(AText[1], Path[PathLength], Length(AText));
    Inc(PathLength, Length(AText));
  end;

begin
  Str(AThreadID, Number);
  PathLength := 0;
  Put('/proc/self/task/');
  Put(Number);
  Put('/');
  Put(AFile);
  Path[PathLength] := #0;
  FileDescriptor := FpOpen(PChar(@Path[0]), O_RDONLY);
  if FileDescriptor < 0 then Exit(0);
  Result := FpRead(FileDescriptor, ABuffer[0], SizeOf(ABuffer));
  FpClose(FileDescriptor);
end;

// Whether a thread blocks the signal that parks threads. Libraries start threads of their own
// that block every signal, such as the workers of Mesa's software renderer. Such a thread
// never parks, and sending it the signal each time would queue real-time signals until
// the process may queue no more.
function BlocksParkSignal(AThreadID: LongInt): Boolean;
const
  BlockedField = 'SigBlk:';
  HexBase = 16;
  HexLetterBase = 10;   // the value of 'a'
var
  Buffer: TStatusBuffer;
  Count, Index, K: TSsize;
  Mask: QWord;
begin
  Result := False;
  Count := ReadTaskFile(AThreadID, 'status', Buffer);
  Index := 0;
  while Index + Length(BlockedField) <= Count do
  begin
    K := 0;
    while (K < Length(BlockedField)) and (Buffer[Index + K] = BlockedField[K + 1]) do Inc(K);
    if K = Length(BlockedField) then Break;
    Inc(Index);
  end;
  if Index + Length(BlockedField) > Count then Exit;
  Index := Index + Length(BlockedField);
  while (Index < Count) and (Buffer[Index] in [' ', #9]) do Inc(Index);
  Mask := 0;
  while (Index < Count) and (Buffer[Index] in ['0'..'9', 'a'..'f']) do
  begin
    if Buffer[Index] <= '9' then Mask := Mask * HexBase + QWord(Ord(Buffer[Index]) - Ord('0'))
    else Mask := Mask * HexBase + QWord(Ord(Buffer[Index]) - Ord('a') + HexLetterBase);
    Inc(Index);
  end;
  Result := (Mask and (QWord(1) shl (ParkSignal - 1))) <> 0;
end;

// Whether a thread waits in the kernel (state S or D in /proc/self/task/<thread>/stat, after
// the name in parentheses, which may itself hold parentheses).
function WaitsInKernel(AThreadID: LongInt): Boolean;
var
  Buffer: TStatusBuffer;
  Count, Index: TSsize;
begin
  Count := ReadTaskFile(AThreadID, 'stat', Buffer);
  Index := Count - 1;
  while (Index >= 0) and (Buffer[Index] <> ')') do Dec(Index);
  Result := (Index >= 0) and (Index + 2 < Count) and (Buffer[Index + 2] in ['S', 'D']);
end;

// False when the program has more threads than the lists hold: a thread left off them
// would not be stopped.
function ListThreads: Boolean;
var
  Directory: pDir;
  Entry: pDirent;
  ThreadID, ErrorCode: LongInt;
begin
  Result := True;
  ThreadIDCount := 0;
  BlockerCount := 0;
  Directory := FpOpendir('/proc/self/task');
  if Directory = nil then Exit;
  repeat
    Entry := FpReaddir(Directory^);
    if Entry = nil then Break;
    Val(AnsiString(PChar(@Entry^.d_name[0])), ThreadID, ErrorCode);
    if ErrorCode <> 0 then Continue;
    if BlocksParkSignal(ThreadID) then
    begin
      if BlockerCount > High(BlockerIDs) then Result := False
      else
      begin
        BlockerIDs[BlockerCount] := ThreadID;
        Inc(BlockerCount);
      end;
    end
    else if ThreadIDCount > High(ThreadIDs) then Result := False
    else
    begin
      ThreadIDs[ThreadIDCount] := ThreadID;
      Inc(ThreadIDCount);
    end;
  until False;
  FpClosedir(Directory^);
end;

procedure WorldStop;
var
  CurrentThread, ProcessID, I, Sent: LongInt;
  StartTime: Double;
begin
  StopFailure := '';
  SleepingBlockers := False;
  if not SuspendThreads then Exit;
  if not ListThreads then
  begin
    StopFailure := TooManyThreadsFailure;
    Exit;
  end;
  CurrentThread := LibCGetTID;
  ProcessID := FpGetpid;
  InterLockedExchange(Hold, 1);
  InterLockedExchange(Arrived, 0);
  Sent := 0;
  for I := 0 to ThreadIDCount - 1 do
    if (ThreadIDs[I] <> CurrentThread) and (LibCTGKill(ProcessID, ThreadIDs[I], ParkSignal) = 0) then Inc(Sent);
  StartTime := NowMilliseconds;
  while (InterlockedCompareExchange(Parked, 0, 0) < Sent) and (NowMilliseconds - StartTime < ParkTimeoutMilliseconds) do ;
  // A thread that blocked the signal only for a moment may have unblocked since: stop it
  // like the others. One that still blocks it must be waiting in the kernel. It can wake
  // there, so ApplyPatches writes each entry in one store (WritePatch).
  for I := 0 to BlockerCount - 1 do
    if BlockerIDs[I] <> CurrentThread then
      if not BlocksParkSignal(BlockerIDs[I]) then
      begin
        if LibCTGKill(ProcessID, BlockerIDs[I], ParkSignal) = 0 then Inc(Sent);
      end
      else if WaitsInKernel(BlockerIDs[I]) then SleepingBlockers := True
      else StopFailure := BlockerRunningFailure;
  while (InterlockedCompareExchange(Parked, 0, 0) < Sent) and (NowMilliseconds - StartTime < ParkTimeoutMilliseconds) do ;
  if InterlockedCompareExchange(Parked, 0, 0) < Sent then StopFailure := ParkTimeoutFailure;
end;

procedure WorldStart;
var
  StartTime: Double;
begin
  if not SuspendThreads then Exit;
  InterLockedExchange(Hold, 0);
  StartTime := NowMilliseconds;
  while (InterlockedCompareExchange(Parked, 0, 0) > 0) and (NowMilliseconds - StartTime < ParkTimeoutMilliseconds) do ;
end;
{$else}
// Windows: VirtualProtect around each write. The other threads are stopped, and none of
// them is inside the bytes written (StoppedInsidePatch).
function ApplyPatches: Boolean;
var
  I: SizeInt;
  Address: QWord;
  OldProtection, Ignored: LongWord;
begin
  Result := True;
  for I := 0 to PatchCount - 1 do
  begin
    Address := Patches[I].Address;
    if InJIT(Address) then
    begin
      Move(Patches[I].Bytes[0], PByte(PtrUInt(Address))^, Patches[I].ByteCount);
      Inc(PatchedCount);
      Continue;
    end;
    if not VirtualProtect(Pointer(PtrUInt(Address)), Patches[I].ByteCount, PAGE_EXECUTE_READWRITE, OldProtection) then
    begin
      PatchError := 'cannot make a code page of the program writable';
      Exit(False);
    end;
    Move(Patches[I].Bytes[0], PByte(PtrUInt(Address))^, Patches[I].ByteCount);
    VirtualProtect(Pointer(PtrUInt(Address)), Patches[I].ByteCount, OldProtection, Ignored);
    Inc(PatchedCount);
  end;
  FlushInstructionCache(GetCurrentProcess, nil, 0);
end;

procedure MakeWritable(AAddress: QWord);
var
  OldProtection: LongWord;
begin
  VirtualProtect(Pointer(PtrUInt(AAddress)), 8, PAGE_READWRITE, OldProtection);
end;

// SuspendThread for every other thread of the process; GetThreadContext waits until a
// thread has really stopped and says where. The list and handles are made first, so that
// nothing is allocated while a stopped thread may hold a lock.
var
  ThreadHandles: array[0..MaxThreads - 1] of TWindowsHandle;
  ThreadHandleCount: LongInt;
  ProgramCounters: array[0..MaxThreads - 1] of QWord;
  ProgramCounterCount: LongInt;
  ContextBuffer: array[0..ContextSize + ContextSlack] of Byte;   // CONTEXT, aligned inside

procedure WorldStop;
var
  Snapshot, Handle: TWindowsHandle;
  Entry: TThreadEntry32;
  CurrentThread, ProcessID: LongWord;
  Context: PByte;
  I: LongInt;
begin
  ThreadHandleCount := 0;
  ProgramCounterCount := 0;
  StopFailure := '';
  if not SuspendThreads then Exit;
  CurrentThread := GetCurrentThreadId;
  ProcessID := GetCurrentProcessId;
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if Snapshot = InvalidHandle then Exit;
  Entry.dwSize := SizeOf(Entry);
  if Thread32First(Snapshot, Entry) then
    repeat
      if (Entry.th32OwnerProcessID = ProcessID) and (Entry.th32ThreadID <> CurrentThread) and (ThreadHandleCount > High(ThreadHandles)) then
        StopFailure := TooManyThreadsFailure   // a thread left off the list would not be stopped
      else if (Entry.th32OwnerProcessID = ProcessID) and (Entry.th32ThreadID <> CurrentThread) then
      begin
        Handle := OpenThread(THREAD_SUSPEND_RESUME or THREAD_GET_CONTEXT, False, Entry.th32ThreadID);
        if Handle <> 0 then
        begin
          ThreadHandles[ThreadHandleCount] := Handle;
          Inc(ThreadHandleCount);
        end;
      end;
      Entry.dwSize := SizeOf(Entry);
    until not Thread32Next(Snapshot, Entry);
  CloseHandle(Snapshot);
  Context := PByte((PtrUInt(@ContextBuffer[0]) + (ContextAlignment - 1)) and not PtrUInt(ContextAlignment - 1));
  for I := 0 to ThreadHandleCount - 1 do
    if SuspendThread(ThreadHandles[I]) <> SuspendFailed then
    begin
      FillChar(Context^, ContextSize, 0);
      PLongWord(Context + ContextFlagsOffset)^ := CONTEXT_CONTROL_AMD64;
      if GetThreadContext(ThreadHandles[I], Context) and (ProgramCounterCount <= High(ProgramCounters)) then
      begin
        ProgramCounters[ProgramCounterCount] := PQWord(Context + ContextRIPOffset)^;
        Inc(ProgramCounterCount);
      end;
    end;
end;

procedure WorldStart;
var
  I: LongInt;
begin
  for I := 0 to ThreadHandleCount - 1 do
  begin
    ResumeThread(ThreadHandles[I]);
    CloseHandle(ThreadHandles[I]);
  end;
  ThreadHandleCount := 0;
end;

procedure SetupWorldStop;
begin
end;

// A thread stopped after the first byte of an entry about to be overwritten would resume in
// the middle of the new jump.
function StoppedInsidePatch: Boolean;
var
  K: LongInt;
  I: SizeInt;
begin
  Result := False;
  for K := 0 to ProgramCounterCount - 1 do
    for I := 0 to PatchCount - 1 do
      if (ProgramCounters[K] > Patches[I].Address) and (ProgramCounters[K] < Patches[I].Address + QWord(Patches[I].ByteCount)) then Exit(True);
end;
{$endif}

{$ifdef windows}
// Win64 exceptions unwind through tables: code without an entry would be taken for a leaf
// function and the unwinder would lose its way. The entries of the loaded .pdata sections
// (begin, end, unwind info; offsets from the image base after relocation) go into one sorted
// table per load, registered with the system. ATable: nil when there were none.
function RegisterUnwind(const AObjectFiles: array of PObjectFile; out ATable: Pointer): Boolean;
var
  EntryCount, I, K, Index, Filled: SizeInt;
  Section: PSection;
  Entries: PLongWord;
  Entry: array[0..2] of LongWord;
begin
  Result := True;
  ATable := nil;
  EntryCount := 0;
  for I := 0 to High(AObjectFiles) do
    for K := 0 to High(AObjectFiles[I]^.Sections) do
      if (AObjectFiles[I]^.Sections[K].Base <> nil) and AObjectFiles[I]^.Sections[K].Live and StartsWith(AObjectFiles[I]^.Sections[K].Name, PDataSectionPrefix) then Inc(EntryCount, AObjectFiles[I]^.Sections[K].Size div RuntimeFunctionSize);
  if EntryCount = 0 then Exit;
  Entries := PLongWord(Bump(DataNext, DataRegion + DataAreaSize, EntryCount * RuntimeFunctionSize, 8));
  if Entries = nil then Exit(False);
  Filled := 0;
  for I := 0 to High(AObjectFiles) do
    for K := 0 to High(AObjectFiles[I]^.Sections) do
    begin
      Section := @AObjectFiles[I]^.Sections[K];
      if (Section^.Base = nil) or not Section^.Live or not StartsWith(Section^.Name, PDataSectionPrefix) then Continue;
      Move(Section^.Base^, Entries[Filled * RuntimeFunctionWords], (Section^.Size div RuntimeFunctionSize) * RuntimeFunctionSize);
      Inc(Filled, Section^.Size div RuntimeFunctionSize);
    end;
  for I := 1 to EntryCount - 1 do   // by begin address
  begin
    Move(Entries[I * RuntimeFunctionWords], Entry[0], RuntimeFunctionSize);
    Index := I - 1;
    while (Index >= 0) and (Entries[Index * RuntimeFunctionWords] > Entry[0]) do
    begin
      Move(Entries[Index * RuntimeFunctionWords], Entries[(Index + 1) * RuntimeFunctionWords], RuntimeFunctionSize);
      Dec(Index);
    end;
    Move(Entry[0], Entries[(Index + 1) * RuntimeFunctionWords], RuntimeFunctionSize);
  end;
  Result := RtlAddFunctionTable(Entries, EntryCount, ImageBase);
  if Result then ATable := Entries;
end;
{$endif}

// ================================================================ one load transaction
procedure CommandLoad(const APaths: array of AnsiString);
var
  StartTime, ParsedTime, PlacedTime, CommittedTime: Double;
  ObjectFiles: array of PObjectFile;
  SavedJITNext, SavedDataNext, SavedIslandNext, SavedVeneerNext: PByte;
  Succeeded, Applied: Boolean;
  I, K: SizeInt;
  Counts: TCounts;
  Bytes: QWord;
  VMTWords, RedirectCount: LongInt;
  Symbol: PRegistrySymbol;
  OldCurrentAddress, ViaAddress: QWord;
  Distance: Int64;
  NewWords, OldWords: PQWord;
  OldObject: PObjectFile;
  Address: QWord;
  Cleared: Boolean;
  Attempt: LongInt;
  UnwindTable: Pointer;
begin
  UnwindTable := nil;
  StartTime := NowMilliseconds;
  BuildHostSymbols;
  if not InitializeRegions then
  begin
    Say('refused');
    Exit;
  end;
  if Poisoned then
  begin
    Say('restart an earlier reload failed after some functions were already redirected');
    Say('refused');
    Exit;
  end;
  SetLength(ObjectFiles, Length(APaths));
  // Code and data of a load that is not applied are given back. Slots, islands and veneers
  // are not: the veneer cache and the records of functions keep pointing at them, and
  // handing one out twice would send a call to the wrong function.
  SavedJITNext := JITNext;
  SavedDataNext := DataNext;
  SavedIslandNext := IslandNext;
  SavedVeneerNext := VeneerNext;
  RestartCount := 0;
  PendingCount := 0;
  PatchCount := 0;
  StoreCount := 0;
  VMTUpdateCount := 0;
  DataCopyCount := 0;
  PatchError := '';
  PatchKernelResult := 0;
  Succeeded := True;
  for I := 0 to High(APaths) do
  begin
    ObjectFiles[I] := ParseObjectFile(APaths[I]);
    if ObjectFiles[I] = nil then
    begin
      Succeeded := False;
      Break;
    end;
    ObjectFiles[I]^.Previous := MapGet(Units, ObjectFiles[I]^.UnitName);
  end;
  ParsedTime := NowMilliseconds;
  FillChar(Counts, SizeOf(Counts), 0);
  Bytes := 0;
  if Succeeded then
  begin
    JITWritable(True);
    for I := 0 to High(ObjectFiles) do
      if Succeeded and not PlaceSections(ObjectFiles[I]) then Succeeded := False;
    if Succeeded then for I := 0 to High(ObjectFiles) do BindSymbols(ObjectFiles[I], Counts);
    if Succeeded then
    begin
      MarkLive(ObjectFiles);
      for I := 0 to High(ObjectFiles) do Unregister(ObjectFiles[I]);
    end;
    if Succeeded then for I := 0 to High(ObjectFiles) do ResolveUndefined(ObjectFiles[I]);
    if RestartCount > 0 then Succeeded := False;
    if Succeeded then for I := 0 to High(ObjectFiles) do CopySections(ObjectFiles[I]);
    if Succeeded then for I := 0 to High(ObjectFiles) do
      if Succeeded and not Relocate(ObjectFiles[I]) then Succeeded := False;
{$ifdef windows}
    if Succeeded and not RegisterUnwind(ObjectFiles, UnwindTable) then
    begin
      Say('error the system did not take the unwind tables of the new code');
      Succeeded := False;
    end;
{$endif}
    if Succeeded then ClearCache(SavedJITNext, JITNext - SavedJITNext);
    if VeneerNext > SavedVeneerNext then ClearCache(SavedVeneerNext, VeneerNext - SavedVeneerNext);
  end;
  PlacedTime := NowMilliseconds;
  VMTWords := 0;
  RedirectCount := 0;
  if Succeeded then
  begin
    // Everything below is the commit. Collect the writes first, then stop the other
    // threads for the few microseconds the writes take.
    for I := 0 to PendingCount - 1 do
    begin
      Symbol := PendingSymbols[I];
      if Symbol^.Kind <> KindCode then Continue;
      if Symbol^.CurrentAddress <> 0 then OldCurrentAddress := Symbol^.CurrentAddress
      else if Symbol^.PendingCanonicalAddress <> Symbol^.PendingCurrentAddress then OldCurrentAddress := Symbol^.PendingCanonicalAddress
      else OldCurrentAddress := 0;
      if OldCurrentAddress = 0 then Continue;   // a new function: nothing to redirect
      if Symbol^.Slot = nil then
      begin
        Symbol^.Slot := NewSlot(Symbol^.PendingCurrentAddress);
        if Symbol^.Slot <> nil then Symbol^.Island := MakeIsland(Symbol^.Slot) else Symbol^.Island := 0;
        if Symbol^.Island = 0 then
        begin
          Restart('no room left for call islands');
          Succeeded := False;
          Break;
        end;
      end
      else AddStore(Symbol^.Slot, Symbol^.PendingCurrentAddress);
      // The entry being retired is in the program's text the first time and in the code
      // region afterwards; the two can be more than a branch apart, so each has its island.
      ViaAddress := Symbol^.Island;
      if (OldCurrentAddress >= QWord(PtrUInt(JITRegion))) and (OldCurrentAddress < QWord(PtrUInt(JITRegion)) + JITSize) then
      begin
        if Symbol^.FarIsland = 0 then Symbol^.FarIsland := MakeVeneer(Symbol^.Slot);
        if Symbol^.FarIsland = 0 then
        begin
          Restart('no room left for call islands');
          Succeeded := False;
          Break;
        end;
        ViaAddress := Symbol^.FarIsland;
      end;
      Distance := Int64(ViaAddress - OldCurrentAddress);
      if (Distance >= BranchReach) or (Distance < -BranchReach) then
      begin
        Say('error ' + Pretty(Symbol^.Name) + ' is out of reach of its island');
        Succeeded := False;
        Break;
      end;
      AddPatch(RedirectPatch(OldCurrentAddress, ViaAddress));
      Inc(RedirectCount);
    end;
    if IslandNext > SavedIslandNext then ClearCache(SavedIslandNext, IslandNext - SavedIslandNext);
    if VeneerNext > SavedVeneerNext then ClearCache(SavedVeneerNext, VeneerNext - SavedVeneerNext);
  end;
  if Succeeded then
  begin
    for I := 0 to VMTUpdateCount - 1 do
    begin
      NewWords := PQWord(PtrUInt(PlacedAddress(VMTUpdates[I].ObjectFile, VMTUpdates[I].Symbol)));
      OldWords := PQWord(PtrUInt(VMTUpdates[I].OldAddress));
      for K := 0 to SizeInt(VMTUpdates[I].Symbol^.Size div VMTSlotSize) - 1 do
      begin
        if K = VMTClassNameSlot then Continue;   // the class name: equal text, another address
        if NewWords[K] <> OldWords[K] then
        begin
          AddStore(@OldWords[K], NewWords[K]);
          Inc(VMTWords);
        end;
      end;
    end;
    // Tables of the program (VMTs) may sit in a segment that is read-only.
    for I := 0 to StoreCount - 1 do
    begin
      Address := QWord(PtrUInt(Stores[I].Destination));
      if (Address < QWord(PtrUInt(DataRegion))) or (Address >= QWord(PtrUInt(DataRegion)) + DataAreaSize) then MakeWritable(Address);
    end;
    SortPatches;
    PatchedCount := 0;
    Cleared := False;
    for Attempt := 1 to StopAttempts do
    begin
      WorldStop;
      if (StopFailure = '') and not StoppedInsidePatch then
      begin
        Cleared := True;
        Break;
      end;
      WorldStart;
      if (StopFailure = ParkTimeoutFailure) or (StopFailure = TooManyThreadsFailure) then Break;   // trying again won't help
      Nap(1);
    end;
    if not Cleared then
    begin
      if StopFailure <> '' then PatchError := StopFailure
      else PatchError := 'a thread stayed inside the first bytes of a function being redirected';
      Applied := False;   // nothing written; the threads already run again
    end
    else Applied := ApplyPatches;
    if Applied then
    begin
      for I := 0 to StoreCount - 1 do InterLockedExchange64(PInt64(Stores[I].Destination)^, Int64(Stores[I].Value));
      for I := 0 to DataCopyCount - 1 do Move(DataCopies[I].Source^, PByte(PtrUInt(DataCopies[I].Destination))^, DataCopies[I].Size);
    end;
    WorldStart;
    if not Applied then
    begin
      Succeeded := False;
{$ifdef darwin}
      if PatchKernelResult <> 0 then PatchError := PatchError + ': ' + AnsiString(MachErrorString(PatchKernelResult));
{$endif}
      Say('error ' + PatchError);
      // Some entries already branch to islands whose slots name the new code: that code
      // must stay where it is, and nothing more can be trusted to apply cleanly.
      if PatchedCount > 0 then
      begin
        Poisoned := True;
        SavedJITNext := JITNext;
        SavedDataNext := DataNext;
        Say('error the reload stopped halfway: ' + SignedToString(PatchedCount) + ' functions are redirected and the rest are not; restart the program');
      end;
    end;
  end;
  JITWritable(False);
  CommittedTime := NowMilliseconds;
  if Succeeded then
  begin
    for I := 0 to PendingCount - 1 do
    begin
      Symbol := PendingSymbols[I];
      Symbol^.CanonicalAddress := Symbol^.PendingCanonicalAddress;
      Symbol^.CurrentAddress := Symbol^.PendingCurrentAddress;
      Symbol^.Pending := False;
    end;
    for I := 0 to High(ObjectFiles) do
    begin
      for K := 0 to High(ObjectFiles[I]^.Sections) do
        if ObjectFiles[I]^.Sections[K].Kind in [KindCode, KindData] then Inc(Bytes, ObjectFiles[I]^.Sections[K].Size);
      OldObject := ObjectFiles[I]^.Previous;
      ObjectFiles[I]^.Previous := nil;
      MapPut(Units, ObjectFiles[I]^.UnitName, ObjectFiles[I]);
      FreeObjectFile(OldObject);
    end;
    Say('stat units=' + SignedToString(Length(ObjectFiles)) + ' functions=' + SignedToString(Counts.Functions) + ' changed=' + SignedToString(Counts.Changed) + ' added=' + SignedToString(Counts.Added)
      + ' redirected=' + SignedToString(RedirectCount) + ' kept=' + SignedToString(Counts.Kept) + ' newdata=' + SignedToString(Counts.NewData) + ' vmtwords=' + SignedToString(VMTWords) + ' bytes=' + UnsignedToString(Bytes));
    Say('time parse=' + FloatToString(ParsedTime - StartTime) + ' place=' + FloatToString(PlacedTime - ParsedTime) + ' commit=' + FloatToString(CommittedTime - PlacedTime) + ' total=' + FloatToString(CommittedTime - StartTime) + ' hostsyms=' + FloatToString(HostMilliseconds));
    HostMilliseconds := 0;
    Say('ok');
  end
  else
  begin
    for I := 0 to PendingCount - 1 do PendingSymbols[I]^.Pending := False;
{$ifdef windows}
    if UnwindTable <> nil then RtlDeleteFunctionTable(UnwindTable);
{$endif}
    if UnwindTable <> nil then;
    JITNext := SavedJITNext;
    DataNext := SavedDataNext;
    for I := 0 to High(ObjectFiles) do FreeObjectFile(ObjectFiles[I]);
    Say('time total=' + FloatToString(NowMilliseconds - StartTime));
    if RestartCount > 0 then Say('refused') else Say('failed');
  end;
end;

procedure CommandBase(const APath: AnsiString);
var
  ObjectFile, OldObject: PObjectFile;
begin
  ObjectFile := ParseObjectFile(APath);
  if ObjectFile = nil then
  begin
    Say('failed');
    Exit;
  end;
  OldObject := MapGet(Units, ObjectFile^.UnitName);
  MapPut(Units, ObjectFile^.UnitName, ObjectFile);
  FreeObjectFile(OldObject);
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
// it to be idle, and the thread does nothing more once it sees AgentExiting.
var
  AgentToken: array[0..TokenCapacity - 1] of Char;   // not managed: valid during finalization too
  AgentPort: Word;
  AgentBusy, AgentExiting: LongInt;
  AgentConnected: Boolean;

{$ifdef windows}
var
  SocketHandle: PtrUInt;

function SocketConnect(APort: Word): Boolean;
var
  StartupData: array[0..WinSockDataSize - 1] of Byte;
  Address: TSockAddrIn;
begin
  Result := False;
  if WSAStartup(WinSockVersion, @StartupData[0]) <> 0 then Exit;
  SocketHandle := WinSockSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if SocketHandle = InvalidSocket then Exit;
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := Swap(APort);
  Address.sin_addr := LoopbackNetworkOrder;
  Result := WinSockConnect(SocketHandle, @Address, SizeOf(Address)) = 0;
end;

function SocketSend(ABuffer: PChar; ACount: LongInt): LongInt;
begin
  Result := WinSockSend(SocketHandle, ABuffer, ACount, 0);
end;

function SocketReceive(ABuffer: PChar; ACount: LongInt): LongInt;
begin
  Result := WinSockReceive(SocketHandle, ABuffer, ACount, 0);
end;

procedure SocketShutdown;
begin
  WinSockShutdown(SocketHandle, ShutdownBoth);
end;
{$else}
var
  SocketHandle: cint;

function SocketConnect(APort: Word): Boolean;
var
  Address: TInetSockAddr;
begin
  SocketHandle := FpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := htons(APort);
  Address.sin_addr.s_addr := htonl(LoopbackAddress);
  Result := (SocketHandle >= 0) and (FpConnect(SocketHandle, @Address, SizeOf(Address)) = 0);
end;

function SocketSend(ABuffer: PChar; ACount: LongInt): LongInt;
begin
  Result := FpSend(SocketHandle, ABuffer, ACount, 0);
end;

function SocketReceive(ABuffer: PChar; ACount: LongInt): LongInt;
begin
  Result := FpRecv(SocketHandle, ABuffer, ACount, 0);
end;

procedure SocketShutdown;
begin
  FpShutdown(SocketHandle, ShutdownBoth);
end;
{$endif}

// Busy from here on, unless the program is ending: then wait for the process to go.
procedure EnterBusy;
begin
  InterLockedExchange(AgentBusy, 1);
  if InterlockedCompareExchange(AgentExiting, 0, 0) <> 0 then
  begin
    InterLockedExchange(AgentBusy, 0);
    repeat
      Nap(IdleNapMilliseconds);
    until False;
  end;
end;

function SendAll(const AText: AnsiString): Boolean;
var
  Sent, Count: SizeInt;
begin
  Sent := 0;
  while Sent < Length(AText) do
  begin
    Count := SocketSend(PChar(AText) + Sent, Length(AText) - Sent);
    if Count <= 0 then Exit(False);
    Inc(Sent, Count);
  end;
  Result := True;
end;

function AgentMain(AArgument: Pointer): PtrInt;
var
{$ifdef unix}
  SignalMask: array[0..SignalSetSize - 1] of Byte;
{$endif}
  Buffer: array[0..ReceiveBufferSize - 1] of Char;
  Pending, Line: AnsiString;
  Received, NewlineIndex: SizeInt;
  Arguments: array of AnsiString;
  Token: AnsiString;
  Index: SizeInt;
begin
  Result := 0;
  EnterBusy;
{$ifdef unix}
  FillChar(SignalMask, SizeOf(SignalMask), $ff);
  LibCPThreadSigMask(SignalBlockHow, @SignalMask, nil);   // the program's signals are not for this thread
{$endif}
  if not SocketConnect(AgentPort) then
  begin
    WriteLn(StdErr, '[hotfpc agent] cannot reach the driver at 127.0.0.1:', AgentPort);
    InterLockedExchange(AgentBusy, 0);
    Exit;
  end;
  AgentConnected := True;
  FindProgram;
  SetupWorldStop;
  Reply := '';
  InitializeRegions;   // early: before the program's allocator claims the neighbourhood
  Reply := '';
  if not SendAll('hello ' + AnsiString(PChar(@AgentToken[0])) + #10) then
  begin
    InterLockedExchange(AgentBusy, 0);
    Exit;
  end;
  Pending := '';
  repeat
    InterLockedExchange(AgentBusy, 0);
    Received := SocketReceive(@Buffer[0], SizeOf(Buffer));
    EnterBusy;
    if Received <= 0 then Break;
    SetLength(Line, Received);
    Move(Buffer, Line[1], Received);
    Pending := Pending + Line;
    repeat
      NewlineIndex := Pos(#10, Pending);
      if NewlineIndex = 0 then Break;
      Line := Copy(Pending, 1, NewlineIndex - 1);
      Delete(Pending, 1, NewlineIndex);
      while (Line <> '') and (Line[Length(Line)] = #13) do SetLength(Line, Length(Line) - 1);
      SetLength(Arguments, 0);
      while Line <> '' do
      begin
        Index := Pos(#9, Line);
        if Index = 0 then Index := Length(Line) + 1;
        Token := Copy(Line, 1, Index - 1);
        Delete(Line, 1, Index);
        if Token <> '' then
        begin
          SetLength(Arguments, Length(Arguments) + 1);
          Arguments[High(Arguments)] := Token;
        end;
      end;
      if Length(Arguments) = 0 then Continue;
      Reply := '';
      if Arguments[0] = 'ping' then Say('pong')
      else if (Arguments[0] = 'base') and (Length(Arguments) = 2) then CommandBase(Arguments[1])
      else if (Arguments[0] = 'load') and (Length(Arguments) >= 2) then CommandLoad(Copy(Arguments, 1, Length(Arguments) - 1))
      else
      begin
        Say('error unknown command');
        Say('failed');
      end;
      Say('.');
      if not SendAll(Reply) then Break;
    until False;
  until False;
  InterLockedExchange(AgentBusy, 0);
end;

procedure StartAgent;
var
  Value: AnsiString;
  PortNumber, ErrorCode: LongInt;
  Count: SizeInt;
begin
  if not TryGetEnvironmentVariable('HOT_PORT', Value) then Exit;
  Val(Value, PortNumber, ErrorCode);
  if (ErrorCode <> 0) or (PortNumber <= 0) or (PortNumber > MaxPort) then Exit;
  AgentPort := PortNumber;
  TryGetEnvironmentVariable('HOT_TOKEN', Value);
  Count := Length(Value);
  if Count > High(AgentToken) then Count := High(AgentToken);
  if Count > 0 then Move(Value[1], AgentToken[0], Count);
  AgentToken[Count] := #0;
  if TryGetEnvironmentVariable('HOT_NOSUSPEND', Value) then SuspendThreads := False;
{$ifdef unix}
  PageSize := PtrUInt(LibCGetPageSize);
{$else}
  PageSize := WindowsPageSize;
{$endif}
  // A program this one starts must not take the driver for its own.
  UnsetEnvironmentVariable('HOT_PORT');
  UnsetEnvironmentVariable('HOT_TOKEN');
  BeginThread(@AgentMain, nil);
end;

procedure StopAgent;
var
  StartTime: Double;
begin
  InterLockedExchange(AgentExiting, 1);
  StartTime := NowMilliseconds;
  while (InterlockedCompareExchange(AgentBusy, 0, 0) <> 0) and (NowMilliseconds - StartTime < IdleTimeoutMilliseconds) do Nap(1);
  if AgentConnected then SocketShutdown;
end;

initialization
  StartAgent;

finalization
  StopAgent;
end.
