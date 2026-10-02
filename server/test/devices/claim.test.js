'use strict';

// B3 / B11: claimDevice - tek transaction, FOR UPDATE, atomik PIN sayaci, OTP zorunlulugu, yarislar

const test = require('node:test');
const assert = require('node:assert');
const bcrypt = require('bcryptjs');

const { createWorld, createServices, setTestEnv, expectHttp, fakePin } = require('./_world');

const PIN = '123456';
const UUID = 'AHBU-S3-0001';

function setup({ model, inventory = {} } = {}) {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world);
  const customer = world.helpers.addUser({ email: 'ev.sahibi@example.test', phone: '+905551112233' });
  const inv = world.helpers.addInventory({ uuid: UUID, pin: PIN, model: model || 'ESP32-S3-POE-ETH-8DI-8RO', ...inventory });
  const act = (user, extra = {}) => ({ userId: user.id, globalRole: user.role, ip: '10.0.0.7', ...extra });
  return { world, ...svc, customer, inv, act };
}

function claim(ctx, user, overrides = {}) {
  return ctx.deviceService.claimDevice({
    actor: ctx.act(user),
    deviceUuid: UUID,
    setupPin: PIN,
    ...overrides,
  });
}

/** Servis personeli akisi: OTP iste -> musteriye giden kodu al. */
async function requestOtp(ctx, tech, target, uuid = UUID) {
  await ctx.deviceService.requestClaimOtp({ actor: ctx.act(tech), deviceUuid: uuid, targetOwnerIdentifier: target });
  return ctx.mailer.lastCode();
}

// ------------------------------------------------------------------------------------------------
test('basarili sahiplenme: yeni ev (h_+16 hex), sahiplik, cihaz, kanallar, envanter, tek seferlik kimlik', async () => {
  const ctx = setup();
  const r = await claim(ctx, ctx.customer, { homeName: 'Daire 5' });
  const { state, db } = ctx.world;

  assert.strictEqual(r.home_name, 'Daire 5');
  assert.strictEqual(r.device_uuid, UUID);
  assert.strictEqual(state.homes.length, 1);
  const home = state.homes[0];
  assert.strictEqual(r.home_id, home.id);
  assert.match(home.mqtt_username, /^h_[0-9a-f]{16}$/);

  // sahiplik
  const members = state.home_users.filter((m) => m.home_id === home.id);
  assert.deepStrictEqual(members.map((m) => [m.user_id, m.role]), [[ctx.customer.id, 'owner']]);

  // cihaz kaydi
  assert.strictEqual(state.devices.length, 1);
  const dev = state.devices[0];
  assert.strictEqual(dev.home_id, home.id);
  assert.strictEqual(dev.is_claimed, true);
  assert.strictEqual(dev.claimed_by, ctx.customer.id);
  assert.strictEqual(dev.is_online, false);
  assert.strictEqual(dev.is_commissioned, false, 'sahiplenme devreye alma DEGILDIR');
  assert.strictEqual(dev.commissioning_status, 'PENDING_INSTALLATION');
  assert.strictEqual(dev.setup_pin, null, 'duz metin PIN saklanmaz');
  assert.strictEqual(dev.mac_address, ctx.inv.mac_address);

  // yerel anahtar sifreli saklanir ve cozulur
  const localKey = ctx.secretBox.decrypt(dev.local_key_enc);
  assert.strictEqual(localKey.length, 16);
  assert.strictEqual(ctx.inv.local_key_enc, dev.local_key_enc);

  // kanallar: model (8RO) kanal sayisi, tek INSERT ... generate_series
  const eps = state.endpoints.filter((e) => e.device_id === dev.id);
  assert.strictEqual(eps.length, 8);
  assert.strictEqual(eps.filter((e) => e.type === 'shutter').length, 4);
  assert.strictEqual(db.count('INSERT INTO endpoints'), 1, 'kanallar tek INSERT ile eklenmeli (dongu yok)');
  assert.ok(db.find('INSERT INTO endpoints')[0].sql.includes('generate_series'));

  // envanter: CLAIMED + PIN yakildi
  assert.strictEqual(ctx.inv.status, 'CLAIMED');
  assert.strictEqual(ctx.inv.claimed_home_id, home.id);
  assert.strictEqual(ctx.inv.claimed_by_user_id, ctx.customer.id);
  assert.strictEqual(ctx.inv.pin_hash, 'CLAIMED_BURNED_PIN');
  assert.strictEqual(ctx.inv.failed_attempts, 0);

  // cihaz MQTT kimligi: d_{t}, tek seferlik parola, DB'de yalnizca bcrypt
  const cred = r.device_credential;
  assert.strictEqual(cred.username, `d_${home.mqtt_username}`);
  assert.strictEqual(cred.topic_id, home.mqtt_username);
  assert.strictEqual(cred.host, 'broker.test.invalid');
  assert.strictEqual(cred.port, 8884);
  assert.strictEqual(cred.password.length, 24);
  assert.strictEqual(state.mqtt_credentials.length, 1);
  const row = state.mqtt_credentials[0];
  assert.strictEqual(row.kind, 'device');
  assert.ok(bcrypt.compareSync(cred.password, row.password_hash), 'DB ozeti bcrypt ve parolayla eslesmeli');
  assert.ok(!JSON.stringify(state).includes(cred.password), 'duz metin parola hicbir tabloda olmamali');

  // cihaz ACL: pub state/status, sub cmd/sys
  const acl = state.mqtt_acl.map((a) => `${a.action}:${a.topic}`).sort();
  assert.deepStrictEqual(acl, [
    `publish:ev/${home.mqtt_username}/state`,
    `publish:ev/${home.mqtt_username}/status`,
    `subscribe:ev/${home.mqtt_username}/cmd`,
    `subscribe:ev/${home.mqtt_username}/sys`,
  ].sort());

  // denetim kaydi: IP var, sir yok
  assert.strictEqual(state.device_audit_logs.length, 1);
  assert.strictEqual(state.device_audit_logs[0].event, 'device_claimed');
  assert.strictEqual(state.device_audit_logs[0].ip_address, '10.0.0.7');
  const auditText = JSON.stringify(state.device_audit_logs);
  assert.ok(!auditText.includes(cred.password), 'denetim kaydinda parola olmamali');
  assert.ok(!auditText.includes(PIN), 'denetim kaydinda PIN olmamali');
  assert.ok(!auditText.includes(localKey), 'denetim kaydinda yerel anahtar olmamali');

  // TEK transaction, havuza dusen sorgu yok
  assert.strictEqual(db.commits, 1);
  assert.strictEqual(db.rollbacks, 0);
  assert.deepStrictEqual(db.nonTxQueries(), [], 'tum sorgular ayni transaction icinde olmali');

  // PIN ve yerel anahtar hicbir yerde duz metin kalmaz
  const dump = JSON.stringify(state);
  assert.ok(!dump.includes(PIN), 'duz metin PIN saklanmamali');
  assert.ok(!dump.includes(localKey), 'duz metin yerel anahtar saklanmamali');
});

test('ev sunucuda belirlenir: govdedeki home_id YOK SAYILIR', async () => {
  const ctx = setup();
  const otherHome = ctx.world.helpers.addHome({ name: 'Baskasinin evi' });
  const r = await ctx.deviceService.claimDevice({
    actor: ctx.act(ctx.customer),
    deviceUuid: UUID,
    setupPin: PIN,
    homeId: otherHome.id, // servis imzasinda yok: yok sayilmali
    home_id: otherHome.id,
  });
  assert.notStrictEqual(r.home_id, otherHome.id);
  assert.strictEqual(ctx.world.state.devices[0].home_id, r.home_id);
  assert.strictEqual(ctx.world.state.home_users.filter((m) => m.home_id === otherHome.id).length, 0);
});

test('varsayilan daire adi ve bos ev yeniden kullanimi; cihazli evi olan icin YENI ev', async () => {
  const ctx = setup();
  // 1) cihazsiz (bos) sahip evi varsa o kullanilir
  const empty = ctx.world.helpers.addHome({ name: 'Bos Ev', owner: ctx.customer });
  const r1 = await claim(ctx, ctx.customer);
  assert.strictEqual(r1.home_id, empty.id);
  assert.strictEqual(ctx.world.state.homes.length, 1);

  // 2) bu ev artik cihazli: ikinci cihaz icin YENI ev olusur (bir ev = bir pano)
  ctx.world.helpers.addInventory({ uuid: 'AHBU-S3-0002', pin: '654321' });
  const r2 = await ctx.deviceService.claimDevice({
    actor: ctx.act(ctx.customer),
    deviceUuid: 'AHBU-S3-0002',
    setupPin: '654321',
  });
  assert.notStrictEqual(r2.home_id, empty.id);
  assert.strictEqual(r2.home_name, 'Evim');
  assert.strictEqual(ctx.world.state.homes.length, 2);
  const topics = ctx.world.state.homes.map((h) => h.mqtt_username);
  assert.strictEqual(new Set(topics).size, 2);
});

// ------------------------------------------------------------------------------------------------
test('girdi dogrulama: gecersiz uuid / PIN / daire adi / hedef VERITABANINA DOKUNMADAN 400', async () => {
  const ctx = setup();
  const base = { actor: ctx.act(ctx.customer), deviceUuid: UUID, setupPin: PIN };
  const cases = [
    { deviceUuid: 'xyz' },
    { deviceUuid: 'AHBU-' },
    { deviceUuid: 'DEV-S3-8754-AHBU' },
    { deviceUuid: undefined },
    { setupPin: '12345' },
    { setupPin: '1234567' },
    { setupPin: 'abcdef' },
    { setupPin: '' },
    { setupPin: undefined },
    { setupPin: { toString: () => PIN } },
    { homeName: 'x'.repeat(101) },
    { homeName: 42 },
    { targetOwnerIdentifier: 'not-an-email' },
  ];
  for (const c of cases) {
    await expectHttp(ctx.deviceService.claimDevice({ ...base, ...c }), 400, 'VALIDATION');
  }
  assert.strictEqual(ctx.world.db.log.length, 0, 'gecersiz girdi sayaclara/DB\'ye dokunmamali');
});

test('kimlik dogrulanmamis / yetkisiz global rol reddedilir', async () => {
  const ctx = setup();
  await expectHttp(
    ctx.deviceService.claimDevice({ actor: { userId: null, globalRole: 'service_session' }, deviceUuid: UUID, setupPin: PIN }),
    403, 'FORBIDDEN'
  );
  await expectHttp(
    ctx.deviceService.claimDevice({ actor: { userId: ctx.customer.id, globalRole: 'admin' }, deviceUuid: UUID, setupPin: PIN }),
    403, 'FORBIDDEN'
  );
  await expectHttp(ctx.deviceService.claimDevice({ actor: null, deviceUuid: UUID, setupPin: PIN }), 403, 'FORBIDDEN');
  assert.strictEqual(ctx.world.db.log.length, 0);
});

test('pasif hesap sahiplenemez', async () => {
  const ctx = setup();
  const inactive = ctx.world.helpers.addUser({ email: 'pasif@example.test', is_active: false });
  await expectHttp(claim(ctx, inactive), 403, 'FORBIDDEN');
  assert.strictEqual(ctx.inv.status, 'IN_STOCK');
});

// ------------------------------------------------------------------------------------------------
test('envanterde olmayan cihaz 404; ESKI devices yolu YOK (kaçak donanim sahiplenemez)', async () => {
  const ctx = setup();
  // legacy: yalniz devices tablosunda kayitli cihaz
  ctx.world.helpers.addDevice({ uuid: 'AHBU-LEGACY-1', mac: 'AA:BB:CC:DD:EE:01' });
  await expectHttp(
    ctx.deviceService.claimDevice({ actor: ctx.act(ctx.customer), deviceUuid: 'AHBU-LEGACY-1', setupPin: PIN }),
    404, 'NOT_FOUND'
  );
  assert.strictEqual(ctx.world.state.homes.length, 0);
  assert.strictEqual(ctx.world.db.count('FROM devices'), 0, 'eski devices sorgu yolu silinmis olmali');
});

test('durum kontrolleri: REVOKED/SUSPENDED 403, CLAIMED 409 - sayaclara DOKUNMAZ', async () => {
  for (const [status, httpStatus, code] of [['REVOKED', 403, 'FORBIDDEN'], ['SUSPENDED', 403, 'FORBIDDEN'], ['CLAIMED', 409, 'CONFLICT']]) {
    const ctx = setup({ inventory: { status } });
    await expectHttp(claim(ctx, ctx.customer, { setupPin: '000000' }), httpStatus, code);
    assert.strictEqual(ctx.inv.failed_attempts, 0, `${status}: sayac artmamali`);
    assert.strictEqual(ctx.world.state.homes.length, 0);
  }
});

// ------------------------------------------------------------------------------------------------
test('yanlis PIN: sayac ATOMIK artar ve hata firlatilsa bile COMMIT edilir (commit-then-throw)', async () => {
  const ctx = setup();
  const e1 = await expectHttp(claim(ctx, ctx.customer, { setupPin: '000000' }), 403, 'FORBIDDEN', { remaining_attempts: 4 });
  assert.match(e1.message, /Kalan deneme hakkı: 4/);
  assert.strictEqual(ctx.inv.failed_attempts, 1, 'sayac ROLLBACK ile geri alinmamali');
  assert.strictEqual(ctx.world.db.rollbacks, 0);
  assert.strictEqual(ctx.world.db.commits, 1);
  // sayac artisi SQL icinde (JS'te hesaplanmaz): kaba kuvvet yarisini onler
  const upd = ctx.world.db.find('UPDATE device_inventory SET failed_attempts')[0];
  assert.ok(upd.sql.includes('COALESCE(failed_attempts, 0) + 1'));
  assert.ok(!ctx.world.db.sqls().some((s) => /failed_attempts = \$\d/.test(s)), 'sayac degeri parametreyle yazilmamali');

  await expectHttp(claim(ctx, ctx.customer, { setupPin: '111111' }), 403, 'FORBIDDEN', { remaining_attempts: 3 });
  assert.strictEqual(ctx.inv.failed_attempts, 2);
  assert.strictEqual(ctx.world.state.homes.length, 0);
});

test('5 yanlis PIN: 15 dk kilit (423 PIN_LOCKED + retry_after); kilitliyken DOGRU PIN de reddedilir; sure dolunca calisir', async () => {
  const ctx = setup();
  for (let i = 1; i <= 4; i++) {
    await expectHttp(claim(ctx, ctx.customer, { setupPin: '000000' }), 403, 'FORBIDDEN');
  }
  const locked = await expectHttp(claim(ctx, ctx.customer, { setupPin: '000000' }), 423, 'PIN_LOCKED');
  assert.strictEqual(ctx.inv.failed_attempts, 5);
  assert.ok(ctx.inv.locked_until instanceof Date);
  assert.ok(locked.extra.retry_after >= 899 && locked.extra.retry_after <= 900, `retry_after=${locked.extra.retry_after}`);

  // kilitliyken dogru PIN: reddedilir, sayac artmaz
  const again = await expectHttp(claim(ctx, ctx.customer, { setupPin: PIN }), 423, 'PIN_LOCKED');
  assert.ok(again.extra.retry_after > 0);
  assert.strictEqual(ctx.inv.failed_attempts, 5);
  assert.strictEqual(ctx.world.state.homes.length, 0);

  // 15 dk sonra dogru PIN calisir ve sayac sifirlanir
  ctx.world.clock.advance(15 * 60 * 1000 + 1000);
  const ok = await claim(ctx, ctx.customer);
  assert.ok(ok.home_id);
  assert.strictEqual(ctx.inv.failed_attempts, 0);
  assert.strictEqual(ctx.inv.locked_until, null);
});

test('kilit sonrasi tek yanlis deneme tekrar kilitler (5 hakki yeniden vermez)', async () => {
  const ctx = setup();
  for (let i = 1; i <= 5; i++) await expectHttp(claim(ctx, ctx.customer, { setupPin: '000000' }), i < 5 ? 403 : 423, null);
  ctx.world.clock.advance(15 * 60 * 1000 + 1000);
  await expectHttp(claim(ctx, ctx.customer, { setupPin: '000000' }), 423, 'PIN_LOCKED');
  assert.strictEqual(ctx.inv.failed_attempts, 6);
});

test('PIN sayaci ATOMIK: 8 eszamanli yanlis deneme -> tam 5 sayilir, kalanlar kilit nedeniyle reddedilir', async () => {
  const ctx = setup();
  const results = await Promise.allSettled(
    Array.from({ length: 8 }, () => claim(ctx, ctx.customer, { setupPin: '000000' }))
  );
  const statuses = results.map((r) => (r.status === 'rejected' ? r.reason.status : 200)).sort();
  assert.strictEqual(results.every((r) => r.status === 'rejected'), true);
  assert.strictEqual(statuses.filter((s) => s === 403).length, 4, JSON.stringify(statuses));
  assert.strictEqual(statuses.filter((s) => s === 423).length, 4, JSON.stringify(statuses));
  assert.strictEqual(ctx.inv.failed_attempts, 5, 'sayac kayip guncelleme olmadan tam 5 olmali');
  assert.ok(ctx.inv.locked_until);
});

test('CLAIM YARISI: ayni cihaza iki eszamanli sahiplenme -> yalnizca biri basarili, digeri 409', async () => {
  const ctx = setup();
  const other = ctx.world.helpers.addUser({ email: 'ikinci@example.test' });
  const results = await Promise.allSettled([claim(ctx, ctx.customer), claim(ctx, other)]);
  const fulfilled = results.filter((r) => r.status === 'fulfilled');
  const rejected = results.filter((r) => r.status === 'rejected');
  assert.strictEqual(fulfilled.length, 1, 'tam bir sahiplenme basarili olmali');
  assert.strictEqual(rejected.length, 1);
  assert.strictEqual(rejected[0].reason.status, 409);
  assert.strictEqual(rejected[0].reason.code, 'CONFLICT');

  const { state } = ctx.world;
  assert.strictEqual(state.homes.length, 1, 'yalnizca bir ev olusmali');
  assert.strictEqual(state.devices.length, 1);
  assert.strictEqual(state.mqtt_credentials.length, 1, 'yalnizca bir cihaz kimligi');
  assert.strictEqual(state.endpoints.length, 8);
  const winner = fulfilled[0].value;
  assert.strictEqual(ctx.inv.claimed_home_id, winner.home_id);
  assert.ok([ctx.customer.id, other.id].includes(ctx.inv.claimed_by_user_id));
});

test('CLAIM YARISI: 6 eszamanli sahiplenme -> 1 basarili, 5 conflict; envanter satiri tek kez yakilir', async () => {
  const ctx = setup();
  const users = Array.from({ length: 6 }, (_, i) => ctx.world.helpers.addUser({ email: `yaris${i}@example.test` }));
  const results = await Promise.allSettled(users.map((u) => claim(ctx, u)));
  assert.strictEqual(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.strictEqual(results.filter((r) => r.status === 'rejected' && r.reason.status === 409).length, 5);
  assert.strictEqual(ctx.world.state.homes.length, 1);
  assert.strictEqual(ctx.world.state.device_audit_logs.length, 1);
});

test('hata durumunda TUM islem geri alinir (ev/cihaz/kanal/kimlik/envanter): kimlik uretimi basarisiz', async () => {
  const ctx = setup();
  delete process.env.MQTT_PUBLIC_HOST; // issueDeviceCredential 500 firlatir
  await assert.rejects(claim(ctx, ctx.customer), (err) => err.status === 500);
  const { state } = ctx.world;
  assert.strictEqual(ctx.world.db.rollbacks, 1);
  assert.strictEqual(state.homes.length, 0);
  assert.strictEqual(state.home_users.length, 0);
  assert.strictEqual(state.devices.length, 0);
  assert.strictEqual(state.endpoints.length, 0);
  assert.strictEqual(state.mqtt_credentials.length, 0);
  assert.strictEqual(ctx.inv.status, 'IN_STOCK', 'PIN yakilmamali');
  assert.strictEqual(ctx.inv.pin_hash, fakePin.hashPin(PIN));
});

test('LOCAL_KEY_SECRET yoksa sahiplenme baslamaz (fail-closed) ve hicbir sey yazilmaz', async () => {
  const ctx = setup();
  delete process.env.LOCAL_KEY_SECRET;
  await assert.rejects(claim(ctx, ctx.customer), /LOCAL_KEY_SECRET/);
  assert.strictEqual(ctx.world.state.devices.length, 0);
  assert.strictEqual(ctx.inv.status, 'IN_STOCK');
});

test('envanterde fabrika yerel anahtari varsa AYNEN kopyalanir; yoksa uretilip envantere de yazilir', async () => {
  const ctx = setup();
  const factoryEnc = ctx.secretBox.encrypt('FabrikaAnahtar12');
  ctx.inv.local_key_enc = factoryEnc; // fabrikada uretilip sifreli saklanmis (A11)
  await claim(ctx, ctx.customer);
  assert.strictEqual(ctx.world.state.devices[0].local_key_enc, factoryEnc);
  assert.strictEqual(ctx.secretBox.decrypt(ctx.world.state.devices[0].local_key_enc), 'FabrikaAnahtar12');
  assert.strictEqual(ctx.inv.local_key_enc, factoryEnc);

  // yoksa: uretilip hem cihaza hem envantere yazilir (ayni sifreli deger)
  const ctx2 = setup();
  assert.strictEqual(ctx2.inv.local_key_enc, null);
  await claim(ctx2, ctx2.customer);
  assert.ok(ctx2.inv.local_key_enc);
  assert.strictEqual(ctx2.inv.local_key_enc, ctx2.world.state.devices[0].local_key_enc);
});

test('kanal sayisi modele gore: 16RO modeli 16, bilinmeyen model 8 kanal', async () => {
  const ctx = setup({ model: 'ESP32-S3-POE-ETH-8DI-16RO' });
  await claim(ctx, ctx.customer);
  assert.strictEqual(ctx.world.state.endpoints.length, 16);

  const ctx2 = setup({ model: 'BILINMEYEN-PANO' });
  await claim(ctx2, ctx2.customer);
  assert.strictEqual(ctx2.world.state.endpoints.length, 8);
});

test('MAC cakismasi: yetim kayit arsivlenir ve sahiplenme calisir; aktif baska daire kaydi 409 ve geri alinir', async () => {
  // yetim: ayni MAC, farkli UUID, evi yok
  const ctx = setup();
  const orphan = ctx.world.helpers.addDevice({ uuid: 'AHBU-ESKI-9', mac: ctx.inv.mac_address, home: null });
  await claim(ctx, ctx.customer);
  assert.ok(orphan.mac_address.includes('-DUP-'), 'yetim kaydin MAC adresi arsivlenmeli');
  assert.strictEqual(ctx.world.state.devices.find((d) => d.device_uuid === UUID).mac_address, ctx.inv.mac_address);

  // aktif: ayni MAC baska bir dairede
  const ctx2 = setup();
  const home2 = ctx2.world.helpers.addHome({ name: 'Baska' });
  ctx2.world.helpers.addDevice({ uuid: 'AHBU-ESKI-8', mac: ctx2.inv.mac_address, home: home2 });
  await expectHttp(claim(ctx2, ctx2.customer), 409, 'CONFLICT');
  assert.strictEqual(ctx2.inv.status, 'IN_STOCK');
  assert.strictEqual(ctx2.world.state.homes.length, 1, 'yeni ev olusturulmamali (geri alindi)');
});

test('envanter IN_STOCK ama cihaz kaydi baska daireye bagli: cihaz CALINMAZ (409)', async () => {
  const ctx = setup();
  const home2 = ctx.world.helpers.addHome({ name: 'Baska' });
  ctx.world.helpers.addDevice({ uuid: UUID, mac: ctx.inv.mac_address, home: home2 });
  await expectHttp(claim(ctx, ctx.customer), 409, 'CONFLICT');
  assert.strictEqual(ctx.world.state.devices[0].home_id, home2.id);
});

test('yeniden sahiplenme (sifirlanmis cihaz): ayni device kaydi guncellenir, eski yetim kanallar temizlenir', async () => {
  const ctx = setup();
  const oldHome = ctx.world.helpers.addHome({ name: 'Eski' });
  const dev = ctx.world.helpers.addDevice({ uuid: UUID, mac: ctx.inv.mac_address, home: null });
  ctx.world.helpers.addEndpoints(oldHome, dev, 8); // yetim satirlar (eski daireye bagli)
  await claim(ctx, ctx.customer);
  assert.strictEqual(ctx.world.state.devices.length, 1);
  assert.ok(ctx.world.state.endpoints.every((e) => e.home_id !== oldHome.id));
  assert.strictEqual(ctx.world.state.endpoints.length, 8);
});

// ------------------------------------------------------------------------------------------------
// target_owner / OTP / servis personeli
// ------------------------------------------------------------------------------------------------

test('normal kullanici target_owner veremez (OTP atlatma girisimi): 403, DB\'ye dokunulmaz', async () => {
  const ctx = setup();
  await expectHttp(
    claim(ctx, ctx.customer, { targetOwnerIdentifier: 'baska@example.test', otpCode: '123456' }),
    403, 'FORBIDDEN'
  );
  assert.strictEqual(ctx.world.db.log.length, 0);
});

test('servis personeli target_owner OLMADAN sahiplenemez (teknisyen sahip olamaz): 400', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  await expectHttp(claim(ctx, tech), 400, 'VALIDATION');
  assert.strictEqual(ctx.world.db.log.length, 0);
});

test('OTP HER ZAMAN zorunlu: target_owner var, otp_code yok/gecersiz -> 400 (DB\'ye dokunmadan)', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  for (const otp of [undefined, '', '12345', 'abcdef', null]) {
    await expectHttp(claim(ctx, tech, { targetOwnerIdentifier: ctx.customer.email, otpCode: otp }), 400, 'VALIDATION');
  }
  assert.strictEqual(ctx.world.db.log.length, 0);
});

test('servis personeli + dogru OTP: musteri sahip olur, teknisyen SURELI servis uyesi olur', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const code = await requestOtp(ctx, tech, ctx.customer.email);
  assert.match(code, /^\d{6}$/);

  const r = await claim(ctx, tech, { targetOwnerIdentifier: ctx.customer.email, otpCode: code });
  const { state } = ctx.world;
  const dev = state.devices[0];
  assert.strictEqual(dev.claimed_by, ctx.customer.id, 'cihazin sahibi musteri olmali');
  assert.strictEqual(ctx.inv.claimed_by_user_id, ctx.customer.id);

  const members = state.home_users.filter((m) => m.home_id === r.home_id);
  const owner = members.find((m) => m.role === 'owner');
  const staff = members.find((m) => m.role === 'service_user');
  assert.strictEqual(owner.user_id, ctx.customer.id);
  assert.strictEqual(staff.user_id, tech.id, 'teknisyen kurulumu bitirebilsin diye servis uyesi olur');
  const hours = (new Date(staff.installer_expires_at) - ctx.world.clock.now()) / 3600000;
  assert.ok(hours > 71 && hours <= 72, `servis uyeligi sureli olmali (72 saat): ${hours}`);
  assert.ok(r.technician_access_expires_at);

  assert.strictEqual(state.device_claim_otps.length, 0, 'OTP tek kullanimlik: tuketildi');
  assert.strictEqual(ctx.deviceService.invites.length, 0, 'mevcut hesap icin davet gonderilmez');
});

test('OTP tek kullanimlik: ayni kod ikinci cihazda gecmez', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const code = await requestOtp(ctx, tech, ctx.customer.email);
  await claim(ctx, tech, { targetOwnerIdentifier: ctx.customer.email, otpCode: code });

  ctx.world.helpers.addInventory({ uuid: 'AHBU-S3-0002', pin: '654321' });
  await expectHttp(
    ctx.deviceService.claimDevice({
      actor: ctx.act(tech), deviceUuid: 'AHBU-S3-0002', setupPin: '654321',
      targetOwnerIdentifier: ctx.customer.email, otpCode: code,
    }),
    400, 'VALIDATION'
  );
});

test('yanlis OTP: 400, deneme sayaci ATOMIK artar ve COMMIT edilir; 5. hatadan sonra 429 (kod iptal)', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const code = await requestOtp(ctx, tech, ctx.customer.email);
  const wrong = code === '000000' ? '111111' : '000000';

  for (let i = 1; i <= 5; i++) {
    const e = await expectHttp(
      claim(ctx, tech, { targetOwnerIdentifier: ctx.customer.email, otpCode: wrong }),
      400, 'VALIDATION', { remaining_attempts: 5 - i }
    );
    assert.match(e.message, /Hatalı doğrulama kodu/);
    assert.strictEqual(ctx.world.state.device_claim_otps[0].attempts, i, 'sayac rollback ile kaybolmamali');
  }
  // 6. deneme: DOGRU kod bile artik reddedilir
  await expectHttp(
    claim(ctx, tech, { targetOwnerIdentifier: ctx.customer.email, otpCode: code }),
    429, 'RATE_LIMITED'
  );
  assert.strictEqual(ctx.world.state.homes.length, 0);
  assert.strictEqual(ctx.inv.status, 'IN_STOCK');
  assert.strictEqual(ctx.inv.failed_attempts, 0, 'PIN dogru oldugu icin PIN sayaci artmamali');
});

test('OTP suresi (15 dk) dolunca reddedilir', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const code = await requestOtp(ctx, tech, ctx.customer.email);
  ctx.world.clock.advance(15 * 60 * 1000 + 1000);
  await expectHttp(claim(ctx, tech, { targetOwnerIdentifier: ctx.customer.email, otpCode: code }), 400, 'VALIDATION');
});

test('OTP baska cihaz icin istenmisse bu cihazda gecmez', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  ctx.world.helpers.addInventory({ uuid: 'AHBU-S3-0002', pin: '654321' });
  const code = await requestOtp(ctx, tech, ctx.customer.email, 'AHBU-S3-0002');
  await expectHttp(claim(ctx, tech, { targetOwnerIdentifier: ctx.customer.email, otpCode: code }), 400, 'VALIDATION');
});

test('servis personeli kendi e-postasini hedef gosteremez (403) ve OTP tuketilmez', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  await expectHttp(
    ctx.deviceService.requestClaimOtp({ actor: ctx.act(tech), deviceUuid: UUID, targetOwnerIdentifier: 'Teknisyen@Example.Test' }),
    403, 'FORBIDDEN'
  );
  // claim: OTP zaten alinmis gibi sahte satir koy; yine de 403
  ctx.world.state.device_claim_otps.push({
    id: 1, device_uuid: UUID, target_identifier: tech.email, otp_hash: fakePin.hashPin('123456'),
    expires_at: new Date(ctx.world.clock.t + 600000), attempts: 0, window_started_at: ctx.world.clock.now(),
    created_at: ctx.world.clock.now(),
  });
  await expectHttp(claim(ctx, tech, { targetOwnerIdentifier: tech.email, otpCode: '123456' }), 403, 'FORBIDDEN');
  assert.strictEqual(ctx.world.state.device_claim_otps.length, 1, 'OTP tuketilmemeli');
  assert.strictEqual(ctx.world.state.homes.length, 0);
});

test('musteri hesabi yoksa: RASTGELE kullanilamaz parola + pending_invite + davet (SABIT PAROLA YOK)', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const newEmail = 'yeni.musteri@example.test';
  const code = await requestOtp(ctx, tech, newEmail);

  const r = await claim(ctx, tech, { targetOwnerIdentifier: newEmail, otpCode: code });
  const created = ctx.world.state.users.find((u) => u.email === newEmail);
  assert.ok(created, 'musteri hesabi olusturulmali');
  assert.strictEqual(created.account_status, 'pending_invite');
  assert.strictEqual(created.created_by_user_id, tech.id);
  assert.match(created.password_hash, /^\$2[aby]\$12\$/, 'bcrypt maliyet 12');
  // eski sabit parola ve benzerleri ASLA gecmez
  for (const old of ['Ahbu2026!Ev', 'Ahbu2026!', '123456', newEmail]) {
    assert.strictEqual(bcrypt.compareSync(old, created.password_hash), false);
  }
  // iki hesabin parola ozeti ayni olmaz (rastgele)
  const code2 = await requestOtp(ctx, tech, 'ikinci.musteri@example.test', 'AHBU-S3-0002').catch(() => null);
  assert.strictEqual(code2, null); // AHBU-S3-0002 envanterde yok: 404 (rastgelelik testi ayri)

  assert.strictEqual(r.customer_account.created, true);
  assert.strictEqual(r.customer_account.status, 'pending_invite');
  assert.strictEqual(r.customer_account.invite_sent, true);
  assert.deepStrictEqual(ctx.deviceService.invites.map((i) => i.email), [newEmail]);
  assert.strictEqual(ctx.world.state.devices[0].claimed_by, created.id);
});

test('iki yeni musteri hesabinin parola ozetleri farklidir (sabit/turetilebilir parola yok)', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  ctx.world.helpers.addInventory({ uuid: 'AHBU-S3-0002', pin: '654321' });
  const c1 = await requestOtp(ctx, tech, 'bir@example.test');
  await claim(ctx, tech, { targetOwnerIdentifier: 'bir@example.test', otpCode: c1 });
  const c2 = await requestOtp(ctx, tech, 'iki@example.test', 'AHBU-S3-0002');
  await ctx.deviceService.claimDevice({
    actor: ctx.act(tech), deviceUuid: 'AHBU-S3-0002', setupPin: '654321',
    targetOwnerIdentifier: 'iki@example.test', otpCode: c2,
  });
  const h1 = ctx.world.state.users.find((u) => u.email === 'bir@example.test').password_hash;
  const h2 = ctx.world.state.users.find((u) => u.email === 'iki@example.test').password_hash;
  assert.notStrictEqual(h1, h2);
});

test('davet gonderilemezse sahiplenme YINE BASARILI; yanitta uyari doner', async () => {
  setTestEnv();
  const world = createWorld();
  const svc = createServices(world, { inviteCustomer: async () => ({ sent: false }) });
  const tech = world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  world.helpers.addInventory({ uuid: UUID, pin: PIN });
  await svc.deviceService.requestClaimOtp({ actor: { userId: tech.id, globalRole: 'service_user' }, deviceUuid: UUID, targetOwnerIdentifier: 'davetsiz@example.test' });
  const r = await svc.deviceService.claimDevice({
    actor: { userId: tech.id, globalRole: 'service_user' }, deviceUuid: UUID, setupPin: PIN,
    targetOwnerIdentifier: 'davetsiz@example.test', otpCode: svc.mailer.lastCode(),
  });
  assert.ok(r.home_id);
  assert.strictEqual(r.customer_account.invite_sent, false);
  assert.ok(r.warnings && r.warnings.length === 1);
});

test('telefonla hedef: OTP hesabin e-postasina gider ve ayni kimlikle dogrulanir', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  const code = await requestOtp(ctx, tech, '+90 555 111 22 33');
  assert.strictEqual(ctx.mailer.sent[0].to, ctx.customer.email, 'kod hesabin e-postasina gonderilmeli');
  const r = await claim(ctx, tech, { targetOwnerIdentifier: '+905551112233', otpCode: code });
  assert.strictEqual(ctx.world.state.devices[0].claimed_by, ctx.customer.id);
  assert.ok(r.home_id);
});

test('kayitsiz telefon numarasi hedef olamaz (e-posta zorunlu); sahte e-posta uretilmez', async () => {
  const ctx = setup();
  const tech = ctx.world.helpers.addUser({ email: 'teknisyen@example.test', role: 'service_user' });
  await expectHttp(
    ctx.deviceService.requestClaimOtp({ actor: ctx.act(tech), deviceUuid: UUID, targetOwnerIdentifier: '+905559998877' }),
    400, 'VALIDATION'
  );
  assert.ok(!ctx.world.state.users.some((u) => /@ahbu\.com$/.test(u.email)));
});

test('super_user kendi adina sahiplenebilir (hedef zorunlu degil) ve servis uyeligi eklenmez', async () => {
  const ctx = setup();
  const root = ctx.world.helpers.addUser({ email: 'root@example.test', role: 'super_user' });
  const r = await claim(ctx, root);
  const members = ctx.world.state.home_users.filter((m) => m.home_id === r.home_id);
  assert.deepStrictEqual(members.map((m) => [m.user_id, m.role]), [[root.id, 'owner']]);
});

test('uretim kodunda sabit parola, Math.random ve sahte e-posta kalintisi yok', () => {
  const src = require('fs').readFileSync(require.resolve('../../src/services/device_service'), 'utf8');
  assert.ok(!/Ahbu2026/.test(src), 'sabit parola kalintisi');
  assert.ok(!/Math\.random\s*\(/.test(src), 'Math.random');
  assert.ok(!/@ahbu\.com/.test(src), 'sahte e-posta uretimi');
  assert.ok(!/ensureOtpTable|CREATE TABLE/i.test(src), 'calisma zamani DDL');
  assert.ok(!/db\.query\(\s*['"`]BEGIN/.test(src), 'db.query(BEGIN) kullanilmamali');
  assert.ok(!/mqttBridge\.publish\(/.test(src), 'olmayan mqttBridge.publish cagrisi');
  assert.ok(!/E8:F6:0A:DD:87:54/.test(src), 'sabit yedek MAC');
  assert.ok(!/setup_pin = '/.test(src), 'duz metin setup_pin yazimi');
});

// ------------------------------------------------------------------------------------------------
// Kenar durumlar: musteri daveti, konu kimligi cakismasi, eski cihaz kimligi baglantisi
// ------------------------------------------------------------------------------------------------
test('musteri daveti: createAccountSetupInvite tercih edilir; yoksa requestPasswordReset yedegi; hatalar claim\'i bozmaz (sent:false)', async () => {
  setTestEnv();
  const world = createWorld();
  const calls = [];
  const build = (authService) => createServices(world, { inviteCustomer: undefined, authService }).deviceService;
  const args = { userId: 'u1', email: 'a@example.test', fullName: 'A' };

  let svc = build({ createAccountSetupInvite: async (a) => { calls.push(['invite', a.userId, a.email]); return { sent: true }; } });
  assert.deepStrictEqual(await svc._inviteCustomer(args), { sent: true });

  svc = build({ createAccountSetupInvite: async () => ({ sent: false }) });
  assert.strictEqual((await svc._inviteCustomer(args)).sent, false, 'sent:false sonucu basari sayilmaz');

  svc = build({ requestPasswordReset: async (email) => { calls.push(['reset', email]); } });
  assert.deepStrictEqual(await svc._inviteCustomer(args), { sent: true, via: 'password_reset' });

  svc = build({ createAccountSetupInvite: async () => { throw new Error('smtp down'); } });
  assert.deepStrictEqual(await svc._inviteCustomer(args), { sent: false, reason: 'INVITE_FAILED' });
  svc = build({ requestPasswordReset: async () => { throw new Error('smtp down'); } });
  assert.deepStrictEqual(await svc._inviteCustomer(args), { sent: false, reason: 'INVITE_FAILED' });

  svc = build({});
  assert.deepStrictEqual(await svc._inviteCustomer(args), { sent: false, reason: 'NO_INVITE_API' });

  svc = createServices(world, { inviteCustomer: async () => { throw new Error('x'); } }).deviceService;
  assert.deepStrictEqual(await svc._inviteCustomer(args), { sent: false, reason: 'INVITE_FAILED' });

  assert.deepStrictEqual(calls, [['invite', 'u1', 'a@example.test'], ['reset', 'a@example.test']]);
});

test('ev konu kimligi 5 denemede de cakisirsa 500 INTERNAL (sonsuz dongu yok); cihaz/envanter degismez', async () => {
  const ctx = setup();
  const taken = ctx.world.helpers.addHome({ name: 'Baska', topic: 'h_0123456789abcdef' });
  let calls = 0;
  ctx.credentials.generateTopicId = () => {
    calls += 1;
    return taken.mqtt_username;
  };
  await expectHttp(claim(ctx, ctx.customer), 500, 'INTERNAL');
  assert.strictEqual(calls, 5);
  assert.strictEqual(ctx.world.state.devices.length, 0);
  assert.strictEqual(ctx.inv.status, 'IN_STOCK');
  assert.strictEqual(ctx.world.state.homes.length, 1, 'yeni ev yazilmadi (rollback)');
});

test('bosta kalmis eski cihaz kimligi: claim yeni kimlik uretir; eski baglanti atilamazsa UYARI doner (claim basarili)', async () => {
  const ctx = setup();
  const home = ctx.world.helpers.addHome({ name: 'Bos Daire', owner: ctx.customer });
  const stale = await ctx.credentials.issueDeviceCredential({ homeId: home.id });
  process.env.EMQX_API_URL = 'http://emqx.test.invalid:18083';
  process.env.EMQX_API_KEY = 'test-key';
  process.env.EMQX_API_SECRET = 'test-secret';
  ctx.fetchFn.failAll = true;

  const r = await claim(ctx, ctx.customer);
  assert.strictEqual(r.home_id, home.id, 'sahibin cihazsiz evi kullanilir');
  assert.ok(r.warnings.some((w) => /Eski cihaz bağlantısı atılamadı/.test(w)), JSON.stringify(r.warnings));

  const rows = ctx.world.state.mqtt_credentials.filter((c) => c.kind === 'device');
  assert.strictEqual(rows.length, 1, 'evde tek cihaz kimligi');
  assert.ok(!bcrypt.compareSync(stale.password, rows[0].password_hash), 'eski parola gecersiz olmali');
  assert.ok(bcrypt.compareSync(r.device_credential.password, rows[0].password_hash), 'yeni parola gecerli olmali');
});
