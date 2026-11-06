#!/usr/bin/env bash
# 2026-11-06：清冊 status=disabled 的模型不得進免費層（opencode/ 免費項 120s 全超時，先停用不刪）。
# 也驗每日 Zen 同步（probe.tsv）把它們加回來時會被 drop_disabled 擋掉。
set -u
. "$(dirname "$0")/env.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export DCQ_HOME="$T/q"; mkdir -p "$DCQ_HOME/logs" "$T/catalog"
printf '%s\t%s\t%s\t%s\n' "$(date +%F_%T)" opencode opencode/off-free OK > "$DCQ_HOME/logs/probe.tsv"
printf 'free\topencode-run\topencode/off-free\tdisabled\tall-timeout\tstop\toff-free\tany\n' > "$T/catalog/models.tsv"
printf 'free\topencode-run\topencode/on-free\tok\tok\t\ton-free\tany\n' >> "$T/catalog/models.tsv"
printf 'sub\topencode-run\topencode-go/sub1\tok\tsub\t\t\topencode-go/sub1\tany\n' >> "$T/catalog/models.tsv"
printf '# t\n- 來源：test\n\n## 驗收\n\n```bash\ntrue\n```\n' > "$T/task.md"
out="$(DCQ_CATALOG="$T/catalog" DCQ_ORDER=default DCQ_AUTORANK=0 dcq plan "$T/task.md" 2>&1)"
free="$(printf '%s\n' "$out" | sed -n 's/^  1 免費 opencode：//p')"
fail=0
case " $free " in *" off-free "*) echo "FAIL disabled 進了免費第一層：$free"; fail=1 ;; esac
case " $free " in *" on-free "*) ;; *) echo "FAIL 可用模型不在第一層：$free"; fail=1 ;; esac
case "$out" in *off-free*) echo "FAIL disabled 仍出現在 plan：$out"; fail=1 ;; esac
[ "$fail" = 0 ] && echo "PASS free_layer"
exit "$fail"
