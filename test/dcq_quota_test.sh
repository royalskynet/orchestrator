#!/usr/bin/env bash
# 額度／上游錯誤不記模型的帳（issue #8）、Zen 額度整池冷卻到 UTC 午夜（#10）、Google 冷卻到太平洋午夜（#11）、
# 免費池剔出要看得到（#9）、OmniRoute 連不到就剔出（#12）。
set -u
. "$(dirname "$0")/env.sh"
T="$(mktemp -d)"; trap '[ -n "${KEEP:-}" ] && echo "T=$T" || rm -rf "$T"' EXIT
export DCQ_HOME="$T/q"; mkdir -p "$T/bin" "$T/w1" "$T/w2" "$T/w3" "$T/cfg/opencode"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH" XDG_CONFIG_HOME="$T/cfg"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json" TRACE="$T/trace" DCQ_GO_STATE="$T/none.json"
export DCQ_ZEN_MODELS_URL="file://$T/none.json"
mkdir -p "$T/cat"; cp "$(cd "$(dirname "$0")/.." && pwd)/catalog/"*.tsv "$T/cat/"; export DCQ_CATALOG="$T/cat"
: > "$TRACE"; echo '{}' > "$T/cfg/opencode/opencode.json"
# 假 dc：照真 dc 提早結束時印的那行
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$1" .md) $DC_FREE_MODEL" >> "$TRACE"
case "$DC_FREE_MODEL" in
  zen-a)        echo "Error: Free usage limit reached."; echo "dc: 上游額度用完（Free usage limit reached），已提早結束"; exit 1 ;;
  google/g1)    echo "dc: 上游額度用完（Quota exceeded for metric），已提早結束"; exit 1 ;;
  google/g2)    echo "dc: 上游額度用完（You exceeded your current quota），已提早結束"; echo "dc: 額度窗口＝每分鐘"; exit 1 ;;
  kilo/k1)      echo "dc: 上游限流（429），opencode 會照 retry-after 久等重試，已提早結束"; exit 1 ;;
  kilo/bad)     echo "boom"; echo "dc: opencode run rc=1（常見：上游掛=1、逾時=124、權限拒絕）"; exit 1 ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/wo-verify"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/opencode"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/hpush"
chmod +x "$T/bin/"*
DCQ="$(cd "$(dirname "$0")/.." && pwd)/bin/dcq"
dcq() { "$DCQ" "$@"; }
add() { printf '# %s\n' "$1" > "$T/$1.md"; dcq add "$T/$1.md" "$T/$2" >/dev/null 2>&1; }
run() { DCQ_MODELS="$1" DCQ_BREAK_N=99 dcq run -j 1 >> "$T/run.out" 2>&1; }
H="$DCQ_HOME/.health"
left() { echo $(( $(cat "$H/$1.cool" 2>/dev/null || echo 0) - $(date +%s) )); }
tried() { grep -c "^$1 $2\$" "$TRACE"; }
why() { awk -F'\t' -v m="$1" '$2==m {w=$5} END {print w}' "$DCQ_HOME/logs/gaps.tsv"; }
fail=0
ck() { if eval "$2"; then echo "ok  $1"; else echo "FAIL $1"; fail=1; fi; }

# 1. Zen 額度：記 quota、整個 Zen 池冷卻到 UTC 午夜，同池 zen-b 不再試，換 Go 免費過
add j1 w1; run "zen-a zen-b opencode-go/live-free"
ck "j1 PASS" 'ls "$DCQ_HOME/done" | grep -q -- -j1.job'
ck "zen-a 記 why=quota" '[ "$(why zen-a)" = quota ]'
ck "Zen 整池冷卻（zen-b 沒被試）" '[ "$(tried j1 zen-b)" = 0 ]'
l=$(left @zen); ck "@zen 冷卻到 UTC 午夜（${l}s）" '[ "$l" -gt 0 ] && [ "$l" -le 86400 ]'
ck "zen-a 不記 fail 計數" '[ ! -e "$H/zen-a.fails" ]'

# 2. Google：RPD 冷卻該模型到太平洋午夜；RPM 只冷 QUOTA_RPM_COOL_S；限流記 upstream；普通 rc=1 照記 exit
add j2 w2; run "google/g1 google/g2 kilo/k1 kilo/bad opencode-go/live-free"
pt=$(TZ=America/Los_Angeles date +%H:%M:%S); IFS=: read -r h m s <<<"$pt"; want=$(( 86400 - (10#$h*3600 + 10#$m*60 + 10#$s) ))
l=$(left google_g1); ck "google/g1 冷卻到太平洋午夜（${l}s≈${want}s）" '[ $(( want - l )) -ge -5 ] && [ $(( want - l )) -le 30 ]'
l=$(left google_g2); ck "google/g2 RPM 只冷 ≤120s（${l}s）" '[ "$l" -gt 0 ] && [ "$l" -le 120 ]'
ck "google 額度不碰 Zen 冷卻檔以外的 provider" '[ ! -e "$H/@google.cool" ]'
ck "kilo/k1 限流記 why=upstream" '[ "$(why kilo/k1)" = upstream ]'
ck "kilo/bad 普通 rc=1 照記 exit" '[ "$(why kilo/bad)" = exit ]'

# 3. 排名：quota／upstream 不算樣本；普通失敗照算
for i in 1 2 3 4 5 6; do printf '2026-10-24_0%s:00:00\tzen-a\t1\t1\tquota\t2\tmid\n' "$i"; printf '2026-10-24_0%s:00:00\tkilo/bad\t1\t1\texit\t2\tmid\n' "$i"; done >> "$DCQ_HOME/logs/gaps.tsv"
tbl="$(DCQ_MODELS="zen-a kilo/bad opencode-go/live-free" dcq rank 2>/dev/null)"
ck "rank 冷宮不含 zen-a（額度不算失敗）" '! printf "%s\n" "$tbl" | grep -E "冷宮|0 PASS" | grep -q "zen-a"'
ck "rank 冷宮含 kilo/bad（真失敗照算）" 'printf "%s\n" "$tbl" | grep -E "冷宮|0 PASS" | grep -q "kilo/bad"'

# 4. PASS 一隻 Zen 就解除整池冷卻
rm -f "$H/zen-a.cool"; echo $(( $(date +%s) - 1 )) > "$H/@zen.cool"; add j3 w3; run "zen-b"
ck "Zen PASS 後 @zen.cool 清掉" '[ ! -e "$H/@zen.cool" ]'

# 5. #9 剔出看得到：空 opencode.json → doctor 非 0、plan 首行列剔出、pool_alert 每天一則 TG
unset DCQ_POOL_TAIL
printf '#!/bin/sh\necho "$*" >> "%s/push"\n' "$T" > "$T/bin/hpush"; chmod +x "$T/bin/hpush"
export DC_PUSH=1
# 第 1–4 段 DCQ_POOL_TAIL="" 讓主層只剩 Zen 一家，add 時已觸發「單一 provider」告警蓋了今天的戳記
ck "主層只剩一家 provider 時也告警（第 1–4 段蓋了戳記）" 'ls "$DCQ_HOME"/logs/pool-alert.* >/dev/null 2>&1'
ck "告警戳記不進冷卻目錄 .health" '! ls "$H"/pool-alert.* >/dev/null 2>&1'
rm -f "$DCQ_HOME"/logs/pool-alert.*
if dcq doctor > "$T/doc" 2>&1; then echo "FAIL doctor 空設定應非 0"; fail=1; else echo "ok  doctor 空設定 exit 非 0"; fi
ck "doctor 列出剔出的 kilo/*" 'grep -q "FAIL.*kilo/" "$T/doc"'
dcq doctor --fix > "$T/fix" 2>"$T/fix.err"
ck "doctor --fix 印 kilo 補丁（含剔出的模型、baseURL）" 'sed -n "/^{/,\$p" "$T/fix" | sed "/^FAIL/d" | jq -e ".provider.kilo.models | length > 0" >/dev/null && grep -q "api.kilo.ai" "$T/fix"'
# 無 OmniRoute 機器照補丁就能直連：nvidia 要 baseURL＋models，groq 要 models（oc_declared 要求 models 有列）
ck "doctor --fix 印 nvidia 完整區塊" 'sed -n "/^{/,\$p" "$T/fix" | sed "/^FAIL/d" | jq -e ".provider.nvidia.options.baseURL and (.provider.nvidia.models | length > 0)" >/dev/null'
ck "doctor --fix 印 groq models 宣告" 'sed -n "/^{/,\$p" "$T/fix" | sed "/^FAIL/d" | jq -e ".provider.groq.models | length > 0" >/dev/null'
ck "doctor --fix 的 key 只用 {env:} 引用" '! grep -q "\"apiKey\": \"[^{]" "$T/fix"'
printf '# p\n' > "$T/p.md"
dcq plan "$T/p.md" > "$T/plan" 2> "$T/plan.err"
ck "plan 首行是免費池摘要且含剔出數" 'head -1 "$T/plan" | grep -q "^免費池 provider：.*剔出 [0-9]* 個"'
ck "plan 印 WARN 到 stderr" 'grep -q "WARN.*免費池縮水" "$T/plan.err"'
dcq plan "$T/p.md" >/dev/null 2>&1; sleep 1
ck "TG 一天只推一則" '[ "$(wc -l < "$T/push" | tr -d " ")" = 1 ]'
# 1 隻沒宣告就告警（M2 追加建議）：只缺一隻 kilo、其餘都宣告
# 刻意關掉的 provider 不算壞：enabled_providers 不含 kilo/google/omniroute 以外的 → 只剩宣告問題
km="$(awk -F'\t' '!/^#/ && $1=="free" && $7 ~ /^kilo\// {sub(/^kilo\//,"",$7); printf "%s\"%s\":{}", (n++?",":""), $7}' "$T/cat/models.tsv")"
om="$(awk -F'\t' '!/^#/ && $7 ~ /^omniroute\// {sub(/^omniroute\//,"",$7); printf "%s\"%s\":{}", (n++?",":""), $7}' "$T/cat/models.tsv")"
echo "{\"enabled_providers\":[\"opencode\",\"kilo\",\"google\",\"omniroute\"],\"provider\":{\"kilo\":{\"models\":{$km}},\"google\":{\"options\":{\"apiKey\":\"x\"}},\"omniroute\":{\"options\":{\"baseURL\":\"http://127.0.0.1:9/v1\"},\"models\":{$om}}}}" > "$T/cfg/opencode/opencode.json"
export DCQ_OR_HC=0
ck "完整設定 doctor exit 0" 'dcq doctor > "$T/doc2" 2>&1'
cp "$T/cfg/opencode/opencode.json" "$T/full.json"
k1="$(jq -r '.provider.kilo.models | keys[0]' "$T/full.json")"
jq --arg k "$k1" 'del(.provider.kilo.models[$k])' "$T/full.json" > "$T/cfg/opencode/opencode.json"
dcq plan "$T/p.md" >/dev/null 2> "$T/plan2.err"
ck "清冊有、本機只缺 1 隻也告警" 'grep -q "WARN.*kilo/$k1" "$T/plan2.err"'
ck "同一天剔出名單變了再推一則 TG" '[ "$(wc -l < "$T/push" | tr -d " ")" = 2 ]'
cp "$T/full.json" "$T/cfg/opencode/opencode.json"
ck "刻意關掉的列為略過" 'grep -q "略過" "$T/doc2" || ! grep -qE "openrouter/|nvidia/" "$T/cat/models.tsv"'

# 6. #12 OmniRoute 連不到（127.0.0.1:9）→ 剔出並提示；快取期間不重打
if grep -q $'\tomniroute/' "$T/cat/models.tsv"; then
  unset DCQ_OR_HC; rm -f "$H/@omniroute.hc"
  dcq doctor > "$T/doc3" 2> "$T/doc3.err"; rc=$?
  ck "OmniRoute 不通 → doctor 非 0 且提示" '[ "$rc" != 0 ] && grep -q "OmniRoute.*無回應" "$T/doc3.err"'
  ck "健康檢查結果有快取" '[ "$(cat "$H/@omniroute.hc")" = down ]'
fi

# 10-25：Go 額度窗受限（freecheck exit 5）只 WARN，dcq run 照跑非 Go 模型；不寫 .ALARM
printf '#!/bin/sh\necho %s\n' "'{\"usage\":{\"monthly\":{\"status\":\"rate-limited\",\"percent\":100}}}'" > "$T/bin/curl"; chmod +x "$T/bin/curl"
add goq w3; DC_FREECHECK=on OPENCODE_GO_API_KEY=fake run "kilo/ok1"
ck "Go 額度窗受限 dcq run 不中止" '[ "$(tried goq kilo/ok1)" -ge 1 ] && grep -q "Go 額度窗受限" "$T/run.out"'
ck "Go 額度窗受限不寫 .ALARM" '[ ! -e "$DCQ_HOME/.ALARM" ]'

[ "$fail" = 0 ] || { echo "--- run.out"; tail -30 "$T/run.out"; echo "--- rank"; printf '%s\n' "$tbl"; exit 1; }
echo QUOTA_OK
