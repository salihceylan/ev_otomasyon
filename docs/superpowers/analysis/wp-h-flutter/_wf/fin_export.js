// FIN adim 5: LIVE'daki 25 yeni dosyayi PAKET altina .txt olarak BIREBIR aktarir ve bayt bayt karsilastirir.
const fs = require('fs');
const path = require('path');
const SP = 'C:/Users/FINGON~1/AppData/Local/Temp/claude/g--site-site-kapi-kontrol/a379bdb3-93a0-4167-8a2c-eed43f0e926f/scratchpad';
const LIVE = SP + '/flutter_live2';
const PAKET = 'G:/site/ev_otomasyon/docs/superpowers/analysis/wp-h-flutter';
const list = JSON.parse(fs.readFileSync(SP + '/wp-h-flutter-wf/FIN-patch-dosya-listesi.json', 'utf8'))['01-yeni-dosyalar']
  .map((l) => l.replace(/^YENI /, ''));
if (list.length !== 25) throw new Error('25 dosya bekleniyordu: ' + list.length);

const expected = new Set();
let ok = 0;
for (const rel of list) {
  const src = `${LIVE}/${rel}`;
  const dst = `${PAKET}/${rel}.txt`;
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(src, dst);
  expected.add(path.normalize(dst));
  const a = fs.readFileSync(src);
  const b = fs.readFileSync(dst);
  if (!a.equals(b)) { console.log('FARKLI:', rel); process.exitCode = 1; } else ok++;
}
console.log(`${ok}/${list.length} dosya bayt bayt AYNI (cmp esdegeri)`);

// PAKET/lib ve PAKET/test altinda beklenmeyen (eski) .txt var mi?
function walk(dir, acc = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, acc); else acc.push(p);
  }
  return acc;
}
let extra = 0;
for (const top of ['lib', 'test']) {
  for (const f of walk(`${PAKET}/${top}`)) {
    if (!expected.has(path.normalize(f))) { console.log('BEKLENMEYEN dosya:', f); extra++; }
  }
}
console.log('beklenmeyen .txt sayisi:', extra);
