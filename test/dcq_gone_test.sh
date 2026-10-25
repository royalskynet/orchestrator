#!/usr/bin/env bash
# 下架處理（10-23，借鏡 quadseven/loom#1295）：模型回下架錯誤 → 冷卻 1 小時並記 .gone、本單換下一隻照常過；
# 冷卻到期要再派前查清單：清單沒有 → 再停 1 小時；清單有 → 恢復派工。
# Go 清單＝go-sync 強制掃（節流），Zen 清單＝GET /zen/v1/models（節流），抓不到才退回 `opencode models opencode`。
set -u
. "$(dirname "$0")/env.sh"
T="$(mktemp -d)"; trap '[ -n "${KEEP:-}" ] && echo "T=$T" || rm -rf "$T"' EXIT
export DCQ_HOME="$T/q"; mkdir -p "$T/bin" "$T/w1" "$T/w2" "$T/w3" "$T/w4" "$T/w5"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
export DCQ_FREE_ROUNDS=1 DCQ_POOL_PAID="" DCQ_POOL_TAIL="" DCQ_ORDER=default
export DCQ_GO_STATE="$T/go-models.json" DCQ_GO_SYNC="$T/bin/go-sync" SYNCLOG="$T/sync.log" TRACE="$T/trace" OCLIST="$T/oclist"
echo '{"at":"2026-10-20T09:00:00","upstream":["dead-free","flaky-free","live-free"]}' > "$DCQ_GO_STATE"
printf 'opencode/live-zen\n' > "$OCLIST"
export DCQ_ZEN_MODELS_URL="file://$T/zen.json"
echo '{"data":[{"id":"live-zen"}]}' > "$T/zen.json"
: > "$SYNCLOG"; : > "$TRACE"
mkdir -p "$T/cat"; cp "$(cd "$(dirname "$0")/.." && pwd)/catalog/models.tsv" "$T/cat/"; export DCQ_CATALOG="$T/cat"   # 回灌清冊只動暫存副本

# 假 go-sync：記一次呼叫，寫新清單（dead-free 下架，flaky-free 還在）
cat > "$T/bin/go-sync" <<'EOF'
#!/usr/bin/env bash
echo "scan $*" >> "$SYNCLOG"
echo '{"at":"2026-10-23T19:00:00","upstream":["flaky-free","live-free"]}' > "$DCQ_GO_STATE"
EOF
cat > "$T/bin/opencode" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "models opencode" ] && { cat "$OCLIST"; exit 0; }
exit 1
EOF
# 假 dc：dead 回 not found、flaky 回 deprecated、zen-x 回 not found（ZENOK 檔在時改成過），其餘過
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$1" .md) $DC_FREE_MODEL" >> "$TRACE"
case "$DC_FREE_MODEL" in
  opencode-go/dead-free) echo "Error: ProviderModelNotFoundError: Model not found: $DC_FREE_MODEL"; echo "dc: opencode run rc=1"; exit 1 ;;
  opencode-go/flaky-free) echo "Error: Model flaky-free has been deprecated."; echo "dc: opencode run rc=1"; exit 1 ;;
  zen-x) [ -e "$ZENOK" ] && exit 0; echo "Error: ProviderModelNotFoundError: Model not found: zen-x"; echo "dc: opencode run rc=1"; exit 1 ;;
esac
exit 0
EOF
export ZENOK="$T/zenok"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/wo-verify"
chmod +x "$T/bin/"*
dcq() { "$(cd "$(dirname "$0")/.." && pwd)/bin/dcq" "$@"; }
add() { printf '# %s\n' "$1" > "$T/$1.md"; dcq add "$T/$1.md" "$T/$2" >/dev/null; }
run() { DCQ_MODELS="zen-x opencode-go/dead-free opencode-go/flaky-free opencode-go/live-free" DCQ_BREAK_N=99 dcq run -j 1 >> "$T/run.out" 2>&1; }
H="$DCQ_HOME/.health"
done_() { ls "$DCQ_HOME/done/" | grep -q -- "-$1\.job$"; }
left() { echo $(( $(cat "$H/$1.cool" 2>/dev/null || echo 0) - $(date +%s) )); }
expire() { for m in "$@"; do echo $(( $(date +%s) - 1 )) > "$H/$m.cool"; done; }
tried() { grep -c "^$1 $2\$" "$TRACE"; }

fail=0
ck() { if eval "$2"; then echo "ok  $1"; else echo "FAIL $1"; fail=1; fi; }

# 第 1 段：撞錯 → 冷卻 1 小時、記 .gone、換下一隻過
add j1 w1; add j2 w2; run
ck "j1 j2 都 PASS" 'done_ j1 && done_ j2'
ck "go-sync 只叫 1 次且帶 --scan" '[ "$(grep -c "^scan --scan" "$SYNCLOG")" = 1 ]'
ck "下架的只被試 1 次（j2 跳過）" '[ "$(tried j2 opencode-go/dead-free)" = 0 ] && [ "$(tried j2 zen-x)" = 0 ]'
for m in zen-x opencode-go_dead-free opencode-go_flaky-free; do
  l=$(left $m); ck "$m 冷卻約 1 小時（$l s）且有 .gone" '[ "$l" -gt 3000 ] && [ "$l" -le 3600 ] && [ -e "$H/$m.gone" ]'
done

# 第 2 段：冷卻到期 → 查清單。zen-x 清單沒有、dead 清單沒有 → 再停；flaky 清單有 → 恢復、被試
expire zen-x opencode-go_dead-free opencode-go_flaky-free
add j3 w3; run
ck "j3 PASS" 'done_ j3'
ck "清單沒有的不派（zen-x、dead）" '[ "$(tried j3 zen-x)" = 0 ] && [ "$(tried j3 opencode-go/dead-free)" = 0 ]'
ck "清單沒有的再停約 1 小時" '[ "$(left zen-x)" -gt 3000 ] && [ "$(left opencode-go_dead-free)" -gt 3000 ]'
ck "清單有的恢復派工（flaky 被試）" '[ "$(tried j3 opencode-go/flaky-free)" = 1 ]'

ck "Zen /models 有抓且寫進 state" 'jq -e ".upstream == [\"live-zen\"]" "$DCQ_HOME/logs/zen-models.json" >/dev/null'

# 第 3 段：Zen 上游清單列回 zen-x（models.dev 仍沒有）→ 恢復、派到就過、.gone 清掉
echo '{"data":[{"id":"live-zen"},{"id":"zen-x"}]}' > "$T/zen.json"; : > "$ZENOK"
export DCQ_RESYNC_MIN_S=0
expire zen-x
add j4 w4; run
ck "zen-x 上游列回後恢復並 PASS（不看 models.dev）" '[ "$(tried j4 zen-x)" = 1 ] && done_ j4 && [ ! -e "$H/zen-x.gone" ]'

# 第 4 段：Zen 上游抓不到、state 也沒有 → 退回 models.dev；它沒有 zen-x → 續停
rm -f "$ZENOK" "$DCQ_HOME/logs/zen-models.json"; export DCQ_ZEN_MODELS_URL="file://$T/nope.json"
add j5 w5; run
ck "zen-x 再撞錯被停" '[ -e "$H/zen-x.gone" ]'
expire zen-x; add j6 w1; run
ck "上游抓不到 → 退回 models.dev 判沒有、不派" '[ "$(tried j6 zen-x)" = 0 ] && [ "$(left zen-x)" -gt 3000 ]'

# 第 5 段：加掃結果回灌名單 → x-pool.tsv（GONE 池內已下架、NEW 上游新 -free）＋清冊（暫存副本）
XP="$DCQ_HOME/logs/x-pool.tsv"
ck "第 1 段加掃已記 GONE zen-x" 'grep -q "	zen-models	GONE	zen-x$" "$XP"'
ck "GONE zen-x 不重記" '[ "$(grep -c "	GONE	zen-x$" "$XP")" = 1 ]'
printf '2026-01-01_00:00:00\topencode\tbig-pickle\tOK\n' > "$DCQ_HOME/logs/probe.tsv"   # 舊批次：x-pool 列都比它新
echo '{"data":[{"id":"live-zen"},{"id":"fresh-free"}]}' > "$T/zen.json"; export DCQ_ZEN_MODELS_URL="file://$T/zen.json"
expire zen-x; add j7 w2; run
ck "上游新 -free 記 NEW" 'grep -q "	zen-models	NEW	fresh-free$" "$XP"'
ck "NEW 回寫進清冊" 'grep -q "	fresh-free	" "$T/cat/models.tsv"'

[ "$fail" = 0 ] || { echo "--- run.out"; tail -40 "$T/run.out"; echo "--- trace"; cat "$TRACE"; exit 1; }
echo GONE_OK
