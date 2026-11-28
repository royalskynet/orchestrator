#!/usr/bin/env bash
# 全量測試（repo CLAUDE.md 的驗收指令）。開頭先印 git status：工作樹有未提交改動時
# 中止——別的 session 的半套改動會污染結果（issue #39：hpush 改名改一半，推播斷言全零查半天）。
# 確認髒檔是自己的再跑：RUN_ALL_DIRTY_OK=1 test/run_all.sh
set -u
cd "$(dirname "$0")/.."
dirty="$(git status --porcelain 2>/dev/null | grep -v '^??' || true)"
untracked_tests="$(git ls-files --others --exclude-standard -- 'test/*_test.sh' 2>/dev/null | sed 's/^/?? /' || true)"
[ -z "$untracked_tests" ] || dirty="${dirty:+$dirty
}$untracked_tests"
if [ -n "$dirty" ]; then
  echo "⚠️ 工作樹有未提交改動，測試結果會混入這些改動（issue #39）："
  echo "$dirty"
  [ "${RUN_ALL_DIRTY_OK:-}" = 1 ] || { echo "是自己的改動就明講再跑：RUN_ALL_DIRTY_OK=1 $0"; exit 2; }
fi
fail=0
for f in test/*_test.sh; do
  case "$f" in
    test/wo_e_acceptance_test.sh) limit=1200 ;;
    test/dcq_test.sh) limit=900 ;;
    *) limit=600 ;;
  esac
  timeout "$limit" bash "$f" >/dev/null 2>&1 || { echo "FAIL $f"; fail=1; }
done
[ "$fail" = 0 ] && echo ALL_PASS
exit $fail
