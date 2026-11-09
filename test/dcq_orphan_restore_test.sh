#!/usr/bin/env bash
# runner 被殺後的 worktree job：下一輪 run 要先還原 TASK=／CWD= 成原值（wt_restore_job 靠 TASK0=）再收 worktree，
# 否則 CWD 指著被 wt_gc 刪掉的 worktree（WO-F2 codex 第二輪：wt_setup 漏寫 TASK0 → 還原直接 return）。
# 做法：第一輪假 dc 把 running job 檔存下來就結束；把那份 job 放回 running/ 模擬被殺，再跑一輪，斷言 dc 拿到的 cwd 存在。
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
export TRACE="$T/trace" SAVE="$T/saved.job"; : > "$TRACE"

cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
cwd="$2"
echo "CWD $cwd $([ -d "$cwd" ] && echo exists || echo missing)" >> "$TRACE"
[ -f "$1" ] && grep -q '只是測試' "$1" || exit 2
echo 'TASK valid' >> "$TRACE"
if [ ! -e "$SAVE" ]; then
  cp "$DCQ_HOME"/running/*.job "$SAVE"
  id="$(basename "$cwd")"
  cp -R "$DCQ_HOME/.src/$id" "$SAVE.src"
fi
exit 0
EOF
chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done

git init -q "$T/repo"; git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf '# a\n只是測試\n' > "$T/a.md"
"$REPO/bin/dcq" add "$T/a.md" "$T/repo" >/dev/null 2>&1 || echo "add failed"
DCQ_MODELS="m1" DCQ_MODEL_MAX=1 "$REPO/bin/dcq" run -j 1 >"$T/run1.out" 2>&1

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
chk "第一輪在 worktree 跑" "$(grep -c "^CWD $DCQ_HOME/.wt/" "$TRACE")" "1"
chk "worktree job 留有 TASK0=" "$(grep -c '^TASK0=' "$SAVE" 2>/dev/null)" "1"

# 模擬被殺：復原當時尚未結案的 job 與原快照；舊 worktree 已收掉。
id="$(basename "$(ls "$DCQ_HOME"/done/*.job | head -1)" .job)"
cp -R "$SAVE.src" "$DCQ_HOME/.src/$id"
mkdir -p "$DCQ_HOME/running"; cp "$SAVE" "$DCQ_HOME/running/$(basename "$(ls "$DCQ_HOME"/done/*.job | head -1)")"
rm -f "$DCQ_HOME"/done/*.job
: > "$TRACE"
DCQ_MODELS="m1" DCQ_MODEL_MAX=1 "$REPO/bin/dcq" run -j 1 >"$T/run2.out" 2>&1
chk "重跑時 dc 拿到的 cwd 存在" "$(grep -c ' exists$' "$TRACE")" "1"
chk "重跑時工單存在且含原標記" "$(grep -c '^TASK valid$' "$TRACE")" "1"
chk "重跑時沒有指著已刪路徑" "$(grep -c ' missing$' "$TRACE")" "0"

[ "$fail" = 0 ] || { echo "--- run1 ---"; tail -20 "$T/run1.out"; echo "--- run2 ---"; tail -20 "$T/run2.out"; echo "--- saved ---"; cat "$SAVE"; }
[ "$fail" = 0 ] && echo PASS
exit $fail
