#!/usr/bin/env node
'use strict';

// ==============================================================================
// AHBU Akilli Ev - Flutter istemci <-> Express SOZLESME UYUM TARAMASI              [WP-B2, gorev 5]
// ==============================================================================
//
// Flutter `lib/services/ev_cloud_api_service.dart` icindeki istek yollarini ve HTTP yontemlerini (regex ile) cikarir,
// sunucuda KAYITLI Express rotalariyla karsilastirir ve eslesmeyen uclari listeler.
//
// Sunucu rota tablosu: `createApp()` sahte db / sahte MQTT koprusu ile yuklenir (hicbir baglanti ACILMAZ) ve
// Express yonlendirici yigini dolasilir (mount yollari dahil). `app._router` Express 4 ic yapisidir; Express
// surumu degisirse `collectRoutes` guncellenmelidir (testi bunu yakalar).
//
// KULLANIM (server/ dizininden):
//   node scripts/check_client_contract.js                     Tarama; eslesmeyen istemci cagrisi varsa cikis 1
//   node scripts/check_client_contract.js --json              Makine okunur cikti
//   node scripts/check_client_contract.js --unused            + istemcinin KULLANMADIGI sunucu uclari (bilgi)
//   node scripts/check_client_contract.js --dart <dosya>      Baska bir Dart istemci dosyasi
//   node scripts/check_client_contract.js --allow "POST /api/v1/x,GET /api/v1/y"   bilinen/beklenen eksikler (uyari)
// Cikis kodu: 0 uyumlu, 1 eslesmeyen cagri var, 2 kullanim/yukleme hatasi.
//
// SINIR: yalnizca yol + yontem (govde alanlari, sorgu parametreleri, yanit sekilleri DENETLENMEZ). Dinamik olarak
// kurulan yollar ('$prefix/...') cozulemez ve "cozulemedi" olarak raporlanir.

const fs = require('fs');
const path = require('path');

const SERVER_DIR = path.join(__dirname, '..');
const DEFAULT_DART = path.join(SERVER_DIR, '..', 'lib', 'services', 'ev_cloud_api_service.dart');
// AppConfig.apiBaseUrl `/api` ile biter; istemci yollari `/v1/...` ile baslar.
const DEFAULT_API_PREFIX = '/api';
const METHODS = new Set(['GET', 'POST', 'PUT', 'PATCH', 'DELETE']);

// ------------------------------------------------------------------------------
// 1) Dart istemcisinden cagrilari cikar
// ------------------------------------------------------------------------------

/**
 * `src[i]` bir tirnak (' veya ") ise Dart dize sabitini okur. Enterpolasyonlar (`${...}` ve `$ad`) `:p` olur.
 * @returns {{value:string, end:number}|null} end = kapanis tirnagindan SONRAKI indeks
 */
function readDartString(src, i) {
  const quote = src[i];
  if (quote !== "'" && quote !== '"') return null;
  let out = '';
  let j = i + 1;
  while (j < src.length) {
    const ch = src[j];
    if (ch === '\\') {
      out += src[j + 1] || '';
      j += 2;
      continue;
    }
    if (ch === quote) return { value: out, end: j + 1 };
    if (ch === '$') {
      if (src[j + 1] === '{') {
        // ${ ... } iceri tirnaklari ve ic ice suslu parantezleri atla
        let depth = 1;
        let k = j + 2;
        while (k < src.length && depth > 0) {
          const c = src[k];
          if (c === "'" || c === '"') {
            const inner = readDartString(src, k);
            k = inner ? inner.end : k + 1;
            continue;
          }
          if (c === '{') depth++;
          else if (c === '}') depth--;
          k++;
        }
        out += ':p';
        j = k;
        continue;
      }
      const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(src.slice(j + 1, j + 80));
      if (m) {
        out += ':p';
        j += 1 + m[0].length;
        continue;
      }
    }
    if (ch === '\n') return null; // tek satirli dize sabiti beklenir
    out += ch;
    j++;
  }
  return null;
}

function skipSpace(src, i) {
  let j = i;
  while (j < src.length && /\s/.test(src[j])) j++;
  return j;
}

function lineOf(src, index) {
  let n = 1;
  for (let i = 0; i < index && i < src.length; i++) if (src[i] === '\n') n++;
  return n;
}

/**
 * @param {string} dartSource
 * @param {{apiPrefix?:string}} [opts]
 * @returns {{calls:Array<{method:string, path:string, clientPath:string, line:number}>, unresolved:Array<{line:number, snippet:string}>}}
 */
function extractClientCalls(dartSource, { apiPrefix = DEFAULT_API_PREFIX } = {}) {
  const src = String(dartSource);
  const calls = [];
  const unresolved = [];

  const finder = /\b(_call|_sendRaw)\(/g;
  let m;
  while ((m = finder.exec(src)) !== null) {
    const kind = m[1];
    // Satir yorumunun ICINDEKI ornek cagrilari atla (// veya /// ... _call(...)); dize sabitlerindeki '//' sayilmaz
    const lineStart = src.lastIndexOf('\n', m.index) + 1;
    const prefix = src.slice(lineStart, m.index).replace(/'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"/g, '');
    if (prefix.includes('//')) continue;
    const line = lineOf(src, m.index);
    let i = skipSpace(src, finder.lastIndex);
    // tanim satirlari: `Future<...> _call(\n String method,` -> ilk arguman tirnakli degil, atlanir
    const methodLit = readDartString(src, i);
    if (!methodLit) continue;
    const method = methodLit.value.toUpperCase();
    if (!METHODS.has(method)) continue;
    i = skipSpace(src, methodLit.end);
    if (src[i] !== ',') {
      unresolved.push({ line, snippet: src.slice(m.index, m.index + 80).replace(/\s+/g, ' ') });
      continue;
    }
    i = skipSpace(src, i + 1);

    let pathLit = null;
    if (kind === '_sendRaw') {
      // _sendRaw('POST', _uri('/v1/...'), ...)
      const uri = /^_uri\(\s*/.exec(src.slice(i, i + 20));
      if (!uri) {
        unresolved.push({ line, snippet: src.slice(m.index, m.index + 80).replace(/\s+/g, ' ') });
        continue;
      }
      pathLit = readDartString(src, i + uri[0].length);
    } else {
      pathLit = readDartString(src, i);
    }
    if (!pathLit || !pathLit.value.startsWith('/')) {
      unresolved.push({ line, snippet: src.slice(m.index, m.index + 80).replace(/\s+/g, ' ') });
      continue;
    }
    const clientPath = pathLit.value;
    calls.push({ method, clientPath, path: `${apiPrefix}${clientPath}`.replace(/\/+$/, '') || '/', line });
  }

  // tekillestir (ayni yontem+yol birden fazla yerde olabilir)
  const seen = new Map();
  for (const c of calls) {
    const key = `${c.method} ${c.path}`;
    if (!seen.has(key)) seen.set(key, { ...c, lines: [c.line] });
    else seen.get(key).lines.push(c.line);
  }
  return { calls: [...seen.values()], unresolved };
}

// ------------------------------------------------------------------------------
// 2) Express rota tablosu
// ------------------------------------------------------------------------------

/** Express 4 Layer.regexp + keys -> '/api/v1/homes/:home_id' (cozulemezse null). */
function mountPathOf(layer) {
  const re = layer.regexp;
  if (!re) return '';
  if (re.fast_slash) return '';
  let source = re.source;
  source = source.replace(/^\^/, '').replace(/\\\/\?\(\?=\\\/\|\$\)\$?$/, '');
  const keys = Array.isArray(layer.keys) ? layer.keys.slice() : [];
  // her parametre: path-to-regexp 0.1.x `(?:\/([^/]+?))` (egik cizgiyi icerir) ya da `(?:([^\/]+?))`
  source = source.replace(/\(\?:(\\\/)?\(\[\^\\?\/\]\+\?\)\)/g, (_all, slash) => {
    const k = keys.shift();
    return `${slash ? '/' : ''}${k ? `:${k.name}` : ':?'}`;
  });
  source = source.replace(/\\\//g, '/');
  if (/[()[\]?*+^$|\\]/.test(source.replace(/:[A-Za-z0-9_]+/g, ''))) return null; // duz yol degil
  return source;
}

/** '/a/:b?' -> ['/a/:b', '/a'] (istege bagli parametre iki bicimde). */
function expandOptional(p) {
  const out = [p];
  if (/\/:[A-Za-z0-9_]+\?/.test(p)) {
    out.length = 0;
    out.push(p.replace(/\?/g, ''), p.replace(/\/:[A-Za-z0-9_]+\?/g, ''));
  }
  return out.map((x) => x.replace(/\/+/g, '/').replace(/(.)\/$/, '$1') || '/');
}

function joinPaths(a, b) {
  const x = String(a || '').replace(/\/+$/, '');
  const y = String(b || '');
  if (!y || y === '/') return x || '/';
  return `${x}${y.startsWith('/') ? '' : '/'}${y}`;
}

/**
 * Express uygulamasinin kayitli rotalari.
 * @returns {{routes:Array<{method:string, path:string}>, warnings:string[]}}
 */
function collectRoutes(app) {
  const routes = [];
  const warnings = [];
  const root = app && (app._router || app.router);
  if (!root || !Array.isArray(root.stack)) {
    throw new Error('Express yonlendirici yigini bulunamadi (Express 4 beklenir).');
  }

  function walk(stack, prefix) {
    for (const layer of stack) {
      if (layer.route) {
        const paths = Array.isArray(layer.route.path) ? layer.route.path : [layer.route.path];
        for (const p of paths) {
          if (typeof p !== 'string') {
            warnings.push(`Dizge olmayan rota yolu atlandi (${prefix || '/'})`);
            continue;
          }
          for (const method of Object.keys(layer.route.methods).filter((k) => layer.route.methods[k])) {
            for (const full of expandOptional(joinPaths(prefix, p))) routes.push({ method: method.toUpperCase(), path: full });
          }
        }
      } else if (layer.name === 'router' && layer.handle && Array.isArray(layer.handle.stack)) {
        const mp = mountPathOf(layer);
        if (mp === null) {
          warnings.push(`Cozulemeyen mount yolu atlandi: ${layer.regexp && layer.regexp.source}`);
          continue;
        }
        walk(layer.handle.stack, joinPaths(prefix, mp));
      } else if (layer.handle && typeof layer.handle.createRouter === 'function' && !Array.isArray(layer.handle.stack)) {
        // Tembel yonlendirici (ornegin scheduled_rules_routes: ilk istekte olusur): modulun `createRouter()` fabrikasi
        // cagrilarak GERCEK rota yigini okunur (istek calistirilmaz, baglanti acilmaz).
        const mp = mountPathOf(layer);
        if (mp === null) {
          warnings.push(`Cozulemeyen mount yolu atlandi: ${layer.regexp && layer.regexp.source}`);
          continue;
        }
        let inner = null;
        try {
          inner = layer.handle.createRouter();
        } catch (err) {
          warnings.push(`Tembel yonlendirici olusturulamadi (${joinPaths(prefix, mp)}): ${err.message}`);
          continue;
        }
        if (inner && Array.isArray(inner.stack)) walk(inner.stack, joinPaths(prefix, mp));
      }
    }
  }
  walk(root.stack, '');

  const seen = new Set();
  const unique = routes.filter((r) => {
    const k = `${r.method} ${r.path}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
  return { routes: unique, warnings };
}

/**
 * createApp'i HICBIR baglanti acmadan yukler: sahte DATABASE_URL (var olan degere dokunulmaz ama `.env`'in canli
 * degerlerini yuklemesi engellenir), sahte db / MQTT koprusu / push servisi.
 */
function loadApp() {
  const env = process.env;
  // dotenv yalniz TANIMSIZ degiskenleri yukler: onemli olanlari bos dizgeyle sabitle (yerel .env canli olabilir)
  env.DATABASE_URL = 'postgres://127.0.0.1:1/contract_check';
  for (const k of ['EMQX_API_URL', 'EMQX_API_KEY', 'EMQX_API_SECRET', 'SMTP_HOST', 'SMTP_USER', 'SMTP_PASSWORD', 'MQTT_BACKEND_USER', 'MQTT_BACKEND_PASS', 'MQTT_HOST', 'ADMIN_API_KEY']) {
    env[k] = '';
  }
  env.NODE_ENV = 'test';
  const quiet = { log: console.log, warn: console.warn };
  console.log = () => {};
  console.warn = () => {};
  try {
    const { createApp } = require(path.join(SERVER_DIR, 'src', 'server'));
    const fakeDb = {
      pool: { end: async () => {} },
      query: async () => ({ rows: [], rowCount: 0 }),
      withTransaction: async () => {
        throw new Error('sozlesme taramasinda veritabani kullanilamaz');
      },
    };
    const fakeBridge = { isConnected: () => false, init() {}, end: async () => {} };
    const fakePush = { upsertToken: async () => {}, disableToken: async () => {} };
    return createApp({ db: fakeDb, mqttBridge: fakeBridge, pushService: fakePush });
  } finally {
    console.log = quiet.log;
    console.warn = quiet.warn;
  }
}

// ------------------------------------------------------------------------------
// 3) Karsilastirma
// ------------------------------------------------------------------------------

const isParam = (seg) => seg.startsWith(':');

/**
 * Istemci yolu sunucu yoluyla eslesir mi? Istemcinin dinamik parcasi (':p') yalnizca sunucunun PARAMETRESIYLE
 * eslesir; istemcinin sabit parcasi sunucunun sabit parcasiyla esit ya da sunucunun parametresi olmalidir.
 */
function matchPath(clientPath, serverPath) {
  const a = clientPath.split('/').filter(Boolean);
  const b = serverPath.split('/').filter(Boolean);
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (isParam(a[i])) {
      if (!isParam(b[i])) return false;
    } else if (!isParam(b[i]) && a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

/**
 * @param {Array<{method:string,path:string}>} calls
 * @param {Array<{method:string,path:string}>} routes
 * @returns {{ok:Array, methodMismatch:Array, missing:Array}}
 */
function compare(calls, routes) {
  const ok = [];
  const methodMismatch = [];
  const missing = [];
  for (const call of calls) {
    const samePath = routes.filter((r) => matchPath(call.path, r.path));
    if (samePath.some((r) => r.method === call.method)) {
      ok.push(call);
    } else if (samePath.length > 0) {
      methodMismatch.push({ ...call, serverMethods: [...new Set(samePath.map((r) => r.method))].sort() });
    } else {
      missing.push(call);
    }
  }
  return { ok, methodMismatch, missing };
}

/**
 * Istemcinin hicbir cagrisiyla eslesmeyen sunucu uclari (bilgi amacli). Eski `/api/...` takma yollari, ayni ucun
 * `/api/v1/...` ikizi varsa listelenmez (gurultu).
 */
function unusedRoutes(calls, routes) {
  const keys = new Set(routes.map((r) => `${r.method} ${r.path}`));
  return routes.filter((r) => {
    if (calls.some((c) => c.method === r.method && matchPath(c.path, r.path))) return false;
    if (r.path.startsWith('/api/') && !r.path.startsWith('/api/v1/') && keys.has(`${r.method} /api/v1${r.path.slice(4)}`)) return false;
    return true;
  });
}

// ------------------------------------------------------------------------------
// CLI
// ------------------------------------------------------------------------------

function parseArgs(argv) {
  const opts = { json: false, unused: false, dart: DEFAULT_DART, allow: [], help: false, errors: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--json') opts.json = true;
    else if (a === '--unused') opts.unused = true;
    else if (a === '--help' || a === '-h') opts.help = true;
    else if (a === '--dart') {
      if (!argv[i + 1]) opts.errors.push('--dart bir dosya yolu bekler');
      else opts.dart = path.resolve(argv[++i]);
    } else if (a === '--allow') {
      if (!argv[i + 1]) opts.errors.push('--allow "METHOD /yol,..." bekler');
      else {
        for (const part of argv[++i].split(',').map((s) => s.trim()).filter(Boolean)) {
          const [method, ...rest] = part.split(/\s+/);
          opts.allow.push({ method: method.toUpperCase(), path: rest.join(' ') });
        }
      }
    } else opts.errors.push(`Bilinmeyen secenek: ${a}`);
  }
  return opts;
}

const USAGE = 'Kullanim: node scripts/check_client_contract.js [--json] [--unused] [--dart <dosya>] [--allow "METHOD /yol,..."]';

async function main(deps = {}) {
  const argv = deps.argv || process.argv.slice(2);
  const log = deps.log || ((...a) => console.log(...a));
  const errLog = deps.errLog || ((...a) => console.error(...a));
  const opts = parseArgs(argv);
  if (opts.help) {
    log(USAGE);
    return 0;
  }
  if (opts.errors.length > 0) {
    for (const e of opts.errors) errLog(`HATA: ${e}`);
    errLog(USAGE);
    return 2;
  }

  let dartSource;
  try {
    dartSource = (deps.readFile || ((p) => fs.readFileSync(p, 'utf8')))(opts.dart);
  } catch (err) {
    errLog(`HATA: Dart istemci dosyasi okunamadi (${opts.dart}): ${err.message}`);
    return 2;
  }

  let table;
  try {
    const app = deps.app || loadApp();
    table = collectRoutes(app);
  } catch (err) {
    errLog(`HATA: sunucu rota tablosu cikarilamadi: ${err.message}`);
    return 2;
  }

  const { calls, unresolved } = extractClientCalls(dartSource);
  const result = compare(calls, table.routes);
  const allowed = (c) => opts.allow.some((a) => a.method === c.method && matchPath(a.path, c.path) && matchPath(c.path, a.path));
  const missing = result.missing.filter((c) => !allowed(c));
  const mismatch = result.methodMismatch.filter((c) => !allowed(c));
  const waived = [...result.missing, ...result.methodMismatch].filter(allowed);
  const unused = opts.unused ? unusedRoutes(calls, table.routes) : [];

  const failing = missing.length + mismatch.length;
  if (opts.json) {
    log(
      JSON.stringify(
        {
          dart: path.relative(SERVER_DIR, opts.dart).replace(/\\/g, '/'),
          client_calls: calls.length,
          server_routes: table.routes.length,
          ok: result.ok.length,
          missing: missing.map((c) => ({ method: c.method, path: c.path, lines: c.lines })),
          method_mismatch: mismatch.map((c) => ({ method: c.method, path: c.path, server_methods: c.serverMethods, lines: c.lines })),
          waived: waived.map((c) => ({ method: c.method, path: c.path })),
          unresolved,
          warnings: table.warnings,
          unused_server_routes: unused,
        },
        null,
        2
      )
    );
  } else {
    log(`Istemci cagrisi: ${calls.length} (cozulemeyen ${unresolved.length}); sunucu rotasi: ${table.routes.length}; eslesen: ${result.ok.length}`);
    for (const w of table.warnings) log(`UYARI: ${w}`);
    for (const u of unresolved) log(`COZULEMEDI (satir ${u.line}): ${u.snippet}`);
    for (const c of waived) log(`BILINEN EKSIK (izinli): ${c.method} ${c.path}`);
    if (missing.length > 0) {
      log('\nSUNUCUDA OLMAYAN UCLAR (istemci 404 alir):');
      for (const c of missing) log(`  ${c.method.padEnd(6)} ${c.path}   [dart:${c.lines.join(',')}]`);
    }
    if (mismatch.length > 0) {
      log('\nYONTEM UYUMSUZLUGU (yol var, yontem yok):');
      for (const c of mismatch) log(`  ${c.method.padEnd(6)} ${c.path}   sunucu: ${c.serverMethods.join('/')}   [dart:${c.lines.join(',')}]`);
    }
    if (opts.unused) {
      log(`\nISTEMCININ KULLANMADIGI SUNUCU UCLARI (${unused.length}; bilgi):`);
      for (const r of unused) log(`  ${r.method.padEnd(6)} ${r.path}`);
    }
    if (failing === 0) log('\nIstemci-sunucu sozlesmesi UYUMLU (yol + yontem).');
  }
  return failing > 0 ? 1 : 0;
}

module.exports = {
  main,
  extractClientCalls,
  readDartString,
  collectRoutes,
  mountPathOf,
  matchPath,
  compare,
  unusedRoutes,
  loadApp,
  parseArgs,
  DEFAULT_DART,
};

if (require.main === module) {
  main().then(
    (code) => process.exit(code),
    (err) => {
      console.error(`HATA: ${err && err.message ? err.message : err}`);
      process.exit(2);
    }
  );
}
