// Usage: node scripts/i18n/extract-ru.mjs
// Writes i18n-work/ru/*.json English sources for the Russian (ru) locale.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const outDir = path.join(root, 'i18n-work', 'ru');
const chunkSize = 350;
fs.mkdirSync(outDir, { recursive: true });

function writeChunks(prefix, entries) {
  const rows = Object.entries(entries);
  const files = [];
  for (let i = 0; i < rows.length; i += chunkSize) {
    const n = String(Math.floor(i / chunkSize) + 1).padStart(2, '0');
    const name = `${prefix}-${n}.json`;
    fs.writeFileSync(path.join(outDir, name), `${JSON.stringify(Object.fromEntries(rows.slice(i, i + chunkSize)), null, 2)}\n`);
    files.push(name);
  }
  if (!rows.length) return files;
  return files;
}

function* localeArrays(source) {
  const startRe = /([A-Za-z_$][\w$]*):\s*\[/g;
  for (let match; (match = startRe.exec(source));) {
    const open = startRe.lastIndex - 1;
    let quote = '', escaped = false, depth = 1, end = open + 1;
    for (; end < source.length && depth; end++) {
      const ch = source[end];
      if (quote) {
        if (escaped) escaped = false;
        else if (ch === '\\') escaped = true;
        else if (ch === quote) quote = '';
      } else if (ch === "'" || ch === '"') quote = ch;
      else if (ch === '[') depth++;
      else if (ch === ']') depth--;
    }
    if (!depth) yield { key: match[1], inner: source.slice(open + 1, end - 1) };
    startRe.lastIndex = end;
  }
}

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

const ui = {};
const localeSource = read('i18n-locales.js');
for (const match of localeArrays(localeSource)) {
  try {
    const values = Function(`return [${match.inner}]`)();
    if (values.length >= 8 && typeof values[2] === 'string') ui[`ui:${match.key}`] = values[2];
  } catch {}
}

const extSource = read('src/runtime/i18n-ext-beta4.js');
const extBlock = extSource.match(/const TABLE = Object\.freeze\(\{([\s\S]*?)\n  \}\);/);
if (extBlock) {
  for (const match of localeArrays(extBlock[1])) {
    try {
      const values = Function(`return [${match.inner}]`)();
      if (values.length >= 8 && typeof values[2] === 'string') ui[`ext:${match.key}`] = values[2];
    } catch {}
  }
}

const inlineSource = read('vendor/inline-diff/inline-diff-client.js');
const inlineBlock = inlineSource.match(/const DIFF_FALLBACK = \{([\s\S]*?)\n\};/);
if (inlineBlock) {
  for (const match of inlineBlock[1].matchAll(/(inlineDiff\w+):\s*\{([\s\S]*?)\n?\s*\},?/g)) {
    const en = match[2].match(/\ben:\s*'((?:\\.|[^'\\])*)'/);
    if (en) ui[`inline:${match[1]}`] = Function(`return '${en[1]}'`)();
  }
}

const omniSource = read('vendor/omni-viewer/workbench-page.mjs');
const omniBlock = omniSource.match(/export const WORKBENCH_I18N = \{([\s\S]*?)\n\};/);
if (omniBlock) {
  for (const match of omniBlock[1].matchAll(/(\w+):\s*\[([^\]]*)\]/g)) {
    try {
      const values = Function(`return [${match[2]}]`)();
      if (typeof values[2] === 'string') ui[`omni:${match[1]}`] = values[2];
    } catch {}
  }
}

const omniClient = read('vendor/omni-viewer/omni-client.js');
const omniFb = omniClient.match(/const FALLBACK_ROWS = \{([\s\S]*?)\n  \};/);
if (omniFb) {
  for (const match of omniFb[1].matchAll(/(\w+):\s*\[([^\]]*)\]/g)) {
    try {
      const values = Function(`return [${match[2]}]`)();
      if (typeof values[2] === 'string') ui[`omniClient:${match[1]}`] = values[2];
    } catch {}
  }
}

function pipeEnglish(file, marker, prefix) {
  const source = read(file);
  const start = source.indexOf(marker);
  const end = source.indexOf('\n  };', start);
  const block = start >= 0 && end > start ? source.slice(start, end) : '';
  const english = block.match(/\ben:\s*'((?:\\.|[^'\\])*)'/);
  if (!english) return;
  Function(`return '${english[1]}'`)().split('|').forEach((value, i) => { ui[`${prefix}:${i}`] = value; });
}
pipeEnglish('context-menu-btw.js', 'const I18N = {', 'context');
pipeEnglish('host-workbench-enhancer.js', 'const UI_RAW = {', 'workbench');

const effortSource = read('vendor/effort-slider/upstream-client.js');
for (const [table, name] of [['SET_TITLE_I18N', 'settingsTitle'], ['SET_HEAD_I18N', 'settingsHeading'], ['FIXED_I18N', 'fixed'], ['EFFORT_TITLE_I18N', 'effortTitle']]) {
  const line = effortSource.match(new RegExp(`var ${table}\\s*=\\s*\\{([^}]+)\\}`));
  const en = line?.[1].match(/\ben:\s*"([^"]*)"/);
  if (en) ui[`effort:${name}`] = en[1];
}

const usageSource = read('usage-core.js');
for (const match of usageSource.matchAll(/\['([^']+)',\s*\d+,\s*\[([^\]]+)\]\]/g)) {
  try {
    const labels = Function(`return [${match[2]}]`)();
    if (typeof labels[2] === 'string') ui[`usage:homeRange:${match[1]}`] = labels[2];
  } catch {}
}

function pipeRow(source, langKey) {
  const re = new RegExp(`${langKey}:\\s*\\n?\\s*'((?:\\\\.|[^'\\\\])*)'`);
  const m = source.match(re);
  if (!m) return null;
  return Function(`return '${m[1]}'`)();
}

const wall = read('vendor/wallpaper/wallpaper-settings-ui.js');
const wallEn = pipeRow(wall, 'en');
const wallKeys = wall.match(/const I18N_KEYS = '([^']+)'/);
if (wallEn && wallKeys) {
  const keys = wallKeys[1].split('|');
  wallEn.split('|').forEach((value, i) => { ui[`wallpaper:${keys[i] || i}`] = value; });
}

const sugg = read('vendor/prompt-suggester/suggester-settings-ui.js');
const suggEn = pipeRow(sugg, 'en');
const suggKeys = sugg.match(/const I18N_KEYS = '([^']+)'/);
if (suggEn && suggKeys) {
  const keys = suggKeys[1].split('|');
  suggEn.split('|').forEach((value, i) => { ui[`suggester:${keys[i] || i}`] = value; });
}

const thoughtClient = read('vendor/thought-translator/thought-client.js');
const thoughtEn = thoughtClient.match(/\ben: '([^']*)'\.split\('\|'\)/);
if (thoughtEn) thoughtEn[1].split('|').forEach((value, i) => { ui[`thoughtClient:${i}`] = value; });

['Analyzed', 'Searched', 'Ran', 'Running', 'Edited', 'Viewed', 'Explored', 'Created', 'Updated', 'Deleted', 'Listed', 'Checked']
  .forEach((value, i) => { ui[`verb:${i}`] = value; });

const thoughtSet = read('vendor/thought-translator/thought-settings-ui.js');
const thoughtSetEn = pipeRow(thoughtSet, 'en');
if (thoughtSetEn) thoughtSetEn.split('|').forEach((value, i) => { ui[`thoughtSettings:${i}`] = value; });

const prompts = read('vendor/thought-translator/translator-service.mjs');
const enPrompt = prompts.match(/en: Object\.freeze\(\{([\s\S]*?)\n  \}\),/);
if (enPrompt) {
  for (const m of enPrompt[1].matchAll(/(technical|concise):\s*\n?\s*'((?:\\.|[^'\\])*)'/g)) {
    ui[`prompt:${m[1]}`] = Function(`return '${m[2]}'`)();
  }
}
const langName = prompts.match(/en:\s*'([^']*English[^']*)'/);
if (langName) ui['prompt:langName'] = langName[1];

function extractObjectLiteral(source, marker) {
  const start = source.indexOf(marker);
  if (start < 0) return null;
  const brace = source.indexOf('{', start);
  let depth = 0, quote = '', escaped = false;
  for (let i = brace; i < source.length; i++) {
    const ch = source[i];
    if (quote) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === quote) quote = '';
    } else if (ch === "'" || ch === '"') quote = ch;
    else if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (!depth) return source.slice(brace, i + 1);
    }
  }
  return null;
}

const pp = read('vendor/periodic-picker/periodic-picker.js');
const ppEn = extractObjectLiteral(pp, 'en: { tierOrch:');
if (ppEn) {
  const obj = Function(`return (${ppEn})`)();
  for (const [k, v] of Object.entries(obj)) {
    if (Array.isArray(v)) v.forEach((item, i) => { ui[`pp:${k}:${i}`] = item; });
    else ui[`pp:${k}`] = v;
  }
}

const bento = read('vendor/periodic-picker/bento-ui.js');
const bentoEn = extractObjectLiteral(bento, 'en:{') || extractObjectLiteral(bento, 'en: {');
if (bentoEn) {
  try {
    const obj = Function(`return (${bentoEn})`)();
    const walk = (node, prefix) => {
      if (typeof node === 'string') ui[prefix] = node;
      else if (Array.isArray(node)) node.forEach((item, i) => walk(item, `${prefix}:${i}`));
      else if (node && typeof node === 'object') {
        for (const [k, v] of Object.entries(node)) walk(v, prefix ? `${prefix}.${k}` : `bento:${k}`);
      }
    };
    walk(obj, 'bento');
  } catch (err) {
    console.error('bento extract failed', err.message);
  }
}

ui['oled:nonPlanner'] = 'NON-PLANNER · LOCKED IN ORCH';
ui['oled:standbyAux'] = 'STANDBY · RESERVED MACRO SLOT';
ui['oled:synced'] = 'SYNCED';

const suggClient = read('vendor/prompt-suggester/suggester-client.js');
const acceptEn = suggClient.match(/en:\s*\{\s*accept:\s*'([^']*)'/);
if (acceptEn) ui['suggesterClient:accept'] = acceptEn[1];

const pulse = read('vendor/pulse-dashboard/inline-fallback.js');
const pulseEn = pulse.match(/\ben:'([^']*)'/);
if (pulseEn) pulseEn[1].split('|').forEach((value, i) => { ui[`pulse:${i}`] = value; });

const bridge = read('pulse-vial-bridge.js');
const mL0 = bridge.match(/,L0=Z\('([^']+)'\.replace/);
if (mL0) {
  const rows = mL0[1].replace(/~/g, '/compact').replace(/\^/g, 'Swarm/').split('|').map((r) => {
    let p = '';
    return r.split(',').map((c) => (p = c || p));
  });
  rows.forEach((row, i) => { ui[`vial:${i}`] = row[2] || ''; });
}

const home = read('home-studio-panel.js');
const homeEn = home.match(/^en\|([^\n]*)/m);
if (homeEn) homeEn[1].split('|').forEach((value, i) => { ui[`home:${i}`] = value; });

const greetSrc = read('vendor/sidebar-studio/state-machine.mjs');
function slicePool(marker) {
  const start = greetSrc.indexOf(marker);
  const end = greetSrc.indexOf('\n  }),', start);
  return start >= 0 && end > start ? greetSrc.slice(start, end + 5) : '';
}
const greetEn = slicePool('  en: Object.freeze({\n    withUser:');
const heroEn = slicePool("  en: Object.freeze({\n    eyebrowWithUser:");
if (greetEn) {
  const obj = Function(`return ({${greetEn}})`)();
  obj.en.withUser.forEach((v, i) => { ui[`greet:withUser:${i}`] = v; });
  obj.en.anonymous.forEach((v, i) => { ui[`greet:anon:${i}`] = v; });
}
if (heroEn) {
  const obj = Function(`return ({${heroEn}})`)();
  obj.en.eyebrowWithUser.forEach((v, i) => { ui[`hero:eyeUser:${i}`] = v; });
  obj.en.eyebrowAnonymous.forEach((v, i) => { ui[`hero:eyeAnon:${i}`] = v; });
  obj.en.headlines.forEach((v, i) => { ui[`hero:head:${i}`] = v; });
}

const uiFiles = writeChunks('ui', ui);

function hintFor(regex) {
  let groupIndex = 0;
  let hint = String(regex)
    .replace(/^\^|\$$/g, '')
    .replace(/\((?!\?)(?:\\.|[^)])*\)/g, () => `$${++groupIndex}`)
    .replace(/\\s\*/g, ' ')
    .replace(/\\s\+/g, ' ')
    .replace(/\\d\+/g, 'number')
    .replace(/\[A-Za-z0-9_.+\-\\]+?\+/g, 'text')
    .replace(/\\n/g, ' ')
    .replace(/\\\./g, '.')
    .replace(/\\-/g, '-')
    .replace(/[?*]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (!hint || /[\[\\{}]/.test(hint)) hint = `English text matching this pattern: ${hint || regex}`;
  return { hint, groups: groupIndex };
}

const host = JSON.parse(read('vendor/host-i18n/zh-CN.json'));
const exact = Object.fromEntries(Object.keys(host.exact || {}).map((key) => [`exact:${key}`, key]));
const exactFiles = writeChunks('host-exact', exact);
const patterns = {};
for (const [i, item] of (host.patterns || []).entries()) {
  const id = `pattern:${String(i + 1).padStart(4, '0')}`;
  const hinted = hintFor(item.regex);
  patterns[id] = { regex: item.regex, groups: hinted.groups, en_hint: hinted.hint };
}
const patternFiles = writeChunks('host-patterns', patterns);

const swarm = JSON.parse(read('vendor/host-i18n/swarm-zh-CN.json'));
const swarmEntries = {};
for (const key of Object.keys(swarm.exact || {})) swarmEntries[`swarm-exact:${key}`] = key;
for (const [i, item] of (swarm.patterns || []).entries()) {
  const hinted = hintFor(item.regex);
  swarmEntries[`swarm-pattern:${String(i + 1).padStart(4, '0')}`] = { regex: item.regex, groups: hinted.groups, en_hint: hinted.hint };
}
for (const [i, item] of (swarm.optionPatterns || []).entries()) {
  const hinted = hintFor(item.regex);
  swarmEntries[`swarm-option:${String(i + 1).padStart(4, '0')}`] = { regex: item.regex, groups: hinted.groups, en_hint: hinted.hint };
}
for (const [key, value] of Object.entries(swarm.protectedUiKeys || {})) swarmEntries[`protected:${key}`] = typeof value === 'string' ? value : key;
const swarmFiles = writeChunks('swarm', swarmEntries);

const manifest = {
  ui: Object.keys(ui).length,
  exact: Object.keys(exact).length,
  patterns: Object.keys(patterns).length,
  swarm: Object.keys(swarmEntries).length,
  files: [...uiFiles, ...exactFiles, ...patternFiles, ...swarmFiles],
};
fs.writeFileSync(path.join(outDir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(JSON.stringify(manifest, null, 2));
