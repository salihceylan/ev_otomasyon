'use strict';

// push_service: FCM v1 gönderimi, hata sınıflaması, token deposu, log sızıntısı. Ağ/DB YOK (sahteler).

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  createPushService,
  MESSAGE_VERSION,
  MAX_ACTIVE_TOKENS_PER_USER,
  MAX_RECIPIENT_TOKENS_PER_USER,
  buildMessage,
  defaultAuthFactory,
  FCM_SCOPE,
} = require('../../src/services/push_service');
const H = require('./_push_helpers');

const NOTICE = {
  title: 'Gül Apartmanı 5',
  body: 'Salonda 2, Mutfakta 1 lamba, 1 panjur açık. Işık çok.',
  data: { home_id: H.HOME_ID, notice_id: 42, open_lights: 3, open_shutters: 1 },
};

function setup({ env = H.CONFIGURED_ENV, responder, authTokens, authOpts, dbHandler, now, ...rest } = {}) {
  const fetchImpl = H.createFakeFetch(responder);
  const authFactory = H.createFakeAuthFactory(authTokens, authOpts);
  const logger = H.createLogger();
  const db = H.createFakeDb(dbHandler);
  const push = createPushService({
    db, logger, fetchImpl, authFactory, env, now: now || (() => 1_800_000_000_000), ...rest,
  });
  return { push, fetchImpl, authFactory, logger, db };
}

test('MESSAGE_VERSION 1', () => {
  assert.equal(MESSAGE_VERSION, 1);
});

test('modül kimlik bilgisi olmadan yüklenir; google-auth-library yalnızca varsayılan factory içinde istenir', () => {
  // require zaten yukarıda başarılı oldu. Varsayılan factory yalnızca nesne kurar (ağ/dosya yok).
  const auth = defaultAuthFactory({ keyFile: '/nonexistent/x.json', scopes: [FCM_SCOPE] });
  assert.equal(typeof auth.getAccessToken, 'function');
});

// ---------------------------------------------------------------------------
// isConfigured / yapılandırılmamış
// ---------------------------------------------------------------------------
test('isConfigured: yalnızca değişken adlarına bakar', () => {
  const mk = (env) => createPushService({ env, db: H.createFakeDb(), logger: H.createLogger() }).isConfigured();
  assert.equal(mk({}), false);
  assert.equal(mk({ FCM_PROJECT_ID: 'p' }), false);
  assert.equal(mk({ FCM_SERVICE_ACCOUNT_FILE: '/x.json' }), false);
  assert.equal(mk({ FCM_PROJECT_ID: '  ', FCM_SERVICE_ACCOUNT_FILE: '/x.json' }), false);
  assert.equal(mk({ FCM_PROJECT_ID: 'p', FCM_SERVICE_ACCOUNT_FILE: '/x.json' }), true);
  assert.equal(mk({ FCM_PROJECT_ID: 'p', GOOGLE_APPLICATION_CREDENTIALS: '/x.json' }), true);
  // Gömülü JSON (özel anahtarı ortam değişkenine koymak) bilerek desteklenmez: yalnızca dosya yolu.
  assert.equal(mk({ FCM_PROJECT_ID: 'p', FCM_SERVICE_ACCOUNT_JSON: '{"a":1}' }), false);
});

test('yapılandırma yok -> ağa ve kimlik üreticisine HİÇ çıkmaz, fırlatmaz', async () => {
  const { push, fetchImpl, authFactory, db } = setup({ env: {} });
  const r = await push.sendNotice({ tokens: [{ id: 'i1', token: H.FAKE_TOKEN_A }], ...NOTICE });
  assert.deepEqual(r, {
    attempted: 0, sent: 0, failed: 0, disabledTokenIds: [], transient: false, errors: [{ code: 'PUSH_NOT_CONFIGURED' }],
  });
  assert.equal(fetchImpl.calls.length, 0);
  assert.equal(authFactory.calls.length, 0);
  assert.equal(db.calls.length, 0);
});

// ---------------------------------------------------------------------------
// Başarılı gönderim: mesaj şekli
// ---------------------------------------------------------------------------
test('başarılı gönderim: URL, başlıklar ve FCM v1 gövdesi', async () => {
  const { push, fetchImpl, authFactory } = setup();
  const r = await push.sendNotice({ tokens: [{ id: 'i1', token: H.FAKE_TOKEN_A, platform: 'android' }], ...NOTICE });

  assert.deepEqual({ a: r.attempted, s: r.sent, f: r.failed, d: r.disabledTokenIds, t: r.transient, e: r.errors },
    { a: 1, s: 1, f: 0, d: [], t: false, e: [] });
  assert.equal(fetchImpl.calls.length, 1);

  const { url, init, body } = fetchImpl.calls[0];
  assert.equal(url, 'https://fcm.googleapis.com/v1/projects/fake-project/messages:send');
  assert.equal(init.method, 'POST');
  assert.equal(init.headers.Authorization, `Bearer ${H.FAKE_BEARER_1}`);
  assert.match(init.headers['Content-Type'], /^application\/json/);
  assert.ok(init.signal, 'AbortController sinyali verilmeli');

  // kimlik üretici doğru kapsamla çağrıldı
  assert.equal(authFactory.calls.length, 1);
  assert.deepEqual(authFactory.calls[0].scopes, ['https://www.googleapis.com/auth/firebase.messaging']);
  assert.equal(authFactory.calls[0].keyFile, H.CONFIGURED_ENV.FCM_SERVICE_ACCOUNT_FILE);

  const m = body.message;
  assert.equal(m.token, H.FAKE_TOKEN_A);
  assert.equal(m.notification.title, 'Gül Apartmanı 5');
  assert.ok(m.notification.body.includes('Işık çok.'), 'Türkçe karakterler korunmalı');
  assert.ok(fetchImpl.calls[0].init.body.includes('Gül Apartmanı'), 'UTF-8 kaçışsız gider');

  // data: YALNIZ string değerler
  assert.deepEqual(m.data, {
    type: 'peace_open_devices',
    home_id: H.HOME_ID,
    notice_id: '42',
    open_lights: '3',
    open_shutters: '1',
    action: 'close_all',
    v: '1',
  });
  for (const v of Object.values(m.data)) assert.equal(typeof v, 'string');

  const collapse = `peace_${H.HOME_ID}`;
  assert.deepEqual(m.android, {
    priority: 'HIGH',
    ttl: '3600s',
    collapse_key: collapse,
    notification: { channel_id: 'peace_reminder', tag: collapse },
  });
  assert.equal(m.apns.headers['apns-priority'], '10');
  assert.equal(m.apns.headers['apns-collapse-id'], collapse);
  assert.equal(m.apns.headers['apns-expiration'], String(1_800_000_000 + 3600));
  assert.deepEqual(m.apns.payload.aps, { category: 'PEACE_CLOSE_ALL', 'thread-id': H.HOME_ID, sound: 'default' });
});

test('data camelCase kabul eder; bilinmeyen/kişisel alanlar aktarılmaz; sayılar güvenli', () => {
  const msg = buildMessage({
    token: H.FAKE_TOKEN_A,
    title: 'T',
    body: 'B',
    data: { homeId: H.HOME_ID, noticeId: 'n-1', openLights: '2', openShutters: -5, room: 'Salon', email: 'a@b.c' },
    nowMs: 0,
  });
  assert.deepEqual(msg.message.data, {
    type: 'peace_open_devices', home_id: H.HOME_ID, notice_id: 'n-1', open_lights: '2', open_shutters: '0', action: 'close_all', v: '1',
  });
  assert.equal(msg.message.apns.headers['apns-expiration'], '3600');
});

test('home_id güvenli değilse (enjeksiyon) boşaltılır ve collapse unknown olur', () => {
  const msg = buildMessage({ token: H.FAKE_TOKEN_A, title: 'T', body: 'B', data: { home_id: 'x y/../z' }, nowMs: 0 });
  assert.equal(msg.message.data.home_id, '');
  assert.equal(msg.message.android.collapse_key, 'peace_unknown');
});

test('çok uzun başlık/gövde kod noktası bazında kırpılır', () => {
  const msg = buildMessage({ token: H.FAKE_TOKEN_A, title: 'ş'.repeat(300), body: '😀'.repeat(900), data: {}, nowMs: 0 });
  assert.equal(Array.from(msg.message.notification.title).length, 100);
  assert.equal(Array.from(msg.message.notification.body).length, 400);
  assert.ok(msg.message.notification.title.endsWith('…'));
  assert.doesNotMatch(msg.message.notification.body, /[\uD800-\uDBFF](?![\uDC00-\uDFFF])/); // yarım vekil yok
});

test('jeton başına bir istek; mükerrer jeton tek kez; dizi ve nesne biçimi birlikte', async () => {
  const { push, fetchImpl } = setup();
  const r = await push.sendNotice({
    tokens: [H.FAKE_TOKEN_A, { id: 'i2', token: H.FAKE_TOKEN_B }, H.FAKE_TOKEN_A, { token: '' }, null, 7],
    ...NOTICE,
  });
  assert.equal(r.attempted, 2);
  assert.equal(r.sent, 2);
  assert.deepEqual(fetchImpl.calls.map((c) => c.body.message.token).sort(), [H.FAKE_TOKEN_A, H.FAKE_TOKEN_B]);
});

test('boş jeton listesi -> istek yok; başlık/gövde yok -> VALIDATION, istek yok', async () => {
  const a = setup();
  const r1 = await a.push.sendNotice({ tokens: [], ...NOTICE });
  assert.equal(r1.attempted, 0);
  assert.equal(a.fetchImpl.calls.length, 0);
  assert.equal(a.authFactory.calls.length, 0);

  const b = setup();
  const r2 = await b.push.sendNotice({ tokens: [H.FAKE_TOKEN_A], title: '', body: 'x', data: {} });
  assert.deepEqual(r2.errors, [{ code: 'VALIDATION' }]);
  assert.equal(b.fetchImpl.calls.length, 0);
});

test('eşzamanlılık en fazla 5', async () => {
  const gate = () => new Promise((r) => setTimeout(r, 15));
  const { push, fetchImpl } = setup({
    responder: async () => { await gate(); return H.makeResponse(200, {}); },
  });
  const tokens = Array.from({ length: 14 }, (_, i) => ({ id: `id${i}`, token: `fake-fcm-token-${String(i).padStart(20, 'x')}` }));
  const r = await push.sendNotice({ tokens, ...NOTICE });
  assert.equal(r.sent, 14);
  assert.equal(fetchImpl.calls.length, 14);
  assert.ok(fetchImpl.state.maxInFlight <= 5, `maxInFlight=${fetchImpl.state.maxInFlight}`);
  assert.ok(fetchImpl.state.maxInFlight >= 2, 'paralel çalışmalı');
  // erişim jetonu 14 istek için TEK kez alındı
  assert.equal(fetchImpl.calls.every((c) => c.init.headers.Authorization === `Bearer ${H.FAKE_BEARER_1}`), true);
});

test('concurrency seçeneği 5 üst sınırını aşamaz', async () => {
  const { push, fetchImpl } = setup({
    concurrency: 50,
    responder: async () => { await new Promise((r) => setTimeout(r, 10)); return H.makeResponse(200, {}); },
  });
  const tokens = Array.from({ length: 12 }, (_, i) => `fake-fcm-token-${String(i).padStart(20, 'y')}`);
  await push.sendNotice({ tokens, ...NOTICE });
  assert.ok(fetchImpl.state.maxInFlight <= 5);
});

// ---------------------------------------------------------------------------
// Hata sınıflaması
// ---------------------------------------------------------------------------
test('404 UNREGISTERED -> jeton devre dışı (id ile) ve SQL', async () => {
  const { push, db } = setup({
    responder: () => H.makeResponse(404, H.fcmError(404, 'UNREGISTERED')),
  });
  const r = await push.sendNotice({ tokens: [{ id: 'tok-1', token: H.FAKE_TOKEN_A }], ...NOTICE });
  assert.equal(r.sent, 0);
  assert.equal(r.failed, 1);
  assert.deepEqual(r.disabledTokenIds, ['tok-1']);
  assert.equal(r.transient, false);
  assert.deepEqual(r.errors, [{ status: 404, code: 'UNREGISTERED' }]);
  assert.equal(db.calls.length, 1);
  assert.match(db.calls[0].text, /UPDATE push_tokens SET disabled_at = now\(\)/);
  assert.match(db.calls[0].text, /id = ANY\(\$1::uuid\[\]\)/);
  assert.deepEqual(db.calls[0].params, [['tok-1']]);
});

test('UNREGISTERED kimliksiz jeton token metniyle devre dışı bırakılır', async () => {
  const { push, db } = setup({ responder: () => H.makeResponse(404, H.fcmError(404, 'UNREGISTERED')) });
  const r = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.deepEqual(r.disabledTokenIds, []); // kimlik bilinmiyor
  assert.equal(db.calls.length, 1);
  assert.match(db.calls[0].text, /token = ANY\(\$1::text\[\]\)/);
  assert.deepEqual(db.calls[0].params, [[H.FAKE_TOKEN_A]]);
  assert.deepEqual(r.errors, [{ status: 404, code: 'UNREGISTERED' }]);
});

test('404 UNREGISTERED kanıtı OLMADAN (gövdesiz / NOT_FOUND / yanlış FCM_PROJECT_ID) jeton devre dışı BIRAKILMAZ', async () => {
  const bodies = [
    '',
    '<html>404</html>',
    H.fcmError(404, null, { status: 'NOT_FOUND', message: 'Requested entity was not found.' }),
    // errorCode alanı olmayan ayrıntı: yine kanıt değil
    H.fcmError(404, null, { status: 'NOT_FOUND', details: [{ '@type': 'type.googleapis.com/google.rpc.ErrorInfo' }] }),
    // 'NOT_FOUND' errorCode'u da (FCM ErrorCode sıralamasında yok) kalıcı geçersizlik kanıtı değildir
    H.fcmError(404, 'NOT_FOUND'),
  ];
  for (const responseBody of bodies) {
    const { push, db, logger } = setup({ responder: () => H.makeResponse(404, responseBody) });
    const tokens = [H.FAKE_TOKEN_A, H.FAKE_TOKEN_B, H.FAKE_TOKEN_C].map((token, i) => ({ id: `t${i}`, token }));
    const r = await push.sendNotice({ tokens, ...NOTICE });
    assert.equal(r.sent, 0);
    assert.equal(r.failed, 3);
    assert.deepEqual(r.disabledTokenIds, [], 'hiçbir jeton devre dışı olmamalı');
    assert.equal(db.calls.length, 0, 'UPDATE push_tokens ÇALIŞMAMALI');
    assert.equal(r.transient, true, 'yapılandırma hatası düzelince yeniden denenebilir');
    assert.equal(r.errors.length, 1);
    assert.equal(r.errors[0].status, 404);
    const errorLogs = logger.lines.filter((l) => l.startsWith('error:'));
    assert.equal(errorLogs.length, 1, 'tek error logu (jeton başına değil)');
    assert.match(errorLogs[0], /adet=3/);
    assert.match(errorLogs[0], /FCM_PROJECT_ID/);
    assert.equal(logger.lines.join('\n').includes('fake-project'), false, 'değişken DEĞERİ loglanmaz');
  }
});

test('karışık 404: yalnızca UNREGISTERED kanıtlı jeton devre dışı, kanıtsız olan kalır', async () => {
  const { push, db } = setup({
    responder: (call) => (call.body.message.token === H.FAKE_TOKEN_A
      ? H.makeResponse(404, H.fcmError(404, 'UNREGISTERED'))
      : H.makeResponse(404, '')),
  });
  const r = await push.sendNotice({ tokens: [{ id: 'a', token: H.FAKE_TOKEN_A }, { id: 'b', token: H.FAKE_TOKEN_B }], ...NOTICE });
  assert.deepEqual(r.disabledTokenIds, ['a']);
  assert.deepEqual(db.calls[0].params, [['a']]);
});

test('kalıcı jeton hatasında (UNREGISTERED) yapılandırma uyarısı loglanmaz', async () => {
  const { push, logger } = setup({ responder: () => H.makeResponse(404, H.fcmError(404, 'UNREGISTERED')) });
  await push.sendNotice({ tokens: [{ id: 'a', token: H.FAKE_TOKEN_A }], ...NOTICE });
  assert.equal(logger.lines.some((l) => l.startsWith('error:')), false);
});

test('400 INVALID_ARGUMENT jetonla ilgiliyse devre dışı; ilgisizse devre dışı DEĞİL', async () => {
  const tokenRelated = setup({
    responder: () => H.makeResponse(400, H.fcmError(400, null, {
      status: 'INVALID_ARGUMENT',
      details: [{
        '@type': 'type.googleapis.com/google.rpc.BadRequest',
        fieldViolations: [{ field: 'message.token', description: 'x' }],
      }],
    })),
  });
  const r1 = await tokenRelated.push.sendNotice({ tokens: [{ id: 't1', token: H.FAKE_TOKEN_A }], ...NOTICE });
  assert.deepEqual(r1.disabledTokenIds, ['t1']);

  const other = setup({
    responder: () => H.makeResponse(400, H.fcmError(400, null, {
      status: 'INVALID_ARGUMENT',
      message: 'Invalid JSON payload received.',
      details: [{ '@type': 'type.googleapis.com/google.rpc.BadRequest', fieldViolations: [{ field: 'message.data' }] }],
    })),
  });
  const r2 = await other.push.sendNotice({ tokens: [{ id: 't1', token: H.FAKE_TOKEN_A }], ...NOTICE });
  assert.deepEqual(r2.disabledTokenIds, []);
  assert.equal(other.db.calls.length, 0);
  assert.equal(r2.failed, 1);
  assert.equal(r2.transient, false);
  assert.deepEqual(r2.errors, [{ status: 400, code: 'INVALID_ARGUMENT' }]);
});

test('429 + Retry-After ve 5xx -> geçici; jeton devre dışı bırakılmaz', async () => {
  const a = setup({ responder: () => H.makeResponse(429, H.fcmError(429, 'QUOTA_EXCEEDED'), { 'Retry-After': '30' }) });
  const r1 = await a.push.sendNotice({ tokens: [{ id: 'x', token: H.FAKE_TOKEN_A }], ...NOTICE });
  assert.equal(r1.transient, true);
  assert.equal(r1.retryAfterSec, 30);
  assert.deepEqual(r1.disabledTokenIds, []);
  assert.equal(a.db.calls.length, 0);
  assert.equal(a.fetchImpl.calls.length, 1, 'bekleme/yeniden deneme YOK, yalnızca rapor');

  const b = setup({ responder: () => H.makeResponse(503, H.fcmError(503, 'UNAVAILABLE')) });
  const r2 = await b.push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.equal(r2.transient, true);
  assert.deepEqual(r2.errors, [{ status: 503, code: 'UNAVAILABLE' }]);
  assert.equal(r2.retryAfterSec, undefined);

  const c = setup({ responder: () => H.makeResponse(500, '<html>proxy</html>') });
  const r3 = await c.push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.equal(r3.transient, true);
  assert.deepEqual(r3.errors, [{ status: 500, code: 'HTTP_500' }]);
});

test('ağ hatası -> geçici NETWORK; zaman aşımı -> geçici TIMEOUT (sinyal iptal edilir)', async () => {
  const a = setup({ responder: () => new Error('ECONNRESET jeton=' + H.FAKE_TOKEN_A) });
  const r1 = await a.push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.equal(r1.transient, true);
  assert.deepEqual(r1.errors, [{ status: 0, code: 'NETWORK' }]);
  assert.doesNotMatch(JSON.stringify(r1), new RegExp(H.FAKE_TOKEN_A), 'hata metni sonuca sızmaz');

  let seenSignal;
  const b = setup({
    timeoutMs: 20,
    responder: (call) => new Promise((_, reject) => {
      seenSignal = call.init.signal;
      call.init.signal.addEventListener('abort', () => reject(new Error('aborted')));
    }),
  });
  const r2 = await b.push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.equal(r2.transient, true);
  assert.deepEqual(r2.errors, [{ status: 0, code: 'TIMEOUT' }]);
  assert.equal(seenSignal.aborted, true);
});

test('sinyali yok sayan fetch de zaman aşımıyla sınırlanır', async () => {
  const { push } = setup({ timeoutMs: 20, responder: () => new Promise(() => {}) });
  const r = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.deepEqual(r.errors, [{ status: 0, code: 'TIMEOUT' }]);
});

test('401 -> kimlik yenilenir ve BİR kez yeniden denenir (başarılı)', async () => {
  const { push, fetchImpl, authFactory } = setup({
    responder: (call, i) => (i === 0 ? H.makeResponse(401, H.fcmError(401, null, { status: 'UNAUTHENTICATED' })) : H.makeResponse(200, {})),
  });
  const r = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.equal(r.sent, 1);
  assert.equal(r.failed, 0);
  assert.equal(fetchImpl.calls.length, 2);
  assert.equal(fetchImpl.calls[0].init.headers.Authorization, `Bearer ${H.FAKE_BEARER_1}`);
  assert.equal(fetchImpl.calls[1].init.headers.Authorization, `Bearer ${H.FAKE_BEARER_2}`);
  assert.equal(authFactory.calls.length, 2, 'önbellekteki kimlik atılıp factory yeniden çağrıldı');
});

test('401/403 yenilemeden sonra da sürerse: toplam 2 istek, başarısız ve geçici (kimlik düzelince geçer)', async () => {
  for (const status of [401, 403]) {
    const { push, fetchImpl, authFactory } = setup({
      responder: () => H.makeResponse(status, H.fcmError(status, null, { status: status === 401 ? 'UNAUTHENTICATED' : 'PERMISSION_DENIED' })),
    });
    const r = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
    assert.equal(fetchImpl.calls.length, 2, `status ${status}`);
    assert.equal(authFactory.calls.length, 2);
    assert.equal(r.sent, 0);
    assert.equal(r.failed, 1);
    assert.equal(r.transient, true);
  }
});

test('403 SENDER_ID_MISMATCH jetona özgüdür: yenileme denenmez, geçici sayılmaz', async () => {
  const { push, fetchImpl, authFactory } = setup({
    responder: () => H.makeResponse(403, H.fcmError(403, 'SENDER_ID_MISMATCH', { status: 'PERMISSION_DENIED' })),
  });
  const r = await push.sendNotice({ tokens: [{ id: 'a', token: H.FAKE_TOKEN_A }], ...NOTICE });
  assert.equal(fetchImpl.calls.length, 1);
  assert.equal(authFactory.calls.length, 1);
  assert.equal(r.transient, false);
  assert.deepEqual(r.disabledTokenIds, []);
});

test('eşzamanlı birkaç 401: kimlik TEK kez yenilenir, her istek bir kez yeniden denenir', async () => {
  const { push, fetchImpl, authFactory } = setup({
    authTokens: [H.FAKE_BEARER_1, H.FAKE_BEARER_2],
    responder: async (call) => {
      await new Promise((r) => setTimeout(r, 5));
      return call.init.headers.Authorization.endsWith(H.FAKE_BEARER_1)
        ? H.makeResponse(401, H.fcmError(401, null, { status: 'UNAUTHENTICATED' }))
        : H.makeResponse(200, {});
    },
  });
  const tokens = [H.FAKE_TOKEN_A, H.FAKE_TOKEN_B, H.FAKE_TOKEN_C];
  const r = await push.sendNotice({ tokens, ...NOTICE });
  assert.equal(r.sent, 3);
  assert.equal(authFactory.calls.length, 2, 'bir ilk, bir yenileme');
  assert.equal(fetchImpl.calls.length, 6);
});

test('erişim jetonu alınamazsa ağa çıkılmaz: AUTH_FAILED, geçici', async () => {
  const { push, fetchImpl } = setup({ authOpts: { fail: true } });
  const r = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A, H.FAKE_TOKEN_B], ...NOTICE });
  assert.equal(fetchImpl.calls.length, 0);
  assert.equal(r.sent, 0);
  assert.equal(r.failed, 2);
  assert.equal(r.transient, true);
  assert.deepEqual(r.errors, [{ status: 0, code: 'AUTH_FAILED' }]);
});

test('gömülü FCM_SERVICE_ACCOUNT_JSON kimlik kaynağı SAYILMAZ -> yapılandırılmamış, ağa çıkmaz', async () => {
  const { push, fetchImpl, authFactory } = setup({ env: { FCM_PROJECT_ID: 'p', FCM_SERVICE_ACCOUNT_JSON: '{bozuk' } });
  const r = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.equal(fetchImpl.calls.length, 0);
  assert.equal(authFactory.calls.length, 0);
  assert.deepEqual(r.errors, [{ code: 'PUSH_NOT_CONFIGURED' }]);
});

// ---------------------------------------------------------------------------
// Süre sınırları: erişim jetonu alma ve toplam gönderim süresi
// ---------------------------------------------------------------------------
function hangingAuthFactory() {
  const calls = [];
  const factory = (args) => { calls.push(args); return { getAccessToken: () => new Promise(() => {}) }; };
  factory.calls = calls;
  return factory;
}

test('erişim jetonu alma takılırsa timeoutMs sonunda AUTH_TIMEOUT (geçici) döner, sözü askıda KALMAZ', async () => {
  const fetchImpl = H.createFakeFetch();
  const authFactory = hangingAuthFactory();
  const push = createPushService({
    db: H.createFakeDb(), logger: H.createLogger(), fetchImpl, authFactory, env: H.CONFIGURED_ENV, timeoutMs: 60,
  });
  const started = Date.now();
  const r = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A, H.FAKE_TOKEN_B, H.FAKE_TOKEN_C], ...NOTICE });
  assert.ok(Date.now() - started < 1500, 'takılı kimlik çağrısı toplam süreyi uzatmamalı');
  assert.equal(fetchImpl.calls.length, 0);
  assert.equal(r.sent, 0);
  assert.equal(r.failed, 3);
  assert.equal(r.transient, true);
  assert.deepEqual(r.errors, [{ status: 0, code: 'AUTH_TIMEOUT' }]);
  assert.equal(authFactory.calls.length, 1, 'üç jeton için tek-uçuş: tek kimlik çağrısı');
});

test('zaman aşımına uğrayan kimlik nesnesi atılır: sonraki gönderim yeni factory çağrısıyla düzelir', async () => {
  let n = 0;
  const calls = [];
  const authFactory = (args) => {
    calls.push(args);
    n += 1;
    const hang = n === 1;
    return { getAccessToken: () => (hang ? new Promise(() => {}) : Promise.resolve(H.FAKE_BEARER_1)) };
  };
  const { push } = setup({ authFactory, timeoutMs: 40 });
  const first = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.equal(first.transient, true);
  const second = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.equal(second.sent, 1);
  assert.equal(calls.length, 2, 'takılan istemci yeniden kullanılmadı');
});

test('toplam süre sınırı: dolunca yeni jeton başlatılmaz (DEADLINE_EXCEEDED, geçici) ve söz zamanında biter', async () => {
  const { push, fetchImpl } = setup({
    concurrency: 1,
    responder: async () => { await new Promise((r) => setTimeout(r, 30)); return H.makeResponse(200, {}); },
  });
  const tokens = Array.from({ length: 40 }, (_, i) => `fake-fcm-token-dl-${String(i).padStart(12, '0')}`);
  const started = Date.now();
  const r = await push.sendNotice({ tokens, ...NOTICE, deadlineMs: 150 });
  assert.ok(Date.now() - started < 1000, `süre sınırı işlemedi: ${Date.now() - started} ms`);
  assert.equal(r.attempted, 40);
  assert.ok(r.sent >= 1 && r.sent < 40, `sent=${r.sent}`);
  assert.equal(r.sent + r.failed, 40);
  assert.ok(fetchImpl.calls.length <= r.sent + 1, 'süre dolduktan sonra yeni istek BAŞLATILMADI (en çok sürmekte olan 1 istek kesilmiş olabilir)');
  assert.ok(r.errors.some((e) => e.code === 'DEADLINE_EXCEEDED'), JSON.stringify(r.errors));
  assert.equal(r.transient, false, 'kısmi başarı: çağıran "gönderildi" sayar, yeniden denemez');
});

test('toplam süre sınırı: hiçbiri gönderilemediyse transient=true; sürmekte olan istek kalan süreyle kesilir', async () => {
  const { push } = setup({
    timeoutMs: 5000, // jeton başına 5 sn olsa da toplam sınır kısadır
    responder: () => new Promise(() => {}),
  });
  const started = Date.now();
  const r = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A, H.FAKE_TOKEN_B], ...NOTICE, deadlineMs: 120 });
  assert.ok(Date.now() - started < 1500, `askıda kaldı: ${Date.now() - started} ms`);
  assert.equal(r.sent, 0);
  assert.equal(r.transient, true);
  assert.deepEqual(r.errors, [{ status: 0, code: 'TIMEOUT' }]);
});

test('kurucu deadlineMs seçeneği uygulanır (çağrı başına verilmezse)', async () => {
  const slow = createPushService({
    db: H.createFakeDb(), logger: H.createLogger(), fetchImpl: () => new Promise(() => {}),
    authFactory: H.createFakeAuthFactory(), env: H.CONFIGURED_ENV, timeoutMs: 5000, deadlineMs: 80,
  });
  const started = Date.now();
  const r = await slow.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.ok(Date.now() - started < 1500);
  assert.equal(r.transient, true);
});

test('401 yenilemesi de süre sınırına tabidir: süre bittiyse yenileme/yeniden deneme başlatılmaz', async () => {
  const clock = { t: 0 };
  const { push, fetchImpl, authFactory } = setup({
    monotonic: () => clock.t,
    responder: () => { clock.t += 20_000; return H.makeResponse(401, H.fcmError(401, null, { status: 'UNAUTHENTICATED' })); },
  });
  const r = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE, deadlineMs: 10_000 });
  assert.equal(r.sent, 0);
  assert.equal(r.transient, true);
  assert.equal(fetchImpl.calls.length, 1, 'yeniden deneme yok');
  assert.equal(authFactory.calls.length, 1, 'kimlik yenilenmedi');
  assert.deepEqual(r.errors, [{ status: 401, code: 'DEADLINE_EXCEEDED' }]);
});

test('kısmi başarı: transient=false (çağıran "gönderildi" saymalı, yeniden denememeli)', async () => {
  const { push } = setup({
    responder: (call) => (call.body.message.token === H.FAKE_TOKEN_A
      ? H.makeResponse(200, {})
      : H.makeResponse(503, H.fcmError(503, 'UNAVAILABLE'))),
  });
  const r = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A, H.FAKE_TOKEN_B], ...NOTICE });
  assert.equal(r.sent, 1);
  assert.equal(r.failed, 1);
  assert.equal(r.transient, false);
});

test('karışık sonuçlar: hata anahtarları tekilleştirilir, devre dışı jetonlar toplanır', async () => {
  const { push, db } = setup({
    responder: (call) => {
      const t = call.body.message.token;
      if (t === H.FAKE_TOKEN_A) return H.makeResponse(404, H.fcmError(404, 'UNREGISTERED'));
      if (t === H.FAKE_TOKEN_B) return H.makeResponse(404, H.fcmError(404, 'UNREGISTERED'));
      return H.makeResponse(500, '');
    },
  });
  const r = await push.sendNotice({
    tokens: [{ id: 'a', token: H.FAKE_TOKEN_A }, { id: 'b', token: H.FAKE_TOKEN_B }, { id: 'c', token: H.FAKE_TOKEN_C }],
    ...NOTICE,
  });
  assert.equal(r.failed, 3);
  assert.deepEqual(r.disabledTokenIds.sort(), ['a', 'b']);
  assert.equal(r.errors.length, 2);
  assert.equal(r.transient, true);
  assert.equal(db.calls.length, 1);
  assert.deepEqual([...db.calls[0].params[0]].sort(), ['a', 'b']);
});

test('devre dışı bırakma SQL hatası gönderim sonucunu bozmaz', async () => {
  const { push, logger } = setup({
    responder: () => H.makeResponse(404, H.fcmError(404, 'UNREGISTERED')),
    dbHandler: () => Object.assign(new Error('boom ' + H.FAKE_TOKEN_A), { code: '57014' }),
  });
  const r = await push.sendNotice({ tokens: [{ id: 'a', token: H.FAKE_TOKEN_A }], ...NOTICE });
  assert.equal(r.failed, 1);
  assert.deepEqual(r.disabledTokenIds, ['a']);
  assert.ok(logger.lines.some((l) => l.includes('57014')));
  assert.equal(logger.lines.some((l) => l.includes(H.FAKE_TOKEN_A)), false);
});

// ---------------------------------------------------------------------------
// Token deposu
// ---------------------------------------------------------------------------
test('upsertToken: ON CONFLICT (token) ile kullanıcıya yeniden bağlar, disabled_at=NULL', async () => {
  const { push, db } = setup({ dbHandler: () => [{ id: 'row-1' }] });
  const r = await push.upsertToken({ userId: H.USER_ID, token: `  ${H.FAKE_TOKEN_A}  `, platform: 'IOS', appVersion: '1.2.0' });
  assert.deepEqual(r, { id: 'row-1' });
  assert.equal(db.calls.length, 1);
  const { text, params } = db.calls[0];
  assert.match(text, /INSERT INTO push_tokens/);
  assert.match(text, /ON CONFLICT \(token\) DO UPDATE/);
  assert.match(text, /user_id\s+= EXCLUDED\.user_id/);
  assert.match(text, /disabled_at\s+= NULL/);
  assert.match(text, /last_seen_at\s+= now\(\)/);
  assert.deepEqual(params.slice(0, 4), [H.USER_ID, H.FAKE_TOKEN_A, 'ios', '1.2.0']);
});

test('upsertToken: kullanıcı başına üst sınır AYNI deyimde uygulanır (en eskiler silinir, kayıt edilen korunur)', async () => {
  const { push, db } = setup({ dbHandler: () => [{ id: 'row-1' }] });
  await push.upsertToken({ userId: H.USER_ID, token: H.FAKE_TOKEN_A, platform: 'android' });
  assert.equal(db.calls.length, 1, 'tek deyim (atomik)');
  const { text, params } = db.calls[0];
  assert.match(text, /^\s*WITH upserted AS \(/);
  assert.match(text, /DELETE FROM push_tokens/);
  assert.match(text, /user_id = \$1 AND disabled_at IS NULL AND token <> \$2/, 'kayıt edilen jeton budanmaz');
  assert.match(text, /ORDER BY last_seen_at DESC, id\s+OFFSET \$5/);
  assert.match(text, /SELECT id FROM upserted/);
  // N-1 diğer jeton + yeni jeton = en çok N
  assert.equal(params[4], MAX_ACTIVE_TOKENS_PER_USER - 1);
  assert.ok(MAX_ACTIVE_TOKENS_PER_USER >= 3 && MAX_ACTIVE_TOKENS_PER_USER <= 20);
  assert.ok(MAX_RECIPIENT_TOKENS_PER_USER <= MAX_ACTIVE_TOKENS_PER_USER);
});

test('upsertToken: 20 sahte jetonla doldurma kullanıcı başına sınırı aşmaz (bellek içi SQL benzetimi)', async () => {
  // Gerçek SQL çalıştırılmaz; deyimin sözleşmesini (OFFSET = N-1, kayıt edilen hariç) bellek içi uygular.
  const rows = []; // { token, userId, seen }
  let clock = 0;
  const db = H.createFakeDb((text, params) => {
    const [userId, token, , , offset] = params;
    clock += 1;
    const existing = rows.find((r) => r.token === token);
    if (existing) { existing.userId = userId; existing.seen = clock; } else rows.push({ token, userId, seen: clock });
    const others = rows.filter((r) => r.userId === userId && r.token !== token).sort((a, b) => b.seen - a.seen);
    for (const doomed of others.slice(offset)) rows.splice(rows.indexOf(doomed), 1);
    return [{ id: 'x' }];
  });
  const push = createPushService({ db, logger: H.createLogger(), env: {}, now: () => 0 });
  for (let i = 0; i < 25; i += 1) {
    await push.upsertToken({ userId: H.USER_ID, token: `fake-fcm-token-junk-${String(i).padStart(10, '0')}`, platform: 'android' });
  }
  await push.upsertToken({ userId: 'other-user', token: H.FAKE_TOKEN_B, platform: 'ios' });
  assert.equal(rows.filter((r) => r.userId === H.USER_ID).length, MAX_ACTIVE_TOKENS_PER_USER);
  assert.equal(rows.filter((r) => r.userId === 'other-user').length, 1, 'başka kullanıcı etkilenmez');
  assert.ok(rows.some((r) => r.token.endsWith('0000000024')), 'en yeni jeton korunur');
});

test('upsertToken: appVersion yoksa NULL; doğrulama hataları VALIDATION ve DB çağrılmaz', async () => {
  const { push, db } = setup({ dbHandler: () => [{ id: 'r' }] });
  await push.upsertToken({ userId: H.USER_ID, token: H.FAKE_TOKEN_A, platform: 'android' });
  assert.equal(db.calls[0].params[3], null);

  for (const bad of [
    { userId: H.USER_ID, token: 'kisa', platform: 'android' },
    { userId: H.USER_ID, token: 'x'.repeat(513), platform: 'android' },
    { userId: H.USER_ID, token: `${'a'.repeat(19)} b`, platform: 'android' },
    { userId: H.USER_ID, token: `${'a'.repeat(30)}ğ`, platform: 'android' },
    { userId: H.USER_ID, token: 42, platform: 'android' },
    { userId: H.USER_ID, token: H.FAKE_TOKEN_A, platform: 'windows' },
    { userId: H.USER_ID, token: H.FAKE_TOKEN_A, platform: undefined },
    { userId: H.USER_ID, token: H.FAKE_TOKEN_A, platform: 'ios', appVersion: 'v'.repeat(33) },
    { userId: H.USER_ID, token: H.FAKE_TOKEN_A, platform: 'ios', appVersion: 12 },
    { userId: '', token: H.FAKE_TOKEN_A, platform: 'ios' },
  ]) {
    await assert.rejects(() => push.upsertToken(bad), (e) => e.code === 'VALIDATION' && e.status === 400, JSON.stringify(bad).slice(0, 60));
  }
  assert.equal(db.calls.length, 1);
});

test('disableToken: userId verilirse yalnızca o kullanıcının jetonu; verilmezse tüm eşleşme', async () => {
  const { push, db } = setup({ dbHandler: () => ({ rows: [], rowCount: 1 }) });
  assert.equal(await push.disableToken({ token: H.FAKE_TOKEN_A, userId: H.USER_ID }), 1);
  assert.match(db.calls[0].text, /disabled_at = now\(\)/);
  assert.match(db.calls[0].text, /token = \$1 AND user_id = \$2 AND disabled_at IS NULL/);
  assert.deepEqual(db.calls[0].params, [H.FAKE_TOKEN_A, H.USER_ID]);

  await push.disableToken({ token: H.FAKE_TOKEN_A });
  assert.doesNotMatch(db.calls[1].text, /user_id/);
  assert.deepEqual(db.calls[1].params, [H.FAKE_TOKEN_A]);

  await assert.rejects(() => push.disableToken({ token: 'kisa' }), (e) => e.code === 'VALIDATION');
});

test('recipientsForHome: yalnız owner/resident + aktif hesap + devre dışı olmayan jeton', async () => {
  const { push, db } = setup({
    dbHandler: () => [
      { id: 'p1', user_id: 'u1', token: H.FAKE_TOKEN_A, platform: 'android' },
      { id: 'p2', user_id: 'u2', token: H.FAKE_TOKEN_B, platform: 'ios' },
    ],
  });
  const rec = await push.recipientsForHome(H.HOME_ID);
  assert.deepEqual(rec, [
    { id: 'p1', userId: 'u1', token: H.FAKE_TOKEN_A, platform: 'android' },
    { id: 'p2', userId: 'u2', token: H.FAKE_TOKEN_B, platform: 'ios' },
  ]);
  const { text, params } = db.calls[0];
  assert.match(text, /FROM home_users hu/);
  assert.match(text, /hu\.role IN \('owner', 'resident'\)/);
  assert.doesNotMatch(text, /guest|service_user/);
  assert.match(text, /u\.is_active IS NOT FALSE/);
  assert.match(text, /u\.account_status = 'active'/);
  assert.match(text, /pt\.disabled_at IS NULL/);
  assert.match(text, /hu\.home_id = \$1/);
  assert.equal(params[0], H.HOME_ID);
  assert.equal(params.length, 3);
  assert.ok(Number.isInteger(params[2]) && params[2] > 0 && params[2] <= 200, 'genel üst sınır parametresi');
});

test('recipientsForHome: kullanıcı başına adil sınır (row_number) genel LIMIT\'ten ÖNCE uygulanır', async () => {
  const { push, db } = setup();
  await push.recipientsForHome(H.HOME_ID);
  const { text, params } = db.calls[0];
  assert.match(text, /row_number\(\) OVER \(PARTITION BY pt\.user_id ORDER BY pt\.last_seen_at DESC, pt\.id\)/);
  assert.match(text, /WHERE rn <= \$2/);
  assert.ok(text.indexOf('rn <= $2') < text.indexOf('LIMIT $3'), 'önce kullanıcı başına, sonra genel sınır');
  assert.equal(params[1], MAX_RECIPIENT_TOKENS_PER_USER);
  assert.ok(params[1] >= 1 && params[1] < params[2]);
});

test('recipientsForHome: satır yoksa boş dizi', async () => {
  const { push } = setup();
  assert.deepEqual(await push.recipientsForHome(H.HOME_ID), []);
});

test('cleanup: 30+ gün eski disabled_at siler; geçersiz değer 30 olur', async () => {
  const { push, db } = setup({ dbHandler: () => ({ rows: [], rowCount: 4 }) });
  assert.equal(await push.cleanup({ olderThanDays: 30 }), 4);
  assert.match(db.calls[0].text, /DELETE FROM push_tokens/);
  assert.match(db.calls[0].text, /disabled_at IS NOT NULL/);
  assert.match(db.calls[0].text, /disabled_at < now\(\) - \(\$1::int \* interval '1 day'\)/);
  assert.equal(db.calls[0].params[0], 30);

  await push.cleanup({ olderThanDays: 7 });
  assert.equal(db.calls[1].params[0], 7);
  await push.cleanup({ olderThanDays: -1 });
  await push.cleanup({ olderThanDays: '5; DROP TABLE x' });
  await push.cleanup();
  assert.deepEqual([db.calls[2].params[0], db.calls[3].params[0], db.calls[4].params[0]], [30, 30, 30]);
});

test('cleanup: ev üyeliği (owner/resident) olmayan kullanıcıların uzun süredir görülmeyen jetonlarını da siler', async () => {
  const { push, db } = setup({ dbHandler: () => ({ rows: [], rowCount: 0 }) });
  await push.cleanup({ olderThanDays: 30 });
  const { text, params } = db.calls[0];
  assert.match(text, /pt\.last_seen_at < now\(\) - \(\$2::int \* interval '1 day'\)/);
  assert.match(text, /NOT EXISTS \(\s*SELECT 1 FROM home_users hu\s+WHERE hu\.user_id = pt\.user_id\s+AND hu\.role IN \('owner', 'resident'\)/);
  assert.equal(params.length, 2);
  assert.ok(Number.isInteger(params[1]) && params[1] >= 1 && params[1] <= 30, 'taze jetonlar korunmalı');
  assert.equal(db.calls.length, 1, 'tek deyim');
});

// ---------------------------------------------------------------------------
// Oturum kapanınca / parola sıfırlanınca jeton iptali
// ---------------------------------------------------------------------------
test('disableAllTokensForUser: kullanıcının tüm etkin jetonlarını devre dışı bırakır; userId ve {userId, tx} biçimleri', async () => {
  const { push, db } = setup({ dbHandler: () => ({ rows: [], rowCount: 3 }) });
  assert.equal(await push.disableAllTokensForUser(H.USER_ID), 3);
  assert.match(db.calls[0].text, /UPDATE push_tokens SET disabled_at = now\(\)/);
  assert.match(db.calls[0].text, /WHERE user_id = \$1 AND disabled_at IS NULL/);
  assert.deepEqual(db.calls[0].params, [H.USER_ID]);

  // çağıranın işlemi (tx) verilirse DB havuzu DEĞİL tx kullanılır (oturum iptaliyle aynı işlemde)
  const txCalls = [];
  const tx = { async query(text, params) { txCalls.push({ text, params }); return { rows: [], rowCount: 2 }; } };
  assert.equal(await push.disableAllTokensForUser({ userId: H.USER_ID, tx }), 2);
  assert.equal(txCalls.length, 1);
  assert.equal(db.calls.length, 1, 'havuz kullanılmadı');

  for (const bad of ['', null, undefined, 42, {}, { userId: '' }]) {
    await assert.rejects(() => push.disableAllTokensForUser(bad), (e) => e.code === 'VALIDATION');
  }
  assert.equal(db.calls.length, 1);
});

// ---------------------------------------------------------------------------
// Log sızıntısı
// ---------------------------------------------------------------------------
test('loglar jeton, başlık/gövde, oda adı, Bearer değeri veya hata gövdesi İÇERMEZ', async () => {
  const secretRoom = 'Gizli Çocuk Odası';
  const scenarios = [
    () => H.makeResponse(200, {}),
    () => H.makeResponse(404, H.fcmError(404, 'UNREGISTERED', { message: `token ${H.FAKE_TOKEN_A} unregistered` })),
    () => H.makeResponse(429, H.fcmError(429, 'QUOTA_EXCEEDED'), { 'Retry-After': '5' }),
    () => H.makeResponse(401, H.fcmError(401, null, { status: 'UNAUTHENTICATED' })),
    () => new Error(`ECONNRESET ${H.FAKE_TOKEN_A} ${H.FAKE_BEARER_1}`),
  ];
  for (const responder of scenarios) {
    const { push, logger } = setup({ responder });
    await push.sendNotice({
      tokens: [{ id: 'row-9', token: H.FAKE_TOKEN_A }, { id: 'row-8', token: H.FAKE_TOKEN_B }],
      title: 'Gizli Başlık',
      body: `${secretRoom}nda 2 lamba açık.`,
      data: { home_id: H.HOME_ID, notice_id: 1, open_lights: 2, open_shutters: 0 },
    });
    const all = logger.lines.join('\n');
    assert.ok(all.length > 0, 'özet log yazılmalı');
    for (const secret of [H.FAKE_TOKEN_A, H.FAKE_TOKEN_B, H.FAKE_BEARER_1, H.FAKE_BEARER_2, 'Gizli Başlık', secretRoom, 'Bearer', 'UNREGISTERED', H.HOME_ID]) {
      assert.equal(all.includes(secret), false, `log sızıntısı: ${secret}`);
    }
    assert.match(all, /home=11111111/, 'yalnızca ev kimliği öneki');
  }
});

test('logger olmadan/bozuk logger ile de çalışır', async () => {
  const brokenLogger = { log() { throw new Error('log bozuk'); }, error() { throw new Error('log bozuk'); } };
  const { push } = setup({ logger: brokenLogger });
  const r = await push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  assert.equal(r.sent, 1);
});

test('aynı servis örneği ardışık gönderimlerde kimliği yeniden kullanır (bir kez factory)', async () => {
  const { push, authFactory } = setup();
  await push.sendNotice({ tokens: [H.FAKE_TOKEN_A], ...NOTICE });
  await push.sendNotice({ tokens: [H.FAKE_TOKEN_B], ...NOTICE });
  assert.equal(authFactory.calls.length, 1);
});
