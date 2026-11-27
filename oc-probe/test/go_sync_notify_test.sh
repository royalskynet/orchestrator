#!/usr/bin/env bash
# go-sync 模型上下架是純資訊：不得呼叫 hpush，只寫 log。
set -u
cd "$(dirname "$0")/.."
if grep -q 'def notify' bin/go-sync; then echo 'FAIL: notify() 仍存在'; exit 1; fi
if grep -q 'hpush' bin/go-sync; then echo 'FAIL: go-sync 仍引用 hpush'; exit 1; fi
if grep -q 'notify(' bin/go-sync; then echo 'FAIL: go-sync 仍呼叫 notify'; exit 1; fi
python3 bin/go-sync --selftest >/dev/null || { echo 'FAIL: selftest'; exit 1; }
echo GO_SYNC_NOTIFY_TEST_PASS
