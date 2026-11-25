#!/usr/bin/env bash
# bin/dc SIGTERM 壓力測試（issue #32）：重複 dc_lock_test.sh §6 的情境——
# 假 opencode 睡著後 pkill -TERM -P + kill -TERM，每次限 15 秒。
# 斷言兩件：1) dc 要在 15 秒內退出  2) rc 必須是 143（bash 3.2 會丟 trap，rc=1 也算 FAIL）。
# 卡住的一律先 kill -9 清場再以非 0 結束。次數由 DC_TERM_STRESS_N 控制，預設 60 秒內跑完。
set -u
# env.sh 會清掉所有 DC* 變數，次數要在 source 之前先接住
N="${DC_TERM_STRESS_N:-20}"
. "$(dirname "$0")/env.sh"
OC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
mkdir -p "$T/bin" "$T/wa" "$T/cfg/opencode"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0
unset DC_LOCK_HELD
export TRACE="$T/trace"

# 假 opencode 同 dc_lock_test §6：進場記一行、睡 30 秒
cat > "$T/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo "IN" >> "$TRACE"
sleep "${FAKE_OC_SLEEP:-30}"
echo "OUT" >> "$TRACE"
EOF
chmod +x "$T/bin/opencode"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done
printf '# t\n' > "$T/t.md"

fail=0
i=0
while [ "$i" -lt "$N" ]; do
  i=$((i + 1))
  : > "$TRACE"
  FAKE_OC_SLEEP=30 "$OC" "$T/t.md" "$T/wa" >"$T/dc.out" 2>&1 &
  tp=$!
  until grep -q '^IN$' "$TRACE" 2>/dev/null; do sleep 0.02; done
  # kill 時機加抖動蓋到不同相位：等 IN 後的偏移、以及 pkill 與 kill 之間的 gap
  # （TERM 落在「子程序剛被殺、bash 正要往下走」的窗口時 bash 3.2 會丟 trap）
  off=$(awk -v i="$i" 'BEGIN{printf "%.2f", ((i%10)*0.14)}')
  gap=$(awk -v i="$i" 'BEGIN{printf "%.2f", ((i%4)*0.06)}')
  sleep "$off"
  pkill -TERM -P "$tp" 2>/dev/null
  [ "$gap" = "0.00" ] || sleep "$gap"
  kill -TERM "$tp" 2>/dev/null
  deadline=$(( $(date +%s) + 15 )); st=""
  while :; do
    st=$(ps -o stat= -p "$tp" 2>/dev/null | tr -d ' ')
    case "$st" in ""|*Z*) break ;; esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "FAIL 第 ${i} 次：dc 收到 SIGTERM 後 15 秒沒退出（stat=${st}, off=${off} gap=${gap}）"
      pkill -9 -P "$tp" 2>/dev/null; kill -9 "$tp" 2>/dev/null
      pkill -f "$T/bin/opencode" 2>/dev/null
      fail=1; break 2
    fi
    sleep 0.05
  done
  wait "$tp" 2>/dev/null; rc=$?
  if [ "$rc" != 143 ]; then
    echo "FAIL 第 ${i} 次：SIGTERM 後 dc rc=${rc} ，應為 143（off=${off} gap=${gap}）"
    fail=1; break
  fi
done

[ "$fail" = 0 ] && echo "PASS（${i} 次 SIGTERM 全部 15 秒內 rc=143）"
exit "$fail"
