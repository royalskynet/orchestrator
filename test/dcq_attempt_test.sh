#!/usr/bin/env bash
# issue #29：DCQ_ATTEMPT_AUTO=1 時 watchdog 用逐模型（逐難度）的建議上限判 slow；
# hint（預設）只在 dcq rank 顯示、watchdog 仍用全域 DCQ_ATTEMPT_MAX。
# 假 gaps.tsv 給 m1 建議上限 4s（12 筆 PASS 各 3s：p95=3 → round(3×1.25)=4，夾 [3,30]），
# 假 dc 每秒吐 tick（有輸出不觸發 stall）但不改檔連跑 8s。
# 暫存 $Q 與假 gaps.tsv，不碰真的 ~/.dcq；秒數用環境變數縮小，整支 60 秒內跑完。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_LOOP=0
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘檔
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default
export DCQ_AUTORANK=0 DCQ_POOLSYNC=0 DCQ_GO_STATE="$T/none.json"
export DCQ_STALL_S=99 DCQ_ATTEMPT_FLOOR=3 DCQ_ATTEMPT_MAX=30 DCQ_JOB_MAX=60 DCQ_SPIN_S=0 DCQ_PROGRESS_S=99
mkdir -p "$T/bin" "$T/w1" "$T/w2" "$DCQ_HOME/logs"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# 假 dc：sl* 工單的 m1 每秒 tick 一次連跑 8s（有輸出 → 不觸發 stall；不改檔 → 撞嘗試上限）；
# 其他模型 1s 收工過關
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
task="$1"; n="$(basename "$task" .md)"
echo "IN $n $DC_FREE_MODEL" >> "$TRACE"
case "$n:$DC_FREE_MODEL" in
  sl*:m1) for i in $(seq 8); do echo tick; sleep 1; done ;;
  *) sleep 1 ;;
esac
echo "OUT $n $DC_FREE_MODEL" >> "$TRACE"
exit 0
EOF
chmod +x "$T/bin/dc"
export TRACE="$T/trace"; : > "$TRACE"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"; chmod +x "$T/bin/deep-lint"
# 假驗收：這張工單有模型跑完（TRACE 有 OUT 行）才算過。被 watchdog 殺掉的沒有 OUT → 殺後驗收不過 → 換下一隻；
# 工單名 vok 一律過（殺後驗收通過的正向對照）。
cat > "$T/bin/wo-verify" <<'SH'
#!/bin/sh
case "$*" in *--dry*) exit 0 ;; esac
n="$(basename "$1" .md)"
[ "$n" = vok ] && exit 0
grep -q "^OUT $n " "$TRACE"
SH
chmod +x "$T/bin/wo-verify"
dcq() { "$R/bin/dcq" "$@"; }
mk() { printf '# %s\n' "$1" > "$T/$1.md"; dcq add "$T/$1.md" "$2" >/dev/null || echo "add failed: $1"; }
G="$DCQ_HOME/logs/gaps.tsv"
# m1 視窗 12 筆 PASS 各 3s（無難度欄＝每個難度都算）→ 建議上限 round(3×1.25)=4s
seed() { : > "$G"; local i; for i in $(seq 12); do printf '%s\tm1\t1\t0\texit\t3\n' "$(date +%F_%T)" >> "$G"; done; }

# 1) AUTO=1：假 dc 跑 8s 不改檔、建議上限 4s → m1 記 slow 被殺、換 m2 過關
seed; mk sl1 "$T/w1"
DCQ_MODELS="m1 m2" DCQ_ATTEMPT_AUTO=1 DCQ_ALLOWED_FAILS=1 dcq run -j 1 >"$T/a1.out" 2>&1
chk "AUTO=1 m1 沒跑完 8s 就被殺" "$(grep -c '^OUT sl1 m1' "$TRACE")" "0"
chk "AUTO=1 換 m2" "$(grep -c '^IN sl1 m2' "$TRACE")" "1"
chk "工單過關" "$(ls -1 "$DCQ_HOME/done" | grep -c sl1)" "1"
chk "gaps.tsv m1 記 slow" "$(awk -F'\t' '$2=="m1" && $5=="slow"' "$G" | wc -l | tr -d ' ')" "1"
grep -q 'watchdog: m1 slow' "$T/a1.out" || { echo "FAIL 沒印 watchdog slow"; fail=1; }

# 2) AUTO=hint：同樣種子與假 dc，watchdog 用全域 30s → m1 跑完 8s 過關、不換模型、不記 slow
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"; seed; mk sl2 "$T/w2"
DCQ_MODELS="m1 m2" DCQ_ATTEMPT_AUTO=hint dcq run -j 1 >"$T/a2.out" 2>&1
chk "hint m1 跑完沒被殺" "$(grep -c '^OUT sl2 m1' "$TRACE")" "1"
chk "hint 沒換 m2" "$(grep -c '^IN sl2 m2' "$TRACE")" "0"
chk "hint 無新 slow 記錄" "$(awk -F'\t' '$5=="slow"' "$G" | wc -l | tr -d ' ')" "0"

[ "$fail" = 0 ] && echo PASS
exit "$fail"
