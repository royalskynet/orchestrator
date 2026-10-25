#!/usr/bin/env bash
# dc 的三道防假成功閘自檢（用假 opencode，不打上游）：
#   1) 評分器釘住：執行人改了驗收區塊 → wo-verify --pinned exit 3，dc 判 3
#   2) do-nothing 負向對照：驗收在未動工前就通過 → 不派工，exit 2
#   3) pass^k：DC_VERIFY_K 次全過才 PASS；第二次才失敗也要判 FAIL
# 用真的 wo-verify（這裡測的就是它和 dc 的接線），假的只有 opencode 與 deep-lint。
set -u
. "$(dirname "$0")/env.sh"
DC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
WV="$(cd "$(dirname "$0")/.." && pwd)/bin/wo-verify"   # repo 自帶那份，不走 PATH（PATH 上是 deepclaude 的）
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘（10-19：Jev 閘封鎖時這些測試全掛）
mkdir -p "$T/bin" "$T/w" "$T/cfg/opencode"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1
unset DC_LOCK_HELD
ln -s "$WV" "$T/bin/wo-verify"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"; chmod +x "$T/bin/deep-lint"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# 工單的驗收＝「$T/w/done 要存在」。未動工前必定失敗，做完才通過。
wo() { cat > "$T/t.md" <<EOF
# 任務
$1
## 驗收
\`\`\`bash
test -f "$T/w/done"
\`\`\`
EOF
}

# --- 1) 篡改偵測 -------------------------------------------------------------
# 假 opencode 扮演「改驗收讓它過關」的執行人：不做事，把驗收換成 true。
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
cat > "$T/t.md" <<'WOEOF'
# 任務
作弊
## 驗收
\`\`\`bash
true
\`\`\`
WOEOF
exit 0
EOF
chmod +x "$T/bin/opencode"
wo "要產生 done"
rm -f "$T/w/done"
"$DC" "$T/t.md" "$T/w" > "$T/1.out" 2>&1; rc=$?
chk "改驗收讓它過關 → rc=3" "$rc" "3"
grep -q '驗收區塊被改動' "$T/1.out" || { echo "FAIL 篡改訊息沒印出來"; sed -n '1,12p' "$T/1.out"; fail=1; }
grep -q 'wo-verify rc=3 (tamper)' "$T/1.out" || { echo "FAIL 沒看到 wo-verify 的 tamper 行"; fail=1; }

# --- 2) do-nothing 負向對照 --------------------------------------------------
# 誠實的執行人：真的做事。但工單要求的狀態已經存在 → 驗收未動工就過 → 不該派工。
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
echo RAN >> "$T/ran"
: > "$T/w/done"
exit 0
EOF
chmod +x "$T/bin/opencode"
wo "要產生 done"
: > "$T/w/done"; : > "$T/ran"
"$DC" "$T/t.md" "$T/w" > "$T/2.out" 2>&1; rc=$?
chk "驗收未動工就過 → rc=2" "$rc" "2"
chk "且沒派工（opencode 沒被叫）" "$(wc -l < "$T/ran" | tr -d ' ')" "0"
grep -q 'do-nothing 對照失敗' "$T/2.out" || { echo "FAIL 負向對照訊息沒印出來"; fail=1; }

# NEG-CONTROL: n/a 是逃生門：同一張工單加這行就放行，而且驗收照跑照過。
printf '\nNEG-CONTROL: n/a\n' >> "$T/t.md"
"$DC" "$T/t.md" "$T/w" > "$T/2b.out" 2>&1
chk "NEG-CONTROL: n/a 放行且驗收過 → rc=0" "$?" "0"
# DC_NEGCTL=0 也是逃生門
wo "要產生 done"; : > "$T/w/done"
DC_NEGCTL=0 "$DC" "$T/t.md" "$T/w" > "$T/2c.out" 2>&1
chk "DC_NEGCTL=0 放行 → rc=0" "$?" "0"

# --- 3) pass^k ---------------------------------------------------------------
# 誠實的執行人，從乾淨狀態做事：K 次驗收全過。
wo "要產生 done"
rm -f "$T/w/done"
DC_VERIFY_K=3 "$DC" "$T/t.md" "$T/w" > "$T/3.out" 2>&1
chk "做完事 K=3 全過 → rc=0" "$?" "0"
chk "驗收真的跑了 3 次" "$(grep -c '驗收第 ./3 次' "$T/3.out" | tr -d ' ')" "3"

# flaky 驗收：第一次過、第二次掛。單次驗收會放它過，pass^k 要抓到。
cat > "$T/t.md" <<EOF
# 任務
flaky
## 驗收
\`\`\`bash
n=\$(cat "$T/n" 2>/dev/null || echo 0); echo \$((n + 1)) > "$T/n"
test "\$n" -lt 1
\`\`\`
EOF
rm -f "$T/n"
cat > "$T/bin/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/bin/opencode"
DC_NEGCTL=0 DC_VERIFY_K=1 "$DC" "$T/t.md" "$T/w" > "$T/4a.out" 2>&1
chk "flaky 驗收 K=1 會被放過 → rc=0" "$?" "0"
rm -f "$T/n"
DC_NEGCTL=0 DC_VERIFY_K=2 "$DC" "$T/t.md" "$T/w" > "$T/4b.out" 2>&1; rc=$?
chk "flaky 驗收 K=2 被抓到 → rc!=0" "$([ "$rc" != 0 ] && echo yes || echo no)" "yes"
grep -q '第 2 次才失敗' "$T/4b.out" || { echo "FAIL 沒指出是第 2 次才失敗"; fail=1; }

# --- 4) 前置檢查憑證（DC_PREFLIGHT_DIR）----------------------------------------
# 同一張工單換模型時不再重跑整套驗收：第一次前置檢查全過時留下的評分器快照（pin）
# 留在 DC_PREFLIGHT_DIR 裡，後面換模型直接沿用（不重抽評分器、不重跑 lint 與負向對照）。
PFD="$T/pf"; mkdir -p "$PFD"
# 誠實的執行人：真的做事（做完驗收才會過）
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
: > "$T/w/done"
exit 0
EOF
chmod +x "$T/bin/opencode"

# 4a) 閘都過 → 目錄出現 pin
wo "要產生 done"
rm -f "$T/w/done"
DC_PREFLIGHT_DIR="$PFD" "$DC" "$T/t.md" "$T/w" > "$T/5a.out" 2>&1
chk "前置檢查通過 → rc=0" "$?" "0"
chk "前置檢查通過 → 目錄出現 pin" "$([ -f "$PFD/pin" ] && echo yes || echo no)" "yes"

# 4b) deep-lint 失敗 → 不留 pin（留下來下一次會拿沒驗過的評分器當基準）
rm -f "$PFD/pin"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/deep-lint"; chmod +x "$T/bin/deep-lint"
DC_PREFLIGHT_DIR="$PFD" "$DC" "$T/t.md" "$T/w" > "$T/5b.out" 2>&1; rc=$?
chk "deep-lint 失敗 → rc=1" "$rc" "1"
chk "deep-lint 失敗 → 不留 pin" "$([ -f "$PFD/pin" ] && echo yes || echo no)" "no"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"; chmod +x "$T/bin/deep-lint"

# 4c) 有憑證時不再跑 do-nothing 對照：工單驗收在動工前就會過也不中止
PFC="$T/pfc"; mkdir -p "$PFC"
wo "要產生 done"
"$WV" "$T/t.md" --dump > "$PFC/pin"      # 造出憑證（等同第一次嘗試留下的那份）
: > "$T/w/done"                            # 驗收未動工就過
cat > "$T/bin/opencode" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/bin/opencode"
DC_PREFLIGHT_DIR="$PFC" "$DC" "$T/t.md" "$T/w" > "$T/5c.out" 2>&1; rc=$?
chk "有憑證時不因 do-nothing 對照中止 → rc=0" "$rc" "0"
grep -q '沿用本單前置檢查憑證' "$T/5c.out" || { echo "FAIL 沒印沿用本單前置檢查憑證"; fail=1; }

# 4d) 有憑證時改驗收區塊照樣 exit 3（沿用第一次的評分器，不是改過的那份）
PFT="$T/pft"; mkdir -p "$PFT"
wo "要產生 done"
"$WV" "$T/t.md" --dump > "$PFT/pin"
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
cat > "$T/t.md" <<'WOEOF'
# 任務
作弊
## 驗收
\`\`\`bash
true
\`\`\`
WOEOF
exit 0
EOF
chmod +x "$T/bin/opencode"
DC_PREFLIGHT_DIR="$PFT" "$DC" "$T/t.md" "$T/w" > "$T/5d.out" 2>&1; rc=$?
chk "有憑證時改驗收 → rc=3" "$rc" "3"

[ "$fail" -eq 0 ] && { echo "RESULT PASS"; exit 0; } || { echo "RESULT FAIL"; exit 1; }
