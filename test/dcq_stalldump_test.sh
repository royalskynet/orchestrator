#!/usr/bin/env bash
# issue #33：stall_dump 用 opencode session list 找 session，opencode 存的 directory 是
# 解析過符號連結的實體路徑（macOS /tmp → /private/tmp）；cwd 給符號連結路徑也要找得到，
# 找到才有 stall.json 與 stalls.tsv 診斷行。只用 mktemp 暫存與假 opencode，不碰 ~/.dcq。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_STALL_S=2 DCQ_TOK_POLL_S=1 DCQ_LOOP=0 DCQ_SPIN_S=0
export DCQ_ATTEMPT_MAX=99 DCQ_TOK_MAX=0 DCQ_COST_MAX=0 DCQ_JOB_TOK_MAX=0
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘檔
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL=""
export DCQ_AUTORANK=0 DCQ_POOLSYNC=0 DCQ_GO_STATE="$T/none.json"
mkdir -p "$T/bin" "$T/real"; ln -s "$T/real" "$T/link"   # link＝工單 cwd（符號連結路徑）
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# 假 dc：不輸出也不改檔，睡到被 stall watchdog 殺掉（gap≥DCQ_STALL_S）
printf '#!/bin/sh\nsleep 60\n' > "$T/bin/dc"
# 假 opencode：session list 照真實行為回「實體路徑」（stall_dump 先 cd cwd，pwd -P 即解析後的路徑）；
# export 回有輸出的 assistant 訊息（不觸發 zero_output 上游判定）
cat > "$T/bin/opencode" <<'SH'
#!/bin/sh
case "$1" in
  session) printf '[{"id":"ses_fake","directory":"%s","created":%s}]\n' "$(pwd -P)" "$(date +%s)000" ;;
  export)  printf '%s\n' '{"messages":[{"info":{"role":"assistant","tokens":{"output":5},"time":{"completed":1}},"parts":[{"type":"text","text":"x"}]}]}' ;;
esac
SH
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"
printf '#!/bin/sh\ncase "$*" in *--dry*) exit 0 ;; esac\nexit 1\n' > "$T/bin/wo-verify"   # 殺後驗收不過 → 照樣記 stall
chmod +x "$T/bin/"*

printf '# s\n' > "$T/s.md"
"$R/bin/dcq" add "$T/s.md" "$T/link" >/dev/null
DCQ_MODELS="m1" "$R/bin/dcq" run -j 1 > "$T/run.out" 2>&1

chk "stalls.tsv 多一行" "$(grep -c . "$DCQ_HOME/logs/stalls.tsv" 2>/dev/null || echo 0)" 1
chk "stalls.tsv 記到 session" "$(awk -F'\t' '{print $3}' "$DCQ_HOME/logs/stalls.tsv" 2>/dev/null)" "ses_fake"
chk "stall.json 有留下" "$(ls "$DCQ_HOME"/logs/*.stall.json 2>/dev/null | wc -l | tr -d ' ')" "1"
grep -q 'stall_dump m1 ses_fake' "$T/run.out" || { echo "FAIL stderr 缺 stall_dump 摘要"; fail=1; }
chk "gaps.tsv 記 stall" "$(awk -F'\t' '$5=="stall"{n++} END{print n+0}' "$DCQ_HOME/logs/gaps.tsv")" 1

[ "$fail" = 0 ] && echo PASS
exit "$fail"
