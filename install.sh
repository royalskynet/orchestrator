#!/usr/bin/env bash
# 把 Orchestrator 裝到使用者路徑。無 admin 需求，全部 user-level。
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"

mkdir -p ~/.local/bin ~/.claude/skills

ln -sfn "$REPO/bin/dc" ~/.local/bin/dc
ln -sfn "$REPO/bin/dcq" ~/.local/bin/dcq
ln -sfn "$REPO/bin/zen-gate" ~/.local/bin/zen-gate
# PATH 上的 wo-verify 也由本 repo 提供（手動驗收、其他腳本用）；dc 自己不走 PATH
ln -sfn "$REPO/bin/wo-verify" ~/.local/bin/wo-verify
# freepool-guard（freepool 層的守門與補貨）：免費模型雷達（讀上游價格目錄判零價）。dc 自己走 bin/ 同目錄那份，這個連結給手動 scan／guard 用
ln -sfn "$REPO/bin/freepool-guard" ~/.local/bin/freepool-guard
# 週探測（oc-free-check／go-sync／launchd）是選配，在 oc-probe/，由 oc-probe/install.sh 裝；
# dcq rank 照讀 ~/.dcq/logs/probe.tsv，沒裝就沒有探測資料。

# ~/.claude/skills/o：若已是實體目錄（非 symlink），先備份進 repo 再連結
if [ -d ~/.claude/skills/o ] && [ ! -L ~/.claude/skills/o ]; then
  mkdir -p "$REPO/.bak"
  mv ~/.claude/skills/o "$REPO/.bak/o-$(date +%Y%m%d-%H%M%S)"
fi
ln -sfn "$REPO/skills/o" ~/.claude/skills/o
[ -L ~/.claude/skills/dc ] && rm ~/.claude/skills/dc  # 10-16 前舊名

echo "Installed symlinks:"
for t in ~/.local/bin/dc ~/.local/bin/dcq ~/.local/bin/zen-gate ~/.local/bin/wo-verify ~/.local/bin/freepool-guard ~/.claude/skills/o; do
  ls -l "$t"
  [ -e "$t" ] || { echo "DANGLING: $t"; exit 1; }
done

echo
# wo-verify／deep-lint 已收進 bin/，dc 直接用同目錄那份，不依賴 deepclaude／deep-agent。
for g in wo-verify deep-lint; do
  [ -x "$REPO/bin/$g" ] || { echo "MISSING: $REPO/bin/$g"; exit 1; }
done
echo "  wo-verify／deep-lint：repo 自帶（bin/）"
