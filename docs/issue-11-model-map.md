結論：H3 — 請求確實送出 gemini-3.5-flash，3.6 是 Google 上游錯誤訊息自己寫的；官方文件未查證，屬間接證據

issue：royalskynet/orchestrator #11 剩下的疑問「請求 gemini-3.5-flash，429 卻報 gemini-3.6-flash」。
查證：2026-10-27，只讀本機 log 與 opencode 模型清冊，未打 Google API。

## H1 dcq／dc 或 opencode 把 3.5 改寫成 3.6 — 排除

- `~/.dcq/logs/1793034162-41396-graphify-version.google_gemini-3.5-flash.out:3`：`> build · gemini-3.5-flash`
- 同檔第 5 行 opencode 的錯誤紀錄：`providerID=google modelID=gemini-3.5-flash … error.error="AI_APICallError`，送出去的 modelID 就是 3.5。
- `~/.cache/opencode/models.json` 的 google 段：`gemini-3.5-flash -> id gemini-3.5-flash（Gemini 3.5 Flash，2026-05-19）`、`gemini-3.6-flash -> id gemini-3.6-flash（2026-07-21）`，兩者一對一，沒有別名。
- `catalog/models.tsv:54-55` 兩列各自獨立，dc_id 與模型名相同。

## H2 錯誤其實來自同一單先試的 3.6 — 排除

- dcq 每隻模型一個 .out（檔名帶模型名）。上述 3.5 的 .out 裡唯一一句額度錯誤是 `free_tier_requests, limit: 20, model: gemini-3.6-flash`，緊接在 `modelID=gemini-3.5-flash` 的 stream error 之後，不是別的嘗試寫進來的。
- `grep -l free_tier_requests ~/.dcq/logs/*gemini-3.5-flash*.out` 只命中這一檔。

## H3 Google 上游把 3.5 的額度記在 3.6 名下 — 成立（間接）

- 請求 modelID＝3.5，錯誤 metric 的 model 標籤＝3.6，中間只有 Google API。合理解釋是上游把 gemini-3.5-flash 路由到 3.6，或兩者共用同一個免費層額度桶。
- 未查證：Google 官方 models／rate limits 頁有沒有寫這個對應。樣本只有 1 筆。

## 建議

- 先不改 dcq 程式：dcq 已依錯誤文字把該隻冷卻到太平洋時間午夜（bin/dcq:459-470），就算兩者共用額度，最多多浪費一次嘗試。
- catalog/models.tsv 的 gemini-3.5-flash 那列備註補一句「429 可能記在 3.6 名下，疑共用額度（#11）」；之後再撞到第 2 筆就改成兩隻一起冷卻。
