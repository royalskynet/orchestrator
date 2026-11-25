#!/usr/bin/env bash
# F3 空回合續做（dc）：exit 0、工作區無改動、session 無工具呼叫 → 同模型續做 1 次
#   1) 空轉執行人 → 被叫 2 次、印「空回合」，第二次還是空 → 走既有驗收失敗
#   2) 第二次才做事的執行人 → 續做後驗收過 → rc=0
#   3) 第一次就做事 → 只叫 1 次
#   4) DC_EMPTY_REDO=0 → 空轉也只叫 1 次
set -u
. "$(dirname "$0")/env.sh"
DC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
WV="$(cd "$(dirname "$0")/.." && pwd)/bin/wo-verify"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
mkdir -p "$T/bin" "$T/w" "$T/cfg/opencode"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1
export DCQ_OC_DB="$T/no-such.db"   # 不碰真 opencode db；查不到＝工具數 0
unset DC_LOCK_HELD
ln -s "$WV" "$T/bin/wo-verify"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"; chmod +x "$T/bin/deep-lint"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# 工單驗收＝$T/w/done 要存在（未動工必敗）
cat > "$T/t.md" <<EOF
# 任務
產生 done
## 驗收
\`\`\`bash
test -f "$T/w/done"
\`\`\`
EOF

# --- 1) 空轉執行人：什麼都不做 ----------------------------------------------
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
echo CALL >> "$T/calls"
exit 0
EOF
chmod +x "$T/bin/opencode"
rm -f "$T/w/done" "$T/calls"
"$DC" "$T/t.md" "$T/w" > "$T/1.out" 2>&1; rc=$?
chk "空轉 → 被叫 2 次" "$(wc -l < "$T/calls" | tr -d ' ')" "2"
chk "空轉 → 驗收不過 rc!=0" "$([ "$rc" != 0 ] && echo yes || echo no)" "yes"
grep -q '空回合（工作區無改動、無工具呼叫），同一模型續做 1 次' "$T/1.out" \
  || { echo "FAIL 沒印空回合續做訊息"; tail -8 "$T/1.out"; fail=1; }

# --- 2) 第二次才做事的執行人 -------------------------------------------------
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
echo CALL >> "$T/calls"
n=\$(wc -l < "$T/calls" | tr -d ' ')
[ "\$n" -ge 2 ] && : > "$T/w/done"
exit 0
EOF
chmod +x "$T/bin/opencode"
rm -f "$T/w/done" "$T/calls"
"$DC" "$T/t.md" "$T/w" > "$T/2.out" 2>&1; rc=$?
chk "第二次才做 → 被叫 2 次" "$(wc -l < "$T/calls" | tr -d ' ')" "2"
chk "第二次才做 → 驗收過 rc=0" "$rc" "0"

# --- 3) 第一次就做事：不算空回合，不續做 ------------------------------------
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
echo CALL >> "$T/calls"
: > "$T/w/done"
exit 0
EOF
chmod +x "$T/bin/opencode"
rm -f "$T/w/done" "$T/calls"
"$DC" "$T/t.md" "$T/w" > "$T/3.out" 2>&1; rc=$?
chk "第一次就做 → 只叫 1 次" "$(wc -l < "$T/calls" | tr -d ' ')" "1"
chk "第一次就做 → rc=0" "$rc" "0"
! grep -q '空回合' "$T/3.out" || { echo "FAIL 有做事卻印空回合"; fail=1; }

# --- 4) DC_EMPTY_REDO=0：空轉不續做 ------------------------------------------
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
echo CALL >> "$T/calls"
exit 0
EOF
chmod +x "$T/bin/opencode"
rm -f "$T/w/done" "$T/calls"
DC_EMPTY_REDO=0 "$DC" "$T/t.md" "$T/w" > "$T/4.out" 2>&1; rc=$?
chk "DC_EMPTY_REDO=0 → 只叫 1 次" "$(wc -l < "$T/calls" | tr -d ' ')" "1"
chk "DC_EMPTY_REDO=0 → 驗收不過 rc!=0" "$([ "$rc" != 0 ] && echo yes || echo no)" "yes"

[ "$fail" -eq 0 ] && { echo "RESULT PASS"; exit 0; } || { echo "RESULT FAIL"; exit 1; }
