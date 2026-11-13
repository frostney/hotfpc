unit Scene;
{ Everything you see: balls that fall, bounce and change colour. Edit this file and save
  while game.pas runs. }
{$mode objfpc}{$H+}

interface

procedure Update(Seconds: Single);
procedure Draw;

implementation

uses
  SysUtils, Raylib;

const
  MaxBalls = 64;
  Gravity = 900.0;      // pixels per second, per second
  Bounce = 0.9;         // how much of its speed a ball keeps when it hits a wall
  Radius = 18.0;
  HueSpeed = 40.0;      // degrees per second

type
  TBall = record
    Position, Velocity: TVector2;
    Hue: Single;
  end;

var
  Balls: array[0..MaxBalls - 1] of TBall;
  Count: Integer = 0;
  Bounces: Integer = 0;

procedure AddBall(Position: TVector2);
begin
  if Count = MaxBalls then
    Exit;
  Balls[Count].Position := Position;
  Balls[Count].Velocity := Vector2(GetRandomValue(-300, 300), GetRandomValue(-500, -100));
  Balls[Count].Hue := GetRandomValue(0, 359);
  Inc(Count);
end;

procedure Move(var Ball: TBall; Seconds: Single);
var
  Right, Bottom: Single;
begin
  Right := GetScreenWidth - Radius;
  Bottom := GetScreenHeight - Radius;
  Ball.Velocity.Y := Ball.Velocity.Y + Gravity * Seconds;
  Ball.Position.X := Ball.Position.X + Ball.Velocity.X * Seconds;
  Ball.Position.Y := Ball.Position.Y + Ball.Velocity.Y * Seconds;
  if (Ball.Position.X < Radius) or (Ball.Position.X > Right) then
  begin
    if Ball.Position.X < Radius then Ball.Position.X := Radius else Ball.Position.X := Right;
    Ball.Velocity.X := -Ball.Velocity.X * Bounce;
    Inc(Bounces);
  end;
  if Ball.Position.Y > Bottom then
  begin
    Ball.Position.Y := Bottom;
    Ball.Velocity.Y := -Ball.Velocity.Y * Bounce;
    Inc(Bounces);
  end;
  Ball.Hue := Ball.Hue + HueSpeed * Seconds;
  if Ball.Hue >= 360 then
    Ball.Hue := Ball.Hue - 360;
end;

procedure Update(Seconds: Single);
var
  I: Integer;
begin
  if Count = 0 then
    for I := 1 to 8 do
      AddBall(Vector2(GetRandomValue(100, GetScreenWidth - 100), GetRandomValue(50, 200)));
  if IsMouseButtonPressed(MOUSE_BUTTON_LEFT) then
    AddBall(GetMousePosition);
  if IsKeyPressed(KEY_SPACE) then
    for I := 0 to Count - 1 do
      Balls[I].Velocity.Y := Balls[I].Velocity.Y - 600;
  if IsKeyPressed(KEY_R) then
    Count := 0;
  for I := 0 to Count - 1 do
    Move(Balls[I], Seconds);
end;

procedure Draw;
var
  I: Integer;
begin
  ClearBackground(Color(24, 26, 34));
  for I := 0 to Count - 1 do
    DrawCircleV(Balls[I].Position, Radius, ColorFromHSV(Balls[I].Hue, 0.6, 0.95));
  DrawText(PChar(Format('%d balls, %d bounces', [Count, Bounces])), 20, 20, 20, Color(200, 200, 200));
  DrawText('click: a ball   space: jump   r: start again', 20, GetScreenHeight - 36, 16, Color(120, 120, 130));
end;

end.
