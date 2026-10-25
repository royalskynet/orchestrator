# 每支測試開頭 source：和呼叫端環境隔離（issue #13）。
# 在 dcq 派的工單裡跑測試時，worker 帶著 DC_FREE_MODEL 等變數，會蓋掉測試預設的模型；
# 讀真的 ~/.config/opencode/opencode.json 則隨機器設定漂移（10-24 M2 那份只剩 $schema）。
for _v in $(compgen -e | grep -E '^(DC|DCQ|JEV|OPENCODE)_'); do unset "$_v"; done; unset _v
export XDG_CONFIG_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/xdg-empty"
export DC_OC_V2=0  # 假 opencode 不認 run --help，跳過旗標偵測
