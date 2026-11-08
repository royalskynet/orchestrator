#!/usr/bin/env bash
# CLI 訂閱層：以假 Codex 驗排序、剔除、覆寫及失敗 fallback，不打上游。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_CATALOG="$T/cat"
export DCQ_AUTOSTART=0 DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_POOLSYNC=0 DCQ_FREE_ROUNDS=1 DCQ_GO_STATE="$T/none.json" DCQ_AUTORANK=0
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
unset DCQ_POOL_ZEN DCQ_POOL_TAIL DCQ_POOL_PAID DCQ_POOL_GO DCQ_POOL_CLAUDE DCQ_MODELS DCQ_PROV_MAX DCQ_EASY_ONLY DCQ_EASY_STRICT DCQ_ALLOW_API DCQ_TIER DCQ_ORDER
mkdir -p "$T/bin" "$T/cat" "$T/w" "$T/tasks"
fail=0; ok() { echo "ok - $1"; }; bad() { echo "not ok - $1"; fail=1; }

# 正式清冊確保 dc_id 突變會被抓到。
awk -F '\t' '$1=="sub" && $2=="codex"' "$R/catalog/models.tsv" > "$T/cat/models.tsv"
printf 'free\topencode-run\tza\tok\tx\tx\tza\tany\nsub\tclaude-code\th1\tok\tx\tx\tclaude/h1\tany\n' >> "$T/cat/models.tsv"
: > "$T/cat/providers.tsv"
export CODEX_BIN="$T/bin/codex" TRACE="$T/trace" WRAPPER="$R/bin/codex-exec" TASK="$T/t.md"
echo '# 測試' > "$TASK"
cat > "$CODEX_BIN" <<'SH'
#!/usr/bin/env bash
echo '{"type":"error","message":"usage limit reached"}'
exit 1
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/claude"
cat > "$T/bin/dc" <<'SH'
#!/usr/bin/env bash
echo "$DC_FREE_MODEL" >> "$TRACE"
case "$DC_FREE_MODEL" in
 codex/*) exec "$WRAPPER" 做事 -f "$TASK" -m "$DC_FREE_MODEL" ;;
 claude/*) exit 0 ;;
 *) exit 1 ;;
esac
SH
chmod +x "$T/bin/"*
plan="$(DCQ_ORDER=sub "$R/bin/dcq" plan "$TASK" 2>&1)"
[[ "$plan" == *'codex/default claude/h1'* ]] && ok 'sub：Codex 在 Claude 前' || bad 'sub 順序'
plan="$(DCQ_ORDER=default "$R/bin/dcq" plan "$TASK" 2>&1)"
[[ "$plan" != *codex/* ]] && ok 'default 不派 Codex' || bad 'default 派了 Codex'
plan="$(CODEX_BIN="$T/missing" DCQ_ORDER=sub "$R/bin/dcq" plan "$TASK" 2>&1)"
[[ "$plan" != *codex/* && "$plan" == *claude/h1* ]] && ok '不可執行 CODEX_BIN 剔除' || bad '不可執行未剔除'
# 隔離 PATH，不讓本機 Codex 混入；只連結測試與 dcq 所需工具。
mkdir "$T/path"
for name in bash dirname readlink mkdir date awk cat sed grep tr sort head tail basename wc cut cp mv rm touch find xargs jq sleep uname ps stat env; do
 file="$(command -v "$name")"; [ -z "$file" ] || ln -s "$file" "$T/path/$name"
done
ln -s "$T/bin/claude" "$T/path/claude"
plan="$(unset CODEX_BIN; PATH="$T/path" DCQ_ORDER=sub "$R/bin/dcq" plan "$TASK" 2>&1)"
[[ "$plan" != *codex/* && "$plan" == *claude/h1* ]] && ok 'PATH 無 Codex 剔除' || bad "PATH 剔除：$plan"
plan="$(DCQ_POOL_CLAUDE=claude/h1 DCQ_ORDER=sub "$R/bin/dcq" plan "$TASK" 2>&1)"
[[ "$plan" != *codex/* && "$plan" == *claude/h1* ]] && ok '覆寫保留' || bad '覆寫失效'
id="$(DCQ_ORDER=sub "$R/bin/dcq" add "$TASK" "$T/w" mid 2>/dev/null)"
DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 > "$T/run" 2>&1
[ -e "$DCQ_HOME/done/$id.job" ] && [ "$(tail -2 "$TRACE")" = "$(printf 'codex/default\nclaude/h1')" ] && ok 'Codex 失敗後 Claude 完成' || bad "fallback：$(cat "$TRACE") $(tail -5 "$T/run")"
[ "$fail" = 0 ] && echo CODEX_LANE_OK
exit "$fail"
