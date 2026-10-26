#!/usr/bin/env bash
# dcq help：rc 0、有觀念總覽（派法四種、freepool 是閘不是層）、後面接 usage；無參數仍 rc 2 印 usage。
set -u
. "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/.."
fail=0
o="$(bin/dcq help 2>&1)"; rc=$?
[ "$rc" = 0 ] && echo "PASS help rc 0" || { echo "FAIL help rc=$rc"; fail=1; }
for n in 派o 派of 派os 派deep "freepool 不是一層" "dcq add <task.md 絕對路徑>"; do
  case "$o" in *"$n"*) echo "PASS help 有「${n}」" ;; *) echo "FAIL help 缺「${n}」"; fail=1 ;; esac
done
bin/dcq >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && echo "PASS 無參數 rc 2" || { echo "FAIL 無參數 rc=$rc"; fail=1; }
exit $fail
