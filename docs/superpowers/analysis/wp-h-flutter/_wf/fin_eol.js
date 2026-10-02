// FIN: dosyalarin satir sonu (CRLF / LF) sayimi. Kullanim: node fin_eol.js <dosya> [<dosya> ...]
const fs = require('fs');
for (const f of process.argv.slice(2)) {
  if (!fs.existsSync(f)) { console.log('YOK      ', f); continue; }
  const s = fs.readFileSync(f);
  let crlf = 0, lf = 0, cr = 0;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === 0x0d) { if (s[i + 1] === 0x0a) { crlf++; i++; } else cr++; }
    else if (s[i] === 0x0a) lf++;
  }
  const bom = s.length >= 3 && s[0] === 0xef && s[1] === 0xbb && s[2] === 0xbf;
  const lastNl = s.length > 0 && s[s.length - 1] === 0x0a;
  console.log(`CRLF=${crlf} LF=${lf} CR=${cr} bom=${bom} sonNewline=${lastNl}`.padEnd(48), f);
}
