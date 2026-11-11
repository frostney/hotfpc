program AgentLinkTest;
{ Tests of HotFPC.AgentLink: the lines of the protocol, how a reply is read, and a real
  connection on 127.0.0.1 inside this process, with the test as the program's side of it. }
{$mode delphi}{$H+}

uses
  Classes,
  Sockets,
  SysUtils,

  HotFPC.AgentLink,
  HotFPC.Network,
  HotFPC.Testing;

const
  AttemptLimit = 50;
  AttemptPause = 5;

procedure TestEncodeCommand;
begin
  ExpectEqual(TAgentLink.EncodeCommand(['ping']), 'ping' + #10, 'a command without arguments');
  ExpectEqual(TAgentLink.EncodeCommand(['base', '/a/b.o']), 'base' + #9 + '/a/b.o' + #10, 'base');
  ExpectEqual(TAgentLink.EncodeCommand(['load', '/a/b.o', '/a/c.o']), 'load' + #9 + '/a/b.o' + #9 + '/a/c.o' + #10,
    'load with two files');
end;

procedure TestTakeLine;
var
  Buffer, Line: string;
begin
  Buffer := 'ok';
  Line := '';
  Expect(not TAgentLink.TakeLine(Buffer, Line), 'a line that is not complete');
  ExpectEqual(Buffer, 'ok', 'stays in the buffer');
  Buffer := 'stat a=1' + #10 + 'ok' + #10 + '.' + #10 + 'next';
  Expect(TAgentLink.TakeLine(Buffer, Line), 'the first line');
  ExpectEqual(Line, 'stat a=1', 'is taken without its end');
  Expect(TAgentLink.TakeLine(Buffer, Line), 'the second line');
  ExpectEqual(Line, 'ok', 'is next');
  Expect(TAgentLink.TakeLine(Buffer, Line), 'the closing dot');
  ExpectEqual(Line, '.', 'is a line');
  ExpectEqual(Buffer, 'next', 'what follows stays');
  Buffer := #10;
  Expect(TAgentLink.TakeLine(Buffer, Line), 'an empty line');
  ExpectEqual(Line, '', 'is empty');
end;

procedure TestReplyField;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('note something happened');
    Lines.Add('stat redirected=3 changed=1 added=2 kept=7 newdata=0 bytes=4096');
    Lines.Add('time total=0.42');
    Lines.Add('ok');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'redirected'), '3', 'the first field');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'bytes'), '4096', 'the last field');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'time', 'total'), '0.42', 'a field of another line');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'total'), '', 'a field of another line is not found here');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'redirect'), '', 'a key is whole');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'missing', 'bytes'), '', 'a line that is not there');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'stat'), '', 'the line''s own name is no field');
    Lines.Add('stat extra=a=b');
    ExpectEqual(TAgentLink.ReplyField(Lines, 'stat', 'extra'), 'a=b', 'a value keeps its own equals signs');
  finally
    Lines.Free;
  end;
end;

procedure TestReplyDetail;
var
  Detail: string;
begin
  Expect(TAgentLink.ReplyDetail('note unit moved', 'note ', Detail), 'a note');
  ExpectEqual(Detail, 'unit moved', 'its text');
  Expect(TAgentLink.ReplyDetail('restart TFoo: a new field', 'restart ', Detail), 'a restart');
  ExpectEqual(Detail, 'TFoo: a new field', 'its text');
  Expect(not TAgentLink.ReplyDetail('ok', 'note ', Detail), 'another line');
  ExpectEqual(Detail, '', 'has no text');
  Expect(not TAgentLink.ReplyDetail('note', 'note ', Detail), 'a prefix needs its blank');
  Expect(TAgentLink.ReplyDetail('error ', 'error ', Detail), 'an error without text');
  ExpectEqual(Detail, '', 'has none');
end;

procedure TestPathsAndToken;
var
  Token: string;
  I: Integer;
begin
  ExpectEqual(TAgentLink.TranslatePath('/tmp/p/.hot/live/a.o', False), '/tmp/p/.hot/live/a.o', 'a native path as it is');
  ExpectEqual(TAgentLink.TranslatePath('/tmp/p/.hot/live/a.o', True), 'Z:\tmp\p\.hot\live\a.o', 'a path under Wine');
  Token := TAgentLink.NewToken;
  ExpectEqual(Length(Token), 16, 'a token has sixteen digits');
  for I := 1 to Length(Token) do
    Expect(Token[I] in ['0'..'9', 'A'..'F'], 'and they are hexadecimal');
  ExpectEqual(TAgentLink.Greeting('0123456789ABCDEF'), 'hello 0123456789ABCDEF', 'the greeting of the agent');
end;

function ConnectClient(const APort: Word): TSocket;
var
  Address: TInetSockAddr;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Address, SizeOf(Address), 0);
  Address.sin_family := AF_INET;
  Address.sin_port := htons(APort);
  Address.sin_addr := StrToNetAddr('127.0.0.1');
  Expect(fpConnect(Result, @Address, SizeOf(Address)) = 0, 'the client connects');
end;

procedure SendText(const ASocket: TSocket; const AText: string);
begin
  Expect(fpSend(ASocket, @AText[1], Length(AText), 0) = Length(AText), 'the client sends');
end;

function ReceiveText(const ASocket: TSocket; const ALength: Integer): string;
var
  Received, Count: Integer;
begin
  Result := '';
  SetLength(Result, ALength);
  Received := 0;
  while Received < ALength do
  begin
    Count := fpRecv(ASocket, @Result[Received + 1], ALength - Received, 0);
    if Count <= 0 then
      Break;
    Inc(Received, Count);
  end;
  SetLength(Result, Received);
end;

function AcceptWithin(const ALink: TAgentLink): Boolean;
var
  Attempt: Integer;
begin
  Result := False;
  for Attempt := 1 to AttemptLimit do
  begin
    Result := ALink.TryAccept;
    if Result then
      Exit;
    Sleep(AttemptPause);
  end;
end;

procedure TestConnection;
var
  Link: TAgentLink;
  Client: TSocket;
  Paths, Reply: TStringList;
  Command: string;
  Character: Char;
begin
  Link := TAgentLink.Create(False);
  try
    Expect(Link.Listen, 'the link listens');
    Expect(Link.Port <> 0, 'on a port the system picked');
    ExpectEqual(Length(Link.Token), 16, 'with a token');
    Expect(not Link.TryAccept, 'nobody is connecting');
    { something that connects without the token is not the program }
    Client := ConnectClient(Link.Port);
    SendText(Client, 'hello not-the-token' + #10);
    Expect(not AcceptWithin(Link), 'a greeting with another token is refused');
    SetBlocking(Client, False);
    ExpectEqual(fpRecv(Client, @Character, 1, 0), 0, 'and the connection is closed');
    CloseSocketHandle(Client);
    Client := ConnectClient(Link.Port);
    SendText(Client, 'hello ' + Link.Token + #10);
    Expect(AcceptWithin(Link), 'the greeting with the token is accepted');
    SetBlocking(Client, True);
    { the program's side: the replies are sent ahead, in pieces the driver has to put together }
    SendText(Client, 'ok' + #10 + '.' + #10);
    Link.Base('/p/.hot/live/a.o');
    Command := 'base' + #9 + '/p/.hot/live/a.o' + #10;
    ExpectEqual(ReceiveText(Client, Length(Command)), Command, 'base reaches the program');
    SendText(Client, 'note a thing' + #10 + 'stat redirected=2 bytes=64' + #10 + 'ok' + #10 + '.' + #10);
    Paths := TStringList.Create;
    try
      Paths.Add('/p/.hot/v2/a.o');
      Paths.Add('/p/.hot/v2/b.o');
      Reply := Link.Load(Paths);
    finally
      Paths.Free;
    end;
    try
      Command := 'load' + #9 + '/p/.hot/v2/a.o' + #9 + '/p/.hot/v2/b.o' + #10;
      ExpectEqual(ReceiveText(Client, Length(Command)), Command, 'load reaches the program');
      ExpectEqual(Reply.Count, 3, 'the reply has its lines without the dot');
      ExpectEqual(Reply[2], 'ok', 'the verdict is the last');
      ExpectEqual(TAgentLink.ReplyField(Reply, 'stat', 'bytes'), '64', 'with its statistics');
    finally
      Reply.Free;
    end;
    CloseSocketHandle(Client);
  finally
    Link.Free;
  end;
end;

begin
  TestEncodeCommand;
  TestTakeLine;
  TestReplyField;
  TestReplyDetail;
  TestPathsAndToken;
  TestConnection;
  FinishTests;
end.
