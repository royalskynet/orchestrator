#!/usr/bin/env bash
# dcq best-of-N（2026-10-25）：hard 工單、強模型全冷卻 → 同派 fit=easy 的便宜模型，第一隻驗收過的採用、其餘殺掉。
# 假 dc 依 DC_FREE_MODEL 決定行為，不打上游。斷言：
#   1) 三隻候選同時跑、各在自己的 .bon worktree  2) w2 勝出：job 進 done、記 BON=w2、改動 merge 回主 checkout
#   3) 慢的 w3 被殺（整張遠小於它的 40s）  4) .bon 收乾淨  5) mid 工單不走 best-of-N  6) plan 對 hard 印 best-of-N 行
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
export DCQ_HOME="$T/q" DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_CATALOG="$T/cat"
export DC_FREECHECK=off DC_NEGCTL=0 DCQ_POLL_S=1 DCQ_POOLSYNC=0 DCQ_FREE_ROUNDS=1 DCQ_GO_STATE="$T/none.json" DCQ_AUTORANK=0
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json" DCQ_ORDER=free DCQ_PROV_MAX="zen=4"
unset DCQ_POOL_ZEN DCQ_POOL_TAIL DCQ_POOL_PAID DCQ_POOL_GO DCQ_MODELS DCQ_EASY_ONLY DCQ_EASY_STRICT DCQ_ALLOW_API DCQ_TIER DCQ_BON_N
mkdir -p "$T/bin" "$T/cat"
fail=0; ok() { echo "ok - $1"; }; bad() { echo "not ok - $1"; fail=1; }

printf '# 測試清冊\n' > "$T/cat/models.tsv"
for m in strong:any w1:easy w2:easy w3:easy; do printf 'free\topencode-run\t%s\tok\tx\tx\t%s\t%s\n' "${m%%:*}" "${m%%:*}" "${m#*:}" >> "$T/cat/models.tsv"; done
: > "$T/cat/providers.tsv"

export TRACE="$T/trace"; : > "$TRACE"
cat > "$T/bin/dc" <<'EOF'
#!/usr/bin/env bash
echo "IN $DC_FREE_MODEL $2 $(date +%s)" >> "$TRACE"
case "$DC_FREE_MODEL" in
  w1) sleep 2; exit 1 ;;
  w2) sleep 3; echo w2 > "$2/out.txt"; exit 0 ;;
  w3) sleep 40; exit 0 ;;
  *) sleep 1; exit 1 ;;
esac
EOF
# 假 wo-verify：--dry 一律過；正式驗收看 cwd 有沒有 out.txt
printf '#!/bin/sh\n[ "${2:-}" = --dry ] && exit 0\n[ -f out.txt ]\n' > "$T/bin/wo-verify"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"
chmod +x "$T/bin/"*

git init -q "$T/repo"; git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo "# h" > "$T/h.md"
"$R/bin/dcq" status >/dev/null 2>&1   # 建 $Q 目錄
mkdir -p "$DCQ_HOME/.health"; echo $(( $(date +%s) + 3600 )) > "$DCQ_HOME/.health/strong.cool"

# 6) plan
DCQ_TIER=hard "$R/bin/dcq" plan "$T/h.md" 2>&1 | grep -q 'best-of-N 同派 ≤3 隻 fit=easy（w1 w2 w3）' && ok "plan 對 hard 印 best-of-N" || bad "plan 沒印 best-of-N：$("$R/bin/dcq" plan "$T/h.md" 2>&1 | tail -5)"

id="$("$R/bin/dcq" add "$T/h.md" "$T/repo" hard 2>/dev/null)"
t0=$(date +%s); "$R/bin/dcq" run -j 1 > "$T/run.out" 2>&1; dt=$(( $(date +%s) - t0 ))

n="$(grep -c '/\.bon/' "$TRACE")"
[ "$n" = 3 ] && [ "$(grep '/\.bon/' "$TRACE" | awk '{print $3}' | sort -u | wc -l | tr -d ' ')" = 3 ] && ok "三隻候選各在自己的 .bon worktree" || bad "候選：$(cat "$TRACE")"
[ -e "$DCQ_HOME/done/$id.job" ] && grep -q '^BON=w2$' "$DCQ_HOME/done/$id.job" && ok "w2 勝出、記 BON=w2" || bad "job 狀態：$(ls "$DCQ_HOME"/done "$DCQ_HOME"/failed; tail -20 "$T/run.out")"
[ "$(cat "$T/repo/out.txt" 2>/dev/null)" = w2 ] && ok "勝出改動 merge 回主 checkout" || bad "主 checkout 沒有 out.txt：$(git -C "$T/repo" log --oneline | head -3)"
[ "$dt" -lt 25 ] && ok "慢的 w3 被殺（整張 ${dt}s）" || bad "等了 w3：${dt}s"
[ -z "$(ls -A "$DCQ_HOME/.bon" 2>/dev/null)" ] && ok ".bon 收乾淨" || bad ".bon 殘留：$(ls -A "$DCQ_HOME/.bon")"
[ -z "$(git -C "$T/repo" worktree list | grep '\.bon')" ] && ok "git worktree 清單沒有 .bon" || bad "worktree 殘留：$(git -C "$T/repo" worktree list)"

# 5) mid 不走 best-of-N
: > "$TRACE"; rm -f "$T/repo/out.txt"; git -C "$T/repo" -c user.email=t@t -c user.name=t commit -qam rm >/dev/null 2>&1
echo "# m" > "$T/m.md"; "$R/bin/dcq" add "$T/m.md" "$T/repo" mid >/dev/null 2>&1
DCQ_ALLOWED_FAILS=9 "$R/bin/dcq" run -j 1 > "$T/run2.out" 2>&1
if grep -q 'best-of-N' "$T/run2.out" || grep -q '/\.bon/' "$TRACE"; then bad "mid 工單走了 best-of-N"; else ok "mid 工單不走 best-of-N"; fi

[ "$fail" = 0 ] && echo BON_OK
exit "$fail"
