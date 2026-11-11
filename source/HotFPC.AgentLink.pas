unit HotFPC.AgentLink;
{ HotFPC.AgentLink: the connection between the driver and the agent inside the program, and
  the protocol on it. The driver listens on 127.0.0.1 on a port the system picks; the program
  connects and greets with "hello <token>", the token being the one the driver put into the
  program's environment. A command is one line of tab-separated fields; the reply is lines
  ended by a line with a single dot. The commands are base (remember a unit's code before its
  first change) and load (apply object files). TCP works the same on every system, including
  between a program under Wine and a driver outside it. }
{$mode delphi}{$H+}

interface

uses
  Classes,
  Sockets;

type
  TAgentLink = class
  private
    FListener: TSocket;
    FConnection: TSocket;
    FPort: Word;
    FToken: string;
    FReceived: string;
    FWinePaths: Boolean;
    function Ask(const AFields: array of string): TStringList;
  public
    { AWinePaths: the program runs under Wine, so paths sent to it are Windows paths. }
    constructor Create(const AWinePaths: Boolean);
    destructor Destroy; override;
    { Starts listening, without blocking, on a port the system picks. False when that is
      not possible. }
    function Listen: Boolean;
    { Takes one waiting connection and keeps it when it greets with the token; anything else
      that connects (a program the program started, or something else) is closed. True once
      the agent is connected. }
    function TryAccept: Boolean;
    { Tells the agent to remember the code of a unit's object file as the base of later swaps. }
    procedure Base(const APath: string);
    { Asks the agent to apply object files; the reply's lines, without the closing dot. The
      caller frees the list. }
    function Load(const APaths: TStrings): TStringList;
    { The command as it goes on the wire. }
    class function EncodeCommand(const AFields: array of string): string;
    { Takes the first complete line out of ABuffer. False when there is none yet. }
    class function TakeLine(var ABuffer: string; out ALine: string): Boolean;
    { From "stat a=1 b=2" among the lines: the value of a key, or ''. }
    class function ReplyField(const ALines: TStrings; const APrefix, AKey: string): string;
    { True when the line starts with the prefix, and then what follows it. }
    class function ReplyDetail(const ALine, APrefix: string; out ADetail: string): Boolean;
    { A program under Wine sees the host's root as drive Z:. }
    class function TranslatePath(const APath: string; const AWinePaths: Boolean): string;
    class function NewToken: string;
    class function Greeting(const AToken: string): string;
    property Port: Word read FPort;
    property Token: string read FToken;
  end;

implementation

uses
  SysUtils,

  HotFPC.Network;

const
  InvalidSocket = TSocket(-1);
  LoopbackAddress = $7f000001;
  ListenBacklog = 8;
  MaximumGreetingLength = 200;
  ReceiveBufferSize = 65536;
  TokenRange = $7fffffff;
  TokenPartDigits = 8;
  FieldSeparator = #9;
  LineEnd = #10;
  ReplyEnd = '.';
  GreetingPrefix = 'hello ';
  BaseCommand = 'base';
  LoadCommand = 'load';

constructor TAgentLink.Create(const AWinePaths: Boolean);
begin
  inherited Create;
  FWinePaths := AWinePaths;
  FListener := InvalidSocket;
  FConnection := InvalidSocket;
  StartNetwork;
end;

destructor TAgentLink.Destroy;
begin
  if FConnection <> InvalidSocket then
    CloseSocketHandle(FConnection);
  if FListener <> InvalidSocket then
    CloseSocketHandle(FListener);
  inherited Destroy;
end;

class function TAgentLink.NewToken: string;
begin
  Randomize;
  Result := IntToHex(Random(TokenRange), TokenPartDigits) + IntToHex(Random(TokenRange), TokenPartDigits);
end;

class function TAgentLink.Greeting(const AToken: string): string;
begin
  Result := GreetingPrefix + AToken;
end;

class function TAgentLink.TranslatePath(const APath: string; const AWinePaths: Boolean): string;
begin
  if AWinePaths then
    Result := 'Z:' + StringReplace(APath, '/', '\', [rfReplaceAll])
  else
    Result := APath;
end;

class function TAgentLink.EncodeCommand(const AFields: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AFields) do
  begin
    if I > 0 then
      Result := Result + FieldSeparator;
    Result := Result + AFields[I];
  end;
  Result := Result + LineEnd;
end;

class function TAgentLink.TakeLine(var ABuffer: string; out ALine: string): Boolean;
var
  Separator: Integer;
begin
  Separator := Pos(LineEnd, ABuffer);
  if Separator = 0 then
    Exit(False);
  ALine := Copy(ABuffer, 1, Separator - 1);
  Delete(ABuffer, 1, Separator);
  Result := True;
end;

class function TAgentLink.ReplyField(const ALines: TStrings; const APrefix, AKey: string): string;
var
  I, Separator: Integer;
  Rest, Item: string;
begin
  Result := '';
  for I := 0 to ALines.Count - 1 do
    if Copy(ALines[I], 1, Length(APrefix) + 1) = APrefix + ' ' then
    begin
      Rest := ALines[I] + ' ';
      repeat
        Separator := Pos(' ', Rest);
        if Separator = 0 then
          Break;
        Item := Copy(Rest, 1, Separator - 1);
        Delete(Rest, 1, Separator);
        if Copy(Item, 1, Length(AKey) + 1) = AKey + '=' then
          Exit(Copy(Item, Length(AKey) + 2, MaxInt));
      until Rest = '';
    end;
end;

class function TAgentLink.ReplyDetail(const ALine, APrefix: string; out ADetail: string): Boolean;
begin
  Result := Copy(ALine, 1, Length(APrefix)) = APrefix;
  if Result then
    ADetail := Copy(ALine, Length(APrefix) + 1, MaxInt)
  else
    ADetail := '';
end;

function TAgentLink.Listen: Boolean;
var
  Address: TInetSockAddr;
  AddressLength: TSockLen;
begin
  FListener := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := 0;
  Address.sin_addr.s_addr := htonl(LoopbackAddress);
  if fpBind(FListener, @Address, SizeOf(Address)) <> 0 then
    Exit(False);
  fpListen(FListener, ListenBacklog);
  AddressLength := SizeOf(Address);
  fpGetSockName(FListener, @Address, @AddressLength);
  FPort := ntohs(Address.sin_port);
  FToken := NewToken;
  { macOS checks a newly linked program on its first start, which can take seconds: the
    driver polls instead of waiting here. }
  SetBlocking(FListener, False);
  Result := True;
end;

function TAgentLink.TryAccept: Boolean;
var
  Connection: TSocket;
  Received: Integer;
  Character: Char;
  Hello: string;
begin
  Result := False;
  Connection := fpAccept(FListener, nil, nil);
  if Connection = InvalidSocket then
    Exit;
  SetBlocking(Connection, True);
  Hello := '';
  repeat
    Received := fpRecv(Connection, @Character, 1, 0);
    if (Received <= 0) or (Character = LineEnd) then
      Break;
    Hello := Hello + Character;
  until Length(Hello) > MaximumGreetingLength;
  if Hello = Greeting(FToken) then
  begin
    FConnection := Connection;
    Result := True;
  end
  else
    CloseSocketHandle(Connection);
end;

function TAgentLink.Ask(const AFields: array of string): TStringList;
var
  Command, Line, Chunk: string;
  Sent, Transferred: Integer;
  Buffer: array[0..ReceiveBufferSize - 1] of Char;
begin
  Command := EncodeCommand(AFields);
  Sent := 1;
  while Sent <= Length(Command) do
  begin
    Transferred := fpSend(FConnection, @Command[Sent], Length(Command) - Sent + 1, 0);
    if Transferred <= 0 then
      Break;
    Inc(Sent, Transferred);
  end;
  Result := TStringList.Create;
  repeat
    if TakeLine(FReceived, Line) then
    begin
      if Line = ReplyEnd then
        Exit;
      Result.Add(Line);
      Continue;
    end;
    Transferred := fpRecv(FConnection, @Buffer[0], SizeOf(Buffer), 0);
    if Transferred <= 0 then
      Exit;
    SetLength(Chunk, Transferred);
    Move(Buffer[0], Chunk[1], Transferred);
    FReceived := FReceived + Chunk;
  until False;
end;

procedure TAgentLink.Base(const APath: string);
begin
  Ask([BaseCommand, TranslatePath(APath, FWinePaths)]).Free;
end;

function TAgentLink.Load(const APaths: TStrings): TStringList;
var
  Fields: array of string;
  I: Integer;
begin
  SetLength(Fields, APaths.Count + 1);
  Fields[0] := LoadCommand;
  for I := 0 to APaths.Count - 1 do
    Fields[I + 1] := TranslatePath(APaths[I], FWinePaths);
  Result := Ask(Fields);
end;

end.
