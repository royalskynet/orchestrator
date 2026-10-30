# 單張 dc

`dc --help` 印檔頭用法；環境變數與分級以本檔為準。

```text
dc <task.md 絕對路徑> [cwd] [--agent <opencode agent>] [-- <opencode run 原生旗標>...]
```

- 未指定模型時用清冊裡第一隻現役 Zen 免費模型（`bin/dc` 的 `DEFAULT_FREE`）；`-- -m <dc_id>` 或 `DC_FREE_MODEL` 指定。`--auto`、`-f`、cd 進 cwd、v1 `--pure`／v2 `--standalone` dc 都自己帶。
- 計費分級不擋：非 free 照派、記 `billing.tsv`、發 TG（`DC_TG_EVERY` 秒最多一則，預設 600）。別家組合名帶 `-free` 不算 free；`kilo/*`、`openrouter/*` 由 `freepool-guard verify` 現場驗價，判不了就拒派（rc=1）。
- 派工前會 `freecheck`：Go 額度窗異常或 Go 免費模型下架 → 寫 `~/.dcq/.ALARM`＋推播，`dc` rc=2、`dcq` 全隊停收單。

## 環境變數

```text
DC_FREE_MODEL=<dc_id>      換預設免費模型
DC_FREE_EXTRA="<id> ..."   補免費白名單（完整 id 不分 provider 都算 free）
DC_FREECHECK=off           關額度閘（確認誤報才用）
DC_FREEPOOL=off            跳過 freepool-guard 驗價
DC_SKIP_LINT=1             跳過 deep-lint
DC_NEGCTL=0                關 do-nothing 負向對照；DC_NEGCTL_TIMEOUT=<s>=120
DC_VERIFY_K=<n>=2          驗收重跑次數，驗收很慢才降成 1
DC_LOCK_WAIT=<s>=0         撞 cwd 鎖時等幾秒
DC_NO_TIMEOUT_WARN=1       關 chunkTimeout WARN
DC_NO_AUTO=1               不帶 --auto（模型會跑不了 bash）
DC_BIN=<dir>               覆寫 wo-verify／deep-lint 所在目錄（測試注入假閘用）
```

## Zen 與 Go：看端點前綴，不看模型名

| 前綴 | 端點 | 呼叫方式 |
|---|---|---|
| 無前綴（Zen，CLI 掛在 `opencode/`） | `opencode.ai/zen/v1` | 只准 `opencode run`／`dc`／`dcq` |
| `opencode-go/…`（含 `*-free`） | `opencode.ai/zen/go/v1` | API 可通，但 dc／dcq 一律走 `opencode run` |

同一個裸名（如 `minimax-m3.1-flash-free`）可能 Zen 和 Go 都有，先判前綴。Go 的 HTTP lane 只給推理、不能改檔，細節見 repo `README.md`。
