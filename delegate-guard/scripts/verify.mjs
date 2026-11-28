#!/usr/bin/env node
// 主 session 重驗 o 的派工：node scripts/verify.mjs <session_id> <派工 id>
// 跑派工當下快照的驗收（wo-verify --pinned），rc 寫進帳本；印完整輸出，exit＝驗收 rc。
// 75＝還沒完工；64＝帳本沒這筆；3＝驗收被改過。指令由 hook 的提醒給出，照抄即可。
import { runVerify } from '../hooks/ledger.mjs';

const [sid, id] = process.argv.slice(2);
if (!sid || !id) { console.error('用法：verify.mjs <session_id> <派工 id>'); process.exit(64); }
const { rc, out } = runVerify(sid, id);
process.stdout.write(out.endsWith('\n') || !out ? out : `${out}\n`);
console.log(`delegate-guard verify ${id}: rc=${rc}`);
process.exit(rc);
