// FIN: LF olarak yazilan belge taslaklarini (fin_docs/*.lf) CRLF'e cevirip PAKET'e yazar (mevcut belgeler CRLF'ti: korunur).
const fs = require('fs');
const WF = 'C:/Users/FINGON~1/AppData/Local/Temp/claude/g--site-site-kapi-kontrol/a379bdb3-93a0-4167-8a2c-eed43f0e926f/scratchpad/wp-h-flutter-wf';
const PAKET = 'G:/site/ev_otomasyon/docs/superpowers/analysis/wp-h-flutter';

for (const name of ['ENTEGRASYON.md', 'README.md', 'PUSH_KURULUM.md']) {
  const src = `${WF}/fin_docs/${name}.lf`;
  const dst = `${PAKET}/${name}`;
  const lf = fs.readFileSync(src, 'utf8');
  if (lf.includes('\r')) throw new Error(`${src}: CR var (LF bekleniyordu)`);
  const old = fs.readFileSync(dst);
  let oldCrlf = 0; for (let i = 0; i < old.length; i++) if (old[i] === 0x0d) oldCrlf++;
  const oldLf = old.toString('utf8').split('\n').length - 1;
  if (oldCrlf !== oldLf) throw new Error(`${dst}: eski dosya tam CRLF degil (${oldCrlf}/${oldLf})`);
  fs.writeFileSync(dst, lf.replace(/\n/g, '\r\n'));
  console.log('yazildi (CRLF):', name, `${lf.split('\n').length - 1} satir`);
}

// Arsiv rehberde eski yol atfi: docs/ENTEGRASYON.md -> ENTEGRASYON.md (ayni dizin). CRLF aynen korunur.
const arsiv = `${PAKET}/PUSH_KURULUM_ARSIV.md`;
let s = fs.readFileSync(arsiv, 'utf8');
const n = s.split('docs/ENTEGRASYON.md').length - 1;
if (n === 0) {
  console.log('PUSH_KURULUM_ARSIV.md: eski atif yok (zaten guncel)');
} else {
  s = s.split('docs/ENTEGRASYON.md').join('ENTEGRASYON.md');
  fs.writeFileSync(arsiv, s);
  console.log(`guncellendi: PUSH_KURULUM_ARSIV.md (${n} atif)`);
}
