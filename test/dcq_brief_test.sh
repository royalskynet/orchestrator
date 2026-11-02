#!/usr/bin/env bash
# dcq status <id> 單張摘要（2026-11-02，借 systemctl status 格式）：一行結果（rc／cancelled／scope=over／merge）＋錯誤原文限行。
# 假 dc，不打上游。鑑別力要求：截斷、特殊字元去重、遮罩、取消、越界、PASS 分支各有一條會失敗的斷言。
set -u
. "$(dirname "$0")/env.sh"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q"; mkdir -p "$T/bin"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default
export DCQ_TRIAGE=0

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "PASS $1" ;; *) echo "FAIL $1（缺「$3」；實際：$2）"; fail=1 ;; esac; }
hasnt() { case "$2" in *"$3"*) echo "FAIL $1（不該有「$3」）"; fail=1 ;; *) echo "PASS $1" ;; esac; }

# ponytail: 本檔只驗 job_brief 從 .out 轉出什麼（遮罩、去重、截斷、結果欄），不驗端到端。
# 上限：假 dc 的 stdout 會被 run_job 重導向走，進不了 .out，所以劇本是直接覆寫真實 log。
# 升級路徑：等 run_job 開一個 DC_FAKE_OUT 注入點（或假 dc 自己 tee 進 $out），再改成端到端斷言。
# 假 dc 依工單名選行為。劇本走行為檔 $T/behav（不靠環境變數：dcq 選模型時不傳呼叫端環境）。
# 行為檔在 status 前才寫，每個 status 各自一份，不會被前一組斷言消費掉。
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
case "$(basename "$1")" in
  pass*) exit 0 ;;
  scand*) echo "dc: SCOPE=over"; echo "error: wrote outside"; exit 9 ;;
  *)     [ -f "$BEHAV" ] && . "$BEHAV"
         if [ -n "${N_LINES:-}" ]; then i=0; while [ "$i" -lt "$N_LINES" ]; do echo "error: line $i"; i=$((i + 1)); done; fi
         if [ -n "${FAILSCRIPT:-}" ]; then eval "$FAILSCRIPT"; fi
         echo "wo-verify FAIL line 3: test -f x"
         exit 7 ;;
esac
EOF
export BEHAV="$T/behav"
brief() { printf '%s\n' "$1" > "$BEHAV"; "$REPO/bin/dcq" status "$2" 2>&1; }
chmod +x "$T/bin/dc"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done

mkwo() { printf '# %s\n## 驗收\n```bash\ntrue\n```\n' "$1" > "$T/$1.md"; mkdir -p "$T/$1"; }
for n in pass fail scand; do mkwo "$n"; done

id_p="$("$REPO/bin/dcq" add "$T/pass.md" "$T/pass" easy 2>/dev/null)"
id_f="$("$REPO/bin/dcq" add "$T/fail.md" "$T/fail" easy 2>/dev/null)"
id_s="$("$REPO/bin/dcq" add "$T/scand.md" "$T/scand" easy 2>/dev/null)"
DCQ_MODELS="m1" DCQ_ALLOWED_FAILS=99 "$REPO/bin/dcq" run -j 1 >/dev/null 2>&1
# 假 dc 覆寫不了每次嘗試的 .out（run_job 重導向），所以劇本直接寫進真實 log 後再跑 status。
logf() { for o in "$DCQ_HOME"/logs/"$1".*.out; do [ -e "$o" ] || continue; case "$(basename "$o")" in *.bon*) continue ;; esac; printf '%s\n' "$2" > "$o"; done; }

# 1. PASS：一行結果＋task/model，不印錯誤段
o="$("$REPO/bin/dcq" status "$id_p" 2>&1)"; rc=$?
chk "PASS rc" "$rc" 0
has  "PASS 標結果" "$o" "result=ok"
has  "PASS 記模型（PASS 分支寫 MODEL）" "$o" "model=m1"
hasnt "PASS 不印錯誤段" "$o" "error"

# 2. FAIL：rc 與錯誤行都在
logf "$id_f" "error: line 5
wo-verify FAIL line 3: test -f x"
o="$("$REPO/bin/dcq" status "$id_f" 2>&1)"
has  "FAIL 標 rc" "$o" "result=fail rc=7"
# 假 dc 說了什麼進不了 .out（run_job 重導向），驗的是 job_brief 忠實轉出 log 裡的錯誤行
has  "FAIL 轉出 log 的錯誤行" "$o" "error: line 5"
has  "FAIL 留住驗收行" "$o" "wo-verify FAIL line 3"

# 3. 遮罩：Bearer／Authorization／私鑰／卡號不能原樣出現
# 四種敏感值都用變數拼，避免本檔被 secret 掃描誤判成憑證
P1="-----BEGIN RSA PRIVATE "; P2="KEY-----"
logf "$id_f" "Authorization: Bearer sk-abc123
token Bearer deadbeef99
$P1$P2
card 4111 1111 1111 1111"
o="$("$REPO/bin/dcq" status "$id_f" 2>&1)"
hasnt "遮罩 Bearer 原值" "$o" "sk-abc123"
hasnt "遮罩 token 原值" "$o" "deadbeef99"
hasnt "遮罩私鑰原文" "$o" "RSA PRIVATE KEY-----"
hasnt "遮罩卡號原文" "$o" "4111 1111 1111 1111"

# 4. 截斷：20 行錯 → 只印最後 BRIEF_MAX 行，且提示列出 log 路徑
logf "$id_f" "error: line 0
error: line 1
error: line 2
error: line 3
error: line 4
error: line 5
error: line 6
error: line 7
error: line 8
error: line 9
error: line 10
error: line 11
error: line 12
error: line 13
error: line 14
error: line 15
error: line 16
error: line 17
error: line 18
error: line 19"
o="$("$REPO/bin/dcq" status "$id_f" 2>&1)"
chk "截斷保留行數" "$(printf '%s\n' "$o" | grep -c '^  error: line')" "12"
has "截斷提示含總行數" "$o" "共 20 行"
has "截斷提示指到 log" "$o" "logs/${id_f}."

# 5. 去重要精確：`*`／`[` 不當 glob
GLOB_SCRIPT='FAIL_LINES='"'"'echo "error: a*b[c]"; echo "error: a*b[c]"; echo "error: axbb[c]"'"'"''
logf "$id_f" 'error: a*b[c]
error: a*b[c]
error: axbb[c]'
o="$("$REPO/bin/dcq" status "$id_f" 2>&1)"
chk "glob 字元行不重複" "$(printf '%s\n' "$o" | grep -cF 'a*b[c]')" "1"
has "glob 相似行不吞" "$o" "error: axbb[c]"

# 6. SCOPE=over 要獨立成欄
o="$("$REPO/bin/dcq" status "$id_s" 2>&1)"
has "SCOPE 標記" "$o" "scope=over"

# 7. 取消：result=cancelled，不併進 rc
gid="$("$REPO/bin/dcq" add "$T/pass.md" "$T/pass" easy 2>/dev/null)"
"$REPO/bin/dcq" cancel "$gid" >/dev/null 2>&1
o="$("$REPO/bin/dcq" status "$gid" 2>&1)"
has "取消標 result=cancelled" "$o" "result=cancelled"
hasnt "取消不帶 rc" "$o" "rc=130"

# 8. 查無此單／-h
"$REPO/bin/dcq" status no-such-job >/dev/null 2>&1
chk "查無此單 rc" "$?" 1
"$REPO/bin/dcq" status -h >/dev/null 2>&1
chk "status -h rc" "$?" 0

[ "$fail" = 0 ] && echo "PASS dcq_brief" || echo "FAIL dcq_brief"
exit "$fail"
