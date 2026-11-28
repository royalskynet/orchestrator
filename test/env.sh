# 每支測試開頭 source：和呼叫端環境隔離（issue #13）。
# 在 dcq 派的工單裡跑測試時，worker 帶著 DC_FREE_MODEL 等變數，會蓋掉測試預設的模型；
# 讀真的 ~/.config/opencode/opencode.json 則隨機器設定漂移（10-24 M2 那份只剩 $schema）。
for _v in $(compgen -e | grep -E '^(DC|DCQ|JEV|OPENCODE)_'); do unset "$_v"; done; unset _v
export XDG_CONFIG_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/xdg-empty"
_xdg_data="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-router-test-xdg.XXXXXX")" || exit 1
export XDG_DATA_HOME="$_xdg_data"; unset _xdg_data  # auth.json/opencode.db 隔離到可寫暫存：不得讀真 key，也不准寫進 fixture
export DC_OC_V2=0  # 假 opencode 不認 run --help，跳過旗標偵測
export DC_FREECHECK=off  # 測試不得 fallback 讀真 Go/Zen key；要測 freecheck 的單案自己設 on＋fake key
# issue #22：測試一律不自動起 runner、不碰正式 socket -L dcq；要測自動啟動的（dcq_autostart_test 等）
# 自己 source 後設回 DCQ_AUTOSTART=1／自己的 DCQ_TMUX。
export DCQ_AUTOSTART=0 DCQ_TMUX="dcqtest$$"
