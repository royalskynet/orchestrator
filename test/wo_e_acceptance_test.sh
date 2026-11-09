#!/usr/bin/env bash
# WO-E 驗收（runner 隔離 #22、DCQ_MODELS 逐單 #23）包成可重跑的測試。
# 並行 dcq_tier 用 pids 逐一 wait 取 exit code，不只 grep not ok。
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
cd "$R" || exit 1
T="$(mktemp -d)" || exit 1; [ -d "$T" ] || exit 1
trap '[ -n "$T" ] && [ -d "$T" ] && [ "$T" != "$R" ] && case "$T" in "${TMPDIR:-/tmp}"*|/tmp/*|/var/folders/*) rm -rf "$T" ;; esac' EXIT
fail=0; ok() { echo "ok - $1"; }; bad() { echo "not ok - $1"; fail=1; }

bash test/dcq_isolation_test.sh >/dev/null 2>&1 && ok isolation || bad isolation
bash test/dcq_models_job_test.sh >/dev/null 2>&1 && ok models_job || bad models_job

# 六次並行 dcq_tier（兩輪 × 3）
for r in 1 2; do
  pids=()
  for i in 1 2 3; do bash test/dcq_tier_test.sh >"$T/tier.$r.$i" 2>&1 & pids+=("$!"); done
  for p in "${pids[@]}"; do wait "$p" || bad "dcq_tier 並行第 $r 輪 pid $p"; done
done
for f in "$T"/tier.*; do if grep -q '^not ok' "$f"; then bad "dcq_tier $(basename "$f")：$(grep -m1 '^not ok' "$f")"; fi; done
[ "$fail" = 0 ] && ok "dcq_tier 並行 6/6"

n="$(tmux -L dcq list-panes -a -F '#{pane_start_command}' 2>/dev/null | grep -c '/T/tmp\.')"
[ "$n" = 0 ] && ok "-L dcq 沒有指向暫存目錄的 runner" || bad "-L dcq 殘留暫存 runner：$n"

# 突變（各用全新副本）
mut() { local M; M="$(mktemp -d /tmp/wof7-mut.XXXXXX)" || return 1; cp -R bin test catalog oc-probe executor-rules.md "$M/" 2>/dev/null; echo "$M"; }
M="$(mut)"; perl -i -pe 's/^(\s*)(echo "MODELS=)/$1: $2/' "$M/bin/dcq"
if bash "$M/test/dcq_models_job_test.sh" >/dev/null 2>&1; then bad "mutation models-job survived"; else ok "mutation models-job killed"; fi; rm -rf "$M"
M="$(mut)"; perl -i -pe 's/^dcq_sock\(\) \{/dcq_sock() { echo "\${DCQ_TMUX:-dcq}"; return; /' "$M/bin/dcq"
if bash "$M/test/dcq_isolation_test.sh" >/dev/null 2>&1; then bad "mutation socket survived"; else ok "mutation socket killed"; fi; rm -rf "$M"
# WO-F：快照改回只存原路徑、#23 清池那行拿掉
M="$(mut)"; perl -0 -i -pe 's/^dcq_snapshot\(\) \{/dcq_snapshot() { printf "%s" "\$2"; return; /m' "$M/bin/dcq"
if bash "$M/test/dcq_snapshot_test.sh" >/dev/null 2>&1; then bad "mutation snapshot survived"; else ok "mutation snapshot killed"; fi; rm -rf "$M"
M="$(mut)"; perl -i -pe 's/^(\s*)pen_pool="" zero_pool="" tail_pool="" fp_pool="".*$/$1:/' "$M/bin/dcq"
if bash "$M/test/dcq_models_job_test.sh" >/dev/null 2>&1; then bad "mutation models-fallback survived"; else ok "mutation models-fallback killed"; fi; rm -rf "$M"

# WO-F3：每個突變必須命中指定保護，且對應行為測試必須失敗。
for mutation in ensure-snapshot task0 add-cleanup gc-jtmp gc-age models-bon wt-rewrite cancel-cleanup; do
  M="$(mut)"
  python3 - "$M/bin/dcq" "$mutation" <<'PYM'
import sys
p, mutation = sys.argv[1:]
s = open(p).read()
if mutation == 'ensure-snapshot':
    old = 'if dcq_ensure_snapshot "$id" "$t"; then'
    new = 'if true; then'
elif mutation == 'task0':
    a = s.index('wt_setup() {'); b = s.index('wt_restore_job() {', a)
    part = s[a:b]
    assert 'TASK0=%s\\n' in part
    part = part.replace('TASK0=%s\\n', '').replace('"$wt" "$t0" "$cwd"', '"$wt" "$cwd"')
    s = s[:a] + part + s[b:]
    old = new = None
elif mutation == 'wt-rewrite':
    old = '  sed "s#$(re_esc "$cwd")#$(rp_esc "$wt")#g" "$task" > "$tcopy"'
    new = '  if [ -n "${WTASK:-}" ]; then sed "s#$(re_esc "$cwd")#$(rp_esc "$wt")#g" "$task" > "$tcopy"; else cp "$task" "$tcopy"; fi'
elif mutation == 'cancel-cleanup':
    a = s.index('cmd_cancel() {'); b = s.index('\n}', a)
    part = s[a:b]
    old_line = '      rm -rf "$Q/.src/$id"'
    assert part.count(old_line) == 1
    s = s[:a] + part.replace(old_line, '      :', 1) + s[b:]
    old = new = None
elif mutation == 'add-cleanup':
    old = 'rm -f "$jtmp"; rm -rf "$Q/.src/$id"; die "dcq add：寫 job 檔失敗"'
    new = 'rm -f "$jtmp"; die "dcq add：寫 job 檔失敗"'
elif mutation == 'gc-jtmp':
    old = ' || [ -e "$Q/pending/.$id.job.tmp" ]'
    new = ''
elif mutation == 'gc-age':
    old = '    [ "$(( $(now) - $(mtime "$d") ))" -lt 600 ] && continue'
    new = '    :'
else:
    old = ' && [ -z "$jm" ] && [ "$JOB_TIER" = hard ]'
    new = ' && [ "$JOB_TIER" = hard ]'
if old is not None:
    assert s.count(old) == 1, (mutation, s.count(old))
    s = s.replace(old, new, 1)
open(p, 'w').write(s)
PYM
  if [ "$?" != 0 ]; then bad "mutation $mutation 未命中"; rm -rf "$M"; continue; fi
  if ! bash -n "$M/bin/dcq"; then bad "mutation $mutation 語法錯誤"; rm -rf "$M"; continue; fi
  case "$mutation" in
    wt-rewrite) test_name=dcq_worktree_test ;;
    task0) test_name=dcq_orphan_restore_test ;;
    models-bon) test_name=dcq_models_job_test ;;
    *) test_name=dcq_snapshot_test ;;
  esac
  if bash "$M/test/$test_name.sh" >"$T/$mutation.log" 2>&1; then
    bad "mutation $mutation survived"
  else
    ok "mutation $mutation killed"
  fi
  rm -rf "$M"
done

# WO-F5：只拿掉 claim_one 裡提前補快照的那個 if 區塊（run_job 的呼叫與 prep_task 本身都留），舊單測試必須紅。
# 失敗要來自行為（TASK0= 指回可變原檔／重派內容漂移），不是語法錯、缺檔或跑不起來：只收 FAIL 行。
mut_apply() {   # $1=副本根目錄 $2=python 片段；成功回 0
  python3 - "$1/bin/dcq" "$2" <<'PYM'
import sys
p, mode = sys.argv[1:]
s = open(p).read()
if mode == 'legacy-snapshot':
    a = s.index('claim_one() {'); b = s.index('\n}\n', a)
    part = s[a:b]
    i = part.index('    # 舊單（快照上線前入列）先補快照')
    j = part.index('    # 乾淨的 git cwd')
    chunk = part[i:j]
    assert 'prep_task "$Q/running/$id.job" "$id"' in chunk and chunk.count('    if ') == 1, chunk
    body = ''.join('#' + ln[4:] + '\n' for ln in chunk.splitlines())
    s = s[:a] + part[:i] + body + part[j:] + s[b:]
else:
    sys.exit('unknown mutation')
open(p, 'w').write(s)
PYM
}
# 只替換必要操作；setup 與錯誤處理保持原樣。
mut_fixture() {
  python3 - "$1" "$2" <<'PYF'
import sys
p, mode = sys.argv[1:]
s = open(p).read()
if mode == 'fixture-failure':
    old = "cp -R '$SAVE.src/.' '$DCQ_HOME/.src/legacy/'"
    new = 'exit 1 # ' + old
elif mode == 'fixture-write-failure':
    old = "  printf '# a\\n只是測試\\nCHANGED-CONTENT\\n' > \"$T/legacy.md\""
    new = '  return 1 # 保留原內容，僅讓寫入操作失敗'
else:
    raise SystemExit('unknown mutation')
assert s.count(old) == 1, (mode, s.count(old))
open(p, 'w').write(s.replace(old, new, 1))
PYF
}
mut_kill() {   # $1=突變名 $2=測試檔 $3=期望失敗訊息
  local M rc tf="test/$2"
  M="$(mut)" || return 1
  case "$1" in
    fixture-failure|fixture-write-failure)
      if ! mut_fixture "$M/$tf" "$1"; then bad "mutation $1 未命中"; rm -rf "$M"; return 0; fi ;;
    *) if ! mut_apply "$M" "$1"; then bad "mutation $1 未命中"; rm -rf "$M"; return 0; fi ;;
  esac
  if ! bash -n "$M/bin/dcq" || ! bash -n "$M/$tf"; then bad "mutation $1 語法錯誤"; rm -rf "$M"; return 0; fi
  bash "$M/$tf" >"$T/$1.log" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then bad "mutation $1 survived"
  elif ! grep -qF "$3" "$T/$1.log"; then echo "--- $1 log ---"; cat "$T/$1.log"
    bad "mutation $1 killed 但證據不符：rc${rc}，找不到「$3」"
  else ok "mutation $1 killed"; fi
  rm -rf "$M"
}
mut_kill legacy-snapshot dcq_legacy_snapshot_test.sh 'FAIL worktree job 的 TASK0= 指快照'
mut_kill fixture-failure dcq_legacy_snapshot_test.sh 'FAIL 造景失敗：sh -c exit 1 # cp -R'
mut_kill fixture-write-failure dcq_legacy_snapshot_test.sh 'FAIL 造景失敗：write_original'

# 同一寫入故障，移除寫入保護與終態斷言後應重現假綠。
NC="$(mut)" || exit 1
if mut_fixture "$NC/test/dcq_legacy_snapshot_test.sh" fixture-write-failure &&
  python3 - "$NC/test/dcq_legacy_snapshot_test.sh" <<'PYN'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'setup write_original'
assert s.count(old) == 1
s = s.replace(old, 'write_original', 1)
a = s.index('# 改寫後必須確認造景成立，才進第二輪。')
b = s.index(': > "$TRACE"', a)
removed = s[a:b]
assert removed.count('FAIL 造景失敗：write_original') == 1
assert removed.count('fi\n') == 1
open(p, 'w').write(s[:a] + s[b:])
PYN
then
  if ! bash -n "$NC/test/dcq_legacy_snapshot_test.sh"; then bad "負控制 語法錯誤"
  elif bash "$NC/test/dcq_legacy_snapshot_test.sh" >"$T/negctl.log" 2>&1; then
    if grep -q '^PASS 第二輪 dc 拿到原內容$' "$T/negctl.log" &&
       grep -q '^PASS 第二輪 cwd 存在$' "$T/negctl.log"; then ok "負控制 無保護時假綠重現"
    else bad "負控制 缺少第二輪行為證據"; fi
  else
    cat "$T/negctl.log"
    bad "負控制 拿掉保護後注入仍非零"
  fi
else bad "負控制 未命中"; fi
rm -rf "$NC"

[ "$fail" = 0 ] && echo "PASS wo_e_acceptance" || { echo "FAIL wo_e_acceptance"; exit 1; }
