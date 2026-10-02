'use strict';

// WP-B2 / gorev 4: POST /api/v1/admin/inventory/:uid/reissue-label
//   - YALNIZ super_user (JWT); API anahtari / staff / diger roller reddedilir
//   - YALNIZ IN_STOCK ve hicbir daireye baglanmamis / devreye alinmamis cihaz
//   - yeni PIN + yeni yerel anahtar (secret_box ile SIFRELI saklanir); ESKI PIN GECERSIZ olur
//   - yanitta PIN ve anahtar BIR KEZ + PIN'li qr_claim_url; denetim kaydi (sir icermez); ATOMIK

const test = require('node:test');
const assert = require('node:assert/strict');
const { createEnv, uid } = require('./_world');

const env = createEnv();
const { h, state, api, tokenOf, world } = env;
const pin = env.SRC('utils/pin');
const secretBox = env.SRC('utils/secret_box');
const inventoryService = env.SRC('services/inventory_service');

const OLD_PIN = '111111';
const sup = h.user({ role: 'super_user', full_name: 'Süper' });
let n = 0;

function stockDevice(extra = {}) {
  const key = secretBox.generateLocalKey();
  const inv = h.inventory({ uuid: `AHBU-S3-R${String(++n).padStart(3, '0')}`, pin_hash: pin.hashPin(OLD_PIN), local_key_enc: secretBox.encrypt(key), ...extra });
  return { inv, oldKey: key };
}
const url = (uuid) => `/api/v1/admin/inventory/${uuid}/reissue-label`;
const reissue = (uuid, token = tokenOf(sup)) => api('post', url(uuid), token, {});

test('yalnız super_user yeniden üretebilir: staff, resident, owner, normal kullanıcı, servis oturumu 403; kimliksiz 401; API anahtarı 401', async () => {
  const { inv } = stockDevice();
  const staff = h.user({ role: 'service_user' });
  const owner = h.user();
  const home = h.home({ name: 'Ev', owner });
  const resident = h.user();
  h.member(home, resident, 'resident');
  const { session } = h.serviceSession(home);
  for (const [label, token, status] of [
    ['staff', tokenOf(staff), 403],
    ['owner', tokenOf(owner), 403],
    ['resident', tokenOf(resident), 403],
    ['servis oturumu', env.sessionToken(home, session), 403],
    ['kimliksiz', null, 401],
  ]) {
    const r = await reissue(inv.device_uuid, token);
    assert.equal(r.status, status, label);
    assert.equal(r.body.success, false);
  }
  // API anahtarı yolu YOK (ADMIN_API_KEY tanımlı olsa bile)
  process.env.ADMIN_API_KEY = 'k'.repeat(40);
  try {
    const r = await env.request(env.app).post(url(inv.device_uuid)).set('X-Admin-Api-Key', 'k'.repeat(40)).send({});
    assert.equal(r.status, 401);
  } finally {
    process.env.ADMIN_API_KEY = '';
  }
  assert.equal(inv.pin_hash, pin.hashPin(OLD_PIN), 'reddedilen isteklerde PIN değişmedi');
  assert.equal(inv.label_reissue_count, 0);
});

test('başarı: yeni PIN + yeni yerel anahtar BİR KEZ; qr_claim_url PIN\'li; eski PIN GEÇERSİZ; anahtar şifreli saklanır; sayaç/kilit sıfırlanır', async () => {
  const { inv, oldKey } = stockDevice();
  const oldEnc = inv.local_key_enc;
  assert.equal(inv.failed_attempts, 3);
  assert.ok(inv.locked_until);

  const r = await reissue(inv.device_uuid);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.headers['cache-control'], 'no-store');
  assert.equal(r.body.success, true);
  const d = r.body.data;
  assert.match(d.setup_pin, /^\d{6}$/);
  assert.match(d.local_key, /^[\x21-\x7E]{8,32}$/);
  assert.notEqual(d.setup_pin, OLD_PIN);
  assert.notEqual(d.local_key, oldKey);
  assert.equal(d.qr_claim_url, `https://evotomasyon.gudeteknoloji.com.tr/claim?uid=${encodeURIComponent(inv.device_uuid)}&pin=${d.setup_pin}`);
  assert.equal(d.device.device_uuid, inv.device_uuid);
  assert.equal(d.device.status, 'IN_STOCK');
  assert.equal(d.device.label_reissue_count, 1);
  assert.ok(d.device.label_reissued_at);
  assert.ok(!('pin_hash' in d.device) && !('local_key_enc' in d.device), 'özet/şifreli değer yanıtta yok');
  assert.ok(d.message.includes('geçersiz'));

  // eski PIN geçersiz, yeni PIN geçerli (HMAC özeti)
  assert.equal(pin.verifyPin(OLD_PIN, inv.pin_hash), false);
  assert.equal(pin.verifyPin(d.setup_pin, inv.pin_hash), true);
  // anahtar: şifreli ve yeni; düz metin hiçbir kayıtta yok
  assert.notEqual(inv.local_key_enc, oldEnc);
  assert.ok(inv.local_key_enc.startsWith('v1:'));
  assert.equal(secretBox.decrypt(inv.local_key_enc), d.local_key);
  assert.ok(!JSON.stringify(inv).includes(d.local_key) && !JSON.stringify(inv).includes(d.setup_pin));
  // yanlış-PIN sayacı/kilidi sıfırlandı
  assert.equal(inv.failed_attempts, 0);
  assert.equal(inv.locked_until, null);
  assert.equal(inv.label_reissue_count, 1);

  // denetim kaydı: kim/IP, sır YOK
  const audit = state.device_audit_logs.find((a) => a.event === 'inventory_label_reissued' && a.device_uuid === inv.device_uuid);
  assert.equal(audit.actor_user_id, sup.id);
  assert.equal(audit.actor_role, 'super_user');
  assert.ok(audit.ip_address);
  assert.deepEqual(audit.details, { reissue_count: 1 });
  assert.ok(!JSON.stringify(audit).includes(d.setup_pin) && !JSON.stringify(audit).includes(d.local_key));
});

test('tekrar yeniden üretim: sayaç artar, her seferinde farklı PIN/anahtar; öncekiler geçersiz; küçük harfli UID kabul edilir', async () => {
  const { inv } = stockDevice();
  const a = (await reissue(inv.device_uuid)).body.data;
  const b = (await reissue(inv.device_uuid.toLowerCase())).body.data;
  assert.equal(b.device.label_reissue_count, 2);
  assert.notEqual(a.local_key, b.local_key);
  assert.equal(pin.verifyPin(b.setup_pin, inv.pin_hash), true);
  if (a.setup_pin !== b.setup_pin) assert.equal(pin.verifyPin(a.setup_pin, inv.pin_hash), false, 'ilk yeniden üretimin PIN\'i de geçersiz');
  assert.equal(secretBox.decrypt(inv.local_key_enc), b.local_key);
});

test('durum kısıtı: IN_STOCK dışı (CLAIMED/INSTALLED/SUSPENDED/REVOKED) 409; hiçbir şey değişmez', async () => {
  for (const status of ['CLAIMED', 'INSTALLED', 'SUSPENDED', 'REVOKED']) {
    const { inv } = stockDevice({ status });
    const before = JSON.stringify(inv);
    const r = await reissue(inv.device_uuid);
    assert.equal(r.status, 409, status);
    assert.equal(r.body.code, 'CONFLICT');
    assert.ok(r.body.message.includes(status));
    assert.equal(JSON.stringify(inv), before, `${status}: değişmedi`);
  }
});

test('provizyon/claim kısıtı: daireye bağlı, sahiplenilmiş veya devreye alınmış cihaz (IN_STOCK görünse bile) 409', async () => {
  const home = h.home({ name: 'Bağlı Ev', owner: h.user() });
  // envanter satırı IN_STOCK ama devices kaydı bir daireye bağlı (tutarsız veri): reddedilir
  const a = stockDevice();
  h.device(home, { uuid: a.inv.device_uuid });
  assert.equal((await reissue(a.inv.device_uuid)).status, 409);
  // claimed_home_id dolu
  const b = stockDevice({ claimed_home_id: home.id });
  assert.equal((await reissue(b.inv.device_uuid)).status, 409);
  // devreye alınmış (home_id boş ama is_commissioned)
  const c = stockDevice();
  const dev = h.device(null, { uuid: c.inv.device_uuid, commissioned: true });
  assert.equal((await reissue(c.inv.device_uuid)).status, 409);
  // yetim cihaz kaydı (acil sıfırlamadan kalan; bağlı değil): İZİNLİ ve anahtarı eşitlenir
  dev.is_commissioned = false;
  dev.is_claimed = false;
  const r = await reissue(c.inv.device_uuid);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(dev.local_key_enc, c.inv.local_key_enc, 'yetim cihaz kaydı da aynı anahtarı taşır');
  assert.equal(secretBox.decrypt(dev.local_key_enc), r.body.data.local_key);
});

test('bilinmeyen cihaz 404; geçersiz kimlik 400; ortam anahtarı yoksa 503 (anahtar üretilemez)', async () => {
  assert.equal((await reissue('AHBU-YOKTUR-999')).status, 404);
  assert.equal((await reissue('gecersiz')).status, 400);
  assert.equal((await reissue('AHBU-')).status, 400, 'UID biçimi (AHBU-xxx, en az 3 karakter)');
  const { inv } = stockDevice();
  const saved = process.env.LOCAL_KEY_SECRET;
  const savedErr = console.error;
  process.env.LOCAL_KEY_SECRET = '';
  console.error = () => {}; // 5xx yanıtlar için hata yakalayıcı yığını loglar (beklenen)
  try {
    const r = await reissue(inv.device_uuid);
    assert.equal(r.status, 503);
    assert.equal(r.body.code, 'SERVICE_UNAVAILABLE');
    assert.equal(inv.pin_hash, pin.hashPin(OLD_PIN), 'PIN değişmedi');
  } finally {
    process.env.LOCAL_KEY_SECRET = saved;
    console.error = savedErr;
  }
});

test('ATOMİK: yetim cihaz anahtarı güncellenirken hata olursa envanter satırı DA geri alınır (PIN değişmez)', async () => {
  const { inv } = stockDevice();
  const before = JSON.stringify(inv);
  const hook = { matcher: (sql) => sql.startsWith('UPDATE devices SET local_key_enc'), fn: () => { throw new Error('beklenen test hatası'); } };
  world.db.handlers.unshift(hook);
  try {
    await assert.rejects(inventoryService.reissueLabel(inv.device_uuid, { userId: sup.id, role: 'super_user', ip: '1.2.3.4' }), /beklenen test hatası/);
  } finally {
    world.db.handlers.splice(world.db.handlers.indexOf(hook), 1);
  }
  assert.equal(JSON.stringify(inv), before, 'envanter geri alındı');
  assert.equal(state.device_audit_logs.filter((a) => a.device_uuid === inv.device_uuid).length, 0);
  assert.equal(pin.verifyPin(OLD_PIN, inv.pin_hash), true, 'eski etiket hâlâ geçerli');
});

test('yazmalar TEK transaction içinde ve envanter satırı FOR UPDATE ile kilitlenir (eşzamanlı claim/yeniden üretim sıralanır)', async () => {
  const { inv } = stockDevice();
  const start = world.db.log.length;
  await inventoryService.reissueLabel(inv.device_uuid, { userId: sup.id, role: 'super_user', ip: '1.2.3.4' });
  const log = world.db.log.slice(start);
  assert.ok(log.some((l) => l.sql.includes('FOR UPDATE OF di') && l.tx !== null));
  const writes = log.filter((l) => /^(INSERT|UPDATE|DELETE)/.test(l.sql));
  assert.equal(writes.length, 3);
  assert.ok(writes.every((l) => l.tx !== null && l.tx === writes[0].tx));
});

test('hız sınırı: kullanıcı başına saatte 20 yeniden üretim; aşımda 429 RATE_LIMITED', async () => {
  const sup2 = h.user({ role: 'super_user' });
  const { inv } = stockDevice();
  const statuses = [];
  for (let i = 0; i < 22; i++) statuses.push((await reissue(inv.device_uuid, tokenOf(sup2))).status);
  assert.equal(statuses.filter((s) => s === 200).length, 20);
  assert.deepEqual(statuses.slice(20), [429, 429]);
  assert.equal(inv.label_reissue_count, 20);
});

test('/api/ takma yolu da çalışır', async () => {
  const { inv } = stockDevice();
  const r = await api('post', `/api/admin/inventory/${inv.device_uuid}/reissue-label`, tokenOf(h.user({ role: 'super_user' })), {});
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(uid());
});
