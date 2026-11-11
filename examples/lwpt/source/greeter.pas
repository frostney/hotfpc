program greeter;

{$mode objfpc}{$H+}

uses
  SysUtils, Greeting;

var
  tick: Integer;
begin
  for tick := 1 to 600 do
  begin
    WriteLn(Line(tick));
    Sleep(1000);
  end;
end.
