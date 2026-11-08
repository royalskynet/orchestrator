#!/usr/bin/env bash
# 假 Codex 驗參數、事件映射與 dc 共用判定鏈；不打模型或網路。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
mkdir -p "$T/bin" "$T/w"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_HOME="$T/q"
export DC_ZEN_GATE="$T/zen" JEV_ZEN_STATUS_FILE="$T/jev.json"
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_VERIFY_K=1 DC_PUSH=0
export CODEX_BIN="$T/bin/fake-codex" ARGS="$T/args"
unset DC_LOCK_HELD
printf '#!/bin/sh\nexit 0\n' > "$T/bin/deep-lint"
cat > "$CODEX_BIN" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGS"
# stdin 必須已封閉，避免接走 dc 的輸入。
if read -r line; then exit 99; fi
case "${FAKE:-ok}" in
  err) echo '{"type":"turn.failed","error":{"message":"failed fixture"}}' ;;
  error) echo '{"type":"error","message":"error fixture"}' ;;
  quota) echo '{"type":"turn.failed","error":{"message":"You\u0027ve hit your usage limit"}}' ;;
  rc) exit 7 ;;
  probe) if cat "$HOME/.claude/projects/probe" >/dev/null 2>&1; then echo leak > done; else echo done > done; fi ;;
  *) echo done > done
     echo '{"type":"item.started","item":{"type":"command_execution","command":"echo done"}}'
     echo '{"type":"item.completed","item":{"type":"agent_message","text":"完成"}}' ;;
esac
EOS
ln -s "$R/bin/wo-verify" "$T/bin/wo-verify"
chmod +x "$T/bin/"*
cat > "$T/t.md" <<'EOS'
# task
writes: done
## 驗收
```bash
test "$(cat done)" = done
```
EOS
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
CE="$R/bin/codex-exec"
cd "$T/w"
out="$("$CE" 做事 -f "$T/t.md" -m codex/default --title x --pure)"; rc=$?
chk 'default 成功' "$rc" 0
chk 'START 行' "$(printf '%s\n' "$out" | head -1)" '> build · codex/default'
chk 'agent 文字' "$(printf '%s\n' "$out" | grep -cx 完成)" 1
chk 'command 文字' "$(printf '%s\n' "$out" | grep -cx '→ echo done')" 1
chk 'default 不帶 -m' "$(grep -cx -- -m "$ARGS")" 0
for arg in exec --json --skip-git-repo-check -C danger-full-access; do
  chk "參數 $arg" "$(grep -cx -- "$arg" "$ARGS")" 1
done
chk 'cwd' "$(grep -cx "$PWD" "$ARGS")" 1
chk '忽略 opencode 旗標' "$(grep -cx -- --pure "$ARGS")" 0
chk 'prompt 含任務' "$(grep -c "任務檔：$T/t.md" "$ARGS")" 1
if [ -r "$R/executor-rules.md" ]; then
  chk '規則前置' "$(python3 - "$ARGS" "$R/executor-rules.md" <<'PY'
import pathlib,sys
args=pathlib.Path(sys.argv[1]).read_text()
rules=pathlib.Path(sys.argv[2]).read_text().rstrip('\n')
print(int(args.split('danger-full-access\n',1)[1].startswith(rules+'\n\n做事')))
PY
)" 1
fi
CODEX_EXEC_SANDBOX=read-only "$CE" 做事 -f "$T/t.md" -m codex/gpt-x >/dev/null
chk '指定模型' "$(grep -A1 -x -- -m "$ARGS" | tail -1)" gpt-x
chk 'sandbox 可指定' "$(grep -A1 -x -- --sandbox "$ARGS" | tail -1)" read-only
for mode in err error quota; do
  out="$(FAKE=$mode "$CE" 做事 -f "$T/t.md" -m codex/default)"; rc=$?
  chk "$mode rc=0 錯誤事件判失敗" "$rc" 1
  chk "$mode Error 映射" "$(printf '%s\n' "$out" | grep -c '^Error: codex-exec: ')" 1
  if [ "$mode" = quota ]; then
    QRE="$(sed -n "s/^QUOTA_RE='\(.*\)'$/\1/p" "$R/bin/dc")"
    chk '額度字串匹配 QUOTA_RE' "$(printf '%s\n' "$out" | grep -Ec "$QRE")" 1
  fi
done
FAKE=rc "$CE" 做事 -f "$T/t.md" -m codex/default >/dev/null; chk '保留上游 rc' "$?" 7
"$CE" 做事 -f "$T/t.md" -m claude/x >/dev/null 2>&1; chk '非 codex 拒絕' "$?" 2
rm -f done
DC_MODEL=codex/default "$R/bin/dc" "$T/t.md" "$T/w" > "$T/dc.out" 2>&1; rc=$?
[ "$rc" = 0 ] || cat "$T/dc.out"
chk 'dc 真正驗收產物' "$rc" 0
chk 'dc 呼叫 codex' "$(grep -c '^> build · codex/default' "$T/dc.out")" 1
chk '產物存在' "$(cat done 2>/dev/null)" done
chk 'tier sub 落帳' "$(awk -F '\t' '$2=="sub" && $3=="codex/default" {n++} END {print n+0}' "$T/q/logs/billing.tsv")" 1
# 既有單模型旗標仍可使用；負向對照需要尚未完成的產物。
rm -f done
"$R/bin/dc" "$T/t.md" "$T/w" -- -m codex/gpt-x > "$T/dc.out" 2>&1
chk 'dc -m 指定模型' "$?" 0
chk 'dc 傳模型' "$(grep -A1 -x -- -m "$ARGS" | tail -1)" gpt-x
# codex 自身沙箱關掉（.git 要能 commit），對話紀錄與憑證改由 dc 外層 sandbox-exec 擋。
if command -v sandbox-exec >/dev/null; then
  mkdir -p "$T/home/.claude/projects"; echo x > "$T/home/.claude/projects/probe"; rm -f done
  HOME="$T/home" FAKE=probe DC_MODEL=codex/default "$R/bin/dc" "$T/t.md" "$T/w" > "$T/dc.out" 2>&1
  chk 'dc 外層沙箱擋 codex 讀對話紀錄' "$(cat done 2>/dev/null)" done
fi
exit "$fail"
