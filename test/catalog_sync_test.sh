#!/usr/bin/env bash
# catalog-sync 回寫清冊＋dc 預設模型跟清冊走的自檢。只動暫存目錄，不碰真清冊、不打上游。
set -u
. "$(dirname "$0")/env.sh"
R="$(cd "$(dirname "$0")/.." && pwd)"
CS="$R/bin/catalog-sync" DC="$R/bin/dc"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
chk() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
row() { awk -F'\t' -v m="$2" '!/^#/ && $3==m { print $4 "|" $7 }' "$1" | tr '\n' ' ' | sed 's/ $//'; }
pos() { awk -F'\t' -v d="$2" '!/^#/ && $7!="" { n++; if ($7==d) print n }' "$1"; }

seed() {  # $1=路徑
  printf '%s\n' '# 欄位：billing route model status evidence note dc_id fit' > "$1"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    free opencode-run opencode/zen-a-free gated x 'Zen 免費' zen-a-free any \
    free opencode-run opencode-go/go-a-free ok x 'Go 免費' opencode-go/go-a-free any \
    free opencode-run opencode-go/go-b-free ok x 'Go 免費' opencode-go/go-b-free any \
    free opencode-run opencode-go/old-free removed x 'Go 免費' '' any \
    free omniroute omniroute/nim-pool ok x NIM omniroute/nim-pool any \
    sub opencode-run opencode-go/s1 ok x 'Go 訂閱' opencode-go/s1 any \
    sub omniroute opencode-go/s-rec ok x 'Go 訂閱紀錄' '' any >> "$1"
}

# 1. 移出＋新增排位＋恢復＋紀錄列不被恢復
seed "$T/a.tsv"
SYNC_RM="opencode-go/go-b-free" SYNC_ADD_GOFREE="opencode-go/go-c-free opencode-go/old-free" \
SYNC_ADD_SUB="opencode-go/s-rec" SYNC_ADD_ZEN="zen-b-free" python3 "$CS" "$T/a.tsv" --no-commit >/dev/null
chk "移出：removed 且 dc_id 清空"          "$(row "$T/a.tsv" opencode-go/go-b-free)" "removed|"
chk "新增 Go 免費排在 opencode-go 段尾、nim-pool 前" \
  "$(pos "$T/a.tsv" opencode-go/go-c-free)<$(pos "$T/a.tsv" omniroute/nim-pool)" "4<6"
chk "removed 列原地恢復"                   "$(row "$T/a.tsv" opencode-go/old-free)" "ok|opencode-go/old-free"
chk "omniroute 紀錄列不被當成恢復"         "$(row "$T/a.tsv" opencode-go/s-rec | tr ' ' '\n' | sort | tr '\n' ' ')" "ok| ok|opencode-go/s-rec "
chk "Zen 新增排在 Zen 段尾"                "$(pos "$T/a.tsv" zen-b-free)" "2"

# 2. 沒有變動就不改檔
seed "$T/b.tsv"; cp "$T/b.tsv" "$T/b0"
python3 "$CS" "$T/b.tsv" >/dev/null
chk "無變動不改檔" "$(cmp -s "$T/b.tsv" "$T/b0" && echo same || echo changed)" same

# 3. git：乾淨才 commit；有未提交改動只寫檔
G="$T/g"; mkdir -p "$G/catalog"; git -C "$G" init -q
git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
seed "$G/catalog/models.tsv"; git -C "$G" add -A; git -C "$G" -c user.email=t@t -c user.name=t commit -q -m seed
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  SYNC_RM="opencode-go/go-a-free" python3 "$CS" "$G/catalog/models.tsv" --source test >/dev/null
chk "乾淨清冊自動 commit" "$(git -C "$G" log -1 --format=%s | grep -c '自動同步（test）')" 1
echo '# 手改' >> "$G/catalog/models.tsv"
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  SYNC_RM="opencode-go/s1" python3 "$CS" "$G/catalog/models.tsv" >/dev/null 2>&1
chk "有手改不 commit、仍寫檔" "$(git -C "$G" log --oneline | wc -l | tr -d ' '):$(row "$G/catalog/models.tsv" opencode-go/s1)" "3:removed|"

# 4. dc：預設模型不在清冊 Zen 現役名單 → 用清冊第一隻；在名單 → 不動
mkdir -p "$T/bin" "$T/w" "$T/cfg/opencode"
export DC_ZEN_GATE="$T/zen-gate" JEV_ZEN_STATUS_FILE="$T/jev-zen.json" DC_BIN="$T/bin" PATH="$T/bin:$PATH" \
  DCQ_HOME="$T/q" XDG_CONFIG_HOME="$T/cfg" DC_TG_EVERY=0 DC_FREECHECK=off DC_NO_TIMEOUT_WARN=1 DC_NEGCTL=0 \
  OMNIROUTE_API_KEY=fake OPENCODE_API_KEY=fake TRACE="$T/trace"
cat > "$T/bin/opencode" <<'X'
#!/usr/bin/env bash
[ "$1" = debug ] && { echo '{}'; exit 0; }
m=""; prev=""; for a in "$@"; do [ "$prev" = "-m" ] && m="$a"; prev="$a"; done
echo "RUN $m" >> "$TRACE"
X
printf '#!/bin/sh\nexit 0\n' > "$T/bin/hpush"
for g in deep-lint wo-verify; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$g"; done
chmod +x "$T/bin"/*; printf '# t\n' > "$T/t.md"
dcrun() { : > "$T/trace"; DC_CATALOG="$1" "$DC" "$T/t.md" "$T/w" >/dev/null 2>&1; sed -n 's/^RUN //p' "$T/trace" | head -1; }
seed "$T/c.tsv"
chk "dc 預設已下架 → 清冊第一隻 Zen" "$(dcrun "$T/c.tsv")" "opencode/zen-a-free"
DEF="$(sed -n 's/^DEFAULT_FREE="\([^"]*\)".*/\1/p' "$DC")"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' free opencode-run "opencode/$DEF" ok x Zen "$DEF" any >> "$T/c.tsv"
chk "dc 預設仍在清冊 → 不動" "$(dcrun "$T/c.tsv")" "opencode/$DEF"

exit $fail
