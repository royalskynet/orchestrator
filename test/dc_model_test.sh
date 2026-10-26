#!/usr/bin/env bash
# dc 的計費分級自檢：全部照派，非免費一定要發 TG 警示；免費的不准吵。
# 用假的 opencode 記下實際被派的 -m、假的 hpush 記下警示，不打上游也不真發 TG。
set -u
. "$(dirname "$0")/env.sh"
DC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘（10-19：Jev 閘封鎖時這些測試全掛）
mkdir -p "$T/bin" "$T/w" "$T/cfg/opencode"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
export DC_TG_EVERY=0  # 逐條驗警示內容；限流另外測
export DC_PUSH=1      # DCQ_HOME 是暫存目錄，dc 預設不推；這裡要驗推播內容（配假 hpush）
# DC_NEGCTL=0：這些測試的 wo-verify 是 `exit 0` 的假貨，do-nothing 對照會當場中止派工。
# 負向對照本身由 dc_verify_gate_test.sh 驗。
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0
# 假 key：測閘門不測憑證，也不讓測試去讀真的 kv
export OMNIROUTE_API_KEY=fake OPENCODE_API_KEY=fake
export TRACE="$T/trace" PUSH="$T/push"

cat > "$T/bin/opencode" <<'X'
#!/usr/bin/env bash
[ "$1" = debug ] && { echo '{}'; exit 0; }
m=""; prev=""
for a in "$@"; do [ "$prev" = "-m" ] && m="$a"; prev="$a"; done
echo "RUN $m" >> "$TRACE"
X
printf '#!/bin/sh\necho "$*" >> "$PUSH"\n' > "$T/bin/hpush"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; done
chmod +x "$T/bin"/*
printf '# t\n' > "$T/t.md"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
# 印「有沒有跑:警示的計費層」，例如 ran:- 或 ran:metered；rejected＝rc=2 且沒叫起 opencode
try() { : > "$TRACE"; : > "$PUSH"; env "$@" "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1; rc=$?
  sleep 0.3  # hpush 是背景送
  r=rejected; grep -q '^RUN ' "$TRACE" && r=ran; [ "$r" = rejected ] && [ "$rc" != 2 ] && r="rc=$rc"
  w="$(grep -oE '（(sub|metered)）' "$PUSH" | tr -d '（）' | head -1)"; echo "$r:${w:--}"; }

chk "免費 opencode/*-free 不吵"             "$(try DC_FREE_MODEL=opencode/mimo-v2.6-flash-free)" ran:-
chk "裸名 big-pickle 不吵"                  "$(try DC_FREE_MODEL=big-pickle)" ran:-
chk "Go 免費模型不吵"                       "$(try DC_FREE_MODEL=opencode-go/space-bunny-free)" ran:-
chk "omniroute/free-tools 不吵"             "$(try DC_FREE_MODEL=omniroute/free-tools)" ran:-
chk "Go 訂閱照派＋警示 sub"                 "$(try DC_FREE_MODEL=opencode-go/glm-5.3)" ran:sub
chk "Zen 按量照派＋警示 metered"            "$(try DC_FREE_MODEL=opencode/kimi-k3)" ran:metered
# *-free 只在 opencode 系算數：別家組合名帶 -free 不代表成員全免費
chk "omniroute 其他組合(名字帶 -free)要警示" "$(try DC_FREE_MODEL=omniroute/auto/best-free)" ran:metered
chk "陌生 provider 帶 -free 要警示"         "$(try DC_FREE_MODEL=openrouter/x-free)" ran:metered
# DC_FREE_EXTRA 列完整 id 對任何 provider 都算 free（遠端 OmniRoute combo 成員，如 Grok 端）；沒列的照舊警示
chk "DC_FREE_EXTRA 完整 id 不吵"            "$(try DC_FREE_EXTRA='omniroute/x omniroute/gemini/g-flash' DC_FREE_MODEL=omniroute/gemini/g-flash)" ran:-
chk "DC_FREE_EXTRA 沒列到的仍警示"          "$(try DC_FREE_EXTRA='omniroute/gemini/g-flash' DC_FREE_MODEL=omniroute/gemini/g-pro)" ran:metered
# 帳目錄是暫存路徑（非 ~/.dcq）且沒 DC_PUSH=1：不推播（測試、手動試跑不發真 TG，10-21）
chk "暫存帳目錄不推播"                      "$(try DC_PUSH= DC_FREE_MODEL=opencode/kimi-k3)" ran:-
: > "$TRACE"; : > "$PUSH"; "$DC" "$T/t.md" "$T/w" -- -m opencode/kimi-k3 >/dev/null 2>&1; sleep 0.3
chk "-m 旗標指定的付費模型也要警示"         "$(grep -c 'opencode/kimi-k3（metered）' "$PUSH")" 1
# TG 限流：窗口內第二筆只落帳不發，窗口過後的那則附上被壓掉的筆數
: > "$T/q/logs/billing.tsv"; rm -f "$T/q/logs/.billing-tg-last"
try DC_TG_EVERY=600 DC_FREE_MODEL=opencode-go/glm-5.3 >/dev/null
chk "限流：窗口內第二筆不發 TG"             "$(try DC_TG_EVERY=600 DC_FREE_MODEL=opencode-go/glm-5.3)" ran:-
chk "限流：被壓的照樣落帳"                  "$(grep -c glm-5.3 "$T/q/logs/billing.tsv")" 2
touch -t 202001010000 "$T/q/logs/.billing-tg-last"; : > "$TRACE"; : > "$PUSH"
DC_TG_EVERY=600 DC_FREE_MODEL=opencode-go/glm-5.3 "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1; sleep 0.3
chk "限流：窗口過後發，並附被壓筆數"        "$(grep -c '另有 1 筆被限流' "$PUSH")" 1
# TG 送不出去不能拖垮派工，也不能讓這筆花費沒留下紀錄
# 不能 rm 假 hpush：PATH 後面有真的 ~/.local/bin/hpush，刪了會真發 TG。改成送失敗的假 hpush。
printf '#!/bin/sh\nexit 1\n' > "$T/bin/hpush"; : > "$T/q/logs/billing.tsv"
chk "hpush 失敗照派"                     "$(try DC_FREE_MODEL=opencode/kimi-k3)" ran:-
chk "hpush 失敗也記進 billing.tsv"       "$(grep -c "metered	opencode/kimi-k3" "$T/q/logs/billing.tsv")" 1
chk "免費模型不進 billing.tsv"              "$(try DC_FREE_MODEL=big-pickle >/dev/null; grep -c big-pickle "$T/q/logs/billing.tsv")" 0
# omniroute 沒 key：要在派工前就停，不是送空 key 去吃 401
chk "omniroute 沒 key 不派"                 "$(try OMNIROUTE_API_KEY= HOME="$T" DC_FREE_MODEL=omniroute/free-tools)" rejected:-

# 模型回報工單瑕疵：dc 必須 exit 2，且完全不跑驗收（issue #4）。
# 驗收的假 wo-verify 改成落 marker 檔 —— 用「跑完 rc=0」當通關證明不了它沒被叫。
# 只認驗收那次：派工前的准入閘會呼叫 --dry 驗語法、--dump 拍 pin，那兩次不算跑驗收。
printf '#!/bin/sh\ncase "${2:-}" in --dry|--dump) ;; *) touch "$WV_MARK";; esac\nexit 0\n' > "$T/bin/wo-verify"
cat > "$T/bin/opencode" <<'X'
#!/usr/bin/env bash
[ "$1" = debug ] && { echo '{}'; exit 0; }
echo "DC_TASK_DEFECT: line 1 x"
exit 0
X
chmod +x "$T/bin/opencode" "$T/bin/wo-verify"
export WV_MARK="$T/wv.called"; rm -f "$WV_MARK"
DC_FREE_MODEL=opencode/mimo-v2.6-flash-free "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1; drc=$?
chk "標了 DC_TASK_DEFECT 就 exit 2"          "$drc" "2"
chk "不跑驗收"                              "$([ -e "$WV_MARK" ] && echo called || echo skipped)" "skipped"
# 反向：同一個 opencode 沒標記時，驗收照跑（別把 DC_TASK_DEFECT 通道寫成無條件擋）
printf '#!/bin/sh\nexit 0\n' > "$T/bin/opencode"; chmod +x "$T/bin/opencode"
rm -f "$WV_MARK"
DC_FREE_MODEL=opencode/mimo-v2.6-flash-free "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1
chk "沒標記時照跑驗收"                      "$([ -e "$WV_MARK" ] && echo called || echo skipped)" "called"
# 反向：模型回「DC_TASK_DEFECT: N/A」＝沒有瑕疵，驗收照跑
printf '#!/bin/sh\n[ "$1" = debug ] && { echo "{}"; exit 0; }\necho "DC_TASK_DEFECT: N/A - No defect found."\nexit 0\n' > "$T/bin/opencode"
rm -f "$WV_MARK"
DC_FREE_MODEL=opencode/mimo-v2.6-flash-free "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1
chk "DEFECT: N/A 照跑驗收"                  "$([ -e "$WV_MARK" ] && echo called || echo skipped)" "called"

# opencode 遇 429 會照 retry-after 久等重試（PR #44517 前無設定可關）：dc 要看到主 agent 的限流 log 就砍掉、rc=1 快速失敗
cat > "$T/bin/opencode" <<'X'
#!/usr/bin/env bash
[ "$1" = debug ] && { echo '{}'; exit 0; }
echo "timestamp=x level=ERROR message=\"stream error\" small=false agent=build error.error=\"AI_APICallError: Rate limit exceeded. Please try again later.\"" >&2
echo $$ > "$OC_PID"; sleep 60
X
chmod +x "$T/bin/opencode"; export OC_PID="$T/oc.pid"
s=$(date +%s)
DC_FREE_MODEL=opencode/mimo-v2.6-flash-free "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1; rrc=$?
chk "主 agent 限流 → rc=1"                   "$rrc" "1"
chk "10 秒內結束（不等 opencode 重試）"      "$([ $(( $(date +%s) - s )) -lt 10 ] && echo fast || echo slow)" "fast"
chk "opencode 已被殺"                        "$(kill -0 "$(cat "$OC_PID")" 2>/dev/null && echo alive || echo dead)" "dead"
# 反向：只有取標題的小模型（small=true）限流，主程序照常跑完
cat > "$T/bin/opencode" <<'X'
#!/usr/bin/env bash
[ "$1" = debug ] && { echo '{}'; exit 0; }
echo "level=ERROR small=true agent=title error.error=\"Rate limit exceeded.\"" >&2
sleep 2; exit 0
X
DC_FREE_MODEL=opencode/mimo-v2.6-flash-free "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1
chk "標題小模型限流不殺主程序"              "$?" "0"

exit $fail
