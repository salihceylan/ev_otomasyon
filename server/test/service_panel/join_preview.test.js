'use strict';

// WP-B2 / gorev 5 (sozlesme taramasi bulgusu): POST /api/v1/homes/join-preview
//   Flutter `previewJoinCode` bu ucu bekler: davet / devir kodunu TUKETMEDEN onizler.
//   - kimlik dogrulamali (servis PIN oturumu HARIC), sert hiz siniri
//   - gecersiz / kullanilmis / suresi dolmus / bilinmeyen kod AYNI yanit: 410 GONE (istemci 404/405'i "uc yok" sayar)
//   - devir kodu hedef kimlikle eslesen hesaba aittir; baskasina 403 ve HICBIR ayrinti sizmaz
//   - hicbir durum degisikligi yok (kod tuketilmez)
//
// Mantik testleri servis katmaninda (hiz sinirina takilmadan), yetki/hiz siniri/yol testleri HTTP uzerinden.

const test = require('node:test');
const assert = require('node:assert/strict');
const { createEnv, uid } = require('./_world');

const env = createEnv();
const { h, state, api, tokenOf } = env;
const InvitationService = env.SRC('services/invitation_service');
const TransferService = env.SRC('services/transfer_service');
const preview = env.SRC('services/join_preview_service');

const URL = '/api/v1/homes/join-preview';
let n = 0;
const INVITE = () => `AHBU-${'ABCDEFGHJK'.slice(0, 7)}${String(100 + (++n)).slice(-3)}`; // AHBU- + 10 karakter
const TRANSFER = () => `AHBU-TR-${'ABCDEFGHJKMNPQRS'.slice(0, 13)}${String(100 + (++n)).slice(-3)}`; // 16 karakter

function addInvite(home, creator, { code = INVITE(), role = 'resident', expiresInMs = 3600e3, used = false, guestUntilMs = null } = {}) {
  state.home_invitations.push({
    id: uid(), home_id: home.id, created_by: creator.id, role, is_used: used, code_hash: InvitationService.hashInviteCode(code),
    expires_at: new Date(Date.now() + expiresInMs), guest_valid_from: role === 'guest' ? new Date(Date.now() - 1000) : null,
    guest_valid_until: role === 'guest' ? new Date(Date.now() + (guestUntilMs ?? expiresInMs)) : null,
  });
  return code;
}
function addTransfer(home, from, target, { code = TRANSFER(), status = 'PENDING', expiresInMs = 3600e3 } = {}) {
  state.home_transfers.push({
    id: uid(), home_id: home.id, from_user_id: from.id, target_identifier: target, status, code_hash: TransferService.hashTransferCode(code),
    expires_at: new Date(Date.now() + expiresInMs),
  });
  return code;
}

const owner = h.user({ full_name: 'Ev Sahibi' });
const home = h.home({ name: 'Önizleme Evi', owner });
h.member(home, h.user(), 'resident');
h.member(home, h.user(), 'resident');
h.member(home, h.user(), 'guest', { valid_until: new Date(Date.now() + 3600e3) });
h.member(home, h.user({ role: 'service_user' }), 'service_user');
const residentCount = () => state.home_users.filter((m) => m.home_id === home.id && ['owner', 'resident'].includes(m.role)).length;
const run = (user, code) => preview.previewCode({ userId: user.id, code });
const post = (token, body) => api('post', URL, token, body);

const rejects = async (promise, status, code) => {
  let caught = null;
  try {
    await promise;
  } catch (e) {
    caught = e;
  }
  assert.ok(caught, `HTTP ${status} ${code} bekleniyordu ama basarili oldu`);
  assert.equal(caught.status, status, `durum ${caught.status}: ${caught.message}`);
  if (code) assert.equal(caught.code, code);
  return caught;
};

test('davet önizleme: ev adı, sakin sayısı (owner + resident), rol, bitiş; kod TÜKETİLMEZ; özet/hedef alanı sızmaz', async () => {
  const joiner = h.user();
  const code = addInvite(home, owner);
  const before = JSON.stringify(state.home_invitations) + JSON.stringify(state.home_users);
  const r = await run(joiner, code);
  assert.deepEqual(
    { ...r, expires_at: typeof r.expires_at },
    { kind: 'invitation', is_transfer: false, home_name: 'Önizleme Evi', resident_count: residentCount(), role: 'resident', expires_at: 'object', already_member: false }
  );
  assert.equal(residentCount(), 3, 'owner + 2 resident (misafir ve servis üyeliği sayılmaz)');
  assert.equal(JSON.stringify(state.home_invitations) + JSON.stringify(state.home_users), before, 'hiçbir durum değişikliği yok');
  assert.ok(!JSON.stringify(r).includes('code_hash'));
  await run(joiner, code); // tekrar önizlenebilir
});

test('kod biçimleri: AHBU-INVITE: öneki, küçük harf, boşluk kabul edilir', async () => {
  const joiner = h.user();
  const code = addInvite(home, owner);
  for (const variant of [`AHBU-INVITE:${code}`, code.toLowerCase(), ` ${code} `, `ahbu-invite:${code.toLowerCase()}`]) {
    assert.equal((await run(joiner, variant)).home_name, 'Önizleme Evi', variant);
  }
});

test('misafir daveti: guest_valid_from/until döner; süresi dolmuş misafir penceresi 410', async () => {
  const joiner = h.user();
  const ok = await run(joiner, addInvite(home, owner, { role: 'guest' }));
  assert.equal(ok.role, 'guest');
  assert.ok(ok.guest_valid_from && ok.guest_valid_until);
  await rejects(run(joiner, addInvite(home, owner, { role: 'guest', expiresInMs: 3600e3, guestUntilMs: -1000 })), 410, 'GONE');
});

test('zaten üye: already_member=true', async () => {
  const member = h.user();
  h.member(home, member, 'resident');
  assert.equal((await run(member, addInvite(home, owner))).already_member, true);
});

test('geçersiz / kullanılmış / süresi dolmuş / bilinmeyen davet AYNI yanıt: 410 GONE (404/405 DEĞİL); biçim hatası 400', async () => {
  const joiner = h.user();
  const messages = [];
  for (const code of [addInvite(home, owner, { used: true }), addInvite(home, owner, { expiresInMs: -1000 }), INVITE()]) {
    const e = await rejects(run(joiner, code), 410, 'GONE');
    messages.push(e.message);
  }
  assert.equal(new Set(messages).size, 1, 'nedene göre farklı mesaj yok (numaralandırma ayrımı yok)');
  for (const bad of ['KISA', 'AHBU-ABC', 'x'.repeat(100), '', undefined, ['AHBU-ABCDEFGHJK'], 5]) {
    await rejects(run(joiner, bad), 400, 'VALIDATION');
  }
  await rejects(preview.previewCode({ userId: 'uuid-degil', code: INVITE() }), 403, 'FORBIDDEN');
});

test('devir önizleme: yalnız HEDEF hesap görür; başka hesap 403 ve hiçbir ayrıntı sızmaz; telefonla hedeflenen devir ve QR öneki', async () => {
  const target = h.user({ email: 'hedef@example.test', phone: '+905559990011' });
  const code = addTransfer(home, owner, 'hedef@example.test');
  const r = await run(target, code);
  assert.deepEqual(
    { ...r, expires_at: typeof r.expires_at },
    { kind: 'transfer', is_transfer: true, home_name: 'Önizleme Evi', resident_count: residentCount(), role: 'owner', expires_at: 'object' }
  );
  assert.ok(!JSON.stringify(r).includes('hedef@example.test'), 'hedef kimlik sızmaz');

  const stranger = h.user({ email: 'baskasi@example.test' });
  const denied = await rejects(run(stranger, code), 403, 'FORBIDDEN');
  assert.ok(!JSON.stringify(denied.message).includes('Önizleme Evi'), 'ev adı sızmaz');
  assert.ok(!denied.message.includes('hedef@example.test'));

  const byPhone = addTransfer(home, owner, '+905559990011');
  assert.equal((await run(target, `AHBU-TRANSFER:${byPhone}`)).kind, 'transfer');
  await rejects(run(stranger, byPhone), 403, 'FORBIDDEN');
});

test('ev_uyelik-2: devir önizleme - hedef hesap servis personeli ya da süper yönetici ise 403 FORBIDDEN (açıklayıcı mesaj); devir değişmez', async () => {
  for (const role of ['service_user', 'super_user']) {
    const staffTarget = h.user({ email: `personel.hedef.${role}@example.test`, role });
    const code = addTransfer(home, owner, `personel.hedef.${role}@example.test`);
    const before = JSON.stringify(state.home_transfers);
    const e = await rejects(run(staffTarget, code), 403, 'FORBIDDEN');
    assert.equal(e.message, 'Servis personeli ve yönetici hesapları daire sahibi olamaz. Devri bir müşteri hesabına yapın.');
    assert.equal(JSON.stringify(state.home_transfers), before, `${role}: devir PENDING kalir`);
  }
});

test('devir önizleme: iptal/süresi dolmuş/tamamlanmış/bilinmeyen kod 410; devri başlatan kendi kodunu önizleyemez (400); kod tüketilmez', async () => {
  const target = h.user({ email: 'hedef2@example.test' });
  for (const [label, code] of [
    ['iptal', addTransfer(home, owner, 'hedef2@example.test', { status: 'CANCELLED' })],
    ['tamamlanmış', addTransfer(home, owner, 'hedef2@example.test', { status: 'COMPLETED' })],
    ['süresi dolmuş', addTransfer(home, owner, 'hedef2@example.test', { expiresInMs: -1000 })],
    ['bilinmeyen', TRANSFER()],
  ]) {
    await rejects(run(target, code), 410, 'GONE');
    assert.ok(label);
  }
  await rejects(run(owner, addTransfer(home, owner, 'baska@example.test')), 400, 'VALIDATION');
  const live = addTransfer(home, owner, 'hedef2@example.test');
  const before = JSON.stringify(state.home_transfers);
  await run(target, live);
  assert.equal(JSON.stringify(state.home_transfers), before, 'devir kodu tüketilmedi / değişmedi');
  await rejects(run(target, 'AHBU-TR-KISA'), 400, 'VALIDATION');
});

test('hesap-uyelik-5 (C3): kodu kullanan üye / devri kabul eden sahip yeniden önizler -> 200 already_member; başkası 410', async () => {
  // davet: kodu kullanan ve hâlâ üye olan kullanıcı -> mevcut rolüyle
  const joined = h.user();
  h.member(home, joined, 'resident');
  const used = addInvite(home, owner, { role: 'guest', used: true });
  state.home_invitations[state.home_invitations.length - 1].used_by = joined.id;
  const r = await run(joined, used);
  assert.equal(r.kind, 'invitation');
  assert.equal(r.is_transfer, false);
  assert.equal(r.already_member, true);
  assert.equal(r.role, 'resident', 'mevcut rol (davetin rolü değil)');
  assert.equal(r.home_name, 'Önizleme Evi');
  await rejects(run(h.user(), used), 410, 'GONE');
  const left = h.user();
  const usedLeft = addInvite(home, owner, { used: true });
  state.home_invitations[state.home_invitations.length - 1].used_by = left.id;
  await rejects(run(left, usedLeft), 410, 'GONE');

  // devir: tamamlanmış devri kabul eden ve hâlâ sahip olan kullanıcı
  const newOwner = h.user({ email: 'devralan@example.test' });
  const tHome = h.home({ name: 'Devredilen Ev', owner: newOwner });
  const done = addTransfer(tHome, owner, 'devralan@example.test', { status: 'COMPLETED' });
  state.home_transfers[state.home_transfers.length - 1].accepted_by = newOwner.id;
  const t = await run(newOwner, done);
  assert.deepEqual([t.kind, t.is_transfer, t.role, t.already_member, t.home_name], ['transfer', true, 'owner', true, 'Devredilen Ev']);
  await rejects(run(h.user({ email: 'devralan2@example.test' }), done), 410, 'GONE');
  state.home_users = state.home_users.filter((m) => !(m.home_id === tHome.id && m.user_id === newOwner.id));
  await rejects(run(newOwner, done), 410, 'GONE');
});

test('HTTP: başarılı yanıt sarmalayıcısı (success/data), önbelleksiz; /api/ takma yolu; alan adı takma adları (invite_code, inviteCode)', async () => {
  const user = h.user();
  const code = addInvite(home, owner);
  const r = await post(tokenOf(user), { code });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.success, true);
  assert.equal(r.body.data.kind, 'invitation');
  assert.equal(r.headers['cache-control'], 'no-store');
  assert.equal((await api('post', '/api/homes/join-preview', tokenOf(user), { invite_code: code })).status, 200);
  assert.equal((await post(tokenOf(user), { inviteCode: code })).status, 200);
  assert.equal((await post(tokenOf(user), {})).status, 400);
  const gone = await post(tokenOf(user), { code: INVITE() });
  assert.equal(gone.status, 410);
  assert.equal(gone.body.code, 'GONE');
});

test('HTTP yetki: kimliksiz 401; servis PIN oturumu 403', async () => {
  const code = addInvite(home, owner);
  assert.equal((await post(null, { code })).status, 401);
  const { session } = h.serviceSession(home);
  assert.equal((await post(env.sessionToken(home, session), { code })).status, 403);
});

test('HTTP hız sınırı: kullanıcı başına 15 dk\'da 10 önizleme; aşımda 429 RATE_LIMITED + Retry-After', async () => {
  const user = h.user();
  const code = addInvite(home, owner);
  const statuses = [];
  for (let i = 0; i < 12; i++) statuses.push((await post(tokenOf(user), { code })).status);
  assert.deepEqual(statuses, [200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 429, 429]);
  const limited = await post(tokenOf(user), { code });
  assert.equal(limited.body.code, 'RATE_LIMITED');
  assert.ok(Number(limited.headers['retry-after']) >= 1);
});
