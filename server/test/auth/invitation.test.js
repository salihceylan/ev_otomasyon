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

test('sahte DB: eslesmeyen SQL yok', () => {
  assert.deepStrictEqual(store.unmatched, []);
});
