#!/usr/bin/env bash
# wo-verify 的 stdin 自檢：驗收行若讀 stdin（此處用 cat），不可吞掉後續斷言行。
# 舊版用 `printf … | bash`，cat 會把下一行 false 吃掉 → rc=0（假通過）。新版腳本走 bash -c 參數、stdin 接 /dev/null。
set -u
WV="${WV:-$(cd "$(dirname "$0")/.." && pwd)/bin/wo-verify}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

printf '# a\n\n## 驗收\n\n```bash\ncat >/dev/null\nfalse\n```\n' > "$T/a.md"
printf '# b\n\n## 驗收\n\n```bash\ncat >/dev/null\ntrue\n```\n' > "$T/b.md"

fail=0
out_a="$("$WV" "$T/a.md" 2>&1)"; rc_a=$?
if [ "$rc_a" = 0 ]; then echo "FAIL: A（cat 吞掉 false）rc=0，應為非零"; fail=1; fi
case "$out_a" in
  *"wo-verify FAIL line 2"*) ;;
  *) echo "FAIL: A 輸出缺 'wo-verify FAIL line 2'"; fail=1 ;;
esac
out_b="$("$WV" "$T/b.md" 2>&1)"; rc_b=$?
if [ "$rc_b" != 0 ]; then echo "FAIL: B（cat 後接 true）rc=$rc_b，應為 0"; fail=1; fi

if [ "$fail" = 0 ]; then echo "PASS"; exit 0; fi
echo "--- A 輸出：$out_a"
exit 1
