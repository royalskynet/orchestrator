#!/usr/bin/env bash
# ds-run 能力內嵌 dcq 的回歸：ask／review／contract 都只產生 dcq 工單，不起獨立 runner；
# 三者的 task/ 輸入與產出都在未提交區，必須記 NOWT=1，否則切 worktree 後 worker 看不到輸入。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q" DCQ_CATALOG="$T/cat" DCQ_AUTOSTART=0
mkdir -p "$T/cat" "$T/repo"
printf 'free\topencode-run\topencode/za\tok\tx\tx\tza\tany\n' > "$T/cat/models.tsv"
printf 'omniroute\t3\tx\n' > "$T/cat/providers.tsv"
dcq() { "$R/bin/dcq" "$@"; }
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }

(cd "$T/repo" && git init -q && git config user.email t@x && git config user.name t && echo base > a.txt && git add a.txt && git commit -qm init) || { bad 'fixture repo init'; exit 1; }

id="$(dcq ask "$T/repo" 'what is a.txt' easy 2>"$T/ask.err")"; rc=$?
[ "$rc" = 0 ] && [ -f "$DCQ_HOME/pending/$id.job" ] && ok 'ask 入列' || { bad "ask 入列 rc=$rc id=$id err=$(cat "$T/ask.err")"; }
grep -qx 'NOWT=1' "$DCQ_HOME/pending/$id.job" && grep -qx 'SPIN=0' "$DCQ_HOME/pending/$id.job" && ok 'ask 關 worktree 與空轉偵測' || bad 'ask job flags'
askf="$(ls "$DCQ_HOME"/generated/ask-*.md 2>/dev/null | head -1)"
grep -q '^writes!: task/notes.md$' "$askf" && grep -q 'test -s task/notes.md' "$askf" && ok 'ask 工單唯讀產出與驗收' || bad 'ask 工單內容'

echo mod > "$T/repo/a.txt"; echo new > "$T/repo/new.txt"
id2="$(dcq review "$T/repo" easy 2>"$T/review.err")"; rc=$?
[ "$rc" = 0 ] && [ -f "$DCQ_HOME/pending/$id2.job" ] && ok 'review 入列' || bad "review 入列 rc=$rc err=$(cat "$T/review.err")"
grep -q '^+mod$' "$T/repo/task/review.diff" && grep -q '^+new$' "$T/repo/task/review.diff" && ok 'review.diff 含工作樹與未追蹤改動' || bad 'review.diff 內容'
grep -qx 'NOWT=1' "$DCQ_HOME/pending/$id2.job" && ok 'review 關 worktree' || bad 'review job flags'
revf="$(ls "$DCQ_HOME"/generated/review-*.md 2>/dev/null | head -1)"
grep -q '^writes!: task/review.md$' "$revf" && grep -q '^grep -Eq.*VERDICT' "$revf" && ok 'review 工單 verdict 驗收' || bad 'review 工單內容'

mkdir -p "$T/repo/task"
printf 'change a.txt\n' > "$T/repo/task/SPEC.md"
printf 'a.txt\n' > "$T/repo/task/scope.txt"
printf '#!/bin/sh\ntest -s a.txt\n' > "$T/repo/task/verify.sh"
id3="$(dcq contract "$T/repo" easy 2>"$T/contract.err")"; rc=$?
[ "$rc" = 0 ] && [ -f "$DCQ_HOME/pending/$id3.job" ] && ok 'contract 入列' || bad "contract 入列 rc=$rc err=$(cat "$T/contract.err")"
grep -qx 'NOWT=1' "$DCQ_HOME/pending/$id3.job" && ok 'contract 關 worktree' || bad 'contract job flags'
cf="$(ls "$DCQ_HOME"/generated/contract-*.md 2>/dev/null | head -1)"
grep -q '^writes!:a.txt$' "$cf" && grep -q '^bash task/verify.sh$' "$cf" && grep -q '^NEG-CONTROL: n/a$' "$cf" && ok 'contract 工單承接 scope、verify 與已完成略過' || bad 'contract 工單內容'
printf 'task/verify.sh\n' > "$T/repo/task/scope.txt"
dcq contract "$T/repo" easy >/dev/null 2>"$T/badscope.err"; rc=$?
[ "$rc" = 2 ] && grep -q '不可含 task/' "$T/badscope.err" && ok 'contract 拒絕把契約檔放進 scope' || bad "contract 壞 scope rc=$rc err=$(cat "$T/badscope.err")"

h="$(dcq help 2>&1)"
for x in 'dcq ask' 'dcq review' 'dcq contract'; do
  case "$h" in *"$x"*) ok "help 有 $x" ;; *) bad "help 缺 $x" ;; esac
done
[ ! -e "$R/bin/ds-run" ] && ok '獨立 bin/ds-run 已移除' || bad 'bin/ds-run 仍存在'
exit $fail
