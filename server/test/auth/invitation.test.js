'use strict';

// A9: davet / katilim / uye listesi / uye cikarma.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const express = require('express');
const request = require('supertest');
const { setTestEnv, installFakeDb, makeAccessToken, makeServiceToken } = require('./_helpers');
const { createHomeStore } = require('./_home_store');

setTestEnv();
const fakeDb = installFakeDb();
const store = createHomeStore().install(fakeDb);

const auth = require('../../src/middlewares/auth_middleware');
const invitationRoutes = require('../../src/routes/invitation_routes');
const InvitationService = require('../../src/services/invitation_service');
const { errorHandler } = require('../../src/middlewares/error_handler');

auth.configureAuthMiddleware({ cacheTtlMs: 0 });

const mqttCalls = [];
InvitationService.setMqttCredentialService({
  revokeUserAccess: async (args) => { mqttCalls.push(['revokeUserAccess', args.homeId, args.userId, Boolean(args.tx)]); return { revoked: 1, usernames: [`a_${args.userId}`] }; },
  kickUsernames: async (names) => { mqttCalls.push(['kick', names]); return { kicked: names.length, failed: 0, skipped: false }; },
});

const app = express();
app.use(express.json());
app.use('/api/v1', invitationRoutes);
app.use(errorHandler);

const HOME = store.addHome({ name: 'Davet Evi' });
const OTHER = store.addHome({ name: 'Diger Ev' });
const owner = store.addUser({ full_name: 'Sahip', email: 'sahip@example.com', phone: '+905551230000' });
const owner2 = store.addUser({ full_name: 'Ikinci Sahip' });
const resident = store.addUser({ full_name: 'Sakin', email: 'sakin@example.com', phone: '+905551230001' });
const guest = store.addUser({ full_name: 'Misafir' });
const expiredGuest = store.addUser({ full_name: 'Eski Misafir' });
const staff = store.addUser({ role: 'service_user' });
const superUser = store.addUser({ role: 'super_user' });
const stranger = store.addUser();
const otherOwner = store.addUser();
store.addMember(HOME, owner, 'owner');
store.addMember(HOME, resident, 'resident');
store.addMember(HOME, guest, 'guest', { valid_from: new Date(Date.now() - 3600e3), valid_until: new Date(Date.now() + 3600e3) });
store.addMember(HOME, expiredGuest, 'guest', { valid_from: new Date(Date.now() - 7200e3), valid_until: new Date(Date.now() - 3600e3) });
store.addMember(HOME, staff, 'service_user');
store.addMember(OTHER, otherOwner, 'owner');

const T = (u) => `Bearer ${makeAccessToken(u)}`;
const SVC_SID = crypto.randomUUID();
store.sessions.push({ id: SVC_SID, home_id: HOME.id, technician_name: 'T', expires_at: new Date(Date.now() + 3600e3), revoked_at: null });
const SVC = `Bearer ${makeServiceToken({ sid: SVC_SID, home_id: HOME.id })}`;

const invite = (who, body = {}) => request(app).post(`/api/v1/homes/${HOME.id}/invitations`).set('Authorization', who).send(body);
const join = (who, code) => request(app).post('/api/v1/homes/join').set('Authorization', who).send({ code });

test.beforeEach(() => {
  mqttCalls.length = 0;
});

// hesap-uyelik-7: ara katman (requireHomeAccess) uyeligi okuduktan SONRA ama servis INSERT'inden ONCE sahiplik gider
// (es zamanli devir kabulu): ilk uyelik okumasindan sonra satir silinir.
function dropMembershipAfterMiddleware(home, user) {
  let fired = false;
  fakeDb.on(/FROM home_users\s+WHERE home_id = \$1 AND user_id = \$2/, async (p, t) => {
    const out = await store.handle(p, t);
    if (!fired && /installer_expires_at/.test(t) && p[0] === home.id && p[1] === user.id) {
      fired = true;
      store.members = store.members.filter((m) => !(m.home_id === home.id && m.user_id === user.id));
    }
    return out;
  });
}
const txSlice = (re) => {
  const texts = fakeDb.calls.map((c) => c.text);
  const begin = texts.lastIndexOf('BEGIN');
  return texts.slice(begin, texts.indexOf('COMMIT', begin) + 1).filter((t) => t === 'BEGIN' || t === 'COMMIT' || re.test(t));
};

test('hesap-uyelik-7: davet uretimi yetkiyi INSERT ile ayni islemde FOR SHARE ile yeniden dogrular; ara katmandan sonra sahiplik giderse 403, davet yok', async () => {
  const h = store.addHome({ name: 'Yaris Evi' });
  const seller = store.addUser();
  store.addMember(h, seller, 'owner');
  const before = store.invitations.length;
  dropMembershipAfterMiddleware(h, seller);
  const r = await request(app).post(`/api/v1/homes/${h.id}/invitations`).set('Authorization', T(seller)).send({ role: 'resident' });
  assert.strictEqual(r.status, 403, JSON.stringify(r.body));
  assert.strictEqual(r.body.code, 'FORBIDDEN');
  assert.strictEqual(r.body.message, 'Bu işlem için yetkiniz yok.');
  assert.strictEqual(store.invitations.length, before, 'davet uretilmedi');
  // yetkili sahip: denetim ve INSERT ayni islemde (BEGIN ... FOR SHARE ... INSERT ... COMMIT)
  const ok = await invite(T(owner), { role: 'resident' });
  assert.strictEqual(ok.status, 201, JSON.stringify(ok.body));
  const seq = txSlice(/FOR SHARE|INSERT INTO home_invitations/).map((t) => (/FOR SHARE/.test(t) ? 'share' : /INSERT/.test(t) ? 'insert' : t));
  assert.deepStrictEqual(seq, ['BEGIN', 'share', 'insert', 'COMMIT']);
  // global rolle gelen super kullanici: uyelik gerekmez (mevcut denetim korunur)
  assert.strictEqual((await invite(T(superUser), { role: 'resident' })).status, 201);
});

test('davet: owner -> 201, kod "AHBU-" + 10 karakter, QR, DB de yalnizca ozet', async () => {
  const res = await invite(T(owner), { role: 'resident' });
  assert.strictEqual(res.status, 201, JSON.stringify(res.body));
  const d = res.body.data;
  assert.match(d.code, /^AHBU-[A-Z0-9]{10}$/);
  assert.strictEqual(d.invite_code, d.code);
  assert.strictEqual(d.qr_payload, `AHBU-INVITE:${d.code}`);
  assert.strictEqual(d.role, 'resident');
  const row = store.invitations[store.invitations.length - 1];
  assert.strictEqual(row.invite_code, null);
  assert.strictEqual(row.code_hash, crypto.createHash('sha256').update(d.code).digest('hex'));
});

test('davet: eski "member" rolu "resident" e cevrilir; "owner" ve bilinmeyen rol 400', async () => {
  assert.strictEqual((await invite(T(owner), { role: 'member' })).body.data.role, 'resident');
  assert.strictEqual((await invite(T(owner), { role: 'owner' })).status, 400);
  assert.strictEqual((await invite(T(owner), { role: 'admin' })).status, 400);
});

test('davet: misafir suresi <= 72 saat, baslangic < bitis, gecmis baslangic yok', async () => {
  const now = Date.now();
  assert.strictEqual((await invite(T(owner), { role: 'guest', duration_hours: 73 })).status, 400);
  assert.strictEqual((await invite(T(owner), { role: 'guest', duration_hours: 0 })).status, 400);
  assert.strictEqual((await invite(T(owner), { role: 'guest', valid_from: new Date(now + 7200e3).toISOString(), valid_until: new Date(now + 3600e3).toISOString() })).status, 400);
  assert.strictEqual((await invite(T(owner), { role: 'guest', valid_from: new Date(now).toISOString(), valid_until: new Date(now + 73 * 3600e3).toISOString() })).status, 400);
  assert.strictEqual((await invite(T(owner), { role: 'guest', valid_from: new Date(now - 86400e3).toISOString() })).status, 400);
  assert.strictEqual((await invite(T(owner), { role: 'guest', valid_from: 'tarih-degil' })).status, 400);
  const ok = await invite(T(owner), { role: 'guest', duration_hours: 72, guest_name: 'Temizlikci' });
  assert.strictEqual(ok.status, 201);
  const d = ok.body.data;
  const span = new Date(d.guest_valid_until) - new Date(d.guest_valid_from);
  assert.strictEqual(span, 72 * 3600e3);
  // camelCase de kabul edilir
  assert.strictEqual((await invite(T(owner), { role: 'guest', durationHours: 4 })).status, 201);
});

test('davet: super_user 201; resident/misafir/staff/servis oturumu/yabanci/baska ev sahibi 403', async () => {
  assert.strictEqual((await invite(T(superUser), { role: 'resident' })).status, 201);
  for (const who of [T(resident), T(guest), T(staff), SVC, T(stranger), T(otherOwner)]) {
    const r = await invite(who, { role: 'resident' });
    assert.strictEqual(r.status, 403, JSON.stringify(r.body));
  }
  assert.strictEqual((await invite(T(expiredGuest), { role: 'resident' })).body.code, 'GUEST_EXPIRED');
});

test('katilim: QR onekiyle ve kucuk harfle calisir; ikinci kullanim 410', async () => {
  const code = (await invite(T(owner), { role: 'resident' })).body.data.code;
  const u = store.addUser();
  const r = await join(T(u), `ahbu-invite:${code.toLowerCase()}`);
  assert.strictEqual(r.status, 200, JSON.stringify(r.body));
  assert.strictEqual(r.body.data.home.id, HOME.id);
  assert.strictEqual(r.body.data.home.role, 'resident');
  assert.strictEqual(r.body.data.already_member, false);
  assert.strictEqual(store.member(HOME.id, u.id).role, 'resident');
  const u2 = store.addUser();
  const again = await join(T(u2), code);
  assert.strictEqual(again.status, 410);
  assert.strictEqual(store.member(HOME.id, u2.id), undefined);
});

test('hesap-uyelik-5 (C3): ayni kullanici ayni kodla yeniden katilir -> 200 already_member, yazim yok; uye degilse / baska kullanici 410', async () => {
  const code = (await invite(T(owner), { role: 'resident' })).body.data.code;
  const u = store.addUser();
  assert.strictEqual((await join(T(u), code)).status, 200);
  const inv = store.invitations.find((i) => i.used_by === u.id);
  const snapshot = JSON.stringify({ members: store.members, used_at: inv.used_at });
  const again = await join(T(u), code);
  assert.strictEqual(again.status, 200, JSON.stringify(again.body));
  assert.strictEqual(again.body.message, 'Bu davet kodunu zaten kullandınız; dairenin üyesisiniz.');
  assert.strictEqual(again.body.data.already_member, true);
  assert.deepStrictEqual(again.body.data.home, { id: HOME.id, name: 'Davet Evi', address: null, role: 'resident', valid_from: null, valid_until: null });
  assert.strictEqual(JSON.stringify({ members: store.members, used_at: inv.used_at }), snapshot, 'yazim yok');
  // kodu kullanan baska kullanici degil: 410 aynen (numaralandirma yok)
  const other = store.addUser();
  assert.strictEqual((await join(T(other), code)).status, 410);
  // kodu kullanan artik uye degil: 410
  store.members = store.members.filter((m) => !(m.home_id === HOME.id && m.user_id === u.id));
  assert.strictEqual((await join(T(u), code)).status, 410);
});

test('katilim: eszamanli iki kullanici ayni kodu kullanirsa yalnizca biri katilir', async () => {
  const code = (await invite(T(owner), { role: 'resident' })).body.data.code;
  const a = store.addUser();
  const b = store.addUser();
  const [ra, rb] = await Promise.all([join(T(a), code), join(T(b), code)]);
  assert.deepStrictEqual([ra.status, rb.status].sort(), [200, 410]);
  const joined = [a, b].filter((u) => store.member(HOME.id, u.id));
  assert.strictEqual(joined.length, 1);
});

test('katilim: gecersiz kod 404, bozuk bicim 400, suresi dolmus 410', async () => {
  const u = store.addUser();
  assert.strictEqual((await join(T(u), 'AHBU-ZZZZZZZZZZ')).status, 404);
  assert.strictEqual((await join(T(u), 'AHBU-123')).status, 400);
  const code = (await invite(T(owner), { role: 'resident' })).body.data.code;
  store.invitations[store.invitations.length - 1].expires_at = new Date(Date.now() - 1000);
  assert.strictEqual((await join(T(u), code)).status, 410);
});

test('katilim: zaten uye -> already_member, davet TUKETILMEZ', async () => {
  const code = (await invite(T(owner), { role: 'resident' })).body.data.code;
  const r = await join(T(resident), code);
  assert.strictEqual(r.status, 200);
  assert.strictEqual(r.body.data.already_member, true);
  assert.strictEqual(store.invitations[store.invitations.length - 1].is_used, false);
});

test('katilim: misafir yeni misafir davetiyle sure yeniler; aile davetiyle sakine yukselir', async () => {
  const g = store.addUser();
  store.addMember(HOME, g, 'guest', { valid_from: new Date(Date.now() - 3600e3), valid_until: new Date(Date.now() + 600e3) });
  const gcode = (await invite(T(owner), { role: 'guest', duration_hours: 10 })).body.data.code;
  const r1 = await join(T(g), gcode);
  assert.strictEqual(r1.status, 200);
  assert.ok(new Date(store.member(HOME.id, g.id).valid_until).getTime() > Date.now() + 9 * 3600e3);
  const rcode = (await invite(T(owner), { role: 'resident' })).body.data.code;
  await join(T(g), rcode);
  assert.strictEqual(store.member(HOME.id, g.id).role, 'resident');
  assert.strictEqual(store.member(HOME.id, g.id).valid_until, null);
});

test('katilim: servis oturumu ve tokensiz istek reddedilir; kod gerekli', async () => {
  assert.strictEqual((await join(SVC, 'AHBU-ZZZZZZZZZZ')).status, 403);
  assert.strictEqual((await request(app).post('/api/v1/homes/join').send({ code: 'x' })).status, 401);
  assert.strictEqual((await request(app).post('/api/v1/homes/join').set('Authorization', T(stranger)).send({})).status, 400);
});

test('katilim: kullanici+IP basina 15 dk de 10 deneme -> 429', async () => {
  const u = store.addUser();
  for (let i = 0; i < 10; i++) await join(T(u), 'AHBU-ZZZZZZZZZZ');
  const r = await join(T(u), 'AHBU-ZZZZZZZZZZ');
  assert.strictEqual(r.status, 429);
});

test('uyeler: owner iletisim bilgisini gorur; misafir GOREMEZ; suresi dolmus misafir 403 GUEST_EXPIRED', async () => {
  const o = await request(app).get(`/api/v1/homes/${HOME.id}/members`).set('Authorization', T(owner));
  assert.strictEqual(o.status, 200);
  const sakin = o.body.data.members.find((m) => m.user_id === resident.id);
  assert.strictEqual(sakin.email, 'sakin@example.com');
  assert.strictEqual(sakin.phone, '+905551230001');
  const g = await request(app).get(`/api/v1/homes/${HOME.id}/members`).set('Authorization', T(guest));
  assert.strictEqual(g.status, 200);
  assert.ok(g.body.data.members.every((m) => !('email' in m) && !('phone' in m)));
  const e = await request(app).get(`/api/v1/homes/${HOME.id}/members`).set('Authorization', T(expiredGuest));
  assert.strictEqual(e.status, 403);
  assert.strictEqual(e.body.code, 'GUEST_EXPIRED');
});

test('uyeler: aktif sureli teknisyen bitis zamaniyla gorunur; suresi dolmus teknisyen gizlenir', async () => {
  const activeTech = store.addUser({ role: 'service_user', full_name: 'Aktif Teknisyen' });
  const oldTech = store.addUser({ role: 'service_user', full_name: 'Eski Teknisyen' });
  const until = new Date(Date.now() + 2 * 3600e3);
  store.addMember(HOME, activeTech, 'service_user', { installer_expires_at: until });
  store.addMember(HOME, oldTech, 'service_user', { installer_expires_at: new Date(Date.now() - 1000) });
  const o = await request(app).get(`/api/v1/homes/${HOME.id}/members`).set('Authorization', T(owner));
  const names = o.body.data.members.map((m) => m.full_name);
  assert.ok(names.includes('Aktif Teknisyen'));
  assert.ok(!names.includes('Eski Teknisyen'));
  const t = o.body.data.members.find((m) => m.full_name === 'Aktif Teknisyen');
  assert.strictEqual(new Date(t.valid_until).getTime(), until.getTime());
  assert.strictEqual(t.is_expired, false);
});

test('uyeler: yabanci / baska ev sahibi / servis oturumu 403', async () => {
  for (const who of [T(stranger), T(otherOwner), SVC]) {
    assert.strictEqual((await request(app).get(`/api/v1/homes/${HOME.id}/members`).set('Authorization', who)).status, 403);
  }
});

test('uye cikarma: owner sakini cikarir + bu evdeki MQTT kimlikleri iptal (tx icinde) + commit sonrasi kick', async () => {
  const victim = store.addUser();
  store.addMember(HOME, victim, 'resident');
  const r = await request(app).delete(`/api/v1/homes/${HOME.id}/members/${victim.id}`).set('Authorization', T(owner));
  assert.strictEqual(r.status, 200, JSON.stringify(r.body));
  assert.strictEqual(store.member(HOME.id, victim.id), undefined);
  assert.deepStrictEqual(mqttCalls[0], ['revokeUserAccess', HOME.id, victim.id, true]);
  assert.deepStrictEqual(mqttCalls[1], ['kick', [`a_${victim.id}`]]);
  assert.ok(fakeDb.commits > 0);
});

test('uye cikarma: owner baska owner i cikaramaz (403); kendini cikaramaz (400); olmayan uye 404', async () => {
  store.addMember(HOME, owner2, 'owner');
  assert.strictEqual((await request(app).delete(`/api/v1/homes/${HOME.id}/members/${owner2.id}`).set('Authorization', T(owner))).status, 403);
  assert.strictEqual((await request(app).delete(`/api/v1/homes/${HOME.id}/members/${owner.id}`).set('Authorization', T(owner))).status, 400);
  assert.strictEqual((await request(app).delete(`/api/v1/homes/${HOME.id}/members/${stranger.id}`).set('Authorization', T(owner))).status, 404);
  assert.strictEqual((await request(app).delete(`/api/v1/homes/${HOME.id}/members/gecersiz`).set('Authorization', T(owner))).status, 400);
});

test('uye cikarma: super ikinci owner i cikarabilir ama SON owner i cikaramaz (409)', async () => {
  if (!store.member(HOME.id, owner2.id)) store.addMember(HOME, owner2, 'owner');
  assert.strictEqual((await request(app).delete(`/api/v1/homes/${HOME.id}/members/${owner2.id}`).set('Authorization', T(superUser))).status, 200);
  const last = await request(app).delete(`/api/v1/homes/${HOME.id}/members/${owner.id}`).set('Authorization', T(superUser));
  assert.strictEqual(last.status, 409);
  assert.ok(store.member(HOME.id, owner.id));
});

test('uye cikarma: resident / misafir / staff / servis oturumu / yabanci 403', async () => {
  const target = store.addUser();
  store.addMember(HOME, target, 'guest', { valid_from: new Date(Date.now() - 1000), valid_until: new Date(Date.now() + 3600e3) });
  for (const who of [T(resident), T(guest), T(staff), SVC, T(stranger), T(otherOwner)]) {
    const r = await request(app).delete(`/api/v1/homes/${HOME.id}/members/${target.id}`).set('Authorization', who);
    assert.strictEqual(r.status, 403);
  }
  assert.ok(store.member(HOME.id, target.id));
});

// ---- pano-6: owner/resident cikarilinca yerel anahtar BEKLEYEN yolla doner (tek panolu ev); misafirde donmez ----
test('pano-6: sakin cikarilinca tek panolu evde rotasyon (ayni tx, COMMIT sonrasi uzlastirici); misafir cikarilinca rotasyon yok', async () => {
  const { LocalKeyRotation } = require('../../src/services/local_key_rotation');
  const reconciles = [];
  const fakeBox = { generateLocalKey: () => 'YeniAnahtar0000', encrypt: (k) => `enc(${k.length})` };
  InvitationService.setLocalKeyRotation(new LocalKeyRotation({ secretBox: fakeBox, requestReconcile: (t) => reconciles.push(t), logger: { warn() {}, log() {}, error() {} } }));
  try {
    const home = store.addHome({ name: 'Anahtar Evi' });
    const own = store.addUser();
    const res1 = store.addUser();
    const g1 = store.addUser();
    store.addMember(home, own, 'owner');
    store.addMember(home, res1, 'resident');
    store.addMember(home, g1, 'guest', { valid_from: new Date(Date.now() - 1000), valid_until: new Date(Date.now() + 3600e3) });
    const dev = store.addDevice(home);

    const rg = await request(app).delete(`/api/v1/homes/${home.id}/members/${g1.id}`).set('Authorization', T(own));
    assert.strictEqual(rg.status, 200);
    assert.strictEqual(dev.local_key_pending_enc, null, 'misafir anahtari okuyamaz: rotasyon yok');
    assert.deepStrictEqual(reconciles, []);

    const rr = await request(app).delete(`/api/v1/homes/${home.id}/members/${res1.id}`).set('Authorization', T(own));
    assert.strictEqual(rr.status, 200, JSON.stringify(rr.body));
    assert.ok(dev.local_key_pending_enc, 'bekleyen anahtar yazildi');
    const a = store.audits.filter((x) => x.event === 'local_key_rotation_scheduled' && x.home_id === home.id);
    assert.strictEqual(a.length, 1);
    assert.deepStrictEqual(a[0].details, { reason: 'member_removed' });
    assert.deepStrictEqual(reconciles, [home.mqtt_username]);
  } finally {
    InvitationService.setLocalKeyRotation(undefined);
  }
});

// ---- ev_uyelik-6: uretilmis davetleri listeleme ve iptal ----
const listInv = (who, homeId = HOME.id) => request(app).get(`/api/v1/homes/${homeId}/invitations`).set('Authorization', who);
const delInv = (who, id, homeId = HOME.id) => request(app).delete(`/api/v1/homes/${homeId}/invitations/${id}`).set('Authorization', who);

test('ev_uyelik-6: davet listesi - owner/super 200 (kod DONMEZ, yalniz kullanilmamis + suresi dolmamis, yeniden eskiye), no-store', async () => {
  const a = (await invite(T(owner), { role: 'resident' })).body.data;
  const b = (await invite(T(owner), { role: 'guest', duration_hours: 2, guest_name: 'Komsu' })).body.data;
  const used = (await invite(T(owner), { role: 'resident' })).body.data;
  store.invitations.find((i) => i.id === used.id).is_used = true; // kullanilmis (katilim IP sinirini harcamadan)
  const res = await listInv(T(owner));
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.strictEqual(res.headers['cache-control'], 'no-store');
  const ids = res.body.data.map((i) => i.id);
  assert.ok(ids.includes(a.id) && ids.includes(b.id), 'aktif davetler listelenir');
  assert.ok(!ids.includes(used.id), 'kullanilmis davet listelenmez');
  for (const item of res.body.data) {
    assert.deepStrictEqual(Object.keys(item).sort(), ['created_at', 'expires_at', 'guest_name', 'guest_valid_from', 'guest_valid_until', 'id', 'role']);
  }
  const s = JSON.stringify(res.body);
  assert.ok(!s.includes(a.code) && !s.includes(b.code), 'kod donmez');
  const created = res.body.data.map((i) => new Date(i.created_at).getTime());
  assert.deepStrictEqual(created, [...created].sort((x, y) => y - x), 'yeniden eskiye');
  assert.strictEqual((await listInv(T(superUser))).status, 200);
  // baska evin davetleri sizmaz
  assert.deepStrictEqual((await listInv(T(otherOwner), OTHER.id)).body.data.filter((i) => ids.includes(i.id)), []);
});

test('ev_uyelik-6: davet listesi/iptali - resident, misafir, staff, servis oturumu, yabanci 403', async () => {
  const inv = (await invite(T(owner), { role: 'resident' })).body.data;
  for (const who of [T(resident), T(guest), T(staff), SVC, T(stranger), T(otherOwner)]) {
    assert.strictEqual((await listInv(who)).status, 403);
    assert.strictEqual((await delInv(who, inv.id)).status, 403);
  }
  assert.ok(store.invitations.some((i) => i.id === inv.id), 'davet silinmedi');
});

test('ev_uyelik-6: davet iptali - owner 200 {id} + denetim; iptal sonrasi katilim 404; kullanilmis/bilinmeyen 404; gecersiz kimlik 400', async () => {
  const inv = (await invite(T(owner), { role: 'resident' })).body.data;
  const res = await delInv(T(owner), inv.id);
  assert.strictEqual(res.status, 200, JSON.stringify(res.body));
  assert.deepStrictEqual(res.body.data, { id: inv.id });
  assert.strictEqual(res.headers['cache-control'], 'no-store');
  assert.ok(!store.invitations.some((i) => i.id === inv.id));
  const audit = store.audits.find((x) => x.event === 'invitation_revoked' && x.home_id === HOME.id);
  assert.ok(audit, 'denetim kaydi');
  assert.ok(!JSON.stringify(audit).includes(inv.code), 'kod denetimde yok');
  const j = await join(T(stranger), inv.code);
  assert.strictEqual(j.status, 404, 'iptal edilen kodla katilim yok');
  assert.strictEqual((await delInv(T(owner), inv.id)).status, 404, 'tekrar iptal 404');

  const used = (await invite(T(owner), { role: 'resident' })).body.data;
  store.invitations.find((i) => i.id === used.id).is_used = true;
  assert.strictEqual((await delInv(T(owner), used.id)).status, 404, 'kullanilmis davet iptal edilemez');
  assert.ok(store.invitations.some((i) => i.id === used.id), 'kullanilmis davet gecmisi korunur');
  assert.strictEqual((await delInv(T(owner), 'gecersiz-kimlik')).status, 400);
  // baska evin daveti bu ev uzerinden iptal edilemez
  const foreign = (await request(app).post(`/api/v1/homes/${OTHER.id}/invitations`).set('Authorization', T(otherOwner)).send({ role: 'resident' })).body.data;
  assert.strictEqual((await delInv(T(owner), foreign.id)).status, 404);
  assert.ok(store.invitations.some((i) => i.id === foreign.id));
  // super de iptal edebilir
  const s2 = (await invite(T(owner), { role: 'resident' })).body.data;
  assert.strictEqual((await delInv(T(superUser), s2.id)).status, 200);
});

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
