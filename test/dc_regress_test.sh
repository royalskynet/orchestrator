#!/usr/bin/env bash
# #21：dc 的 `regress: <指令>`（基準綠→完工紅＝REGRESSION，rc=4）自檢；用假 opencode，不打上游。
#   1) 有回歸 → rc=4、stderr 含 REGRESSION 與測試名
#   2) 基準本來就紅 → 不判
#   3) 完工新增的測試 → 不判
#   4) 沒寫 regress: → rc=0
#   5) 基準沒有 `<rc> <測試名>` 行 → 工單契約錯 rc=2
#   6) DC_PREFLIGHT_DIR 已有的基準沿用（不重拍）
set -u
. "$(dirname "$0")/env.sh"
OC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"
T="$(cd "$T" && pwd -P)"; export T   # regress 指令在 dc 的 bash -c 裡跑，要讀得到 $T
mkdir -p "$T/bin" "$T/cfg/opencode" "$T/r" "$T/pf"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0 DC_VERIFY_K=1 DC_PREFLIGHT_DIR="$T/pf"
unset DC_LOCK_HELD
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/wo-verify"
chmod +x "$T/bin/"*
# 假 opencode 照 MUT（0=綠 1=紅 2=消失 3=新增）改測試檔輸出（展開 $T 時不展開 MUT）
cat > "$T/bin/opencode" <<EOS
#!/usr/bin/env bash
case "\${MUT:-0}" in
  1) echo 1 > "$T/r/t1.out" ;;
  2) rm -f "$T/r/t1.out" ;;
  3) echo 0 > "$T/r/t3.out" ;;
esac
exit 0
EOS
chmod +x "$T/bin/opencode"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
REG='printf "%s %s\n" "$(cat "$T/r/t1.out" 2>/dev/null || echo 1)" t1; printf "%s %s\n" "$(cat "$T/r/t2.out" 2>/dev/null || echo 0)" t2'
run() { # $1=regress 行（空=不寫） $2=MUT
  printf '# t\n%s\n' "$1" > "$T/t.md"
  echo 1 > "$T/r/t2.out"; echo 0 > "$T/r/t1.out"; rm -f "$T/r/t3.out"
  rm -rf "$T/pf"; mkdir -p "$T/pf"
  export MUT="$2"; MUT="$2" "$OC" "$T/t.md" "$T/r" >"$T/o" 2>&1; echo $? > "$T/rc"
}
run "regress: $REG" 1
chk "回歸 → rc=4" "$(cat "$T/rc")" "4"
chk "回歸 → 印 REGRESSION 與測試名" "$(grep -c '^dc: REGRESSION：t1$' "$T/o" | tr -d ' ')" "1"
chk "回歸不列基準就紅的 t2" "$(grep -c 't2' "$T/o" | tr -d ' ')" "0"
run "regress: $REG" 0
chk "全綠 → rc=0" "$(cat "$T/rc")" "0"
run "Regress：$REG" 1   # 大小寫與全形冒號
chk "大小寫不拘、全形冒號也收 → rc=4" "$(cat "$T/rc")" "4"
run "regress: $REG" 2
chk "完工沒有這個測試名 → rc=4" "$(cat "$T/rc")" "4"
run "regress: $REG" 3
chk "完工新增的測試 → 不判（rc=0）" "$(cat "$T/rc")" "0"
run "" 1
chk "沒寫 regress: → rc=0" "$(cat "$T/rc")" "0"
run "regress: echo hello" 1
chk "基準沒有可解析的行 → rc=2" "$(cat "$T/rc")" "2"
chk "基準沒有可解析的行 → 有說明" "$(grep -c 'regress 指令沒有輸出' "$T/o" | tr -d ' ')" "1"
# 6) 基準沿用：DC_PREFLIGHT_DIR 已有 pin ＋ regress.base → 不重拍（指令不可能輸出 t9，重拍就變契約錯 rc=2）
run "regress: $REG" 0
echo x > "$T/pf/pin"; printf '0 t1\n1 t2\n' > "$T/pf/regress.base"
MUT=0 "$OC" "$T/t.md" "$T/r" >"$T/o" 2>&1; echo $? > "$T/rc"
chk "沿用既有基準 → 不重拍、rc=0" "$(cat "$T/rc")" "0"
chk "沿用時印沿用" "$(grep -c '沿用 regress 基準' "$T/o" | tr -d ' ')" "1"
exit "$fail"
