#!/usr/bin/env bash
# 共用判定鏈自檢：假執行人、本機 git，不打上游。
set -u
. "$(dirname "$0")/env.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/bin/gate"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
mkdir -p "$T/bin" "$T/r/test"
export DC_BIN="$T/bin" DC_NEGCTL=0 DC_VERIFY_K=1
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"
ln -s "$ROOT/bin/wo-verify" "$T/bin/wo-verify"
cat > "$T/bin/opencode" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' 'pytest.mark.skip' >> "$1/test/x_test.sh"
EOS
chmod +x "$T/bin/deep-lint" "$T/bin/opencode"
git init -q "$T/r"
printf 'echo test\n' > "$T/r/test/x_test.sh"
git -C "$T/r" add test/x_test.sh
git -C "$T/r" -c user.name=t -c user.email=t@t commit -qm init
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
task() {
  cat > "$T/task.md" <<'EOS'
# task
regress: printf '0 stable\n'
## 驗收
```bash
test -f done
```
EOS
}
pre() { "$G" preflight "$T/task.md" "$T/r" "$T/pf" > "$T/o" 2>&1; rc=$?; }
judge() { "$G" judge "$T/task.md" "$T/r" "$T/pf" --k 1 > "$T/o" 2>&1; rc=$?; }
reset_case() {
  git -C "$T/r" reset --hard -q HEAD
  git -C "$T/r" clean -fdq
  rm -rf "$T/pf"
  task
}
reset_case; pre
chk 'preflight 單獨執行' "$rc" 0
chk '產出 pin' "$(test -s "$T/pf/pin"; echo $?)" 0
chk '產出 regress.base' "$(cat "$T/pf/regress.base")" '0 stable'
cp "$T/pf/pin" "$T/expected"
printf '#!/bin/sh\nexit 99\n' > "$T/bin/deep-lint"
pre
chk '有 pin 不重跑 lint' "$rc" 0
chk '有 pin 保持原樣' "$(cmp -s "$T/expected" "$T/pf/pin"; echo $?)" 0
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"
touch "$T/r/done"
printf '\nfalse\n' >> "$T/pf/pin"
judge
chk 'pin 被改判 3' "$rc" 3
reset_case; pre; touch "$T/r/done"
"$T/bin/opencode" "$T/r"
judge
chk '新增 pytest.mark.skip 判 6' "$rc" 6
chk '作弊輸出含檔名' "$(grep -c 'dc: CHEAT：.*test/x_test.sh' "$T/o")" 1
reset_case; pre; touch "$T/r/done"; rm "$T/r/test/x_test.sh"
judge
chk '刪追蹤測試判 6' "$rc" 6
reset_case
printf '\nALLOW-SKIP: 合法測試停用\n' >> "$T/task.md"
pre; touch "$T/r/done"; "$T/bin/opencode" "$T/r"
judge
chk 'ALLOW-SKIP 不判' "$rc" 0
chk 'ALLOW-SKIP 有略過說明' "$(grep -c 'ALLOW-SKIP' "$T/o")" 1
reset_case
printf '# dirty\n' >> "$T/r/test/x_test.sh"
pre; touch "$T/r/done"; "$T/bin/opencode" "$T/r"
judge
chk '跑前髒測試不算' "$rc" 0
reset_case; pre; touch "$T/r/done"
printf 'test.skip("x")\n' > "$T/r/test/new.py"
judge
chk '未追蹤新增 skip 判 6' "$rc" 6
reset_case; pre; touch "$T/r/done"
printf '# ordinary comment\n' >> "$T/r/test/x_test.sh"
judge
chk '正常修改測試可通過' "$rc" 0
# 重試不可把第一次執行人改髒的檔納入排除清單。
reset_case; pre
"$T/bin/opencode" "$T/r"; pre; touch "$T/r/done"
judge
chk '重試沿用首次髒檔快照' "$rc" 6
reset_case; pre; touch "$T/r/done"
printf '0 other\n' > "$T/pf/regress.base"
judge
chk '回歸測試消失判 4' "$rc" 4
reset_case
cat > "$T/task.md" <<'EOS'
# flaky
## 驗收
```bash
n=$(cat count 2>/dev/null || echo 0); echo $((n + 1)) > count
test "$n" -lt 1
```
EOS
pre
DC_VERIFY_K=2 "$G" judge "$T/task.md" "$T/r" "$T/pf" > "$T/o" 2>&1
chk '預設 K 抓第二次失敗' "$?" 1
chk '保留 flaky 訊息' "$(grep -c '第 2 次才失敗' "$T/o")" 1
rm -f "$T/r/count"
judge
chk '--k 1 覆蓋預設次數' "$rc" 0
reset_case
printf '\nNEG-CONTROL: n/a\n' >> "$T/task.md"
touch "$T/r/done"
DC_NEGCTL=1 "$G" preflight "$T/task.md" "$T/r" "$T/pf" > "$T/o" 2>&1
chk '已完成 preflight 回 10' "$?" 10
chk '保留 SKIPPED 訊息' "$(grep -c '^dc: SKIPPED' "$T/o")" 1
exit "$fail"
