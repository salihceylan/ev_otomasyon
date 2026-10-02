// Tum .js dosyalarinda soz dizimi kontrolu (node --check). CI/yerel dogrulama icin.
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

function walk(dir, out = []) {
  for (const name of fs.readdirSync(dir)) {
    if (name === 'node_modules' || name.startsWith('.')) continue;
    const full = path.join(dir, name);
    const st = fs.statSync(full);
    if (st.isDirectory()) walk(full, out);
    else if (name.endsWith('.js')) out.push(full);
  }
  return out;
}

let failed = 0;
for (const file of walk(path.join(__dirname, '..'))) {
  try {
    execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' });
  } catch (e) {
    failed++;
    console.error('SOZ DIZIMI HATASI:', file, '\n', String(e.stderr || e.message));
  }
}
if (failed > 0) {
  console.error(`${failed} dosyada soz dizimi hatasi var.`);
  process.exit(1);
}
console.log('Soz dizimi kontrolu: tum dosyalar temiz.');
