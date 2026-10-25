#!/usr/bin/env bash
# freecheck 判準自檢：假 curl 回指定 usage，不打上游、不發推播。
# 斷言加白語意：percent>0 只 WARN 不停單；額度窗受限 exit 5 不寫 .ALARM（不停整個 dcq）；目錄消失才警報；全 0 放行。
set -u
. "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
case "$*" in *usage*) printf '%s' "$FAKE_USAGE" ;; *) echo '["longcat-2.5-preview-free","space-bunny-free"]' ;; esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/hpush"
chmod +x "$T/bin/"*
export OPENCODE_GO_API_KEY=fake DCQ_HOME="$T/q" PATH="$T/bin:$PATH"

fail=0
chk() { # name usage want_rc want_alarm
  rm -f "$T/q/.ALARM"
  FAKE_USAGE="$2" bin/freecheck longcat-2.5-preview-free >/dev/null 2>&1; rc=$?
  a=N; [ -e "$T/q/.ALARM" ] && a=Y
  if [ "$rc" = "$3" ] && [ "$a" = "$4" ]; then echo "PASS $1"; else echo "FAIL $1: rc=$rc alarm=$a want rc=$3 alarm=$4"; fail=1; fi
}
chk "percent>0 加白只 WARN" '{"usage":{"weekly":{"status":"ok","percent":5}}}' 0 N
chk "額度窗受限算額度用完"  '{"usage":{"weekly":{"status":"limited","percent":100}}}' 5 N
chk "全 0 放行"             '{"usage":{"weekly":{"status":"ok","percent":0}}}' 0 N
# 目錄消失仍警報（假目錄沒有 longcat）
printf '#!/bin/sh\ncase "$*" in *usage*) printf "%%s" "$FAKE_USAGE" ;; *) echo "[\\"space-bunny-free\\"]" ;; esac\n' > "$T/bin/curl"
chk "Go 目錄消失仍警報"     '{"usage":{"weekly":{"status":"ok","percent":0}}}' 3 Y
# 警報推播：DCQ_HOME 是暫存路徑不推，DC_PUSH=1 才推（10-21，測試不發真 TG）
printf '#!/bin/sh\necho x >> "%s/push"\n' "$T" > "$T/bin/hpush"
lim='{"usage":{"weekly":{"status":"ok","percent":0}}}'
FAKE_USAGE="$lim" bin/freecheck longcat-2.5-preview-free >/dev/null 2>&1
[ ! -s "$T/push" ] && echo "PASS 暫存狀態目錄不推播" || { echo "FAIL 暫存狀態目錄推播了"; fail=1; }
FAKE_USAGE="$lim" DC_PUSH=1 bin/freecheck longcat-2.5-preview-free >/dev/null 2>&1
[ -s "$T/push" ] && echo "PASS DC_PUSH=1 照推" || { echo "FAIL DC_PUSH=1 沒推"; fail=1; }
exit $fail
