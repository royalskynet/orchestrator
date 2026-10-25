#!/usr/bin/env bash
# dc 越界偵測自檢：用假 opencode，不打上游。
# 為什麼要有：2026-10-08 派工到 worktree，模型照工單絕對路徑寫進主 checkout，
# 3 個 commit 落在 main 而 dc 回報正常。斷言三件：
#   1) 改到主 checkout → rc=2 且印出越界路徑
#   2) 只改自己的 worktree → rc=0
#   3) 被別的 dc 持鎖的 sibling 有變化 → 不算越界（併發派工本來就會改它）
#   4) I3a（10-23）：主 checkout 被 dcq 的 sibling merge 前進（新 commit 全是 committer=dcq）→ 不算越界；
#      模型自己 commit（committer 不是 dcq）或動工作樹 → 仍判越界。10-22 批次 R7／R10／R11 因此誤判 FATAL
set -u
. "$(dirname "$0")/env.sh"
OC="$(cd "$(dirname "$0")/.." && pwd)/bin/dc"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json"   # 不讀真的全域閘（10-19：Jev 閘封鎖時這些測試全掛）
T="$(cd "$T" && pwd -P)"   # macOS /var → /private/var，要和 git worktree list 印的一致
mkdir -p "$T/bin" "$T/cfg/opencode"
export DC_BIN="$T/bin" PATH="$T/bin:$PATH" DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg"
# DC_NEGCTL=0：這些測試的 wo-verify 是 `exit 0` 的假貨，do-nothing 對照會當場中止派工。
# 負向對照本身由 dc_verify_gate_test.sh 驗。
export DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0
unset DC_LOCK_HELD

git init -q "$T/main"
git -C "$T/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$T/main" worktree add -q "$T/wt" -b wo/x

# 假 opencode：往 $FAKE_TARGET 寫一個檔
cat > "$T/bin/opencode" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_TARGET:-}" ] && echo x > "$FAKE_TARGET"
[ -n "${FAKE_COMMIT_AS:-}" ] && git -C "$FAKE_COMMIT_REPO" -c user.email=t@t -c user.name="$FAKE_COMMIT_AS" commit -q --allow-empty -m sib
exit 0
EOF
chmod +x "$T/bin/opencode"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; chmod +x "$T/bin/$g"; done
printf '# t\n' > "$T/t.md"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

FAKE_TARGET="$T/main/stray.txt" "$OC" "$T/t.md" "$T/wt" >"$T/o1" 2>&1; rc=$?
chk "寫到主 checkout rc=2" "$rc" "2"
grep -q "越界.*" "$T/o1" && grep -q "$T/main" "$T/o1" || { echo "FAIL 沒印越界路徑"; cat "$T/o1"; fail=1; }
rm -f "$T/main/stray.txt"

FAKE_TARGET="$T/wt/ok.txt" "$OC" "$T/t.md" "$T/wt" >"$T/o2" 2>&1; rc=$?
chk "只改自己 worktree rc=0" "$rc" "0"

mkdir -p "$DCQ_HOME/.cwdlock/$(printf '%s' "$T/main" | shasum | cut -c1-12)"
echo $$ > "$DCQ_HOME/.cwdlock/$(printf '%s' "$T/main" | shasum | cut -c1-12)/pid"
FAKE_TARGET="$T/main/locked.txt" "$OC" "$T/t.md" "$T/wt" >"$T/o3" 2>&1; rc=$?
chk "持鎖 sibling 變化不算越界 rc=0" "$rc" "0"

# 4) 主 checkout HEAD 被 dcq 的 sibling 前進（未持鎖）→ rc=0；同樣動作但 committer 不是 dcq → rc=2
rmdir "$DCQ_HOME/.cwdlock/$(printf '%s' "$T/main" | shasum | cut -c1-12)" 2>/dev/null || rm -rf "$DCQ_HOME/.cwdlock/$(printf '%s' "$T/main" | shasum | cut -c1-12)"
FAKE_COMMIT_REPO="$T/main" FAKE_COMMIT_AS=dcq "$OC" "$T/t.md" "$T/wt" >"$T/o4" 2>&1; rc=$?
chk "sibling(dcq) merge 讓主 checkout 前進不算越界 rc=0" "$rc" "0"
FAKE_COMMIT_REPO="$T/main" FAKE_COMMIT_AS=model "$OC" "$T/t.md" "$T/wt" >"$T/o5" 2>&1; rc=$?
chk "非 dcq 的 commit 進主 checkout 仍判越界 rc=2" "$rc" "2"

exit "$fail"
