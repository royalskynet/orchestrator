#!/usr/bin/env bash
# dcq 清冊組池／難度分層／provider 併發的自檢：假 dc，不打上游。
# 斷言：1) 清冊組出各層、API 層預設關  2) hard 工單不派 fit=easy  3) provider 上限 1 時同 provider 不重疊
#       4) gaps.tsv 帶難度、排名依難度分開  5) 難度入列：給的照收、亂給拒收、triage 不在就 mid
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_CATALOG="$T/cat"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_POOLSYNC=0 DCQ_FREE_ROUNDS=1 DCQ_GO_STATE="$T/none.json"
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
unset DCQ_POOL_ZEN DCQ_POOL_TAIL DCQ_POOL_PAID DCQ_POOL_GO DCQ_MODELS DCQ_PROV_MAX DCQ_EASY_ONLY DCQ_ALLOW_API DCQ_TIER
mkdir -p "$T/bin" "$T/cat" "$T/w1" "$T/w2" "$T/tasks"
dcq() { "$R/bin/dcq" "$@"; }
fail=0; ok() { echo "ok - $1"; }; bad() { echo "not ok - $1"; fail=1; }

printf '# 測試清冊\nfree\topencode-run\topencode/za\tok\tx\tx\tza\tany\nfree\topencode-run\topencode/zb\tok\tx\tx\tzb\teasy\nfree\tlocal\tlaya\tok\tx\tx\t\tany\nfree\tomniroute\tx/t\tok\tx\tx\tomniroute/t1\tany\nsub\tomniroute\tg\tok\tx\tx\topencode-go/g1\tany\napi\topencode-run\tp\tok\tx\tx\topencode/p1\tany\n' > "$T/cat/models.tsv"
printf '# 測試\nomniroute\t3\tx\n' > "$T/cat/providers.tsv"

# 假 dc：記 (工單, model, 進出時間)；za 一律失敗，其他一律過；slow* 工單睡 3 秒
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
n="$(basename "$1" .md)"
echo "IN $n $DC_FREE_MODEL $(date +%s.%N)" >> "$TRACE"
case "$n" in slow*) sleep 3 ;; *) sleep 1 ;; esac
echo "OUT $n $DC_FREE_MODEL $(date +%s.%N)" >> "$TRACE"
[ "$DC_FREE_MODEL" = za ] && exit 1; exit 0
EOF
chmod +x "$T/bin/dc"
export TRACE="$T/trace"; : > "$TRACE"
for n in e1 h1 m1 slowa slowb; do echo "# $n" > "$T/tasks/$n.md"; done
# omniroute/* 要在 opencode.json 宣告才進池（fixindex 11136）：假設定只宣告 t1
mkdir -p "$T/xdg/opencode"; echo '{"provider":{"omniroute":{"models":{"t1":{}}}}}' > "$T/xdg/opencode/opencode.json"
export XDG_CONFIG_HOME="$T/xdg"

# 1) 清冊組池
out="$(DCQ_AUTORANK=0 dcq rank 2>&1)"
echo "$out" | grep -q '^順序：za zb$' && ok "免費層＝清冊無斜線列，依列序" || bad "免費層：$(echo "$out" | grep '^順序')"
echo "$out" | grep -q '^兜底層：omniroute/t1$' && ok "兜底層＝免費有斜線列" || bad "兜底層：$(echo "$out" | grep '^兜底層')"
out2="$(echo '{"provider":{"omniroute":{"models":{}}}}' > "$T/xdg/opencode/opencode.json"; DCQ_AUTORANK=0 dcq rank 2>&1)"
echo '{"provider":{"omniroute":{"models":{"t1":{}}}}}' > "$T/xdg/opencode/opencode.json"
echo "$out2" | grep -q '剔出池：omniroute/t1' && ! echo "$out2" | grep -q '^兜底層：omniroute/t1' && ok "opencode.json 未宣告的 omniroute/* 剔出兜底層" || bad "未宣告沒剔：$(echo "$out2" | grep -E '兜底|剔出')"
echo "$out" | grep -q '^訂閱層：opencode-go/g1$' && ok "訂閱層＝sub 列" || bad "訂閱層：$(echo "$out" | grep '^訂閱層')"
echo "$out" | grep -q '^API 層：（關' && ok "API 層預設關" || bad "API 層：$(echo "$out" | grep '^API')"
echo "$out" | grep -q '^hard 不派：zb$' && ok "EASY_ONLY＝fit=easy" || bad "$(echo "$out" | grep '^hard')"
echo "$out" | grep -q '^provider 上限：omniroute=3$' && ok "provider 上限讀 providers.tsv" || bad "$(echo "$out" | grep '^provider')"
DCQ_ALLOW_API=1 DCQ_AUTORANK=0 dcq rank 2>&1 | grep -q '^API 層：opencode/p1$' && ok "DCQ_ALLOW_API=1 才有 API 層" || bad "API 層開旗標後不對"

# 2) hard 工單跳過 fit=easy：za 失敗後，easy 落到 zb，hard 跳過 zb 落到兜底層
dcq add "$T/tasks/e1.md" "$T/w1" easy >/dev/null 2>&1
dcq add "$T/tasks/h1.md" "$T/w2" hard >/dev/null 2>&1
DCQ_ALLOWED_FAILS=9 dcq run -j 2 >/dev/null 2>&1
grep -q '^IN e1 zb ' "$TRACE" && ok "easy 工單會派 fit=easy 的 zb" || bad "easy 沒派到 zb：$(grep ' e1 ' "$TRACE")"
if grep -q '^IN h1 zb ' "$TRACE"; then bad "hard 工單派到了 fit=easy 的 zb"; else ok "hard 工單不派 zb"; fi
grep -q '^IN h1 omniroute/t1 ' "$TRACE" && ok "hard 工單落到兜底層" || bad "hard 沒到兜底層：$(grep ' h1 ' "$TRACE")"

# 4a) gaps.tsv 第 7 欄記難度
awk -F'\t' '$2=="zb" && $7=="easy"' "$DCQ_HOME/logs/gaps.tsv" | grep -q . && ok "gaps.tsv 記 easy" || bad "gaps.tsv 沒記難度：$(tail -3 "$DCQ_HOME/logs/gaps.tsv")"
awk -F'\t' '$2=="omniroute/t1" && $7=="hard"' "$DCQ_HOME/logs/gaps.tsv" | grep -q . && ok "gaps.tsv 記 hard" || bad "gaps.tsv 沒記 hard"

# 4b) zb 只在 hard 連 3 次 0 PASS：hard 排名降級，easy 不受影響
: > "$DCQ_HOME/logs/gaps.tsv"
for i in 1 2 3; do printf '%s\tzb\t1\t1\texit\t5\thard\n' "$(date +%F_%T)" >> "$DCQ_HOME/logs/gaps.tsv"; done
dcq rank hard 2>&1 | grep -q '^冷宮（兜底層之後、訂閱層之前）：zb$' && ok "hard 排名把 zb（0 PASS）降到冷宮" || bad "hard 排名：$(dcq rank hard 2>&1 | grep 冷宮)"
dcq rank easy 2>&1 | grep -q '^懲罰層（免費層之後）：$' && ok "easy 排名不吃 hard 的紀錄" || bad "easy 排名：$(dcq rank easy 2>&1 | grep 懲罰)"
dcq rank 2>&1 | grep -q '^冷宮（兜底層之後、訂閱層之前）：zb$' && ok "不分難度時照舊全算" || bad "不分難度：$(dcq rank 2>&1 | grep 冷宮)"
: > "$DCQ_HOME/logs/gaps.tsv"

# 3) provider 上限：zen=1 時 za／zb 兩張不同 cwd 工單不重疊；不設上限時會重疊（證明這個斷言抓得到）
overlap() {  # trace 裡 slowa／slowb 的 [IN,OUT] 區間是否相交
  awk '$2 ~ /^slow/ { t[$1" "$2]=$4 } END { if (t["IN slowa"]<t["OUT slowb"] && t["IN slowb"]<t["OUT slowa"]) exit 0; exit 1 }' "$TRACE"
}
run_pair() {
  : > "$TRACE"
  DCQ_POOL_ZEN="zb ze" dcq add "$T/tasks/slowa.md" "$T/w1" mid >/dev/null 2>&1
  DCQ_POOL_ZEN="zb ze" dcq add "$T/tasks/slowb.md" "$T/w2" mid >/dev/null 2>&1
  DCQ_POOL_ZEN="zb ze" DCQ_AUTORANK=0 DCQ_MODEL_MAX=1 dcq run -j 2 >/dev/null 2>&1
}
DCQ_PROV_MAX="" run_pair
overlap && ok "對照：不設 provider 上限時兩張同時跑" || bad "對照組沒重疊，斷言抓不到差別：$(cat "$TRACE")"
DCQ_PROV_MAX="zen=1" run_pair
if overlap; then bad "zen=1 時兩張 Zen 工單重疊：$(cat "$TRACE")"; else ok "zen=1 時同 provider 不重疊"; fi
grep -c '^OUT slow' "$TRACE" | grep -qx 2 && ok "兩張都跑完" || bad "沒跑完：$(cat "$TRACE")"
ls "$DCQ_HOME/.inuse" | grep -q . && bad "跑完還有殘留槽：$(ls "$DCQ_HOME/.inuse")" || ok "provider 槽有歸還"

# 5) 難度入列
dcq clear >/dev/null 2>&1
id="$(dcq add "$T/tasks/m1.md" "$T/w1" hard 2>/dev/null)"; grep -qx 'TIER=hard' "$DCQ_HOME/pending/$id.job" && ok "給 hard 照收" || bad "給 hard 沒記"
id="$(dcq add "$T/tasks/m1.md" "$T/w1" 2>/dev/null)"; grep -qx 'TIER=mid' "$DCQ_HOME/pending/$id.job" && ok "DC_BIN 沒 triage 時記 mid" || bad "沒 triage 沒記 mid"
dcq add "$T/tasks/m1.md" "$T/w1" huge >/dev/null 2>&1; [ $? = 2 ] && ok "亂給難度拒收 rc=2" || bad "亂給難度沒拒收"
[ "$(JEV_GATE_DIR="$T/nope" "$R/bin/triage" "$T/tasks/m1.md")" = mid ] && ok "triage 找不到 jev-gate 印 mid" || bad "triage fail-open 不對"
# Laya 預設不叫（2026-10-24）：DC_BIN 有 triage 也記 mid，DCQ_TRIAGE=1 才照 triage
printf '#!/bin/sh\necho hard\n' > "$T/bin/triage"; chmod +x "$T/bin/triage"
id="$(dcq add "$T/tasks/m1.md" "$T/w1" 2>/dev/null)"; grep -qx 'TIER=mid' "$DCQ_HOME/pending/$id.job" && ok "triage 在但預設不叫，記 mid" || bad "預設仍叫了 triage"
id="$(DCQ_TRIAGE=1 dcq add "$T/tasks/m1.md" "$T/w1" 2>/dev/null)"; grep -qx 'TIER=hard' "$DCQ_HOME/pending/$id.job" && ok "DCQ_TRIAGE=1 照 triage 記 hard" || bad "DCQ_TRIAGE=1 沒叫 triage"
rm -f "$T/bin/triage"

# 5a) 直連兜底（無 OmniRoute 機器）：要 key 才進池、enabled_providers 擋掉就剔除
ORT=openrouter/openrouter/free
o="$(XDG_DATA_HOME="$T/nodata" DCQ_POOL_TAIL=$ORT DCQ_AUTORANK=0 env -u OPENROUTER_API_KEY "$R/bin/dcq" rank 2>&1)"
echo "$o" | grep -q "剔出池：$ORT" && ok "直連沒 key 剔出兜底層" || bad "直連沒 key 沒剔：$(echo "$o" | grep -E '兜底|剔出')"
o="$(XDG_DATA_HOME="$T/nodata" OPENROUTER_API_KEY=x DCQ_POOL_TAIL=$ORT DCQ_AUTORANK=0 "$R/bin/dcq" rank 2>&1)"
echo "$o" | grep -q "剔出池：$ORT" && ok "直連有 key 但模型沒宣告就剔除" || bad "沒宣告沒剔：$(echo "$o" | grep -E '兜底|剔出')"
mkdir -p "$T/xdg3/opencode"; echo '{"provider":{"openrouter":{"models":{"openrouter/free":{}}}}}' > "$T/xdg3/opencode/opencode.json"
o="$(XDG_CONFIG_HOME="$T/xdg3" XDG_DATA_HOME="$T/nodata" OPENROUTER_API_KEY=x DCQ_POOL_TAIL=$ORT DCQ_AUTORANK=0 "$R/bin/dcq" rank 2>&1)"
echo "$o" | grep -qx "兜底層：$ORT" && ok "直連有 key＋宣告進兜底層" || bad "直連有 key 沒進：$(echo "$o" | grep -E '兜底|剔出')"
mkdir -p "$T/xdg2/opencode"; echo '{"enabled_providers":["omniroute","opencode"],"provider":{"openrouter":{"models":{"openrouter/free":{}}}}}' > "$T/xdg2/opencode/opencode.json"
o="$(XDG_CONFIG_HOME="$T/xdg2" XDG_DATA_HOME="$T/nodata" OPENROUTER_API_KEY=x DCQ_POOL_TAIL=$ORT DCQ_AUTORANK=0 "$R/bin/dcq" rank 2>&1)"
echo "$o" | grep -q "剔出池：$ORT" && ok "enabled_providers 沒開 openrouter 就剔除（M4 情境）" || bad "enabled_providers 沒擋：$(echo "$o" | grep -E '兜底|剔出')"

# 5b) 層級順序：of 只用免費、os 訂閱先、派o 預設免費先；plan 與實跑一致
: > "$TRACE"; dcq clear >/dev/null 2>&1
for n in of os od; do echo "# $n" > "$T/tasks/$n.md"; done
# 免費池只放必敗的 za、關掉兜底層，看各順序走到哪一層
export DCQ_POOL_ZEN="za" DCQ_POOL_TAIL=""
DCQ_ORDER=free dcq add "$T/tasks/of.md" "$T/w1" mid >/dev/null 2>&1
DCQ_ORDER=sub  dcq add "$T/tasks/os.md" "$T/w2" mid >/dev/null 2>&1
DCQ_AUTORANK=0 DCQ_ALLOWED_FAILS=9 dcq run -j 2 >/dev/null 2>&1
if grep -q '^IN of opencode-go/' "$TRACE"; then bad "of 用到了訂閱層"; else ok "of 不碰訂閱層"; fi
ls "$DCQ_HOME/failed" | grep -q 'of' && ok "of 免費全敗就結案失敗" || bad "of 沒進 failed"
[ "$(grep '^IN os ' "$TRACE" | head -1 | awk '{print $3}')" = opencode-go/g1 ] && ok "os 第一棒是訂閱層" || bad "os 第一棒：$(grep '^IN os ' "$TRACE" | head -1)"
DCQ_ORDER=default dcq add "$T/tasks/od.md" "$T/w1" mid >/dev/null 2>&1; : > "$TRACE"
DCQ_AUTORANK=0 DCQ_ALLOWED_FAILS=9 dcq run -j 1 >/dev/null 2>&1
[ "$(grep '^IN od ' "$TRACE" | awk '{print $3}' | tr '\n' ' ')" = "za opencode-go/g1 " ] && ok "派o 免費先、訂閱後" || bad "派o 順序：$(grep '^IN od ' "$TRACE")"
# 呼叫端漏帶 DCQ_ORDER＝派o（default），免費全敗可升訂閱層（10-21 使用者定，取代 10-20 的 of 預設）
echo "# on" > "$T/tasks/on.md"
id="$(env -u DCQ_ORDER dcq add "$T/tasks/on.md" "$T/w1" mid 2>/dev/null)"
grep -qx 'ORDER=default' "$DCQ_HOME/pending/$id.job" && ok "沒給 DCQ_ORDER 記 default" || bad "沒給 DCQ_ORDER 記成：$(grep ORDER "$DCQ_HOME/pending/$id.job")"
: > "$TRACE"; DCQ_AUTORANK=0 DCQ_ALLOWED_FAILS=9 dcq run -j 1 >/dev/null 2>&1
[ "$(grep '^IN on ' "$TRACE" | awk '{print $3}' | tr '\n' ' ')" = "za opencode-go/g1 " ] && ok "沒給 DCQ_ORDER 免費全敗升訂閱" || bad "沒給 DCQ_ORDER 順序：$(grep '^IN on ' "$TRACE")"
out="$(env -u DCQ_ORDER DCQ_AUTORANK=0 dcq plan "$T/tasks/on.md" 2>&1)"
if echo "$out" | grep -q '訂閱'; then ok "plan 沒給 DCQ_ORDER 列出訂閱層"; else bad "plan 沒給 DCQ_ORDER 沒列訂閱層：$out"; fi
out="$(DCQ_ORDER=sub DCQ_AUTORANK=0 dcq plan "$T/tasks/os.md" 2>&1)"
echo "$out" | grep -q '1 訂閱：opencode-go/g1' && echo "$out" | grep -q '2 免費 opencode：za' && ok "plan sub 順序與實跑一致" || bad "plan sub：$out"
out="$(DCQ_ORDER=free DCQ_AUTORANK=0 dcq plan "$T/tasks/of.md" 2>&1)"
if echo "$out" | grep -q '訂閱'; then bad "plan free 列出訂閱層：$out"; else ok "plan free 不列訂閱層"; fi
DCQ_ORDER=x dcq add "$T/tasks/od.md" "$T/w1" mid >/dev/null 2>&1; [ $? = 2 ] && ok "亂給 DCQ_ORDER 拒收" || bad "亂給 DCQ_ORDER 沒拒收"
unset DCQ_POOL_ZEN DCQ_POOL_TAIL

# 5b) 免費層分兩層（10-26）：opencode free（無斜線＋opencode-go/*-free）先、freepool（其他斜線）後，不混排；
#     手排把 kilo 放最前也一樣。za 失敗 → opencode-go/gf 過，kilo 沒被碰；opencode 全敗才輪到 kilo
echo "# t1" > "$T/tasks/ft1.md"; echo "# t2" > "$T/tasks/ft2.md"
: > "$TRACE"
DCQ_MODELS="kilo/k:free za opencode-go/gf-free" DCQ_ORDER=free dcq add "$T/tasks/ft1.md" "$T/w1" mid >/dev/null 2>&1
DCQ_MODELS="kilo/k:free za opencode-go/gf-free" DCQ_AUTORANK=0 DCQ_ALLOWED_FAILS=9 dcq run -j 1 >/dev/null 2>&1
[ "$(grep '^IN ft1 ' "$TRACE" | awk '{print $3}' | tr '\n' ' ')" = "za opencode-go/gf-free " ] && ok "opencode free 層先於 freepool" || bad "兩層順序：$(grep '^IN ft1 ' "$TRACE")"
DCQ_MODELS="kilo/k:free za" DCQ_ORDER=free dcq add "$T/tasks/ft2.md" "$T/w1" mid >/dev/null 2>&1
DCQ_MODELS="kilo/k:free za" DCQ_AUTORANK=0 DCQ_ALLOWED_FAILS=9 dcq run -j 1 >/dev/null 2>&1
[ "$(grep '^IN ft2 ' "$TRACE" | awk '{print $3}' | tr '\n' ' ')" = "za kilo/k:free " ] && ok "opencode free 用盡才換 freepool" || bad "換層：$(grep '^IN ft2 ' "$TRACE")"
out="$(DCQ_MODELS="kilo/k:free za" DCQ_AUTORANK=0 dcq plan "$T/tasks/ft2.md" 2>&1)"
echo "$out" | grep -q '1 免費 opencode：za$' && echo "$out" | grep -q '2 免費 freepool：kilo/k:free$' && ok "plan 分列兩層" || bad "plan 兩層：$out"

# 6) bash 會把緊接在 $var 後的全形字當成變數名（set -u 下直接 unbound variable），一律要寫 ${var}
bad_lines="$(perl -ne 'print "$ARGV:$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*(?=[\x80-\xff])/; close ARGV if eof' "$R"/bin/*)"
[ -z "$bad_lines" ] && ok "bin/ 沒有 \$var 緊接全形字" || bad "要改成 \${var}：$bad_lines"

exit "$fail"
