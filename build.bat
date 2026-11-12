@echo off
rem Builds hotfpc on Windows (docs/build-system.md); build.sh does the same elsewhere.
rem
rem   build.bat [clean] [hotfpc] [tests] [--production] [-- fpc options]
rem
rem Targets, in the order given; none means hotfpc and tests:
rem   hotfpc   build\hotfpc.exe
rem   tests    hotfpc with its unit tests as build\tests\hotfpc-tests.exe, then runs them
rem   clean    removes build\
rem
rem fpc and fpcres may be batch files too, which is why they're run with call.
rem
rem Every compile first turns source\HotFPC.rc into source\HotFPC.res with fpcres, so hotfpc
rem carries the agent it was built with. The compiler is fpc on PATH or the FPC variable,
rem and fpcres is fpcres on PATH or the FPCRES variable. A development build turns on the
rem checks the source relies on: overflow, range, stack and object checks, and assertions.
rem --production builds with optimisation and without them. Options after -- go to every
rem compile, for example -- -Twin64 -Px86_64.
setlocal
cd /d "%~dp0"

if "%FPC%"=="" set "FPC=fpc"
if "%FPCRES%"=="" set "FPCRES=fpcres"
set "MODE_OPTIONS=-gl -B -Co -Cr -Ct -CR -Sa"
set "TARGETS="
set "OPTIONS="

:arguments
if "%~1"=="" goto run
if "%~1"=="--" goto options
if "%~1"=="--production" goto production
if "%~1"=="hotfpc" goto target
if "%~1"=="tests" goto target
if "%~1"=="clean" goto target
echo usage: build.bat [clean] [hotfpc] [tests] [--production] [-- fpc options] 1>&2
exit /b 2

:production
set "MODE_OPTIONS=-dPRODUCTION -O2 -Xs -B"
goto next

:target
set "TARGETS=%TARGETS% %~1"

:next
shift
goto arguments

:options
shift
if "%~1"=="" goto run
set "OPTIONS=%OPTIONS% %1"
goto options

:run
if "%TARGETS%"=="" set "TARGETS=hotfpc tests"
rem A failed step sets FAILED; the targets after it don't run.
set "FAILED="
for %%T in (%TARGETS%) do if not defined FAILED call :%%T
if defined FAILED exit /b 1
exit /b 0

:clean
if exist build rmdir /s /q build
exit /b 0

:hotfpc
call :embed_agent
if not defined FAILED call :compile hotfpc build ""
exit /b 0

:tests
call :embed_agent
if not defined FAILED call :compile hotfpc-tests build\tests -dHOTFPC_TESTS
if defined FAILED exit /b 0
echo run build\tests\hotfpc-tests.exe
build\tests\hotfpc-tests.exe
if errorlevel 1 (
  echo build: the unit tests failed 1>&2
  set "FAILED=1"
)
exit /b 0

:embed_agent
call "%FPCRES%" -of res -o source\HotFPC.res source\HotFPC.rc
if errorlevel 1 (
  echo build: fpcres could not compile source\HotFPC.rc 1>&2
  set "FAILED=1"
)
exit /b 0

rem :compile NAME DIRECTORY DEFINE
:compile
if not exist build\units\%1 mkdir build\units\%1
if not exist %2 mkdir %2
echo compile source\HotFPC.pas as %2\%1.exe
call "%FPC%" %MODE_OPTIONS% %~3 -FUbuild\units\%1 -o%2\%1.exe %OPTIONS% source\HotFPC.pas
if errorlevel 1 (
  echo build: source\HotFPC.pas did not compile 1>&2
  set "FAILED=1"
)
exit /b 0
