#!/usr/bin/env bash
# DCQ_ORDER=foo（派foo）：入列記 ORDER=foo＋VIA=foo、foo lint 只 advisory 不擋單；
# 純免費堅持（2026-11-26 起）：只走免費的層、永不升訂閱；沒真正交過件的模型會等冷卻重來整梯，
# 全進 noretry 才放棄。假 dc／假 foo，不打上游。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_CATALOG="$T/cat"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_POOLSYNC=0 DCQ_FREE_ROUNDS=1 DCQ_GO_STATE="$T/none.json"
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
mkdir -p "$T/bin" "$T/cat" "$T/w" "$T/tasks" "$T/home/dev/fm-harness/bin" "$T/xdg/opencode"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got '$2' want '$3'"; fail=1; fi; }

printf '# 測試清冊\nfree\topencode-run\topencode/za\tok\tx\tx\tza\tany\nsub\tomniroute\tg\tok\tx\tx\topencode-go/g1\tany\n' > "$T/cat/models.tsv"
printf '# 測試\nomniroute\t3\tx\n' > "$T/cat/providers.tsv"
echo '{"provider":{"omniroute":{"models":{"g":{}}}}}' > "$T/xdg/opencode/opencode.json"
export XDG_CONFIG_HOME="$T/xdg"

# 假 dc：只記進場順序。za 的行為分工單——
#   foo＝第一次上游失敗（不印驗收）、第二次過，驗證純免費堅持會重來整梯；
#   zafail＝印驗收後失敗（ran=1 → noretry），驗證全進 noretry 就放棄；
# opencode-go/g1 過（但純免費的 foo 永遠不該用到它）。
cat > "$T/bin/dc" <<'EOQ'
#!/usr/bin/env bash
n="$(basename "$1" .md)"
echo "IN $n $DC_FREE_MODEL" >> "$TRACE"
[ "$DC_FREE_MODEL" = za ] || exit 0
case "$n" in
  zafail|ofail) echo "dc: 驗收 → fake verify fail"; exit 1 ;;
  zastuck) exit 1 ;;   # 永遠上游失敗（不印驗收）：不進 noretry，沒有預算會堅持到 JOB_MAX
  *) c=$(cat "$CNT" 2>/dev/null || echo 0); echo $((c + 1)) > "$CNT"
     [ "$c" = 0 ] && exit 1; exit 0 ;;
esac
EOQ
chmod +x "$T/bin/dc"
export TRACE="$T/trace" CNT="$T/cnt"; : > "$TRACE"

# 假 hpush：記推播內容（fail loud 驗證用）
printf '#!/bin/sh\necho "hpush $*" >> "%s/push"\n' "$T" > "$T/bin/hpush"
chmod +x "$T/bin/hpush"
printf '#!/usr/bin/env bash\necho "openbot-handoff $*" >> "%s/unexpected-push"\n' "$T" > "$T/bin/openbot-handoff"; chmod +x "$T/bin/openbot-handoff"

# 假 foo lint：記 argv，stdout/stderr 都印一行，用來確認 dcq add 的 stdout 仍只有 job id
cat > "$T/home/dev/fm-harness/bin/foo" <<'EOQ'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FOOTRACE"
echo "mock lint stdout"
echo "mock lint stderr" >&2
exit "${FOO_LINT_RC:-0}"
EOQ
chmod +x "$T/home/dev/fm-harness/bin/foo"

echo "# foo 單" > "$T/tasks/foo.md"

# 1) plan 接受 foo：免費層在、訂閱層不在、有純免費堅持提示
plan="$(DCQ_ORDER=foo DCQ_AUTORANK=0 "$R/bin/dcq" plan "$T/tasks/foo.md" 2>&1)"; rc=$?
chk "plan 接受 DCQ_ORDER=foo" "$rc" "0"
echo "$plan" | grep -q '1 免費 opencode：za' && echo "ok - plan foo 列免費層" || { echo "not ok - plan foo 沒列免費層：$plan"; fail=1; }
if echo "$plan" | grep -q '訂閱（付費）'; then echo "not ok - plan foo 仍列訂閱層：$plan"; fail=1; else echo "ok - plan foo 不列訂閱層"; fi
echo "$plan" | grep -q '純免費堅持' && echo "ok - plan foo 有純免費堅持提示" || { echo "not ok - plan foo 缺堅持提示：$plan"; fail=1; }

# 2) add 記 ORDER=foo＋VIA=foo、呼叫 foo lint 一次；lint 輸出只在 stderr，stdout 仍單行 job id
out="$(env HOME="$T/home" FOOTRACE="$T/foo.trace" DCQ_ORDER=foo "$R/bin/dcq" add "$T/tasks/foo.md" "$T/w" mid 2>"$T/add.err")"; rc=$?
chk "DCQ_ORDER=foo add rc" "$rc" "0"
chk "dcq add stdout 單行 job id" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
chk "job id 非空" "$([ -n "$out" ] && echo yes)" "yes"
id="$out"
chk "job 記 ORDER=foo" "$(grep -c '^ORDER=foo$' "$DCQ_HOME/pending/$id.job" 2>/dev/null)" "1"
chk "job 記 VIA=foo" "$(grep -c '^VIA=foo$' "$DCQ_HOME/pending/$id.job" 2>/dev/null)" "1"
chk "foo lint argv" "$(cat "$T/foo.trace" 2>/dev/null)" "lint $T/tasks/foo.md $T/w"
chk "lint stdout 改走 stderr" "$(grep -c 'mock lint stdout' "$T/add.err")" "1"
chk "lint stderr 保留" "$(grep -c 'mock lint stderr' "$T/add.err")" "1"

# 3) lint 失敗也是 advisory：不擋入列
echo "# lint 失敗照派" > "$T/tasks/lintfail.md"
out2="$(env HOME="$T/home" FOOTRACE="$T/foo.trace" FOO_LINT_RC=9 DCQ_ORDER=foo "$R/bin/dcq" add "$T/tasks/lintfail.md" "$T/w" mid 2>/dev/null)"; rc=$?
chk "lint rc=9 仍入列" "$rc" "0"
chk "lint 失敗單也記 VIA=foo" "$(grep -c '^VIA=foo$' "$DCQ_HOME/pending/$out2.job" 2>/dev/null)" "1"

# 3b) foo 不存在：lint 仍 advisory，但 stderr 要明說略過；job 照舊入列＋標 VIA
echo "# foo 不存在照派" > "$T/tasks/nofoo.md"
mkdir -p "$T/home2/dev/fm-harness/bin"
out3="$(env HOME="$T/home2" DCQ_ORDER=foo "$R/bin/dcq" add "$T/tasks/nofoo.md" "$T/w" mid 2>"$T/nofoo.err")"; rc=$?
chk "foo 不存在仍入列" "$rc" "0"
chk "foo 不存在 stderr 明說略過" "$(grep -c '派foo lint 略過' "$T/nofoo.err")" "1"
chk "foo 不存在也記 VIA=foo" "$(grep -c '^VIA=foo$' "$DCQ_HOME/pending/$out3.job" 2>/dev/null)" "1"

# 4) 純免費堅持：za 第一次上游失敗（沒進 noretry）→ 免費梯用盡不升訂閱，重來整梯再試 za 過關
rm -f "$DCQ_HOME/pending/$out2.job" "$DCQ_HOME/pending/$out3.job"   # 只跑第一張，避免 trace 混進其他單
DCQ_AUTORANK=0 DCQ_ALLOWED_FAILS=9 DCQ_FOO_WAIT_S=1 "$R/bin/dcq" run -j 1 >/dev/null 2>&1
chk "foo 堅持重試 za 兩次" "$(awk '/^IN foo /{print $3}' "$TRACE" | tr '\n' ' ')" "za za "
chk "foo 不碰訂閱層" "$(grep -c 'opencode-go' "$TRACE" || true)" "0"
chk "foo 完工" "$(ls "$DCQ_HOME"/done/*-foo.job 2>/dev/null | wc -l | tr -d ' ')" "1"

# 5) 真跑過但驗收未過（noretry）→ 免費模型全進 noretry 就放棄，不無窮等、也不碰訂閱
echo "# zafail 單" > "$T/tasks/zafail.md"
zout="$(env HOME="$T/home" FOOTRACE="$T/foo.trace" DCQ_ORDER=foo "$R/bin/dcq" add "$T/tasks/zafail.md" "$T/w" mid 2>/dev/null)"
: > "$TRACE"
DCQ_AUTORANK=0 DCQ_ALLOWED_FAILS=9 DCQ_FOO_WAIT_S=1 "$R/bin/dcq" run -j 1 >/dev/null 2>&1
chk "zafail 只試一次 za 就放棄" "$(awk '/^IN zafail /{print $3}' "$TRACE" | tr '\n' ' ')" "za "
chk "zafail 不碰訂閱層" "$(grep -c 'opencode-go' "$TRACE" || true)" "0"
chk "zafail 結案失敗" "$(ls "$DCQ_HOME"/failed/*-zafail.job 2>/dev/null | wc -l | tr -d ' ')" "1"

# 6) DCQ_FOO_PERSIST_S：za 永遠上游失敗（不進 noretry），沒預算會等到 JOB_MAX；
#    預算 3s 要在時限內放棄，不等 45 分鐘、也不碰訂閱
echo "# zastuck 單" > "$T/tasks/zastuck.md"
sout="$(env HOME="$T/home" FOOTRACE="$T/foo.trace" DCQ_ORDER=foo "$R/bin/dcq" add "$T/tasks/zastuck.md" "$T/w" mid 2>/dev/null)"
: > "$TRACE"
t_start=$(date +%s)
DCQ_AUTORANK=0 DCQ_ALLOWED_FAILS=9 DCQ_FOO_WAIT_S=1 DCQ_FOO_PERSIST_S=3 "$R/bin/dcq" run -j 1 >/dev/null 2>&1
elapsed=$(( $(date +%s) - t_start ))
chk "zastuck 結案失敗" "$(ls "$DCQ_HOME"/failed/*-zastuck.job 2>/dev/null | wc -l | tr -d ' ')" "1"
chk "zastuck 不碰訂閱層" "$(grep -c 'opencode-go' "$TRACE" || true)" "0"
[ "$elapsed" -lt 60 ] && echo "ok - zastuck 預算內放棄（${elapsed}s < 60s）" || { echo "not ok - zastuck 跑太久：${elapsed}s"; fail=1; }

# 7) fail loud：結案失敗落 fail.tsv 本機帳＋hpush 推播（含 order 與失敗類型）；of 單同機制
echo "# ofail 單" > "$T/tasks/ofail.md"
env HOME="$T/home" FOOTRACE="$T/foo.trace" DCQ_ORDER=free "$R/bin/dcq" add "$T/tasks/ofail.md" "$T/w" mid >/dev/null 2>&1
DC_PUSH=1 DCQ_FAIL_TG_EVERY=0 DCQ_AUTORANK=0 DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 >/dev/null 2>&1
sleep 1   # 推播是背景送的，等它落檔
chk "ofail 結案失敗" "$(ls "$DCQ_HOME"/failed/*-ofail.job 2>/dev/null | wc -l | tr -d ' ')" "1"
chk "fail.tsv 落帳 ofail" "$(grep -c 'ofail' "$DCQ_HOME/logs/fail.tsv" 2>/dev/null || true)" "1"
chk "fail.tsv 也落帳 zafail（foo）" "$(grep -c 'zafail' "$DCQ_HOME/logs/fail.tsv" 2>/dev/null || true)" "1"
if grep -q 'order=free' "$T/push" && grep -q '驗收未過' "$T/push"; then echo "ok - of 失敗推播含 order 與原因"
else echo "not ok - 推播內容：$(cat "$T/push" 2>/dev/null)"; fail=1; fi

[ ! -s "$T/unexpected-push" ] && echo "PASS 無人再叫 openbot-handoff" || { echo "FAIL 有程式還在叫 openbot-handoff：$(head -2 "$T/unexpected-push" 2>/dev/null)"; fail=1; }
exit "$fail"
