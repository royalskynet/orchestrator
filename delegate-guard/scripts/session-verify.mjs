#!/usr/bin/env node
// delegate-guard — supervise .goal 的驗收腳本：這個 session 的派工帳本全結清才 PASS。
// 結清＝每筆 pending 已完工（isTerminal）＋主 session 重驗 rc=0＋未作廢（!stale）；沒有派工直接 PASS。
// 只看帳本紀錄不重跑驗收（重驗是主 session 的 `scripts/verify.mjs`）。
// 用法：node session-verify.mjs <sid>（supervise 以 `bash verify-<sid>.sh` 呼叫，末行要剛好是 PASS）
import { readLedger, isTerminal } from '../hooks/ledger.mjs';

const sid = process.argv[2] ?? '';
const l = readLedger(sid);
const bad = l.pending.filter((p) => !isTerminal(p) || p.stale || p.verified?.rc !== 0);
if (bad.length) {
  console.log(`${bad.length}/${l.pending.length} 筆派工未結清：`);
  for (const p of bad) {
    const v = p.verified ? `rc=${p.verified.rc}${p.stale ? ' stale' : ''}` : '未重驗';
    console.log(`- ${p.id} ${p.status}${p.jobId ? ` job=${p.jobId}` : ''} ${v}`);
  }
  console.log('FAIL');
  process.exit(1);
}
console.log(`${l.pending.length} 筆派工全結清`);
console.log('PASS');
