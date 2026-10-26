#!/usr/bin/env bash
# freepool 判準自檢：用假快取，FREEPOOL_OFFLINE=1 不連網、不打模型。
# 斷言加白語意：零價放行；現價非零拒派（rc=2）；缺 :free 後綴指出零價 id；沒價格目錄的 provider 回 unknown（rc=3）；
# 清冊有漲價列 guard rc=1；完全沒快取時不得宣告任何模型免費。
set -u
. "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export FREEPOOL_CACHE="$T/freepool.json" FREEPOOL_OFFLINE=1

cat > "$FREEPOOL_CACHE" <<'EOF'
{
  "checked_at": "2999-01-01T00:00:00+00:00",
  "providers": {
    "kilo": {
      "free": {
        "kilo-auto/free": {"tools": true, "context_length": 256000},
        "poolside/laguna-s-2.1:free": {"tools": true, "context_length": 262144},
        "liquid/lfm-2.5-2.6b:free": {"tools": false, "context_length": 65536}
      },
      "paid": ["anthropic/claude-sonnet-4.5", "poolside/laguna-s-2.1"],
      "error": null
    },
    "openrouter": {"free": {}, "paid": ["openai/gpt-5"], "error": null}
  },
  "free_count": 3
}
EOF

fail=0
chk() { # name want_rc args...
  local n="$1" want="$2"; shift 2
  out="$(bin/freepool "$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then echo "PASS $n"; else echo "FAIL ${n}: rc=${rc} 期望 ${want}"; echo "$out" | sed 's/^/    /'; fail=1; fi
}
has() { # name needle output
  case "$3" in *"$2"*) echo "PASS $1" ;; *) echo "FAIL ${1}: 輸出沒有「${2}」"; echo "$3" | sed 's/^/    /'; fail=1 ;; esac
}

chk "零價放行"            0 verify kilo/kilo-auto/free
chk "現價非零拒派"        2 verify kilo/anthropic/claude-sonnet-4.5
chk "沒價格目錄回 unknown" 3 verify nvidia/openai/gpt-oss-20b
chk "多個裡有付費就 rc=2"  2 verify kilo/kilo-auto/free kilo/anthropic/claude-sonnet-4.5

# 缺 :free 後綴：不得當成同一隻放行，要指出零價的是後綴版（照原名打會走付費版）
o="$(bin/freepool verify poolside/laguna-s-2.1 2>&1)" || true
o="$(bin/freepool verify kilo/poolside/laguna-s-2.1 2>&1)" || true
has "缺後綴指出零價 id" "kilo/poolside/laguna-s-2.1:free" "$o"

# pool 只列支援 tools 的（lfm-2.5 的 tools=false 不該出現），--all 才列
o="$(bin/freepool pool 2>/dev/null)"
has "pool 列零價＋tools" "kilo/kilo-auto/free" "$o"
case "$o" in *lfm-2.5*) echo "FAIL pool 不該列不支援 tools 的"; fail=1 ;; *) echo "PASS pool 濾掉不支援 tools 的" ;; esac
has "pool --all 連非 tools 也列" "lfm-2.5" "$(bin/freepool pool --all 2>/dev/null)"

# guard：清冊 billing=free 的列漲價或 id 缺後綴 → rc=1；全零價 → rc=0
cat > "$T/ok.tsv" <<'EOF'
# billing	route	model	status	evidence	note	dc_id	fit
free	opencode-run	kilo/kilo-auto/free	ok	freepool	零價	kilo/kilo-auto/free	any
free	opencode-run	opencode/beam-free	ok	probe	Zen 免費	beam-free	any
EOF
chk "清冊全零價 guard 放行" 0 guard "$T/ok.tsv"
cat > "$T/bad.tsv" <<'EOF'
# billing	route	model	status	evidence	note	dc_id	fit
free	opencode-run	kilo/poolside/laguna-s-2.1	ok	手填	忘了 :free	kilo/poolside/laguna-s-2.1	any
EOF
chk "清冊 id 缺後綴 guard 擋" 1 guard "$T/bad.tsv"
cat > "$T/paid.tsv" <<'EOF'
# billing	route	model	status	evidence	note	dc_id	fit
free	opencode-run	kilo/anthropic/claude-sonnet-4.5	ok	手填	已漲價	kilo/anthropic/claude-sonnet-4.5	any
EOF
chk "清冊列漲價 guard 擋" 1 guard "$T/paid.tsv"

# propose：清冊缺的零價模型要提 ADD，且只提支援 tools 的
o="$(bin/freepool propose "$T/ok.tsv" 2>/dev/null)"
has "propose 提 ADD" "ADD	kilo/poolside/laguna-s-2.1:free" "$o"

# probe：拒探的都要在連 OmniRoute 之前擋下（OMNIROUTE_URL 指向關閉的 port，連了就會變 rc=3）
export OMNIROUTE_URL=http://127.0.0.1:9 OMNIROUTE_ADMIN_PASSWORD=fake
chk "probe 拒探付費 id"     2 probe kilo/anthropic/claude-sonnet-4.5
chk "probe 拒探缺後綴 id"   2 probe kilo/poolside/laguna-s-2.1
chk "probe 拒探非 kilo"     2 probe nvidia/openai/gpt-oss-20b
chk "probe 超過上限拒探"    2 probe kilo/kilo-auto/free kilo/kilo-auto/free kilo/kilo-auto/free kilo/kilo-auto/free kilo/kilo-auto/free kilo/kilo-auto/free
chk "probe OmniRoute 不在回 3" 3 probe kilo/kilo-auto/free
if bin/../oc-probe/bin/oc-free-check -p kilo >/dev/null 2>&1; then echo "FAIL oc-free-check 沒擋 kilo"; fail=1; else echo "PASS oc-free-check 擋 kilo 併發探測"; fi
unset OMNIROUTE_URL OMNIROUTE_ADMIN_PASSWORD

# 沒快取又連不上上游：不得宣告任何模型免費（fail-closed）
rm -f "$FREEPOOL_CACHE"
chk "無快取時 pool 不列模型" 1 pool
o="$(bin/freepool verify kilo/kilo-auto/free 2>&1)" || true
case "$o" in *"	free	"*) echo "FAIL 無快取卻宣告免費"; fail=1 ;; *) echo "PASS 無快取不宣告免費" ;; esac

# dc 的 freepool 閘：付費 id 要在送出請求前就中止（不產生任何 opencode 呼叫）
mkdir -p "$T/bin" "$T/wd"
printf '#!/bin/sh\necho "opencode 不該被呼叫" >> "%s/called"\nexit 0\n' "$T" > "$T/bin/opencode"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/jq-noop"
chmod +x "$T/bin/"*
cat > "$FREEPOOL_CACHE" <<'EOF'
{"checked_at":"2999-01-01T00:00:00+00:00","providers":{"kilo":{"free":{},"paid":["anthropic/claude-sonnet-4.5"],"error":null}},"free_count":0}
EOF
echo "# 任務" > "$T/task.md"
if PATH="$T/bin:$PATH" DC_MODEL=kilo/anthropic/claude-sonnet-4.5 bin/dc "$T/task.md" "$T/wd" >/dev/null 2>&1; then
  echo "FAIL dc 沒擋付費 kilo 模型"; fail=1
else
  echo "PASS dc 擋下付費 kilo 模型"
fi
[ ! -e "$T/called" ] && echo "PASS dc 擋下時沒呼叫 opencode" || { echo "FAIL dc 擋下前已呼叫 opencode"; fail=1; }

exit $fail
