#!/bin/sh
# build.sh [FPC [options]]: builds bin/hotfpc with the given compiler (default: fpc).
# Options go to the compile of hotfpc itself, e.g. -Twin64 -Px86_64 to build bin/hotfpc.exe.
# The agent's source is embedded first (source/embed.pas, built for this machine).
set -eu
cd "$(dirname "$0")"
FPC=${1:-fpc}
[ $# -gt 0 ] && shift
mkdir -p build/embed build/hotfpc bin
"$FPC" -FUbuild/embed -obuild/embed/embed source/embed.pas > build/embed.log 2>&1 || { cat build/embed.log; exit 1; }
build/embed/embed source/hotagent.pas build/agentsource.inc
out=bin/hotfpc
case " $* " in *" -Twin"*) out=bin/hotfpc.exe ;; esac
"$FPC" -Fibuild -FUbuild/hotfpc -o"$out" "$@" source/hotfpc.pas > build/hotfpc.log 2>&1 || { cat build/hotfpc.log; exit 1; }
grep -E "Warning|lines compiled" build/hotfpc.log | grep -v "deprecated" || true
echo "built $out"
