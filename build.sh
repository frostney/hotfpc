#!/bin/sh
# Builds hotfpc (docs/build-system.md); build.bat does the same on Windows.
#
#   ./build.sh [clean] [hotfpc] [tests] [--production] [-- fpc options]
#
# Targets, in the order given; none means hotfpc and tests:
#   hotfpc   build/hotfpc (build/hotfpc.exe for a Windows target)
#   tests    hotfpc with its unit tests as build/tests/hotfpc-tests, then runs them
#   clean    removes build/
#
# Every compile first turns source/HotFPC.rc into source/HotFPC.res with fpcres, so hotfpc
# carries the agent it was built with. The compiler is fpc on PATH or $FPC, and fpcres is
# fpcres on PATH or $FPCRES. A development build turns on the checks the source relies on:
# overflow, range, stack and object checks, and assertions. --production builds with
# optimisation and without them. Options after -- go to every compile, for example
# -- -Twin64 -Px86_64.
set -eu
cd "$(dirname "$0")"

FPC=${FPC:-fpc}
FPCRES=${FPCRES:-fpcres}
usage="usage: ./build.sh [clean] [hotfpc] [tests] [--production] [-- fpc options]"
development_options="-gl -B -Co -Cr -Ct -CR -Sa"
production_options="-dPRODUCTION -O2 -Xs -B"

targets=
mode_options=$development_options
while [ $# -gt 0 ]; do
  case $1 in
    --) shift; break ;;
    --production) mode_options=$production_options ;;
    hotfpc | tests | clean) targets="$targets $1" ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$targets" ] || targets="hotfpc tests"

# A Windows target, from the last -T option, or this system's own.
suffix=
case $(uname -s) in MINGW* | MSYS* | CYGWIN*) suffix=.exe ;; esac
for option in "$@"; do
  case $option in
    -Twin*) suffix=.exe ;;
    -T*) suffix= ;;
  esac
done

embed_agent() {
  "$FPCRES" -of res -o source/HotFPC.res source/HotFPC.rc
}

# compile NAME DIRECTORY [DEFINE] -- fpc options
compile() {
  name=$1 directory=$2 define=$3
  shift 3
  mkdir -p "build/units/$name" "$directory"
  echo "compile source/HotFPC.pas as $directory/$name$suffix"
  # shellcheck disable=SC2086 # the mode's options are separate words
  "$FPC" $mode_options $define "-FUbuild/units/$name" "-o$directory/$name$suffix" "$@" source/HotFPC.pas \
    || { echo "build: source/HotFPC.pas did not compile" >&2; exit 1; }
}

for target in $targets; do
  case $target in
    clean)
      rm -rf build
      ;;
    hotfpc)
      embed_agent
      compile hotfpc build "" "$@"
      ;;
    tests)
      embed_agent
      compile hotfpc-tests build/tests -dHOTFPC_TESTS "$@"
      echo "run build/tests/hotfpc-tests$suffix"
      "build/tests/hotfpc-tests$suffix" || { echo "build: the unit tests failed" >&2; exit 1; }
      ;;
  esac
done
