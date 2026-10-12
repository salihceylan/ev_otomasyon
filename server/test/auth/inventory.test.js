'use strict';

// A8 + A11: envanter erisim kapisi ve envanter servisi.
//  - Kod icinde varsayilan API anahtari YOK; ADMIN_API_KEY yoksa/kisaysa yol KAPALI
//  - Kullanici parolasi API anahtari olarak KABUL EDILMEZ
//  - JWT super_user birincil; staff yalnizca kendi stogunu listeler
//  - durum gecis matrisi; CLAIMED/bagli cihaz silinemez; PIN ozeti; local_key bir kez

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');
const bcrypt = require('bcryptjs');
const { setTestEnv, installFakeDb, makeAccessToken, makeServiceToken } = require('./_helpers');

setTestEnv({ LOCAL_KEY_SECRET: crypto.randomBytes(32).toString('hex') });
const fakeDb = installFakeDb();

const auth = require('../../src/middlewares/auth_middleware');
const inventoryRoutes = require('../../src/routes/inventory_routes');
const inventoryService = require('../../src/services/inventory_service');
const apiKeyMw = require('../../src/middlewares/admin_api_key_middleware');
const secretBox = require('../../src/utils/secret_box');
const pin = require('../../src/utils/pin');
const { errorHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });

// ---- kucuk bellek ici model ----
const users = new Map();
const staffHomes = new Map(); // userId -> Set(homeId)
const devices = new Map(); // uuid -> inventory row
const attachedDevices = new Set(); // devices tablosunda home_id dolu
function addUser(fields) {
  const u = { id: crypto.randomUUID(), email: 'x@test.invalid', full_name: 'x', role: 'user', is_active: true, account_status: 'active', token_version: 1, ...fields };
  users.set(u.id, u);
  return u;
}
function addDevice(uuid, fields = {}) {
  const d = { id: crypto.randomUUID(), serial_no: String(devices.size + 1), device_uuid: uuid, mac_address: `AA:BB:CC:00:00:${String(devices.size).padStart(2, '0')}`, model: 'M', batch_no: 'B', status: 'IN_STOCK', claimed_home_id: null, claimed_by_user_id: null, pin_hash: 'x', local_key_enc: 'y', ...fields };
  devices.set(uuid, d);
  return d;
}
// 045: servis kapsami = kartin KENDI stogu (device_inventory.service_owner_id)
const inScope = (d, staffId) => d.service_owner_id === staffId;

fakeDb.on(/[\s\S]*/, (p, t) => {
  if (/FROM users\s+WHERE id = \$1/.test(t)) return users.has(p[0]) ? [{ ...users.get(p[0]) }] : [];
  if (/SELECT id, home_id, technician_name, expires_at, revoked_at\s+FROM service_sessions/.test(t)) return [{ id: p[0], home_id: SVC_HOME, technician_name: 't', expires_at: new Date(Date.now() + 3600e3), revoked_at: null }];
  if (/SELECT device_uuid, mac_address FROM device_inventory WHERE device_uuid = \$1 OR mac_address = \$2/.test(t)) {
    return [...devices.values()].filter((d) => d.device_uuid === p[0] || d.mac_address === p[1]);
  }
  if (/INSERT INTO device_inventory/.test(t)) {
    const d = addDevice(p[0], { mac_address: p[1], pin_hash: p[2], local_key_enc: p[3], model: p[4], batch_no: p[5], service_owner_id: p[6] || null });
    return [{ id: d.id, serial_no: d.serial_no, device_uuid: d.device_uuid, mac_address: d.mac_address, model: d.model, batch_no: d.batch_no, status: d.status, service_owner_id: d.service_owner_id, created_at: new Date() }];
  }
  if (/FROM device_inventory di\s+WHERE di\.device_uuid = \$1/.test(t) && /FOR UPDATE OF di/.test(t)) {
    const d = devices.get(p[0]);
    return d ? [{ id: d.id, status: d.status, claimed_home_id: d.claimed_home_id, service_owner_id: d.service_owner_id || null, attached: attachedDevices.has(d.device_uuid) ? 1 : 0 }] : [];
  }
  if (/FROM device_inventory di\s+WHERE di\.device_uuid = \$1/.test(t)) {
    const d = devices.get(p[0]);
    if (!d) return [];
    if (p.length > 1 && !inScope(d, p[1])) return [];
    return [{ ...d, pin_hash: undefined, local_key_enc: undefined }];
  }
  if (/UPDATE device_inventory\s+SET status = \$1/.test(t)) {
    const d = [...devices.values()].find((x) => x.id === p[1]);
    d.status = p[0];
    return [{ id: d.id, serial_no: d.serial_no, device_uuid: d.device_uuid, status: d.status }];
  }
  if (/DELETE FROM devices WHERE device_uuid = \$1 AND home_id IS NULL/.test(t)) return [];
  if (/DELETE FROM device_inventory WHERE id = \$1/.test(t)) {
    for (const [k, v] of devices) if (v.id === p[0]) devices.delete(k);
    return [];
  }
  if (/SELECT COUNT\(\*\)::int AS total FROM device_inventory di/.test(t)) {
    const staffId = /di\.service_owner_id = \$/.test(t) ? p[p.length - 1] : null;
    return [{ total: [...devices.values()].filter((d) => !staffId || inScope(d, staffId)).length }];
  }
  if (/FROM device_inventory di\s+LEFT JOIN homes h/.test(t)) {
    const staffId = /di\.service_owner_id = \$/.test(t) ? p[p.length - 3] : null;
    return [...devices.values()].filter((d) => !staffId || inScope(d, staffId)).map((d) => ({ ...d, pin_hash: undefined, local_key_enc: undefined }));
  }
  if (/COUNT\(\*\) FILTER/.test(t)) return [{ total: devices.size, in_stock: 0, claimed: 0, suspended: 0, revoked: 0 }];
  return [];
});

const SVC_HOME = crypto.randomUUID();
const superUser = addUser({ role: 'super_user', password_hash: bcrypt.hashSync('Super-Parola-Gizli-1', 4) });
const staff = addUser({ role: 'service_user' });
const staff2 = addUser({ role: 'service_user' });
const user = addUser({ role: 'user' });
const T = (u) => `Bearer ${makeAccessToken(u)}`;
const SVC = `Bearer ${makeServiceToken({ sid: crypto.randomUUID(), home_id: SVC_HOME })}`;

const app = express();
app.use(express.json());
app.use('/api/v1/admin/inventory', inventoryRoutes);
app.use(errorHandler);

const register = (headers, body) => {
  const r = request(app).post('/api/v1/admin/inventory/register');
  for (const [k, v] of Object.entries(headers)) r.set(k, v);
  return r.send(body);
};
let seq = 0;
const newBody = () => {
  seq += 1;
  return { device_uuid: `AHBU-S3-T${String(seq).padStart(4, '0')}`, mac_address: `e8f60a00${String(seq).padStart(4, '0')}`, pin: '246810' };
};

test.beforeEach(() => {
  delete process.env.ADMIN_API_KEY;
  apiKeyMw.badKeyLimiter.reset();
  inventoryService.setSecretBox(undefined);
});

test('API anahtari: ADMIN_API_KEY tanimli degilse yol KAPALI (her anahtar 401)', async () => {
  const r = await register({ 'X-Admin-Api-Key': crypto.randomBytes(24).toString('hex') }, newBody());
  assert.strictEqual(r.status, 401);
  assert.strictEqual(apiKeyMw.isApiKeyConfigured(), false);
});

test('API anahtari: 32 karakterden kisa ADMIN_API_KEY de yol kapali', async () => {
  process.env.ADMIN_API_KEY = 'k'.repeat(31);
  const r = await register({ 'X-Admin-Api-Key': 'k'.repeat(31) }, newBody());
  assert.strictEqual(r.status, 401);
});

test('API anahtari: super kullanici PAROLASI anahtar olarak kabul edilmez', async () => {
  const r = await register({ 'X-Admin-Api-Key': 'Super-Parola-Gizli-1' }, newBody());
  assert.strictEqual(r.status, 401);
  process.env.ADMIN_API_KEY = crypto.randomBytes(32).toString('hex');
  const r2 = await register({ 'X-Admin-Api-Key': 'Super-Parola-Gizli-1' }, newBody());
  assert.strictEqual(r2.status, 401);
});

test('API anahtari: gecerli anahtar kayit + listeleme yapar; durum/silme YAPAMAZ; yanlis anahtar JWT ye dusmez', async () => {
  const key = crypto.randomBytes(32).toString('hex');
  process.env.ADMIN_API_KEY = key;
  const r = await register({ 'X-Admin-Api-Key': key }, newBody());
  assert.strictEqual(r.status, 201, JSON.stringify(r.body));
  const list = await request(app).get('/api/v1/admin/inventory').set('X-Admin-Api-Key', key);
  assert.strictEqual(list.status, 200);
  const uuid = r.body.data.device.device_uuid;
  assert.strictEqual((await request(app).patch(`/api/v1/admin/inventory/${uuid}/status`).set('X-Admin-Api-Key', key).send({ status: 'SUSPENDED' })).status, 401);
  assert.strictEqual((await request(app).delete(`/api/v1/admin/inventory/${uuid}`).set('X-Admin-Api-Key', key)).status, 401);
  // yanlis anahtar + gecerli JWT: anahtar denemesi basarisiz sayilir, JWT'ye dusulmez
  const mixed = await register({ 'X-Admin-Api-Key': 'yanlis', Authorization: T(superUser) }, newBody());
  assert.strictEqual(mixed.status, 401);
});

test('API anahtari: gecersiz denemeler IP basina sinirlanir (429)', async () => {
  for (let i = 0; i < 10; i++) await register({ 'X-Admin-Api-Key': `yanlis-${i}` }, newBody());
  const r = await register({ 'X-Admin-Api-Key': 'yanlis-son' }, newBody());
  assert.strictEqual(r.status, 429);
});

test('JWT: kayit/durum/silme super_user ve servis sorumlusu (kendi kapsaminda); kullanici/servis oturumu 403; tokensiz 401', async () => {
  assert.strictEqual((await register({}, newBody())).status, 401);
  for (const who of [T(user), SVC]) {
    assert.strictEqual((await register({ Authorization: who }, newBody())).status, 403);
  }
  const d = addDevice('AHBU-S3-JWT1');
  for (const who of [T(user), SVC]) {
    assert.strictEqual((await request(app).patch(`/api/v1/admin/inventory/${d.device_uuid}/status`).set('Authorization', who).send({ status: 'SUSPENDED' })).status, 403);
    assert.strictEqual((await request(app).delete(`/api/v1/admin/inventory/${d.device_uuid}`).set('Authorization', who)).status, 403);
  }
  // Servis sorumlusu (045): KOK stogundaki karti yonetemez (404), kendi kaydettigi karti yonetir
  assert.strictEqual((await request(app).patch(`/api/v1/admin/inventory/${d.device_uuid}/status`).set('Authorization', T(staff)).send({ status: 'SUSPENDED' })).status, 404);
  assert.strictEqual((await request(app).delete(`/api/v1/admin/inventory/${d.device_uuid}`).set('Authorization', T(staff))).status, 404);
  assert.ok(devices.has('AHBU-S3-JWT1'), 'kok stogundaki kart silinmedi');
  assert.strictEqual(d.status, 'IN_STOCK');
  assert.strictEqual((await request(app).get('/api/v1/admin/inventory').set('Authorization', T(user))).status, 403);
  assert.strictEqual((await request(app).get('/api/v1/admin/inventory').set('Authorization', SVC)).status, 403);
  assert.strictEqual((await request(app).get(`/api/v1/admin/inventory/${d.device_uuid}`).set('Authorization', T(user))).status, 403);
  assert.strictEqual((await request(app).get(`/api/v1/admin/inventory/${d.device_uuid}`).set('Authorization', SVC)).status, 403);
});

test('kayit: PIN HMAC ozeti, local_key sifreli saklanir ve yanitta BIR KEZ doner; PIN li QR yalnizca bu yanitta', async () => {
  const body = newBody();
  const r = await register({ Authorization: T(superUser) }, body);
  assert.strictEqual(r.status, 201, JSON.stringify(r.body));
  assert.strictEqual(r.headers['cache-control'], 'no-store');
  const d = r.body.data;
  assert.match(d.local_key, /^[A-Za-z0-9]{16}$/);
  assert.ok(d.qr_claim_url.includes('pin=246810'));
  assert.strictEqual(d.device.mac_address, `E8:F6:0A:00:${body.mac_address.slice(8, 10)}:${body.mac_address.slice(10, 12)}`);
  const row = devices.get(body.device_uuid);
  assert.ok(pin.verifyPin('246810', row.pin_hash));
  assert.match(row.pin_hash, /^h1\$/);
  assert.notStrictEqual(row.local_key_enc, d.local_key);
  assert.strictEqual(secretBox.decrypt(row.local_key_enc), d.local_key);
  const get = await request(app).get(`/api/v1/admin/inventory/${body.device_uuid}`).set('Authorization', T(superUser));
  assert.strictEqual(get.status, 200);
  assert.ok(!('local_key' in get.body.data) && !get.body.data.pin_hash && !get.body.data.local_key_enc);
  const list = await request(app).get('/api/v1/admin/inventory').set('Authorization', T(superUser));
  assert.ok(list.body.data.items.every((i) => !i.qr_claim_url.includes('pin=') && !i.pin_hash && !i.local_key_enc));
});

test('kayit: dogrulama (UUID bicimi, MAC, 6 haneli PIN) ve cift kayit 409', async () => {
  const H = { Authorization: T(superUser) };
  assert.strictEqual((await register(H, { ...newBody(), device_uuid: 'BASKA-123' })).status, 400);
  assert.strictEqual((await register(H, { ...newBody(), mac_address: 'zz' })).status, 400);
  assert.strictEqual((await register(H, { ...newBody(), pin: '12345' })).status, 400);
  assert.strictEqual((await register(H, { ...newBody(), model: '<script>' })).status, 400);
  const b = newBody();
  assert.strictEqual((await register(H, b)).status, 201);
  assert.strictEqual((await register(H, b)).status, 409);
});

test('kayit: LOCAL_KEY_SECRET / secret_box yoksa 503 (anahtarsiz cihaz kaydedilmez)', async () => {
  inventoryService.setSecretBox(null);
  const r = await register({ Authorization: T(superUser) }, newBody());
  assert.strictEqual(r.status, 503);
  inventoryService.setSecretBox({ isConfigured: () => false });
  assert.strictEqual((await register({ Authorization: T(superUser) }, newBody())).status, 503);
});

test('durum gecis matrisi', async () => {
  const H = (r) => r.set('Authorization', T(superUser));
  const patch = (uuid, status) => H(request(app).patch(`/api/v1/admin/inventory/${uuid}/status`)).send({ status });
  const a = addDevice('AHBU-S3-ST01');
  assert.strictEqual((await patch(a.device_uuid, 'SUSPENDED')).status, 200);
  assert.strictEqual((await patch(a.device_uuid, 'IN_STOCK')).status, 200);
  assert.strictEqual((await patch(a.device_uuid, 'CLAIMED')).status, 409, 'CLAIMED elle atanamaz');
  assert.strictEqual((await patch(a.device_uuid, 'IN_STOCK')).status, 409, 'ayni durum');
  assert.strictEqual((await patch(a.device_uuid, 'GECERSIZ')).status, 400);
  assert.strictEqual((await patch(a.device_uuid, 'REVOKED')).status, 200);
  assert.strictEqual((await patch(a.device_uuid, 'SUSPENDED')).status, 409, 'REVOKED -> SUSPENDED yok');

  const c = addDevice('AHBU-S3-ST02', { status: 'CLAIMED', claimed_home_id: crypto.randomUUID() });
  const toStock = await patch(c.device_uuid, 'IN_STOCK');
  assert.strictEqual(toStock.status, 409, 'daireye bagli cihaz stoga alinamaz (acil sifirlama)');
  assert.strictEqual((await patch(c.device_uuid, 'SUSPENDED')).status, 200);
  assert.strictEqual((await patch(c.device_uuid, 'CLAIMED')).status, 200, 'askidan geri (hala bagli)');

  const detached = addDevice('AHBU-S3-ST03', { status: 'CLAIMED', claimed_home_id: null });
  assert.strictEqual((await patch(detached.device_uuid, 'IN_STOCK')).status, 200, 'bagli degilse super stoga alabilir');

  const attached = addDevice('AHBU-S3-ST04', { status: 'REVOKED' });
  attachedDevices.add(attached.device_uuid);
  assert.strictEqual((await patch(attached.device_uuid, 'IN_STOCK')).status, 409);
  assert.strictEqual((await patch('AHBU-S3-YOK1', 'SUSPENDED')).status, 404);
});

test('silme: CLAIMED / bagli cihaz silinemez; stoktaki silinir', async () => {
  const del = (uuid) => request(app).delete(`/api/v1/admin/inventory/${uuid}`).set('Authorization', T(superUser));
  addDevice('AHBU-S3-DL01', { status: 'CLAIMED', claimed_home_id: crypto.randomUUID() });
  assert.strictEqual((await del('AHBU-S3-DL01')).status, 409);
  const s = addDevice('AHBU-S3-DL02', { status: 'SUSPENDED', claimed_home_id: crypto.randomUUID() });
  assert.strictEqual((await del(s.device_uuid)).status, 409);
  addDevice('AHBU-S3-DL03');
  assert.strictEqual((await del('AHBU-S3-DL03')).status, 200);
  assert.ok(!devices.has('AHBU-S3-DL03'));
  assert.strictEqual((await del('AHBU-S3-DL03')).status, 404);
});

test('listeleme: staff YALNIZCA kendi stogunu gorur; kapsam disi tekil sorgu 404', async () => {
  const myHome = crypto.randomUUID();
  staffHomes.set(staff.id, new Set([myHome]));
  addDevice('AHBU-S3-SC01', { status: 'CLAIMED', claimed_home_id: myHome, service_owner_id: staff.id });
  addDevice('AHBU-S3-SC02', { status: 'CLAIMED', claimed_by_user_id: staff.id, claimed_home_id: crypto.randomUUID(), service_owner_id: staff.id });
  addDevice('AHBU-S3-SC03', { status: 'CLAIMED', claimed_home_id: crypto.randomUUID() }); // kok stogu / kok evi
  addDevice('AHBU-S3-SC04', { status: 'IN_STOCK', service_owner_id: staff2.id }); // baska servisin stogu
  const list = await request(app).get('/api/v1/admin/inventory').set('Authorization', T(staff));
  assert.strictEqual(list.status, 200);
  const uuids = list.body.data.items.map((i) => i.device_uuid).sort();
  assert.deepStrictEqual(uuids, ['AHBU-S3-SC01', 'AHBU-S3-SC02']);
  assert.strictEqual(list.body.data.total, 2);
  assert.strictEqual((await request(app).get('/api/v1/admin/inventory/AHBU-S3-SC01').set('Authorization', T(staff))).status, 200);
  assert.strictEqual((await request(app).get('/api/v1/admin/inventory/AHBU-S3-SC03').set('Authorization', T(staff))).status, 404);
});

test('listeleme: sayfalama siniri (en fazla 100), gecersiz durum filtresi 400', async () => {
  const before = fakeDb.calls.length;
  const r = await request(app).get('/api/v1/admin/inventory?limit=5000&offset=-3').set('Authorization', T(superUser));
  assert.strictEqual(r.status, 200);
  assert.strictEqual(r.body.data.limit, 100);
  assert.strictEqual(r.body.data.offset, 0);
  const listCall = fakeDb.calls.slice(before).find((c) => /LIMIT \$\d+ OFFSET \$\d+/.test(c.text));
  assert.deepStrictEqual(listCall.params.slice(-2), [100, 0]);
  assert.strictEqual((await request(app).get('/api/v1/admin/inventory?status=HACK').set('Authorization', T(superUser))).status, 400);
});

// ---- servis_kurulum-9 / atolye-7 / atolye-8 / bireysel-7 ----
const flatLinked = new Set(); // site_flats.device_uuid (migration 035)
const pinLockAudits = [];
fakeDb.on(/SELECT to_regclass\(\$1\) AS t/, (p) => [{ t: p[0] === 'public.site_flats' ? 'public.site_flats' : null }]);
fakeDb.on(/SELECT 1 FROM site_flats WHERE device_uuid = \$1/, (p) => (flatLinked.has(p[0]) ? [{ '?column?': 1 }] : []));
fakeDb.on(/UPDATE device_inventory\s+SET failed_attempts = 0, locked_until = NULL/, (p, t) => {
  const d = devices.get(p[0]);
  if (!d) return [];
  if (/AND service_owner_id = \$2/.test(t) && d.service_owner_id !== p[1]) return []; // 045: servis yalniz kendi karti
  d.failed_attempts = 0;
  d.locked_until = null;
  return [{ device_uuid: d.device_uuid }];
});
fakeDb.on(/INSERT INTO device_audit_logs/, (p) => {
  pinLockAudits.push({ event: p[0], device_uuid: p[1], actor_user_id: p[3], actor_role: p[4], details: p[6] });
  return [];
});

test('servis_kurulum-9: super_user liste/tekil yanitinda claimed_home_id VAR; service_user (045: kendi karti) icin de VAR, baska servisin karti hic gorunmez', async () => {
  const myHome = crypto.randomUUID();
  staffHomes.set(staff.id, new Set([myHome]));
  addDevice('AHBU-S3-CH01', { status: 'CLAIMED', claimed_home_id: myHome, service_owner_id: staff.id });
  const sup = await request(app).get('/api/v1/admin/inventory').set('Authorization', T(superUser));
  const item = sup.body.data.items.find((i) => i.device_uuid === 'AHBU-S3-CH01');
  assert.strictEqual(item.claimed_home_id, myHome);
  const supOne = await request(app).get('/api/v1/admin/inventory/AHBU-S3-CH01').set('Authorization', T(superUser));
  assert.strictEqual(supOne.body.data.claimed_home_id, myHome);

  const st = await request(app).get('/api/v1/admin/inventory').set('Authorization', T(staff));
  const sItem = st.body.data.items.find((i) => i.device_uuid === 'AHBU-S3-CH01');
  assert.ok(sItem && sItem.claimed_home_id === myHome, 'kendi kartinda claimed_home_id doner (045)');
  const stOne = await request(app).get('/api/v1/admin/inventory/AHBU-S3-CH01').set('Authorization', T(staff));
  assert.strictEqual(stOne.status, 200);
  assert.strictEqual(stOne.body.data.claimed_home_id, myHome);
  // baska servis bu karti goremez (liste + tekil)
  const other = await request(app).get('/api/v1/admin/inventory').set('Authorization', T(staff2));
  assert.ok(!other.body.data.items.some((i) => i.device_uuid === 'AHBU-S3-CH01'));
  assert.strictEqual((await request(app).get('/api/v1/admin/inventory/AHBU-S3-CH01').set('Authorization', T(staff2))).status, 404);
});

test('atolye-7: daireye bagli kart silinemez (409 DEVICE_LINKED_TO_FLAT); bagli degilse silinir', async () => {
  const del = (uuid) => request(app).delete(`/api/v1/admin/inventory/${uuid}`).set('Authorization', T(superUser));
  addDevice('AHBU-S3-FL01');
  flatLinked.add('AHBU-S3-FL01');
  const r = await del('AHBU-S3-FL01');
  assert.strictEqual(r.status, 409);
  assert.strictEqual(r.body.code, 'DEVICE_LINKED_TO_FLAT');
  assert.strictEqual(r.body.message, 'Kart bir daireye bağlı; önce daireden ayırın.');
  assert.ok(devices.has('AHBU-S3-FL01'));
  flatLinked.delete('AHBU-S3-FL01');
  assert.strictEqual((await del('AHBU-S3-FL01')).status, 200);
});

test('atolye-8: daireye bagli kart REVOKED -> IN_STOCK yapilamaz (409 DEVICE_LINKED_TO_FLAT); diger gecisler etkilenmez', async () => {
  const patch = (uuid, status) => request(app).patch(`/api/v1/admin/inventory/${uuid}/status`).set('Authorization', T(superUser)).send({ status });
  addDevice('AHBU-S3-FL02', { status: 'REVOKED' });
  flatLinked.add('AHBU-S3-FL02');
  const r = await patch('AHBU-S3-FL02', 'IN_STOCK');
  assert.strictEqual(r.status, 409);
  assert.strictEqual(r.body.code, 'DEVICE_LINKED_TO_FLAT');
  assert.strictEqual(devices.get('AHBU-S3-FL02').status, 'REVOKED');
  addDevice('AHBU-S3-FL03', { status: 'IN_STOCK' });
  flatLinked.add('AHBU-S3-FL03');
  assert.strictEqual((await patch('AHBU-S3-FL03', 'SUSPENDED')).status, 200, 'askiya alma serbest');
});

test('bireysel-7: PIN kilidini kaldirma - yalniz super_user; sayaclar sifirlanir, anahtar/PIN degismez; denetim kaydi', async () => {
  const d = addDevice('AHBU-S3-PL01', { failed_attempts: 5, locked_until: new Date(Date.now() + 600e3), pin_hash: 'pin-ozeti', local_key_enc: 'anahtar-sifreli' });
  const url = '/api/v1/admin/inventory/AHBU-S3-PL01/clear-pin-lock';
  for (const who of [T(user), SVC]) {
    assert.strictEqual((await request(app).post(url).set('Authorization', who).send({})).status, 403);
  }
  // 045: servis sorumlusu kok stogundaki kartin kilidini kaldiramaz (404); baska servisin karti da 404
  assert.strictEqual((await request(app).post(url).set('Authorization', T(staff)).send({})).status, 404);
  assert.strictEqual(d.failed_attempts, 5, 'yetkisiz istekte dokunulmaz');
  const r = await request(app).post(url).set('Authorization', T(superUser)).send({});
  assert.strictEqual(r.status, 200, JSON.stringify(r.body));
  assert.deepStrictEqual(r.body.data, { device_uuid: 'AHBU-S3-PL01', cleared: true });
  assert.strictEqual(d.failed_attempts, 0);
  assert.strictEqual(d.locked_until, null);
  assert.strictEqual(d.pin_hash, 'pin-ozeti');
  assert.strictEqual(d.local_key_enc, 'anahtar-sifreli');
  const a = pinLockAudits.find((x) => x.event === 'inventory_pin_lock_cleared' && x.device_uuid === 'AHBU-S3-PL01');
  assert.ok(a, 'denetim kaydi');
  assert.strictEqual(a.actor_user_id, superUser.id);
  assert.strictEqual((await request(app).post('/api/v1/admin/inventory/AHBU-S3-YOK9/clear-pin-lock').set('Authorization', T(superUser)).send({})).status, 404);
  assert.strictEqual((await request(app).post('/api/v1/admin/inventory/gecersiz/clear-pin-lock').set('Authorization', T(superUser)).send({})).status, 400);
});

// ---- 045: servis sorumlusu kapsami (kiracilik) ----
fakeDb.on(/UPDATE device_inventory SET service_owner_id = \$2, updated_at = CURRENT_TIMESTAMP WHERE id = \$1/, (p) => {
  const d = [...devices.values()].find((x) => x.id === p[0]);
  if (d) d.service_owner_id = p[1];
  return [];
});

test('045: servis KENDI stoguna kart kaydeder (service_owner_id = kendisi); kok kok stoguna (NULL); baska servis goremez', async () => {
  const mine = newBody();
  const r = await register({ Authorization: T(staff) }, mine);
  assert.strictEqual(r.status, 201, JSON.stringify(r.body));
  assert.strictEqual(r.headers['cache-control'], 'no-store');
  assert.strictEqual(devices.get(mine.device_uuid).service_owner_id, staff.id);
  assert.strictEqual(r.body.data.device.service_owner_id, staff.id);
  assert.match(r.body.data.local_key, /^[A-Za-z0-9]{16}$/, 'local_key BIR KEZ doner');
  const rootBody = newBody();
  assert.strictEqual((await register({ Authorization: T(superUser) }, rootBody)).status, 201);
  assert.strictEqual(devices.get(rootBody.device_uuid).service_owner_id || null, null, 'kok kok stoguna kaydeder');
  // servis yalniz kendi kartlarini listeler/arar: kok ve baska servis kartlari yok
  const own = await request(app).get(`/api/v1/admin/inventory?search=${mine.device_uuid}`).set('Authorization', T(staff));
  assert.strictEqual(own.status, 200);
  assert.ok(own.body.data.items.some((i) => i.device_uuid === mine.device_uuid));
  const list = await request(app).get('/api/v1/admin/inventory').set('Authorization', T(staff));
  assert.ok(list.body.data.items.every((i) => devices.get(i.device_uuid).service_owner_id === staff.id), 'yalniz kendi kartlari');
  assert.ok(!list.body.data.items.some((i) => i.device_uuid === rootBody.device_uuid));
  const other = await request(app).get('/api/v1/admin/inventory').set('Authorization', T(staff2));
  assert.ok(!other.body.data.items.some((i) => i.device_uuid === mine.device_uuid), 'baska servis goremez');
  assert.strictEqual((await request(app).get(`/api/v1/admin/inventory/${mine.device_uuid}`).set('Authorization', T(staff2))).status, 404);
});

test('045: servis kendi kartini askiya alir/aktif eder/siler; REVOKED, baska servisin ve kok stogundaki kart yasak (404/403)', async () => {
  const body = newBody();
  assert.strictEqual((await register({ Authorization: T(staff) }, body)).status, 201);
  const uuid = body.device_uuid;
  const patch = (who, status, u = uuid) => request(app).patch(`/api/v1/admin/inventory/${u}/status`).set('Authorization', who).send({ status });
  assert.strictEqual((await patch(T(staff), 'SUSPENDED')).status, 200, 'askiya alma');
  assert.strictEqual(devices.get(uuid).status, 'SUSPENDED');
  assert.strictEqual((await patch(T(staff), 'IN_STOCK')).status, 200, 'aktif etme (stoga)');
  assert.strictEqual((await patch(T(staff), 'REVOKED')).status, 403, 'REVOKED yalniz kok');
  assert.strictEqual(devices.get(uuid).status, 'IN_STOCK');
  // baska servis: ne durum ne silme
  assert.strictEqual((await patch(T(staff2), 'SUSPENDED')).status, 404);
  assert.strictEqual((await request(app).delete(`/api/v1/admin/inventory/${uuid}`).set('Authorization', T(staff2))).status, 404);
  assert.ok(devices.has(uuid));
  // servis kendi stoktaki kartini siler
  assert.strictEqual((await request(app).delete(`/api/v1/admin/inventory/${uuid}`).set('Authorization', T(staff))).status, 200);
  assert.ok(!devices.has(uuid));
});

test('045: kapsamlar arasi aktarim (PATCH /:uuid/service-owner) YALNIZ KOK; servis 403; kurulu kart 409; hedef service_user olmali', async () => {
  const body = newBody();
  assert.strictEqual((await register({ Authorization: T(superUser) }, body)).status, 201);
  const url = `/api/v1/admin/inventory/${body.device_uuid}/service-owner`;
  const patchOwner = (who, payload) => request(app).patch(url).set('Authorization', who).send(payload);
  for (const who of [T(staff), T(staff2), T(user), SVC]) {
    assert.strictEqual((await patchOwner(who, { service_user_id: staff.id })).status, 403);
  }
  assert.strictEqual(devices.get(body.device_uuid).service_owner_id || null, null, 'yetkisiz istekte degismedi');
  assert.strictEqual((await patchOwner(T(superUser), {})).status, 400, 'alan zorunlu');
  assert.strictEqual((await patchOwner(T(superUser), { service_user_id: user.id })).status, 404, 'hedef service_user degil');
  const ok = await patchOwner(T(superUser), { service_user_id: staff.id });
  assert.strictEqual(ok.status, 200, JSON.stringify(ok.body));
  assert.strictEqual(devices.get(body.device_uuid).service_owner_id, staff.id);
  assert.strictEqual(ok.body.data.previous_service_owner_id, null);
  // artik sahibi staff: kendi stogunda; staff2 goremez
  assert.strictEqual((await request(app).get(`/api/v1/admin/inventory/${body.device_uuid}`).set('Authorization', T(staff))).status, 200);
  assert.strictEqual((await request(app).get(`/api/v1/admin/inventory/${body.device_uuid}`).set('Authorization', T(staff2))).status, 404);
  // koke geri al (null)
  assert.strictEqual((await patchOwner(T(superUser), { service_user_id: null })).status, 200);
  assert.strictEqual(devices.get(body.device_uuid).service_owner_id, null);
  // kurulu kart: 409 (evinin servisini izler)
  const installed = addDevice('AHBU-S3-AK01', { status: 'CLAIMED', claimed_home_id: crypto.randomUUID() });
  const r409 = await request(app).patch('/api/v1/admin/inventory/AHBU-S3-AK01/service-owner').set('Authorization', T(superUser)).send({ service_user_id: staff.id });
  assert.strictEqual(r409.status, 409);
  assert.strictEqual(installed.service_owner_id || null, null);
});
