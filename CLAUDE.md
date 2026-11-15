# dispatch-router

## 驗證
改完程式跑這條，全綠才算完成：
```bash
fail=0; for f in test/*_test.sh; do bash "$f" >/dev/null 2>&1 || { echo "FAIL $f"; fail=1; }; done; [ "$fail" = 0 ]
```
單跑一個測試：`bash test/dcq_help_test.sh`
