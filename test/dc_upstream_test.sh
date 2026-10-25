#!/usr/bin/env bash
# dc 的上游提早結束自檢：opencode 碰到上游不可用／限流／啟動卡住時會自己久等或重試，
# dc 要在幾秒內以 rc=1 結束（dcq 才會換模型），而且不能跑驗收。正常開工的不可被誤殺。
# 假 opencode 照真實 log 格式吐一行 ERROR 後 sleep，模擬它在程序內重試。
set -u
. "$(dirname "$0")/env.sh"
DC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/w" "$T/cfg/opencode"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
# DC_NEGCTL=0：這些測試的 wo-verify 是 `exit 0` 的假貨，do-nothing 對照會當場中止派工。
# 負向對照本身由 dc_verify_gate_test.sh 驗。
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0
export VERIFIED="$T/verified" DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"

cat > "$T/bin/opencode" <<X
T=$T
X
cat >> "$T/bin/opencode" <<'X'
#!/usr/bin/env bash
[ "$1" = debug ] && { echo '{}'; exit 0; }
e='timestamp=2026-10-11T02:48:47.936Z level=ERROR run=b4472e2a message="stream error" providerID=opencode modelID=x session.id=ses_x small=false agent=build mode=primary error.error="AI_APICallError:'
case "$FAKE" in
  unavail)  echo '> build · x'; echo "$e Upstream request failed: Model is unavailable.\""; sleep 30 ;;
  endpoint) echo '> build · x'; echo "$e Upstream request failed: Endpoint is unavailable.\""; sleep 30 ;;
  gone)     echo '> build · x'; echo "$e Model exo-free has been deprecated.\""; sleep 30 ;;
  ratelimit) echo '> build · x'; echo "$e Rate limit exceeded\""; sleep 30 ;;
  abuse)    : > "$T/called"; echo '> build · x'; echo "$e Forbidden, OpenCode Free Model Gateway Detect Abuse Traffic\""; sleep 30 ;;
  abuse2)   echo '> build · x'; echo "Error: OpenCode's free models aren't available from your current network because we've detected abusive traffic from this IP address."; sleep 30 ;;
  freetier) echo '> build · x'; echo "$e OpenCode's free tier can only be used from within OpenCode. Download it at https://opencode.ai and keep building.\""; sleep 30 ;;
  # issue #8：額度錯誤原文（M2 實例，含 ANSI）。opencode 對 Zen／Go 額度是自己馬上 rc=1 結束
  zenquota) echo '> build · x'; printf '\033[91m\033[1mError: \033[0mFree usage limit reached. Connect a provider or subscribe to OpenCode Go to keep going, or switch models.\n'; exit 1 ;;
  goquota)  echo '> build · x'; printf '\033[91m\033[1mError: \033[0mGo usage limit exceeded\n'; exit 1 ;;
  gquota)   echo '> build · x'; echo "$e You exceeded your current quota, please check your plan and billing details. Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 20\""; sleep 30 ;;
  grpm)     echo '> build · x'; echo "$e You exceeded your current quota. quotaId: GenerateRequestsPerMinutePerProjectPerModel-FreeTier\""; sleep 30 ;;
  quotatalk) echo '> build · x'; echo 'log 裡寫著 Free usage limit reached 是另一回事'; echo done ;;
  ok)       : > "$T/called"; echo '> build · x'; echo done ;;
  selfcat)  echo '> build · x'; cat "$DCSRC"; echo done ;;
  hang)     sleep 30 ;;
  slow)     echo '> build · x'; sleep 4; echo done ;;
  title)    echo "${e/small=false/small=true} Upstream request failed: Model is unavailable.\""; echo '> build · x'; echo done ;;
esac
X
# dc 派工前會先跑 wo-verify --dry 驗語法、--dump 拍 pin，那兩次不算跑驗收
printf '#!/bin/sh\ncase "$2" in --dry|--dump) ;; *) echo ok > "$VERIFIED";; esac\nexit 0\n' > "$T/bin/wo-verify"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/hpush"
chmod +x "$T/bin"/*
printf '# t\n' > "$T/t.md"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
# 印「rc:有沒有跑驗收:秒數是否在上限內:錯誤訊息關鍵字」
try() { local lim="$1" key="$2"; shift 2; rm -f "$VERIFIED"; local s=$(date +%s)
  env "$@" "$DC" "$T/t.md" "$T/w" > "$T/err" 2>&1; local rc=$? d=$(( $(date +%s) - s ))
  local v=no; [ -f "$VERIFIED" ] && v=yes
  local f=slow; [ "$d" -le "$lim" ] && f=fast
  local k=nokey; grep -q "$key" "$T/err" && k=key
  echo "$rc:$v:$f:$k"; }

chk "Model is unavailable 提早結束"       "$(try 8 '上游不可用' FAKE=unavail)"  1:no:fast:key
chk "Endpoint is unavailable 提早結束"    "$(try 8 'Endpoint is unavailable' FAKE=endpoint)" 1:no:fast:key
chk "已下架提早結束"                       "$(try 8 'has been deprecated' FAKE=gone)" 1:no:fast:key
chk "限流照舊提早結束"                     "$(try 8 '上游限流' FAKE=ratelimit)" 1:no:fast:key
chk "啟動卡住在 DC_START_S 內結束"         "$(try 8 '沒開工' FAKE=hang DC_START_S=3)" 1:no:fast:key
# 開工後的靜默不歸 dc 管（STALL_S 在 dcq），不可被啟動看門狗誤殺
chk "已開工的慢模型不誤殺"                 "$(try 15 '提早結束\|沒開工' FAKE=slow DC_START_S=2)" 0:yes:fast:nokey
# 只認主 agent：small=true（取標題等小模型）的上游錯誤不算
chk "小模型錯誤不觸發"                     "$(try 8 '上游不可用' FAKE=title)" 0:yes:fast:nokey
# Zen 判濫用：提早結束、寫全域閘檔；閘檔有效期間 Zen 模型不送請求（opencode 不被呼叫），非 Zen 模型照跑
chk "判濫用提早結束"                       "$(try 8 '判濫用' FAKE=abuse)" 1:no:fast:key
chk "判濫用寫閘檔"                         "$([ "$(cat "$T/zen-gate" 2>/dev/null || echo 0)" -gt "$(date +%s)" ] && echo y)" y
rm -f "$T/called"
chk "閘內 Zen 不送請求"                    "$(try 8 '冷卻中' FAKE=ok)" 1:no:fast:key
chk "閘內 opencode 未被呼叫"               "$([ -e "$T/called" ] && echo called || echo none)" none
chk "閘內非 Zen 照跑"                      "$(try 8 '冷卻中' FAKE=ok DC_FREE_MODEL=omniroute/or-free)" 0:yes:fast:nokey
echo 0 > "$T/zen-gate"; rm -f "$T/jev-zen.json"   # dc 判濫用兩份閘都寫，過期要兩份都過
chk "閘過期 Zen 恢復"                      "$(try 8 '冷卻中' FAKE=ok)" 0:yes:fast:nokey
# 10-21：模型 cat 了 dc 原始碼（改 dc 的工單），原始碼裡的偵測字串不可觸發判濫用／限流／不可用
chk "模型印出 dc 原始碼不誤判"             "$(try 8 '^dc: .*\(判濫用\|上游限流\|上游不可用\)' FAKE=selfcat DCSRC="$DC")" 0:yes:fast:nokey
chk "模型印出 dc 原始碼不寫閘"             "$(cat "$T/zen-gate")" 0
# 10-18 起的新措辭（IP 判濫用，連官方客戶端也擋）同樣要整池停用
chk "新措辭判濫用提早結束"                 "$(try 8 '判濫用' FAKE=abuse2)" 1:no:fast:key
chk "新措辭寫閘檔"                         "$([ "$(cat "$T/zen-gate" 2>/dev/null || echo 0)" -gt "$(date +%s)" ] && echo y)" y
# 10-22：FreeTierError（10-18 整個 IP 中、dc 照打 74 次）也要整池停用
echo 0 > "$T/zen-gate"; rm -f "$T/jev-zen.json"
chk "FreeTierError 判濫用提早結束"         "$(try 8 '判濫用' FAKE=freetier)" 1:no:fast:key
chk "FreeTierError 寫閘檔"                 "$([ "$(cat "$T/zen-gate" 2>/dev/null || echo 0)" -gt "$(date +%s)" ] && echo y)" y
# 10-19：閘有兩份（dc 秒／Jev 毫秒＋blocked）。06:00 dc 閘已過期、Jev 閘仍封鎖，dc 系仍照打。
# 任一份封鎖都要擋；Jev 的額度冷卻（blocked=false）不是 IP 封鎖，不擋。
echo 0 > "$T/zen-gate"; rm -f "$T/called"
printf '{"ok":false,"blocked":true,"cooldown_until":%s}' "$(( ($(date +%s) + 3600) * 1000 ))" > "$T/jev-zen.json"
chk "Jev 閘封鎖時 dc 也不送 Zen"          "$(try 8 '冷卻中' FAKE=ok)" 1:no:fast:key
chk "Jev 閘封鎖時 opencode 未被呼叫"      "$([ -e "$T/called" ] && echo called || echo none)" none
printf '{"ok":false,"blocked":false,"cooldown_until":%s}' "$(( ($(date +%s) + 3600) * 1000 ))" > "$T/jev-zen.json"
chk "Jev 額度冷卻不擋 dc"                 "$(try 8 '冷卻中' FAKE=ok)" 0:yes:fast:nokey
# dc 判濫用時兩份閘都要寫，Jev 那邊才會停打
echo '{"ok":true,"model":"jev-1.13-free"}' > "$T/jev-zen.json"
try 8 '判濫用' FAKE=abuse2 >/dev/null
chk "dc 判濫用也寫 Jev 閘"                "$(jq -r '"\(.blocked):\(.cooldown_until > (now*1000)):\(.model)"' "$T/jev-zen.json" 2>/dev/null)" "true:true:jev-1.13-free"
# 10-21：Zen 閘的延遲倍增靠「上游有正常回應」解封（zen-gate ok 清掉失敗計數）。
# 恢復判準是「請求被上游正常回應」，不是「工單通過」——驗收過不過不影響退避歸零。
echo 0 > "$T/zen-gate"; rm -f "$T/jev-zen.json"; echo 3 > "$T/zen-gate.streak"
try 8 'x' FAKE=ok >/dev/null
chk "上游正常回應後清掉失敗計數"            "$([ -f "$T/zen-gate.streak" ] && echo yes || echo no)" "no"
# 判濫用那一路相反：是 trip（計數 +1），不能把計數清掉
echo 0 > "$T/zen-gate"; rm -f "$T/jev-zen.json"; echo 3 > "$T/zen-gate.streak"
try 8 '判濫用' FAKE=abuse2 >/dev/null
chk "判濫用不清計數（反而 +1）"            "$(cat "$T/zen-gate.streak" 2>/dev/null)" "4"
# issue #8：額度用完提早結束並印可辨識的一行（dcq 據此記 quota、冷卻到重置，不記模型的帳）
echo 0 > "$T/zen-gate"; rm -f "$T/jev-zen.json"
chk "Zen 額度用完判 quota"                 "$(try 8 '^dc: 上游額度用完（Free usage limit reached）' FAKE=zenquota)" 1:no:fast:key
chk "Go 額度用完判 quota"                  "$(try 8 '^dc: 上游額度用完（Go usage limit exceeded）' FAKE=goquota)" 1:no:fast:key
chk "Google RPD 判 quota 且提早結束"        "$(try 8 '^dc: 上游額度用完' FAKE=gquota DC_FREE_MODEL=google/x)" 1:no:fast:key
chk "Google RPD 不標每分鐘"                "$(try 8 '額度窗口＝每分鐘' FAKE=gquota DC_FREE_MODEL=google/x)" 1:no:fast:nokey
chk "Google RPM 標每分鐘"                  "$(try 8 '^dc: 額度窗口＝每分鐘' FAKE=grpm DC_FREE_MODEL=google/x)" 1:no:fast:key
chk "模型輸出提到額度字樣不誤判"           "$(try 8 '上游額度用完' FAKE=quotatalk)" 0:yes:fast:nokey
chk "額度用完不寫 Zen 濫用閘"              "$(cat "$T/zen-gate")" 0
exit "$fail"
