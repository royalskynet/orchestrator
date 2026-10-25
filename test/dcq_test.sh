#!/usr/bin/env bash
# dcq 的最小自檢：用假的 dc 驗佇列機制，不打上游。
# 斷言三件：1) 平行度真的 >1  2) 同 cwd 的 job 絕不重疊  3) rc=1 會換模型、rc=2 不重試
set -u
. "$(dirname "$0")/env.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q"; mkdir -p "$T/bin" "$T/wa" "$T/wb"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
# freecheck 會打真的上游：Go 付費額度只要 >0% 就警報，整個自檢會被擋在開跑前。
# 這裡測佇列不測計費，關掉。
# 同 dc_lock_test.sh：假 wo-verify 一律 exit 0，關掉 do-nothing 對照。
export DC_FREECHECK=off DC_NEGCTL=0
export DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘檔
# 舊斷言（up1 跑 2 次）假設「免費一輪、無訂閱層」；付費層另在 11)、12) 明確打開
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL=""
# 本檔測 default 鏈（派o）；dcq 未設時預設也是 default（10-21 改，原 free 見 fixindex 11106），沒給的預設由 dcq_tier_test 5b 測
export DCQ_ORDER=default

# 假 dc：記下 (cwd, 進出時間, model)，依任務檔名決定 rc
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
task="$1"; cwd="$2"; n="$(basename "$task" .md)"
echo "IN $n $cwd $DC_FREE_MODEL $(date +%s.%N)" >> "$TRACE"
# 2026-10-21 前置檢查憑證：記下這次收到的 DC_PREFLIGHT_DIR（寫另一個檔，
# 不塞進 TRACE —— TRACE 的 IN/OUT 配對被別的斷言用 awk 算並行度）
[ -n "${DC_PREFLIGHT_DIR:-}" ] && echo "$n $DC_PREFLIGHT_DIR" >> "$PFLOG"
case "$n:$DC_FREE_MODEL" in defect*) echo "DC_TASK_DEFECT: line 3 x"; sleep 30 ;; slow*|hang*:m1) sleep 30 ;; spin*:m1|vspin*:m1) case "$n" in v*) echo "dc: 驗收 → wo-verify --pinned (cwd=$cwd, K=2)" ;; esac; for i in $(seq 8); do echo tick; sleep 1; done ;; wspin*:m1) for i in $(seq 8); do echo $i > "$cwd/f$i"; echo tick; sleep 1; done ;; busy*:m1) for i in $(seq 30); do echo tick; sleep 1; done ;; jm*:m1) sleep 30 ;; ho*:*) sleep 3 ;; *) sleep 1 ;; esac
echo "OUT $n $cwd $DC_FREE_MODEL $(date +%s.%N)" >> "$TRACE"
case "$n" in
  local*) echo "Error: Unexpected error"; echo "no such column: project_id"; echo "dc: opencode run rc=1" ;;
  diff*) echo "Error: boom from $DC_FREE_MODEL"; echo "dc: opencode run rc=1" ;;
  # 真 dc 上游提早結束時 .out 末尾＝bash 殺子程序的 Terminated 回顯（同一段 prompt），每隻模型都一樣
  ux*) echo "dc: 上游不可用（Upstream request failed: Endpoint is unavailable.），已提早結束"; echo "Terminated: 15 sh -c opencode run 你是執行人。"; echo "驗收由外部 wo-verify 機械執行"; echo "--pure --print-logs" ;;
  vf*) echo "dc: 驗收 → wo-verify --pinned (cwd=$cwd, K=2)"; echo "verify fail $DC_FREE_MODEL" ;;
  # 假憑證值執行期拼出，檔案內不出現完整字面值（sensitive-canary 會擋讀檔，fix 9880）
  leak*) echo "FAKE_TOKEN=sk-$(printf 'x%.0s' $(seq 16))" ;;
esac
case "$n:$DC_FREE_MODEL" in tl*:t/*) exit 0 ;; tl*) exit 1 ;; up*:go/*) exit 0 ;; up*) exit 1 ;; bad*|defect*) exit 2 ;; local*|diff*|vf*|ux*) exit 1 ;; leak*) exit 0 ;; *) exit 0 ;; esac
EOF
chmod +x "$T/bin/dc"
export TRACE="$T/trace"; : > "$TRACE"
export PFLOG="$T/pflog"; : > "$PFLOG"

# 假 opencode：只給 stall_dump 用。session 在當前目錄、建立於現在；最後一則 assistant 卡在 read running
cat > "$T/bin/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "session list") printf '[{"id":"ses_fake","directory":"%s","created":%s}]\n' "$(pwd)" "$(( $(date +%s) * 1000 ))" ;;
  "export ses_fake") echo '{"messages":[{"info":{"role":"assistant","time":{}},"parts":[{"type":"reasoning","text":"abcd"},{"type":"tool","tool":"read","state":{"status":"completed"}},{"type":"tool","tool":"read","state":{"status":"running"}}]}]}' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/opencode"

# dcq add 的准入閘會跑 deep-lint/wo-verify；這裡測佇列不測閘，用假的放行
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"; chmod +x "$T/bin/deep-lint"
# 假 wo-verify：--dry（入列閘）一律過；jmf*／slow* 工單的正式驗收不過（10、10a'、16b 要的是
# 「總時限到且沒交件」；總時限到但驗收過的新路徑由 16a 用 jm1 測）
printf '#!/bin/sh\ncase "$*" in *--dry*) exit 0 ;; *jmf*|*slow*) exit 1 ;; esac\nexit 0\n' > "$T/bin/wo-verify"; chmod +x "$T/bin/wo-verify"

mk() { printf '# %s\n' "$1" > "$T/$1.md"; dcq add "$T/$1.md" "$2" >/dev/null || echo "add failed: $1"; }
dcq() { "$(cd "$(dirname "$0")/.." && pwd)/bin/dcq" "$@"; }

# a1,a2 共用 cwd wa（必須互斥）；b1,b2 各自 cwd（可平行）
mk a1 "$T/wa"; mk a2 "$T/wa"; mk b1 "$T/wb"; mk b2 "$T"
mk up1 "$T/wb"    # rc=1 → 兩個模型都試
mk bad1 "$T/wb"   # rc=2 → 只試一次

DCQ_MODELS="m1 m2" DCQ_BREAK_N=99 dcq run -j 4 >"$T/run.out" 2>&1
echo "--- dcq status ---"; cat "$T/run.out" | tail -20

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# 1) 平行度 >1：任一時刻有兩個 IN 沒對應 OUT
maxpar=$(awk '{if($1=="IN")c++;else c--; if(c>m)m=c} END{print m}' "$TRACE")
[ "${maxpar:-0}" -ge 2 ] && echo "PASS 平行度=$maxpar" || { echo "FAIL 平行度=$maxpar 應 >=2"; fail=1; }

# 2) 同 cwd 不重疊
ov=$(awk -v w="$T/wa" '$3==w{if($1=="IN")c++;else c--; if(c>m)m=c} END{print m+0}' "$TRACE")
chk "同cwd互斥(wa最大重疊=1)" "$ov" "1"

# 3) exit code 分流
chk "rc=1 換模型(up1 跑 2 次)" "$(grep -c '^IN up1' "$TRACE")" "2"
chk "rc=2 不重試(bad1 跑 1 次)" "$(grep -c '^IN bad1' "$TRACE")" "1"
chk "done 數" "$(ls -1 "$DCQ_HOME/done" | wc -l | tr -d ' ')" "4"
chk "failed 數" "$(ls -1 "$DCQ_HOME/failed" | wc -l | tr -d ' ')" "2"

# 4) 免費終止警報：有 .ALARM 就拒絕開跑，且工單原封不動留在 pending
mk z1 "$T/wb"
echo "測試用警報" > "$DCQ_HOME/.ALARM"
DCQ_MODELS="m1" dcq run -j 1 >"$T/alarm.out" 2>&1; arc=$?
chk "有 .ALARM 時 run 拒絕(rc!=0)" "$([ "$arc" -ne 0 ] && echo yes || echo no)" "yes"
chk "拒絕時工單留在 pending" "$(ls -1 "$DCQ_HOME/pending" | wc -l | tr -d ' ')" "1"
grep -q "警報" "$T/alarm.out" || { echo "FAIL 拒絕訊息沒提警報"; fail=1; }
rm -f "$DCQ_HOME/.ALARM"
dcq clear >/dev/null

# 5) cancel：取消一張正在跑的工單 —— 階梯不得換下一個模型重跑（issue #2）
: > "$TRACE"
mk slow1 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_BREAK_N=99 dcq run -j 1 >"$T/cancel.out" 2>&1 &
runner=$!
cid=""
for _ in $(seq 1 100); do
  for p in "$DCQ_HOME"/running/*.pid; do [ -e "$p" ] && cid="$(basename "$p" .pid)"; done
  [ -n "$cid" ] && break
  sleep 0.2
done
if [ -z "$cid" ]; then echo "FAIL cancel: 等不到 running 的 job"; fail=1; else
  dcq cancel "$cid" >"$T/cancel.cmd.out" 2>&1
  wait "$runner"
  chk "cancel 後 job 在 failed" "$([ -e "$DCQ_HOME/failed/$cid.job" ] && echo yes || echo no)" "yes"
  grep -q '^CANCELLED=1' "$DCQ_HOME/failed/$cid.job" || { echo "FAIL cancel: 沒標 CANCELLED=1"; fail=1; }
  chk "cancel 不換下一個模型(只跑 m1)" "$(grep -c '^IN slow1' "$TRACE")" "1"
  chk "沒有第二個模型的 .out" "$([ -e "$DCQ_HOME/logs/$cid.m2.out" ] && echo yes || echo no)" "no"
  chk "status 標出 cancelled" "$(dcq status 2>/dev/null | grep -c cancelled)" "1"
  chk "pid 檔已清掉" "$([ -e "$DCQ_HOME/running/$cid.pid" ] && echo yes || echo no)" "no"
fi

# 6) cancel 一張還沒開跑的：直接進 failed，不留永遠收不走的標記
mk slow2 "$T/wb"
pid_job="$(ls -1 "$DCQ_HOME/pending" | head -1)"; pid_job="${pid_job%.job}"
dcq cancel "$pid_job" >/dev/null 2>&1
chk "pending 的 cancel 直接進 failed" "$([ -e "$DCQ_HOME/failed/$pid_job.job" ] && echo yes || echo no)" "yes"
chk "cancel 標記已收走" "$(ls -1 "$DCQ_HOME/.cancel" 2>/dev/null | wc -l | tr -d ' ')" "0"
dcq cancel no-such-job >/dev/null 2>&1; crc=$?
chk "cancel 不存在的 job 要報錯" "$([ "$crc" -ne 0 ] && echo yes || echo no)" "yes"

dcq clear >/dev/null

# 0) lint：`$VAR（` 這種變數後緊貼全形字元，bash 會把位元組吞進變數名，set -u 下直接崩
#    （20c5395 修過一次，pool 改版又踩一次）。一律寫成 ${VAR}。
R="$(cd "$(dirname "$0")/.." && pwd)"
chk "bin/ 無 \$VAR 緊貼全形字元" "$(LC_ALL=C grep -lE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$R"/bin/* | wc -l | tr -d ' ')" "0"
# dc 與 deepclaude 互不依賴：wo-verify／deep-lint 用 bin/ 自帶那份，不准再指回 ~/.deepclaude
chk "bin/ 不引用 ~/.deepclaude 路徑" "$(grep -lE '\.deepclaude|deep-agent/bin' "$R"/bin/* | wc -l | tr -d ' ')" "0"
chk "bin/ 自帶 wo-verify 與 deep-lint" "$( [ -x "$R/bin/wo-verify" ] && [ -x "$R/bin/deep-lint" ] && echo ok)" "ok"

# 7) watchdog 停滯：hang 在 m1 上靜默 → 被殺、換 m2 過關、m1 進冷卻、gaps.tsv 有記錄
: > "$TRACE"
mk hang1 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_STALL_S=4 DCQ_ALLOWED_FAILS=1 DCQ_COOLDOWN_S=60 dcq run -j 1 >"$T/stall.out" 2>&1
chk "停滯被殺後換 m2 過關" "$(ls -1 "$DCQ_HOME/done" | wc -l | tr -d ' ')" "1"
chk "m1 沒等滿 30s 就被殺" "$(grep -c '^OUT hang1 .* m1 ' "$TRACE")" "0"
grep -q 'watchdog: m1 stall' "$T/stall.out" || { echo "FAIL 沒印 watchdog stall"; fail=1; }
chk "gaps.tsv 記到 stall" "$(grep -c 'm1.*stall' "$DCQ_HOME/logs/gaps.tsv")" "1"
# 7b) 停滯殺之前匯出 session：摘要要分得出「tool 卡 running」與 reasoning 字數（fix 10309 兩假設）
chk "stalls.tsv 摘要 tool 狀態與 reasoning 字數" "$(grep -c $'m1\tses_fake\tassistant\tfalse\tread:completed,read:running\t4$' "$DCQ_HOME/logs/stalls.tsv")" "1"
chk "stall.json 已存且 600" "$(stat -c %a "$DCQ_HOME"/logs/*hang1*.m1.stall.json 2>/dev/null || stat -f %Lp "$DCQ_HOME"/logs/*hang1*.m1.stall.json 2>/dev/null)" "600"
chk "status 顯示 m1 cooling" "$(DCQ_MODELS="m1 m2" dcq status | grep -c 'm1 .*cooling')" "1"

# 8) 冷卻中的模型直接跳過（不清 .health，沿用上一步的 m1 冷卻）
: > "$TRACE"
mk c1 "$T/wb"
DCQ_MODELS="m1 m2" dcq run -j 1 >/dev/null 2>&1
chk "冷卻中跳過 m1" "$(grep -c '^IN c1 .* m1 ' "$TRACE")" "0"
chk "改走 m2" "$(grep -c '^IN c1 .* m2 ' "$TRACE")" "1"
dcq clear >/dev/null

# 9) per-model 併發上限：m1 只准 1 張，同時兩張 → 一張走 m1、一張溢到 m2
: > "$TRACE"
mk p1 "$T/wa"; mk p2 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_MODEL_MAX=1 dcq run -j 2 >/dev/null 2>&1
chk "m1 只被用 1 次" "$(grep -c '^IN p.* m1 ' "$TRACE")" "1"
chk "溢出到 m2 1 次" "$(grep -c '^IN p.* m2 ' "$TRACE")" "1"
chk "槽都歸還" "$(ls -1 "$DCQ_HOME/.inuse" | wc -l | tr -d ' ')" "0"
dcq clear >/dev/null

# 10) 總時限：工單的錯不是模型的錯 —— 不換模型、不罰冷卻
: > "$TRACE"
mk slow3 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_JOB_MAX=3 DCQ_STALL_S=99 DCQ_ALLOWED_FAILS=1 dcq run -j 1 >"$T/jm.out" 2>&1
chk "超時進 failed rc=124" "$(grep -h '^LAST_RC=' "$DCQ_HOME"/failed/*.job)" "LAST_RC=124"
chk "超時不換模型" "$(grep -c '^IN slow3' "$TRACE")" "1"
chk "超時不罰 m1" "$(DCQ_MODELS="m1 m2" dcq status | grep -c cooling)" "0"

# 10a') 逐張總時限：入列帶 DCQ_JOB_MAX=3，runner 用預設 2700 也要 3s 收
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
printf '# slowjm\n' > "$T/slowjm.md"; DCQ_JOB_MAX=3 dcq add "$T/slowjm.md" "$T/wb" >/dev/null
DCQ_MODELS="m1 m2" DCQ_STALL_S=99 DCQ_ALLOWED_FAILS=1 dcq run -j 1 >"$T/jm2.out" 2>&1
chk "逐張總時限生效（只試 1 隻）" "$(grep -c '^IN slowjm' "$TRACE")" "1"
chk "逐張總時限判失敗" "$(ls -1 "$DCQ_HOME/failed" | grep -c slowjm)" "1"

# 10a'') 飽和停損：每隻都 slow 且不改檔，SAT=2 → 試 2 次就停，不跑滿 3 隻×輪次
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"; mkdir -p "$T/ws"
printf '# slowsat\n' > "$T/slowsat.md"; DCQ_SAT_N=2 dcq add "$T/slowsat.md" "$T/ws" >/dev/null
DCQ_MODELS="m1 m2 m3" DCQ_ATTEMPT_MAX=2 DCQ_STALL_S=99 DCQ_ALLOWED_FAILS=99 dcq run -j 1 >"$T/sat.out" 2>&1
chk "飽和試 2 次就停" "$(grep -c '^IN slowsat' "$TRACE")" "2"
chk "飽和有印原因" "$(grep -c '飽和' "$T/sat.out")" "1"
: > "$DCQ_HOME/logs/gaps.tsv"   # 上面兩段的 slow 紀錄不要算進 10b

# 10b) 單隻上限：m1 一直有輸出（不觸發 stall）但不收工 → 撞 ATTEMPT_MAX 被殺、換 m2 過關，不是整張吃滿 JOB_MAX
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk busy1 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_ATTEMPT_MAX=4 DCQ_STALL_S=99 DCQ_ALLOWED_FAILS=1 dcq run -j 1 >"$T/am.out" 2>&1
chk "單隻超時換 m2 過關" "$(ls -1 "$DCQ_HOME/done" | wc -l | tr -d ' ')" "1"
chk "m1 沒跑滿 30s" "$(grep -c '^OUT busy1 .* m1 ' "$TRACE")" "0"
chk "gaps.tsv 記 slow" "$(grep -c $'\tm1\t.*\tslow\t' "$DCQ_HOME/logs/gaps.tsv")" "1"
# 10b') 看進度：非 git cwd 裡 m1 超過 ATTEMPT_MAX 但一直在寫檔 → 不判 slow，跑完 8s 才收工
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"; mkdir -p "$T/wp"
mk wspin4 "$T/wp"
DCQ_MODELS="m1 m2" DCQ_ATTEMPT_MAX=3 DCQ_PROGRESS_S=4 DCQ_STALL_S=99 DCQ_ALLOWED_FAILS=1 dcq run -j 1 >"$T/wp.out" 2>&1
chk "有進度的 m1 不被 slow 砍" "$(grep -c '^OUT wspin4 .* m1 ' "$TRACE")" "1"
chk "有進度不換 m2" "$(grep -c '^IN wspin4 .* m2 ' "$TRACE")" "0"

# 10c) 防空轉：git cwd 裡 m1 一直有輸出但不改檔 → SPIN_S 到就殺、換 m2；有改檔／進驗收／逐張關掉都不殺
for w in g1 g2 g3 g4; do git init -q "$T/$w"; done
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"; : > "$DCQ_HOME/logs/gaps.tsv"
mk spin1 "$T/g1"; mk wspin1 "$T/g2"; mk vspin1 "$T/g3"; mkdir -p "$T/ng"; mk spin3 "$T/ng"
printf '# spin2\n' > "$T/spin2.md"; DCQ_SPIN_S=0 dcq add "$T/spin2.md" "$T/g4" >/dev/null
DCQ_MODELS="m1 m2" DCQ_SPIN_S=3 DCQ_STALL_S=99 DCQ_ALLOWED_FAILS=99 dcq run -j 4 >"$T/spin.out" 2>&1
chk "五張都過關" "$(ls -1 "$DCQ_HOME/done" | wc -l | tr -d ' ')" "5"
chk "空轉的 m1 被殺（沒跑完 8s）" "$(grep -c '^OUT spin1 .* m1 ' "$TRACE")" "0"
chk "空轉換 m2 過關" "$(grep -c '^IN spin1 .* m2 ' "$TRACE")" "1"
chk "gaps.tsv 只記 1 筆 spin" "$(grep -c $'\tspin\t' "$DCQ_HOME/logs/gaps.tsv")" "1"
chk "一直改檔的不殺" "$(grep -c '^OUT wspin1 .* m1 ' "$TRACE")" "1"
chk "進驗收後不殺" "$(grep -c '^OUT vspin1 .* m1 ' "$TRACE")" "1"
chk "DCQ_SPIN_S=0 入列的不殺" "$(grep -c '^OUT spin2 .* m1 ' "$TRACE")" "1"
chk "非 git cwd 不看（同樣不改檔也不殺）" "$(grep -c '^OUT spin3 .* m1 ' "$TRACE")" "1"

# 11) 權重：免費兩隻 × 2 輪全上游失敗，才 fallback 訂閱層
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk up2 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_POOL_PAID="go/px" DCQ_FREE_ROUNDS=2 DCQ_ALLOWED_FAILS=99 dcq run -j 1 >"$T/paid.out" 2>&1
chk "免費層跑滿 2 輪(4 次)才升級" "$(grep -c '^IN up2 .* m[12] ' "$TRACE")" "4"
chk "訂閱層只跑 1 次" "$(grep -c '^IN up2 .* go/px ' "$TRACE")" "1"
chk "過關且標 PAID=1" "$(grep -h '^PAID=1' "$DCQ_HOME"/done/*.job 2>/dev/null | wc -l | tr -d ' ')" "1"
chk "免費全敗之前沒碰訂閱層" "$(awk '/^IN up2/{print $4}' "$TRACE" | tail -1)" "go/px"

# 11b) 免費的層全部排在付費之前：免費→懲罰（免費累犯）→兜底（免費）；兜底過關就停，不碰訂閱層（2026-10-13 使用者定）
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk tl1 "$T/wb"
DCQ_MODELS="m1" DCQ_POOL_PAID="go/px" DCQ_POOL_PEN="p/x" DCQ_POOL_TAIL="t/a t/b" DCQ_ALLOWED_FAILS=99 dcq run -j 1 >"$T/tail.out" 2>&1
chk "順序＝免費→懲罰→兜底，兜底過關不碰訂閱" "$(awk '/^IN tl1/{print $4}' "$TRACE" | tr '\n' ' ')" "m1 p/x t/a "
chk "兜底過關" "$(ls "$DCQ_HOME"/done/ 2>/dev/null | wc -l | tr -d ' ')" "1"
# 11e) 2026-10-22：第 2 輪只重試上游失敗的；驗收沒過的模型不再跑第二次（wo-r1：minimax 連跑 245s＋1021s）
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk vf2 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_POOL_PAID="go/px" DCQ_FREE_ROUNDS=2 DCQ_ALLOWED_FAILS=99 dcq run -j 1 >"$T/vf2.out" 2>&1
chk "驗收沒過的不進第 2 輪" "$(grep -c '^IN vf2 .* m[12] ' "$TRACE")" "2"
chk "沒印第 2 輪重試" "$(grep -c '免費層第 2 輪重試' "$T/vf2.out")" "0"
# 11f) 冷宮（0 PASS 的免費模型）排在兜底層之後、訂閱層之前（2026-10-22 使用者定）
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk tl3 "$T/wb"
DCQ_MODELS="m1" DCQ_POOL_PAID="go/px" DCQ_POOL_PEN="p/x" DCQ_POOL_TAIL="n/a" DCQ_POOL_ZERO="z/a" DCQ_ALLOWED_FAILS=99 dcq run -j 1 >"$T/zero.out" 2>&1
chk "順序＝免費→懲罰→兜底→冷宮→訂閱" "$(awk '/^IN tl3/{print $4}' "$TRACE" | tr '\n' ' ')" "m1 p/x n/a z/a go/px "
# 11d) Zen 判濫用閘檔有效：無前綴模型（Zen 免費）一隻都不送，直接懲罰→兜底
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
echo $(( $(date +%s) + 600 )) > "$DC_ZEN_GATE"
mk tl2 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_POOL_PAID="go/px" DCQ_POOL_PEN="p/x" DCQ_POOL_TAIL="t/a" DCQ_ALLOWED_FAILS=99 dcq run -j 1 >"$T/gate.out" 2>&1
chk "Zen 閘內不碰無前綴模型" "$(awk '/^IN tl2/{print $4}' "$TRACE" | tr '\n' ' ')" "p/x t/a "
rm -f "$DC_ZEN_GATE"
# 11e) 10-19：只有 Jev 那份閘封鎖（dc 閘已過期）也要整池跳過
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
printf '{"ok":false,"blocked":true,"cooldown_until":%s}' "$(( ($(date +%s) + 600) * 1000 ))" > "$JEV_ZEN_STATUS_FILE"
mk tl3 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_POOL_PAID="go/px" DCQ_POOL_PEN="p/x" DCQ_POOL_TAIL="t/a" DCQ_ALLOWED_FAILS=99 dcq run -j 1 >"$T/gate2.out" 2>&1
chk "Jev 閘內不碰無前綴模型" "$(awk '/^IN tl3/{print $4}' "$TRACE" | tr '\n' ' ')" "p/x t/a "
rm -f "$JEV_ZEN_STATUS_FILE"
# 11c) 訂閱層（付費）墊底：免費、懲罰、兜底全敗才用
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk up3 "$T/wb"
DCQ_MODELS="m1" DCQ_POOL_PAID="go/px" DCQ_POOL_PEN="p/x" DCQ_POOL_TAIL="t/a" DCQ_ALLOWED_FAILS=99 dcq run -j 1 >"$T/last.out" 2>&1
chk "順序＝免費→懲罰→兜底→訂閱" "$(awk '/^IN up3/{print $4}' "$TRACE" | tr '\n' ' ')" "m1 p/x t/a go/px "
chk "訂閱墊底過關且標 PAID" "$(grep -c '^PAID=1' "$DCQ_HOME"/done/*up3*.job 2>/dev/null)" "1"

# 12) 免費全在冷卻＝免費掛了 → 不等冷卻，直接走訂閱層
dcq clear >/dev/null; : > "$TRACE"
for m in m1 m2; do echo $(( $(date +%s) + 600 )) > "$DCQ_HOME/.health/$m.cool"; done
mk c2 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_POOL_PAID="go/px" dcq run -j 1 >"$T/cool.out" 2>&1
chk "免費全冷卻時直接走訂閱層" "$(grep -c '^IN c2 .* go/px ' "$TRACE")" "1"
chk "不碰冷卻中的免費模型" "$(grep -c '^IN c2 .* m[12] ' "$TRACE")" "0"

# 13) 訂閱層設空 → 免費全冷卻時是等待，不是偷跑付費（用 cancel 收尾）
dcq clear >/dev/null; : > "$TRACE"
for m in m1 m2; do echo $(( $(date +%s) + 600 )) > "$DCQ_HOME/.health/$m.cool"; done
mk c3 "$T/wb"; jid="$(ls -1 "$DCQ_HOME/pending" | head -1)"; jid="${jid%.job}"
DCQ_MODELS="m1 m2" DCQ_POOL_PAID="" dcq run -j 1 >/dev/null 2>&1 &
runner=$!; sleep 3
chk "無訂閱層時不跑任何模型" "$(grep -c '^IN c3' "$TRACE")" "0"
dcq cancel "$jid" >/dev/null 2>&1; wait "$runner"

# 14) 模型標了 DC_TASK_DEFECT 卻沒收手 → watchdog 殺掉後要認工單的錯，不是模型的錯：
#     不罰 m1 進冷卻、不換 m2，直接 FATAL 進 failed（issue #4）
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk defect1 "$T/wb"
# POOL_PAID 設空：這個案例只該走 exit:2 一條路。萬一退化成換模型，也別真的去燒訂閱額度。
DCQ_MODELS="m1 m2" DCQ_POOL_PAID="" DCQ_STALL_S=4 DCQ_ALLOWED_FAILS=1 DCQ_COOLDOWN_S=60 \
  dcq run -j 1 >"$T/defect.out" 2>&1
chk "defect 進 failed" "$(ls -1 "$DCQ_HOME/failed" | wc -l | tr -d ' ')" "1"
chk "defect 標 rc=2" "$(grep -h '^LAST_RC=' "$DCQ_HOME"/failed/*.job)" "LAST_RC=2"
chk "只試 1 隻模型" "$(grep -h '^TRIED=' "$DCQ_HOME"/failed/*.job)" "TRIED=1"
chk "m2 從未被派" "$(grep -c '^IN defect1 .* m2 ' "$TRACE")" "0"
chk "m1 沒被罰進冷卻" "$(DCQ_MODELS="m1 m2" dcq status | grep -c 'm1 .*cooling')" "0"
chk "沒被 bump_fail 冷卻" "$(ls -1 "$DCQ_HOME/.health" | wc -l | tr -d ' ')" "0"
grep -q 'FATAL rc=2' "$T/defect.out" || { echo "FAIL defect 沒走 FATAL rc=2 分支"; fail=1; }
grep -q 'watchdog: m1 stall' "$T/defect.out" || { echo "FAIL defect 沒被 watchdog 殺"; fail=1; }
dcq clear >/dev/null

# 15) 本機確定性錯誤：不同模型連續兩次上游失敗且簽章相同 → 停階梯、不罰模型（issue #6）
# 15a) 同錯：m1、m2 簽章相同 → 第 2 隻就 FATAL rc=2，m3 與付費池從未被派
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk local1 "$T/wb"
DCQ_MODELS="m1 m2 m3" DCQ_POOL_PAID="go/px" DCQ_ALLOWED_FAILS=1 \
  dcq run -j 1 >"$T/local.out" 2>&1
chk "同錯進 failed" "$(ls -1 "$DCQ_HOME/failed" | wc -l | tr -d ' ')" "1"
chk "同錯標 rc=2" "$(grep -h '^LAST_RC=' "$DCQ_HOME"/failed/*.job)" "LAST_RC=2"
chk "同錯只試 2 隻" "$(grep -h '^TRIED=' "$DCQ_HOME"/failed/*.job)" "TRIED=2"
chk "m3 從未被派" "$(grep -c '^IN local1 .* m3 ' "$TRACE")" "0"
chk "付費池從未被派" "$(grep -c '^IN local1 .* go/px ' "$TRACE")" "0"
chk "沒被 bump_fail 冷卻" "$(ls -1 "$DCQ_HOME/.health" | wc -l | tr -d ' ')" "0"
grep -q '本機確定性錯誤' "$T/local.out" || { echo "FAIL 同錯沒走本機確定性錯誤分支"; fail=1; }

# 15b) 不同錯：三隻簽章各異 → 統統試過（TRIED=3），證明沒有誤停
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk diff1 "$T/wb"
DCQ_MODELS="m1 m2 m3" DCQ_POOL_PAID="" DCQ_ALLOWED_FAILS=99 \
  dcq run -j 1 >"$T/diff.out" 2>&1
chk "不同錯三隻都試" "$(grep -h '^TRIED=' "$DCQ_HOME"/failed/*.job)" "TRIED=3"
chk "不同錯 rc=1" "$(grep -h '^LAST_RC=' "$DCQ_HOME"/failed/*.job)" "LAST_RC=1"
chk "全死在上游 VERIFY_RUNS=0" "$(grep -h '^VERIFY_RUNS=' "$DCQ_HOME"/failed/*.job)" "VERIFY_RUNS=0"

# 15c) 有交件但驗收不過：每次嘗試都跑到 dc 的驗收 → VERIFY_RUNS＝嘗試數（呼叫端據此判驗收失敗，不是基礎設施失敗）
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk vf1 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_POOL_PAID="" DCQ_ALLOWED_FAILS=99 dcq run -j 1 >"$T/vf.out" 2>&1
chk "驗收失敗 VERIFY_RUNS=2" "$(grep -h '^VERIFY_RUNS=' "$DCQ_HOME"/failed/*.job)" "VERIFY_RUNS=2"

# 16) .out 權限與遮罩（issue #5）：600 空檔先建、跑完遮罩掉假憑證、過期刪、既存 644 收成 600
dcq clear >/dev/null
touch -t 202001010000 "$DCQ_HOME/logs/old.out"
: > "$DCQ_HOME/logs/keep.out"; chmod 644 "$DCQ_HOME/logs/keep.out"
mk leak1 "$T/wb"
DCQ_MODELS="m1" DCQ_POOL_PAID="" dcq run -j 1 >"$T/leak.out" 2>&1
chk "leak1 進 done" "$(ls -1 "$DCQ_HOME/done" | wc -l | tr -d ' ')" "1"
leakout="$(ls -1 "$DCQ_HOME"/logs/*leak1*.out 2>/dev/null | head -1)"
perms=$(stat -c %a "$leakout" 2>/dev/null || stat -f %Lp "$leakout" 2>/dev/null)
chk "leak1 的 .out 權限 600" "$perms" "600"
if grep -q "sk-$(printf 'x%.0s' $(seq 16))" "$leakout" 2>/dev/null; then
  echo "FAIL .out 沒遮罩（還找得到假憑證）"; fail=1
else
  echo "PASS .out 已遮罩（找不到假憑證）"
fi
chk "過期 .out 已刪(old.out)" "$([ -e "$DCQ_HOME/logs/old.out" ] && echo yes || echo no)" "no"
keepperms=$(stat -c %a "$DCQ_HOME/logs/keep.out" 2>/dev/null || stat -f %Lp "$DCQ_HOME/logs/keep.out" 2>/dev/null)
chk "既存 644 的 .out 被收成 600" "$keepperms" "600"

# 17) status 的 running 數只算 .job：running/ 同時有 .job 與 .pid，1 張不能顯示成 2
dcq clear >/dev/null
: > "$DCQ_HOME/running/x.job"; : > "$DCQ_HOME/running/x.pid"
chk "status running 只算 .job" "$(dcq status | awk '$1=="running"{print $2}')" "1"
rm -f "$DCQ_HOME/running/x.job" "$DCQ_HOME/running/x.pid"

# 18) 活著的 runner 在跑時第二個 run 要被拒：否則孤兒回收會搶走它正在跑的 job
dcq clear >/dev/null
sleep 60 & live=$!
echo "$live" > "$DCQ_HOME/.runner.pid"
mk a9 "$T/wa"
rc=0; DCQ_MODELS="m1" dcq run -j 1 >"$T/dup.out" 2>&1 || rc=$?
chk "第二個 runner 被拒 rc=2" "$rc" "2"
chk "被拒時 pending 沒被動" "$(ls "$DCQ_HOME/pending" | wc -l | tr -d ' ')" "1"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
# 持有者已死＝孤兒 pid 檔，照跑
DCQ_MODELS="m1" dcq run -j 1 >/dev/null 2>&1
chk "runner pid 檔是孤兒時照跑完" "$(ls "$DCQ_HOME/done" | grep -c a9 | tr -d ' ')" "1"
chk "runner 收工後刪 pid 檔" "$([ -e "$DCQ_HOME/.runner.pid" ] && echo yes || echo no)" "no"

# 19) start：runner 進獨立 tmux（呼叫端死了它還活著），且同時只准一個
if command -v tmux >/dev/null; then
  export DCQ_TMUX="dcqtest$$"
  dcq clear >/dev/null
  mk a10 "$T/wa"
  DCQ_MODELS="m1" dcq start -j 1 >/dev/null 2>&1
  rc=0; DCQ_MODELS="m1" dcq start -j 1 >/dev/null 2>&1 || rc=$?
  chk "第二個 start 被拒 rc=2" "$rc" "2"
  for _ in $(seq 1 30); do ls "$DCQ_HOME/done" | grep -q a10 && break; sleep 1; done
  chk "start 的 runner 跑完工單" "$(ls "$DCQ_HOME/done" | grep -c a10 | tr -d ' ')" "1"
  grep -q "dcq: 起 1 個 slot" "$DCQ_HOME/logs/runner.log" 2>/dev/null; chk "runner.log 有輸出" "$?" "0"
  tmux -L "$DCQ_TMUX" kill-server 2>/dev/null
else
  echo "SKIP 19) 沒有 tmux"
fi

# 20) wait：start 脫離後呼叫端靠 wait 拿完成訊號（零 token）；rc 反映成敗
dcq clear >/dev/null
mk a11 "$T/wa"; mk bad2 "$T/wb"
ida="$(basename "$(ls "$DCQ_HOME"/pending/*.job | head -1)" .job)"
DCQ_MODELS="m1" dcq run -j 2 >/dev/null 2>&1 &
rc=0; out="$(dcq wait --timeout 60)" || rc=$?
chk "wait 無 id：有 failed 回 rc=1" "$rc" "1"
rc=0; dcq wait "$ida" >/dev/null || rc=$?
echo "$ida" | grep -q a11 && chk "wait 指定通過的 id 回 0" "$rc" "0"
rc=0; dcq wait nope-id >/dev/null || rc=$?
chk "wait 不存在的 id 回 1" "$rc" "1"
mk slow9 "$T/wa"
rc=0; dcq wait --timeout 1 >/dev/null 2>&1 || rc=$?
chk "wait 逾時回 124" "$rc" "124"
dcq clear >/dev/null

# 21) 10-21：半開只放 1 個探測 —— Zen 閘已到期但還有被封紀錄（streak）時，
#     zen 這個 provider 的併發上限壓到 1；不是半開時照 providers.tsv 的上限（2）。
#     對照組先跑：兩個 zen job 可以併發；半開組則要排隊。
zen_par() { awk '$4 !~ /\// {if($1=="IN")c++;else c--; if(c>m)m=c} END{print m+0}' "$TRACE"; }
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk ho1 "$T/wa"; mk ho2 "$T/wb"
echo $(( $(date +%s) - 10 )) > "$DC_ZEN_GATE"; rm -f "$DC_ZEN_GATE.streak" "$JEV_ZEN_STATUS_FILE"
DCQ_MODELS="m1 m2" DCQ_PROV_MAX="zen=2" DCQ_ALLOWED_FAILS=99 dcq run -j 2 >"$T/ho1.out" 2>&1
chk "對照：非半開時 zen 可併發 2" "$(zen_par)" "2"
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk ho3 "$T/wa"; mk ho4 "$T/wb"
echo $(( $(date +%s) - 10 )) > "$DC_ZEN_GATE"; echo 3 > "$DC_ZEN_GATE.streak"; rm -f "$JEV_ZEN_STATUS_FILE"
DCQ_MODELS="m1 m2" DCQ_PROV_MAX="zen=2" DCQ_ALLOWED_FAILS=99 dcq run -j 2 >"$T/ho2.out" 2>&1
chk "半開時 zen 只放 1 個探測" "$(zen_par)" "1"
chk "半開時兩張都跑完" "$(ls -1 "$DCQ_HOME/done" | wc -l | tr -d ' ')" "2"
dcq clear >/dev/null

# 22) 2026-10-21 前置檢查憑證：同一張工單的每次嘗試收到同一個 DC_PREFLIGHT_DIR；
#     工單結束（PASS／FAIL）後那個目錄要被刪掉（憑證只對這張工單有效）。
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"; : > "$PFLOG"
mk up5 "$T/wb"; mk pf2 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_ALLOWED_FAILS=99 dcq run -j 1 >"$T/pf.out" 2>&1
chk "up5 換過一次模型（兩次嘗試）" "$(grep -c '^IN up5 ' "$TRACE")" "2"
pfpath="$(awk '$1=="up5"{print $2}' "$PFLOG" | head -1)"
chk "兩次嘗試收到同一個 DC_PREFLIGHT_DIR" "$(awk '$1=="up5"{print $2}' "$PFLOG" | sort -u | wc -l | tr -d ' ')" "1"
case "$pfpath" in "$DCQ_HOME"/.preflight/*) pfok=yes ;; *) pfok=no ;; esac
chk "DC_PREFLIGHT_DIR 在 .preflight/ 下" "$pfok" "yes"
chk "FAIL 結束後該目錄已刪" "$([ -e "$pfpath" ] && echo yes || echo no)" "no"
pfpath2="$(awk '$1=="pf2"{print $2}' "$PFLOG" | head -1)"
chk "PASS 的工單也有收到 DC_PREFLIGHT_DIR" "$([ -n "$pfpath2" ] && echo yes || echo no)" "yes"
chk "PASS 結束後該目錄已刪" "$([ -e "$pfpath2" ] && echo yes || echo no)" "no"
dcq clear >/dev/null

# 16) 總時限到但模型已交件：殺掉後 dcq 自己用 pin 跑一次驗收，過就 PASS（10-22 cabinet R1／R8 做完仍記 FAIL rc=124）
# 16a) 驗收過 → done，不換第二隻
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk jm1 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_POOL_PAID="" DCQ_JOB_MAX=3 dcq run -j 1 >"$T/jm.out" 2>&1
chk "總時限到但驗收過 → done" "$(ls -1 "$DCQ_HOME/done" | wc -l | tr -d ' ')" "1"
grep -q '總時限.*驗收通過' "$T/jm.out" || { echo "FAIL jm1 沒印「總時限到但驗收通過」"; fail=1; }
chk "jm1 沒換第二隻模型" "$(grep -c '^IN jm1 .* m2 ' "$TRACE")" "0"
# 16b) 驗收不過 → 照舊 FAIL rc=124
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk jmf1 "$T/wb"
DCQ_MODELS="m1 m2" DCQ_POOL_PAID="" DCQ_JOB_MAX=3 dcq run -j 1 >"$T/jmf.out" 2>&1
chk "總時限到且驗收不過 → failed" "$(ls -1 "$DCQ_HOME/failed" | wc -l | tr -d ' ')" "1"
chk "jmf1 rc=124" "$(grep -h '^LAST_RC=' "$DCQ_HOME"/failed/*.job)" "LAST_RC=124"

# 17) 上游不可用提早結束：簽章是同一段 prompt 回顯，不同模型必相同 → 不得判同錯（10-22 cabinet R4 兩次誤停）
dcq clear >/dev/null; rm -rf "$DCQ_HOME/.health"/*; : > "$TRACE"
mk ux1 "$T/wb"
DCQ_MODELS="m1 m2 m3" DCQ_POOL_PAID="" DCQ_ALLOWED_FAILS=99 dcq run -j 1 >"$T/ux.out" 2>&1
chk "上游提早結束三隻都試" "$(grep -h '^TRIED=' "$DCQ_HOME"/failed/*.job)" "TRIED=3"
grep -q 'FATAL rc=2' "$T/ux.out" && { echo "FAIL ux1 被誤判同錯"; fail=1; }
dcq clear >/dev/null

# 27) id=$(dcq add …) 只拿到 job id：deep-lint 印「LINT OK」不能混進 stdout（fix 10521，Grok bot 派o 回 1）
printf '#!/bin/sh\necho "LINT OK"\nexit 0\n' > "$T/bin/deep-lint"
printf '# idl\n' > "$T/idl.md"; idl="$(dcq add "$T/idl.md" "$T/wb" 2>/dev/null)"
chk "add 的 stdout 只有一行" "$(printf '%s\n' "$idl" | wc -l | tr -d ' ')" "1"
chk "add 的 stdout 就是 pending 的 job id" "$([ -e "$DCQ_HOME/pending/$idl.job" ] && echo yes || echo no)" "yes"
dcq clear >/dev/null

exit $fail
