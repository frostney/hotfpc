program demo;

{$mode objfpc}{$H+}

uses
  SysUtils, Scene;

var
  i: Integer;
begin
  for i := 1 to 1000 do
  begin
    Step;
    WriteLn(Frame);
    Sleep(400);
  end;
end.
