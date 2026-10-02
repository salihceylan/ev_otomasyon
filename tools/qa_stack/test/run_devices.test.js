// run_devices.js: tek surecte birden fazla simulator (farkli HTTP portlari), kimlik/durum yalitimi.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { DeviceFleet, defaultPlan } from '../sim/run_devices.js';
import { freePort, waitFor } from '../lib/util.js';
import { tmpDir } from './_helpers.js';

const get = async (port, p, key) => {
  const r = await fetch(`http://127.0.0.1:${port}${p}`, { headers: key ? { 'X-Device-Key': key } : {} });
  return { status: r.status, json: await r.json().catch(() => null) };
};

test('fleet: 3 simulator farkli portlarda, kimlik ve durumlar birbirinden yalitilmis', async () => {
  const dir = tmpDir();
  const base = await freePort();
  const fleet = new DeviceFleet({ stateDir: dir });
  try {
    const plan = defaultPlan({ basePort: base, timeScale: 50 });
    // varsayilan planda 3 cihaz ve portlar ardisik
    assert.deepEqual(plan.map((p) => p.httpPort), [base, base + 1, base + 2]);
    assert.deepEqual(plan.map((p) => p.uid), ['AHBU-S3-0A0001', 'AHBU-S3-0A0002', 'AHBU-S3-0A0003']);
    assert.deepEqual(plan.map((p) => p.relays), [8, 8, 16]);
    assert.equal(plan.filter((p) => p.localKey).length, 1, 'yalniz hazir cihaz provizyonlu');

    for (const { name, ...opts } of plan) fleet.add(name, { ...opts, bootHoldMs: 0 });
    await fleet.startAll();
    const list = fleet.list();
    assert.equal(list.length, 3);
    assert.equal(new Set(list.map((d) => d.http_port)).size, 3);

    const key = plan[1].localKey;
    const a = await get(base, '/api/status');
    const b = await get(base + 1, '/api/status');
    const c = await get(base + 2, '/api/status');
    assert.equal(a.json.device, 'AHBU-S3-0A0001');
    assert.equal(a.json.provisioned, false);
    assert.equal(b.json.device, 'AHBU-S3-0A0002');
    assert.equal(b.json.provisioned, true);
    assert.equal(c.json.device, 'AHBU-S3-0A0003');
    assert.equal(c.json.provisioned, false);

    // hazir cihaz: dogru anahtarla tam durum; baskasinin anahtari kabul edilmez
    assert.equal((await get(base + 1, '/api/config', key)).status, 200);
    assert.equal((await get(base, '/api/config', key)).status, 403, 'new1 provizyonsuz');
    assert.equal((await get(base + 2, '/api/status', key)).json.provisioned, false);
    assert.equal((await get(base + 1, '/api/status', key)).json.total_relays, 8);

    // new2 provizyonlanir -> yalniz o degisir, 16 role
    const init = await fetch(`http://127.0.0.1:${base + 2}/api/factory/init`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ local_key: 'new2-key-123456', ap_pass: 'ap-pass-12345' }),
    });
    assert.equal(init.status, 200);
    assert.equal((await get(base + 2, '/api/status', 'new2-key-123456')).json.total_relays, 16);
    assert.equal((await get(base, '/api/status')).json.provisioned, false, 'new1 etkilenmedi');

    // kalici durum dosyalari cihaz basina ayri
    await fleet.stopAll();
    const files = fs.readdirSync(dir).sort();
    assert.deepEqual(files, ['AHBU-S3-0A0001.json', 'AHBU-S3-0A0002.json', 'AHBU-S3-0A0003.json']);
    const nvs = (f) => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
    assert.equal(nvs('AHBU-S3-0A0003.json').cfg.lk, 'new2-key-123456');
    assert.equal(nvs('AHBU-S3-0A0001.json').cfg.lk, '');

    // portlar kapandi
    await assert.rejects(fetch(`http://127.0.0.1:${base}/api/status`));
  } finally {
    await fleet.stopAll();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('fleet: ayni UID veya ayni port ikinci kez eklenemez; baslatma hatasinda baslatilanlar durdurulur', async () => {
  const fleet = new DeviceFleet();
  const p = await freePort();
  fleet.add('a', { uid: 'AHBU-DUP-1', httpPort: p });
  assert.throws(() => fleet.add('b', { uid: 'AHBU-DUP-1', httpPort: p + 1 }), /UID zaten/);
  assert.throws(() => fleet.add('c', { uid: 'AHBU-DUP-3', httpPort: p }), /portu zaten/);
  assert.throws(() => fleet.add('a', { uid: 'AHBU-DUP-4', httpPort: p + 5 }), /adi zaten/);

  // dolu bir port: ikinci cihaz baslayamaz -> hata ve ilk cihaz da kapanir
  const blocker = await freePort();
  const net = await import('node:net');
  const srv = net.createServer().listen(blocker, '127.0.0.1');
  await new Promise((r) => srv.once('listening', r));
  const f2 = new DeviceFleet();
  const ok = await freePort();
  f2.add('ok', { uid: 'AHBU-OK-1', httpPort: ok });
  f2.add('busy', { uid: 'AHBU-BUSY-1', httpPort: blocker });
  await assert.rejects(f2.startAll(), /EADDRINUSE/);
  await assert.rejects(fetch(`http://127.0.0.1:${ok}/api/status`), 'baslatilan cihaz da kapatildi');
  srv.close();
});

test('CLI: node sim/device_sim.js bagimsiz surec olarak calisir; gecersiz UID cikis kodu 2', async () => {
  const port = await freePort();
  const sim = path.resolve(import.meta.dirname, '../sim/device_sim.js');
  const child = spawn(process.execPath, [sim, '--uid', 'AHBU-S3-0A00CC', '--http-port', String(port), '--local-key', 'cli-key-123456', '--time-scale', '10', '--relays', '16'], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  child.stdout.on('data', (d) => { out += d.toString(); });
  child.stderr.on('data', (d) => { out += d.toString(); });
  try {
    await waitFor(async () => (await get(port, '/api/status', 'cli-key-123456').catch(() => ({ status: 0 }))).status === 200, { timeoutMs: 8000, label: `CLI cihaz acilmadi: ${out}` });
    const st = (await get(port, '/api/status', 'cli-key-123456')).json;
    assert.equal(st.device, 'AHBU-S3-0A00CC');
    assert.equal(st.total_relays, 16);
    assert.match(out, /\[sim\] AHBU-S3-0A00CC http:\/\/127\.0\.0\.1:/);
  } finally {
    child.kill();
  }
  const bad = spawn(process.execPath, [sim, '--uid', 'yanlis'], { stdio: ['ignore', 'pipe', 'pipe'] });
  const code = await new Promise((resolve) => bad.on('exit', resolve));
  assert.equal(code, 2, 'gecersiz UID -> cikis kodu 2');
});
