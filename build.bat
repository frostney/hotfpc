@echo off
rem build.bat [FPC [options]]: builds bin\hotfpc.exe with the given compiler (default: fpc).
rem Up to eight options go to every compile, e.g. -Fu paths when the compiler has no fpc.cfg.
rem The agent's source is embedded first (source\embed.pas).
setlocal
cd /d "%~dp0"
set "FPC=%~1"
if "%FPC%"=="" set "FPC=fpc"
if not exist build\embed mkdir build\embed
if not exist build\hotfpc mkdir build\hotfpc
if not exist bin mkdir bin
"%FPC%" %2 %3 %4 %5 %6 %7 %8 %9 -FUbuild\embed -obuild\embed\embed.exe source\embed.pas > build\embed.log 2>&1
if errorlevel 1 (type build\embed.log & exit /b 1)
build\embed\embed.exe source\hotagent.pas build\agentsource.inc
if errorlevel 1 exit /b 1
"%FPC%" %2 %3 %4 %5 %6 %7 %8 %9 -Fibuild -FUbuild\hotfpc -obin\hotfpc.exe source\hotfpc.pas > build\hotfpc.log 2>&1
if errorlevel 1 (type build\hotfpc.log & exit /b 1)
echo built bin\hotfpc.exe
