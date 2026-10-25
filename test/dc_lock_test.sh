#!/usr/bin/env bash
# dc 的 cwd 互斥鎖自檢：用假的 opencode 驗鎖，不打上游。
# 斷言四件：1) 同 cwd 第二個 dc 不啟動  2) 不同 cwd 可併發
#          3) 孤兒鎖（pid 已死）會被清掉  4) DC_LOCK_HELD=1 不重複拿鎖
set -u
OC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘（10-19：Jev 閘封鎖時這些測試全掛）
mkdir -p "$T/bin" "$T/wa" "$T/wb" "$T/cfg/opencode"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DCQ_HOME="$T/q"                  # 鎖根目錄
export XDG_CONFIG_HOME="$T/cfg"         # 別碰使用者真的 opencode.json
# DC_NEGCTL=0：這些測試的 wo-verify 是 `exit 0` 的假貨，do-nothing 對照會當場中止派工。
# 負向對照本身由 dc_verify_gate_test.sh 驗。
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0
# 從 dcq 裡派出來時環境會帶著 DC_LOCK_HELD=1，dc 會整段跳過鎖 —— 那這個測試就測不到東西。
unset DC_LOCK_HELD
export TRACE="$T/trace"; : > "$TRACE"

# 假 opencode：記下 --dir 的值與進出
cat > "$T/bin/opencode" <<'EOF'
#!/usr/bin/env bash
d=""; prev=""
for a in "$@"; do [ "$prev" = "--dir" ] && d="$a"; prev="$a"; done
echo "IN $d" >> "$TRACE"
sleep "${FAKE_OC_SLEEP:-2}"
echo "OUT $d" >> "$TRACE"
EOF
chmod +x "$T/bin/opencode"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done
printf '# t\n' > "$T/t.md"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
runs_in() { grep -c "^IN $1\$" "$TRACE" | tr -d ' '; }
h="$(printf '%s' "$T/wa" | shasum | cut -c1-12)"

# 1) 同 cwd：第一個在跑時第二個要被拒（rc=75），且不得啟動 opencode
: > "$TRACE"
"$OC" "$T/t.md" "$T/wa" >"$T/a1.out" 2>&1 &
first=$!
until [ "$(runs_in "$T/wa")" -ge 1 ]; do sleep 0.2; done
"$OC" "$T/t.md" "$T/wa" >"$T/a2.out" 2>&1; rc2=$?
chk "同cwd第二個被拒 rc=75" "$rc2" "75"
grep -q "已被 pid" "$T/a2.out" || { echo "FAIL 拒絕訊息沒印持鎖者 pid"; fail=1; }
chk "同cwd只跑過一次 opencode" "$(runs_in "$T/wa")" "1"
wait "$first"
chk "持鎖者跑完 rc=0" "$?" "0"
# 鎖要在結束後釋放，否則下一次派工永遠拿不到（function + local 的 trap 就會爛在這）
chk "跑完鎖已釋放" "$([ -d "$DCQ_HOME/.cwdlock/$h" ] && echo held || echo free)" "free"

# 2) 不同 cwd 可併發
: > "$TRACE"
"$OC" "$T/t.md" "$T/wa" >/dev/null 2>&1 &
p1=$!
"$OC" "$T/t.md" "$T/wb" >/dev/null 2>&1 &
p2=$!
wait "$p1"; wait "$p2"
maxpar=$(awk '{if($1=="IN")c++;else c--; if(c>m)m=c} END{print m+0}' "$TRACE")
chk "不同cwd可併發(最大重疊)" "$maxpar" "2"

# 3) 孤兒鎖：pid 已死就清掉照跑
: > "$TRACE"
mkdir -p "$DCQ_HOME/.cwdlock/$h"
sh -c 'echo $$' > "$DCQ_HOME/.cwdlock/$h/pid"   # 這個 pid 立刻就死了
FAKE_OC_SLEEP=0 "$OC" "$T/t.md" "$T/wa" >"$T/orphan.out" 2>&1; rc3=$?
chk "孤兒鎖被清掉後照跑 rc=0" "$rc3" "0"
grep -q "孤兒鎖" "$T/orphan.out" || { echo "FAIL 沒說清掉孤兒鎖"; fail=1; }
chk "孤兒情境真的跑了 opencode" "$(runs_in "$T/wa")" "1"

# 4) DC_LOCK_HELD=1（dcq 已持鎖）：不重複拿，所以不會卡自己，也不能把 dcq 的鎖刪掉
: > "$TRACE"
mkdir -p "$DCQ_HOME/.cwdlock/$h"; echo $$ > "$DCQ_HOME/.cwdlock/$h/pid"
FAKE_OC_SLEEP=0 DC_LOCK_HELD=1 "$OC" "$T/t.md" "$T/wa" >"$T/held.out" 2>&1; rc4=$?
chk "DC_LOCK_HELD=1 不被自己的鎖擋 rc=0" "$rc4" "0"
chk "dcq 的鎖沒被 dc 刪掉" "$([ -d "$DCQ_HOME/.cwdlock/$h" ] && echo held || echo free)" "held"
rm -rf "$DCQ_HOME/.cwdlock/$h"

# 5) DC_LOCK_WAIT：持鎖者放開後要接上去跑
: > "$TRACE"
( FAKE_OC_SLEEP=2 "$OC" "$T/t.md" "$T/wa" >/dev/null 2>&1 ) &
held=$!
until [ "$(runs_in "$T/wa")" -ge 1 ]; do sleep 0.2; done
FAKE_OC_SLEEP=0 DC_LOCK_WAIT=20 "$OC" "$T/t.md" "$T/wa" >"$T/wait.out" 2>&1; rc5=$?
wait "$held"
chk "DC_LOCK_WAIT 等到鎖後跑完 rc=0" "$rc5" "0"
chk "等待組共跑兩次 opencode" "$(runs_in "$T/wa")" "2"

# 6) 被 SIGTERM（主 session 收工會殺整個行程群組）：dc 要立刻退出 143，
#    不得接著跑 wo-verify——半成品去驗收必 FAIL，會被 dcq 當成模型做錯、罰冷卻（2026-10-03 實證）。
: > "$TRACE"
printf '#!/bin/sh\ncase "$2" in --dry|--dump) ;; *) echo WV >> "$TRACE";; esac\nexit 0\n' > "$T/bin/wo-verify"
FAKE_OC_SLEEP=30 "$OC" "$T/t.md" "$T/wa" >"$T/term.out" 2>&1 &
tp=$!
until [ "$(runs_in "$T/wa")" -ge 1 ]; do sleep 0.2; done
pkill -TERM -P "$tp"; kill -TERM "$tp"
wait "$tp"; rc6=$?
chk "SIGTERM 後 dc rc=143" "$rc6" "143"
chk "SIGTERM 後沒跑 wo-verify" "$(grep -c '^WV$' "$TRACE" | tr -d ' ')" "0"
chk "SIGTERM 後鎖已釋放" "$([ -d "$DCQ_HOME/.cwdlock/$h" ] && echo held || echo free)" "free"

exit $fail
