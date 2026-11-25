#!/usr/bin/env bash
# issue #27：預算熔斷、逐張設定與 rank 近邊警告；只使用暫存 Q 與假 opencode.db。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_OC_DB="$T/oc.db"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_TOK_POLL_S=1 DCQ_LOOP=0 DCQ_SPIN_S=0 DCQ_ATTEMPT_MAX=15 DCQ_JOB_MAX=40 DCQ_STALL_S=99 DCQ_TOK_MAX=0 DCQ_COST_MAX=0 DCQ_JOB_TOK_MAX=0
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘檔
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL=""
export DCQ_AUTORANK=0 DCQ_POOLSYNC=0 DCQ_GO_STATE="$T/none.json"
mkdir -p "$T/bin" "$T/wc" "$T/wo" "$T/wj"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

sqlite3 "$DCQ_OC_DB" <<'SQL'
CREATE TABLE session (id text PRIMARY KEY, directory text NOT NULL, time_created integer NOT NULL);
CREATE TABLE part (id text PRIMARY KEY, message_id text, session_id text, time_created integer, time_updated integer, data text);
CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
SQL
export TRACE="$T/trace"; : > "$TRACE"
cat > "$T/bin/dc" <<'SH'
#!/usr/bin/env bash
n="$(basename "$1" .md)"; cwd="$2"; ms=$(( $(date +%s) * 1000 )); sid="${n}_${DC_FREE_MODEL}"
echo "IN $n $DC_FREE_MODEL" >> "$TRACE"
[ "$n" = verify ] && echo "dc: 驗收 → fake"
out=1500; cost=0.8
[ "$n" = job ] && out=600
# BON 三隻各自的 out_tok 要不同：合計 600+700+800=2100，只算勝出者或漏加任一隻都驗得出來
case "$cwd" in */.bon/*) case "$DC_FREE_MODEL" in w1) out=600 ;; w2) out=700 ;; *) out=800 ;; esac ;; esac
[ "$DC_FREE_MODEL" = m2 ] && [ "$n" != job ] && { out=0; cost=0; }
sqlite3 "$DCQ_OC_DB" "INSERT INTO session VALUES ('$sid','$cwd',$ms); INSERT INTO message VALUES ('$sid','$sid',$ms,$ms,'{\"role\":\"assistant\",\"cost\":$cost,\"tokens\":{\"output\":$out,\"reasoning\":0}}');"
if [ "$n:$DC_FREE_MODEL" = overlap:m1 ]; then
  for i in $(seq 1 10); do
    sqlite3 "$DCQ_OC_DB" "INSERT INTO part VALUES ('${sid}_$i','m','$sid',$ms,$ms,'{\"type\":\"tool\",\"tool\":\"read\",\"state\":{\"input\":{\"filePath\":\"/same\"}}}');"
  done
fi
if [ "$n:$DC_FREE_MODEL" = job:m1 ]; then sleep 2; exit 1; fi
# BONWIN：w2 1 秒勝出，w1／w3 睡 10 秒注定是被殺的落選者，強制走 oc_usage 補計路徑。
if grep -q BONWIN "$1"; then
  case "$cwd:$DC_FREE_MODEL" in
    */.bon/*:w2) sleep 1; echo w2 > "$cwd/out.txt"; echo "OUT $n $DC_FREE_MODEL" >> "$TRACE"; exit 0 ;;
    */.bon/*:w1|*/.bon/*:w3) sleep 10; echo "OUT $n $DC_FREE_MODEL" >> "$TRACE"; exit 1 ;;
  esac
fi
sleep 3
echo "OUT $n $DC_FREE_MODEL" >> "$TRACE"
case "$cwd" in */.bon/*) exit 1 ;; esac
exit 0
SH
chmod +x "$T/bin/dc"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"
chmod +x "$T/bin/deep-lint"
# 假驗收：這張工單有模型跑完（TRACE 有 OUT 行）才算過。被 watchdog 殺掉的沒有 OUT → 殺後驗收不過 → 換下一隻；
# 工單名 vok 一律過（殺後驗收通過的正向對照）。
cat > "$T/bin/wo-verify" <<'SH'
#!/bin/sh
case "$*" in *--dry*) exit 0 ;; esac
n="$(basename "$1" .md)"
[ "$n" = vok ] && exit 0
[ -f out.txt ] && exit 0   # BON 勝出者套回 cwd 後的正向驗收
grep -q "^OUT $n " "$TRACE"
SH
chmod +x "$T/bin/wo-verify"
dcq() { "$R/bin/dcq" "$@"; }
mk() { mkdir -p "$T/$1"; printf '# %s\n' "$1" > "$T/$1.md"; dcq add "$T/$1.md" "$T/$1" >/dev/null; }
run() { rm -rf "$DCQ_HOME/.health"/*; DCQ_MODELS="m1 m2 m3" dcq run -j 1 > "$T/$1.log" 2>&1; }
count() { awk -F'\t' '$5=="budget"{n++} END{print n+0}' "$DCQ_HOME/logs/gaps.tsv"; }
DCQ_TOK_MAX=1000 mk tok
chk "入列 TOKMAX" "$(sed -n 's/^TOKMAX=//p' "$DCQ_HOME"/pending/*.job)" 1000
run tok
chk "token 超限記 budget" "$(count)" 1
chk "m1 未跑完" "$(grep -c '^OUT tok m1' "$TRACE")" 0
chk "換 m2" "$(grep -c '^IN tok m2' "$TRACE")" 1
# 殺後驗收：budget 殺掉但驗收通過 → 直接記 PASS，不換 m2（gaps.tsv 仍記這次 budget）
DCQ_TOK_MAX=1000 mk vok
run vok
chk "budget 殺後驗收過：進 done" "$(ls "$DCQ_HOME/done" | grep -c vok)" 1
chk "budget 殺後驗收過：不換 m2" "$(grep -c '^IN vok m2' "$TRACE")" 0
chk "budget 殺後驗收過：m1 確實被殺" "$(grep -c '^OUT vok m1' "$TRACE")" 0
DCQ_TOK_MAX=1000 DCQ_LOOP=kill mk overlap
DCQ_LOOP=kill run overlap
chk "同輪 loop 不覆寫 budget" "$(awk -F'\t' '$2=="m1" && $5=="budget"{n++} END{print n+0}' "$DCQ_HOME/logs/gaps.tsv")" 3
DCQ_TOK_MAX=2000 mk high
run high
chk "2000 不殺" "$(grep -c '^OUT high m1' "$TRACE")" 1
DCQ_TOK_MAX=0 mk off
run off
chk "0 不殺" "$(grep -c '^OUT off m1' "$TRACE")" 1
# 未設定時同樣預設關閉，且不把前一張工單的上限帶到下一張。
unset DCQ_TOK_MAX DCQ_COST_MAX DCQ_JOB_TOK_MAX
mk default
run default
chk "預設不殺" "$(grep -c '^OUT default m1' "$TRACE")" 1
DCQ_COST_MAX=0.5 mk cost
chk "入列 COSTMAX" "$(sed -n 's/^COSTMAX=//p' "$DCQ_HOME"/pending/*.job)" 0.5
run cost
chk "cost 超限" "$(count)" 4
DCQ_TOK_MAX=1000 mk verify
run verify
chk "進驗收不殺" "$(grep -c '^OUT verify m1' "$TRACE")" 1
DCQ_JOB_TOK_MAX=1000 mk job
chk "入列 JOBTOKMAX" "$(sed -n 's/^JOBTOKMAX=//p' "$DCQ_HOME"/pending/*.job)" 1000
run job
chk "整張第二隻確實開始" "$(grep -c '^IN job m2' "$TRACE")" 1
chk "整張第二隻記 budget" "$(awk -F'\t' '$2=="m2" && $5=="budget" {n++} END{print n+0}' "$DCQ_HOME/logs/gaps.tsv")" 1
chk "整張超限不換 m3" "$(grep -c '^IN job m3' "$TRACE")" 0
chk "整張超限進 failed" "$(ls "$DCQ_HOME/failed" | grep -c job)" 1
chk "整張 rc124" "$(sed -n 's/^LAST_RC=//p' "$DCQ_HOME"/failed/*job.job)" 124
grep -q 'token 預算用完' "$T/job.log" || { echo 'FAIL 缺少整張預算訊息'; fail=1; }
printf '%s\tm1\t0\t0\texit\t2\tmid\t950\t0\t0\n' "$(date +%F_%T)" > "$DCQ_HOME/logs/gaps.tsv"
DCQ_TOK_MAX=1000 DCQ_MODELS=m1 dcq rank > "$T/rank"
chk "近邊警告" "$(grep -c '⚠.*out_tok' "$T/rank")" 1
DCQ_TOK_MAX=2000 DCQ_MODELS=m1 dcq rank > "$T/rank"
chk "遠離門檻無警告" "$(grep -c '⚠.*out_tok' "$T/rank")" 0
printf '%s\tm1\t0\t0\texit\t2\tmid\t1\t0\t0\n' "$(date +%F_%T)" >> "$DCQ_HOME/logs/gaps.tsv"
DCQ_RANK_WIN=1 DCQ_TOK_MAX=1000 DCQ_MODELS=m1 dcq rank > "$T/rank"
chk "視窗外不警告" "$(grep -c '⚠.*out_tok' "$T/rank")" 0
# 沿用 dcq_bon_test 的清冊與暫存 git repo，驗證 BON 增量也計入整張預算。
# 假 mv：job 檔搬進 failed/ 時把主工單 preflight 的 tok_used 抄出來——結案 rm -rf 會刪，
# 這是能直接驗 bon_total 合計落點的最後窗口（#36）
export BONCAP="$T/bon_tok_used"
cat > "$T/bin/mv" <<'SH'
#!/bin/sh
case "$2" in */failed/*.job|*/done/*.job)
  pf="${DCQ_HOME}/.preflight/$(basename "$2" .job)"
  [ -f "$pf/tok_used" ] && cp "$pf/tok_used" "$BONCAP" ;;
esac
exec /bin/mv "$@"
SH
chmod +x "$T/bin/mv"
mkdir -p "$T/cat"
for m in strong:any w1:easy w2:easy w3:easy; do
  printf 'free\topencode-run\t%s\tok\tx\tx\t%s\t%s\n' "${m%%:*}" "${m%%:*}" "${m#*:}" >> "$T/cat/models.tsv"
done
: > "$T/cat/providers.tsv"
git init -q "$T/bonrepo"
git -C "$T/bonrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture
printf '# BON budget\n' > "$T/bon.md"
echo $(( $(date +%s) + 3600 )) > "$DCQ_HOME/.health/strong.cool"
DCQ_CATALOG="$T/cat" DCQ_JOB_TOK_MAX=1000 dcq add "$T/bon.md" "$T/bonrepo" hard >/dev/null
DCQ_CATALOG="$T/cat" dcq run -j 1 > "$T/bon.log" 2>&1
chk "BON 合計超限進 failed" "$(ls "$DCQ_HOME/failed" | grep -c -- '-bon.job')" 1
# 主工單 tok_used＝三隻各自 out_tok 的合計（600+700+800）：只算勝出者或漏加任一隻都不是這個數
chk "BON tok_used＝三隻合計" "$(cat "$T/bon_tok_used" 2>/dev/null)" 2100
grep -q 'token 預算用完' "$T/bon.log" || { echo 'FAIL BON 缺少預算訊息'; cat "$T/bon.log"; fail=1; }
# #36 補缺口：勝出者存在時落選者會被殺，沒有 .res／tok_used 收尾，只能靠 oc_usage 補計；
# 同場景 seed tok_used=100 當前一嘗試留下的共同基數。正確合計＝100＋600＋700＋800＝2200；
# 落選者補計寫 0 會得 800，不扣共同基數會得 2300，只算勝出者也不是 2200。
printf '# BONWIN baseline\n' > "$T/bonwin.md"
rm -f "$T/bon_tok_used"
: > "$TRACE"
bonwin_id="$(DCQ_CATALOG="$T/cat" DCQ_JOB_TOK_MAX=3000 dcq add "$T/bonwin.md" "$T/bonrepo" hard 2>/dev/null)"
mkdir -p "$DCQ_HOME/.preflight/$bonwin_id"
printf '100\n' > "$DCQ_HOME/.preflight/$bonwin_id/tok_used"
DCQ_CATALOG="$T/cat" dcq run -j 1 > "$T/bonwin.log" 2>&1
chk "BONWIN 進 done" "$(ls "$DCQ_HOME/done" | grep -c -- '-bonwin.job')" 1
chk "BONWIN 勝出者 w2" "$(awk -F= '/^BON=/{print $2}' "$DCQ_HOME"/done/*bonwin.job 2>/dev/null)" w2
chk "BONWIN w2 完成" "$(grep -c 'OUT .* w2' "$TRACE")" 1
chk "BONWIN w1 被殺未完成" "$(grep -c 'OUT .* w1' "$TRACE")" 0
chk "BONWIN w3 被殺未完成" "$(grep -c 'OUT .* w3' "$TRACE")" 0
chk "BONWIN 勝出改動套回" "$(cat "$T/bonrepo/out.txt" 2>/dev/null)" w2
chk "BON tok_used＝基數一次＋三隻合計" "$(cat "$T/bon_tok_used" 2>/dev/null)" 2200
[ "$fail" = 0 ] && echo PASS
[ "$fail" = 0 ] || cat "$T/job.log"
exit "$fail"
