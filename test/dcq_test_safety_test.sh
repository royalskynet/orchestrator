#!/usr/bin/env bash
# 測試安全閘（WO-F）：mktemp 失敗時，被測腳本必須非 0 退出、不 cd、不清 repo。
# 假 mktemp（PATH 注入，回傳失敗）跑兩支；被測腳本用 $(dirname "$0") 定位（驗收會整包複製到暫存目錄再突變）。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
D="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)" || exit 1; [ -d "$T" ] || exit 1; cd "$T" || exit 1
trap '[ -n "$T" ] && [ -d "$T" ] && [ "$T" != "$R" ] && case "$T" in "${TMPDIR:-/tmp}"*|/tmp/*|/var/folders/*) rm -rf "$T" ;; esac' EXIT

fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got '$2' want '$3'"; fail=1; fi; }

mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/mktemp"; chmod +x "$T/bin/mktemp"

# worktree 的 .git 是要留著的檔案；monorepo 子目錄沒有 .git，就退查共同的 gitdir。
# 要在跑假 mktemp 前決定檢查對象，否則 worktree 的 .git 被刪後會誤落到還存在的 common dir。
if [ -e "$R/.git" ]; then
  GCK="$R/.git"
else
  GCK="$(git -C "$R" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [ -n "$GCK" ] || GCK="$(git -C "$R" rev-parse --git-common-dir 2>/dev/null)"
  case "$GCK" in /*) ;; *) GCK="$R/$GCK" ;; esac
fi

for f in dcq_isolation_test.sh dcq_models_job_test.sh; do
  [ -f "$D/$f" ] || { chk "找到 $f" no yes; continue; }
  before="$(git -C "$R" status --porcelain 2>/dev/null)"
  ( cd "$R" && PATH="$T/bin:$PATH" bash "$D/$f" ) >"$T/$f.out" 2>&1; rc=$?
  chk "${f}：mktemp 失敗時非 0 退出" "$([ "$rc" -ne 0 ] && echo yes)" "yes"
  chk "${f}：repo 檔案沒有多也沒有少" "$(git -C "$R" status --porcelain 2>/dev/null | sort | md5 -q 2>/dev/null || true)" \
    "$(printf '%s' "$before" | sort | md5 -q 2>/dev/null || true)"
  # 破除假 mktemp 之後不能有東西被刪：repo 還是同一份 git 樹
  chk "${f}：repo gitdir 還在" "$([ -e "$GCK" ] && echo yes)" "yes"
done

# 對照：真 mktemp 時隔離測試照常跑（證明上面非 0 是假 mktemp 造成的，不是本測試本身壞）
(cd "$R" && bash "$D/dcq_isolation_test.sh") >"$T/iso.out" 2>&1
chk "對照：真 mktemp 下 isolation 測試通過" "$?" "0"

[ "$fail" = 0 ] && echo PASS
exit "$fail"
