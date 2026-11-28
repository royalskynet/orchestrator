#!/usr/bin/env node
// 回放：把最近 N 個主 session transcript 切成「一則使用者訊息→下一則」的段，逐個 tool_use 餵 onPreTool（S1／S2／S3／S5 與放行條件），
// 成功的 Read（tool_result 非 error）餵 onPostTool 記即時上下文；o-worker／dcq add 視為派出（回放沒有 PostToolUse，ponytail：不分辨派工失敗）。
// 驗收（DESIGN-v0.2.md）：改派段數 ≤20%，且改派段佔計費輸入 ≥50%。不達標 exit 1。
// 用法：node scripts/replay.mjs [N=60]
// ponytail: S4（大輸出）與 S6 的 Laya 平手裁判不回放——前者只建議不擋，後者要打網路；只影響建議派，不影響改派統計。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { newState, onPrompt, onPreTool, onPostTool, onDispatched, scoreTask, usageTokens, S6_HIT } from '../hooks/lib.mjs';

const N = Number(process.argv[2] || 60);
const root = path.join(os.homedir(), '.claude/projects');
const files = fs.readdirSync(root).flatMap((d) => {
  try { return fs.readdirSync(path.join(root, d)).filter((f) => f.endsWith('.jsonl')).map((f) => path.join(root, d, f)); } catch { return []; }
}).map((f) => ({ f, m: fs.statSync(f).mtimeMs })).sort((a, b) => b.m - a.m).map((x) => x.f);

const isHumanTurn = (e) => e.type === 'user' && !e.isMeta && !e.isSidechain && (typeof e.message?.content === 'string'
  || (Array.isArray(e.message?.content) && e.message.content.some((c) => c?.type === 'text') && !e.message.content.some((c) => c?.type === 'tool_result')));
// task-notification、local-command 輸出、中斷訊息不觸發 UserPromptSubmit，不開新段
const NOT_PROMPT = /^\s*(?:<task-notification|<local-command|Caveat:|\[Request interrupted)/;
const textOf = (e) => typeof e.message.content === 'string' ? e.message.content : e.message.content.filter((c) => c?.type === 'text').map((c) => c.text).join('\n');

const segs = [];
let used = 0;
for (const f of files) {
  if (used >= N) break;
  let lines; try { lines = fs.readFileSync(f, 'utf8').split('\n'); } catch { continue; }
  let st = newState(), cur = null, any = false;
  const seen = new Set(), reads = new Map();
  for (const line of lines) {
    let e; try { e = JSON.parse(line); } catch { continue; }
    if (isHumanTurn(e) && !NOT_PROMPT.test(textOf(e))) {
      if (cur) segs.push(cur);
      const p = textOf(e);
      st = onPrompt(st, p);
      st.s6 = scoreTask(p).score >= S6_HIT;
      cur = { calls: 0, billed: 0, reroute: '', cls: '' };
      continue;
    }
    if (cur && e.type === 'user' && !e.isSidechain && Array.isArray(e.message?.content)) {
      for (const c of e.message.content) {
        if (c?.type === 'tool_result' && !c.is_error && reads.has(c.tool_use_id)) st = onPostTool(st, { tool: 'Read', input: reads.get(c.tool_use_id) }).st;
      }
      continue;
    }
    if (!cur || e.type !== 'assistant' || e.isSidechain) continue;
    const u = e.message?.usage;
    const ctx = u ? usageTokens(u) : null;
    if (u && !seen.has(e.message.id)) { seen.add(e.message.id); cur.billed += ctx; }
    for (const c of e.message?.content ?? []) {
      if (c?.type !== 'tool_use') continue;
      any = true; cur.calls++;
      const r = onPreTool(st, { tool: c.name, input: c.input ?? {}, ctx, cwd: e.cwd ?? '' });
      st = r.st;
      if (c.name === 'Read') reads.set(c.id, c.input ?? {});
      if (c.input?.subagent_type === 'o-worker' || /\bdcq\s+add\b/.test(c.input?.command ?? '')) st = onDispatched(st);
      if (r.action?.kind === 'reroute' && !cur.reroute) { cur.reroute = r.action.via.split(' ')[0]; cur.cls = r.action.cls; }
      if (r.action?.kind === 'note' && !cur.cls) cur.cls = 'none';
    }
  }
  if (cur) segs.push(cur);
  if (any) used++;
}

const total = segs.length, billed = segs.reduce((s, x) => s + x.billed, 0);
const rr = segs.filter((s) => s.reroute), rrBilled = rr.reduce((s, x) => s + x.billed, 0);
const by = {}; for (const s of rr) by[s.reroute] = (by[s.reroute] ?? 0) + 1;
const cls = {}; for (const s of segs) if (s.cls) cls[s.cls] = (cls[s.cls] ?? 0) + 1;
const pctSegs = (100 * rr.length) / Math.max(1, total), pctBilled = (100 * rrBilled) / Math.max(1, billed);
console.log(`transcripts=${used} segments=${total} reroute=${rr.length} (${pctSegs.toFixed(1)}%) by=${JSON.stringify(by)} 三類=${JSON.stringify(cls)}`);
console.log(`billed_input reroute_share=${pctBilled.toFixed(1)}%`);
const nn = segs.filter((s) => s.cls === 'none'), nnBilled = nn.reduce((s, x) => s + x.billed, 0);
console.log(`billed_input none_share=${(100 * nnBilled / Math.max(1, billed)).toFixed(1)}%`);
const ok = pctSegs <= 20 && pctBilled >= 50;
console.log(ok ? 'REPLAY PASS' : 'REPLAY FAIL（標準：改派段 ≤20%，改派段計費輸入 ≥50%）');
process.exit(ok ? 0 : 1);
