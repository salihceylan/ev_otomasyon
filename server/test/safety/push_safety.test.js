'use strict';

// WP-S3 - Guvenlik push'u (tasarim §5.2.3, kararlar §7.2b-3/4):
//   - `safety_alarm`: Android yuksek oncelik + `safety_alarm` kanali + 6 sa ttl; APNs priority 10 +
//     interruption-level `time-sensitive` (kritik izin basvurusu YOK); collapse alarm_<home>_<device>_<zone>;
//     kategori SAFETY_ALARM; veri yalniz dizge ve bilinen alanlar.
//   - `safety_info` (alarm durumu dogrulanamadi / politika degisti): yalniz owner'a, bilgi kanali.
//   - Alicilar: owner + resident; MISAFIR ve servis rolleri ALMAZ (§7.2b-4). Bilgi push'u yalniz owner.
//   - Varsayilan tur (gece huzur) mesaji AYNEN.

const test = require('node:test');
const assert = require('node:assert/strict');

const { createPushService, buildMessage } = require('../../src/services/push_service');
const H = require('../peace/_push_helpers');

const DEV = '22222222-3333-4444-8555-666666666666';

test('buildMessage(safety_alarm): kanal, oncelik, ttl, collapse, APNs time-sensitive, kategori, veri', () => {
  const msg = buildMessage({
    token: H.FAKE_TOKEN_A,
    title: 'Su baskını',
    body: 'Mutfak: vana kapatıldı',
    kind: 'safety_alarm',
    data: { home_id: H.HOME_ID, device_id: DEV, alarm_id: 42, zone: 1, kind: 'water', status: 'latched', secret: 'x' },
    nowMs: 1_800_000_000_000,
  }).message;
  const collapse = `alarm_${H.HOME_ID}_${DEV}_1`;
  assert.deepEqual(msg.data, {
    type: 'safety_alarm', v: '1', home_id: H.HOME_ID, device_id: DEV, alarm_id: '42', zone: '1', kind: 'water', status: 'latched',
  });
  assert.ok(Object.values(msg.data).every((v) => typeof v === 'string'));
  assert.equal(msg.android.priority, 'HIGH');
  assert.equal(msg.android.ttl, '21600s');
  assert.equal(msg.android.collapse_key, collapse);
  assert.equal(msg.android.notification.channel_id, 'safety_alarm');
  assert.equal(msg.apns.headers['apns-priority'], '10');
  assert.equal(msg.apns.headers['apns-collapse-id'], collapse);
  assert.equal(msg.apns.headers['apns-expiration'], String(1_800_000_000 + 21600));
  assert.equal(msg.apns.payload.aps.category, 'SAFETY_ALARM');
  assert.equal(msg.apns.payload.aps['interruption-level'], 'time-sensitive');
  assert.equal(msg.apns.payload.aps.sound, 'default');
  assert.equal(JSON.stringify(msg).includes('critical'), false, 'kritik uyari izni yok (§7.2b-3)');
});

test('buildMessage(safety_info): bilgi kanali, normal oncelik; bilinmeyen tur gece huzur bicimine duser (geri uyum)', () => {
  const msg = buildMessage({
    token: H.FAKE_TOKEN_A, title: 'Alarm', body: 'Doğrulanamadı', kind: 'safety_info',
    data: { home_id: H.HOME_ID, device_id: DEV, alarm_id: 7, reason: 'alarm_lost' }, nowMs: 0,
  }).message;
  assert.equal(msg.data.type, 'safety_info');
  assert.equal(msg.data.reason, 'alarm_lost');
  assert.equal(msg.android.notification.channel_id, 'safety_info');
  assert.equal(msg.apns.payload.aps.category, 'SAFETY_INFO');
  // tur verilmezse / bilinmiyorsa eski (peace) mesaj AYNEN
  const a = buildMessage({ token: H.FAKE_TOKEN_A, title: 'T', body: 'B', data: { home_id: H.HOME_ID }, nowMs: 0 });
  const b = buildMessage({ token: H.FAKE_TOKEN_A, title: 'T', body: 'B', data: { home_id: H.HOME_ID }, nowMs: 0, kind: 'peace' });
  assert.deepEqual(a, b);
  assert.equal(a.message.data.type, 'peace_open_devices');
  assert.equal(a.message.android.notification.channel_id, 'peace_reminder');
});

test('recipientsForHome({roles}): yalniz owner/resident alt kumesi; misafir/servis istense de SQL\'e girmez', async () => {
  const db = H.createFakeDb(() => []);
  const push = createPushService({ db, logger: H.createLogger(), env: H.CONFIGURED_ENV });
  await push.recipientsForHome(H.HOME_ID, { roles: ['owner'] });
  const { text, params } = db.calls[0];
  assert.match(text, /hu\.role = ANY\(\$4::text\[\]\)/);
  assert.deepEqual(params[3], ['owner']);
  await push.recipientsForHome(H.HOME_ID, { roles: ['owner', 'guest', 'service_user', 'resident'] });
  assert.deepEqual(db.calls[1].params[3], ['owner', 'resident']);
  // gecerli rol kalmazsa sorgu YAPILMAZ, bos liste
  assert.deepEqual(await push.recipientsForHome(H.HOME_ID, { roles: ['guest'] }), []);
  assert.equal(db.calls.length, 2);
  // secenek yoksa SQL AYNEN (3 parametre)
  await push.recipientsForHome(H.HOME_ID);
  assert.equal(db.calls[2].params.length, 3);
  assert.doesNotMatch(db.calls[2].text, /ANY\(\$4/);
});

test('sendNotice(kind): FCM govdesi turun mesajidir; yapilandirilmamissa ag yok + PUSH_NOT_CONFIGURED', async () => {
  const fetchImpl = H.createFakeFetch();
  const push = createPushService({
    db: H.createFakeDb(), logger: H.createLogger(), env: H.CONFIGURED_ENV, fetchImpl,
    authFactory: H.createFakeAuthFactory(), now: () => 1_800_000_000_000,
  });
  const r = await push.sendNotice({
    tokens: [H.FAKE_TOKEN_A], title: 'Su baskını', body: 'Vana kapatıldı', kind: 'safety_alarm',
    data: { home_id: H.HOME_ID, device_id: DEV, alarm_id: 1, zone: 2, kind: 'water', status: 'latched' },
  });
  assert.equal(r.sent, 1);
  assert.equal(fetchImpl.calls[0].body.message.data.type, 'safety_alarm');
  assert.equal(fetchImpl.calls[0].body.message.android.notification.channel_id, 'safety_alarm');

  const off = createPushService({ db: H.createFakeDb(), logger: H.createLogger(), env: {}, fetchImpl });
  const r2 = await off.sendNotice({ tokens: [H.FAKE_TOKEN_A], title: 'x', body: 'y', kind: 'safety_alarm', data: {} });
  assert.deepEqual(r2.errors, [{ code: 'PUSH_NOT_CONFIGURED' }]);
  assert.equal(fetchImpl.calls.length, 1);
});
