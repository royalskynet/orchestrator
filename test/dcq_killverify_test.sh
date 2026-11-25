#!/usr/bin/env bash
# 殺後驗收（fm-harness#5／issue #13-3）：watchdog（stall/slow/spin/loop/budget）殺掉嘗試後
# 用同一份 pin 跑 wo-verify，過了就記 PASS 不換模型——模型卡死不等於沒交件。
# 假 dc：先寫 WORKED（已交件）再睡死 → stall 殺掉 → 殺後驗收過 → 進 done/、不換 m2。
# 變異檢查：把 jobmax_verify 呼叫的 if 改成恆假，此案例必須失敗（驗 test 真的咬這條分支）。
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

printf '#!/bin/sh\ncd "$2" || exit 2\n: > WORKED\nsleep 60\n' > "$T/bin/dc"; chmod +x "$T/bin/dc"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"; chmod +x "$T/bin/deep-lint"
printf '#!/bin/sh\ncase "$2" in --dry*) exit 0;; esac\ntest -f WORKED\n' > "$T/bin/wo-verify"; chmod +x "$T/bin/wo-verify"

mkdir -p "$T/wd"; printf '# kv1\n' > "$T/w.md"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

run_case() {  # $1=dcq 路徑 $2=queue 子目錄
  export DCQ_HOME="$T/$2"; mkdir -p "$DCQ_HOME"
  "$1/dcq" add "$T/w.md" "$T/wd" >/dev/null 2>&1
  DCQ_MODELS="m1 m2" DCQ_STALL_S=3 DCQ_SPIN_S=0 DCQ_ATTEMPT_MAX=60 DCQ_ALLOWED_FAILS=99 \
    "$1/dcq" run -j 1 >"$T/$2.out" 2>&1
}

run_case "$REPO/bin" q1
chk "工單進 done/" "$(ls "$T/q1/done"/*.job 2>/dev/null | wc -l | tr -d ' ')" "1"
chk "殺後驗收訊息" "$(grep -c 'watchdog stall 殺掉，但驗收通過' "$T/q1.out")" "1"
chk "只跑一隻模型（沒換 m2）" "$(ls "$T/q1"/logs/*.out 2>/dev/null | wc -l | tr -d ' ')" "1"

# 變異：殺後驗收改成恆假 → 同樣場景不能 PASS（要換 m2 再死一次或記失敗）
M="$(mktemp -d)"; mkdir -p "$M/bin"
for f in "$REPO/bin/"*; do [ "$(basename "$f")" = dcq ] || ln -s "$f" "$M/bin/"; done
cp "$REPO/bin/dcq" "$M/bin/dcq"
perl -i -pe 's/if jobmax_verify "\$task" "\$cwd" "\$DC_PREFLIGHT_DIR"; then/if false; then/g' "$M/bin/dcq"
grep -c 'if false; then' "$M/bin/dcq" | grep -q '^[1-9][0-9]*$' || { echo "FAIL 變異沒改到行"; fail=1; }
run_case "$M/bin" q2
chk "變異版沒有殺後 PASS 訊息" "$(grep -c 'watchdog stall 殺掉，但驗收通過' "$T/q2.out")" "0"
chk "變異版工單沒進 done/" "$(ls "$T/q2/done"/*.job 2>/dev/null | wc -l | tr -d ' ')" "0"

[ "$fail" = 0 ] && echo "PASS dcq_killverify_test" || echo "FAIL dcq_killverify_test"
exit "$fail"
