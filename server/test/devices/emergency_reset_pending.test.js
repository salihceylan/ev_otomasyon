'use strict';

// SERVIS-01 (+ SERVIS-K1, SERVIS-K2): acil sifirlamada yeni yerel anahtar panoya SIMDI iletilemiyorsa (pano cevrimdisi
// ya da kopru broker'a bagli degil) panodaki GERCEK anahtar gecerli kalir (devices + envanter DEGISMEZ); yeni anahtar
// BEKLEYEN olarak (devices.local_key_pending_enc) yazilir ve pano buluta baglaninca uzlastirici iletir. Boylece servis
// sihirbazi 6. adimda LAN'dan mevcut anahtarla baglanip yeni bulut kimligini yazabilir (cikmaz sokak yok).
// Cevrimici + bagli kopruda bugunku yol korunur; commit sonrasi yayin basarisizsa TELAFI: gecerli anahtar eskisine,
// bekleyen yenisine cekilir. Yanit: local_key_publish 'published' | 'pending' | 'skipped'; 'pending' iken local_key YOK.
// (fx2 S-1) 'pending' HATA DEGILDIR: bekleyen anahtar icin warnings'e uyari EKLENMEZ ve tek basina partial=true yapmaz;
// baska gercek uyari (or. cocuk kilidi) varsa partial onlar yuzunden true kalir.
// (fx2 S-2) Cocuk kilidi komutu gonderilemezse uyari NEDENE gore yazilir (kopru kopuk: "Bulut bağlantısı yok"; pano
// cevrimdisi: "Pano çevrimdışı"); devirde (REASSIGNED) "kilit kapali" NIYETI yazilir ve panonun bildirdigi durum
// korunur: uzlastirici pano baglaninca set_child_lock false gonderir.

const test = require('node:test');
const assert = require('node:assert');

const { createWorld, createServices, setTestEnv } = require('./_world');

const UUID = 'AHBU-S3-0001';
const REASON = 'Kiraci ulasilamiyor, daire teslim alindi';
const OLD_KEY = 'EskiAnahtar123456';
const PENDING_WARNING =
  'Yeni yerel anahtar şu an panoya iletilemedi (pano ya da bulut bağlantısı yok). Pano buluta bağlandığında otomatik ' +
  'iletilecek; o zamana kadar panonun mevcut anahtarı geçerli kalır.';

async function setup({ online = true, locked = false } = {}) {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const h = world.helpers;
  const tech = h.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const owner = h.addUser({ email: 'sahip@example.test' });
  const newbie = h.addUser({ email: 'yeni.sahip@example.test', full_name: 'Yeni Sahip' });
  const inv = h.addInventory({ uuid: UUID, pin: '246810', status: 'CLAIMED' });
  const home = h.addHome({ name: 'Daire 7', owner });
  h.addMember(home, tech, 'service_user', { installer_expires_at: new Date(world.clock.t + 3600000) });
  const oldKeyEnc = svc.secretBox.encrypt(OLD_KEY);
  const dev = h.addDevice({ home, uuid: UUID, mac: inv.mac_address, claimedBy: owner, online, local_key_enc: oldKeyEnc });
  h.addEndpoints(home, dev, 8);
  if (locked) {
    dev.child_lock_enabled = true;
    home.child_lock_enabled = true;
  }
  Object.assign(inv, { claimed_home_id: home.id, claimed_by_user_id: owner.id, pin_hash: 'CLAIMED_BURNED_PIN', local_key_enc: oldKeyEnc });
  await svc.credentials.issueUserCredential({ homeId: home.id, userId: owner.id });
  await svc.credentials.issueDeviceCredential({ homeId: home.id, deviceId: dev.id });
  svc.timeline.length = 0;
  world.db.log.length = 0;
  world.db.commits = 0;
  const rearmed = [];
  svc.bridge.requestReconcile = (topicId) => rearmed.push(topicId);
  // baglanti atma basarili (EMQX ayari yok uyarisi bu dosyanin konusu degil; warnings tam karsilastirilir)
  svc.credentials.kickUsernames = async () => ({ failed: 0 });
  const reset = (extra = {}) =>
    svc.deviceService.emergencyReset({
      actor: { userId: tech.id, globalRole: 'service_user', ip: '203.0.113.9' },
      deviceUuid: UUID,
      confirmUid: UUID,
      reason: REASON,
      ...extra,
    });
  return { world, ...svc, tech, owner, newbie, inv, home, dev, oldKeyEnc, reset, rearmed };
}

const CHILD_LOCK_OFFLINE_REASSIGNED =
  'Pano çevrimdışı; çocuk kilidi sıfırlama komutu gönderilemedi. Kilit, pano bağlandığında otomatik kaldırılacak.';
const CHILD_LOCK_BRIDGE_REASSIGNED =
  'Bulut bağlantısı yok; çocuk kilidi sıfırlama komutu gönderilemedi. Kilit, pano bağlandığında otomatik kaldırılacak.';
const CHILD_LOCK_OFFLINE_UNCLAIMED =
  'Pano çevrimdışı; çocuk kilidi sıfırlama komutu gönderilemedi. Pano yerelde kilitli kalmış olabilir.';
const FAILED_WARNING =
  'Yeni yerel anahtar panoya iletilemedi; anahtar yalnız bu yanıtta gösterilir. Panoya seri konsoldan RESETKEY ve ' +
  'ardından FACTORYINIT ile (fabrika aracı) yazılabilir.';

const sysPublishes = (ctx) => ctx.bridge.topics.filter((t) => t.obj && t.obj.cmd === 'set_local_key');

function assertPending(ctx, r) {
  assert.strictEqual(r.local_key_publish, 'pending');
  assert.ok(!('local_key' in r), "'pending' iken yanitta local_key DONMEZ");
  // S-1: bekleyen anahtar uyari DEGILDIR; partial yalniz baska gercek uyari varsa true
  const warnings = r.warnings || [];
  assert.ok(!warnings.includes(PENDING_WARNING), JSON.stringify(warnings));
  assert.ok(!warnings.some((w) => /yerel anahtar/i.test(w)), JSON.stringify(warnings));
  assert.strictEqual(r.partial === true, warnings.length > 0, 'partial yalniz gercek uyari varsa');
  // panodaki GERCEK anahtar gecerli kalir: devices + envanter
  assert.strictEqual(ctx.dev.local_key_enc, ctx.oldKeyEnc, 'devices.local_key_enc degismemeli');
  assert.strictEqual(ctx.inv.local_key_enc, ctx.oldKeyEnc, 'device_inventory.local_key_enc degismemeli');
  // yeni anahtar BEKLEYEN: sifreli, gecerli bicim, eskisinden farkli; zaman damgasi var
  assert.ok(ctx.dev.local_key_pending_enc, 'bekleyen anahtar yazilmali');
  const pending = ctx.secretBox.decrypt(ctx.dev.local_key_pending_enc);
  assert.ok(ctx.secretBox.isValidLocalKey(pending));
  assert.notStrictEqual(pending, OLD_KEY);
  assert.ok(ctx.dev.local_key_pending_at instanceof Date, 'bekleme zamani yazilmali');
  // duz metin anahtar hicbir tabloda / yanitta yok
  assert.ok(!JSON.stringify(ctx.world.state).includes(pending));
  assert.ok(!JSON.stringify(r).includes(pending));
  return pending;
}

test('pano CEVRIMDISI (devir): mevcut anahtar korunur, yeni anahtar bekleyen; yanit pending, local_key yok, uyari; yayin denenmez', async () => {
  const ctx = await setup({ online: false });
  const r = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assert.strictEqual(r.action, 'REASSIGNED');
  assertPending(ctx, r);
  assert.strictEqual(sysPublishes(ctx).length, 0, 'cevrimdisi panoya sys yayini denenmez');
  assert.ok(r.device_credential && r.device_credential.password, 'yeni bulut kimligi yine tek seferlik doner');
  assert.deepStrictEqual(ctx.rearmed, [ctx.home.mqtt_username], 'uzlastirici bu ev icin yeniden kurulur');
  // cocuk kilidi: komut gonderilemedi -> nedene gore uyari + devirde otomatik kaldirma niyeti
  assert.strictEqual(r.child_lock_reset, 'skipped_offline');
  assert.deepStrictEqual(r.warnings, [CHILD_LOCK_OFFLINE_REASSIGNED], 'tek gercek uyari cocuk kilidi');
  assert.strictEqual(r.partial, true);
});

test('pano CEVRIMDISI (stoga donus): ayni kural; PIN yine bir kez doner', async () => {
  const ctx = await setup({ online: false });
  const r = await ctx.reset();
  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.match(r.setup_pin, /^\d{6}$/);
  assertPending(ctx, r);
  assert.deepStrictEqual(r.warnings, [CHILD_LOCK_OFFLINE_UNCLAIMED], 'stoga donuste niyet yazilacak ev yok');
});

test('SERVIS-K1: pano cevrimici ama KOPRU broker\'a bagli degil -> pending (yayin denenmez, "cevrimdisi" denmez)', async () => {
  const ctx = await setup({ online: true });
  ctx.bridge.connected = false;
  const r = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assertPending(ctx, r);
  assert.strictEqual(sysPublishes(ctx).length, 0);
  assert.ok(!r.warnings.some((w) => /yerinde elle yazılmalıdır/.test(w)), 'uygulanamaz "yerinde yaz" yonergesi verilmez');
  // M1-03: pano CEVRIMICI; cocuk kilidi uyarisi "Pano çevrimdışı" DEMEZ, nedeni (bulut baglantisi) soyler
  assert.ok(!r.warnings.some((w) => /çevrimdışı/i.test(w)), JSON.stringify(r.warnings));
  assert.deepStrictEqual(r.warnings, [CHILD_LOCK_BRIDGE_REASSIGNED]);
  assert.strictEqual(r.child_lock_reset, 'skipped_offline');
});

test('M1-03: devirde cocuk kilidi komutu gonderilemezse "kilit kapali" NIYETI yazilir; panonun bildirdigi kilit durumu korunur (uzlastirici uygular)', async () => {
  for (const scenario of [{ online: false }, { online: true, bridgeDown: true }]) {
    const ctx = await setup({ online: scenario.online, locked: true });
    if (scenario.bridgeDown) ctx.bridge.connected = false;
    const before = ctx.world.clock.t;
    const r = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
    assert.strictEqual(r.action, 'REASSIGNED');
    assert.strictEqual(r.child_lock_reset, 'skipped_offline');
    assert.strictEqual(ctx.home.child_lock_requested, false, 'niyet: kilit kapali');
    assert.ok(ctx.home.child_lock_requested_at instanceof Date && ctx.home.child_lock_requested_at.getTime() >= before);
    // panonun son bildirdigi durum korunur: uzlastirici farki gorup set_child_lock false gonderebilsin
    assert.strictEqual(ctx.dev.child_lock_enabled, true, JSON.stringify(scenario));
    assert.strictEqual(ctx.bridge.commands.filter((c) => c.obj.cmd === 'set_child_lock').length, 0);
  }
});

test('M1-03: stoga donuste (UNCLAIMED) cevrimdisi panoda niyet YAZILMAZ (ev bagi kalmaz); DB kilidi yine sifirlanir', async () => {
  const ctx = await setup({ online: false, locked: true });
  const r = await ctx.reset();
  assert.strictEqual(r.action, 'UNCLAIMED');
  assert.ok(ctx.home.child_lock_requested === null || ctx.home.child_lock_requested === undefined);
  assert.strictEqual(ctx.dev.child_lock_enabled, false);
});

test('cevrimici + bagli kopru: cocuk kilidi yayinlanir; niyet YAZILMAZ ve DB kilidi sifirlanir (bugunku yol)', async () => {
  const ctx = await setup({ online: true, locked: true });
  const r = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assert.strictEqual(r.child_lock_reset, 'published');
  assert.ok(ctx.home.child_lock_requested === null || ctx.home.child_lock_requested === undefined);
  assert.strictEqual(ctx.dev.child_lock_enabled, false);
});

test('M1-04: TELAFI CAS negatif yolu - yayin penceresinde cihaz anahtari BASKA yazimla degistiyse telafi hicbir sey degistirmez; yanit failed + anahtar + seri konsol yonergesi', async () => {
  const ctx = await setup({ online: true });
  const OTHER = ctx.secretBox.encrypt('BaskaYazim987654');
  ctx.bridge.publishSys = async () => {
    ctx.dev.local_key_enc = OTHER; // es zamanli yazim taklidi (ikinci sifirlama / etiket yenileme)
    throw new Error('broker down');
  };
  const r = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assert.strictEqual(r.local_key_publish, 'failed');
  assert.ok(ctx.secretBox.isValidLocalKey(r.local_key), 'gecerli anahtar yanitta bir kez doner');
  assert.ok(r.warnings.includes(FAILED_WARNING), JSON.stringify(r.warnings));
  assert.ok(!r.warnings.some((w) => /yerinde elle/.test(w)));
  assert.strictEqual(r.partial, true);
  // telafi transaction'i BUTUNUYLE geri alindi: envanter yeni anahtarda kalir, cihaz satirina dokunulmaz
  assert.strictEqual(ctx.secretBox.decrypt(ctx.inv.local_key_enc), r.local_key, 'envanter geri cekilmez');
  assert.strictEqual(ctx.dev.local_key_enc, OTHER, 'cihaz satirindaki baska yazim korunur');
  assert.strictEqual(ctx.dev.local_key_pending_enc, null, 'bekleyen yazilmaz');
  assert.deepStrictEqual(ctx.rearmed, [], 'pending olmadi: uzlastirici kurulmaz');
});

test('S-1: cevrimici + bagli kopru + yayin basarisiz (TELAFI) ve baska uyari yok -> pending, warnings/partial YOK', async () => {
  const ctx = await setup({ online: true });
  ctx.bridge.failSys = true;
  const r = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assert.strictEqual(r.local_key_publish, 'pending');
  assert.ok(!('warnings' in r), JSON.stringify(r.warnings));
  assert.ok(!('partial' in r));
});

test('cevrimici + bagli kopru + yayin BASARISIZ: TELAFI - gecerli anahtar eskisine, yeni anahtar bekleyene; yanit pending', async () => {
  const ctx = await setup({ online: true });
  ctx.bridge.failSys = true;
  const r = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assertPending(ctx, r);
  assert.strictEqual(ctx.world.db.commits, 2, 'ana islem + telafi islemi');
  assert.deepStrictEqual(ctx.rearmed, [ctx.home.mqtt_username]);
});

test('cevrimici + bagli kopru + yayin basarili: bugunku yol (yeni anahtar gecerli, bekleyen YOK, yanit published)', async () => {
  const ctx = await setup({ online: true });
  ctx.dev.local_key_pending_enc = ctx.secretBox.encrypt('OncekiBekleyen12'); // onceki cevrimdisi sifirlamadan kalan
  ctx.dev.local_key_pending_at = new Date();
  const r = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assert.strictEqual(r.local_key_publish, 'published');
  assert.ok(!('local_key' in r));
  const sent = sysPublishes(ctx);
  assert.strictEqual(sent.length, 1);
  assert.strictEqual(ctx.secretBox.decrypt(ctx.dev.local_key_enc), sent[0].obj.local_key);
  assert.strictEqual(ctx.inv.local_key_enc, ctx.dev.local_key_enc);
  assert.strictEqual(ctx.dev.local_key_pending_enc, null, 'yeni anahtar gecerli oldu: eski bekleyen silinir');
  assert.strictEqual(ctx.dev.local_key_pending_at, null);
  assert.deepStrictEqual(ctx.rearmed, []);
});

test('ust uste ikinci cevrimdisi sifirlama: bekleyen anahtar YENISIYLE degisir, gecerli anahtar yine ayni', async () => {
  const ctx = await setup({ online: false });
  await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  const first = ctx.dev.local_key_pending_enc;
  // ikinci sifirlama: yeni sahip ayni evin servis uyeligini yeniden verir (teknisyen sureli servis uyesi kalir)
  const r2 = await ctx.reset({ newOwnerIdentifier: 'yeni.sahip@example.test' });
  assert.strictEqual(r2.local_key_publish, 'pending');
  assert.notStrictEqual(ctx.dev.local_key_pending_enc, first);
  assert.strictEqual(ctx.dev.local_key_enc, ctx.oldKeyEnc);
});
