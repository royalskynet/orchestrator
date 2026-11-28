// delegate-guard 派工帳本：派工前驗收閘、派出／完工配對、主 session 重驗紀錄、Stop 提醒。
// 不改 O：只讀 o 的產物（~/.dcq/{pending,running,done,failed}/<id>.job、工單檔），驗收執行沿用 wo-verify --dump／--pinned。
// 配對：Agent＝tool_use_id → tool_response.agentId → SubagentStop.agent_id；dcq＝job 檔 TASK= 對工單路徑。不猜順序。
// 帳本一個 session 一檔，mkdir 鎖＋tmp→rename 原子寫；JSON 損壞就改名保留並標 corrupt，Stop 會明報，不靜默重置。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { STATE_DIR, PLUGIN_ROOT, safeId, sessFile, newState, isReadOnly, isRunnerCmd, redirectTargets, dispatchTargets, targetPath, WRITE_TOOLS, stripQuoted, log } from './lib.mjs';

const HOME = os.homedir();
export const DCQ_HOME = process.env.DEGUARD_DCQ_HOME || path.join(HOME, '.dcq');
const WO_VERIFY = process.env.DEGUARD_WO_VERIFY
  || [path.join(HOME, '.local/bin/wo-verify')].find((f) => fs.existsSync(f)) || 'wo-verify';
const MAX_REMINDERS = 2;
const PROPOSED_TTL_MS = 3600e3;

export const ledgerFile = (sid) => path.join(STATE_DIR, `ledger-${safeId(sid)}.json`);

// —— 鎖＋原子寫 ——
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
export function withLock(file, fn) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const lock = `${file}.lock`;
  for (let i = 0; ; i++) {
    try { fs.mkdirSync(lock); break; } catch {
      try { if (Date.now() - fs.statSync(lock).mtimeMs > 5000) { fs.rmSync(lock, { recursive: true, force: true }); continue; } } catch {}
      if (i >= 200) throw new Error(`lock timeout ${lock}`);
      sleep(10);
    }
  }
  try {
    let data;
    if (fs.existsSync(file)) {
      try { data = JSON.parse(fs.readFileSync(file, 'utf8')); } catch {
        const bad = `${file}.corrupt-${Date.now()}`;
        fs.renameSync(file, bad);
        log(`CORRUPT\t${file} → ${bad}`);
        data = { corrupt: bad };
      }
    }
    const { value, result } = fn(data);
    if (value !== undefined) {
      const tmp = `${file}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(value));
      fs.renameSync(tmp, file);
    }
    return result;
  } finally { fs.rmSync(lock, { recursive: true, force: true }); }
}
export const updateLedger = (sid, fn) => withLock(ledgerFile(sid), (d) => {
  const l = { pending: [], orphanStops: [], ...d };
  const result = fn(l);
  return { value: l, result };
});
// session 段狀態也走同一把鎖（平行工具呼叫不互蓋）；壞了就重開一段，不影響帳本
export const updateSess = (sid, fn) => withLock(sessFile(sid), (d) => {
  const { st, result } = fn(d && !d.corrupt ? d : newState());
  return { value: st, result };
});
export const readLedger = (sid) => withLock(ledgerFile(sid), (d) => ({ value: undefined, result: { pending: [], orphanStops: [], ...d } }));

// —— 驗收抽取與假驗收檢查（抽取沿用 O 的 wo-verify，不自己解析） ——
export function extractAcceptance(ticketPath) {
  const r = spawnSync(WO_VERIFY, [ticketPath, '--dump'], { encoding: 'utf8', timeout: 10_000 });
  if (r.status !== 0 || !r.stdout.trim()) return { ok: false, why: r.status === 2 ? '沒有 `## 驗收`／Verify 章節內的 bash 區塊' : `wo-verify --dump rc=${r.status}` };
  const dry = spawnSync(WO_VERIFY, [ticketPath, '--dry'], { encoding: 'utf8', timeout: 10_000 });
  if (dry.status !== 0) return { ok: false, why: `驗收區塊語法錯：${(dry.stdout + dry.stderr).trim().slice(0, 200)}` };
  const fake = fakeAcceptance(r.stdout);
  if (fake) return { ok: false, why: fake };
  return { ok: true, script: r.stdout };
}

// 啟發式，只擋明顯一定通過的寫法；擋不住刻意造假（例如恆真比較的變形），那靠完工後主 session 自己看驗收內容。
// 去掉註解；兩版等長、引號外完全相同：quoted 把引號與其內容換成 _（找管線），bare 只把引號與其中的 ;&| 換成空白（認 `set -o 'pipefail'`）
function shellScan(script) {
  const s = String(script).replace(/\\\n/g, ' ');
  let quoted = '', bare = '', q = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === q) { q = ''; quoted += '_'; bare += ' '; continue; }
      if (q === '"' && c === '\\' && i + 1 < s.length) { quoted += '__'; bare += '  '; i++; continue; }
      quoted += c === '\n' ? '\n' : '_'; bare += /[;&|]/.test(c) ? ' ' : c; continue;
    }
    if (c === '\\' && i + 1 < s.length) { quoted += '__'; bare += '  '; i++; continue; }
    if (c === "'" || c === '"') { q = c; quoted += '_'; bare += ' '; continue; }
    if (c === '#' && (i === 0 || /\s/.test(s[i - 1]))) { while (i + 1 < s.length && s[i + 1] !== '\n') i++; continue; }
    quoted += c; bare += c;
  }
  // 斷句只看 quoted，再用同樣位置切 bare；行尾是單一 | 或 |& 的換行屬於同一條管線
  const cuts = [];
  for (const m of quoted.matchAll(/;|&&|\|\||\n/g)) {
    if (m[0] === '\n' && /(?<!\|)\|&?\s*$/.test(quoted.slice(0, m.index))) continue;
    cuts.push([m.index, m.index + m[0].length, m[0]]);
  }
  const split = (x) => { const out = []; let a = 0; for (const [b, c] of cuts) { out.push(x.slice(a, b).trim()); a = c; } out.push(x.slice(a).trim()); return out; };
  return { quoted: split(quoted), bare: split(bare), operators: cuts.map(([, , op]) => op) };
}

// 依執行順序回傳第一個「沒有 pipefail 保護、以 tail／head／tee 等收尾」的管線
export function maskedPipe(script) {
  const { quoted, bare } = shellScan(script);
  let pipefail = false;
  for (let i = 0; i < quoted.length; i++) {
    if (!pipefail && /\|&?\s*(?:tail|head|tee|cat|sort|less|more)\b[^|]*$/.test(quoted[i])) return quoted[i];
    if (/^set\s(?:.*\s)?-[a-z]*o\s+pipefail\b/.test(bare[i])) pipefail = true;
    if (/^set\s(?:.*\s)?\+[a-z]*o\s+pipefail\b/.test(bare[i])) pipefail = false;
  }
  return '';
}

const MASKED_FALLBACK = '驗收用 `|| true` 之類吞掉失敗';
const isTrivialSuccess = (cmd) => !/\||(?<![<>])&(?!>)/.test(cmd) && /^(?:(?:echo|true|:)(?:\s|$)|exit\s+0$)/.test(cmd);

// 大括號內只要有不確定的指令，就不判定整組會吞掉失敗。
function masksFailure(commands, start) {
  let depth = 0;
  for (let i = start; i < commands.length; i++) {
    let cmd = commands[i];
    if (!cmd) continue;
    while (/^\{(?:\s|$)/.test(cmd)) { depth++; cmd = cmd.slice(1).trimStart(); }
    if (!depth) return isTrivialSuccess(cmd);
    if (cmd === '}') {
      if (--depth === 0) return true;
    } else if (cmd && !isTrivialSuccess(cmd)) return false;
  }
  return false;
}

const acceptanceLines = (script) => String(script).split('\n').map((l) => l.replace(/^\s*#.*$/, '').trim()).filter((l) => l && !/^set\s+-[euxo]/.test(l));

function maskedFallback(script, lines = acceptanceLines(script)) {
  if (lines.some((l) => /\|\|\s*(?:true|:|exit\s+0)\s*$/.test(l))) return true;
  const { quoted, operators } = shellScan(script);
  return operators.some((op, i) => op === '||' && masksFailure(quoted, i + 1));
}

export function fakeAcceptance(script) {
  const lines = acceptanceLines(script);
  if (!lines.length) return '驗收區塊是空的';
  if (maskedFallback(script, lines)) return MASKED_FALLBACK;
  // wo-verify 跑 set -e 但不開 pipefail：`npm test | tail` 的 rc 是 tail 的，測試失敗照樣過（issue #1 第 2 類）
  const masked = maskedPipe(script);
  if (masked) return `驗收有 \`${masked.slice(0, 80)}\`：沒有 pipefail 時 rc 是最後一段的，前面失敗會被吞掉；改成 \`cmd > log 2>&1 || { tail -20 log; exit 1; }\``;
  const trivial = /^(?:echo\b.*|printf\b.*|true|:|exit\s+0|test\s+(\S+)\s*==?\s*\1|\[\s+(\S+)\s*==?\s*\2\s+\])$/;
  if (lines.every((l) => trivial.test(l))) return '驗收只有 echo／true／恆真比較，一定會過';
  // 重驗在完工後才跑，主 session 那時常已再 commit；綁死 HEAD 的斷言會誤判失敗（10-27 兩張單 rc=1）
  if (lines.some((l) => /\bgit\b.*\b(?:log\s+(?:\S+\s+)*-(?:1|n\s*1)\b|show\s+(?:\S+\s+)*HEAD\b|diff\S*\s+(?:\S+\s+)*HEAD~)/.test(l)))
    return '驗收綁死最新一筆 commit（git log -1／git show HEAD／HEAD~），完工後再有 commit 就會誤判；改查檔案內容，或 `git log --format=%s -20 | grep`';
  return '';
}

const expand = (p) => String(p).replace(/^~(?=\/)/, HOME);
const CWD_LINE = /(?:工作目錄|cwd|working\s+dir(?:ectory)?)\s*[:：=]?\s*`?((?:~|\/)[^\s`'"，、。；（）()]+)/i;

// 派工前閘：Agent(o-worker) 或 Bash `dcq add`。回 { deny } 或 { entries }（要記進帳本的 pending）；不是派工回 null。
export function gateDispatch({ tool, input = {}, cwd = '', toolUseId = '' }) {
  const now = Date.now();
  if ((tool === 'Agent' || tool === 'Task') && input.subagent_type === 'o-worker') {
    const text = String(input.prompt ?? '');
    const id = `a${now.toString(36)}${crypto.randomBytes(2).toString('hex')}`;
    const ticket = path.join(STATE_DIR, `p-${id}.md`);
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(ticket, text);
    const acc = extractAcceptance(ticket);
    if (!acc.ok) { fs.rmSync(ticket, { force: true }); return { deny: acceptDeny(acc.why) }; }
    const snapshot = ticket.replace(/\.md$/, '.sh');
    fs.writeFileSync(snapshot, acc.script);
    pin(ticket, snapshot);
    const m = CWD_LINE.exec(text);
    return { entries: [{ id, kind: 'agent', status: 'proposed', toolUseId, ticket, snapshot, hash: sha(acc.script), cwd: m ? expand(m[1]) : cwd, createdAt: now }] };
  }
  const cmd = tool === 'Bash' ? String(input.command ?? '') : '';
  const adds = [...stripQuoted(cmd).matchAll(/(?:^|[;&|(\n])\s*(?:\w+=\S*\s+)*dcq\s+add\s+(\S+)(?:\s+(?!easy\b|mid\b|hard\b|\d*[<>])([^\s;&|)<>]+))?/g)];
  if (!adds.length) return null;
  const entries = [];
  for (const [, rawTask, rawCwd] of adds) {
    const task = expand(rawTask.replace(/^['"]|['"]$/g, ''));
    if (!path.isAbsolute(task) || /\$/.test(task)) return { deny: acceptDeny(`dcq add 的工單路徑要寫成字面絕對路徑才能核對驗收（拿到的是 ${rawTask}）`) };
    if (!fs.existsSync(task)) return { deny: acceptDeny(`工單不存在：${task}`) };
    const acc = extractAcceptance(task);
    if (!acc.ok) return { deny: acceptDeny(`${task}：${acc.why}`) };
    const id = `d${now.toString(36)}${crypto.randomBytes(2).toString('hex')}`;
    const snapshot = path.join(STATE_DIR, `p-${id}.sh`);
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(snapshot, acc.script);
    pin(snapshot);
    entries.push({ id, kind: 'dcq', status: 'proposed', toolUseId, ticket: task, snapshot, hash: sha(acc.script), cwd: rawCwd ? expand(rawCwd) : cwd, createdAt: now });
  }
  return { entries };
}
// 派工憑證寫完即唯讀：擋 Write／Edit 工具與 `>` 重導向這類就地改寫（sed -i 這種換檔的擋不住，靠 sha 比對）。
// 只寫一次、不再改，所以不影響本外掛；ledger-*.json 會原子 rename 改寫，chmod 無效，不設。
const pin = (...files) => { for (const f of files) try { fs.chmodSync(f, 0o444); } catch {} };
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const acceptDeny = (why) => [
  `delegate-guard 派工驗收閘：${why}。`,
  '派給 o 的工單必須帶成果驗收標準：`## 驗收` 章節內一個 ```bash 區塊，寫開工前會失敗、完工後會過的斷言（test／grep -q／diff／跑既有測試），',
  '不可只有 echo／true、不可 `|| true`。補上再派。另附 `工作目錄：<絕對路徑>`。',
].join('\n');

// —— 派出／完工 ——
const DCQ_ID = /^\d{9,}-\d+-[\w.-]+$/;
export function jobTask(jobId) {
  for (const d of ['pending', 'running', 'done', 'failed']) {
    try {
      const s = fs.readFileSync(path.join(DCQ_HOME, d, `${jobId}.job`), 'utf8');
      const m = /^TASK=(.*)$/m.exec(s);
      if (!m) continue;
      const o = /^ORIG_TASK=(.*)$/m.exec(s);
      return { state: d, task: m[1].trim(), orig: o ? o[1].trim() : null };
    } catch {}
  }
  return null;
}

// PostToolUse：Agent 回 {status, agentId}；dcq add 的 stdout 每張最後印 job id。回這次確認派出的 pending id 陣列。
export function onLaunched(l, { toolUseId, tool, response }) {
  const mine = l.pending.filter((p) => p.toolUseId === toolUseId && p.status === 'proposed');
  if (!mine.length) return [];
  if (tool === 'Agent' || tool === 'Task') {
    const r = typeof response === 'object' && response ? response : {};
    for (const p of mine) {
      p.agentId = r.agentId ?? null;
      p.status = r.status === 'completed' ? 'terminal' : 'launched';
      if (p.agentId && l.orphanStops.includes(p.agentId)) { p.status = 'terminal'; l.orphanStops = l.orphanStops.filter((x) => x !== p.agentId); }
    }
    return mine.map((p) => p.id);
  }
  const out = typeof response === 'string' ? response : `${response?.stdout ?? ''}`;
  const ids = out.split('\n').map((s) => s.trim()).filter((s) => DCQ_ID.test(s));
  for (const id of ids) {
    const j = jobTask(id);
    const p = j && mine.find((x) => !x.jobId && [j.task, j.orig].some((t) => t && path.resolve(x.ticket) === path.resolve(t)));
    if (p) { p.jobId = id; p.status = 'launched'; }
  }
  // 派了但 job id 對不上工單（dcq add 被拒或輸出格式變了）：標 unlinked，Stop 只提醒一次
  for (const p of mine) if (p.status === 'proposed') p.status = /LINT OK|^\d{9,}-/m.test(out) ? 'unlinked' : 'launch-failed';
  return mine.filter((p) => p.status !== 'launch-failed').map((p) => p.id);
}

export function onLaunchFailed(l, { toolUseId }) {
  for (const p of l.pending) if (p.toolUseId === toolUseId && p.status === 'proposed') p.status = 'launch-failed';
}

export function onSubagentStop(l, { agentId }) {
  const p = l.pending.find((x) => x.agentId === agentId);
  if (p) { if (p.status === 'launched') p.status = 'terminal'; return; }
  if (agentId && !l.orphanStops.includes(agentId)) l.orphanStops = [...l.orphanStops, agentId].slice(-50);
}

export function isTerminal(p) {
  if (p.kind === 'agent') return p.status === 'terminal';
  if (p.kind === 'dcq' && p.jobId) return ['done', 'failed'].includes(jobTask(p.jobId)?.state);
  return false;
}
// 帳本裡還有派出但未完工的項目（issue #2：已派未回）。unlinked 對不上 job 當沒在跑，免得 pending 卡死。
export const anyRunning = (l) => l.pending.some((p) => p.status === 'launched' && !isTerminal(p));

// cwd 的指紋：只用工作樹內容算 tree hash（commit 不影響）；非 repo 或失敗回 null。
// 用暫存 index 檔（GIT_INDEX_FILE）而非真正的 .git/index，算完即刪。
export function cwdFingerprint(cwd, { spawn = spawnSync } = {}) {
  if (!cwd) return null;
  let tmp;
  try { tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dg-index-')); } catch { return null; }
  const env = { ...process.env, GIT_INDEX_FILE: path.join(tmp, 'index') };
  const run = (args, gitEnv = env) => {
    const r = spawn('git', args, { cwd, encoding: 'utf8', timeout: 30_000, env: gitEnv });
    if (r.error || r.status !== 0) return null;
    return r.stdout ?? '';
  };
  try {
    const realEnv = { ...process.env };
    delete realEnv.GIT_INDEX_FILE;
    if (run(['rev-parse', '--verify', 'HEAD'], realEnv) === null) return null;
    const index = run(['rev-parse', '--git-path', 'index'], realEnv);
    let seeded = false;
    if (index !== null) {
      try {
        fs.copyFileSync(path.resolve(cwd, index.trim()), env.GIT_INDEX_FILE);
        // 以 HEAD 正規化追蹤項目與模式，只保留可沿用的 stat cache。
        if (run(['-c', 'core.splitIndex=false', 'read-tree', '-m', 'HEAD']) !== null) {
          // 跳過工作樹檢查的旗標不能沿用，改走原本的 HEAD 路徑。
          const files = run(['ls-files', '-v', '-z', '--', ':/']);
          seeded = files !== null && !files.split('\0').some((f) => f && !f.startsWith('H '));
        }
      } catch {}
    }
    const snapshot = () => {
      // 避免暫存 split index 在真正的 git 目錄建立 sharedindex。
      if (run(['-c', 'core.splitIndex=false', 'add', '-A']) === null) return null;
      return run(['-c', 'core.splitIndex=false', 'write-tree']);
    };
    let tree = seeded ? snapshot() : null;
    if (tree === null) {
      fs.rmSync(env.GIT_INDEX_FILE, { force: true });
      if (run(['-c', 'core.splitIndex=false', 'read-tree', 'HEAD']) === null) return null;
      tree = snapshot();
    }
    if (tree === null) return null;
    return crypto.createHash('sha256').update(tree.trim()).digest('hex');
  } finally {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch {}
  }
}

// 驗完之後，在同一個 cwd 底下又寫檔 → 驗收作廢，要重驗（git add/commit/push/tag 不算）
export function invalidate(l, { tool, input = {}, cwd = '' }) {
  const cmd = tool === 'Bash' ? String(input.command ?? '') : '';
  if (tool === 'Bash' && (isReadOnly(cmd) || isRunnerCmd(cmd) || /^\s*(?:cd\s+\S+\s*&&\s*)?git\s+(?:add|commit|push|tag)\b/.test(cmd))) return 0;
  const wheres = WRITE_TOOLS.has(tool) ? [targetPath(input)] : tool === 'Bash' ? (dispatchTargets(cmd, cwd) ?? redirectTargets(cmd, cwd) ?? [cwd]) : [];
  let n = 0;
  for (const p of l.pending) {
    if (p.verified && !p.stale && p.verified.fp == null && p.cwd && wheres.some((w) => w && (w === p.cwd || w.startsWith(`${p.cwd}/`)))) { p.stale = true; n++; }
  }
  return n;
}

export const runnerCmd = (sid, id) => `node ${path.join(PLUGIN_ROOT, 'scripts/verify.mjs')} ${safeId(sid)} ${id}`;

// 重驗（scripts/verify.mjs 呼叫）：必須已完工；跑 wo-verify --pinned（被改過的驗收 exit 3），rc 記進帳本。
export function runVerify(sid, id, { spawn = spawnSync } = {}) {
  const pre = readLedger(sid).pending.find((p) => p.id === id);
  if (!pre) return { rc: 64, out: `帳本裡沒有 ${id}` };
  if (!isTerminal(pre)) return { rc: 75, out: `${id} 還沒完工（${pre.status}${pre.jobId ? ` job ${pre.jobId}` : ''}），完工後再驗` };
  let snap = '';
  try { snap = fs.readFileSync(pre.snapshot, 'utf8'); } catch {}
  if (sha(snap) !== pre.hash) return { rc: 3, out: `派工時的驗收快照被改過：${pre.snapshot}` };
  // cwd 不存在時 spawn 直接 ENOENT、status=null，會被誤記成 124 逾時（10-26：工單寫「工作目錄：/x（不存在就建）」整串被當路徑）
  if (pre.cwd && !fs.existsSync(pre.cwd)) return { rc: 66, out: `派工 cwd 不存在：${pre.cwd}（工單「工作目錄：」行只寫路徑，說明另起一行）` };
  // 舊快照可能在派工時沒擋下吞掉失敗的備援；重驗也不能讓它回報成功。
  const r = maskedFallback(snap)
    ? { status: 1, stderr: `${MASKED_FALLBACK}\n` }
    : spawn(WO_VERIFY, [pre.ticket, '--pinned', pre.snapshot], { cwd: pre.cwd || undefined, encoding: 'utf8', timeout: 660_000 });
  const rc = typeof r.status === 'number' ? r.status : 124;
  updateLedger(sid, (l) => { const p = l.pending.find((x) => x.id === id); if (p) { p.verified = { rc, at: Date.now(), fp: cwdFingerprint(pre.cwd) }; p.stale = false; } });
  return { rc, out: `${r.stdout ?? ''}${r.stderr ?? ''}${r.error ? `wo-verify 沒跑起來：${r.error.message}\n` : ''}` };
}

// Stop：已完工未重驗、驗收作廢、驗收失敗 → 提醒（每筆最多 MAX_REMINDERS 次）。回 reason 或 ''。
export function stopCheck(l, sid, { fingerprint = cwdFingerprint } = {}) {
  const lines = [];
  if (l.corrupt && !l.corruptReported) { lines.push(`派工帳本損壞，已改名保留在 ${l.corrupt}；之前的派工無法核對驗收，回報時要明說。`); l.corruptReported = true; }
  const now = Date.now();
  l.pending = l.pending.filter((p) => !(p.status === 'proposed' && now - p.createdAt > PROPOSED_TTL_MS));
  for (const p of l.pending) {
    if ((p.reminders ?? 0) >= MAX_REMINDERS) continue;
    if (p.verified?.fp != null && !p.stale) {
      const cur = fingerprint(p.cwd);
      if (cur !== p.verified.fp) p.stale = true;
    }
    const label = `${p.id}（${p.kind === 'agent' ? 'o-worker' : `dcq ${p.jobId ?? '?'}`}，cwd ${p.cwd}）`;
    if (p.status === 'unlinked') {
      lines.push(`- ${label} 派出了但對不上 dcq job id，無法判斷是否完工；用 dcq status 自己確認`);
      p.reminders = MAX_REMINDERS;
      continue;
    }
    if (!['launched', 'terminal'].includes(p.status) || !isTerminal(p)) continue;
    if (!p.verified) lines.push(`- ${label} 已完工，主 session 還沒重驗：${runnerCmd(sid, p.id)}`);
    else if (p.stale) lines.push(`- ${label} 驗過之後 cwd 又被改，要重驗：${runnerCmd(sid, p.id)}`);
    else if (p.verified.rc !== 0) lines.push(`- ${label} 重驗失敗 rc=${p.verified.rc}：回報要寫失敗並附原始輸出，不得宣告完成。`);
    else continue;
    p.reminders = (p.reminders ?? 0) + 1;
  }
  if (!lines.length) return '';
  return ['delegate-guard：o 的派工成果還沒被主 session 檢查。', ...lines,
    '重驗跑的是派工當下快照的驗收（wo-verify --pinned），rc 由 hook 記錄；另跑 `git -C <cwd> diff --stat` 看有沒有超出工單的改動。'].join('\n');
}
