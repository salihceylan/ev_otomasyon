// FIN: LIVE_BASE -> LIVE farkini 01/03/04 yamalarina boler (platform/gitignore YOK: Firebase'siz karar).
// Hepsi LF-normalize `git diff --no-index` ciktisidir; a/ b/ onekleri depo kokune goredir. pubspec.lock paket disidir.
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const SP = 'C:/Users/FINGON~1/AppData/Local/Temp/claude/g--site-site-kapi-kontrol/a379bdb3-93a0-4167-8a2c-eed43f0e926f/scratchpad';
const BASE = SP + '/flutter_live_base2';
const LIVE = SP + '/flutter_live2';
const CMP = SP + '/fin_cmp';
const OUT = 'G:/site/ev_otomasyon/docs/superpowers/analysis/wp-h-flutter/yamalar';
const SKIP_DIRS = new Set(['.dart_tool', 'build', '.plugin_symlinks', '.gradle', '.kotlin', 'ephemeral', '.git', 'node_modules']);
const SKIP_FILES = new Set(['pubspec.lock', '.flutter-plugins-dependencies', '.flutter-plugins']);

function walk(root, rel = '', acc = []) {
  for (const e of fs.readdirSync(path.join(root, rel), { withFileTypes: true })) {
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      walk(root, rel ? rel + '/' + e.name : e.name, acc);
    } else if (e.isFile()) {
      if (SKIP_FILES.has(e.name)) continue;
      acc.push(rel ? rel + '/' + e.name : e.name);
    }
  }
  return acc;
}
const norm = (p) => fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n');
const baseFiles = new Set(walk(BASE));
const liveFiles = walk(LIVE);
const changed = [];
for (const rel of liveFiles) {
  if (!baseFiles.has(rel)) { changed.push({ rel, isNew: true }); continue; }
  if (norm(BASE + '/' + rel) !== norm(LIVE + '/' + rel)) changed.push({ rel, isNew: false });
}
for (const rel of baseFiles) if (!fs.existsSync(LIVE + '/' + rel)) { console.log('HATA: LIVE\'da silinmis', rel); process.exit(1); }

function group(f) {
  const r = f.rel;
  if (r === 'lib/ui/app_shell.dart') return '04-app-shell';
  if (r.startsWith('android/') || r.startsWith('ios/') || r === '.gitignore') return 'PLATFORM-YOK';
  if (f.isNew) return '01-yeni-dosyalar';
  return '03-mevcut-dosyalar';
}
const groups = {};
for (const f of changed) (groups[group(f)] ||= []).push(f);
if (groups['PLATFORM-YOK']) {
  console.log('HATA: platform/.gitignore degisikligi paketten CIKARILMALIYDI:', groups['PLATFORM-YOK'].map((f) => f.rel).join(', '));
  process.exit(1);
}

fs.mkdirSync(OUT, { recursive: true });
fs.rmSync(CMP, { recursive: true, force: true });
const summary = {};
for (const [name, files] of Object.entries(groups).sort()) {
  files.sort((a, b) => a.rel.localeCompare(b.rel));
  const cdir = CMP + '/' + name;
  for (const f of files) {
    if (!f.isNew) {
      const dst = path.join(cdir, 'a', f.rel);
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      fs.writeFileSync(dst, norm(BASE + '/' + f.rel));
    }
    const dst = path.join(cdir, 'b', f.rel);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.writeFileSync(dst, norm(LIVE + '/' + f.rel));
  }
  fs.mkdirSync(path.join(cdir, 'a'), { recursive: true });
  const r = spawnSync('git', ['-c', 'core.autocrlf=false', 'diff', '--no-index', '--no-color', name === '01-yeni-dosyalar' ? '-U3' : '-U1', 'a', 'b'], { cwd: cdir, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (r.status !== 1 && r.status !== 0) throw new Error('git diff hata: ' + r.stderr);
  const fixed = r.stdout.split('\n').map((line) => {
    if (line.startsWith('diff --git ')) return line.replace(/^diff --git a\/[ab]\/(.*) b\/b\/(.*)$/, 'diff --git a/$1 b/$2');
    if (line.startsWith('--- a/a/')) return '--- a/' + line.slice('--- a/a/'.length);
    if (line.startsWith('+++ b/b/')) return '+++ b/' + line.slice('+++ b/b/'.length);
    return line;
  }).join('\n');
  fs.writeFileSync(`${OUT}/${name}.patch`, fixed);
  summary[name] = files.map((f) => (f.isNew ? 'YENI ' : 'DEGISEN ') + f.rel);
  console.log(name, files.length, 'dosya,', Buffer.byteLength(fixed), 'bayt');
}
fs.writeFileSync(SP + '/wp-h-flutter-wf/FIN-patch-dosya-listesi.json', JSON.stringify(summary, null, 1));
for (const [k, v] of Object.entries(summary)) { console.log('== ' + k); for (const l of v) console.log('  ' + l); }
