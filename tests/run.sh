#!/bin/bash
# Every test in here runs under a plain Lua interpreter: no Luanti, no server.
set -u
cd "$(dirname "$0")"
LUA=${LUA:-lua5.1}
fail=0
for t in test_*.lua; do
    echo "== $t"
    "$LUA" "$t" || fail=1
    echo
done
exit $fail
