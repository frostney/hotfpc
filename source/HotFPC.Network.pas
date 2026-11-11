unit HotFPC.Network;
{ HotFPC.Network: what differs between Unix and Windows in the sockets the driver uses: the
  start of the socket library, blocking mode, and closing. Everything else about sockets is
  the Sockets unit's, which both systems share. }
{$mode delphi}{$H+}
{ fpc 3.3.1 before fpc-toolchain release 3.3.1+4 miscompiles loops at -O1 and above
  (docs/how-it-works.md, "A compiler bug"); fpc -iV cannot tell those builds from fixed ones. }
{$IF FPC_FULLVERSION >= 30301}{$optimization off}{$ENDIF}

interface

uses
  Sockets;

{ Windows needs the socket library started once; elsewhere there is nothing to do. }
procedure StartNetwork;
procedure SetBlocking(const ASocket: Sockets.TSocket; const ABlocking: Boolean);
procedure CloseSocketHandle(const ASocket: Sockets.TSocket);

implementation

{ WinSock2 declares a TSocket of its own; the interface's one is the Sockets unit's, as it
  was before this code moved here, so the headers below name it. }
uses
  {$ifdef unix}
  BaseUnix;
  {$endif}
  {$ifdef windows}
  WinSock2;
  {$endif}

{$ifdef windows}
const
  WinSockVersion = $0202;
  NonBlockingOn = 1;
  NonBlockingOff = 0;
{$endif}

procedure StartNetwork;
{$ifdef windows}
var
  Data: WinSock2.TWSAData;
begin
  WinSock2.WSAStartup(WinSockVersion, Data);
end;
{$else}
begin
end;
{$endif}

procedure SetBlocking(const ASocket: Sockets.TSocket; const ABlocking: Boolean);
{$ifdef windows}
var
  Mode: WinSock2.u_long;
begin
  if ABlocking then
    Mode := NonBlockingOff
  else
    Mode := NonBlockingOn;
  WinSock2.ioctlsocket(ASocket, LongInt(WinSock2.FIONBIO), Mode);
end;
{$else}
var
  Flags: LongInt;
begin
  Flags := FpFcntl(ASocket, F_GETFL);
  if ABlocking then
    Flags := Flags and not O_NONBLOCK
  else
    Flags := Flags or O_NONBLOCK;
  FpFcntl(ASocket, F_SETFL, Flags);
end;
{$endif}

procedure CloseSocketHandle(const ASocket: Sockets.TSocket);
begin
{$ifdef windows}
  WinSock2.closesocket(ASocket);
{$else}
  FpClose(ASocket);
{$endif}
end;

end.
