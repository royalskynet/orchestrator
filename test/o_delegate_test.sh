#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export DEGUARD_OFF_FILE="$tmp/delegate-guard.off"
out="$(bin/o delegate status)"
[[ "$out" == *'delegate-guard: on'* ]]
out="$(bin/o delegate off)"
[[ "$out" == *'delegate-guard: off'* ]]
[ -e "$DEGUARD_OFF_FILE" ]
out="$(bin/o delegate status)"
[[ "$out" == *'delegate-guard: off'* ]]
out="$(bin/o delegate on)"
[[ "$out" == *'delegate-guard: on'* ]]
[ ! -e "$DEGUARD_OFF_FILE" ]
out="$(bin/o delegate bogus 2>&1)" && exit 1 || rc=$?
[ "$rc" = 2 ]
# symlink invocation must resolve back to repo scripts, not ~/.local/scripts
ln -sfn "$PWD/bin/o" "$tmp/o"
out="$("$tmp/o" delegate status)"
[[ "$out" == *'delegate-guard: on'* ]]
echo PASS
