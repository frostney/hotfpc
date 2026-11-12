unit Raylib;
{ The part of raylib (https://www.raylib.com, 6.x) this example uses, declared from raylib.h.
  Add a declaration here when you want another function: copy its line from raylib.h and
  give it the Pascal types below. }
{$mode objfpc}{$H+}

interface

{$ifndef windows}
{$linklib raylib}
{$endif}

const
  {$ifdef windows}
  RaylibLibrary = 'raylib.dll';
  {$else}
  RaylibLibrary = 'raylib';
  {$endif}

  FLAG_WINDOW_RESIZABLE = $00000004;
  FLAG_MSAA_4X_HINT = $00000020;
  FLAG_VSYNC_HINT = $00000040;

  LOG_WARNING = 4;

  KEY_SPACE = 32;
  KEY_R = 82;
  KEY_RIGHT = 262;
  KEY_LEFT = 263;
  KEY_DOWN = 264;
  KEY_UP = 265;

  MOUSE_BUTTON_LEFT = 0;

type
  TColor = record
    R, G, B, A: Byte;
  end;

  TVector2 = record
    X, Y: Single;
  end;

  TRectangle = record
    X, Y, Width, Height: Single;
  end;

{ Window and frame }
procedure SetConfigFlags(Flags: Cardinal); cdecl; external RaylibLibrary;
procedure SetTraceLogLevel(LogLevel: Integer); cdecl; external RaylibLibrary;
procedure InitWindow(Width, Height: Integer; Title: PChar); cdecl; external RaylibLibrary;
procedure CloseWindow; cdecl; external RaylibLibrary;
function WindowShouldClose: Boolean; cdecl; external RaylibLibrary;
function GetScreenWidth: Integer; cdecl; external RaylibLibrary;
function GetScreenHeight: Integer; cdecl; external RaylibLibrary;
procedure SetTargetFPS(Fps: Integer); cdecl; external RaylibLibrary;
function GetFrameTime: Single; cdecl; external RaylibLibrary;
function GetTime: Double; cdecl; external RaylibLibrary;
function GetRandomValue(Min, Max: Integer): Integer; cdecl; external RaylibLibrary;
procedure BeginDrawing; cdecl; external RaylibLibrary;
procedure EndDrawing; cdecl; external RaylibLibrary;
procedure ClearBackground(Color: TColor); cdecl; external RaylibLibrary;

{ Input }
function IsKeyPressed(Key: Integer): Boolean; cdecl; external RaylibLibrary;
function IsKeyDown(Key: Integer): Boolean; cdecl; external RaylibLibrary;
function IsMouseButtonPressed(Button: Integer): Boolean; cdecl; external RaylibLibrary;
function GetMousePosition: TVector2; cdecl; external RaylibLibrary;

{ Shapes and text }
procedure DrawLineEx(StartPos, EndPos: TVector2; Thick: Single; Color: TColor); cdecl; external RaylibLibrary;
procedure DrawCircleV(Center: TVector2; Radius: Single; Color: TColor); cdecl; external RaylibLibrary;
procedure DrawCircleLinesV(Center: TVector2; Radius: Single; Color: TColor); cdecl; external RaylibLibrary;
procedure DrawCircleGradient(Center: TVector2; Radius: Single; Inner, Outer: TColor); cdecl; external RaylibLibrary;
procedure DrawRing(Center: TVector2; InnerRadius, OuterRadius, StartAngle, EndAngle: Single; Segments: Integer;
  Color: TColor); cdecl; external RaylibLibrary;
procedure DrawPoly(Center: TVector2; Sides: Integer; Radius, Rotation: Single; Color: TColor); cdecl;
  external RaylibLibrary;
procedure DrawRectangleRec(Rec: TRectangle; Color: TColor); cdecl; external RaylibLibrary;
procedure DrawRectangleRounded(Rec: TRectangle; Roundness: Single; Segments: Integer; Color: TColor); cdecl;
  external RaylibLibrary;
procedure DrawText(Text: PChar; PosX, PosY, FontSize: Integer; Color: TColor); cdecl; external RaylibLibrary;
function MeasureText(Text: PChar; FontSize: Integer): Integer; cdecl; external RaylibLibrary;
procedure DrawFPS(PosX, PosY: Integer); cdecl; external RaylibLibrary;

{ Colours }
function Fade(Color: TColor; Alpha: Single): TColor; cdecl; external RaylibLibrary;
function ColorFromHSV(Hue, Saturation, Value: Single): TColor; cdecl; external RaylibLibrary;
function ColorLerp(Color1, Color2: TColor; Factor: Single): TColor; cdecl; external RaylibLibrary;
function ColorToInt(Color: TColor): Integer; cdecl; external RaylibLibrary;

{ Pascal helpers for raylib's struct literals }
function Color(R, G, B: Byte; A: Byte = 255): TColor;
function Vector2(X, Y: Single): TVector2;
function Rectangle(X, Y, Width, Height: Single): TRectangle;

implementation

function Color(R, G, B: Byte; A: Byte): TColor;
begin
  Result.R := R;
  Result.G := G;
  Result.B := B;
  Result.A := A;
end;

function Vector2(X, Y: Single): TVector2;
begin
  Result.X := X;
  Result.Y := Y;
end;

function Rectangle(X, Y, Width, Height: Single): TRectangle;
begin
  Result.X := X;
  Result.Y := Y;
  Result.Width := Width;
  Result.Height := Height;
end;

end.
