'use strict';

// WP-B2 / gorev 5: scripts/check_client_contract.js - Flutter istemci <-> Express sozlesme taramasi.
//   - Dart ayrıştırıcı (dize sabitleri, ${...} enterpolasyonu, cok satirli cagrilar, _sendRaw/_uri)
//   - Express rota tablosu cikarimi (mount yollari, parametreler, istege bagli parametre, tembel yonlendirici)
//   - eslestirme kurali (istemci parametresi yalnizca sunucu parametresiyle eslesir; yontem uyumsuzlugu ayri)
//   - GERCEK tarama: kayitli Flutter istemcisinin TUM cagrilari sunucuda var (yol + yontem) ve yeni WP-B2 uclari tabloda

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const scan = require('../../scripts/check_client_contract');

// ------------------------------------------------------------------------------
// Dart ayristirici
// ------------------------------------------------------------------------------
test('readDartString: tek/çift tırnak, kaçışlar, ${...} (iç içe parantez/dize) ve $ad enterpolasyonu -> :p', () => {
  const read = (src) => scan.readDartString(src, 0);
  assert.deepEqual(read("'/v1/auth/login'"), { value: '/v1/auth/login', end: 16 });
  assert.equal(read('"/v1/x"').value, '/v1/x');
  assert.equal(read("'/v1/homes/${_seg(homeId)}/devices'").value, '/v1/homes/:p/devices');
  assert.equal(read("'/v1/homes/${_seg(map['a'])}/x/${a}'").value, '/v1/homes/:p/x/:p');
  assert.equal(read("'/v1/u/$userId/s'").value, '/v1/u/:p/s');
  assert.equal(read("'/it\\'s'").value, "/it's");
  assert.equal(read("'$'").value, '$', 'tek $ sabit kalır');
  assert.equal(read("'kapanmamis"), null);
  assert.equal(read('x'), null);
});

test('extractClientCalls: _call/_sendRaw, çok satırlı çağrılar, enterpolasyon, tanım satırları ve yorumlar atlanır; yinelenenler tekilleşir', () => {
  const dart = `
    Future<Map<String, dynamic>> _call(
      String method,
      String path, {
      Object? body,
    }) async {}
    Future<void> a() async {
      final body = await _call('GET', '/v1/homes', timeout: const Duration(seconds: 10));
      await _call(
        'POST',
        '/v1/homes/\${_seg(homeId)}/devices/\${_seg(uuid)}/mqtt-credential',
        homeId: homeId,
      );
      await _call("delete", "/v1/auth/account", body: {});
      await _call('GET', '/v1/homes');
      final res = await _sendRaw(
        'POST',
        _uri('/v1/auth/refresh'),
        body: {},
      );
      // await _call('GET', '/v1/yorum');
      /// Örnek: _call('GET', '/v1/yorum2')
      final u = 'https://x.test/a'; await _call('POST', '/v1/dize-sonrasi');
      await _call('PATCH', path);
      await _call(method, '/v1/x');
    }
  `;
  const { calls, unresolved } = scan.extractClientCalls(dart);
  const keys = calls.map((c) => `${c.method} ${c.path}`);
  assert.ok(keys.includes('GET /api/v1/homes'));
  assert.ok(keys.includes('POST /api/v1/homes/:p/devices/:p/mqtt-credential'));
  assert.ok(keys.includes('DELETE /api/v1/auth/account'), 'yöntem büyük harfe çevrilir');
  assert.ok(keys.includes('POST /api/v1/auth/refresh'), '_sendRaw + _uri');
  assert.equal(keys.filter((k) => k === 'GET /api/v1/homes').length, 1, 'tekilleşir');
  assert.equal(calls.find((c) => c.path === '/api/v1/homes').lines.length, 2, 'satır numaraları birleşir');
  assert.ok(keys.every((k) => !k.endsWith('/v1/x')), 'dinamik yöntem çözülmez');
  assert.ok(keys.every((k) => !k.includes('yorum')), 'satır yorumu içindeki örnek çağrı atlanır');
  assert.ok(keys.includes('POST /api/v1/dize-sonrasi'), 'dize sabitindeki // yorum sayılmaz');
  assert.equal(unresolved.length, 1, 'yol sabiti olmayan çağrı raporlanır (_call(\'PATCH\', path))');
  assert.match(unresolved[0].snippet, /PATCH/);
  assert.ok(calls.every((c) => c.clientPath.startsWith('/v1/')));
});

// ------------------------------------------------------------------------------
// Express rota tablosu
// ------------------------------------------------------------------------------
function demoApp() {
  const app = express();
  const auth = express.Router();
  auth.post('/login', (req, res) => res.end());
  auth.get('/magic-login/:token?', (req, res) => res.end());
  const homes = express.Router({ mergeParams: true });
  homes.get('/devices', (req, res) => res.end());
  homes.route('/members/:uid').get((req, res) => res.end()).delete((req, res) => res.end());
  const lazy = (req, res, next) => next();
  lazy.createRouter = () => {
    const r = express.Router();
    r.get('/:homeId/scheduled-rules', (req, res) => res.end());
    r.put('/:homeId/scheduled-rules/:ruleId', (req, res) => res.end());
    return r;
  };
  app.get('/health', (req, res) => res.end());
  app.use('/api/v1/auth', auth);
  app.use('/api/v1/homes/:home_id', homes);
  app.use('/api/v1/homes', lazy);
  app.get(['/a', '/b'], (req, res) => res.end());
  return app;
}

test('collectRoutes: mount yolu + parametreler, istege bagli parametre (iki bicim), dizi yollari, tembel yonlendirici (createRouter)', () => {
  const { routes, warnings } = scan.collectRoutes(demoApp());
  const keys = routes.map((r) => `${r.method} ${r.path}`).sort();
  assert.deepEqual(keys, [
    'DELETE /api/v1/homes/:home_id/members/:uid',
    'GET /a',
    'GET /api/v1/auth/magic-login',
    'GET /api/v1/auth/magic-login/:token',
    'GET /api/v1/homes/:home_id/devices',
    'GET /api/v1/homes/:home_id/members/:uid',
    'GET /api/v1/homes/:homeId/scheduled-rules',
    'GET /b',
    'GET /health',
    'POST /api/v1/auth/login',
    'PUT /api/v1/homes/:homeId/scheduled-rules/:ruleId',
  ].sort());
  assert.deepEqual(warnings, []);
});

test('collectRoutes: Express yığını yoksa açık hata', () => {
  assert.throws(() => scan.collectRoutes({}), /yonlendirici yigini/);
});

// ------------------------------------------------------------------------------
// Eslestirme
// ------------------------------------------------------------------------------
test('matchPath: istemci parametresi yalnızca sunucu PARAMETRESİYLE eşleşir; sabit parça eşit olmalı (ya da sunucuda parametre)', () => {
  assert.equal(scan.matchPath('/api/v1/homes/:p/devices', '/api/v1/homes/:homeId/devices'), true);
  assert.equal(scan.matchPath('/api/v1/homes/join', '/api/v1/homes/:homeId'), true, 'istemci sabit, sunucu parametre');
  assert.equal(scan.matchPath('/api/v1/homes/:p', '/api/v1/homes/join'), false, 'istemci parametre, sunucu sabit: eşleşmez');
  assert.equal(scan.matchPath('/api/v1/homes/:p/devices', '/api/v1/homes/:p/members'), false);
  assert.equal(scan.matchPath('/api/v1/homes/:p', '/api/v1/homes/:p/devices'), false, 'segment sayısı');
  assert.equal(scan.matchPath('/a/b/', '/a/b'), true);
});

test('compare: ok / yöntem uyumsuzluğu / eksik ayrımı; unusedRoutes /api takma yollarını ikizi varsa gizler', () => {
  const routes = [
    { method: 'GET', path: '/api/v1/homes/:id/devices' },
    { method: 'POST', path: '/api/v1/homes/:id/devices' },
    { method: 'GET', path: '/api/homes/:id/devices' },
    { method: 'GET', path: '/api/legacy/only' },
    { method: 'GET', path: '/health' },
  ];
  const calls = [
    { method: 'GET', path: '/api/v1/homes/:p/devices' },
    { method: 'PUT', path: '/api/v1/homes/:p/devices' },
    { method: 'GET', path: '/api/v1/yok' },
  ];
  const r = scan.compare(calls, routes);
  assert.equal(r.ok.length, 1);
  assert.deepEqual(r.methodMismatch.map((c) => [c.method, c.serverMethods]), [['PUT', ['GET', 'POST']]]);
  assert.deepEqual(r.missing.map((c) => c.path), ['/api/v1/yok']);
  assert.deepEqual(
    scan.unusedRoutes(calls, routes).map((x) => `${x.method} ${x.path}`),
    ['POST /api/v1/homes/:id/devices', 'GET /api/legacy/only', 'GET /health']
  );
});

test('parseArgs: seçenekler ve hatalar', () => {
  const o = scan.parseArgs(['--json', '--unused', '--allow', 'POST /api/v1/x, get /api/v1/y/:id', '--dart', 'a.dart']);
  assert.equal(o.json, true);
  assert.equal(o.unused, true);
  assert.deepEqual(o.allow, [{ method: 'POST', path: '/api/v1/x' }, { method: 'GET', path: '/api/v1/y/:id' }]);
  assert.ok(o.dart.endsWith('a.dart'));
  assert.ok(scan.parseArgs(['--bilinmeyen']).errors.length > 0);
  assert.ok(scan.parseArgs(['--dart']).errors.length > 0);
});

// ------------------------------------------------------------------------------
// GERCEK tarama (kayitli Flutter istemcisi <-> gercek createApp)
// ------------------------------------------------------------------------------
function runMain(argv, deps = {}) {
  const out = [];
  const err = [];
  return scan.main({ argv, log: (...a) => out.push(a.join(' ')), errLog: (...a) => err.push(a.join(' ')), ...deps }).then((code) => ({ code, out: out.join('\n'), err: err.join('\n') }));
}

const HAS_DART = require('node:fs').existsSync(scan.DEFAULT_DART);

test('GERÇEK TARAMA: Flutter ev_cloud_api_service.dart içindeki TÜM istekler sunucuda kayıtlı (yol + yöntem); çözülemeyen çağrı yok', { skip: HAS_DART ? false : 'Flutter istemci dosyası bulunamadı (yalnız sunucu çıkarması)' }, async () => {
  const r = await runMain(['--json', '--unused']);
  const report = JSON.parse(r.out);
  if (process.env.CLIENT_CONTRACT_SOFT === '1' && r.code !== 0) {
    // Flutter ve sunucu paketleri paralel gelistirilirken gecici fark: UYARI (cikis kodu etkilenmez)
    console.warn(`UYARI (CLIENT_CONTRACT_SOFT=1): eşleşmeyen uçlar: ${JSON.stringify(report.missing)} ${JSON.stringify(report.method_mismatch)}`);
    return;
  }
  assert.equal(r.code, 0, `eşleşmeyen uçlar: ${JSON.stringify(report.missing)} ${JSON.stringify(report.method_mismatch)}`);
  assert.deepEqual(report.missing, []);
  assert.deepEqual(report.method_mismatch, []);
  assert.deepEqual(report.unresolved, []);
  assert.deepEqual(report.warnings, [], 'mount yolu çözülemeyen/tembel yönlendirici uyarısı yok');
  assert.ok(report.client_calls >= 60, `istemci çağrısı sayısı: ${report.client_calls}`);
  assert.equal(report.ok, report.client_calls);
  assert.ok(report.server_routes > 100);
});

test('GERÇEK TARAMA: yeni WP-B2 uçları ve istemcinin beklediği join-preview sunucu tablosunda', async () => {
  const { loadApp, collectRoutes } = scan;
  const keys = new Set(collectRoutes(loadApp()).routes.map((x) => `${x.method} ${x.path}`));
  for (const k of [
    'GET /api/v1/service/subscribers',
    'GET /api/service/subscribers',
    'POST /api/v1/service/subscribers/:homeId/assign-admin/request-otp',
    'POST /api/v1/service/subscribers/:homeId/assign-admin',
    'DELETE /api/v1/auth/account',
    'DELETE /api/auth/account',
    'POST /api/v1/admin/inventory/:uuid/reissue-label',
    'POST /api/v1/homes/join-preview',
    'POST /api/homes/join-preview',
  ]) assert.ok(keys.has(k), k);
});

test('tarama kırılgan değil: istemciye sunucuda olmayan bir çağrı eklenirse YAKALANIR (çıkış 1), --allow ile izinli olur', { skip: HAS_DART ? false : 'Flutter istemci dosyası bulunamadı' }, async () => {
  const fs = require('node:fs');
  const real = fs.readFileSync(scan.DEFAULT_DART, 'utf8');
  const doctored = `${real}\n  Future<void> x() async { await _call('POST', '/v1/service/yok-boyle-uc/\${_seg(id)}'); await _call('PUT', '/v1/service/subscribers'); }\n`;
  const r = await runMain([], { readFile: () => doctored });
  assert.equal(r.code, 1);
  assert.match(r.out, /SUNUCUDA OLMAYAN UCLAR/);
  assert.match(r.out, /POST\s+\/api\/v1\/service\/yok-boyle-uc\/:p/);
  assert.match(r.out, /YONTEM UYUMSUZLUGU/);
  assert.match(r.out, /PUT\s+\/api\/v1\/service\/subscribers\s+sunucu: GET/);

  const waived = await runMain(['--allow', 'POST /api/v1/service/yok-boyle-uc/:p, PUT /api/v1/service/subscribers'], { readFile: () => doctored });
  assert.equal(waived.code, 0);
  assert.match(waived.out, /BILINEN EKSIK \(izinli\)/);
});

test('CLI: Dart dosyası okunamazsa çıkış 2; bilinmeyen seçenek 2; --help 0', async () => {
  const missing = await runMain(['--dart', 'yok/boyle/dosya.dart']);
  assert.equal(missing.code, 2);
  assert.match(missing.err, /okunamadi/);
  assert.equal((await runMain(['--nope'])).code, 2);
  assert.equal((await runMain(['--help'])).code, 0);
});
