program TimingTest;
{ Tests of HotFPC.Timing: how durations print in the [hot] lines. }
{$mode delphi}{$H+}

uses
  SysUtils,

  HotFPC.Testing,
  HotFPC.Timing;

procedure TestFormats;
begin
  ExpectEqual(FormatMilliseconds(0.0), '0.0', 'no time');
  ExpectEqual(FormatMilliseconds(0.0123), '12.3', 'milliseconds with one decimal');
  ExpectEqual(FormatMilliseconds(0.002), '2.0', 'a whole number of milliseconds keeps its decimal');
  ExpectEqual(FormatMilliseconds(1.5), '1500.0', 'a second and a half');
  ExpectEqual(FormatSeconds(12.34), '12.3', 'seconds with one decimal');
  ExpectEqual(FormatSeconds(0.04), '0.0', 'under a tenth of a second');
end;

procedure TestClock;
var
  Start: TDateTime;
  First, Second: Double;
begin
  First := NowSeconds;
  Sleep(20);
  Second := NowSeconds;
  Expect(Second > First, 'time passes');
  Expect(Second - First < 5.0, 'at the pace of seconds');
  Start := Now - 2.0 / 86400.0;
  Expect(Abs(SecondsSince(Start) - 2.0) < 0.5, 'seconds since two seconds ago');
end;

begin
  TestFormats;
  TestClock;
  FinishTests;
end.
