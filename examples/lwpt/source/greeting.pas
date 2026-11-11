unit Greeting;

{$mode objfpc}{$H+}

interface

function Line(tick: Integer): string;

implementation

uses
  SysUtils;

function Line(tick: Integer): string;
begin
  Result := Format('tick %d: hello again, reloaded', [tick]);
end;

end.
