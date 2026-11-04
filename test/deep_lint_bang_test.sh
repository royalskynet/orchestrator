#!/usr/bin/env bash
# deep-lint 遇裸 `! cmd` 驗收行必須 exit 1（set -e 下永不失敗）；改寫成 if…exit 1 要放行。
set -u
DL="$(cd "$(dirname "$0")/.." && pwd)/bin/deep-lint"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
mk(){ printf '# t\n\n## 目標\nx\n\n## 驗收\n預期：exit 0\n```bash\ntest -f /etc/hosts\n%s\n```\n' "$2" > "$d/$1.md"; }
mk bad '! grep -q zzz /etc/hosts'
mk good 'if grep -q zzz /etc/hosts; then exit 1; fi'
"$DL" "$d/bad.md" >/dev/null 2>&1 && { echo "FAIL bad passed"; exit 1; }
"$DL" "$d/good.md" >/dev/null 2>&1 || { echo "FAIL good rejected"; "$DL" "$d/good.md"; exit 1; }
echo "PASS deep_lint_bang"
