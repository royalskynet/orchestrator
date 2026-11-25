#!/usr/bin/env bash
# oc_git_cache_gc（issue #13-2，對應 fm-harness#4）：repo 的 .git/opencode 是 40B
# project-id 快取，worktree 會解析到同一顆、舊 schema 撞 no such column: project_id 全滅；
# wt_setup 建 worktree 時要清掉讓 opencode 重建。
# .git/opencode 目前只見過檔案型（2026-11-25 本機掃 ~/.dcq ~/dev：5 個 repo 全是 -type f、
# 零目錄）；目錄型若是別的 schema 不能 rm -rf 亂砍，所以 gc 的 [ -f ] 是有意的。
# 假 dc 打 WORKED 標記後結束；不打上游。
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export DCQ_HOME="$T/q"; mkdir -p "$T/bin"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default

printf '#!/bin/sh\ncd "$2" && : > WORKED\n' > "$T/bin/dc"; chmod +x "$T/bin/dc"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"; chmod +x "$T/bin/deep-lint"
printf '#!/bin/sh\ncase "$2" in --dry*) exit 0;; esac\ntest -f WORKED\n' > "$T/bin/wo-verify"; chmod +x "$T/bin/wo-verify"

git init -q "$T/repo"; git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'x' > "$T/repo/.git/opencode"   # project-id 快取

printf '# kv\n' > "$T/w.md"
"$REPO/bin/dcq" add "$T/w.md" "$T/repo" >/dev/null 2>&1
DCQ_MODELS=m1 "$REPO/bin/dcq" run -j 1 >"$T/run.out" 2>&1

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
chk ".git/opencode 快取被清" "$([ -f "$T/repo/.git/opencode" ]; echo $?)" "1"
chk "有清快取訊息" "$(grep -c '清掉 .git/opencode' "$T/run.out")" "1"
# 快取不在時再跑一輪不報錯、訊息數不變
printf '# kv2\n' > "$T/w2.md"
"$REPO/bin/dcq" add "$T/w2.md" "$T/repo" >/dev/null 2>&1
DCQ_MODELS=m1 "$REPO/bin/dcq" run -j 1 >>"$T/run.out" 2>&1 || true
chk "無快取第二輪不收斂錯（訊息仍 1 次）" "$(grep -c '清掉 .git/opencode' "$T/run.out")" "1"

[ "$fail" = 0 ] && echo "PASS dcq_occache_test" || echo "FAIL dcq_occache_test"
exit "$fail"
