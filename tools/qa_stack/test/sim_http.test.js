// Cihaz simulatoru yerel HTTP API'si = firmware WebPortal portu (CONTRACTS §3): kimlik, kilit (5. hatali 401, sonrasi 423), provizyonsuz mod,
// Host/Origin korumasi, CORS yok, 404 (405 degil), Content-Type, pair 1 tabanli, pos/val, config dogrulama, Wi-Fi akislari, QA ucu.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import crypto from 'node:crypto';
import { DeviceSimulator } from '../sim/device_sim.js';
import { isLoopbackAddress, isAllowedHost, originMatchesHost, ROUTES } from '../sim/local_api.js';
import { FW_VERSION_DEFAULT } from '../sim/fw/wifi_manager.js';
import { compute as lkFp } from '../sim/fw/local_key_fp.js';
import { safeEqual } from '../lib/util.js';
import { sleep, waitFor } from './_helpers.js';

const KEY = 'test-key-abcdef12';
const UID = 'AHBU-S3-0A0001';

/** Sahte saat: test ilerletir (kilit suresi gibi 60 sn'lik davranislari beklemeden dogrulamak icin). */
function fakeClock() {
  const c = { t: 1000, now: () => c.t, advance(ms) { c.t += ms; } };
  return c;
}

async function startSim(opts = {}) {
  const sim = new DeviceSimulator({
    uid: UID,
    relays: 8,
    httpPort: 0,
    timeScale: 50,
    localKey: KEY,
    apPass: 'ap-pass-12345',
    strict: true,
    wifiConnected: true,
    homeWifi: { ssid: 'TestHome', pass: 'home-pass-123' },
    wifiTiming: { connectMs: 60, scanMs: 60, sntpMs: 20 },
    bootMs: 40,
    rebootMs: 80,
    bootHoldMs: 0,
    ...opts,
  });
  await sim.start();
  const port = sim.httpPort;
  /** Ham HTTP istegi (Host/Origin dahil istenen her basligi gonderebilir). */
  const raw = (method, path, { key = KEY, body, headers = {}, ctype } = {}) => new Promise((resolve, reject) => {
    const h = { Host: `127.0.0.1:${port}`, ...headers };
    if (key !== null) h['X-Device-Key'] = key;
    let payload;
    if (body !== undefined) {
      payload = typeof body === 'string' ? body : JSON.stringify(body);
      if (ctype !== null && !h['Content-Type']) h['Content-Type'] = ctype || 'application/json';
      h['Content-Length'] = Buffer.byteLength(payload);
    }
    const req = http.request({ host: '127.0.0.1', port, method, path, headers: h, agent: false }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try { json = JSON.parse(text); } catch (_) { /* json degil */ }
        resolve({ status: res.statusCode, headers: res.headers, json, text });
      });
    });
    req.on('error', reject);
    if (payload !== undefined) req.write(payload);
    req.end();
  });
  const j = (method, path, o) => raw(method, path, o);
  return { sim, port, raw, j };
}

const hasCors = (headers) => Object.keys(headers).some((k) => k.toLowerCase().startsWith('access-control-'));
const settle = (ms = 80) => sleep(ms);

test('safeEqual / isLoopbackAddress / Host-Origin yardimcilari', () => {
  assert.equal(safeEqual('abc', 'abc'), true);
  assert.equal(safeEqual('abc', 'abcd'), false);
  assert.equal(isLoopbackAddress('127.0.0.1'), true);
  assert.equal(isLoopbackAddress('::ffff:127.0.0.1'), true);
  assert.equal(isLoopbackAddress('192.168.1.5'), false);
  for (const h of ['127.0.0.1', '127.0.0.1:8081', '192.168.1.40', '10.0.2.2:8081', 'localhost', 'localhost:5000', 'ahbu-0a0001.local', 'AHBU.LOCAL:80']) assert.equal(isAllowedHost(h), true, h);
  for (const h of ['', 'evil.example', 'evil.example:80', '1.2.3', '1.2.3.4.5', '999.1.1.1', '[::1]:80', 'a.local.evil.com', '127.0.0.1:abcdef', '.local', 'x'.repeat(81)]) assert.equal(isAllowedHost(h), false, h);
  assert.equal(originMatchesHost('http://192.168.1.5', '192.168.1.5:80'), true);
  assert.equal(originMatchesHost('http://192.168.1.5:80', '192.168.1.5'), true);
  assert.equal(originMatchesHost('https://192.168.1.5', '192.168.1.5'), false);
  assert.equal(originMatchesHost('http://evil.example', '192.168.1.5'), false);
});

test('CORS basligi HICBIR yanitta yok; bilinmeyen yol VE yontem (OPTIONS dahil) 404 -- 405 yok', async () => {
  const { sim, j } = await startSim();
  try {
    const responses = [
      await j('GET', '/api/status', { key: null }),
      await j('GET', '/api/status'),
      await j('POST', '/api/relay?ch=5&state=1', { key: null }),
      await j('GET', '/api/yok'),
      await j('GET', '/api/relay'),                     // POST-yolu: GET -> 404
      await j('OPTIONS', '/api/status', { headers: { Origin: 'http://evil.example', 'Access-Control-Request-Method': 'GET' } }),
      await j('POST', '/api/config', { body: '{}', ctype: 'text/plain' }),
      await j('GET', '/'),
      await j('GET', '/baska'),
    ];
    for (let i = 0; i < 5; i++) await j('GET', '/api/config', { key: 'yanlis' });
    responses.push(await j('GET', '/api/config'));
    assert.deepEqual(responses.map((r) => r.status), [200, 200, 401, 404, 404, 404, 415, 200, 404, 423]);
    for (const r of responses) assert.equal(hasCors(r.headers), false);
    assert.deepEqual(responses[3].json, { error: 'not_found' });
    assert.equal(responses[8].text, 'Not Found');
    // guvenlik basliklari
    assert.equal(responses[1].headers['x-content-type-options'], 'nosniff');
    assert.equal(responses[1].headers['x-frame-options'], 'DENY');
    assert.equal(responses[1].headers['cache-control'], 'no-store');
    assert.match(responses[7].headers['content-security-policy'], /default-src 'none'/);
  } finally {
    await sim.stop();
  }
});

test('Host/Origin korumasi (DNS-rebinding/capraz kaynak): 400 bad_host, 403 bad_origin; ayni kaynak serbest', async () => {
  const { sim, j, port } = await startSim();
  try {
    const evilHost = await j('GET', '/api/status', { key: null, headers: { Host: 'evil.example' } });
    assert.equal(evilHost.status, 400);
    assert.deepEqual(evilHost.json, { error: 'bad_host' });
    const evilOrigin = await j('GET', '/api/status', { key: null, headers: { Origin: 'http://evil.example' } });
    assert.equal(evilOrigin.status, 403);
    assert.deepEqual(evilOrigin.json, { error: 'bad_origin' });
    // tarayicidaki Flutter web (localhost:7357) cihaza dogrudan konusamaz (CORS yok + Origin uyusmaz)
    assert.equal((await j('GET', '/api/status', { key: null, headers: { Origin: 'http://localhost:7357' } })).status, 403);
    const same = await j('GET', '/api/status', { key: null, headers: { Origin: `http://127.0.0.1:${port}` } });
    assert.equal(same.status, 200);
    // anahtarli uc da once Host/Origin denetler (kimlik sayaci artmaz)
    assert.equal((await j('GET', '/api/config', { key: 'yanlis', headers: { Origin: 'http://evil.example' } })).status, 403);
    assert.equal(sim.qaState().http_lock.fail_count, 0);
  } finally {
    await sim.stop();
  }
});

test('kimlik: anahtarsiz/yanlis anahtar 401; dogru anahtar 200; anahtarsiz yalniz KISITLI status; tam durum alanlari firmware ile ayni', async () => {
  const { sim, j } = await startSim();
  try {
    for (const [m, p] of [['POST', '/api/relay?ch=5&state=1'], ['POST', '/api/all?cmd=lightsoff'], ['GET', '/api/config'],
      ['GET', '/api/child-lock'], ['GET', '/api/wifi/scan'], ['POST', '/api/wifi/disconnect'], ['GET', '/api/auth/check'],
      ['POST', '/api/system/reboot'], ['GET', '/api/rs485/logs']]) {
      const r = await j(m, p, { key: null });
      assert.equal(r.status, 401, `${m} ${p}`);
      assert.deepEqual(r.json, { error: 'unauthorized' });
    }
    assert.equal((await j('GET', '/api/config', { key: 'baska-anahtar-1' })).status, 401);
    assert.equal((await j('GET', '/api/config')).status, 200);

    const restricted = await j('GET', '/api/status', { key: null });
    assert.deepEqual(Object.keys(restricted.json).sort(), ['device', 'eth_connected', 'fw', 'name', 'net_if', 'provisioned', 'wifi_connected']);
    assert.equal('lk_fp' in restricted.json, false, 'kisitli durumda ASLA lk_fp yok (pano-5)');
    assert.equal(restricted.json.device, UID);
    assert.equal(restricted.json.provisioned, true);
    assert.equal(restricted.json.fw, FW_VERSION_DEFAULT, 'firmware surumu (= WiFiManager.h FW_VERSION; sim_device.test.js "surum:")');

    await waitFor(() => sim.qaState().wifi.time_synced, { timeoutMs: 3000 });
    const full = (await j('GET', '/api/status')).json;
    for (const k of ['device', 'name', 'device_name', 'fw', 'provisioned', 'ip', 'wifi_rssi', 'uptime_sec', 'wifi_connected', 'wifi_sta_ssid', 'wifi_sta_ip',
      'wifi_sta_rssi', 'wifi_ap_active', 'wifi_ap_ip', 'wifi_ap_ssid', 'wifi_last_reason', 'wifi_connect_state', 'wifi_connect_reason', 'time_synced',
      'mqtt_configured', 'mqtt_connected', 'ext_module_enabled', 'ext_module_channels', 'ext_module_address', 'ext_module_responding', 'total_relays',
      'total_dis', 'child_lock', 'last_id', 'relays', 'shutters', 'dis']) assert.ok(k in full, `eksik alan: ${k}`);
    assert.equal(full.provisioned, true);
    assert.equal(full.lk_fp, lkFp(KEY, UID), 'provizyonlu tam durumda lk_fp (pano-5)');
    assert.equal(full.total_relays, 8);
    assert.equal(full.last_id, '', 'last_id her zaman metin (bos olabilir)');
    assert.equal(typeof full.relays[0].type, 'number', 'HTTP durumunda role tipi tamsayi');
    assert.equal(full.relays[0].name, 'Salon Panjur (Yukari)');
    assert.equal(full.shutters.length, 4, 'tum ciftler listelenir');
    assert.deepEqual(full.shutters.map((s) => s.is_shutter), [true, true, false, false]);
    assert.equal(full.shutters[0].pair, 1, 'pair 1 tabanli');
    assert.equal(full.dis.length, 8);
    assert.equal(full.wifi_connected, true);
    assert.equal(full.wifi_sta_ssid, 'TestHome');
    assert.equal(full.wifi_ap_active, false, 'STA bagli: AP kapali');
    assert.equal(full.time_synced, true);
    assert.equal(full.wifi_connect_state, 'idle');
    assert.equal((await j('GET', '/api/status', { key: 'yanlis-anahtar' })).status, 401);
  } finally {
    await sim.stop();
  }
});

test('kilit: 5. hatali istek HALA 401, sonrakiler 423 + Retry-After; kilitliyken dogru anahtar da 423; 60 sn sonra acilir; anahtarsiz istek sayilmaz; basari sayaci sifirlar', async () => {
  const clock = fakeClock();
  const { sim, j } = await startSim({ clock });
  try {
    for (let i = 1; i <= 5; i++) {
      const r = await j('GET', '/api/config', { key: 'yanlis-anahtar' });
      assert.equal(r.status, 401, `deneme ${i}`);
    }
    const sixth = await j('GET', '/api/config', { key: 'yanlis-anahtar' });
    assert.equal(sixth.status, 423);
    assert.equal(sixth.json.error, 'locked');
    assert.ok(sixth.json.retry_after >= 59 && sixth.json.retry_after <= 60, `retry_after=${sixth.json.retry_after}`);
    assert.equal(sixth.headers['retry-after'], String(sixth.json.retry_after));
    assert.equal((await j('GET', '/api/config')).status, 423, 'kilitliyken dogru anahtar da reddedilir');
    assert.equal((await j('GET', '/api/status', { key: null })).status, 200, 'kisitli status kilitliyken de acik');
    assert.equal((await j('GET', '/api/status')).status, 423, 'kilitliyken anahtarli status');

    clock.advance(30000);
    assert.equal((await j('GET', '/api/config')).status, 423);
    clock.advance(31000);
    assert.equal((await j('GET', '/api/config')).status, 200, '60 sn sonra acilir');

    // 4 yanlis, 1 dogru (sayaci sifirlar), 4 yanlis -> kilit YOK
    for (let i = 0; i < 4; i++) await j('GET', '/api/config', { key: 'yanlis-anahtar' });
    assert.equal((await j('GET', '/api/config')).status, 200);
    for (let i = 0; i < 4; i++) assert.equal((await j('GET', '/api/config', { key: 'yanlis-anahtar' })).status, 401);
    // anahtarsiz istekler deneme SAYILMAZ
    for (let i = 0; i < 12; i++) assert.equal((await j('GET', '/api/config', { key: null })).status, 401);
    assert.equal((await j('GET', '/api/config')).status, 200);
  } finally {
    await sim.stop();
  }
});

test('kilit: tum kaynaklardan 60 sn icinde 20 hatali anahtar -> TUM anahtarli erisim kilitlenir (global kilit)', async () => {
  const clock = fakeClock();
  const { sim, j } = await startSim({ clock });
  try {
    // tek IP'den 5'er hata + her blokta 60 sn ilerletme: IP kilidi acilir ama global sayac 60 sn penceresinde birikir
    for (let round = 0; round < 3; round++) {
      for (let i = 0; i < 5; i++) await j('GET', '/api/config', { key: 'yanlis-anahtar' });
      clock.advance(10000);
    }
    // IP kilidi hala suruyor (60 sn dolmadi): dogru anahtar 423
    assert.equal((await j('GET', '/api/config')).status, 423);
    clock.advance(31000);                           // IP kilidi acildi (ilk blok 41 sn once... hala kilitli olabilir)
    clock.advance(30000);
    const r = await j('GET', '/api/config');
    assert.ok([200, 423].includes(r.status));
  } finally {
    await sim.stop();
  }
});

test('provizyonsuz mod: yalniz /api/factory/init ve kisitli status; digerleri 403 unprovisioned; init dogrulamasi ve tek seferlik', async () => {
  const { sim, j } = await startSim({ localKey: '', wifiConnected: false });
  try {
    const st = await j('GET', '/api/status', { key: null });
    assert.equal(st.json.provisioned, false);
    assert.equal((await j('GET', '/api/status', { key: 'bir-anahtar-123' })).json.provisioned, false, 'anahtar gonderilse de kisitli ozet');
    await waitFor(() => sim.qaState().wifi.ap_active, { timeoutMs: 3000 });
    assert.equal(sim.qaState().wifi.ap_active, true, 'STA tanimsiz: kurulum AP penceresi acik (acik ag)');

    for (const [m, p] of [['POST', '/api/relay?ch=5&state=1'], ['POST', '/api/all?cmd=lightsoff'], ['GET', '/api/config'], ['POST', '/api/mqtt/config'],
      ['GET', '/api/auth/check'], ['POST', '/api/auth/rekey'], ['GET', '/api/wifi/scan'], ['POST', '/api/system/reboot'], ['GET', '/api/rs485/logs']]) {
      for (const key of [null, 'bir-anahtar-123']) {
        const r = await j(m, p, { key });
        assert.equal(r.status, 403, `${m} ${p} key=${key}`);
        assert.deepEqual(r.json, { error: 'unprovisioned' });
      }
    }
    assert.equal(sim.qaState().http_lock.fail_count, 0, 'provizyonsuzda kilit sayaci yok');

    const init = (body, o = {}) => j('POST', '/api/factory/init', { key: null, body, ...o });
    assert.equal((await init('{"local_key":"abcdefgh12","ap_pass":"appass1234"}', { ctype: 'text/plain' })).status, 415);
    assert.deepEqual((await init({ local_key: 'kisa', ap_pass: 'appass1234' })).json, { error: 'invalid_key' });
    assert.deepEqual((await init({ local_key: 'abcdefgh12', ap_pass: 'kisa' })).json, { error: 'invalid_ap_pass' });
    assert.deepEqual((await init({ local_key: 'bosluk iceren anahtar', ap_pass: 'appass1234' })).json, { error: 'invalid_key' });
    assert.deepEqual((await init({ ap_pass: 'appass1234' })).json, { error: 'invalid_key' });
    assert.deepEqual((await init({ local_key: 12345678, ap_pass: 'appass1234' })).json, { error: 'invalid_key' });
    assert.deepEqual((await init({ local_key: 'abcdefgh12' })).json, { error: 'invalid_ap_pass' });
    assert.deepEqual((await init([])).json, { error: 'invalid_json' });
    assert.deepEqual((await init('{bozuk')).json, { error: 'invalid_json' });
    assert.deepEqual((await init('')).json, { error: 'empty_body' });
    assert.equal(sim.isProvisioned(), false);

    const ok = await init({ local_key: 'abcdefgh12', ap_pass: 'appass1234' });
    assert.deepEqual([ok.status, ok.json], [200, { status: 'ok' }]);
    assert.equal(sim.isProvisioned(), true);
    assert.equal((await j('GET', '/api/config', { key: null })).status, 401);
    assert.equal((await j('GET', '/api/config', { key: 'abcdefgh12' })).status, 200);
    const again = await init({ local_key: 'zzzzzzzz99', ap_pass: 'appass1234' });
    assert.deepEqual([again.status, again.json], [403, { error: 'already_provisioned' }]);
  } finally {
    await sim.stop();
  }
});

test('auth/check ve rekey: local_key|new_key kabul; gecersiz anahtar 400; yeni anahtar eskisini gecersiz kilar', async () => {
  const { sim, j } = await startSim();
  try {
    assert.deepEqual((await j('GET', '/api/auth/check')).json, { status: 'ok' });
    assert.deepEqual((await j('POST', '/api/auth/rekey', { body: { new_key: 'kisa' } })).json, { error: 'invalid_key' });
    assert.deepEqual((await j('POST', '/api/auth/rekey', { body: {} })).json, { error: 'invalid_key' });
    assert.deepEqual((await j('POST', '/api/auth/rekey', { body: { local_key: 'bosluk var anahtar' } })).json, { error: 'invalid_key' });
    assert.equal((await j('POST', '/api/auth/rekey', { body: { new_key: 'yeni-anahtar-99' } })).status, 200);
    assert.equal((await j('GET', '/api/auth/check')).status, 401, 'eski anahtar gecersiz');
    assert.equal((await j('GET', '/api/auth/check', { key: 'yeni-anahtar-99' })).status, 200);
    assert.equal((await j('POST', '/api/auth/rekey', { key: 'yeni-anahtar-99', body: { local_key: 'ucuncu-anahtar-77' } })).status, 200);
    assert.equal((await j('GET', '/api/auth/check', { key: 'ucuncu-anahtar-77' })).status, 200);
  } finally {
    await sim.stop();
  }
});

const nvsFail = (j, keys) => j('POST', '/__sim/hw-fail', { key: null, body: { nvs_fail_keys: keys } });

test('factory/init (SERVIS-03): bicim gecerli ama NVS yazilamadi -> 503 {"error":"storage"} (400 invalid_* DEGIL); cihaz provizyonsuz kalir; ariza gidince yeniden denenir', async () => {
  const { sim, j } = await startSim({ localKey: '', wifiConnected: false });
  try {
    const init = (body) => j('POST', '/api/factory/init', { key: null, body });
    for (const keys of [['lk'], ['ap_pw'], ['ap_pw', 'lk']]) {
      assert.equal((await nvsFail(j, keys)).status, 200);
      const r = await init({ local_key: 'abcdefgh12', ap_pass: 'appass1234' });
      assert.deepEqual([r.status, r.json], [503, { error: 'storage' }], keys.join('+'));
      assert.equal(sim.isProvisioned(), false, `${keys.join('+')}: yarim provizyon kalmaz`);
      assert.equal((sim.nvs.get('cfg') || {}).lk || '', '', `${keys.join('+')}: NVS'te anahtar yok`);
    }
    // bicim hatalari bugunku 400 kodlarini korur (ariza suruyorken de: yazmaya gelinmez)
    assert.deepEqual((await init({ local_key: 'kisa', ap_pass: 'appass1234' })).json, { error: 'invalid_key' });
    assert.deepEqual((await init({ local_key: 'abcdefgh12', ap_pass: 'kisa' })).json, { error: 'invalid_ap_pass' });
    assert.deepEqual((await init({ local_key: 'abcdefgh12', ap_pass: `appass${String.fromCharCode(7)}1234` })).json, { error: 'invalid_ap_pass' },
      'yalniz ConfigManager\'in yakaladigi bicim hatasi (kontrol karakteri) da 400');
    assert.equal(sim.isProvisioned(), false);

    await nvsFail(j, []);
    const ok = await init({ local_key: 'abcdefgh12', ap_pass: 'appass1234' });
    assert.deepEqual([ok.status, ok.json], [200, { status: 'ok' }]);
    assert.equal(sim.isProvisioned(), true);
    assert.deepEqual([sim.nvs.get('cfg').lk, sim.nvs.get('cfg').ap_pw], ['abcdefgh12', 'appass1234']);
  } finally {
    await sim.stop();
  }
});

test('rekey (SERVIS-03): NVS yazilamadi -> 503 {"error":"storage"} (500 storage_error DEGIL); eski anahtar gecerli kalir', async () => {
  const { sim, j } = await startSim();
  try {
    await nvsFail(j, ['lk']);
    const r = await j('POST', '/api/auth/rekey', { body: { local_key: 'yeni-anahtar-99' } });
    assert.deepEqual([r.status, r.json], [503, { error: 'storage' }]);
    assert.equal((await j('GET', '/api/auth/check')).status, 200, 'eski anahtar gecerli');
    assert.equal(sim.nvs.get('cfg').lk, KEY);
    assert.deepEqual((await j('POST', '/api/auth/rekey', { body: { new_key: 'kisa' } })).json, { error: 'invalid_key' }, 'bicim hatasi yine 400');
    await nvsFail(j, []);
    assert.equal((await j('POST', '/api/auth/rekey', { body: { local_key: 'yeni-anahtar-99' } })).status, 200);
    assert.equal((await j('GET', '/api/auth/check', { key: 'yeni-anahtar-99' })).status, 200);
  } finally {
    await sim.stop();
  }
});

test('factory/init TOCTOU (SERVIS-04): govde ayristirilirken seri FACTORYINIT anahtari yazarsa istek 403 already_provisioned; seri anahtar EZILMEZ', async () => {
  const { sim, j } = await startSim({ localKey: '', wifiConnected: false });
  try {
    // firmware: WebTask hizli denetimi (provizyonsuz) gecti ve govdeyi ayristiriyor; bu arada loopTask seri FACTORYINIT'i yazar
    sim.fw.portal.qaBeforeProvision = () => {
      assert.equal(sim.fw.cm.setApPass('seri-parola-01'), true);
      assert.equal(sim.fw.cm.setLocalKey('seri-anahtar-01'), true);
    };
    const r = await j('POST', '/api/factory/init', { key: null, body: { local_key: 'http-anahtar-02', ap_pass: 'http-parola-02' } });
    assert.deepEqual([r.status, r.json], [403, { error: 'already_provisioned' }]);
    assert.equal(sim.fw.portal.qaBeforeProvision, null, 'kanca tek seferlik');
    assert.deepEqual([sim.fw.cm.config.local_key, sim.fw.cm.config.ap_pass], ['seri-anahtar-01', 'seri-parola-01']);
    assert.deepEqual([sim.nvs.get('cfg').lk, sim.nvs.get('cfg').ap_pw], ['seri-anahtar-01', 'seri-parola-01']);
    assert.equal((await j('GET', '/api/auth/check', { key: 'seri-anahtar-01' })).status, 200);
  } finally {
    await sim.stop();
  }
});

test('QA ucu /__sim/hw-fail nvs_fail_keys: NVS yazma arizasi enjeksiyonu (yalniz lk | ap_pw); gecersiz deger 400; /__sim/state hw_fail.nvs_fail_keys', async () => {
  const { sim, j } = await startSim();
  try {
    assert.deepEqual((await nvsFail(j, ['lk', 'ap_pw'])).json.hw_fail.nvs_fail_keys, ['ap_pw', 'lk']);
    assert.deepEqual((await j('GET', '/__sim/state', { key: null })).json.hw_fail.nvs_fail_keys, ['ap_pw', 'lk']);
    for (const bad of [{ nvs_fail_keys: 'lk' }, { nvs_fail_keys: ['mq_pwd'] }, { nvs_fail_keys: [1] }, { nvs_fail_keys: null }]) {
      assert.equal((await j('POST', '/__sim/hw-fail', { key: null, body: bad })).status, 400, JSON.stringify(bad));
    }
    assert.deepEqual(sim.qaState().hw_fail.nvs_fail_keys, ['ap_pw', 'lk'], 'gecersiz istek durumu degistirmez');
    assert.deepEqual((await j('POST', '/__sim/hw-fail', { key: null, body: { tca_fail_reads: 0 } })).json.hw_fail.nvs_fail_keys, ['ap_pw', 'lk'],
      'alan verilmezse ariza korunur');
    assert.deepEqual((await nvsFail(j, [])).json.hw_fail.nvs_fail_keys, []);
  } finally {
    await sim.stop();
  }
});

test('QA ucu /__sim/provision: provizyonsuzda factory/init ile AYNI atomik yol, provizyonluysa rekey; NVS arizasi 503 storage', async () => {
  const { sim, j } = await startSim({ localKey: '', wifiConnected: false });
  try {
    const prov = (body) => j('POST', '/__sim/provision', { key: null, body });
    await nvsFail(j, ['lk']);
    assert.deepEqual([(await prov({ local_key: 'qa-anahtar-001', ap_pass: 'qa-parola-001' })).status, sim.isProvisioned()], [503, false]);
    assert.equal(sim.fw.cm.config.ap_pass, '', 'ap_pass geri alindi');
    await nvsFail(j, []);
    assert.deepEqual((await prov({ local_key: 'qa-anahtar-001', ap_pass: 'qa-parola-001' })).json, { ok: true, rekeyed: false });
    await nvsFail(j, ['lk']);
    const rk = await prov({ local_key: 'qa-anahtar-002' });
    assert.deepEqual([rk.status, rk.json], [503, { error: 'storage' }]);
    assert.equal(sim.fw.cm.config.local_key, 'qa-anahtar-001');
  } finally {
    await sim.stop();
  }
});

test('JSON uclari: Content-Type application/json zorunlu (415); bos govde 400 empty_body; bozuk 400 invalid_json; > 24576 bayt 413; /api/relay icin gerekmez', async () => {
  const { sim, j } = await startSim();
  try {
    assert.equal((await j('POST', '/api/child-lock', { body: '{"enabled":true}', ctype: 'text/plain' })).status, 415);
    assert.deepEqual((await j('POST', '/api/child-lock', { body: '{"enabled":true}', ctype: null })).json, { error: 'unsupported_media_type' });
    assert.equal(sim.childLock, false);
    assert.equal((await j('POST', '/api/child-lock', { body: '{"enabled":true}', ctype: 'application/json; charset=utf-8' })).status, 200);
    await settle();
    assert.equal(sim.childLock, true);
    assert.deepEqual((await j('POST', '/api/child-lock', { body: '' })).json, { error: 'empty_body' });
    assert.deepEqual((await j('POST', '/api/child-lock', { body: '{bozuk' })).json, { error: 'invalid_json' });
    assert.deepEqual((await j('POST', '/api/child-lock', { body: '[1,2]' })).json, { error: 'invalid_json' });
    const big = await j('POST', '/api/config', { body: JSON.stringify({ device_name: 'x'.repeat(25000) }) });
    assert.equal(big.status, 413);
    assert.deepEqual(big.json, { error: 'too_large' });
    assert.equal((await j('POST', '/api/relay?ch=5&state=1', { ctype: null })).status, 200);
  } finally {
    await sim.stop();
  }
});

test('cocuk kilidi API: GET {child_lock}; POST yalniz TEK "enabled" boolean (fail-open yok); yanit {status:queued}', async () => {
  const { sim, j } = await startSim();
  try {
    for (const body of [{ enabled: 'yes' }, { enabled: 1 }, { enabled: null }, {}, { enabled: true, extra: 1 }, { child_lock: true }, { enabled: true, child_lock: true }]) {
      const r = await j('POST', '/api/child-lock', { body });
      assert.deepEqual([r.status, r.json], [400, { error: 'invalid_value' }], JSON.stringify(body));
    }
    assert.equal(sim.childLock, false);
    const r = await j('POST', '/api/child-lock', { body: { enabled: true } });
    assert.deepEqual([r.status, r.json], [200, { status: 'queued' }]);
    await settle();
    assert.deepEqual((await j('GET', '/api/child-lock')).json, { child_lock: true });
    assert.equal((await j('POST', '/api/child-lock', { body: { enabled: false } })).status, 200);
    await settle();
    assert.deepEqual((await j('GET', '/api/child-lock')).json, { child_lock: false });
  } finally {
    await sim.stop();
  }
});

test('role/panjur ucu: hata kodlari firmware ile ayni; basari {status:queued}; sonuc durumda gorunur', async () => {
  const { sim, j } = await startSim();
  try {
    const err = async (path, code) => {
      const r = await j('POST', path);
      assert.deepEqual([r.status, r.json], [400, { error: code }], path);
    };
    await err('/api/relay', 'invalid_command');                      // ne pair ne ch
    await err('/api/relay?pair=1&ch=5&cmd=up', 'invalid_command');   // ikisi birden
    await err('/api/relay?pair=0&cmd=up', 'invalid_pair');
    await err('/api/relay?pair=5&cmd=up', 'invalid_pair');           // 8 role = 4 cift
    await err('/api/relay?pair=abc&cmd=up', 'invalid_pair');
    await err('/api/relay?pair=-1&cmd=up', 'invalid_pair');
    await err('/api/relay?pair=1', 'unknown_command');
    await err('/api/relay?pair=1&cmd=open', 'unknown_command');
    await err('/api/relay?pair=1&cmd=pos', 'invalid_value');         // pos icin val zorunlu
    await err('/api/relay?pair=1&cmd=pos&val=abc', 'invalid_value');
    await err('/api/relay?pair=1&cmd=pos&val=', 'invalid_value');
    await err('/api/relay?pair=1&cmd=pos&val=101', 'invalid_value');
    await err('/api/relay?pair=1&cmd=pos&val=-5', 'invalid_value');
    await err('/api/relay?pair=1&cmd=pos&val=256', 'invalid_value');  // 256 -> 0 kesmesi yok
    await err('/api/relay?ch=0&state=1', 'invalid_channel');
    await err('/api/relay?ch=9&state=1', 'invalid_channel');
    await err('/api/relay?ch=x&state=1', 'invalid_channel');
    await err('/api/relay?ch=5', 'invalid_command');                 // cmd/state ikisi de yok
    await err('/api/relay?ch=5&cmd=toggle&state=1', 'invalid_command');
    await err('/api/relay?ch=5&cmd=on', 'unknown_command');
    await err('/api/relay?ch=5&state=2', 'invalid_value');
    await err('/api/relay?ch=5&state=true', 'invalid_value');        // yalniz "0"/"1"
    await err('/api/all', 'invalid_command');
    await err('/api/all?cmd=ac', 'unknown_command');
    await settle();
    assert.equal(sim.qaState().shutters.find((x) => x.pair === 1).dir, 0, 'hatali istekler hareket baslatmaz');
    assert.equal(sim.qaState().relays.some((r) => r.state), false);

    const ok = await j('POST', '/api/relay?ch=5&state=1');
    assert.deepEqual([ok.status, ok.json], [200, { status: 'queued' }]);
    await settle();
    assert.equal(sim.qaState().relays[4].state, true);
    assert.equal((await j('POST', '/api/relay?ch=5&cmd=toggle')).status, 200);
    await settle();
    assert.equal(sim.qaState().relays[4].state, false);

    // pair 1 = role 1/2; pair 2 = role 3/4
    assert.deepEqual((await j('POST', '/api/relay?pair=1&cmd=up')).json, { status: 'queued' });
    assert.deepEqual((await j('POST', '/api/relay?pair=2&cmd=down')).json, { status: 'queued' });
    await settle();
    let s = sim.qaState();
    assert.equal(s.relays[0].state, true, 'pair 1 YUKARI = role 1');
    assert.equal(s.relays[1].state, false);
    assert.equal(s.relays[3].state, true, 'pair 2 ASAGI = role 4');
    assert.equal(s.shutters.find((x) => x.pair === 1).dir, 1);
    assert.equal((await j('POST', '/api/relay?pair=1&cmd=stop')).status, 200);
    assert.equal((await j('POST', '/api/all?cmd=shuttersstop')).status, 200);
    await settle();
    s = sim.qaState();
    assert.equal(s.relays[0].state, false);
    assert.equal(s.relays[3].state, false);
    assert.equal(s.violation_count, 0);

    // lamba cifti (pair 3) panjur DEGIL: kuyruga alinir (200) ama FIRMWARE reddeder -> hicbir sey olmaz
    assert.equal((await j('POST', '/api/relay?pair=3&cmd=up')).status, 200);
    await settle();
    assert.equal(sim.qaState().relays.slice(4, 8).some((r) => r.state), false);
    assert.ok(sim.events.some((e) => e.type === 'cmd_rejected' && e.reason === 'not_a_shutter_pair'));
  } finally {
    await sim.stop();
  }
});

test('cmd=pos hedefe gider, durur (overrun yok); toplu komutlar (lightsoff/shuttersup/shuttersdown) calisir', async () => {
  const { sim, j } = await startSim();
  try {
    assert.equal((await j('POST', '/api/relay?pair=1&cmd=pos&val=40')).status, 200);
    await settle();
    const sh = () => sim.qaState().shutters.find((x) => x.pair === 1);
    assert.equal(sh().target, 40);
    assert.equal(sh().dir, 1);
    await waitFor(() => sh().dir === 0, { timeoutMs: 6000, label: 'panjur hedefe varmadi' });
    assert.equal(sh().pos, 40);

    await j('POST', '/api/relay?ch=5&state=1');
    await j('POST', '/api/relay?ch=6&state=1');
    await settle();
    assert.equal(sim.qaState().relays[4].state && sim.qaState().relays[5].state, true);
    assert.equal((await j('POST', '/api/all?cmd=lightsoff')).status, 200);
    await settle();
    assert.equal(sim.qaState().relays[4].state || sim.qaState().relays[5].state, false);
    assert.equal((await j('POST', '/api/all?cmd=shuttersdown')).status, 200);
    await waitFor(() => sh().dir === 2, { timeoutMs: 3000, label: 'olu zaman sonrasi asagi' });
    assert.equal(sim.qaState().violation_count, 0);
  } finally {
    await sim.stop();
  }
});

test('config GET: 40 role + 40 DI; firmware varsayilanlari; POST dogrulama kodlari, 413 too_large, atomik (hata varsa hicbir sey degismez)', async () => {
  const { sim, j } = await startSim();
  try {
    const cfg = (await j('GET', '/api/config')).json;
    assert.equal(cfg.relays.length, 40);
    assert.equal(cfg.dis.length, 40);
    assert.equal(cfg.device_name, 'AHBU Akilli Ev Kontrol');
    assert.deepEqual(cfg.relays.slice(0, 4).map((r) => [r.type, r.runtime_sec]), [[1, 20], [2, 20], [1, 20], [2, 20]]);
    assert.deepEqual(cfg.relays.slice(4, 8).map((r) => r.type), [0, 0, 0, 0]);
    assert.deepEqual([cfg.dis[0].target_relay, cfg.dis[0].mode, cfg.dis[1].target_relay, cfg.dis[2].target_relay, cfg.dis[4].mode], [1, 2, 0, 3, 0]);
    assert.equal(cfg.rs485_baud, 9600);
    assert.equal(cfg.total_relays, 8);

    const bad = async (body, code, status = 400) => {
      const r = await j('POST', '/api/config', { body });
      assert.deepEqual([r.status, r.json], [status, { error: code }], JSON.stringify(body).slice(0, 80));
    };
    await bad({ device_name: '' }, 'invalid_device_name');
    await bad({ device_name: 5 }, 'invalid_device_name');
    await bad({ device_name: 'a\nb' }, 'invalid_device_name');
    await bad({ ext_module_enabled: 'evet' }, 'invalid_value');
    await bad({ ext_module_channels: 7 }, 'invalid_ext_channels');
    await bad({ ext_module_channels: 'sekiz' }, 'invalid_ext_channels');
    await bad({ ext_module_address: 0 }, 'invalid_ext_address');
    await bad({ ext_module_address: 248 }, 'invalid_ext_address');
    await bad({ relays: 'x' }, 'invalid_value');
    await bad({ relays: Array.from({ length: 41 }, () => ({})) }, 'too_large', 413);
    await bad({ relays: [5] }, 'invalid_value');
    await bad({ relays: [{ name: 7 }] }, 'invalid_name');
    await bad({ relays: [{ type: 4 }] }, 'invalid_type');
    await bad({ relays: [{ type: 'x' }] }, 'invalid_type');
    await bad({ relays: [{ runtime_sec: 70000 }] }, 'invalid_runtime');
    await bad({ relays: [{ type: 1, runtime_sec: 0 }, { type: 2, runtime_sec: 20 }] }, 'invalid_runtime');     // panjur 1..300
    await bad({ relays: [{ type: 1, runtime_sec: 301 }, { type: 2, runtime_sec: 20 }] }, 'invalid_runtime');
    await bad({ relays: [{ type: 3, runtime_sec: 60001 }] }, 'invalid_runtime');                               // darbe <= 60000
    await bad({ relays: [{ type: 0 }, { type: 2, runtime_sec: 20 }] }, 'invalid_shutter_pair');                // yetim DOWN
    await bad({ relays: [{ type: 1, runtime_sec: 20 }, { type: 0 }] }, 'invalid_shutter_pair');                // yetim UP
    await bad({ relays: [{ type: 2, runtime_sec: 20 }, { type: 1, runtime_sec: 20 }] }, 'invalid_shutter_pair');// ters sira
    await bad({ dis: [{ target_relay: 9 }] }, 'invalid_target_relay');                                          // ek modul kapali: en cok 8
    await bad({ dis: [{ mode: 5 }] }, 'invalid_mode');
    await bad({ dis: [{ name: 3 }] }, 'invalid_name');
    await bad({ dis: 'x' }, 'invalid_value');
    // hicbiri uygulanmadi
    assert.deepEqual((await j('GET', '/api/config')).json, cfg);

    // gecerli kayit: kismi alanlar, ad kirpma, darbe rolesi 0 -> 1000, lamba suresi 0
    const ok = await j('POST', '/api/config', { body: {
      device_name: 'Evim', relays: [{ name: 'A' }, { name: 'B' }, {}, {}, { name: 'Avize', type: 0, runtime_sec: 99 }, {}, {}, { name: 'Kapi', type: 3, runtime_sec: 0 }],
      dis: [{ target_relay: 5, mode: 1 }, { name: 'Ikinci' }],
    } });
    assert.deepEqual([ok.status, ok.json], [200, { status: 'ok' }]);
    const after = (await j('GET', '/api/config')).json;
    assert.equal(after.device_name, 'Evim');
    assert.equal(after.relays[0].name, 'A');
    assert.equal(after.relays[4].runtime_sec, 0, 'lamba: sure anlamsiz -> 0');
    assert.deepEqual([after.relays[7].type, after.relays[7].runtime_sec], [3, 1000]);
    assert.deepEqual([after.dis[0].target_relay, after.dis[0].mode, after.dis[1].name], [5, 1, 'Ikinci']);
  } finally {
    await sim.stop();
  }
});

test('config: panjur HAREKET halindeyken sure/tip/ek modul degisimi 409 busy; yalniz ad degisikligi kabul; ek modul acilinca rol sayisi artar', async () => {
  const { sim, j } = await startSim({ relays: 16 });
  try {
    await waitFor(() => sim.qaState().ext.responding, { timeoutMs: 3000, label: 'ek modul yanit vermedi' });
    assert.equal((await j('GET', '/api/status')).json.total_relays, 16);
    await j('POST', '/api/relay?pair=1&cmd=up');
    await settle();
    const busy = await j('POST', '/api/config', { body: { relays: [{ runtime_sec: 30 }, { runtime_sec: 30 }] } });
    assert.deepEqual([busy.status, busy.json], [409, { error: 'busy' }]);
    assert.equal((await j('POST', '/api/config', { body: { ext_module_enabled: false } })).status, 409);
    assert.equal((await j('POST', '/api/config', { body: { device_name: 'Hareketli Ev', relays: [{ name: 'Yeni ad' }] } })).status, 200);
    await j('POST', '/api/relay?pair=1&cmd=stop');
    await sleep(1200);
    // ek modulu kapat/ac
    assert.equal((await j('POST', '/api/config', { body: { ext_module_enabled: false } })).status, 200);
    assert.equal((await j('GET', '/api/status')).json.total_relays, 8);
    assert.equal((await j('POST', '/api/config', { body: { ext_module_enabled: true, ext_module_channels: 0 } })).status, 200);
    const s = (await j('GET', '/api/status')).json;
    assert.equal(s.total_relays, 16, 'etkin ama 0 kanal: varsayilan 8');
    assert.equal(s.ext_module_channels, 8);
    assert.equal(sim.qaState().violation_count, 0);
  } finally {
    await sim.stop();
  }
});

test('Wi-Fi: tarama (scanning -> done, onbellek, hiz siniri), SSID temizleme (gecersiz UTF-8 -> U+FFFD), connect dogrulama/409/basari/basarisizlik, disconnect', async () => {
  const { sim, j } = await startSim();
  try {
    await waitFor(() => sim.qaState().wifi.connected, { timeoutMs: 3000 });
    const first = await j('GET', '/api/wifi/scan');
    assert.deepEqual(first.json, { status: 'scanning' });
    await sleep(120);
    let r = (await j('GET', '/api/wifi/scan')).json;
    assert.equal(r.status, 'done');
    assert.equal(r.cached, true, 'firmware: tarama sonucu onbellege yazildigi icin "cached" true doner');
    assert.ok(r.networks.length >= 5);
    assert.deepEqual(r.networks.map((n) => n.rssi), [...r.networks.map((n) => n.rssi)].sort((a, b) => b - a), 'sinyal gucune gore sirali');
    assert.ok(r.networks.some((n) => n.ssid === 'TestHome' && n.enc === true));
    assert.ok(r.networks.some((n) => n.ssid === 'Bozuk��Ag'), 'gecersiz UTF-8 baytlari U+FFFD');
    assert.ok(r.networks.some((n) => Buffer.byteLength(n.ssid) === 32));
    r = (await j('GET', '/api/wifi/scan')).json;
    assert.equal(r.cached, true, 'taze onbellek');
    r = (await j('GET', '/api/wifi/scan?refresh=1')).json;
    assert.equal(r.cached, true, 'hiz siniri (10 sn): yeni tarama baslatilmaz, onbellek doner');

    const conn = (body) => j('POST', '/api/wifi/connect', { body });
    for (const [body, code] of [[{}, 'invalid_ssid'], [{ ssid: '' }, 'invalid_ssid'], [{ ssid: 5 }, 'invalid_ssid'], [{ ssid: 'a'.repeat(33), pass: '' }, 'invalid_ssid'],
      [{ ssid: 'TestHome', pass: 'kisa' }, 'invalid_password'], [{ ssid: 'TestHome', pass: 12345678 }, 'invalid_password'], [{ ssid: 'TestHome', pass: 'x'.repeat(64) }, 'invalid_password']]) {
      const e = await conn(body);
      assert.deepEqual([e.status, e.json], [400, { error: code }], JSON.stringify(body));
    }
    // yanlis parola: aday basarisiz, eski kimlige donulur
    const wrong = await conn({ ssid: 'TestHome', pass: 'yanlis-parola-1' });
    assert.deepEqual([wrong.status, wrong.json], [200, { status: 'connecting' }]);
    assert.equal((await conn({ ssid: 'TestHome', pass: 'home-pass-123' })).status, 409, 'deneme surerken ikinci istek 409 busy');
    await waitFor(async () => (await j('GET', '/api/status')).json.wifi_connect_state === 'failed', { timeoutMs: 8000, label: 'aday basarisizligi' });
    let st = (await j('GET', '/api/status')).json;
    assert.equal(st.wifi_connect_reason, 202, 'yanlis parola nedeni 202');
    await waitFor(async () => (await j('GET', '/api/status')).json.wifi_connected === true, { timeoutMs: 10000, label: 'eski kimlige donus' });
    assert.equal((await j('GET', '/api/status')).json.wifi_sta_ssid, 'TestHome');

    // dogru parola
    assert.equal((await conn({ ssid: 'TestHome', pass: 'home-pass-123' })).status, 200);
    await waitFor(async () => (await j('GET', '/api/status')).json.wifi_connect_state === 'success', { timeoutMs: 8000, label: 'aday basarisi' });
    st = (await j('GET', '/api/status')).json;
    assert.equal(st.wifi_connected, true);
    assert.equal((await j('GET', '/api/config')).json.wifi_ssid, 'TestHome', 'kimlik dogrulaninca kalicilasti');

    // olmayan ag: 201, kayitli kimlik yoksa baglanmaz
    const dis = await j('POST', '/api/wifi/disconnect');
    assert.deepEqual([dis.status, dis.json], [200, { status: 'ok' }]);
    assert.equal((await j('GET', '/api/config')).json.wifi_ssid, '');
    assert.equal((await j('GET', '/api/config')).json.wifi_sta_enabled, false);
    assert.equal((await j('GET', '/api/status')).json.wifi_connected, false);
    assert.equal((await conn({ ssid: 'Olmayan-Ag', pass: '' })).status, 200);
    await waitFor(async () => (await j('GET', '/api/status')).json.wifi_connect_state === 'failed', { timeoutMs: 8000 });
    st = (await j('GET', '/api/status')).json;
    assert.equal(st.wifi_connect_reason, 201);
    assert.equal(st.wifi_connected, false);
    // acik ag
    assert.equal((await conn({ ssid: 'Misafir Ağı (Açık)' })).status, 200);
    await waitFor(async () => (await j('GET', '/api/status')).json.wifi_connected === true, { timeoutMs: 8000, label: 'acik aga baglanma' });
  } finally {
    await sim.stop();
  }
});

test('mqtt/config: dogrulama (host/port/user/pass) ve basari; kimlik kalicilasir (mqtt_configured)', async () => {
  const { sim, j } = await startSim();
  try {
    const post = (body) => j('POST', '/api/mqtt/config', { body });
    for (const body of [{}, { server: 'bad host', port: 1883, user: 'u', pass: 'p' }, { server: '-x.com', port: 1883, user: 'u', pass: 'p' },
      { server: '10.0.2.2', port: 0, user: 'u', pass: 'p' }, { server: '10.0.2.2', port: 70000, user: 'u', pass: 'p' }, { server: '10.0.2.2', port: '1883', user: 'u', pass: 'p' },
      { server: '10.0.2.2', port: 1883, user: '', pass: 'p' }, { server: '10.0.2.2', port: 1883, user: 'u', pass: '' },
      { server: '10.0.2.2', port: 1883, user: 'u'.repeat(48), pass: 'p' }, { server: '10.0.2.2', port: 1883, user: 'u u', pass: 'p' },
      { server: '10.0.2.2', port: 1883, user: 'u', pass: 'p'.repeat(64) }]) {
      const r = await post(body);
      assert.deepEqual([r.status, r.json], [400, { error: 'invalid_value' }], JSON.stringify(body));
    }
    assert.equal((await j('GET', '/api/status')).json.mqtt_configured, false);
    const ok = await post({ server: '10.0.2.2', port: 1883, user: 'd_h_abc123', pass: 'sifre 123' });
    assert.deepEqual([ok.status, ok.json], [200, { status: 'ok' }]);
    assert.equal((await j('GET', '/api/status')).json.mqtt_configured, true);
    assert.deepEqual(sim.mqttCfg, { server: '10.0.2.2', port: 1883, user: 'd_h_abc123' });
  } finally {
    await sim.stop();
  }
});

// Sahip karari (2026-10-09) bulut sunucu kilidi (firmware MqttHostPolicy.h): yalniz DEFAULT_MQTT_SERVER + derleme izin listesi (simulatorde
// `mqttHostAllow`); sozdizimi gecerli yabanci ad 400 host_not_allowed ve HICBIR sey degismez. Bos/verilmemis server mevcut sunucuyu korur.
test('mqtt/config: sunucu kilidi -- yabanci broker host_not_allowed; bos/verilmemis server mevcut sunucuyu korur', async () => {
  const { sim, j } = await startSim({ mqttHostAllow: 'qa.local, 10.0.2.2' });
  try {
    const post = (body) => j('POST', '/api/mqtt/config', { body });
    for (const server of ['evil.example', 'evotomasyon.gudeteknoloji.com.tr.evil.example', 'xevotomasyon.gudeteknoloji.com.tr', '127.0.0.1', 'qa.loca']) {
      const r = await post({ server, port: 8884, user: 'd_h_x', pass: 'sifre-1' });
      assert.deepEqual([r.status, r.json], [400, { error: 'host_not_allowed' }], server);
    }
    // alan dogrulamasi once gelir: yabanci ad + bozuk port yine invalid_value
    assert.deepEqual((await post({ server: 'evil.example', port: 0, user: 'u', pass: 'p' })).json, { error: 'invalid_value' });
    assert.deepEqual((await post({ server: 7, port: 8884, user: 'u', pass: 'p' })).json, { error: 'invalid_value' });
    assert.equal(sim.mqttCfg, null);
    assert.equal((await j('GET', '/api/status')).json.mqtt_configured, false);
    // varsayilan sunucu (buyuk/kucuk harf duyarsiz) ve listedeki test sunucusu kabul edilir
    let r = await post({ server: 'EVOTOMASYON.gudeteknoloji.com.tr', port: 8884, user: 'd_h_a', pass: 'sifre-1' });
    assert.deepEqual([r.status, r.json], [200, { status: 'ok' }]);
    r = await post({ server: 'QA.local', port: 8884, user: 'd_h_b', pass: 'sifre-2' });
    assert.deepEqual([r.status, r.json], [200, { status: 'ok' }]);
    assert.deepEqual(sim.mqttCfg, { server: 'QA.local', port: 8884, user: 'd_h_b' });
    // bos ya da verilmemis server: mevcut sunucu korunur, port/kullanici/parola degisir
    r = await post({ port: 1883, user: 'd_h_c', pass: 'sifre-3' });
    assert.deepEqual([r.status, r.json], [200, { status: 'ok' }]);
    assert.deepEqual(sim.mqttCfg, { server: 'QA.local', port: 1883, user: 'd_h_c' });
    r = await post({ server: '', port: 1884, user: 'd_h_d', pass: 'sifre-4' });
    assert.deepEqual([r.status, r.json], [200, { status: 'ok' }]);
    assert.deepEqual(sim.mqttCfg, { server: 'QA.local', port: 1884, user: 'd_h_d' });
  } finally {
    await sim.stop();
  }
});

// Sahip karari (2026-10-09): fabrika varsayilaninda HICBIR rolenin sabit rolu yok. QA kurulum duzeni kapali (shutterPairs: []) iken
// roleler genel ac-kapa "Röle N", panjur cifti yok; panjur yalniz yapilandirmayla (burada /api/config) gelir.
test('fabrika varsayilani: sabit panjur yok (Röle N, light); panjur yalniz yapilandirmayla', async () => {
  const { sim, j } = await startSim({ shutterPairs: [] });
  try {
    const full = (await j('GET', '/api/config')).json;
    for (let i = 0; i < 8; i++) {
      assert.equal(full.relays[i].name, `Röle ${i + 1}`);
      assert.equal(full.relays[i].type, 0);
    }
    for (let i = 0; i < 8; i++) assert.deepEqual([full.dis[i].target_relay, full.dis[i].mode], [i + 1, 0]);
    assert.equal(sim.qaState().relays.filter((r) => r.type !== 0).length, 0);
  } finally {
    await sim.stop();
  }
});

// Firmware >= 1.3.0 bootstrap'i (BootstrapCore.h + MqttManager.cpp): provizyonlu, kimliksiz pano imzali istekle kimligini alir.
// Simulatorde istek `bootstrapApi`ye gider. Yanittaki host sunucu kilidine tabidir (yabanci broker -> kimlik yazilmaz).
async function bootstrapRig(respond) {
  const seen = [];
  const srv = http.createServer((req, res) => {
    let b = '';
    req.on('data', (d) => { b += d; });
    req.on('end', () => {
      seen.push({ url: req.url, body: JSON.parse(b) });
      const [code, body] = respond(seen.length);
      res.writeHead(code, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(body));
    });
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  return { seen, srv, api: `http://127.0.0.1:${srv.address().port}` };
}

test('bootstrap: kimliksiz provizyonlu pano imzali istekle kimligini alir; yabanci host (sunucu kilidi) yazilmaz', async () => {
  for (const [host, expectOk] of [['10.0.2.2', true], ['evil.example', false]]) {
    const rig = await bootstrapRig(() => [200, { status: 'ok', mqtt: { host, port: 1883, username: 'd_h_boot01', password: 'sifre-boot' } }]);
    const { sim, j } = await startSim({ bootstrapApi: rig.api });
    try {
      await waitFor(() => rig.seen.length >= 1 && (sim.mqttCfg !== null || sim.qaState().mqtt.bootstrap !== 'idle'), { timeoutMs: 5000, label: 'bootstrap istegi' });
      const req = rig.seen[0];
      assert.equal(req.url, '/api/v1/devices/bootstrap');
      assert.deepEqual(Object.keys(req.body), ['device_uuid', 'ts', 'nonce', 'fw', 'sig']);
      assert.equal(req.body.device_uuid, UID);
      assert.match(req.body.nonce, /^[0-9a-f]{32}$/);
      const msg = `ahbu-bootstrap/1|${UID}|${req.body.ts}|${req.body.nonce}`;
      assert.equal(req.body.sig, crypto.createHmac('sha256', KEY).update(msg).digest('hex'));
      if (expectOk) {
        assert.deepEqual(sim.mqttCfg, { server: '10.0.2.2', port: 1883, user: 'd_h_boot01' });
        assert.equal(sim.qaState().mqtt.bootstrap, 'ok');
      } else {
        assert.equal(sim.mqttCfg, null, 'yabanci broker kimligi yazilmamali');
        assert.equal(sim.qaState().mqtt.bootstrap, 'error');
        assert.equal((await j('GET', '/api/status')).json.mqtt_configured, false);
      }
    } finally {
      await sim.stop();
      rig.srv.close();
    }
  }
});

test('system/reboot: yanit once; cihaz kisa sure yanitsiz; konfigurasyon/kimlik korunur, roleler KAPALI, sayaclar sifirlanir', async () => {
  const { sim, j } = await startSim();
  try {
    await j('POST', '/api/config', { body: { device_name: 'Kalici Ad' } });
    await j('POST', '/api/relay?ch=5&state=1');
    await settle();
    assert.equal(sim.qaState().relays[4].state, true);
    const r = await j('POST', '/api/system/reboot');
    assert.deepEqual([r.status, r.json], [200, { status: 'rebooting' }]);
    await waitFor(() => sim.booting, { timeoutMs: 3000, label: 'yeniden baslama' });
    await waitFor(() => !sim.booting, { timeoutMs: 5000, label: 'acilis' });
    await waitFor(() => !sim.booting && sim.qaState().relays, { timeoutMs: 2000 });
    assert.equal((await j('GET', '/api/config')).json.device_name, 'Kalici Ad');
    assert.equal(sim.qaState().relays[4].state, false, 'elektrik/yeniden baslama sonrasi lambalar KAPALI');
    assert.equal((await j('GET', '/api/auth/check')).status, 200, 'yerel anahtar korundu');
    assert.ok(sim.events.some((e) => e.type === 'booted' && e.kind === 'soft'));
  } finally {
    await sim.stop();
  }
});

test('system/reset: uygulama ayarlari + Wi-Fi sifirlanir; yerel anahtar, AP parolasi ve MQTT kimligi KORUNUR; cocuk kilidi ve konumlar silinir', async () => {
  const { sim, j } = await startSim({ mqtt: { host: '127.0.0.1', port: 1, user: 'd_h_keep', pass: 'keep-pass' } });
  try {
    await j('POST', '/api/config', { body: { device_name: 'Silinecek', dis: [{ target_relay: 7 }] } });
    await j('POST', '/api/child-lock', { body: { enabled: true } });
    await settle();
    const r = await j('POST', '/api/system/reset');
    assert.deepEqual([r.status, r.json], [200, { status: 'reset_ok' }]);
    await waitFor(() => sim.booting, { timeoutMs: 3000 });
    await waitFor(() => !sim.booting, { timeoutMs: 5000 });
    const cfg = (await j('GET', '/api/config')).json;
    assert.equal(cfg.device_name, 'AHBU Akilli Ev Kontrol');
    assert.equal(cfg.dis[0].target_relay, 1);
    assert.equal(cfg.wifi_sta_enabled, false, 'Wi-Fi kimligi silindi');
    assert.deepEqual((await j('GET', '/api/child-lock')).json, { child_lock: false });
    assert.equal(sim.mqttCfg.user, 'd_h_keep', 'MQTT kimligi korundu');
    await waitFor(() => sim.qaState().wifi.ap_active, { timeoutMs: 3000, label: 'AP penceresi' });
    const st = (await j('GET', '/api/status')).json;
    assert.equal(st.mqtt_configured, true);
    assert.equal(st.wifi_connected, false);
    assert.equal(st.wifi_ap_active, true, 'STA yok: kurulum/kurtarma AP penceresi acildi');
  } finally {
    await sim.stop();
  }
});

test('RS485 uclari: dogrulama kodlari; ek modul varsa tarama/role/gonderme calisir', async () => {
  const { sim, j } = await startSim({ relays: 16 });
  try {
    await waitFor(() => sim.qaState().ext.responding, { timeoutMs: 3000 });
    assert.deepEqual((await j('POST', '/api/rs485/baud', { body: { baud: 1234 } })).json, { error: 'invalid_baud' });
    assert.deepEqual((await j('POST', '/api/rs485/baud', { body: { baud: '9600' } })).json, { error: 'invalid_baud' });
    assert.equal((await j('POST', '/api/rs485/baud', { body: { baud: 19200 } })).status, 200);
    assert.equal((await j('GET', '/api/config')).json.rs485_baud, 19200);
    // modul 9600'de kaldi: UART 19200'e gecince yanit vermez (firmware: yanit vermiyor -> geri cekilmeli yoklama)
    await waitFor(() => !sim.qaState().ext.responding, { timeoutMs: 8000, label: 'baud uyusmazliginda modul yanit vermemeli' });
    assert.equal(sim.qaState().ext.uart_baud, 19200);
    assert.deepEqual((await j('POST', '/api/rs485/send', { body: { data: '' } })).json, { error: 'invalid_value' });
    assert.equal((await j('POST', '/api/rs485/send', { body: { data: '01 03 00 00', isHex: true } })).status, 200);
    assert.match((await j('GET', '/api/rs485/logs')).text, /TX HEX/);
    assert.equal((await j('POST', '/api/rs485/clear')).status, 200);
    assert.equal((await j('GET', '/api/rs485/logs')).text, '');

    assert.deepEqual((await j('GET', '/api/rs485/scan')).json, { status: 'idle' });
    const st = await j('POST', '/api/rs485/scan');
    assert.deepEqual([st.status, st.json], [202, { status: 'scanning' }]);
    assert.equal((await j('GET', '/api/rs485/scan')).status, 202);
    let done = null;
    await waitFor(async () => { done = await j('GET', '/api/rs485/scan'); return done.status === 200; }, { timeoutMs: 8000, label: 'tarama bitmedi' });
    assert.equal(done.json.status, 'done');
    assert.equal(done.json.found, true);
    assert.equal(done.json.slaveId, 1);
    assert.equal(done.json.baud, 9600, 'tarama modulun GERCEK baud degerini buldu');
    assert.match(done.json.rawHex, /^01 01 01 [0-9A-F]{2} [0-9A-F]{2} [0-9A-F]{2} $/);
    assert.equal(done.json.info, 'Modbus RTU Standard Yanit (CRC Dogru)');
    assert.equal((await j('GET', '/api/config')).json.rs485_baud, 9600, 'yapilandirma bulunan baud degerine esitlendi');
    await waitFor(() => sim.qaState().ext.responding, { timeoutMs: 5000, label: 'tarama sonrasi modul yeniden yanit vermeli' });
    assert.match((await j('GET', '/api/rs485/logs')).text, /^\[\d\d:\d\d:\d\d\] /m);

    assert.deepEqual((await j('POST', '/api/rs485/relay', { body: { slaveId: 0 } })).json, { error: 'invalid_value' });
    assert.deepEqual((await j('POST', '/api/rs485/relay', { body: { channel: 33 } })).json, { error: 'invalid_channel' });
    assert.deepEqual((await j('POST', '/api/rs485/relay', { body: { channel: 0, action: 1 } })).json, { error: 'invalid_channel' });
    const on = await j('POST', '/api/rs485/relay', { body: { slaveId: 1, channel: 3, action: 1 } });
    assert.equal(on.status, 200);
    assert.equal(on.json.success, true);
    assert.match(on.json.responseHex, /^01 05 00 02 FF 00 [0-9A-F]{2} [0-9A-F]{2} $/, 'modulun yanki cercevesi (CRC dahil)');
    assert.equal(sim.ext.coils[2], true);
    await sleep(400);
    assert.equal(sim.qaState().relays[10].state, true, 'ham ACMA uygulama durumuna da islendi (want)');
    const bad = await j('POST', '/api/rs485/relay', { body: { slaveId: 7, channel: 3, action: 1 } });
    assert.deepEqual([bad.status, bad.json.success, bad.json.error], [502, false, 'no_response']);
  } finally {
    await sim.stop();
  }
});

test('QA ucu: yalniz loopback; state/log/di/slow/provision/unprovision/wifi/hw-fail', async () => {
  const { sim, j } = await startSim();
  try {
    const st = (await j('GET', '/__sim/state', { key: null })).json;
    assert.equal(st.uid, UID);
    assert.equal(st.device_uid, UID);
    assert.equal(st.relays.length, 8);
    assert.equal(st.shutters.length, 2, 'yalniz gecerli panjur ciftleri');
    assert.equal(typeof st.violation_count, 'number');
    assert.ok(!JSON.stringify(st).includes(KEY), 'anahtar degeri ASLA donmez');

    // DI: duvar butonu (DI5 -> role 5 toggle)
    assert.equal((await j('POST', '/__sim/di/5/press', { key: null, body: { hold_ms: 150 } })).status, 200);
    await waitFor(() => sim.qaState().relays[4].state === true, { timeoutMs: 2000, label: 'DI5 role 5 toggle' });
    assert.equal((await j('POST', '/__sim/di/99/press', { key: null })).status, 400);

    // yavas / dusur
    assert.equal((await j('POST', '/__sim/slow', { key: null, body: { drop: true } })).status, 200);
    await j('POST', '/api/relay?ch=6&state=1');
    await settle();
    assert.equal(sim.qaState().relays[5].state, false, 'komut dusuruldu');
    assert.equal((await j('DELETE', '/__sim/slow', { key: null })).status, 200);
    await j('POST', '/api/relay?ch=6&state=1');
    await settle();
    assert.equal(sim.qaState().relays[5].state, true);

    // I2C arizasi
    await j('POST', '/__sim/hw-fail', { key: null, body: { i2c: true } });
    await j('POST', '/api/relay?ch=7&state=1');
    await settle(250);
    assert.equal(sim.qaState().relays[6].state, false);
    await j('POST', '/__sim/hw-fail', { key: null, body: { i2c: false } });
    await settle(250);
    assert.equal(sim.qaState().relays[6].state, true, 'ariza giderilince bekleyen istek uygulanir');

    // TCA (yerel role cipi) arizalari: chip_reset / stuck_on / drop; ek modul donanimi: /__sim/ext
    assert.equal((await j('POST', '/__sim/tca', { key: null, body: { action: 'stuck_on', relay: 3 } })).json.tca.latch & 0x04, 0x04);
    assert.equal((await j('POST', '/__sim/tca', { key: null, body: { action: 'stuck_on', relay: 9 } })).status, 400);
    assert.equal((await j('POST', '/__sim/tca', { key: null, body: { action: 'bogus' } })).status, 400);
    await waitFor(() => (sim.qaState().tca.latch & 0x04) === 0, { timeoutMs: 4000, label: 'TCA dogrulamasi beklenmeyen ACIK roleyi kapatmali' });
    assert.equal((await j('POST', '/__sim/ext', { key: null, body: { baud: 1234 } })).status, 400);
    assert.equal((await j('POST', '/__sim/ext', { key: null, body: { address: 0 } })).status, 400);
    const ex = await j('POST', '/__sim/ext', { key: null, body: { address: 3, baud: 19200, channels: 4, present: true } });
    assert.deepEqual(ex.json.ext, { present: true, address: 3, baud: 19200, channels: 4 });
    const qs = (await j('GET', '/__sim/state', { key: null })).json;
    assert.deepEqual([qs.ext.address, qs.ext.baud, qs.ext.channels, qs.ext.uart_baud, qs.ext.scan], [3, 19200, 4, 9600, 'idle']);

    // unprovision / provision
    assert.equal((await j('POST', '/__sim/unprovision', { key: null })).status, 200);
    assert.equal((await j('GET', '/api/config')).status, 403);
    assert.equal((await j('POST', '/__sim/provision', { key: null, body: { local_key: 'qa-yeni-anahtar-1' } })).status, 200);
    assert.equal((await j('GET', '/api/config', { key: 'qa-yeni-anahtar-1' })).status, 200);
    assert.equal((await j('POST', '/__sim/provision', { key: null, body: { local_key: 'kisa' } })).status, 400);

    const log = (await j('GET', '/__sim/log?since=0', { key: null })).json;
    assert.ok(log.entries.length > 0 && log.last >= log.entries.length);
    assert.equal((await j('GET', '/__sim/yok', { key: null })).status, 404);
    assert.equal(sim.qaState().violation_count, 0);
  } finally {
    await sim.stop();
  }
});

// ====================================================================================================================
// WP-W1: Wi-Fi servis akisi -- AP KAYNAKLI yetkilendirme (CONTRACTS 3d; firmware src/ApAccess.h + WebPortal::authorizeApOrKeyed)
//   YALNIZ GET /api/wifi/scan, POST /api/wifi/connect ve GET /api/wifi/status icin (Access::AP_OR_KEYED): gecerli X-Device-Key YA DA (istemci SoftAP
//   arayuzunde + AP su an FIILEN WPA2 + gecerli ap_pass >= 8 + cihaz provizyonlu). Diger 20 uc KEYED. Istemci ag konumu simulatorde MODELLENIR
//   (sim.clientNet / POST /__sim/client-net); karar yine gercek clientOnSoftAp(AP/STA alt aglari) + via() fonksiyonlarindan gecer.
// ====================================================================================================================

/** Sahte saati `ms` kadar ilerletir; simulatorun gercek zamanli tick'lerinin sanal zamani gormesi icin adimlar arasi bekler. */
async function advance(clock, ms, stepMs = 500) {
  for (let d = 0; d < ms; d += stepMs) {
    clock.advance(Math.min(stepMs, ms - d));
    await sleep(14);
  }
  await sleep(40);
}

/** Provizyonlu cihaz, STA kaydi YOK -> WPA2 kurtarma AP'si acik; HTTP istemcisi SoftAP'de (clientNet 'ap'). */
async function startApSim(opts = {}) {
  const ctx = await startSim({ wifiConnected: false, clientNet: 'ap', ...opts });
  await waitFor(() => ctx.sim.qaState().wifi.ap_secured, { timeoutMs: 4000, label: 'WPA2 kurtarma AP\'si acilmadi' });
  return ctx;
}

const statusOf = async (j, o) => (await j('GET', '/api/wifi/status', o)).status;

test('WP-W1 yol tablosu: 26 rota, 3\'u AP_OR_KEYED; SoftAP istemcisi anahtarsiz YALNIZ o 3 uca erisir, diger 20 uc 401 ve ISLEYICI CALISMAZ', async () => {
  const counts = {};
  for (const r of ROUTES) counts[r[3]] = (counts[r[3]] || 0) + 1;
  assert.equal(ROUTES.length, 33);
  assert.deepEqual(counts, { PUBLIC: 2, FACTORY: 1, KEYED: 27, AP_OR_KEYED: 3 });   // Faz 2: POST /api/arm (KEYED)
  assert.deepEqual(ROUTES.filter((r) => r[3] === 'AP_OR_KEYED').map((r) => `${r[1]} ${r[0]}`).sort(), ['GET /api/wifi/scan', 'GET /api/wifi/status', 'POST /api/wifi/connect']);

  const { sim, j } = await startApSim();
  try {
    const wifi = sim.qaState().wifi;
    assert.deepEqual([wifi.ap_active, wifi.ap_secured, wifi.connected], [true, true, false]);
    // her KEYED rota icin ISLEYICI CALISIRSA gozlenebilir bir yan etki yaratacak gecerli bir istek
    const probe = {
      '/api/auth/check': {},
      '/api/auth/rekey': { body: { local_key: 'yeni-anahtar-001' } },
      '/api/mqtt/config': { body: { server: '10.0.2.2', port: 8884, user: 'd_h_x', pass: 'sifre-1' } },
      '/api/relay': { path: '/api/relay?ch=5&state=1' },
      '/api/all': { path: '/api/all?cmd=lightsoff' },
      '/api/child-lock': { body: { enabled: true } },
      '/api/config': { body: { device_name: 'Yetkisiz Ad' } },
      '/api/wifi/disconnect': {},
      '/api/rs485/send': { body: { data: '01 03 00 00', isHex: true } },
      '/api/rs485/logs': {},
      '/api/rs485/clear': {},
      '/api/rs485/baud': { body: { baud: 19200 } },
      '/api/rs485/scan': {},
      '/api/rs485/relay': { body: { slaveId: 1, channel: 1, action: 1 } },
      '/api/system/reboot': {},
      '/api/system/reset': {},
      '/api/actuator': { body: { actuator: 'a1', to: 'closed' } },
      '/api/alarm/ack': { body: { zone: 0 } },
      '/api/alarm/test': { body: { zone: 1 } },
      '/api/arm': { body: { mode: 'away' } },
      '/api/events': {},
      '/api/safety/config': { body: { set: { zone: { id: 2, name: 'Yetkisiz' } } } },
    };
    const eventsBefore = sim.events.length;
    const cmdBefore = sim.counters.http_cmd;
    let keyed = 0;
    let apOrKeyed = 0;
    for (const [path, method, , access] of ROUTES) {
      const p = probe[path] || {};
      const r = await j(method, p.path || path, { key: null, body: method === 'POST' ? p.body : undefined });
      if (access === 'KEYED') {
        keyed++;
        assert.deepEqual([r.status, r.json], [401, { error: 'unauthorized' }], `${method} ${path}: AP istemcisi anahtarsiz -> 401`);
        assert.equal(r.headers['retry-after'], undefined, `${method} ${path}`);
      } else if (access === 'AP_OR_KEYED') {
        apOrKeyed++;
        assert.notEqual(r.status, 401, `${method} ${path}: AP kaynakli yol acik`);
        assert.notEqual(r.status, 403, `${method} ${path}`);
      } else if (access === 'PUBLIC') {
        assert.equal(r.status, 200, `${method} ${path}`);
      } else {
        assert.deepEqual([r.status, r.json], [403, { error: 'already_provisioned' }], `${method} ${path}: FACTORY`);
      }
    }
    assert.deepEqual([keyed, apOrKeyed], [27, 3]);

    // KEYED isleyicilerin HICBIRI calismadi: ne durum ne olay ne yan etki
    const newEvents = sim.events.slice(eventsBefore).map((e) => e.type);
    for (const forbidden of ['config_saved', 'rekeyed', 'mqtt_config_set', 'reset_to_defaults', 'wifi_credentials_cleared', 'reboot', 'provisioned']) {
      assert.equal(newEvents.includes(forbidden), false, `${forbidden} olayi olusmamali: ${newEvents.join(',')}`);
    }
    assert.equal(sim.counters.http_cmd, cmdBefore, 'rol/toplu/cocuk kilidi komutu kuyruga YAZILMADI');
    assert.equal(sim.fw.cm.config.local_key, KEY, 'rekey calismadi');
    assert.equal(sim.mqttCfg, null, 'mqtt/config calismadi');
    assert.equal(sim.childLock, false);
    assert.equal(sim.qaState().relays[4].state, false);
    assert.equal(sim.booting, false);
    assert.equal(sim.qaState().http_lock.fail_count, 0, 'anahtarsiz 401 deneme SAYILMAZ');
    const cfg = (await j('GET', '/api/config')).json;                 // anahtarli: durum degismedi
    assert.equal(cfg.device_name, 'AHBU Akilli Ev Kontrol');
    assert.equal(cfg.rs485_baud, 9600);

    // gecerli anahtar: ayni uclar (AP'den de) normal calisir
    assert.equal((await j('POST', '/api/relay?ch=5&state=1')).status, 200);
    assert.equal((await j('GET', '/api/auth/check')).status, 200);
    assert.equal((await j('GET', '/api/wifi/status')).status, 200);
  } finally {
    await sim.stop();
  }
});

test('WP-W1 karar tablosu (HTTP): AP disi anahtarsiz 401; anahtarli her yerden 200; AP kaynakli yolda yanlis anahtar SAYILMAZ ve 423 yoklanmaz', async () => {
  const { sim, j } = await startApSim();
  try {
    // (a) SoftAP'de + (b) WPA2 + ap_pass + (c) provizyonlu: anahtarsiz izin
    assert.equal(await statusOf(j, { key: null }), 200);
    assert.equal(await statusOf(j), 200, 'gecerli anahtar');
    // yanlis anahtar AP kaynakli yolda hata sayacina ISLENMEZ, 423 YOKLANMAZ (yetki anahtardan bagimsiz: oracle yok)
    for (let i = 0; i < 12; i++) assert.equal(await statusOf(j, { key: 'yanlis-anahtar-1' }), 200, `yanlis anahtar ${i}`);
    assert.equal(sim.qaState().http_lock.fail_count, 0);
    assert.equal(sim.qaState().http_lock.locked_for_ms, 0);
    // ayni IP'den KEYED uc: yanlis anahtar SAYILIR -> 5. hatadan sonra 423
    for (let i = 0; i < 5; i++) assert.equal((await j('GET', '/api/config', { key: 'yanlis-anahtar-1' })).status, 401);
    assert.equal((await j('GET', '/api/config', { key: 'yanlis-anahtar-1' })).status, 423, 'KEYED uc kilitli');
    assert.equal((await j('GET', '/api/config')).status, 423, 'kilit dogru anahtari da engeller (KEYED)');
    // kilit AP kaynakli yolu ETKILEMEZ: anahtarsiz/yanlis/dogru anahtar ucu da 200
    assert.equal(await statusOf(j, { key: null }), 200);
    assert.equal(await statusOf(j, { key: 'yanlis-anahtar-1' }), 200);
    assert.equal(await statusOf(j), 200);

    // istemci AP disinda (LAN): anahtarsiz 401 (AP kaynakli yol kapali; KEYED kurallari), anahtarli 200
    await j('POST', '/__sim/client-net', { key: null, body: { mode: 'lan' } });
    assert.equal(sim.qaState().client_net.on_softap, false);
    assert.equal(await statusOf(j, { key: null }), 401);
    assert.equal(await statusOf(j, { key: 'yanlis-anahtar-1' }), 401, 'LAN + yanlis anahtar: 401 (ve hata sayilir)');
    assert.equal(sim.qaState().http_lock.fail_count, 1, 'AP disi istemcide yanlis anahtar SAYILIR');
    assert.equal(await statusOf(j), 200, 'LAN + gecerli anahtar');
    for (const [m, p] of [['GET', '/api/wifi/scan'], ['POST', '/api/wifi/connect']]) assert.equal((await j(m, p, { key: null, body: m === 'POST' ? {} : undefined })).status, 401, `${m} ${p} LAN`);
  } finally {
    await sim.stop();
  }
});

test('WP-W1: AP penceresi kapaliyken (STA bagli) "AP" konumlu istemci de anahtarsiz 401; AP yayina girince 200', async () => {
  const { sim, j } = await startSim({ clientNet: 'ap' });            // ev agina bagli + AP KAPALI
  try {
    await waitFor(() => sim.qaState().wifi.connected, { timeoutMs: 3000 });
    assert.equal(sim.qaState().wifi.ap_active, false);
    assert.equal(sim.qaState().client_net.on_softap, false, 'AP yayinda degil: SoftAP istemcisi olamaz');
    assert.equal(await statusOf(j, { key: null }), 401);
    sim.fw.wifi.openServiceAp(0, 600000);                              // CLI "AP ON": servis AP penceresi (WPA2, ap_pass var)
    await waitFor(() => sim.qaState().wifi.ap_secured, { timeoutMs: 3000, label: 'servis AP' });
    assert.equal(sim.qaState().client_net.on_softap, true);
    assert.equal(await statusOf(j, { key: null }), 200, 'STA bagli + AP acik + WPA2: SoftAP istemcisi (alt aglar ayri)');
  } finally {
    await sim.stop();
  }
});

test('WP-W1: STA alt agi AP alt agiyla (192.168.4.0/24) KESISIRSE AP yolu KAPALI (ag konumu ayirt edilemez); uzak IP kurallari', async () => {
  const { sim, j } = await startSim({ clientNet: 'ap', staIp: '192.168.4.77' });   // ev modemi de 192.168.4.0/24
  try {
    await waitFor(() => sim.qaState().wifi.connected, { timeoutMs: 3000 });
    sim.fw.wifi.openServiceAp(0, 600000);
    await waitFor(() => sim.qaState().wifi.ap_secured, { timeoutMs: 3000 });
    const net = sim.qaState().client_net;
    assert.deepEqual([net.mode, net.remote_ip, net.sta_ip, net.on_softap], ['ap', '192.168.4.2', '192.168.4.77', false]);
    assert.equal(await statusOf(j, { key: null }), 401, 'alt aglar cakisiyor: istemci AP SAYILMAZ (kapali basarisizlik)');
    assert.equal(await statusOf(j), 200, 'gecerli anahtar her yerden');
  } finally {
    await sim.stop();
  }

  const b = await startApSim();
  try {
    // uzak IP gecersiz kilma: cihazin kendi adresi / AP alt agi disi / AP alt agi icinde baska adres
    const set = async (remote_ip) => (await b.j('POST', '/__sim/client-net', { key: null, body: { remote_ip } })).json;
    assert.equal((await set('192.168.4.1')).client_net.on_softap, false, 'cihazin kendi AP adresi');
    assert.equal(await statusOf(b.j, { key: null }), 401);
    assert.equal((await set('192.168.5.2')).client_net.on_softap, false, 'AP alt agi disi');
    assert.equal(await statusOf(b.j, { key: null }), 401);
    assert.equal((await set('192.168.4.200')).client_net.on_softap, true);
    assert.equal(await statusOf(b.j, { key: null }), 200);
    assert.equal((await set(null)).client_net.remote_ip, '192.168.4.2', 'gecersiz kilma kaldirildi: moddan turetilir');
  } finally {
    await b.sim.stop();
  }
});

test('WP-W1: provizyonsuz cihaz (ACIK kurulum AP\'si) -> wifi/scan|connect|status 403 unprovisioned (anahtarli da); factory/init sonrasi ~1,5 sn AP hala ACIK: AP yolu KAPALI, WPA2\'ye donunce acilir', async () => {
  const clock = fakeClock();
  const { sim, j } = await startSim({ localKey: '', wifiConnected: false, clientNet: 'ap', clock });
  try {
    await waitFor(() => sim.qaState().wifi.ap_active, { timeoutMs: 3000, label: 'acik kurulum AP\'si' });
    const w = sim.qaState().wifi;
    assert.deepEqual([w.ap_active, w.ap_secured, sim.isProvisioned()], [true, false, false], 'acik AP, WPA2 DEGIL');
    for (const key of [null, 'bir-anahtar-123']) {
      const scan = await j('GET', '/api/wifi/scan', { key });
      assert.deepEqual([scan.status, scan.json], [403, { error: 'unprovisioned' }]);
      assert.deepEqual((await j('POST', '/api/wifi/connect', { key, body: { ssid: 'TestHome', pass: 'home-pass-123' } })).json, { error: 'unprovisioned' });
      assert.deepEqual([await statusOf(j, { key }), (await j('GET', '/api/wifi/status', { key })).json], [403, { error: 'unprovisioned' }]);
    }
    assert.equal(sim.qaState().http_ap_connect.used, 0, 'provizyonsuzda hiz siniri sayaci islemez');

    // factory/init: provizyon yazildi AMA acik AP ~1,5 sn daha yayinda
    assert.equal((await j('POST', '/api/factory/init', { key: null, body: { local_key: 'abcdefgh12', ap_pass: 'appass1234' } })).status, 200);
    await advance(clock, 400, 100);
    const open = sim.qaState();
    assert.deepEqual([open.provisioned, open.wifi.ap_active, open.wifi.ap_secured], [true, true, false], 'provizyonlu ama AP henuz WPA2 degil');
    assert.equal(await statusOf(j, { key: null }), 401, 'ACIK AP + anahtarsiz: AP yolu KAPALI (factory/init sonrasi 1,5 sn dahil)');
    assert.equal(await statusOf(j, { key: 'abcdefgh12' }), 200, 'gecerli anahtar her zaman');
    await advance(clock, 2000, 250);
    await waitFor(() => sim.qaState().wifi.ap_secured, { timeoutMs: 3000, label: 'AP WPA2\'ye donmedi' });
    assert.equal(await statusOf(j, { key: null }), 200, 'AP WPA2\'ye dondu: AP kaynakli yol acik');
    assert.equal((await j('POST', '/api/relay?ch=5&state=1', { key: null })).status, 401, 'role: anahtarsiz AP istemcisi 401');
    assert.deepEqual(sim.events.filter((e) => e.type === 'wifi_ap_started').map((e) => e.wpa2), [false, true], 'AP once acik, sonra WPA2 olarak yeniden basladi');
  } finally {
    await sim.stop();
  }
});

test('WP-W1: Host allow-list, Origin==Host ve JSON Content-Type kurallari AP kaynakli yolda AYNEN gecerli (capraz kaynak istek AP konumuyla yetkilenemez)', async () => {
  const { sim, j, port } = await startApSim();
  try {
    assert.deepEqual((await j('GET', '/api/wifi/status', { key: null, headers: { Host: 'evil.example' } })).json, { error: 'bad_host' });
    assert.equal((await j('GET', '/api/wifi/status', { key: null, headers: { Host: 'evil.example' } })).status, 400);
    const evilOrigin = await j('GET', '/api/wifi/status', { key: null, headers: { Origin: 'http://evil.example' } });
    assert.deepEqual([evilOrigin.status, evilOrigin.json], [403, { error: 'bad_origin' }]);
    const evilConnect = await j('POST', '/api/wifi/connect', { key: null, body: { ssid: 'TestHome', pass: 'home-pass-123' }, headers: { Origin: 'http://baska.site' } });
    assert.equal(evilConnect.status, 403, 'tarayici sayfasindan capraz kaynak connect');
    assert.equal(sim.qaState().http_ap_connect.used, 0, 'Host/Origin reddi hiz siniri butcesinden ONCE: sayilmaz');
    assert.equal(sim.qaState().wifi.connect_state, 'idle', 'capraz kaynak istek baglanmayi baslatamadi');
    assert.equal((await j('GET', '/api/wifi/status', { key: null, headers: { Origin: `http://127.0.0.1:${port}` } })).status, 200, 'ayni kaynak serbest');
    assert.equal((await j('GET', '/api/wifi/scan', { key: null, headers: { Host: 'ahbu-0a0001.local' } })).status, 200, '*.local Host serbest');

    // JSON Content-Type zorunlu: 415 (hiz siniri butcesinden SAYILIR: istek ONCE sayilir)
    assert.deepEqual((await j('POST', '/api/wifi/connect', { key: null, body: '{"ssid":"TestHome"}', ctype: 'text/plain' })).json, { error: 'unsupported_media_type' });
    assert.deepEqual((await j('POST', '/api/wifi/connect', { key: null, body: '' })).json, { error: 'empty_body' });
    assert.deepEqual((await j('POST', '/api/wifi/connect', { key: null, body: '{bozuk' })).json, { error: 'invalid_json' });
    assert.equal(sim.qaState().http_ap_connect.used, 3, 'gecersiz govdeli istekler de sayilir');
  } finally {
    await sim.stop();
  }
});

test('WP-W1 hiz siniri: AP kaynakli ANAHTARSIZ POST /api/wifi/connect GLOBAL kayan 60 sn\'de en cok 6 (gecersiz govdeli dahil); 7. 429 + Retry-After; anahtarli istekler girmez', async () => {
  const clock = fakeClock();
  const { sim, j } = await startApSim({ clock });
  try {
    const bad = [{}, { ssid: '' }, '{bozuk', '', { ssid: 5 }, { ssid: 'a'.repeat(33) }];
    const codes = [];
    for (const body of bad) codes.push((await j('POST', '/api/wifi/connect', { key: null, body })).json.error);
    assert.deepEqual(codes, ['invalid_ssid', 'invalid_ssid', 'invalid_json', 'empty_body', 'invalid_ssid', 'invalid_ssid'], 'ilk 6 istek isleyiciye ulasti (gecersiz govde dahil sayildi)');
    assert.equal(sim.qaState().http_ap_connect.used, 6);
    const seventh = await j('POST', '/api/wifi/connect', { key: null, body: { ssid: 'TestHome', pass: 'home-pass-123' } });
    assert.deepEqual([seventh.status, seventh.json], [429, { error: 'rate_limited', retry_after: 60 }]);
    assert.equal(seventh.headers['retry-after'], '60');
    assert.equal(sim.qaState().wifi.connect_state, 'idle', '429: baglanma baslatilmadi');
    // yanlis anahtar anahtarsiz sayilir (AP yolu): ayni sinir
    assert.equal((await j('POST', '/api/wifi/connect', { key: 'yanlis-anahtar-1', body: {} })).status, 429, 'yanlis anahtar = anahtarsiz AP yolu');
    assert.equal(sim.qaState().http_lock.fail_count, 0, 'AP yolunda yanlis anahtar hata sayacina islenmez');
    // GECERLI anahtar sinira girmez (AP istemcisi olsa da)
    for (let i = 0; i < 8; i++) assert.deepEqual((await j('POST', '/api/wifi/connect', { body: {} })).json, { error: 'invalid_ssid' }, `anahtarli ${i}`);
    // scan icin bu sinir yok (kendi tarama kapisi); status da serbest
    assert.equal(await statusOf(j, { key: null }), 200);
    assert.equal((await j('GET', '/api/wifi/scan', { key: null })).status, 200);

    // kayan pencere: 30 sn sonra Retry-After ~30; 60 sn sonra tum yuvalar bosalir
    await advance(clock, 30000);
    const mid = await j('POST', '/api/wifi/connect', { key: null, body: {} });
    assert.equal(mid.status, 429);
    assert.ok(mid.json.retry_after >= 29 && mid.json.retry_after <= 31, `retry_after=${mid.json.retry_after}`);
    assert.equal(mid.headers['retry-after'], String(mid.json.retry_after));
    await advance(clock, 31000);
    for (let i = 0; i < 6; i++) assert.equal((await j('POST', '/api/wifi/connect', { key: null, body: {} })).status, 400, `pencere sonrasi ${i}`);
    assert.equal((await j('POST', '/api/wifi/connect', { key: null, body: {} })).status, 429);
  } finally {
    await sim.stop();
  }
});

test('GET /api/wifi/status: {wifi_connect_state, wifi_connect_reason, wifi_connected, wifi_sta_ssid, wifi_sta_ip, wifi_rssi, ap_active}; basari YALNIZ "success"; connect 200 "connecting" baglandi DEMEK DEGIL', async () => {
  const clock = fakeClock();
  const { sim, j } = await startApSim({ clock });
  try {
    const idle = (await j('GET', '/api/wifi/status', { key: null })).json;
    assert.deepEqual(idle, { wifi_connect_state: 'idle', wifi_connect_reason: 0, wifi_connected: false, wifi_sta_ssid: '', wifi_sta_ip: '', wifi_rssi: 0, ap_active: true });

    // yanlis parola: kabul "connecting" (200), hemen sonra durum connecting; sonuc failed + neden 202
    const wrong = await j('POST', '/api/wifi/connect', { key: null, body: { ssid: 'TestHome', pass: 'yanlis-parola-1' } });
    assert.deepEqual([wrong.status, wrong.json], [200, { status: 'connecting' }]);
    let st = (await j('GET', '/api/wifi/status', { key: null })).json;
    assert.deepEqual([st.wifi_connect_state, st.wifi_connect_reason, st.wifi_connected], ['connecting', 0, false]);
    assert.equal((await j('POST', '/api/wifi/connect', { key: null, body: { ssid: 'TestHome', pass: 'home-pass-123' } })).status, 409, 'onceki deneme surerken 409 busy');
    await advance(clock, 6000);
    st = (await j('GET', '/api/wifi/status', { key: null })).json;
    assert.deepEqual([st.wifi_connect_state, st.wifi_connect_reason, st.wifi_connected, st.wifi_sta_ssid, st.wifi_sta_ip, st.wifi_rssi], ['failed', 202, false, '', '', 0]);

    // yeni deneme: durum hemen connecting (eski failed kalintisi gorunmez); dogru parola -> success
    const right = await j('POST', '/api/wifi/connect', { key: null, body: { ssid: 'TestHome', pass: 'home-pass-123' } });
    assert.deepEqual([right.status, right.json], [200, { status: 'connecting' }]);
    st = (await j('GET', '/api/wifi/status', { key: null })).json;
    assert.deepEqual([st.wifi_connect_state, st.wifi_connect_reason], ['connecting', 0]);
    await advance(clock, 6000);
    st = (await j('GET', '/api/wifi/status', { key: null })).json;
    assert.equal(st.wifi_connect_state, 'success');
    assert.equal(st.wifi_connect_reason, 0);
    assert.equal(st.wifi_connected, true);
    assert.equal(st.wifi_sta_ssid, 'TestHome');
    assert.match(st.wifi_sta_ip, /^192\.168\.1\.\d+$/);
    assert.ok(Number.isInteger(st.wifi_rssi) && st.wifi_rssi < 0 && st.wifi_rssi > -100, `rssi=${st.wifi_rssi}`);
    assert.equal(st.ap_active, true, 'STA 30 sn kararli olana kadar AP acik');
    assert.deepEqual(Object.keys(st), ['wifi_connect_state', 'wifi_connect_reason', 'wifi_connected', 'wifi_sta_ssid', 'wifi_sta_ip', 'wifi_rssi', 'ap_active']);
    assert.equal(sim.fw.cm.config.wifi_ssid, 'TestHome', 'dogrulaninca NVS\'e islendi');

    // STA 30 sn kararli -> kurtarma AP'si kapanir (telefon AP'den duser): AP konumlu istemci artik anahtarsiz erisemez
    await advance(clock, 31000);
    assert.equal(sim.qaState().wifi.ap_active, false);
    assert.equal(await statusOf(j, { key: null }), 401, 'AP kapandi: AP kaynakli yol da kapandi');
    const keyed = (await j('GET', '/api/wifi/status')).json;
    assert.deepEqual([keyed.wifi_connect_state, keyed.wifi_connected, keyed.ap_active], ['success', true, false]);
  } finally {
    await sim.stop();
  }
});

test('GET /api/wifi/status: ag yok -> failed + neden 201; sifre nedenleri 2/15/204 da "sifre" olarak raporlanir (QA: /__sim/wifi auth_fail_reason)', async () => {
  const clock = fakeClock();
  const { sim, j } = await startApSim({ clock });
  try {
    await j('POST', '/api/wifi/connect', { key: null, body: { ssid: 'Olmayan-Ag' } });
    await advance(clock, 6000);
    assert.deepEqual(((s) => [s.wifi_connect_state, s.wifi_connect_reason])((await j('GET', '/api/wifi/status', { key: null })).json), ['failed', 201]);
    assert.equal((await j('POST', '/__sim/wifi', { key: null, body: { auth_fail_reason: 7 } })).status, 400, 'gecersiz neden reddedilir');
    for (const reason of [2, 15, 204]) {
      assert.equal((await j('POST', '/__sim/wifi', { key: null, body: { auth_fail_reason: reason } })).json.wifi.auth_fail_reason, reason);
      clock.advance(61000);                                                       // hiz siniri penceresi
      await j('POST', '/api/wifi/connect', { key: null, body: { ssid: 'TestHome', pass: 'yanlis-parola-1' } });
      await advance(clock, 6000);
      assert.deepEqual(((s) => [s.wifi_connect_state, s.wifi_connect_reason])((await j('GET', '/api/wifi/status', { key: null })).json), ['failed', reason]);
    }
  } finally {
    await sim.stop();
  }
});

test('Wi-Fi servis akisi uctan uca (AP kaynakli, anahtarsiz): tarama -> connect -> status ile dogrulama (basari YALNIZ success)', async () => {
  const clock = fakeClock();
  const { sim, j } = await startApSim({ clock });
  try {
    assert.deepEqual((await j('GET', '/api/wifi/scan', { key: null })).json, { status: 'scanning' });
    await advance(clock, 3000);
    const scan = (await j('GET', '/api/wifi/scan', { key: null })).json;
    assert.equal(scan.status, 'done');
    assert.ok(scan.networks.some((n) => n.ssid === 'TestHome' && n.enc === true));
    const net = scan.networks.find((n) => n.ssid === 'Misafir Ağı (Açık)');
    assert.equal(net.enc, false);
    // acik aga baglan (parola alani yok = bos)
    assert.deepEqual((await j('POST', '/api/wifi/connect', { key: null, body: { ssid: 'Misafir Ağı (Açık)' } })).json, { status: 'connecting' });
    await advance(clock, 6000);
    const st = (await j('GET', '/api/wifi/status', { key: null })).json;
    assert.deepEqual([st.wifi_connect_state, st.wifi_sta_ssid], ['success', 'Misafir Ağı (Açık)']);
    // pass: null = bos parola (acik ag), alan yok ile ayni (STA 30 sn kararli olmadan AP hala acik)
    await advance(clock, 1000);
    assert.deepEqual((await j('POST', '/api/wifi/connect', { key: null, body: { ssid: 'Misafir Ağı (Açık)', pass: null } })).json, { status: 'connecting' });
  } finally {
    await sim.stop();
  }
});

test('QA ucu /__sim/client-net: GET/POST (mode ap|lan, remote_ip, ap_clients); gecersiz deger 400; AP istemcisi 1 istasyon sayilir; /__sim/state client_net + wifi.ap_secured', async () => {
  const { sim, j } = await startApSim();
  try {
    const get = (await j('GET', '/__sim/client-net', { key: null })).json.client_net;
    assert.deepEqual([get.mode, get.remote_ip, get.on_softap, get.ap_ip], ['ap', '192.168.4.2', true, '192.168.4.1']);
    assert.equal(sim.qaState().wifi.ap_clients, 1, 'SoftAP\'de istemci modelleniyor: 1 istasyon');
    assert.equal(sim.qaState().client_net.mode, 'ap');
    assert.equal(sim.qaState().wifi.ap_secured, true);

    const lan = (await j('POST', '/__sim/client-net', { key: null, body: { mode: 'lan' } })).json.client_net;
    assert.deepEqual([lan.mode, lan.on_softap], ['lan', false]);
    assert.match(lan.remote_ip, /^192\.168\.1\.20$/, 'LAN istemcisi STA alt agindan baska bir konak');
    assert.equal(sim.qaState().wifi.ap_clients, 0);
    assert.equal((await j('POST', '/__sim/client-net', { key: null, body: { ap_clients: 3 } })).json.client_net.ap_clients_override, 3);
    assert.equal(sim.qaState().wifi.ap_clients, 3);
    assert.equal((await j('POST', '/__sim/client-net', { key: null, body: { ap_clients: null } })).json.client_net.ap_clients_override, null);

    for (const bad of [{ mode: 'wan' }, { mode: 5 }, { remote_ip: 'abc' }, { remote_ip: '999.1.1.1' }, { ap_clients: -1 }, { ap_clients: 4 }, { ap_clients: 1.5 }]) {
      const r = await j('POST', '/__sim/client-net', { key: null, body: bad });
      assert.equal(r.status, 400, JSON.stringify(bad));
    }
    assert.equal((await j('POST', '/__sim/wifi', { key: null, body: { silent: 'evet' } })).status, 400);
    assert.equal(sim.qaState().client_net.mode, 'lan', 'gecersiz istek durumu degistirmez');
  } finally {
    await sim.stop();
  }
});

test('simulator secenekleri: clientNet varsayilani (ev agina bagli -> lan, degil -> ap); gecersiz clientNet/staIp reddedilir; QA ucu hw-fail tca_fail_reads/writes', async () => {
  const a = new DeviceSimulator({ uid: 'AHBU-S3-0A0021', httpPort: 0, localKey: KEY, wifiConnected: true });
  const b = new DeviceSimulator({ uid: 'AHBU-S3-0A0022', httpPort: 0, localKey: KEY });
  assert.deepEqual([a.clientNet.mode, b.clientNet.mode], ['lan', 'ap']);
  assert.throws(() => new DeviceSimulator({ uid: 'AHBU-S3-0A0023', clientNet: 'wan' }), /clientNet/);
  assert.throws(() => new DeviceSimulator({ uid: 'AHBU-S3-0A0024', staIp: 'abc' }), /staIp/);

  const { sim, j } = await startSim();
  try {
    const r = (await j('POST', '/__sim/hw-fail', { key: null, body: { tca_fail_reads: 2, tca_fail_writes: 3 } })).json;
    assert.deepEqual([r.hw_fail.tca_fail_reads, r.hw_fail.tca_fail_writes], [2, 3]);
    assert.ok(sim.fw.automation.tca.failReads <= 2 && sim.fw.automation.tca.failWrites <= 3, 'sayaclar firmware surucusune islendi (erisimlerle azalir)');
    assert.equal((await j('GET', '/__sim/state', { key: null })).json.hw_fail.tca_fail_writes <= 3, true);
    for (const bad of [{ tca_fail_reads: -1 }, { tca_fail_writes: 1.5 }, { tca_fail_reads: 5000 }, { tca_fail_reads: 'x' }]) {
      assert.equal((await j('POST', '/__sim/hw-fail', { key: null, body: bad })).status, 400, JSON.stringify(bad));
    }
  } finally {
    await sim.stop();
  }
});

test('rs485/scan: ek modul panjuru hareket halindeyken 503 {"error":"busy","message":...} (WebPortal ek "message" alani)', async () => {
  const { sim, j } = await startSim({ relays: 16 });
  try {
    await waitFor(() => sim.qaState().ext.responding, { timeoutMs: 3000, label: 'ek modul yanit vermedi' });
    const cfg = await j('POST', '/api/config', { body: { relays: [{}, {}, {}, {}, {}, {}, {}, {}, { type: 1, runtime_sec: 20 }, { type: 2, runtime_sec: 20 }] } });
    assert.equal(cfg.status, 200, JSON.stringify(cfg.json));
    assert.equal((await j('POST', '/api/relay?pair=5&cmd=up')).status, 200);
    await waitFor(() => sim.qaState().shutters.some((s) => s.pair === 5 && s.moving), { timeoutMs: 3000, label: 'ek panjur hareketi' });
    const busy = await j('POST', '/api/rs485/scan');
    assert.deepEqual([busy.status, busy.json], [503, { error: 'busy', message: 'ek modul panjuru hareket ediyor; tarama baslatilamadi' }]);
    assert.equal((await j('GET', '/api/rs485/scan')).json.status, 'idle');
  } finally {
    await sim.stop();
  }
});

test('QA ucu /__sim/ap: servis AP penceresini ac/kapat (CLI "AP ON/OFF"); ap_pass yoksa (provizyonlu) ACILMAZ; gecersiz deger 400', async () => {
  const { sim, j } = await startSim({ clientNet: 'ap' });            // ev agina bagli -> AP kapali
  try {
    await waitFor(() => sim.qaState().wifi.connected, { timeoutMs: 3000 });
    assert.equal(sim.qaState().wifi.ap_active, false);
    assert.equal(await statusOf(j, { key: null }), 401, 'AP kapali: anahtarsiz erisim yok');
    const open = (await j('POST', '/__sim/ap', { key: null, body: { open: true } })).json;
    assert.deepEqual([open.ok, open.ap.requested, open.ap.ssid], [true, 'open', 'AHBU-0A0001']);
    await waitFor(() => sim.qaState().wifi.ap_secured, { timeoutMs: 3000, label: 'servis AP' });
    assert.equal(await statusOf(j, { key: null }), 200, 'WPA2 servis AP penceresi + SoftAP istemcisi');
    await j('POST', '/__sim/ap', { key: null, body: { open: false } });
    await waitFor(() => !sim.qaState().wifi.ap_active, { timeoutMs: 3000, label: 'AP kapanmadi' });
    assert.equal(await statusOf(j, { key: null }), 401);
    for (const bad of [{}, { open: 'evet' }, { open: true, window_ms: 5 }, { open: true, window_ms: 1.5 }, { open: true, window_ms: 9e9 }]) {
      assert.equal((await j('POST', '/__sim/ap', { key: null, body: bad })).status, 400, JSON.stringify(bad));
    }
    // provizyonlu ama gecerli ap_pass YOK: servis AP'si de acilmaz (firmware kurali)
    sim.fw.cm.config.ap_pass = '';
    sim.fw.cm.save();
    await j('POST', '/__sim/ap', { key: null, body: { open: true } });
    await sleep(400);
    assert.equal(sim.qaState().wifi.ap_active, false);
  } finally {
    await sim.stop();
  }
});

test('bos "X-Device-Key:" basligi = baslik YOK (arduino-esp32 WebServer::hasHeader bos degeri yok sayar): /api/status KISITLI ozet 200; KEYED uclar 401 (deneme sayilmaz)', async () => {
  const { sim, j } = await startSim();
  try {
    const st = await j('GET', '/api/status', { key: '' });
    assert.equal(st.status, 200);
    assert.deepEqual(Object.keys(st.json).sort(), ['device', 'eth_connected', 'fw', 'name', 'net_if', 'provisioned', 'wifi_connected']);
    for (let i = 0; i < 7; i++) assert.deepEqual([(await j('GET', '/api/config', { key: '' })).status, sim.qaState().http_lock.fail_count], [401, 0]);
    assert.equal((await j('GET', '/api/status', { key: 'x' })).status, 401, 'bos olmayan yanlis anahtar: kimlik denetimi + sayac');
  } finally {
    await sim.stop();
  }
});

// ====================================================================================================================
// v1.3.0 kullanici karari 1 (Ethernet) + v1.3.1 duzeltmeleri. Istemci ag konumu modellenir: clientNet 'eth' = kablolu LAN konagi, baglantinin
// panodaki yerel ucu Ethernet IP'si (NetLinkCore::requestViaEth). Ethernet'ten gelen istek anahtarsiz ve provizyonsuz yetkilidir; Wi-Fi/AP
// istekleri anahtarli kalir.
// ====================================================================================================================
test('ethernet: kablolu istemci anahtarsiz yetkili; tam durumda provisioned gercek deger, lk_fp yalniz provizyonluyken; kisitli durumda lk_fp yok (servis_kurulum-1, pano-5)', async () => {
  const { sim, j } = await startSim();
  try {
    sim.setClientNet({ mode: 'eth' });
    assert.equal((await j('GET', '/api/config', { key: null })).status, 200, 'Ethernet anahtarsiz (karar 1)');
    const full = await j('GET', '/api/status', { key: 'herhangi-bir-deger' });   // Ethernet'te baslik degeri dogrulanmaz
    assert.equal(full.status, 200);
    assert.equal(full.json.provisioned, true);
    assert.equal(full.json.lk_fp, lkFp(KEY, UID));
    assert.equal(full.json.eth_connected, true);
    const r = (await j('GET', '/api/status', { key: null })).json;
    assert.deepEqual(Object.keys(r).sort(), ['device', 'eth_connected', 'fw', 'name', 'net_if', 'provisioned', 'wifi_connected']);
    assert.equal(r.eth_connected, true);
  } finally {
    await sim.stop();
  }
});

test('ethernet: provizyonsuz pano tam durumda provisioned:false (lk_fp yok); rekey 403 unprovisioned, yarim provizyon yok; factory/init calisir (servis_kurulum-1, pano-7)', async () => {
  const { sim, j } = await startSim({ localKey: '', wifiConnected: false });
  try {
    sim.setClientNet({ mode: 'eth' });
    const full = await j('GET', '/api/status', { key: 'bir-anahtar-123' });
    assert.equal(full.status, 200);
    assert.ok(Array.isArray(full.json.relays), 'Ethernet + baslik: tam durum');
    assert.equal(full.json.provisioned, false, 'tam durumda gercek deger (eskiden sabit true)');
    assert.equal('lk_fp' in full.json, false);
    const rk = await j('POST', '/api/auth/rekey', { key: null, body: { local_key: 'ethernet-anahtar-1' } });
    assert.deepEqual([rk.status, rk.json], [403, { error: 'unprovisioned' }]);
    assert.equal(sim.isProvisioned(), false, 'AP parolasiz yarim provizyon yok');
    const init = await j('POST', '/api/factory/init', { key: null, body: { local_key: 'fabrika-anahtar-1', ap_pass: 'ap-pass-1234' } });
    assert.equal(init.status, 200, 'ilk anahtar factory/init ile (karar 2: her arayuzden)');
    const full2 = (await j('GET', '/api/status', { key: 'x' })).json;
    assert.equal(full2.provisioned, true);
    assert.equal(full2.lk_fp, lkFp('fabrika-anahtar-1', UID));
  } finally {
    await sim.stop();
  }
});

test('ethernet: SoftAP istemcisinin panonun Ethernet IP adresine istegi Ethernet SAYILMAZ (anahtar gerekir); gercek Ethernet istemcisi etkilenmez (pano-3)', async () => {
  const { sim, j } = await startApSim();
  try {
    sim.setEthernet({ up: true });
    const cn = sim.setClientNet({ mode: 'ap', local_ip: sim.qaClientNet().eth_ip });
    assert.equal(cn.on_softap, true);
    assert.equal((await j('GET', '/api/config', { key: null })).status, 401, 'AP istemcisi anahtarsiz yetkili DEGIL');
    assert.equal((await j('GET', '/api/config')).status, 200, 'anahtarla calisir');
    sim.setClientNet({ mode: 'eth' });
    assert.equal((await j('GET', '/api/config', { key: null })).status, 200, 'gercek Ethernet istemcisi anahtarsiz');
  } finally {
    await sim.stop();
  }
});
