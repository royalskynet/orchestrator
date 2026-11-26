# dispatch-router

## 驗證
改完程式跑這條，全綠才算完成：
```bash
test/run_all.sh
```
（開頭有髒樹守衛：未提交改動會污染結果——issue #39；確認是自己的就 `RUN_ALL_DIRTY_OK=1 test/run_all.sh`）
單跑一個測試：`bash test/dcq_help_test.sh`
