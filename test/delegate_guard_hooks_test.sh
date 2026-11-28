#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node delegate-guard/hooks/test/delegate-guard.test.mjs >/dev/null
echo PASS
