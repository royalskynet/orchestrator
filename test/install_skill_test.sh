#!/usr/bin/env bash
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${INSTALL_SH:-$REPO/install.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# 前置
mkdir -p "$T/.claude/skills/o" "$T/.agents/skills"
ln -s /nonexistent "$T/.agents/skills/dc"

# 截段
sed -n '/skill 安裝到各 agent 客戶端/,/^done$/p' "$SRC" > "$T/seg.sh"
if [ ! -s "$T/seg.sh" ]; then
  echo "install_skill_test: FAIL"
  exit 1
fi

# 執行函式（連跑兩次，測冪等）
run_seg() {
  HOME="$T" REPO="$T/repo" bash -c 'set -euo pipefail; mkdir -p "$REPO/skills/o"; '"$(cat "$T/seg.sh")"
}
run_seg || { echo "install_skill_test: FAIL"; exit 1; }
run_seg || { echo "install_skill_test: FAIL"; exit 1; }

# 斷言
fail=0
for c in .claude .agents .codex; do
  got="$(readlink "$T/$c/skills/o" 2>/dev/null || true)"
  [ "$got" = "$T/repo/skills/o" ] || fail=1
done
if [ -e "$T/.agents/skills/dc" ] || [ -L "$T/.agents/skills/dc" ]; then
  fail=1
fi
if ! ls -d "$T/repo/.bak/o-.claude-"* >/dev/null 2>&1; then
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "install_skill_test: PASS"
else
  echo "install_skill_test: FAIL"
  exit 1
fi
