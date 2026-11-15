#!/usr/bin/env bash
# dc 的 opencode 本機 DB 錯自檢：輸出檔行首匹配 no such column: project_id 且 rc!=0 時要判 exit 2。
set -u
. "$(dirname "$0")/env.sh"
DC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/w" "$T/cfg/opencode"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH"
export DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0 DC_OC_V2=0
export VERIFIED="$T/verified"

cat > "$T/bin/opencode" <<'X'
#!/usr/bin/env bash
[ "$1" = debug ] && { echo '{}'; exit 0; }
case "$FAKE" in
  localdb_head)
    echo '> build · x'
    echo 'no such column: project_id'
    exit 1
    ;;
  localdb_mid)
    echo '> build · x'
    echo 'prefix no such column: project_id'
    exit 1
    ;;
esac
X
printf '#!/bin/sh\ncase "$2" in --dry|--dump) ;; *) echo ok > "$VERIFIED";; esac\nexit 0\n' > "$T/bin/wo-verify"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"
chmod +x "$T/bin"/*
printf '# t\n' > "$T/t.md"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

rm -f "$VERIFIED"
env FAKE=localdb_head "$DC" "$T/t.md" "$T/w" > "$T/errA" 2>&1; rcA=$?
chk "案例A rc=2" "$rcA" "2"

rm -f "$VERIFIED"
env FAKE=localdb_mid "$DC" "$T/t.md" "$T/w" > "$T/errB" 2>&1; rcB=$?
chk "案例B rc=1" "$rcB" "1"

if [ "$fail" = 0 ]; then
  echo "ALL PASS"
fi
exit "$fail"
