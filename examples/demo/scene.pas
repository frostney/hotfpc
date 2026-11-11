unit Scene;

{$mode objfpc}{$H+}

interface

procedure Step;
function Frame: string;

implementation

uses
  SysUtils;

var
  Score: Integer = 0;

procedure Step;
begin
  Inc(Score, 1);
end;

function Frame: string;
begin
  Result := Format('score %4d  %s', [Score, StringOfChar('#', 1 + Score mod 20)]);
end;

end.
