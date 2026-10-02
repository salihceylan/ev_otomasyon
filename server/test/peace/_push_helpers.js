'use strict';

// Push testleri için ortak sahteler (`*.test.js` olmadığından test olarak çalışmaz).
// Gerçek ağ / veritabanı / kimlik bilgisi YOKTUR; tüm değerler açıkça uydurmadır.

// Sahte jetonlar: 20+ karakter görünür ASCII. Gerçek bir FCM jetonu DEĞİLDİR.
const FAKE_TOKEN_A = 'fake-fcm-token-AAAAAAAAAAAAAAAAAAAA';
const FAKE_TOKEN_B = 'fake-fcm-token-BBBBBBBBBBBBBBBBBBBB';
const FAKE_TOKEN_C = 'fake-fcm-token-CCCCCCCCCCCCCCCCCCCC';
const FAKE_BEARER_1 = 'fake-bearer-one';
const FAKE_BEARER_2 = 'fake-bearer-two';
const HOME_ID = '11111111-2222-4333-8444-555555555555';
const USER_ID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

const CONFIGURED_ENV = Object.freeze({
  FCM_PROJECT_ID: 'fake-project',
  FCM_SERVICE_ACCOUNT_FILE: '/nonexistent/fake-service-account.json',
});

/** Kayıt tutan sahte logger. */
function createLogger() {
  const lines = [];
  const push = (level) => (...args) => { lines.push(`${level}: ${args.map(String).join(' ')}`); };
  return { lines, log: push('log'), info: push('info'), warn: push('warn'), error: push('error') };
}

/** Programlanabilir sahte DB: query(text, params) çağrılarını `calls`a yazar. */
function createFakeDb(handler) {
  const calls = [];
  return {
    calls,
    async query(text, params = []) {
      calls.push({ text: String(text), params });
      const out = handler ? await handler(String(text), params) : undefined;
      if (out instanceof Error) throw out;
      if (Array.isArray(out)) return { rows: out, rowCount: out.length };
      return out || { rows: [], rowCount: 0 };
    },
  };
}

/** fetch yanıtı taklidi. */
function makeResponse(status, body, headers = {}) {
  const lower = {};
  for (const [k, v] of Object.entries(headers)) lower[k.toLowerCase()] = String(v);
  const text = body === undefined ? '' : typeof body === 'string' ? body : JSON.stringify(body);
  return {
    status,
    ok: status >= 200 && status < 300,
    headers: { get: (k) => (lower[String(k).toLowerCase()] !== undefined ? lower[String(k).toLowerCase()] : null) },
    async text() { return text; },
    async json() { return JSON.parse(text); },
  };
}

function fcmError(status, errorCode, extra = {}) {
  return {
    error: {
      code: status,
      message: extra.message || 'sahte hata',
      status: extra.status || errorCode,
      details: errorCode
        ? [{ '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError', errorCode }].concat(extra.details || [])
        : extra.details,
    },
  };
}

/**
 * Sahte fetch. `responder(call, index)` -> yanıt | Error | Promise.
 * Varsayılan: hepsi 200. Çağrılar `calls` içinde: { url, init, body (ayrıştırılmış), index }.
 * `maxInFlight` aynı anda süren istek sayısının tepe değeridir (eşzamanlılık sınırı testi).
 */
function createFakeFetch(responder) {
  const calls = [];
  const state = { inFlight: 0, maxInFlight: 0 };
  async function fetchImpl(url, init) {
    const index = calls.length;
    const call = { url, init, index, body: init && init.body ? JSON.parse(init.body) : null };
    calls.push(call);
    state.inFlight += 1;
    state.maxInFlight = Math.max(state.maxInFlight, state.inFlight);
    try {
      const out = responder ? await responder(call, index) : makeResponse(200, { name: 'projects/x/messages/1' });
      if (out instanceof Error) throw out;
      return out;
    } finally {
      state.inFlight -= 1;
    }
  }
  fetchImpl.calls = calls;
  fetchImpl.state = state;
  return fetchImpl;
}

/** Sahte kimlik üretici: her çağrıda yeni sıra numaralı jeton üretir. */
function createFakeAuthFactory(tokens = [FAKE_BEARER_1, FAKE_BEARER_2], opts = {}) {
  const factoryCalls = [];
  function authFactory(args) {
    factoryCalls.push(args);
    const mine = factoryCalls.length - 1;
    return {
      async getAccessToken() {
        if (opts.fail) throw new Error('kimlik hatasi (sahte)');
        return tokens[Math.min(mine, tokens.length - 1)];
      },
    };
  }
  authFactory.calls = factoryCalls;
  return authFactory;
}

module.exports = {
  FAKE_TOKEN_A,
  FAKE_TOKEN_B,
  FAKE_TOKEN_C,
  FAKE_BEARER_1,
  FAKE_BEARER_2,
  HOME_ID,
  USER_ID,
  CONFIGURED_ENV,
  createLogger,
  createFakeDb,
  makeResponse,
  fcmError,
  createFakeFetch,
  createFakeAuthFactory,
};
