#!/usr/bin/env bash
# Claude 層（2026-10-25）：bin/claude-exec 把 claude -p 的 stream-json 轉成 dc 認得的輸出；dcq 只在 DCQ_ORDER=sub 最後兜底派 claude/*。
# 假 claude，不打上游。斷言：
#   1) claude-exec 成功：印 START 行、轉出文字／工具、rc=0、參數有傳到 claude  2) result 錯誤：rc=1、印 Error 行
#   3) 額度錯誤行吻合 dc 的 QUOTA_RE  4) 不是 claude/<model> 拒跑
#   5) sub：claude/h1 是最後一棒（API 前）  6) free／default 都不碰 claude/*  7) plan 只有 sub 列 Claude 層
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_CATALOG="$T/cat"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_POOLSYNC=0 DCQ_FREE_ROUNDS=1 DCQ_GO_STATE="$T/none.json" DCQ_AUTORANK=0
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
unset DCQ_POOL_ZEN DCQ_POOL_TAIL DCQ_POOL_PAID DCQ_POOL_GO DCQ_POOL_CLAUDE DCQ_MODELS DCQ_PROV_MAX DCQ_EASY_ONLY DCQ_EASY_STRICT DCQ_ALLOW_API DCQ_TIER DCQ_ORDER
mkdir -p "$T/bin" "$T/cat" "$T/w" "$T/tasks"
fail=0; ok() { echo "ok - $1"; }; bad() { echo "not ok - $1"; fail=1; }

# 假 claude：FAKE=ok／err／quota；把收到的參數寫進 $T/args
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGS"
echo '{"type":"system","subtype":"init"}'
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"開工"},{"type":"tool_use","name":"Write","input":{"file_path":"a.txt"}}]}}'
case "$FAKE" in
  ok) echo '{"type":"result","subtype":"success","is_error":false,"num_turns":2}' ;;
  err) echo '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1}' ;;
  quota) echo '{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached|1792915200"}' ;;
esac
EOF
chmod +x "$T/bin/claude"
export ARGS="$T/args"
echo "# t" > "$T/t.md"
CE="$R/bin/claude-exec"

out="$(FAKE=ok "$CE" "做事" -f "$T/t.md" -m claude/h1 --title x --dir "$T" --pure 2>&1)"; rc=$?
[ "$rc" = 0 ] && echo "$out" | head -1 | grep -qx '> build · claude/h1' && echo "$out" | grep -qx '開工' \
  && echo "$out" | grep -q '^→ Write ' && echo "$out" | grep -qx 'claude-exec: success turns=2' && ok "成功：START 行＋文字＋工具，rc=0" || bad "成功路徑 rc=${rc}：$out"
grep -qx h1 "$ARGS" && grep -q "任務檔：$T/t.md" "$ARGS" && grep -qx -- --allowedTools "$ARGS" && ! grep -qx -- --pure "$ARGS" \
  && ok "model／任務檔／allowedTools 有傳，opencode 旗標沒漏給 claude" || bad "參數：$(tr '\n' ' ' < "$ARGS")"

out="$(FAKE=err "$CE" "做事" -f "$T/t.md" -m claude/h1 2>&1)"; rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -qx 'Error: claude-exec: error_during_execution' && ok "result 錯誤：rc=1" || bad "錯誤路徑 rc=${rc}：$out"

out="$(FAKE=quota "$CE" "做事" -f "$T/t.md" -m claude/h1 2>&1)"; rc=$?
QRE="$(sed -n "s/^QUOTA_RE='\(.*\)'$/\1/p" "$R/bin/dc")"
[ -n "$QRE" ] && [ "$rc" = 1 ] && echo "$out" | grep -Eq "$QRE" && ok "額度錯誤吻合 dc QUOTA_RE" || bad "額度路徑 rc=$rc QRE=${QRE:0:20}：$out"

if FAKE=ok "$CE" "做事" -f "$T/t.md" -m opencode/x >/dev/null 2>&1; then bad "非 claude/ 也跑了"; else ok "非 claude/<model> 拒跑"; fi

# dcq 層級：免費 za、訂閱 g1 都必敗；只有 claude/h1 會過
printf '# 測試清冊\nfree\topencode-run\tza\tok\tx\tx\tza\tany\nsub\tomniroute\tg\tok\tx\tx\topencode-go/g1\tany\nsub\tclaude-code\th1\tok\tx\tx\tclaude/h1\tany\napi\topencode-run\tp\tok\tx\tx\topencode/p1\tany\n' > "$T/cat/models.tsv"
: > "$T/cat/providers.tsv"
export TRACE="$T/trace"
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
echo "IN $(basename "$1" .md) $DC_FREE_MODEL" >> "$TRACE"
sleep 1; case "$DC_FREE_MODEL" in claude/*) exit 0 ;; *) exit 1 ;; esac
EOF
chmod +x "$T/bin/dc"
"$R/bin/dcq" status >/dev/null 2>&1
for o in sub free default; do
  : > "$TRACE"; echo "# $o" > "$T/tasks/$o.md"
  id="$(DCQ_ORDER=$o "$R/bin/dcq" add "$T/tasks/$o.md" "$T/w" mid 2>/dev/null)"
  DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 > "$T/run.$o" 2>&1
  seq_="$(awk '{print $3}' "$TRACE" | tr '\n' ' ')"
  case "$o" in
    sub) [ "$(awk 'END{print $3}' "$TRACE")" = claude/h1 ] && [ "$(grep -c claude/ "$TRACE")" = 1 ] && grep -q za "$TRACE" && grep -q opencode-go/g1 "$TRACE" \
           && [ -e "$DCQ_HOME/done/$id.job" ] && ok "sub：claude/h1 最後一棒且交件（${seq_}）" || bad "sub 順序：${seq_} $(tail -3 "$T/run.$o")" ;;
    *) if grep -q claude/ "$TRACE"; then bad "$o 用到 Claude 層：${seq_}"; else ok "$o 不碰 Claude 層（${seq_}）"; fi ;;
  esac
done
grep -q opencode/p1 "$T"/trace "$T"/run.* && bad "沒開 DCQ_ALLOW_API 卻派了 API" || ok "API 層預設關"

DCQ_ORDER=sub "$R/bin/dcq" plan "$T/t.md" 2>&1 | grep -q 'Claude（訂閱額度）：claude/h1' && ok "plan sub 列 Claude 層" || bad "plan sub 沒列 Claude 層"
for o in free default; do
  if DCQ_ORDER=$o "$R/bin/dcq" plan "$T/t.md" 2>&1 | grep -q 'Claude（'; then bad "plan $o 列了 Claude 層"; else ok "plan $o 不列 Claude 層"; fi
done

[ "$fail" = 0 ] && echo CLAUDE_OK
exit "$fail"
