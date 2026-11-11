unit Scene;
{$mode objfpc}{$H+}

interface

procedure Step;
function Frame: string;

implementation

uses SysUtils;

const
  Glyph = '#';
  Color = #27'[32m';
  Reset = #27'[0m';

var
  Score: Integer = 0;

procedure Step;
begin
  Inc(Score, 1);
end;

function Frame: string;
var
  Bar: string;
begin
  Bar := StringOfChar(Glyph, 1 + Score mod 20);
  Result := Format('%sscore %4d  %s%s', [Color, Score, Bar, Reset]);
end;

end.
