// delegate-guard 共用：路徑、log、訊號與動作判定（純函式，hook 與 replay 共用）。派工帳本在 ledger.mjs。
// 設計：DESIGN-v0.2.md＋v0.3（改派三類、派工驗收閘、完工後主 session 重驗）。
// 動作：建議派（additionalContext，不擋）／直接改派（deny，直到真的派出或明示自做；每段最多擋 3 次）／無法派（不擋，說原因）。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const HOME = os.homedir();
export const OFF_FILE = process.env.DEGUARD_OFF_FILE || path.join(HOME, '.claude/delegate-guard.off');
export const LOG = process.env.DEGUARD_LOG || path.join(HOME, '.claude/logs/delegate-guard.log');
export const STATE_DIR = process.env.DEGUARD_STATE || path.join(HOME, '.claude/state/delegate-guard');
export const CASCADE_FILE = process.env.DECIDE_CASCADE_FILE || path.join(HOME, '.jevgate/cascade-callers.json');
export const PLUGIN_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const CASCADE_TIMEOUT_MS = 4000;

// 閾值（本機 60 transcript 校準，見 DESIGN-v0.2.md）
export const S1_SUGGEST = 10;
export const S1_REROUTE = 18;
export const S2_CTX = 100_000;
export const S2_FACTOR = 0.6;
export const S3_PATHS = 10;
export const S4_CHARS = 40_000;
export const S6_HIT = 3;      // ≥3 判命中；剛好 S6_TIE 分才問 Laya
export const S6_TIE = 2;
export const REROUTE_MAX_DENY = 3;   // 同一段最多擋 3 次，之後放行並記 overridden，避免鎖死 session

export const isOff = () => fs.existsSync(OFF_FILE);

export const log = (s) => {
  try { fs.mkdirSync(path.dirname(LOG), { recursive: true }); fs.appendFileSync(LOG, `${new Date().toISOString()}\t${s}\n`); } catch {}
};

export const safeId = (id) => String(id ?? 'nosession').replace(/[^\w-]/g, '').slice(0, 80) || 'nosession';
export const sessFile = (id) => path.join(STATE_DIR, `sess-${safeId(id)}.json`);
export const goalFile = (id) => path.join(STATE_DIR, `goal-${safeId(id)}.md`);

export const isMain = (fileUrl) => fileUrl === new URL(`file://${process.argv[1]}`).href;

// —— 規則 ——
// S5：沿用 v0.1 regex，拿掉 sed -i／sd、Edit 內文關鍵字與 for/while 批迴圈（回放 60 transcript：迴圈命中 562 次，多為短診斷）
const DELEGATE_VERB = /\b(?:pnpm|npm|yarn|bun)\s+(?:-r\s+|--filter\s+\S+\s+)?(?:i|install|add|update|up|upgrade|dedupe|audit\s+fix)\b|\bpip3?\s+install\b|\buv\s+(?:sync|add|lock)\b|\bcargo\s+update\b|\bgo\s+get\s+-u\b|\brsync\b|\bmagick\b|\bffmpeg\b/;
// 全套測試：排除只跑單檔／單測試（pytest 帶 .py 檔、::、-k 都算單跑）
const FULL_TEST = /\b(?:vitest|jest|mocha)\s+run(?:\s|$)(?![^\n]*(?:\.\w*test\.[jt]s|-t\s|--filter|--testPathPattern|--testNamePattern))|\bpytest\b(?![^\n]*(?:::|\s-k\s|\.py\b))|\bpnpm\s+(?:-r\s+)?test\b(?!\s+[^\s-])|\bnpm\s+test\b(?!\s+[^\s-])|\bphpunit\b(?![^\n]*--filter)|\bcargo\s+test\b|\bgo\s+test\s+\.\/\.\.\./;
// 派工後在寫文件的指令（deep-run、openmausbot run）也算派工：onPreTool 計次歸零、invalidate 不當成 cwd 寫入
const DISPATCHED = /\bo-worker\b|(?:^|[\s;&|(/])(?:dcq|dc)\s+(?:add|plan|run|start|wait|status|cancel)\b|DCQ_ORDER=|dispatch-router\/bin\/dcq?\b|(?:^|[\s;&|(/])deep-run\s|(?:^|[\s;&|(/])openmausbot\s+run\b/;  // `cd ~/dev/dispatch-router` 是在改派工系統本身，不算
const DISPATCH_WRITE = /^(\s*(?:\w+=\S*\s+)*)(?:(?:deep-run\s+([^\s;&|]+)(?:\s+([^\s;&|]+))?)|(?:dcq\s+add\s+([^\s;&|]+)(?:\s+([^\s;&|]+))?)|openmausbot\s+run\b)/;
// 派工指令的寫入位置：deep-run／dcq add 的 cwd 參數；openmausbot run 在本機 cwd 不寫檔 → []。
// 同時含其他非唯讀段（`deep-run …; rm x`）或寫法認不得 → null（呼叫端退回保守的 cwd）。
export function dispatchTargets(command, cwd = '') {
  const c = String(command ?? '');
  if (!isDispatchedCmd(c) || isReadOnly(c)) return null;
  const s = stripQuoted(c);
  const m = DISPATCH_WRITE.exec(s);
  if (!m) return null;
  const rest = s.slice(m[0].length).replace(/\d?>{1,2}\s*(?:&\d+|\/dev\/null)/g, ' ');  // 丟棄型重導向不算寫入段
  // 分隔字元以空白起頭（`y;`、`y&&`）；重導向以空白＋`>` 起頭（`b.log > x`）。`2>&1` 已在上面丟棄。
  if (/(^|[^\\])\n|(^|\s)[;&|]|(^|[^\S\n])\d?>{1,2}(?=[^&=\d\s])|`|\$\(/.test(rest)) return null;
  if (/^\s*openmausbot\b/.test(m[0].trim())) return [];
  const dir = m[3] ?? m[5];
  if (!dir || dir.startsWith('-') || /[$`(){}*?[\]]/.test(dir)) return null;  // 參數是 shell 展開，解不出來就保守
  return [path.resolve(cwd || '/', dir)];
}
// ponytail: 以 regex 近似解析 shell（拆段、找重導向、抓指令名），不做完整 lexer；遇到解析不了的寫入形式走保守 false。
// 解譯器（node／python）可任意寫檔，不算唯讀，只放行 -v／-V 版本探測
const READONLY_WORDS = 'cd|ls|cat|head|tail|wc|grep|find|which|type|stat|file|jq|pwd|echo|fixindex';
const SEG_GIT = /^\s*git\s+(?:status|log|show|diff)\b(?!.*(?:^|\s)--output\b)/;
const SEG_RG = /^\s*rg\b(?!.*(?:^|\s)--pre(?:=|\s))/;
const SEG_RO = new RegExp(`^\\s*(?:${READONLY_WORDS})\\b|^\\s*node\\s+-v\\b|^\\s*python3?\\s+-V\\b|^\\s*fixindex\\s+(?:find|show|stats)(?:\\s+\\S+)?\\s*$`);
// 重導向：任意 fd（0-9）的 >／>> 都算寫入，唯一例外是目標 /dev/null（`2>&1` 這類 fd 複製不算寫入）
const WRITE_REDIR = (c) => [...c.matchAll(/&>>?|\d*>>?/g)].some((m) => {
  const t = c.slice(m.index + m[0].length).match(/^\s*(\S*)/)?.[1] ?? '';
  return t !== '/dev/null' && !/^&\d+$/.test(t);
});
const stripComments = (c) => c.replace(/(^|\s)#[^\n]*/g, '$1');
// 引號內含空白的片段（多半是字串參數）換成等長空白，避免把裡面的派工字樣當成真派工；
// 不含空白的引號片段（例如 "/abs/wo.md"）保留，實際路徑照常解析。等長替換讓索引不位移。
export function stripQuoted(command) {
  return String(command ?? '').replace(/(['"])((?:\\.|(?!\1)[\s\S])*?)\1/g, (m, q, body) => (/\s/.test(body) ? ' '.repeat(m.length) : m));
}
// o 的禁區（o-worker.md：~/.claude/**、.git/config、launchd、憑證、LCT／CoinW 內部資料）→ 無法派
const FORBIDDEN = /(?:~|\/Users\/[^/\s]+)\/\.claude\/|\.git\/config\b|\blaunchctl\b|LaunchAgents|\.creds\b|\b[A-Z_]*(?:TOKEN|API_KEY|SECRET)\b|\bLCT\b|\bCoinW\b/i;
const SELF_MARK = /#\s*deguard:self\b\s*(.*)$/m;
const RUNNER = /(?:^|\/)scripts\/verify\.mjs\b/;
export const WRITE_TOOLS = new Set(['Edit', 'Write', 'NotebookEdit', 'MultiEdit']);
export const AGENT_TOOLS = new Set(['Agent', 'Task']);

// 只認字面指令；含 $( ) 反引號 <( >(、寫檔重導向、curl、find 刪除/執行一律非唯讀。
const notReadOnly = (c) => !!(/\$\(|`|<\(|>\(/.test(c) || /\bcurl\b/.test(c) || WRITE_REDIR(c)
  || /\bfind\b[^;|&\n]*\s-(?:delete|exec|execdir|ok|okdir|fprint|fprintf|fls)\b/.test(c));
// 唯讀＝每一段（; && || | 換行切開）都是唯讀指令；--help 只認指令本身最後一個參數（先去掉 # 註解）。
// git 只放行 status/log/show/diff 且 diff 不帶 --output；rg 帶 --pre 不算
export const isReadOnly = (raw) => {
  const original = String(raw ?? '');
  const c = stripComments(original);
  if (!c.trim() || notReadOnly(c.replace(/(^|\s)#[^\n]*/g, ' $1'))) return false;
  return c.split(/&&|\|\||[;|\n]/).every((part) => {
    const w = part.trim().split(/\s+/);
    if (!w[0]) return true;
    if (w[w.length - 1] === '--help') return true;
    if (w[0] === 'git') return SEG_GIT.test(part.trim());
    if (w[0] === 'rg') return SEG_RG.test(part.trim());
    if (/\bsed\b/.test(part)) return false;  // sed 只在最後參數是 --help 時放行（上面已先 return）
    return SEG_RO.test(part);
  });
};
// 計次用：Read/Grep/Glob、唯讀 Bash 與純機械 Bash 不累加 st.calls（2026-11-04 瘦身＋issue #2：S1 只該量「要判斷的動作數」，cp/mkdir/git commit 這類搬動記錄不算）
const COUNT_FREE = new Set(['Read', 'Grep', 'Glob']);
const MECH_GIT = /^\s*(?:\w+=\S*\s+)*git\s+(?:add|commit|push|tag|checkout|switch|restore|merge|rebase|stash|pull|fetch|clone|mv|rm|init|branch|cherry-pick|reset|clean|config|remote|submodule|blame|apply|format-patch|archive)\b/;
const MECH_SEG = /^\s*(?:\w+=\S*\s+)*(?:cd|cp|mv|mkdir|rmdir|rm|touch|chmod|chown|chgrp|ln|install|tar|zip|unzip|gzip|gunzip|bzip2|xz|sed)\b/;
// 純機械＝每一段（; && || | 換行切開）都是檔案搬動／git 記錄類動作；含 $( ) 反引號的保守不算
export const isMechanical = (raw) => {
  const c = stripComments(String(raw ?? ''));
  if (!c.trim() || /\$\(|`|<\(|>\(/.test(c) || /\bcurl\b/.test(c)) return false;
  return c.split(/&&|\|\||[;|\n]/).every((part) => {
    const t = part.trim();
    return !t || MECH_GIT.test(t) || MECH_SEG.test(t);
  });
};
export const countsTowardS1 = (tool, input = {}) => !(COUNT_FREE.has(tool) || (tool === 'Bash' && (isReadOnly(input.command) || isMechanical(input.command))));
// Bash 只靠重導向寫檔時回傳寫入目標（絕對路徑）；其他非唯讀指令回 null（呼叫端退回用 cwd 判斷）。
// ponytail: 不解析引號內的 >、tee、cp/mv；遇到就回 null 走保守路線。
const HEREDOC = /<<-?\s*(['"]?)(\w+)\1([^\n]*)\n[\s\S]*?\n\t*\2[ \t]*(?=\n|$)/g;
const REDIR = /(^|[^>&\d<])\d?>{1,2}\s*([^\s;&|]+)/g;
export function redirectTargets(command, cwd = '') {
  const c = String(command ?? '').replace(HEREDOC, '$3');
  const targets = [];
  const rest = c.replace(REDIR, (m, pre, t) => {
    if (t.startsWith('&') || t === '/dev/null') return m;
    targets.push(t.startsWith('~/') ? path.join(HOME, t.slice(2)) : path.resolve(cwd || '/', t));
    return pre;
  });
  return targets.length && isReadOnly(rest) ? targets : null;
}
export const isDispatchedCmd = (command) => DISPATCHED.test(stripQuoted(command));
export const isRunnerCmd = (command) => RUNNER.test(String(command ?? ''));
export const selfReason = (command) => { const m = SELF_MARK.exec(String(command ?? '')); return m ? (m[1].trim() || '(未寫理由)') : null; };
export const targetPath = (input) => String(input?.file_path ?? input?.notebook_path ?? '');
export const isForbidden = (text) => FORBIDDEN.test(String(text ?? ''));

// S5：Bash 指令的硬關鍵字
export function hardKeyword(command) {
  const c = String(command ?? '');
  if (!c || isReadOnly(c) || /--help\b|\s-h\b|^\s*man\s/.test(c)) return '';
  if (FULL_TEST.test(c)) return 'full-test';
  if (DELEGATE_VERB.test(c)) return 'delegate-verb';
  return '';
}

// S6：任務層規則打分（借鏡 LiteLLM complexity router）；判斷型字眼扣 2 分
export function scoreTask(prompt) {
  const p = String(prompt ?? '');
  const hits = [];
  const listItems = p.split('\n').filter((l) => /^\s*(?:[-*•]|\d+[.)、])\s+\S/.test(l)).length;
  if (listItems >= 3) hits.push('items≥3');
  if (/每[個一支份張]|全部|所有|\d+\s*個(?:檔|文件|檔案)|逐[個一]|批次|\b(?:each|every|all)\s+(?:file|files)\b/i.test(p)) hits.push('every');
  if (/照範本|套範本|依範本|按範本|template/i.test(p)) hits.push('template');
  if (/轉檔|格式轉換|轉成\s*\w+\s*格式|\bconvert\b/i.test(p)) hits.push('convert');
  if (/搬移|搬到|搬遷|遷移|\bmigrate\b|\bmove\b.*\bto\b/i.test(p)) hits.push('move');
  if (/審查|驗屍|根因|為什麼|為何|取捨|設計|評估|比較|\breview\b|\baudit\b|\bwhy\b/i.test(p)) hits.push('judgment');
  const score = hits.reduce((s, h) => s + (h === 'judgment' ? -2 : h === 'items≥3' || h === 'every' ? 2 : 1), 0);
  return { score, hits };
}

// —— session 狀態：一段＝一則使用者訊息到下一則 ——
export function newState() {
  return { seg: 0, prompt: '', calls: 0, s6: false, suggested: false, noneNoted: false, bigOutputs: 0, paths: {}, read: [], reroute: null };
}

export function onPrompt(st, prompt) {
  return { ...newState(), seg: st.seg + 1, prompt: String(prompt ?? '').slice(0, 8000) };
}

// 改派三類：none＝無法派、full＝全權派、partial＝部分派。禁區優先，再看明示自做、即時上下文。
export function classify({ via, tool, input, st }) {
  const cmd = tool === 'Bash' ? String(input.command ?? '') : '';
  const p = targetPath(input);
  if (isForbidden(cmd) || isForbidden(p) || isForbidden(st.prompt)) return { cls: 'none', why: 'o 禁區（~/.claude、.git/config、launchd、憑證、LCT／CoinW）' };
  const self = selfReason(cmd);
  if (self !== null) return { cls: 'none', why: `明示自做：${self}` };
  if (WRITE_TOOLS.has(tool) && st.read.includes(p) && !st.s6) return { cls: 'none', why: '即時上下文（本段已讀過這個檔、任務層沒命中）' };
  if (st.s6 && /^S[35]/.test(via)) return { cls: 'full', why: '任務層命中＋高精度訊號' };
  return { cls: 'partial', why: '單一動作訊號只授權這一類動作' };
}

// 一次 PreToolUse。ctx＝當下上下文 token（S2），null＝量不到。
// 回 { st, action }；action＝null | { kind: 'suggest'|'reroute'|'note'|'allow', via, cls?, text? }
export function onPreTool(st, { tool, input = {}, ctx = null, cwd = '', sid = '' }) {
  st = { ...st, paths: { ...st.paths } };
  const cmd = tool === 'Bash' ? String(input.command ?? '') : '';

  if (isRunnerCmd(cmd)) return { st, action: { kind: 'allow', via: 'verify-runner' } };
  // 派子代理或 dcq：本段從這裡重新計數（改派要求要等 PostToolUse 確認派出才解除）
  if (AGENT_TOOLS.has(tool) || isDispatchedCmd(cmd)) {
    return { st: { ...st, calls: 0, paths: {}, suggested: false }, action: { kind: 'allow', via: AGENT_TOOLS.has(tool) ? `agent:${input.subagent_type ?? '?'}` : 'dispatched' } };
  }
  // 已派未回（issue #2）：計數與判定凍結，等 worker 回來（subagent-stop／dcq job 完工）才恢復
  if (st.reroute?.pending) return { st, action: null };

  if (countsTowardS1(tool, input)) st.calls += 1;
  const p = targetPath(input);
  if (WRITE_TOOLS.has(tool) && p) {
    const set = st.paths[tool] ?? [];
    if (!set.includes(p)) st.paths[tool] = [...set, p];
  }

  const scale = ctx !== null && ctx > S2_CTX ? S2_FACTOR : 1;
  const suggestAt = Math.ceil(S1_SUGGEST * scale);

  let via = '';
  const kw = tool === 'Bash' ? hardKeyword(cmd) : '';
  if (kw) via = `S5 ${kw}`;
  else if (WRITE_TOOLS.has(tool) && (st.paths[tool]?.length ?? 0) >= S3_PATHS) via = `S3 ${tool}×${st.paths[tool].length}檔`;
  // S1 呼叫數只到建議線（issue #2）：次數本身不再觸發改派——建議線與改派線共用 st.suggested，
  // 同一段只提示一次；改派只認 S3／S5 這種看「這一動在做什麼」的訊號（S1_REROUTE 保留作校準紀錄）

  const done = st.reroute?.cleared;
  if (via && !done && (tool === 'Bash' ? !isReadOnly(cmd) : WRITE_TOOLS.has(tool))) {
    const { cls, why } = classify({ via, tool, input, st });
    st.suggested = true;
    if (cls === 'none') {
      if (st.noneNoted) return { st, action: { kind: 'allow', via: `${via} ← ${why}`, cls } };
      st.noneNoted = true;
      return { st, action: { kind: 'note', via: `${via} ← ${why}`, cls, text: noneText(via, why) } };
    }
    const denies = (st.reroute?.denies ?? 0) + 1;
    if (denies > REROUTE_MAX_DENY) {
      st.reroute = { ...st.reroute, cleared: 'overridden' };
      return { st, action: { kind: 'allow', via: `${via} ← overridden（已擋 ${REROUTE_MAX_DENY} 次未派）`, cls } };
    }
    st.reroute = { denies, cls, via, cleared: '' };
    return { st, action: { kind: 'reroute', via, cls, text: rerouteText({ via, cls, why, tool, input, cwd, prompt: st.prompt, sid }) } };
  }

  if (!st.suggested && st.calls >= suggestAt) {
    st.suggested = true;
    return { st, action: { kind: 'suggest', via: `S1 ${st.calls}≥${suggestAt}${scale < 1 ? '(S2)' : ''}`, text: suggestText(`本段已 ${st.calls} 次工具呼叫`) } };
  }
  return { st, action: null };
}

// 一次 PostToolUse：Read 成功才記即時上下文；S4 大輸出第 2 次起建議派
export function onPostTool(st, { tool = '', input = {}, responseChars = 0 }) {
  if (tool === 'Read' && input.file_path && !st.read.includes(input.file_path)) st = { ...st, read: [...st.read, input.file_path].slice(-500) };
  if (responseChars <= S4_CHARS) return { st, action: null };
  st = { ...st, bigOutputs: st.bigOutputs + 1 };
  if (st.bigOutputs < 2 || st.suggested) return { st, action: null };
  st.suggested = true;
  return { st, action: { kind: 'suggest', via: `S4 ${st.bigOutputs}次>${S4_CHARS}字`, text: suggestText(`本段第 ${st.bigOutputs} 次工具輸出超過 ${S4_CHARS} 字`) } };
}

// 派出去了（PostToolUse 確認 o-worker 啟動或 dcq add 拿到 job）→ 解除本段改派要求並掛 pending：
// worker 回來前計數與判定凍結（issue #2「已派未回」）
export const onDispatched = (st) => ({ ...st, reroute: { ...(st.reroute ?? { denies: 0 }), cleared: 'dispatched', pending: true } });
// worker 回來（o-worker 的 SubagentStop，或 dcq job 進 done/failed）→ 恢復計數
export const onWorkerBack = (st) => (st.reroute?.pending ? { ...st, reroute: { ...st.reroute, pending: false } } : st);

// —— 動作文字 ——
export const suggestText = (why) => [
  `delegate-guard 建議派 o（${why}）：剩下的機械部分看起來量大、難度低，派出去比在主 session 做省。`,
  '建議：把剩下的工作寫成自含工單（目標、工作目錄絕對路徑、`## 驗收` 區塊內一條會失敗的 bash 指令），交 o-worker subagent，主 session 只收結論，完工後照 hook 給的指令重驗。',
  '小修、要來回迭代、或很依賴本段上下文的，留在主 session 做也合理，自行判斷。',
].join('\n');

const noneText = (via, why) => `delegate-guard：這段已達改派線（${via}），但判定無法派——${why}。留在主 session 做，本段不再提示。`;

const ACCEPT_FORMAT = [
  '工單（Agent prompt）必須含：',
  '  工作目錄：<絕對路徑>',
  '  ## 驗收',
  '  ```bash',
  '  <開工前會失敗、完工後會過的斷言；不可只有 echo／true／|| true>',
  '  ```',
  '沒有驗收區塊的派工會被擋。完工後 hook 會給一條重驗指令，主 session 要自己跑，不採信 o 的自述。',
];

export function rerouteText({ via, cls, why, tool, input, cwd, prompt, sid }) {
  const what = tool === 'Bash' ? String(input.command ?? '').slice(0, 400) : `${tool} ${targetPath(input)}`;
  const scope = cls === 'full'
    ? `全權派（${why}）：本段剩下的工作整包派出，目標＝使用者原話（全文 ${goalFile(sid)}）：${String(prompt || '').slice(0, 1500).replace(/\s+/g, ' ')}`
    : `部分派（${why}）：只派「被擋的這一動＋同類剩下的批次」，設計取捨、找根因留在主 session。`;
  return [
    `delegate-guard 直接改派（${via}）：這一動不在主 session 執行，改派 o-worker。`,
    scope,
    `被擋的這一動：${what.replace(/\s+/g, ' ')}`,
    `工作目錄：${cwd || '(填絕對路徑)'}`,
    '下一個工具呼叫就用 Agent(subagent_type: "o-worker") 派出去，派前不問、不等答覆。',
    ...ACCEPT_FORMAT,
    '確實無法派（要判斷力、要本段即時上下文、碰憑證）：Bash 指令加 `# deguard:self <理由>` 重送。',
  ].join('\n');
}

// —— S2：transcript 最後一筆 assistant usage ——
export function contextTokens(transcriptPath) {
  try {
    const fd = fs.openSync(transcriptPath, 'r');
    const size = fs.fstatSync(fd).size;
    const len = Math.min(size, 512 * 1024);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    fs.closeSync(fd);
    const lines = buf.toString('utf8').split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i].includes('"usage"')) continue;
      let e; try { e = JSON.parse(lines[i]); } catch { continue; }
      const u = e?.message?.usage;
      if (e?.type === 'assistant' && u) return usageTokens(u);
    }
  } catch {}
  return null;
}
export const usageTokens = (u) => (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);

// —— System 1（Laya，免費，127.0.0.1）：只在 UserPromptSubmit 當 S6 平手裁判 ——
function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

export function cascadeUrl() {
  const j = readJson(CASCADE_FILE, {});
  const u = j['delegate'] ?? j['route-judge'] ?? j['decide'];
  return typeof u === 'string' && /^http:\/\/127\.0\.0\.1:\d+\/?$/.test(u) ? u.replace(/\/+$/, '') : '';
}

// 回 'delegate' | 'self' | null（判不下：ABSTAIN、低信心、格式不對）。呼叫端 null 一律放行。
export async function askSystemOne(url, userRequest, fetchImpl = fetch) {
  const res = await fetchImpl(`${url}/v1/systemone`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-jev-caller': 'delegate-guard', 'x-jev-mode': 'laya-only' },
    body: JSON.stringify({
      state: { user_request: String(userRequest).slice(0, 300) },
      questions: {
        delegate: {
          type: 'noul',
          instructions: 'A user gave this task to a coding agent. Should the agent delegate the work to a cheaper background executor instead of doing it in its main session? Yes when it takes over 5 minutes or is high-volume, low-difficulty mechanical work: dependency upgrades, full test suites, batch edits across many files, data moves, format conversion, templated file generation. No when it is a question, a short fix, needs judgment (design trade-offs, root-cause hunting), or touches credentials.',
          criteria: { true: 'yes — long or high-volume and low difficulty', false: 'no — short, a question, or needs judgment' },
        },
      },
    }),
    signal: AbortSignal.timeout(CASCADE_TIMEOUT_MS),
  });
  if (res.status === 503) return null;
  if (!res.ok) throw new Error(`cascade ${res.status}`);
  const a = (await res.json())?.answers?.delegate?.noul;
  if (typeof a !== 'number') return null;
  if (a >= 0.65) return 'delegate';
  if (a <= 0.35) return 'self';
  return null;
}
