#!/usr/bin/env bash
# bash 有些 locale 會把 $var 後面緊貼的全形字（：）、等）吃進變數名，set -u 下直接 unbound variable 死掉
# （10-25 兩次：${POOL_MISS}）、${ocj}：）。變數後面接中文要寫 ${var}。
set -u
. "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/.."
hits="$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' bin/* 2>/dev/null | LC_ALL=C grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
[ -z "$hits" ] || { echo "FAIL \$var 緊貼非 ASCII（改寫成 \${var}）："; echo "$hits"; exit 1; }
echo CJK_VAR_OK
