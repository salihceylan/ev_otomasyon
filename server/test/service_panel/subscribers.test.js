'use strict';

// WP-B2 / gorev 1: GET /api/v1/service/subscribers (+ /api/ takma yolu)
//   - rol/ev kapsami matrisi (super hepsi; staff yalniz suresi dolmamis servis uyeligi olan evler; digerleri 403)
//   - arama (?q=: ev adi, adres, sahip adi/e-posta/telefon, cihaz UID), sayfalama (?limit=&offset=)
//   - kayit sekli ve iletisim bilgisi yalnizca erisim hakki olan evler icin
//   - yer tutucu (teslim edilemez) e-posta sizdirilmaz

const test = require('node:test');
const assert = require('node:assert/strict');
const { createEnv } = require('./_world');

const env = createEnv();
const { h, api, tokenOf, state } = env;
const URL = '/api/v1/service/subscribers';

// ---- ortak veri: 2 staff, 1 super, 5 ev ----
const staff = h.user({ role: 'service_user', full_name: 'Servis Bir' });
const staff2 = h.user({ role: 'service_user', full_name: 'Servis Iki' });
const sup = h.user({ role: 'super_user', full_name: 'Super' });
const ownerA = h.user({ full_name: 'Ayşe Yılmaz', email: 'ayse@example.test', phone: '+905551110001' });
const ownerB = h.user({ full_name: 'Bora Kaya', email: 'bora@example.test' });
const phoneOwner = h.user({ full_name: 'Telefonlu Kisi', email: 'phone_905551110002@ahbu.local' });
const homeA = h.home({ name: 'Alfa Apartmanı', owner: ownerA, address: 'Gül Sokak 5' });
const homeB = h.home({ name: 'Beta Sitesi', owner: ownerB });
const homeC = h.home({ name: 'Gama Evi' }); // sahipsiz
const homeD = h.home({ name: 'Delta Villa', owner: phoneOwner });
const homeExpired = h.home({ name: 'Süresi Dolmuş Ev', owner: ownerB });
h.member(homeA, staff, 'service_user');
h.member(homeB, staff, 'service_user', { installer_expires_at: new Date(Date.now() + 3600e3) });
h.member(homeExpired, staff, 'service_user', { installer_expires_at: new Date(Date.now() - 3600e3) });
h.member(homeC, staff2, 'service_user');
h.member(homeD, staff2, 'service_user');
const devA1 = h.device(homeA, { online: true, commissioned: true });
const devA2 = h.device(homeA, { online: false });
h.device(homeB, { online: false });

const names = (res) => res.body.data.subscribers.map((s) => s.home_name).sort();

test('super_user tüm evleri görür', async () => {
  const r = await api('get', `${URL}?limit=100`, tokenOf(sup));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.data.total, 5);
  assert.deepEqual(names(r), ['Alfa Apartmanı', 'Beta Sitesi', 'Delta Villa', 'Gama Evi', 'Süresi Dolmuş Ev'].sort());
});

test('staff yalnızca KENDİ (süresi dolmamış) servis üyeliği olan evleri görür; başkasının ve süresi dolmuş ev listelenmez', async () => {
  const r1 = await api('get', URL, tokenOf(staff));
  assert.equal(r1.status, 200);
  assert.deepEqual(names(r1), ['Alfa Apartmanı', 'Beta Sitesi']);
  assert.equal(r1.body.data.total, 2, 'toplam da kapsamla sınırlı');
  const r2 = await api('get', URL, tokenOf(staff2));
  assert.deepEqual(names(r2), ['Delta Villa', 'Gama Evi']);
});

test('iletişim bilgisi kapsam dışı evler için dönmez (staff başka evin sahibini göremez)', async () => {
  const r = await api('get', `${URL}?q=${encodeURIComponent('bora@example.test')}`, tokenOf(staff2));
  assert.equal(r.status, 200);
  assert.equal(r.body.data.total, 0);
  assert.ok(!JSON.stringify(r.body).includes('bora@example.test'));
  assert.ok(!JSON.stringify(r.body).includes('ayse@example.test'));
});

test('kayıt şekli: home_id, home_name, owner{full_name,email,phone,account_status}|null, cihaz sayıları, commissioned_at, last_seen_at', async () => {
  const r = await api('get', `${URL}?q=Alfa`, tokenOf(staff));
  const s = r.body.data.subscribers[0];
  assert.equal(s.home_id, homeA.id);
  assert.equal(s.home_name, 'Alfa Apartmanı');
  assert.equal(s.home_address, 'Gül Sokak 5');
  assert.deepEqual(s.owner, { full_name: 'Ayşe Yılmaz', email: 'ayse@example.test', phone: '+905551110001', account_status: 'active' });
  assert.equal(s.device_count, 2);
  assert.equal(s.online_count, 1);
  assert.equal(s.commissioned_count, 1);
  assert.ok(s.commissioned_at);
  assert.ok(s.last_seen_at);
  assert.deepEqual(s.device_uuids, [devA1.device_uuid, devA2.device_uuid]);
  assert.deepEqual(Object.keys(r.body.data).sort(), ['count', 'limit', 'offset', 'subscribers', 'total']);
  assert.equal(r.headers['cache-control'], 'no-store', 'iletişim bilgisi önbelleğe alınmaz');

  // cihazsız / sahipsiz ev
  const c = await api('get', `${URL}?q=Gama`, tokenOf(staff2));
  assert.deepEqual(
    [c.body.data.subscribers[0].owner, c.body.data.subscribers[0].device_count, c.body.data.subscribers[0].commissioned_at, c.body.data.subscribers[0].last_seen_at],
    [null, 0, null, null]
  );
});

test('yer tutucu e-posta (telefon/Apple hesabı) sızdırılmaz; ad ve telefon görünür', async () => {
  const r = await api('get', `${URL}?q=Delta`, tokenOf(sup));
  const s = r.body.data.subscribers[0];
  assert.equal(s.owner.email, null);
  assert.equal(s.owner.full_name, 'Telefonlu Kisi');
});

test('arama: ev adı, adres, sahip adı/e-posta/telefon ve cihaz UID; büyük/küçük harf duyarsız', async () => {
  const find = async (q, token = tokenOf(sup)) =>
    (await api('get', `${URL}?q=${encodeURIComponent(q)}`, token)).body.data.subscribers.map((s) => s.home_name).sort();
  assert.deepEqual(await find('alfa apart'), ['Alfa Apartmanı']);
  assert.deepEqual(await find('gül sokak'), ['Alfa Apartmanı'], 'adres (küçük harf)');
  assert.deepEqual(await find('Gül Sokak'), ['Alfa Apartmanı'], 'adres');
  assert.deepEqual(await find('Bora Kaya'), ['Beta Sitesi', 'Süresi Dolmuş Ev'].sort());
  assert.deepEqual(await find('ayse@example'), ['Alfa Apartmanı'], 'e-posta');
  assert.deepEqual(await find('+905551110001'), ['Alfa Apartmanı'], 'telefon');
  assert.deepEqual(await find(devA2.device_uuid.toLowerCase()), ['Alfa Apartmanı'], 'cihaz UID (küçük harf)');
  assert.deepEqual(await find('yokboylebirsey'), []);
  // staff aramada da kapsamla sınırlı
  assert.deepEqual(await find('Bora', tokenOf(staff)), ['Beta Sitesi']);
});

test('arama: LIKE joker karakterleri (% _ \\) kaçırılır; her şeyi eşleştirmez', async () => {
  for (const q of ['%', 'Al_a', '\\', 'A%a']) {
    const r = await api('get', `${URL}?q=${encodeURIComponent(q)}`, tokenOf(sup));
    assert.equal(r.status, 200);
    assert.equal(r.body.data.total, 0, `q=${q}`);
  }
  // boş / yalnız boşluk arama = filtre yok; dizi olarak gelen q yok sayılır
  assert.equal((await api('get', `${URL}?q=%20%20`, tokenOf(sup))).body.data.total, 5);
  assert.equal((await api('get', `${URL}?q=a&q=b`, tokenOf(sup))).status, 200);
});

test('sayfalama: limit/offset/total tutarlı; sınırlar kırpılır; geçersiz değer varsayılana düşer', async () => {
  const page = async (qs) => (await api('get', `${URL}?${qs}`, tokenOf(sup))).body.data;
  const p1 = await page('limit=2&offset=0');
  const p2 = await page('limit=2&offset=2');
  const p3 = await page('limit=2&offset=4');
  const p4 = await page('limit=2&offset=6');
  assert.deepEqual([p1.total, p1.count, p1.limit, p1.offset], [5, 2, 2, 0]);
  assert.equal(p2.count, 2);
  assert.equal(p3.count, 1);
  assert.equal(p4.count, 0);
  const all = [...p1.subscribers, ...p2.subscribers, ...p3.subscribers].map((s) => s.home_id);
  assert.equal(new Set(all).size, 5, 'sayfalar çakışmaz ve eksiksiz');
  // sıra kararlı: yeniden oluşturulma sırasının tersi (en yeni ev önce)
  assert.equal(p1.subscribers[0].home_id, homeExpired.id);
  // sınırlar
  assert.equal((await page('limit=1000')).limit, 100);
  assert.equal((await page('limit=0')).limit, 50);
  assert.equal((await page('limit=-5')).limit, 1);
  assert.equal((await page('limit=abc&offset=xyz')).limit, 50);
  assert.equal((await page('limit=abc&offset=xyz')).offset, 0);
  assert.equal((await page('offset=-9')).offset, 0);
});

test('/api/ takma yolu aynı davranır', async () => {
  const r = await api('get', '/api/service/subscribers', tokenOf(staff));
  assert.equal(r.status, 200);
  assert.deepEqual(names(r), ['Alfa Apartmanı', 'Beta Sitesi']);
});

test('yetki matrisi: owner/resident/misafir/normal kullanıcı/servis oturumu 403, kimliksiz 401', async () => {
  const resident = h.user();
  h.member(homeA, resident, 'resident');
  const guest = h.user();
  h.member(homeA, guest, 'guest', { valid_until: new Date(Date.now() + 3600e3) });
  const { session } = h.serviceSession(homeA);
  const normal = h.user();
  const cases = [
    ['owner', tokenOf(ownerA), 403],
    ['resident', tokenOf(resident), 403],
    ['misafir', tokenOf(guest), 403],
    ['normal kullanıcı', tokenOf(normal), 403],
    ['servis oturumu', env.sessionToken(homeA, session), 403],
    ['kimliksiz', null, 401],
  ];
  for (const [label, token, status] of cases) {
    const r = await api('get', URL, token);
    assert.equal(r.status, status, label);
    assert.equal(r.body.success, false);
  }
});

test('pasif/dondurulmuş staff hesabı reddedilir', async () => {
  const frozen = h.user({ role: 'service_user', status: 'suspended' });
  h.member(homeA, frozen, 'service_user');
  const r = await api('get', URL, tokenOf(frozen));
  assert.equal(r.status, 401);
});

test('servis katmanı: actor doğrulaması (kullanıcı kimliği yok / servis oturumu / bilinmeyen rol)', async () => {
  const { ServicePanelService } = env.SRC('services/service_panel_service');
  const svc = new ServicePanelService({ db: { query: async () => ({ rows: [] }) } });
  for (const actor of [null, {}, { userId: ownerA.id, globalRole: 'user' }, { userId: sup.id, globalRole: 'super_user', isServiceSession: true }]) {
    await assert.rejects(svc.listSubscribers({ actor }), (e) => e.status === 403 && e.code === 'FORBIDDEN');
  }
  assert.ok(state.homes.length >= 5);
});
