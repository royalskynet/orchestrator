#!/usr/bin/env node
// delegate-guard — SessionEnd（deepclaude-flash#3 併 #1）：session 有 goal 檔就落一筆
// `~/.deepclaude/supervise/state/<sid>.goal`，讓外部 supervise 接手檢查。
//   第一行＝supervise SESS 列 `name|sock|tgt|transcript|verify`。session 已結束沒有 tmux 可催，
//   sock/tgt 寫 '-'；supervise 掃到會直接跑 verify——過→passed 記錄，不過→lost＋推播通知。
//   verify 指到 `state/delegate-guard/verify-<sid>.sh`（本 hook 一併產生）：派工全結清才 PASS。
//   第二行起放 goal 全文，supervise 只讀首行，後面留給查帳的人。
// fail-open：任何例外 exit 0。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { isOff, isMain, safeId, goalFile, STATE_DIR, PLUGIN_ROOT, log } from './lib.mjs';

export const SUPERVISE_STATE = process.env.DEGUARD_SUPERVISE_STATE || path.join(os.homedir(), '.deepclaude/supervise/state');

export function writeSessionGoal(payload) {
  const sid = payload.session_id;
  if (!sid) return null;
  const goal = goalFile(sid);
  if (!fs.existsSync(goal)) return null;
  const name = safeId(sid);
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const verify = path.join(STATE_DIR, `verify-${name}.sh`);
  fs.writeFileSync(verify, `#!/bin/sh\nexec node ${JSON.stringify(path.join(PLUGIN_ROOT, 'scripts/session-verify.mjs'))} ${JSON.stringify(name)}\n`, { mode: 0o755 });
  const tr = typeof payload.transcript_path === 'string' && payload.transcript_path ? payload.transcript_path : '-';
  const goalText = fs.readFileSync(goal, 'utf8').trim();
  const out = path.join(SUPERVISE_STATE, `${name}.goal`);
  fs.mkdirSync(SUPERVISE_STATE, { recursive: true });
  fs.writeFileSync(out, `${name}|-|-|${tr}|${verify}\n${goalText}\n`);
  return out;
}

if (isMain(import.meta.url)) {
  setTimeout(() => process.exit(0), 4500).unref();
  try {
    const payload = JSON.parse(fs.readFileSync(0, 'utf8') || '{}');
    if (isOff() || payload.agent_id || !payload.session_id) process.exit(0);
    const f = writeSessionGoal(payload);
    if (f) log(`session-goal\t${f}`);
  } catch (e) {
    log(`fail-open\tsession-end\t${String(e?.message ?? e).slice(0, 160)}`);
  }
  process.exit(0);
}
