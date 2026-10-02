// Calisma zamani sirlari (lib/secrets.js): her `up` DONEN sirlari (JWT, admin API anahtari, MQTT arka uc, EMQX, SMTP) yeniler;
// veriye bagli sirlar (db_password, pin_pepper, local_key_secret) pgdata ile birlikte yasar; `--keep-secrets` hicbirini yenilemez.
// docs/QA_STACK.md §1: JWT sirri degisince eski access token'lar gecersiz olur; --keep-secrets oturumlari korur.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { runtimePaths } from '../lib/paths.js';
import { DATA_BOUND, ROTATING, loadOrCreateSecrets } from '../lib/secrets.js';
import { tmpDir } from './_helpers.js';

test('secrets: ilk up hepsini uretir; ikinci up DONEN sirlari yeniler, veriye bagli sirlari korur', () => {
  const dir = tmpDir('qa_secrets_');
  try {
    const rt = runtimePaths(dir);
    const a = loadOrCreateSecrets(rt);
    assert.equal(a.created, true);
    for (const k of [...DATA_BOUND, ...ROTATING]) assert.ok(a.secrets[k] && a.secrets[k].length >= 12, `${k} uretilmedi`);
    assert.ok(a.secrets.jwt_secret.length >= 32 && a.secrets.pin_pepper.length >= 32, 'sunucu en az 32 karakter ister');

    const b = loadOrCreateSecrets(rt);
    assert.equal(b.created, false);
    assert.deepEqual(b.rotated.sort(), [...ROTATING].sort(), 'donen sirlarin HEPSI yenilenir');
    for (const k of ROTATING) assert.notEqual(b.secrets[k], a.secrets[k], `${k} degismeliydi (eski oturumlar/kimlikler gecersiz olur)`);
    for (const k of DATA_BOUND) assert.equal(b.secrets[k], a.secrets[k], `${k} pgdata'ya bagli: degismemeli`);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('secrets: --keep-secrets HICBIR sirri yenilemez (JWT dahil: oturumlar korunur)', () => {
  const dir = tmpDir('qa_secrets_keep_');
  try {
    const rt = runtimePaths(dir);
    const a = loadOrCreateSecrets(rt);
    const b = loadOrCreateSecrets(rt, { keepSecrets: true });
    assert.deepEqual(b.rotated, []);
    for (const k of [...DATA_BOUND, ...ROTATING]) assert.equal(b.secrets[k], a.secrets[k], k);
    // dosyaya da ayni degerler yazilir
    const onDisk = JSON.parse(fs.readFileSync(path.join(dir, 'secrets.json'), 'utf8'));
    assert.equal(onDisk.jwt_secret, a.secrets.jwt_secret);
    // keepSecrets olsa bile eksik bir donen sir uretilir (eski/bozuk dosya)
    delete onDisk.smtp_pass;
    fs.writeFileSync(path.join(dir, 'secrets.json'), JSON.stringify(onDisk));
    const c = loadOrCreateSecrets(rt, { keepSecrets: true });
    assert.deepEqual(c.rotated, ['smtp_pass']);
    assert.equal(c.secrets.jwt_secret, a.secrets.jwt_secret);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
