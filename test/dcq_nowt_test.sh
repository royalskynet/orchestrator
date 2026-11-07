#!/usr/bin/env bash
# dcq 逐張關 worktree（NOWT=1，2026-11-07）＋ dcq status 的 sed 替換欄修復。
# 背景：產出寫在 cwd 內被 .gitignore 擋掉的路徑時，worktree 裡寫完、merge 回主 repo 帶不回
# （worktree 一刪產出就沒了）。入列時 DCQ_WORKTREE=0 記成工單的 NOWT=1，該張照序列跑。
# 假 dc 不打上游。斷言：
#   (a) DCQ_WORKTREE=0 dcq add 的 job 檔含 NOWT=1
#   (b) 這張跑時 runner 輸出含「同目錄序列（工單指定 DCQ_WORKTREE=0）」且不含「worktree 模式」，也沒開 worktree
#   (c) 沒帶旗標的工單照舊走 worktree 模式
#   (d) dcq status <done 的 id> 的 stderr 不含 sed 的 unescaped newline 錯
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
export TRACE="$T/trace"; : > "$TRACE"

cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
task="$1"; cwd="$2"; n="$(basename "$task" .md)"
echo "IN $n $cwd $(date +%s)" >> "$TRACE"
echo "OUT $n $cwd $(date +%s)" >> "$TRACE"
exit 0
EOF
chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done

mkrepo() { git init -q "$1"; git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
mkrepo "$T/repo"
printf '# a\n' > "$T/a.md"
printf '# b\n' > "$T/b.md"

# (a) 入列時記 NOWT=1
ida="$(DCQ_WORKTREE=0 "$REPO/bin/dcq" add "$T/a.md" "$T/repo" 2>/dev/null)"
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
fail=0
chk "DCQ_WORKTREE=0 入列的 job 檔含 NOWT=1" "$(grep -q '^NOWT=1$' "$DCQ_HOME/pending/$ida.job" && echo yes)" "yes"

# (b) 該張跑時不切 worktree：log 說「工單指定 DCQ_WORKTREE=0」，直接在 cwd 跑
DCQ_MODELS="m1" "$REPO/bin/dcq" run -j 2 >"$T/run1.out" 2>&1
chk "runner 說明逐張關 worktree 的原因" "$(grep -c '同目錄序列（工單指定 DCQ_WORKTREE=0）' "$T/run1.out")" "1"
chk "runner 沒開 worktree 模式" "$(grep -c 'worktree 模式' "$T/run1.out")" "0"
chk "跑在原 cwd（沒進 .wt/）" "$(grep '^IN a ' "$TRACE" | awk '{print $3}')" "$T/repo"
chk "沒留下 worktree" "$(git -C "$T/repo" worktree list | wc -l | tr -d ' ')" "1"

# (c) 沒帶旗標照舊走 worktree 模式
idb="$("$REPO/bin/dcq" add "$T/b.md" "$T/repo" 2>/dev/null)"
chk "沒帶旗標的 job 檔沒有 NOWT" "$(grep -c '^NOWT=' "$DCQ_HOME/pending/$idb.job")" "0"
: > "$TRACE"
DCQ_MODELS="m1" "$REPO/bin/dcq" run -j 2 >"$T/run2.out" 2>&1
chk "沒帶旗標走 worktree 模式" "$(grep -c 'worktree 模式' "$T/run2.out")" "1"

# (d) dcq status 的 sed 修好：stderr 沒有 unescaped newline
"$REPO/bin/dcq" status "$ida" >"$T/st.out" 2>"$T/st.err"
chk "status stderr 沒有 sed 錯" "$(grep -c 'unescaped newline' "$T/st.err")" "0"

[ "$fail" = 0 ] || { echo "--- run1.out ---"; cat "$T/run1.out"; echo "--- run2.out ---"; cat "$T/run2.out"; echo "--- st.err ---"; cat "$T/st.err"; }
[ "$fail" = 0 ] && echo PASS
exit $fail
