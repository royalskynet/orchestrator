#!/usr/bin/env bash
# issue #28：oc_loop 從 opencode.db 的 part 表判「同一招工具反覆打」（無限 Glob/Read，
# 有輸出不觸發 stall）。watch_oc 每 DCQ_TOK_POLL_S 查一次、進驗收後不查、
# 視窗期間工作樹有變過豁免；DCQ_LOOP=shadow（預設）只記 logs/loops.tsv 不殺，
# kill 記 why=loop 走 spin 同路罰冷卻換模型。
# 假 db 建在暫存目錄（DCQ_OC_DB 指向它），不碰真的 opencode.db 與 ~/.dcq。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_OC_DB="$T/oc.db"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_TOK_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘檔
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL=""
export DCQ_AUTORANK=0 DCQ_POOLSYNC=0 DCQ_GO_STATE="$T/none.json"
export DCQ_STALL_S=99 DCQ_ATTEMPT_MAX=15 DCQ_JOB_MAX=40 DCQ_SPIN_S=0
mkdir -p "$T/bin" "$T/w1" "$T/w2" "$T/w3" "$T/w4" "$T/w5" "$T/w6"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# 假 opencode.db：session／part 欄位摘真實 1.19.4 schema 的最小集
sqlite3 "$DCQ_OC_DB" <<'SQL'
CREATE TABLE session (id text PRIMARY KEY, directory text NOT NULL, time_created integer NOT NULL);
CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
SQL

# 假 dc：依工單名＋模型把 session＋part 寫進假 db（time_created ≥ 嘗試起點 ta），再依情境睡或改檔。
# 不印「dc: 驗收 →」的 loop* 案例會被一直查；loopv 開頭就印驗收，之後不該再查。
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
task="$1"; cwd="$2"; n="$(basename "$task" .md)"
echo "IN $n $DC_FREE_MODEL" >> "$TRACE"
ms=$(( $(date +%s) * 1000 ))
sid="ses_${n}_${DC_FREE_MODEL//\//_}"
ins() {  # $1=tool $2=input JSON：session＋10 筆同簽章的 type=tool part
  sqlite3 "$DCQ_OC_DB" "INSERT OR IGNORE INTO session VALUES ('$sid','$cwd',$ms)" 2>/dev/null
  local i
  for i in $(seq 1 10); do
    sqlite3 "$DCQ_OC_DB" "INSERT INTO part VALUES ('${sid}_p$i','m$i','$sid',$ms,$ms,'{\"type\":\"tool\",\"tool\":\"$1\",\"state\":{\"status\":\"completed\",\"input\":$2}}')" 2>/dev/null
  done
}
case "$n:$DC_FREE_MODEL" in
  loopk:m1) ins read '{"filePath":"/a/1"}'; for i in $(seq 15); do echo tick; sleep 1; done ;;
  loopd:m1)
    sqlite3 "$DCQ_OC_DB" "INSERT INTO session VALUES ('$sid','$cwd',$ms)" 2>/dev/null
    for i in $(seq 1 10); do   # 10 筆各不同 input → 10 個簽章
      sqlite3 "$DCQ_OC_DB" "INSERT INTO part VALUES ('${sid}_p$i','m$i','$sid',$ms,$ms,'{\"type\":\"tool\",\"tool\":\"read\",\"state\":{\"status\":\"completed\",\"input\":{\"filePath\":\"/a/$i\"}}}')" 2>/dev/null
    done
    sleep 2 ;;
  loopx:m1) echo x > "$cwd/changed.txt"; ins bash '{"command":"make test"}'
    for i in $(seq 4); do echo tick; sleep 1; done ;;
  loops:m1) ins read '{"filePath":"/b/9"}'; for i in $(seq 3); do echo tick; sleep 1; done ;;
  loopv:m1) echo "dc: 驗收 → wo-verify --pinned (cwd=$cwd, K=2)"; ins read '{"filePath":"/v/1"}'
    for i in $(seq 3); do echo tick; sleep 1; done ;;
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
ago=$(( $(date +%s) - 60 ))

# 0) oc_loop 單測：不足 LOOP_WIN 筆、db 不存在都回空（eval 出函式；w5 只有 5 筆同簽章）
eval "$(sed -n '/^oc_session()/,/^}/p' "$R/bin/dcq")"
eval "$(sed -n '/^oc_loop()/,/^}/p' "$R/bin/dcq")"
LOOP_WIN=10 LOOP_UNIQ=2
ms=$(( $(date +%s) * 1000 ))
sqlite3 "$DCQ_OC_DB" "INSERT INTO session VALUES ('ses_u','$T/w5',$ms)"
for i in $(seq 1 5); do
  sqlite3 "$DCQ_OC_DB" "INSERT INTO part VALUES ('u$i','m$i','ses_u',$ms,$ms,'{\"type\":\"tool\",\"tool\":\"read\",\"state\":{\"status\":\"completed\",\"input\":{\"filePath\":\"/u\"}}}')"
done
chk "不足 LOOP_WIN 筆不判" "$(oc_loop "$T/w5" "$ago" 0)" ""
chk "db 不存在回空" "$(DCQ_OC_DB="$T/no.db" oc_loop "$T/w5" "$ago" 0)" ""

# 1) DCQ_LOOP=kill：10 次相同 read → m1 記 why=loop 被殺、換 m2 過關
mk loopk "$T/w1"
DCQ_MODELS="m1 m2" DCQ_LOOP=kill dcq run -j 1 >"$T/loopk.out" 2>&1
chk "loop 被殺後換 m2 過關" "$(ls -1 "$DCQ_HOME/done" | grep -c loopk)" "1"
chk "m1 沒跑完 15s 就被殺" "$(grep -c '^OUT loopk m1' "$TRACE")" "0"
chk "換 m2" "$(grep -c '^IN loopk m2' "$TRACE")" "1"
chk "gaps.tsv 記 why=loop" "$(awk -F'\t' '$5=="loop"' "$DCQ_HOME/logs/gaps.tsv" | wc -l | tr -d ' ')" "1"
chk "loops.tsv 記一行" "$(wc -l < "$DCQ_HOME/logs/loops.tsv" | tr -d ' ')" "1"
chk "loops.tsv 欄位（模型/session/工具/次數）" "$(awk -F'\t' '{print $2"|"$3"|"$4"|"$5}' "$DCQ_HOME/logs/loops.tsv")" "m1|ses_loopk_m1|read|10"
grep -q 'watchdog: m1 loop' "$T/loopk.out" || { echo "FAIL 沒印 watchdog loop"; fail=1; }
chk "oc_loop 直測：10 筆同簽章命中" "$(oc_loop "$T/w1" "$ago" 0)" "$(printf '10\tread')"
chk "oc_loop 直測：樹有動過（since≥part 時間）豁免" "$(oc_loop "$T/w1" "$ago" "$(date +%s)")" ""

# 2) 10 筆各不相同的呼叫 → 不判
: > "$TRACE"; : > "$DCQ_HOME/logs/gaps.tsv"; rm -rf "$DCQ_HOME/.health"/*
mk loopd "$T/w2"
DCQ_MODELS="m1" DCQ_LOOP=kill dcq run -j 1 >"$T/loopd.out" 2>&1
chk "10 筆各異：m1 跑完沒被殺" "$(grep -c '^OUT loopd m1' "$TRACE")" "1"
chk "10 筆各異：gaps 無 loop" "$(awk -F'\t' '$5=="loop"' "$DCQ_HOME/logs/gaps.tsv" | wc -l | tr -d ' ')" "0"
chk "10 筆各異：loops.tsv 沒多行" "$(grep -c ses_loopd "$DCQ_HOME/logs/loops.tsv")" "0"

# 3) 同一條 bash 指令 10 次、期間工作樹有變過 → 豁免不判
: > "$TRACE"; : > "$DCQ_HOME/logs/gaps.tsv"; rm -rf "$DCQ_HOME/.health"/*
mk loopx "$T/w3"
DCQ_MODELS="m1" DCQ_LOOP=kill dcq run -j 1 >"$T/loopx.out" 2>&1
chk "樹有動過豁免：m1 跑完沒被殺" "$(grep -c '^OUT loopx m1' "$TRACE")" "1"
chk "樹有動過豁免：gaps 無 loop" "$(awk -F'\t' '$5=="loop"' "$DCQ_HOME/logs/gaps.tsv" | wc -l | tr -d ' ')" "0"
chk "樹有動過豁免：loops.tsv 沒多行" "$(grep -c ses_loopx "$DCQ_HOME/logs/loops.tsv")" "0"

# 4) DCQ_LOOP=shadow（預設，不設環境變數）：記 loops.tsv 不殺、嘗試照樣過關
: > "$TRACE"; : > "$DCQ_HOME/logs/gaps.tsv"; rm -rf "$DCQ_HOME/.health"/*
mk loops "$T/w4"
DCQ_MODELS="m1" dcq run -j 1 >"$T/loops.out" 2>&1
chk "shadow：m1 跑完沒被殺" "$(grep -c '^OUT loops m1' "$TRACE")" "1"
chk "shadow：工單過關" "$(ls -1 "$DCQ_HOME/done" | grep -c loops)" "1"
chk "shadow：gaps 無 loop" "$(awk -F'\t' '$5=="loop"' "$DCQ_HOME/logs/gaps.tsv" | wc -l | tr -d ' ')" "0"
chk "shadow：loops.tsv 多一行" "$(grep -c ses_loops_m1 "$DCQ_HOME/logs/loops.tsv")" "1"
chk "shadow 行欄位" "$(awk -F'\t' '$3=="ses_loops_m1"{print $4"|"$5}' "$DCQ_HOME/logs/loops.tsv")" "read|10"

# 5) .out 出現「dc: 驗收 →」後不查：同樣 10 筆同簽章也不記不殺
: > "$TRACE"; : > "$DCQ_HOME/logs/gaps.tsv"; rm -rf "$DCQ_HOME/.health"/*
mk loopv "$T/w6"
DCQ_MODELS="m1" DCQ_LOOP=kill dcq run -j 1 >"$T/loopv.out" 2>&1
chk "進驗收後不查：m1 跑完沒被殺" "$(grep -c '^OUT loopv m1' "$TRACE")" "1"
chk "進驗收後不查：loops.tsv 沒多行" "$(grep -c ses_loopv "$DCQ_HOME/logs/loops.tsv")" "0"

[ "$fail" = 0 ] && echo PASS
exit "$fail"
