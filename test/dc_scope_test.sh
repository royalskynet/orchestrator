#!/usr/bin/env bash
# dc 範圍斷言自檢（I3，2026-10-23）：用假 opencode，不打上游。
# 為什麼要有：dr 執行人改了工單範圍外的檔（fixindex 10692），驗收沒有範圍斷言。
# 工單可選 `writes: a, b/`；跑完 git 看得到的改動檔不在 writes 內 → log 印 `SCOPE=over`，但不判 FAIL（rc 不變）。
#   1) 改動在 writes 內（檔／目錄／glob）→ 無 SCOPE=over、rc=0
#   2) 改了 writes 外的檔 → 印 SCOPE=over 與該檔名，rc 仍 0
#   3) 沒寫 writes 的工單 → 不檢查
#   4) 跑前就髒的檔不算
set -u
. "$(dirname "$0")/env.sh"
OC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
T="$(cd "$T" && pwd -P)"
mkdir -p "$T/bin" "$T/cfg/opencode"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0
unset DC_LOCK_HELD
git init -q "$T/r"
echo a > "$T/r/pre.txt"
git -C "$T/r" add pre.txt
git -C "$T/r" -c user.email=t@t -c user.name=t commit -q -m init
cat > "$T/bin/opencode" <<'EOS'
#!/usr/bin/env bash
for t in ${FAKE_TARGETS:-}; do mkdir -p "$(dirname "$t")"; echo x > "$t"; done
exit 0
EOS
chmod +x "$T/bin/opencode"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
run() { # $1=writes 行（空=不寫） $2=FAKE_TARGETS
  printf '# t\n%s\n' "$1" > "$T/t.md"
  FAKE_TARGETS="$2" "$OC" "$T/t.md" "$T/r" >"$T/o" 2>&1; echo $? > "$T/rc"
  find "$T/r" -mindepth 1 -maxdepth 1 ! -name .git ! -name pre.txt -exec rm -rf {} +
}
over() { grep -c 'SCOPE=over' "$T/o" | tr -d ' '; }

run "writes: src/, docs/a.md" "$T/r/src/x.txt $T/r/docs/a.md"
chk "目錄與單檔在範圍內：無 SCOPE=over" "$(over)" "0"
chk "目錄與單檔在範圍內：rc=0" "$(cat "$T/rc")" "0"
run "writes: *.txt" "$T/r/a.txt"
chk "glob 命中：無 SCOPE=over" "$(over)" "0"
run "writes: $T/r/src/" "$T/r/src/y.txt"
chk "絕對路徑寫法：無 SCOPE=over" "$(over)" "0"
run "writes: src/" "$T/r/src/x.txt $T/r/stray.txt"
chk "改了範圍外的檔：印 SCOPE=over" "$(over)" "1"
chk "SCOPE=over 列出越界檔名" "$(grep -c 'stray.txt' "$T/o" | tr -d ' ')" "1"
chk "SCOPE=over 不判 FAIL（rc=0）" "$(cat "$T/rc")" "0"
run "" "$T/r/stray.txt"
chk "沒寫 writes：不檢查" "$(over)" "0"
echo changed > "$T/r/pre.txt"
run "writes: src/" "$T/r/src/x.txt"
chk "跑前就髒的檔不算" "$(over)" "0"
git -C "$T/r" checkout -q pre.txt
run "writes: src/" "$T/r/pre.txt"
chk "改到追蹤檔且在範圍外：印 SCOPE=over" "$(over)" "1"
git -C "$T/r" checkout -q pre.txt
exit "$fail"
