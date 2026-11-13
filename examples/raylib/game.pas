program Game;
{ Opens the window and runs the frame loop; scene.pas does the rest. The loop is part of
  the main program, which keeps its old code, so the code to play with is in scene.pas. }
{$mode objfpc}{$H+}

uses
  Math, Raylib, Scene;

begin
  { raylib and the OpenGL driver under it rely on the C default of ignoring invalid floating
    point operations; Pascal turns them into exceptions. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  SetTraceLogLevel(LOG_WARNING);
  SetConfigFlags(FLAG_MSAA_4X_HINT or FLAG_VSYNC_HINT or FLAG_WINDOW_RESIZABLE);
  InitWindow(960, 540, 'hotfpc and raylib');
  SetTargetFPS(60);
  while not WindowShouldClose do
  begin
    Update(GetFrameTime);
    BeginDrawing;
    Draw;
    EndDrawing;
  end;
  CloseWindow;
end.
