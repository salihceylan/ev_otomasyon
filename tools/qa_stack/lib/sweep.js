// Q2 "SUPURME" (sweep): GERCEK PostgreSQL + gercek sunucu uzerinde, tum REST ailelerine DUSMAN GIRDI (hostile input) ve akis (flow) taramasi.
//
// Amac: mock'lu testlerin yakalayamadigi siniflari bulmak -- gecersiz uuid metni (22P02), NUL bayti (22021), cok uzun metin (22001),
// tam sayi tasmasi (22003), tip uyusmazligi, kisit ihlali, FOR UPDATE + dis birlestirme, belirsiz parametre tipi... Her 5xx yanit (X-Error-Ref)
// sunucunun api.log'undaki yigin izine (dosya:satir) baglanir; her `[DB-QUERY-ERROR]` (4xx'e sarilmis olsa bile) ayrica raporlanir.
//
// Yan etkiler: tum yikici/degistirici islemler SUPURME'ye OZGU gecici kullanici/ev/cihazlar uzerinde yapilir (seed verisi bozulmaz);
// seed hesaplariyla yalnizca okuma uclari ve zararsiz (idempotent) yazmalar denenir. Hiz sinirlayicilar (kullanici/ev anahtarli) icin
// "donen aktor" kullanilir: her ~35 istekte yeni kullanici + ev olusturulur, boylece 429 yuzunden kapsam kaybi olmaz.
import fs from 'node:fs';
import crypto from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { PORTS } from './config.js';
import { readAccounts } from './accounts.js';

const rnd = (n = 4) => crypto.randomBytes(n).toString('hex');
const num8 = () => String(Math.floor(1e7 + Math.random() * 8.9e7));

// ------------------------------------------------------------------------------------------------ dusman degerler
export const HOSTILE_STR = [
  ['bos', ''], ['bosluk', '   '], ['nul-icinde', 'a\u0000b'], ['nul', '\u0000'], ['uzun-300', 'x'.repeat(300)], ['uzun-5000', 'y'.repeat(5000)],
  ['uzun-70000', 'z'.repeat(70000)], ['emoji', '\u{1F600}\u{1F468}‍\u{1F469}‍\u{1F467}'], ['tek-vekil', '\ud800'], ['tirnak', "'"], ['sqli-1', "' OR '1'='1"],
  ['sqli-2', '1; DROP TABLE users; --'], ['yuzde', '%'], ['altcizgi', '_'], ['ters-bolu', '\\'], ['crlf', 'a\r\nSet-Cookie: x=1'], ['uuid-degil', 'not-a-uuid'],
  ['sifir-uuid', '00000000-0000-0000-0000-000000000000'], ['rtl', '‮evil'], ['html', '<script>alert(1)</script>'], ['json-metni', '{"a":1}'], ['dev-sayi', '9'.repeat(40)],
  ['negatif', '-1'], ['yol-gezme', '../../etc/passwd'], ['null-metni', 'null'], ['bom', '﻿x'],
];
export const HOSTILE_NUM = [-1, 0, 1.5, 255, 256, 65535, 65536, 2147483647, 2147483648, -2147483649, 4294967296, 9007199254740993, 1e308, 5e-324];
export const HOSTILE_ANY = [null, true, false, [], {}, [1, 2], { a: 1 }, [[]], [null], { $gt: '' }, [{ a: { b: { c: 1 } } }]];
export const HOSTILE_ID = [
  'not-a-uuid', '00000000-0000-0000-0000-000000000000', "' OR 1=1 --", '%00', '..', '%', '_', 'a'.repeat(300), '12345678-1234-1234-1234-12345678901g',
  'ABCDEFAB-ABCD-ABCD-ABCD-ABCDEFABCDEF', '\u0000', '1', '-1', '9'.repeat(30),
];

/** Govde SEKLI dusmanlari (alan degil, kok). [ad, ham govde, content-type] */
export function shapeVariants() {
  const deep = (n) => { let o = { v: 1 }; for (let i = 0; i < n; i++) o = { v: o }; return o; };
  return [
    ['null-govde', 'null', 'application/json'],
    ['dizi-govde', '[]', 'application/json'],
    ['metin-govde', '"x"', 'application/json'],
    ['sayi-govde', '5', 'application/json'],
    ['bos-govde', '', 'application/json'],
    ['bozuk-json', '{"a":', 'application/json'],
    ['text-plain', '{"a":1}', 'text/plain'],
    ['form', 'a=1&b=2', 'application/x-www-form-urlencoded'],
    ['derin-100', JSON.stringify(deep(100)), 'application/json'],
    ['cok-anahtar', JSON.stringify(Object.fromEntries(Array.from({ length: 3000 }, (_, i) => [`k${i}`, i]))), 'application/json'],
    ['proto', '{"__proto__":{"polluted":true},"constructor":{"prototype":{"x":1}}}', 'application/json'],
    ['yinelenen-anahtar', '{"a":1,"a":2}', 'application/json'],
    ['300kb', JSON.stringify({ blob: 'q'.repeat(300 * 1024) }), 'application/json'],
    ['bom-json', '﻿{"a":1}', 'application/json'],
    ['nul-json', '{"a":"\\u0000"}', 'application/json'],
  ];
}

// ------------------------------------------------------------------------------------------------ HTTP
class Http {
  constructor(base, onRequest) {
    this.base = base.replace(/\/+$/, '');
    this.onRequest = onRequest;
    this.ipSeq = Math.floor(Math.random() * 60000);
  }

  nextIp() {
    this.ipSeq = (this.ipSeq + 1) % 65000;
    return `10.${77 + Math.floor(this.ipSeq / 65025)}.${(this.ipSeq >> 8) & 255}.${(this.ipSeq & 255) || 1}`;
  }

  async call(method, path, { token, body, raw, ctype, query, headers = {}, timeoutMs = 20000, ip } = {}) {
    const qs = query ? `?${new URLSearchParams(Object.entries(query).filter(([, v]) => v !== undefined).map(([k, v]) => [k, String(v)])).toString()}` : '';
    const h = { 'X-Forwarded-For': ip || this.nextIp(), ...headers };
    if (token) h.Authorization = `Bearer ${token}`;
    let payload;
    if (raw !== undefined) { payload = raw; if (ctype) h['Content-Type'] = ctype; } else if (body !== undefined) { payload = typeof body === 'string' ? body : JSON.stringify(body); h['Content-Type'] = 'application/json'; }
    const t0 = Date.now();
    let res;
    try {
      res = await fetch(this.base + path + qs, { method, headers: h, body: payload, signal: AbortSignal.timeout(timeoutMs) });
    } catch (e) {
      const out = { status: 0, error: e.name === 'TimeoutError' ? 'timeout' : e.message, json: null, text: '', headers: {}, ms: Date.now() - t0 };
      this.onRequest?.(method, path, out);
      return out;
    }
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch (_) { /* json degil */ }
    const out = { status: res.status, json, text, headers: Object.fromEntries(res.headers), ms: Date.now() - t0 };
    this.onRequest?.(method, path, out);
    return out;
  }
}

const dataOf = (r) => (r.json && typeof r.json === 'object' && 'data' in r.json ? r.json.data : r.json);
const first = (o, ...keys) => { for (const k of keys) if (o && o[k] !== undefined && o[k] !== null) return o[k]; return undefined; };

// ------------------------------------------------------------------------------------------------ api.log analizi
function readNew(file, fromSize) {
  try {
    const fd = fs.openSync(file, 'r');
    const size = fs.fstatSync(fd).size;
    const len = Math.max(0, size - fromSize);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, fromSize);
    fs.closeSync(fd);
    return buf.toString('utf8');
  } catch (_) {
    return '';
  }
}

/** [HATA <ref>] bloklari (yigin: dosya:satir) ve [DB-QUERY-ERROR] kayitlari. */
export function analyzeApiLog(text) {
  const errors = {};
  const lines = text.split(/\r?\n/);
  const frameLoc = (l) => {
    const m = /\(?((?:[A-Za-z]:)?[^()\s]+?\.js):(\d+):\d+\)?\s*$/.exec(l);
    return m ? { file: m[1].replace(/\\/g, '/').replace(/^.*\/server\//, 'server/'), line: Number(m[2]), raw: l.trim() } : null;
  };
  for (let i = 0; i < lines.length; i++) {
    const m = /^\[HATA ([0-9a-f]{12})\] (\S+) (\S+) -> (\d+)\s*(.*)$/.exec(lines[i]);
    if (!m) continue;
    // Kasitli 503 (ornegin OAuth/Apple-Google yapilandirilmamis): beklenmeyen hata degil
    if (Number(m[4]) === 503 && /^HttpError/.test(m[5] || '')) continue;
    const frames = [];
    let j = i + 1;
    while (j < lines.length && /^\s+at /.test(lines[j])) { frames.push(lines[j]); j++; }
    const locs = frames.map(frameLoc).filter(Boolean);
    const own = locs.filter((l) => /^server\/(src|scripts)\//.test(l.file));
    const caller = own.find((l) => l.file !== 'server/src/db.js') || own[0];
    errors[m[1]] = {
      method: m[2], path: m[3], status: Number(m[4]), message: (m[5] || '').slice(0, 300),
      own_frame: caller ? `${caller.file}:${caller.line}` : undefined,
      frames: own.slice(0, 4).map((l) => `${l.file}:${l.line}`),
    };
  }
  // B paketi (route_helpers.sendError): "[WP-B] error [KOD]: mesaj -- at <kare> | at <kare> ..." (X-Error-Ref basligi YOK)
  let wp = 0;
  const wpRe = /^\[WP-[A-Z]\] error(?: \[([^\]]*)\])?: (.*?) -- (.*)$/gm;
  let wm;
  while ((wm = wpRe.exec(text)) !== null) {
    const locs = wm[3].split(' | ').map((f) => frameLoc(f.trim())).filter(Boolean);
    const own = locs.filter((l) => /^server\/(src|scripts)\//.test(l.file));
    const caller = own.find((l) => l.file !== 'server/src/db.js') || own[0];
    errors[`wpb-${++wp}`] = { method: '', path: '', status: 500, message: `[${wm[1] || ''}] ${wm[2]}`.slice(0, 300), own_frame: caller ? `${caller.file}:${caller.line}` : undefined, frames: own.slice(0, 4).map((l) => `${l.file}:${l.line}`), no_ref: true };
  }
  const dbErrors = [];
  const re = /\[DB-QUERY-ERROR\] \{\s*text:\s*([\s\S]*?),\s*error:\s*(['"])([\s\S]*?)\2\s*\}/g;
  let mm;
  while ((mm = re.exec(text)) !== null) dbErrors.push({ sql: mm[1].replace(/'\s*\+\s*\r?\n\s*['"]/g, '').replace(/\s+/g, ' ').slice(0, 320), error: mm[3] });
  const other = (text.match(/^\[(DB-ERROR|UNHANDLED|FATAL)[^\n]*$/gm) || []).slice(0, 20);
  return { errors, dbErrors, other };
}

// ------------------------------------------------------------------------------------------------ sweep
/**
 * @param {object} o
 * @param {object} o.rt            runtimePaths()
 * @param {string} [o.apiBase]
 * @param {boolean} [o.quick]      daha az dusman deger
 * @param {string} [o.only]        yalniz bu on ek ile baslayan spec/akislar (ornegin 'auth.')
 * @param {Function} [o.log]
 */
export async function runSweep({ rt, apiBase = `http://127.0.0.1:${PORTS.api}/api/v1`, quick = false, only = '', log = () => {}, verbose = false }) {
  const acc = readAccounts(rt);
  if (!acc || !acc.users || !acc.homes) throw new Error('accounts.json (tohumlama) yok: once `up --stage2`');
  const logFile = rt.logs.api;
  const logStart = fs.existsSync(logFile) ? fs.statSync(logFile).size : 0;

  const findings = [];
  const stats = { requests: 0, by_status: {}, specs: 0, flows: 0, base_fail: 0, actors: 0 };
  const refs = [];
  const http = new Http(apiBase, (m, p, r) => {
    stats.requests++;
    const k = r.status === 0 ? 'ERR' : `${Math.floor(r.status / 100)}xx`;
    stats.by_status[k] = (stats.by_status[k] || 0) + 1;
  });

  const add = (f) => { findings.push(f); if (verbose) log('sweep_finding', f); };
  const sampleOf = (opts) => {
    const b = opts.raw !== undefined ? opts.raw : opts.body;
    const s = typeof b === 'string' ? b : JSON.stringify(b);
    return s ? s.slice(0, 160) : undefined;
  };
  /** istek yap + sonuc degerlendir. `expect`: beklenen durumlar (5xx dahil olabilir: ornegin yapilandirilmamis ozellik icin 503). */
  async function probe(label, method, path, opts = {}, expect = null, allow5xx = null) {
    const r = await http.call(method, path, opts);
    if ((r.status >= 500 || r.status === 0) && !(expect && expect.includes(r.status)) && !(allow5xx && allow5xx.includes(r.status))) {
      const ref = r.headers['x-error-ref'];
      if (ref) refs.push(ref);
      add({ kind: r.status === 0 ? 'ISTEK_HATASI' : 'SUNUCU_HATASI_5XX', label, method, path, status: r.status, ref, error: r.error, code: r.json && r.json.code, sample: sampleOf(opts) });
    } else if (expect && !expect.includes(r.status)) {
      add({ kind: 'BEKLENMEYEN_DURUM', label, method, path, status: r.status, expected: expect, code: r.json && r.json.code, message: r.json && r.json.message });
    }
    return r;
  }

  // ---------------------------------------------------------------- baglam (kullanicilar, cihazlar)
  const login = async (email, password) => {
    const r = await http.call('POST', '/auth/login', { body: { identifier: email, password } });
    if (r.status !== 200) throw new Error(`giris ${email} -> HTTP ${r.status} ${r.text.slice(0, 120)}`);
    const d = dataOf(r);
    return { token: first(d, 'access_token', 'token'), refresh: first(d, 'refresh_token'), id: first(d && d.user, 'id') };
  };
  const T = {};
  const ids = {};
  for (const key of ['super', 'staff', 'owner1', 'owner2']) {
    const u = acc.users[key];
    if (!u) continue;
    const s = await login(u.email, u.password);
    T[key] = s.token;
    ids[key] = s.id || u.id;
  }
  const API_KEY = (() => { try { return JSON.parse(fs.readFileSync(rt.secretsFile, 'utf8')).admin_api_key; } catch (_) { return null; } })();

  async function mkUser(label) {
    const email = `sw.${label}.${rnd(3)}@example.com`;
    const password = `Sweep-${rnd(6)}-Aa1`;
    const reg = await http.call('POST', '/auth/register', { body: { full_name: `Sweep ${label}`, email, password, phone: `+9055${num8()}` } });
    if (reg.status !== 201) throw new Error(`kayit ${label} -> HTTP ${reg.status} ${reg.text.slice(0, 160)}`);
    const s = await login(email, password);
    return { email, password, ...s };
  }
  async function mkDevice(model = 'ESP32-S3-POE-ETH-8DI-8RO') {
    const uid = `AHBU-S3-${rnd(3).toUpperCase()}`;
    const pin = String(Math.floor(1e5 + Math.random() * 8.9e5));
    const r = await http.call('POST', '/admin/inventory/register', { token: T.super, body: { device_uuid: uid, mac_address: `02:A5:${rnd(1)}:${rnd(1)}:${rnd(1)}:${rnd(1)}`.toUpperCase(), pin, model, batch_no: 'SWEEP' } });
    if (r.status !== 201) throw new Error(`envanter ${uid} -> HTTP ${r.status} ${r.text.slice(0, 160)}`);
    return { uid, pin, local_key: first(dataOf(r), 'local_key') };
  }
  async function mkHome(owner, name = 'Sweep Evi') {
    const dev = await mkDevice();
    const r = await http.call('POST', '/devices/claim', { token: owner.token, body: { device_uuid: dev.uid, setup_pin: dev.pin, home_name: name } });
    if (r.status !== 200) throw new Error(`claim ${dev.uid} -> HTTP ${r.status} ${r.text.slice(0, 160)}`);
    const d = dataOf(r);
    return { id: d.home_id, uid: dev.uid, pin: dev.pin, cred: d.device_credential, local_key: dev.local_key };
  }
  /** Tam aktor: sahip + ev + cihaz + uc noktalar + (aile uyesi, misafir) + zamanli kural. */
  async function mkActor(label, { members = true } = {}) {
    stats.actors++;
    const owner = await mkUser(`${label}O`);
    const home = await mkHome(owner, `Sweep ${label}`);
    const eps = dataOf(await http.call('GET', `/homes/${home.id}/endpoints`, { token: owner.token })) || [];
    const a = { owner, home, ep1: eps.find((e) => e.type === 'shutter') || eps[0], ep2: eps.find((e) => e.type !== 'shutter') || eps[1] };
    if (members) {
      a.member = await mkUser(`${label}M`);
      a.guest = await mkUser(`${label}G`);
      const i1 = await http.call('POST', `/homes/${home.id}/invitations`, { token: owner.token, body: { role: 'resident' } });
      const c1 = first(dataOf(i1), 'code', 'invite_code');
      if (c1) await http.call('POST', '/homes/join', { token: a.member.token, body: { code: c1 } });
      const i2 = await http.call('POST', `/homes/${home.id}/invitations`, { token: owner.token, body: { role: 'guest', duration_hours: 24, guest_name: 'Sweep Misafir' } });
      const c2 = first(dataOf(i2), 'code', 'invite_code');
      if (c2) await http.call('POST', '/homes/join', { token: a.guest.token, body: { code: c2 } });
    }
    const rr = await http.call('POST', `/homes/${home.id}/scheduled-rules`, { token: owner.token, body: { channel: 5, channel_type: 'relay', action: 'on', hour: 8, minute: 30, days_of_week: [1, 2, 3], label: 'sweep', enabled: true } });
    a.ruleId = first(dataOf(rr), 'id') || first(dataOf(rr) && dataOf(rr).rule, 'id');
    return a;
  }

  /** Hiz sinirlayicilar kullanici anahtarlidir: tekrar kosularda emergency-reset kotasi (10/sa) bitmesin diye gecici super kullanici. */
  async function mkSuper() {
    const email = `sw.su.${rnd(3)}@example.com`;
    const password = `Sweep-${rnd(6)}-Su1`;
    const c = await http.call('POST', '/admin/users', { token: T.super, body: { full_name: 'Sweep Super', email, password, phone: `+9055${num8()}`, role: 'super_user' } });
    if (c.status !== 201) return null;
    try { return await login(email, password); } catch (_) { return null; }
  }
  const sel = (name) => (only === '' || name.startsWith(only));
  const A = await mkActor('A');
  const X = await mkActor('X', { members: false });                // IDOR hedefi (baska ev)
  const D = await mkUser('xferD');
  const V = await mkUser('victimV');                               // admin PATCH/send-reset hedefi (devre disi birakilabilir)
  const S2 = (await mkSuper()) || { token: T.super };              // hiz sinirlayicilari (kullanici anahtarli) tuketilmesin diye ayri super kullanici
  const RE = await mkDevice();                                     // etiket yeniden uretimi hedefi (IN_STOCK, hicbir eve bagli degil; seed cihazlarina DOKUNULMAZ)
  const W = await mkUser('delW');                                  // hesap silme alan fuzz'u (yanlis parola: silinmez)

  // ---------------------------------------------------------------- alan/yol/sorgu fuzz motoru
  /**
   * @param {object} s
   * @param {string} s.id          spec adi
   * @param {string} s.m           yontem
   * @param {string} s.path        yol sablonu (':ad' yer tutucular)
   * @param {(a:object)=>string|null} s.token   aktor -> jeton (null = anonim)
   * @param {(a:object)=>object} [s.params]     aktor -> yol parametreleri
   * @param {(a:object)=>object} [s.body]
   * @param {string[]} [s.fields]  govde alanlari (dusman degerlerle)
   * @param {object} [s.query]
   * @param {string[]} [s.qfields]
   * @param {number[]} [s.ok]      baz istek icin beklenen durumlar
   * @param {boolean} [s.rotate]   aktoru her ~35 istekte yenile (hiz sinirlayicilar icin)
   * @param {boolean} [s.noShape]  govde sekli fuzz'u atla
   * @param {boolean} [s.noBase]   baz istegi atla (tek kullanimlik/yikici)
   */
  async function fuzz(s) {
    if (!sel(s.id)) return;
    stats.specs++;
    let actor = A;
    let uses = 0;
    const getActor = async () => {
      if (s.rotate && uses % 35 === 0 && uses > 0) actor = await mkActor(`r${rnd(2)}`, { members: !!s.needMembers });
      uses++;
      return actor;
    };
    const fill = (params) => s.path.replace(/:([A-Za-z_]+)/g, (_, k) => encodeURIComponent(String(params[k])));
    const tokenOf = (a) => (s.token ? s.token(a) || undefined : undefined);
    const bodyOf = (a) => (s.body ? s.body(a) : undefined);
    const paramsOf = (a) => (s.params ? s.params(a) : {});

    const run = async (label, { params, body, raw, ctype, query, expect } = {}) => {
      const a = await getActor();
      const p = { ...paramsOf(a), ...(params || {}) };
      const opts = { token: tokenOf(a), query: query || s.query };
      if (raw !== undefined) { opts.raw = raw; opts.ctype = ctype; } else if (body !== undefined || s.body) opts.body = body !== undefined ? body(a) : bodyOf(a);
      return probe(`${s.id} [${label}]`, s.m, fill(p), opts, expect || null, (s.ok || []).filter((x) => x >= 500));
    };

    if (!s.noBase) {
      const r = await run('taban', { expect: s.ok });
      if (s.ok && !s.ok.includes(r.status)) stats.base_fail++;
    }
    // yol parametreleri
    for (const k of Object.keys(paramsOf(A))) {
      for (const v of HOSTILE_ID) await run(`yol ${k}=${typeof v === 'string' ? v.slice(0, 20) : v}`, { params: { [k]: v } });
    }
    // govde alanlari
    if (s.body && s.fields) {
      for (const f of s.fields) {
        const strs = quick ? HOSTILE_STR.filter(([n], i) => i % 3 === 0 || ['nul-icinde', 'uuid-degil', 'uzun-5000', 'dev-sayi'].includes(n)) : HOSTILE_STR;
        const variants = [
          ...strs.map(([n, v]) => [`s:${n}`, v]),
          ...(quick ? HOSTILE_NUM.slice(0, 9) : HOSTILE_NUM).map((v) => [`n:${v}`, v]),
          ...HOSTILE_ANY.map((v, i) => [`t:${i}`, v]),
          ['eksik', undefined],
        ];
        for (const [vn, v] of variants) {
          await run(`alan ${f}=${vn}`, { body: (a) => { const b = bodyOf(a); if (v === undefined) delete b[f]; else b[f] = v; return b; } });
        }
      }
    }
    // sorgu parametreleri
    if (s.query && s.qfields) {
      for (const f of s.qfields) {
        for (const [vn, v] of [...HOSTILE_STR.filter(([n]) => n !== 'uzun-70000').slice(0, 24).map(([n, x]) => [`s:${n}`, x]), ...HOSTILE_NUM.map((x) => [`n:${x}`, x])]) {
          await run(`sorgu ${f}=${vn}`, { query: { ...s.query, [f]: v } });
        }
      }
    }
    // govde SEKLI
    if (s.body && !s.noShape) {
      for (const [n, raw, ctype] of shapeVariants()) await run(`sekil ${n}`, { raw, ctype });
    }
  }

  // ---------------------------------------------------------------- spec listesi
  const email = () => `fz.${rnd(4)}@example.com`;
  const phone = () => `+9055${num8()}`;
  const zero = '00000000-0000-0000-0000-000000000000';
  const specs = [
    // ---- AUTH
    { id: 'auth.register', m: 'POST', path: '/auth/register', token: () => null, body: () => ({ full_name: 'Fz User', email: email(), password: 'Fuzz-Pass-12345', phone: phone() }), fields: ['full_name', 'email', 'password', 'phone'], ok: [201] },
    { id: 'auth.login', m: 'POST', path: '/auth/login', token: () => null, body: (a) => ({ identifier: (a.member || A.member).email, password: (a.member || A.member).password }), fields: ['identifier', 'password'], ok: [200] },
    { id: 'auth.refresh', m: 'POST', path: '/auth/refresh', token: () => null, body: () => ({ refresh_token: 'x'.repeat(43) }), fields: ['refresh_token'], ok: [401] },
    { id: 'auth.logout', m: 'POST', path: '/auth/logout', token: () => null, body: () => ({ refresh_token: 'x'.repeat(43) }), fields: ['refresh_token'], ok: [200] },
    { id: 'auth.forgot', m: 'POST', path: '/auth/forgot-password', token: () => null, body: () => ({ identifier: email() }), fields: ['identifier'], ok: [200] },
    { id: 'auth.reset', m: 'POST', path: '/auth/reset-password', token: () => null, body: () => ({ identifier: A.member.email, code: '123456', new_password: 'New-Pass-123456' }), fields: ['identifier', 'code', 'token', 'new_password'], ok: [400, 401, 403, 429] },
    { id: 'auth.magic', m: 'POST', path: '/auth/magic-login', token: () => null, body: () => ({ token: 'x'.repeat(40) }), fields: ['token'], ok: [400, 401, 410] },
    { id: 'auth.service-login', m: 'POST', path: '/auth/service-login', token: () => null, body: () => ({ service_pin: '123456', technician_name: 'Fz Teknisyen' }), fields: ['service_pin', 'technician_name'], ok: [400, 401, 403, 429] },
    { id: 'auth.google', m: 'POST', path: '/auth/google', token: () => null, body: () => ({ id_token: 'a.b.c' }), fields: ['id_token'], ok: [400, 401, 503] },
    { id: 'auth.apple', m: 'POST', path: '/auth/apple', token: () => null, body: () => ({ identity_token: 'a.b.c', full_name: 'X', nonce: 'n' }), fields: ['identity_token', 'full_name', 'nonce'], ok: [400, 401, 503] },
    { id: 'auth.otp-send', m: 'POST', path: '/auth/otp/send', token: () => null, body: () => ({ phone: phone() }), fields: ['phone'], ok: [200, 400, 503] },
    { id: 'auth.otp-verify', m: 'POST', path: '/auth/otp/verify', token: () => null, body: () => ({ phone: phone(), code: '123456' }), fields: ['phone', 'code'], ok: [400, 401, 410] },
    { id: 'auth.me', m: 'GET', path: '/auth/me', token: (a) => a.member ? a.member.token : A.member.token, ok: [200] },
    { id: 'auth.homes', m: 'GET', path: '/auth/homes', token: (a) => a.owner.token, ok: [200] },
    { id: 'auth.change-password', m: 'POST', path: '/auth/change-password', token: () => D.token, body: () => ({ current_password: 'yanlis-parola-1', new_password: 'New-Pass-123456' }), fields: ['current_password', 'new_password'], ok: [400, 401, 403] },

    // ---- ADMIN
    { id: 'admin.users-list', m: 'GET', path: '/admin/users', token: () => T.super, query: { limit: 5, offset: 0 }, qfields: ['role', 'search', 'is_active', 'limit', 'offset'], ok: [200] },
    { id: 'admin.users-create', m: 'POST', path: '/admin/users', token: () => T.super, body: () => ({ full_name: 'Fz Admin User', email: email(), phone: phone(), role: 'user', admin_notes: 'x' }), fields: ['full_name', 'email', 'password', 'phone', 'role', 'admin_notes'], ok: [201] },
    { id: 'admin.users-get', m: 'GET', path: '/admin/users/:id', token: () => T.super, params: () => ({ id: ids.owner2 }), ok: [200] },
    { id: 'admin.users-patch', m: 'PATCH', path: '/admin/users/:id', token: () => T.super, params: () => ({ id: V.id }), body: () => ({ full_name: 'Sweep Kurban', phone: phone(), admin_notes: 'x' }), fields: ['full_name', 'phone', 'role', 'password', 'current_password', 'is_active', 'admin_notes'], ok: [200] },
    { id: 'admin.users-sendreset', m: 'POST', path: '/admin/users/:id/send-reset', token: () => T.super, params: () => ({ id: V.id }), ok: [200, 409, 429, 503], noShape: true },
    { id: 'admin.users-delete', m: 'DELETE', path: '/admin/users/:id', token: () => T.super, params: () => ({ id: zero }), noBase: true },
    { id: 'admin.service-summary', m: 'GET', path: '/admin/service-summary', token: () => T.super, ok: [200] },
    { id: 'admin.staff-list', m: 'GET', path: '/admin/users', token: () => T.staff, query: { limit: 5 }, qfields: ['role', 'search'], ok: [200, 403] },
    { id: 'admin.owner-forbidden', m: 'GET', path: '/admin/users', token: () => T.owner1, ok: [403] },

    // ---- ENVANTER
    { id: 'inventory.register', m: 'POST', path: '/admin/inventory/register', token: () => T.super, body: () => ({ device_uuid: `AHBU-S3-${rnd(3).toUpperCase()}`, mac_address: `02:A5:${rnd(1)}:${rnd(1)}:${rnd(1)}:${rnd(1)}`.toUpperCase(), pin: '654321', model: 'ESP32-S3-POE-ETH-8DI-8RO', batch_no: 'SWEEPFZ' }), fields: ['device_uuid', 'mac_address', 'pin', 'model', 'batch_no'], ok: [201] },
    { id: 'inventory.list', m: 'GET', path: '/admin/inventory', token: () => T.super, query: { limit: 5, offset: 0 }, qfields: ['status', 'batch_no', 'search', 'limit', 'offset'], ok: [200] },
    { id: 'inventory.list-staff', m: 'GET', path: '/admin/inventory', token: () => T.staff, query: { limit: 5 }, qfields: ['status', 'search'], ok: [200, 403] },
    { id: 'inventory.get', m: 'GET', path: '/admin/inventory/:uuid', token: () => T.super, params: () => ({ uuid: A.home.uid }), ok: [200] },
    { id: 'inventory.patch', m: 'PATCH', path: '/admin/inventory/:uuid/status', token: () => T.super, params: () => ({ uuid: X.home.uid }), body: () => ({ status: 'CLAIMED' }), fields: ['status'], ok: [200, 400, 409] },
    { id: 'inventory.delete', m: 'DELETE', path: '/admin/inventory/:uuid', token: () => T.super, params: () => ({ uuid: 'AHBU-S3-FFFFFF' }), noBase: true },
    { id: 'inventory.anonim', m: 'GET', path: '/admin/inventory', token: () => null, ok: [401, 403] },

    // ---- CIHAZ / CLAIM
    { id: 'devices.claim', m: 'POST', path: '/devices/claim', rotate: true, token: (a) => (a.guest || D).token, body: (a) => ({ device_uuid: X.home.uid, setup_pin: '000000', home_name: 'Fz Ev' }), fields: ['device_uuid', 'setup_pin', 'home_name', 'target_owner', 'otp_code'], ok: [403, 409, 423, 429] },
    { id: 'devices.request-otp', m: 'POST', path: '/devices/claim/request-otp', token: () => T.staff, body: () => ({ device_uuid: X.home.uid, target_owner: `x${rnd(3)}@example.com` }), fields: ['device_uuid', 'target_owner'], ok: [200, 400, 403, 404, 409, 429] },
    { id: 'devices.emergency', m: 'POST', path: '/devices/emergency-reset', token: () => T.super, body: () => ({ device_uuid: 'AHBU-S3-FFFFFE', confirm_uid: 'AHBU-S3-FFFFFE', reason: 'sweep dusman girdi denemesi' }), fields: ['device_uuid', 'confirm_uid', 'reason', 'new_owner_identifier'], ok: [400, 403, 404, 409, 429] },
    { id: 'devices.replace-board', m: 'POST', path: '/devices/replace-board', rotate: true, token: (a) => a.owner.token, body: (a) => ({ home_id: a.home.id, old_device_uuid: a.home.uid, new_device_uuid: 'AHBU-S3-FFFFFD', setup_pin: '111111', reason: 'sweep denemesi' }), fields: ['home_id', 'old_device_uuid', 'new_device_uuid', 'setup_pin', 'reason'], ok: [400, 403, 404, 409, 429] },
    { id: 'devices.command', m: 'POST', path: '/devices/:id/command', token: (a) => a.owner.token, params: (a) => ({ id: a.home.uid }), body: (a) => ({ home_id: a.home.id, command: { relay: 5, state: true } }), fields: ['home_id', 'command'], ok: [409] },
    { id: 'devices.command-cmd', m: 'POST', path: '/devices/:id/command', token: (a) => a.owner.token, params: (a) => ({ id: a.home.uid }), body: (a) => ({ home_id: a.home.id, command: { cmd: 'set_runtime', shutter: 1, sec: 24, id: 'abc123' } }), fields: ['command'], ok: [409], noShape: true },
    { id: 'devices.child-lock', m: 'POST', path: '/devices/child-lock', rotate: true, token: (a) => a.owner.token, body: (a) => ({ home_id: a.home.id, enabled: true }), fields: ['home_id', 'enabled'], ok: [409, 429] },
    { id: 'devices.child-lock-get', m: 'GET', path: '/devices/child-lock/:home_id', token: (a) => a.owner.token, params: (a) => ({ home_id: a.home.id }), ok: [200] },
    { id: 'devices.peace-get', m: 'GET', path: '/devices/peace-notification/:home_id', token: (a) => a.owner.token, params: (a) => ({ home_id: a.home.id }), ok: [200] },
    { id: 'devices.peace-put', m: 'PUT', path: '/devices/peace-notification/:home_id', token: (a) => a.owner.token, params: (a) => ({ home_id: a.home.id }), body: () => ({ enabled: true, notification_time: '23:15' }), fields: ['enabled', 'notification_time'], ok: [200] },
    { id: 'devices.peace-close-all', m: 'POST', path: '/devices/peace-notification/close-all', token: (a) => a.owner.token, body: (a) => ({ home_id: a.home.id }), fields: ['home_id'], ok: [200, 409] },
    { id: 'devices.diagnostic', m: 'GET', path: '/devices/diagnostic/:home_id', token: (a) => a.owner.token, params: (a) => ({ home_id: a.home.id }), ok: [200] },
    { id: 'devices.home-list', m: 'GET', path: '/devices/home/:home_id', token: (a) => a.owner.token, params: (a) => ({ home_id: a.home.id }), ok: [200] },

    // ---- EV KAPSAMLI CIHAZ
    { id: 'homedev.list', m: 'GET', path: '/homes/:homeId/devices', token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id }), ok: [200] },
    { id: 'homedev.local-key', m: 'GET', path: '/homes/:homeId/devices/:uuid/local-key', token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id, uuid: a.home.uid }), ok: [200] },
    { id: 'homedev.mqtt-credential', m: 'POST', path: '/homes/:homeId/devices/:uuid/mqtt-credential', rotate: true, token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id, uuid: a.home.uid }), ok: [200, 429], noShape: true },
    { id: 'homedev.commissioning', m: 'POST', path: '/homes/:homeId/commissioning', rotate: true, token: () => T.super, params: (a) => ({ homeId: a.home.id }), body: (a) => ({ device_uuid: a.home.uid, checks: { relays: { ok: true, detail: 'x' }, buttons: { ok: true }, shutters: { ok: true }, network: { ok: true }, cloud: { ok: true } }, notes: 'sweep' }), fields: ['device_uuid', 'checks', 'notes'], ok: [200, 429] },
    { id: 'homedev.commissioning-status', m: 'GET', path: '/homes/:homeId/commissioning-status', token: () => T.super, params: (a) => ({ homeId: a.home.id }), ok: [200] },

    // ---- ENDPOINT
    { id: 'endpoints.list', m: 'GET', path: '/homes/:home_id/endpoints', token: (a) => a.owner.token, params: (a) => ({ home_id: a.home.id }), ok: [200] },
    { id: 'endpoints.put', m: 'PUT', path: '/homes/:home_id/endpoints/:id', token: (a) => a.owner.token, params: (a) => ({ home_id: a.home.id, id: a.ep1 && a.ep1.id }), body: () => ({ name: 'Sweep Panjur', room: 'Salon', shutter_duration_sec: 22 }), fields: ['name', 'room', 'type', 'shutter_duration_sec'], ok: [200, 409] },
    { id: 'endpoints.control', m: 'POST', path: '/homes/:home_id/endpoints/:id/control', token: (a) => a.owner.token, params: (a) => ({ home_id: a.home.id, id: a.ep2 && a.ep2.id }), body: () => ({ cmd: 'on' }), fields: ['cmd', 'state', 'pos', 'value'], ok: [200, 400, 409] },

    // ---- MQTT KIMLIK
    { id: 'mqtt.credentials', m: 'POST', path: '/homes/:homeId/mqtt-credentials', rotate: true, token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id }), ok: [200], noShape: true },
    { id: 'mqtt.credentials-guest', m: 'POST', path: '/homes/:homeId/mqtt-credentials', token: (a) => (a.guest || A.guest).token, params: (a) => ({ homeId: (a.guest ? a : A).home.id }), ok: [200], noShape: true },

    // ---- DAVET / UYE
    { id: 'invite.create', m: 'POST', path: '/homes/:homeId/invitations', rotate: true, token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id }), body: () => ({ role: 'guest', duration_hours: 12, guest_name: 'Fz Misafir' }), fields: ['role', 'duration_hours', 'valid_from', 'valid_until', 'guest_name'], ok: [201, 429] },
    { id: 'invite.join', m: 'POST', path: '/homes/join', rotate: true, token: (a) => (a.guest || D).token, body: () => ({ code: 'ABCDEF1234' }), fields: ['code'], ok: [400, 404, 410, 429] },
    { id: 'invite.members', m: 'GET', path: '/homes/:homeId/members', token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id }), ok: [200] },
    { id: 'invite.remove', m: 'DELETE', path: '/homes/:homeId/members/:targetUserId', token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id, targetUserId: D.id }), ok: [200, 400, 404] },

    // ---- DEVIR
    { id: 'transfer.status', m: 'GET', path: '/homes/:homeId/transfer-status', token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id }), ok: [200] },
    { id: 'transfer.accept', m: 'POST', path: '/homes/transfer-accept', rotate: true, token: (a) => (a.guest || D).token, body: () => ({ transfer_code: 'ZZZZZZZZZZ' }), fields: ['transfer_code'], ok: [400, 404, 410, 429] },
    { id: 'transfer.cancel', m: 'POST', path: '/homes/:homeId/transfer-cancel', token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id }), ok: [200, 404, 409], noShape: true },
    { id: 'transfer.initiate', m: 'POST', path: '/homes/:homeId/transfer-initiate', rotate: true, token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id }), body: () => ({ target_identifier: `tg${rnd(3)}@example.com` }), fields: ['target_identifier'], ok: [201, 400, 404, 429] },

    // ---- SERVIS PIN
    { id: 'service.tokens', m: 'GET', path: '/homes/:home_id/service-tokens', token: (a) => a.owner.token, params: (a) => ({ home_id: a.home.id }), ok: [200] },
    { id: 'service.sessions', m: 'GET', path: '/homes/:home_id/service-sessions', token: (a) => a.owner.token, params: (a) => ({ home_id: a.home.id }), ok: [200] },

    // ---- ZAMANLI KURALLAR
    { id: 'rules.list', m: 'GET', path: '/homes/:homeId/scheduled-rules', token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id }), ok: [200] },
    { id: 'rules.create', m: 'POST', path: '/homes/:homeId/scheduled-rules', rotate: true, token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id }), body: () => ({ channel: 5, channel_type: 'relay', action: 'off', hour: 22, minute: 15, days_of_week: [0, 6], label: 'fz', enabled: true }), fields: ['channel', 'channel_type', 'action', 'hour', 'minute', 'days_of_week', 'label', 'enabled', 'device_id'], ok: [201, 200] },
    { id: 'rules.update', m: 'PUT', path: '/homes/:homeId/scheduled-rules/:ruleId', rotate: true, token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id, ruleId: a.ruleId }), body: () => ({ channel: 5, channel_type: 'relay', action: 'on', hour: 9, minute: 0, days_of_week: [1], label: 'fz2', enabled: true }), fields: ['channel', 'channel_type', 'action', 'hour', 'minute', 'days_of_week', 'label', 'enabled'], ok: [200] },
    { id: 'rules.delete', m: 'DELETE', path: '/homes/:homeId/scheduled-rules/:ruleId', token: (a) => a.owner.token, params: (a) => ({ homeId: a.home.id, ruleId: zero }), noBase: true },

    // ---- PUSH (Flutter: PUT /v1/me/push-tokens)
    { id: 'push.put', m: 'PUT', path: '/me/push-tokens', token: (a) => a.owner.token, body: () => ({ token: `fcm-${rnd(20)}`, platform: 'android', app_version: '1.0.0' }), fields: ['token', 'platform', 'app_version'], ok: [200] },
    { id: 'push.delete', m: 'DELETE', path: '/me/push-tokens', token: (a) => a.owner.token, body: () => ({ token: `fcm-${rnd(20)}` }), fields: ['token'], ok: [200, 429] },

    // ---- SERVIS PANELI / ETIKET YENIDEN URETIMI / DAVET ONIZLEME / HESAP SILME / DIAGNOSTIC (WP-B2/B3)
    { id: 'svc.subscribers', m: 'GET', path: '/service/subscribers', token: () => S2.token, query: { limit: 5, offset: 0 }, qfields: ['q', 'limit', 'offset'], ok: [200] },
    { id: 'inventory.reissue', m: 'POST', path: '/admin/inventory/:uuid/reissue-label', token: () => S2.token, params: () => ({ uuid: RE.uid }), ok: [200, 429], noShape: true },
    { id: 'join.preview', m: 'POST', path: '/homes/join-preview', token: (a) => (a.member || A.member).token, body: () => ({ code: 'ABC123' }), fields: ['code'], ok: [400, 403, 410, 429] },
    { id: 'auth.account-delete', m: 'DELETE', path: '/auth/account', token: () => W.token, body: () => ({ password: 'yanlis-parola-1' }), fields: ['password', 'current_password', 'confirm'], ok: [400, 401, 403, 409, 429] },
    { id: 'auth.magic-get', m: 'GET', path: '/auth/magic-login/:token', token: () => null, params: () => ({ token: 'x'.repeat(40) }), ok: [405] },
    { id: 'devices.diagnostic-q', m: 'GET', path: '/devices/diagnostic', token: (a) => a.owner.token, query: { home_id: A.home.id }, qfields: ['home_id'], ok: [200] },
    // Home Admin atama YIKICIDIR (zorla atama: ev uyelikleri silinir): ilk 35 istek taban aktorun evine gider; bu yuzden listenin SONUNDA
    { id: 'svc.assign-otp', m: 'POST', path: '/service/subscribers/:homeId/assign-admin/request-otp', rotate: true, token: () => S2.token, params: (a) => ({ homeId: a.home.id }), body: () => ({ full_name: 'Fz Hedef', email: email() }), fields: ['full_name', 'email', 'phone'], ok: [200, 400, 404, 409, 429] },
    { id: 'svc.assign-admin', m: 'POST', path: '/service/subscribers/:homeId/assign-admin', rotate: true, token: () => S2.token, params: (a) => ({ homeId: a.home.id }), body: () => ({ full_name: 'Fz Yonetici', email: email(), force: true, reason: 'sweep zorla atama gerekcesi' }), fields: ['full_name', 'email', 'phone', 'otp_code', 'force', 'reason'], ok: [200, 400, 403, 404, 409, 429] },
  ];

  // ---------------------------------------------------------------- akislar (gecerli girdi ile derin kod yollari)
  const flows = [];
  const flow = (name, fn) => { if (sel(name)) flows.push([name, fn]); };

  flow('flow.auth-lifecycle', async () => {
    const U = await mkUser('life');
    const lg = await http.call('POST', '/auth/login', { body: { identifier: U.email, password: U.password } });
    const r1 = first(dataOf(lg), 'refresh_token');
    const rot = await probe('flow.auth refresh (rotation)', 'POST', '/auth/refresh', { body: { refresh_token: r1 } }, [200]);
    const r2 = first(dataOf(rot), 'refresh_token');
    await probe('flow.auth refresh (kullanilmis token: aile iptal)', 'POST', '/auth/refresh', { body: { refresh_token: r1 } }, [401]);
    await probe('flow.auth refresh (iptal edilen aile)', 'POST', '/auth/refresh', { body: { refresh_token: r2 } }, [401]);
    const L = await login(U.email, U.password);
    await probe('flow.auth change-password', 'POST', '/auth/change-password', { token: L.token, body: { current_password: U.password, new_password: 'Changed-Pass-12345' } }, [200]);
    await probe('flow.auth eski parola', 'POST', '/auth/login', { body: { identifier: U.email, password: U.password } }, [401]);
    const L2 = await login(U.email, 'Changed-Pass-12345');
    await probe('flow.auth forgot', 'POST', '/auth/forgot-password', { body: { identifier: U.email } }, [200]);
    await probe('flow.auth logout', 'POST', '/auth/logout', { body: { refresh_token: L2.refresh } }, [200]);
    await probe('flow.auth logout-all', 'POST', '/auth/logout-all', { token: L2.token }, [200]);
    await probe('flow.auth me (iptal token)', 'GET', '/auth/me', { token: L2.token }, [401]);
  });

  flow('flow.admin-lifecycle', async () => {
    const mail = `sw.adm.${rnd(3)}@example.com`;
    const c = await probe('flow.admin create (parolasiz: pending_invite)', 'POST', '/admin/users', { token: T.super, body: { full_name: 'Sweep Pending', email: mail, phone: phone(), role: 'service_user' } }, [201]);
    const id = first(dataOf(c), 'id');
    if (!id) return;
    await probe('flow.admin get', 'GET', `/admin/users/${id}`, { token: T.super }, [200]);
    await probe('flow.admin patch', 'PATCH', `/admin/users/${id}`, { token: T.super, body: { full_name: 'Sweep Pending 2', admin_notes: 'n', is_active: true } }, [200]);
    await probe('flow.admin send-reset', 'POST', `/admin/users/${id}/send-reset`, { token: T.super }, [200]);
    await probe('flow.admin patch deactivate', 'PATCH', `/admin/users/${id}`, { token: T.super, body: { is_active: false } }, [200]);
    await probe('flow.admin delete (soft)', 'DELETE', `/admin/users/${id}`, { token: T.super }, [200]);
    const c2 = await probe('flow.admin create user', 'POST', '/admin/users', { token: T.super, body: { full_name: 'Sweep Hard', email: `sw.h.${rnd(3)}@example.com`, phone: phone(), role: 'user' } }, [201]);
    const id2 = first(dataOf(c2), 'id');
    if (id2) await probe('flow.admin delete (hard)', 'DELETE', `/admin/users/${id2}`, { token: T.super, query: { hard: 'true' } }, [200]);
    await probe('flow.admin staff kendini yukseltemez', 'PATCH', `/admin/users/${ids.staff}`, { token: T.staff, body: { role: 'super_user' } }, [403]);
  });

  flow('flow.inventory-lifecycle', async () => {
    const dev = await mkDevice();
    for (const st of ['SUSPENDED', 'IN_STOCK', 'REVOKED']) await probe(`flow.inventory patch ${st}`, 'PATCH', `/admin/inventory/${dev.uid}/status`, { token: T.super, body: { status: st } }, [200, 400, 409]);
    await probe('flow.inventory list filtre', 'GET', '/admin/inventory', { token: T.super, query: { status: 'REVOKED', search: dev.uid, batch_no: 'SWEEP', limit: 10, offset: 0 } }, [200]);
    await probe('flow.inventory delete', 'DELETE', `/admin/inventory/${dev.uid}`, { token: T.super }, [200, 409]);
    if (API_KEY) {
      const uid = `AHBU-S3-${rnd(3).toUpperCase()}`;
      await probe('flow.inventory api-key register', 'POST', '/admin/inventory/register', { headers: { 'X-Admin-Api-Key': API_KEY, Authorization: `Bearer ${API_KEY}` }, body: { device_uuid: uid, mac_address: `02:A5:${rnd(1)}:${rnd(1)}:${rnd(1)}:${rnd(1)}`.toUpperCase(), pin: '123456', model: 'M', batch_no: 'SWEEPKEY' } }, [201, 401, 403]);
    }
  });

  flow('flow.claim-staff-otp', async () => {
    const dev = await mkDevice();
    const customer = await mkUser('cust');
    const r = await probe('flow.claim request-otp (staff)', 'POST', '/devices/claim/request-otp', { token: T.staff, body: { device_uuid: dev.uid, target_owner: customer.email } }, [200, 403]);
    const code = first(dataOf(r), 'debug_code', 'otp_code', 'code');
    await probe('flow.claim staff (OTP olmadan)', 'POST', '/devices/claim', { token: T.staff, body: { device_uuid: dev.uid, setup_pin: dev.pin, target_owner: customer.email } }, [400, 403]);
    if (code) await probe('flow.claim staff (OTP ile)', 'POST', '/devices/claim', { token: T.staff, body: { device_uuid: dev.uid, setup_pin: dev.pin, target_owner: customer.email, otp_code: code } }, [200]);
    const dev2 = await mkDevice();
    for (let i = 0; i < 6; i++) await probe(`flow.claim yanlis PIN #${i + 1}`, 'POST', '/devices/claim', { token: customer.token, body: { device_uuid: dev2.uid, setup_pin: '000000' } }, [403, 423, 429]);
    await probe('flow.claim kilitliyken dogru PIN', 'POST', '/devices/claim', { token: customer.token, body: { device_uuid: dev2.uid, setup_pin: dev2.pin } }, [403, 423, 429]);
  });

  flow('flow.emergency-reset', async () => {
    const SU = (await mkSuper()) || { token: T.super };
    const owner = await mkUser('rst');
    const home = await mkHome(owner, 'Sweep Reset');
    const newOwner = await mkUser('rst2');
    await probe('flow.reset reassign', 'POST', '/devices/emergency-reset', { token: SU.token, body: { device_uuid: home.uid, confirm_uid: home.uid, reason: 'sweep acil sifirlama yeni sahip', new_owner_identifier: newOwner.email } }, [200]);
    const home2 = await mkHome(await mkUser('rst3'), 'Sweep Reset 2');
    await probe('flow.reset unclaim', 'POST', '/devices/emergency-reset', { token: SU.token, body: { device_uuid: home2.uid, confirm_uid: home2.uid, reason: 'sweep acil sifirlama stok' } }, [200]);
    await probe('flow.reset tekrar (stokta)', 'POST', '/devices/emergency-reset', { token: SU.token, body: { device_uuid: home2.uid, confirm_uid: home2.uid, reason: 'sweep acil sifirlama stok' } }, [200, 400, 404, 409]);
  });

  flow('flow.replace-board', async () => {
    const owner = await mkUser('rep');
    const home = await mkHome(owner, 'Sweep Pano');
    const fresh = await mkDevice();
    await probe('flow.replace pano degisimi', 'POST', '/devices/replace-board', { token: owner.token, body: { home_id: home.id, old_device_uuid: home.uid, new_device_uuid: fresh.uid, setup_pin: fresh.pin, reason: 'sweep pano degisimi' } }, [200, 409]);
    await probe('flow.replace eski cihaz tekrar', 'POST', '/devices/replace-board', { token: owner.token, body: { home_id: home.id, old_device_uuid: home.uid, new_device_uuid: fresh.uid, setup_pin: fresh.pin, reason: 'sweep pano degisimi' } }, [400, 404, 409]);
  });

  flow('flow.transfer', async () => {
    const owner = await mkUser('xfo');
    const target = await mkUser('xft');
    const home = await mkHome(owner, 'Sweep Devir');
    const init = await probe('flow.transfer initiate', 'POST', `/homes/${home.id}/transfer-initiate`, { token: owner.token, body: { target_identifier: target.email } }, [201]);
    const code = first(dataOf(init), 'transfer_code', 'code');
    await probe('flow.transfer status', 'GET', `/homes/${home.id}/transfer-status`, { token: owner.token }, [200]);
    await probe('flow.transfer iptal', 'POST', `/homes/${home.id}/transfer-cancel`, { token: owner.token }, [200]);
    const init2 = await probe('flow.transfer initiate #2', 'POST', `/homes/${home.id}/transfer-initiate`, { token: owner.token, body: { target_identifier: target.email } }, [201]);
    const code2 = first(dataOf(init2), 'transfer_code', 'code') || code;
    if (code2) {
      await probe('flow.transfer yanlis kullanici kabul', 'POST', '/homes/transfer-accept', { token: A.member.token, body: { transfer_code: code2 } }, [403, 404, 410]);
      await probe('flow.transfer kabul', 'POST', '/homes/transfer-accept', { token: target.token, body: { transfer_code: code2 } }, [200]);
      await probe('flow.transfer eski sahip erisimi', 'GET', `/homes/${home.id}/devices`, { token: owner.token }, [403, 404]);
      await probe('flow.transfer yeni sahip erisimi', 'GET', `/homes/${home.id}/devices`, { token: target.token }, [200]);
    }
  });

  flow('flow.service-pin', async () => {
    const owner = await mkUser('svo');
    const home = await mkHome(owner, 'Sweep Servis');
    const tk = await probe('flow.service-token uret', 'POST', `/homes/${home.id}/service-token`, { token: owner.token }, [201]);
    const pin = first(dataOf(tk), 'service_pin', 'pin');
    const login1 = await probe('flow.service-login', 'POST', '/auth/service-login', { body: { service_pin: pin, technician_name: 'Sweep Teknisyen' } }, [200]);
    const sTok = first(dataOf(login1), 'access_token');
    await probe('flow.service-login tekrar (tek kullanimlik)', 'POST', '/auth/service-login', { body: { service_pin: pin, technician_name: 'Sweep Teknisyen' } }, [401, 403, 410]);
    if (sTok) {
      await probe('flow.service oturumu: kendi evi', 'GET', `/homes/${home.id}/devices`, { token: sTok }, [200]);
      await probe('flow.service oturumu: baska ev', 'GET', `/homes/${A.home.id}/devices`, { token: sTok }, [403]);
      await probe('flow.service oturumu: mqtt kimligi', 'POST', `/homes/${home.id}/mqtt-credentials`, { token: sTok }, [200]);
      await probe('flow.service oturumu: komissioning', 'POST', `/homes/${home.id}/commissioning`, { token: sTok, body: { device_uuid: home.uid, checks: { relays: { ok: true }, buttons: { ok: true }, shutters: { ok: true }, network: { ok: true }, cloud: { ok: false, detail: 'x' } }, notes: 'servis' } }, [200]);
      await probe('flow.service oturumu: /auth/me', 'GET', '/auth/me', { token: sTok }, [200]);
      await probe('flow.service oturumu: logout-all reddedilir', 'POST', '/auth/logout-all', { token: sTok }, [403]);
    }
    await probe('flow.service sessions', 'GET', `/homes/${home.id}/service-sessions`, { token: owner.token }, [200]);
    await probe('flow.service revoke', 'POST', `/homes/${home.id}/service-access/revoke`, { token: owner.token }, [200]);
    if (sTok) await probe('flow.service revoke sonrasi', 'GET', `/homes/${home.id}/devices`, { token: sTok }, [401, 403]);
  });

  flow('flow.rules', async () => {
    const base = `/homes/${A.home.id}/scheduled-rules`;
    const cases = [
      { channel: 1, channel_type: 'shutter', action: 'open', hour: 0, minute: 0, days_of_week: [0, 1, 2, 3, 4, 5, 6], enabled: true },
      { channel: 8, channel_type: 'relay', action: 'toggle', hour: 23, minute: 59, days_of_week: [6], enabled: false },
      { channel: 1, channel_type: 'shutter', action: 'position', position: 40, hour: 12, minute: 0, days_of_week: [3], enabled: true },
      { channel: 5, channel_type: 'relay', action: 'on', hour: 24, minute: 0, days_of_week: [1] },
      { channel: 5, channel_type: 'relay', action: 'on', hour: 1, minute: 60, days_of_week: [1] },
      { channel: 5, channel_type: 'relay', action: 'on', hour: 1, minute: 0, days_of_week: [7] },
      { channel: 5, channel_type: 'relay', action: 'on', hour: 1, minute: 0, days_of_week: [1, 1] },
      { channel: 5, channel_type: 'relay', action: 'on', hour: 1, minute: 0, days_of_week: [] },
      { channel: 0, channel_type: 'relay', action: 'on', hour: 1, minute: 0, days_of_week: [1] },
      { channel: 99, channel_type: 'relay', action: 'on', hour: 1, minute: 0, days_of_week: [1] },
    ];
    const created = [];
    for (const [i, c] of cases.entries()) {
      const r = await probe(`flow.rules create #${i}`, 'POST', base, { token: A.owner.token, body: c }, [200, 201, 400]);
      const id = first(dataOf(r), 'id') || first(dataOf(r) && dataOf(r).rule, 'id');
      if (id) created.push(id);
    }
    for (const id of created) {
      await probe('flow.rules put', 'PUT', `${base}/${id}`, { token: A.owner.token, body: { channel: 5, channel_type: 'relay', action: 'off', hour: 10, minute: 10, days_of_week: [2], label: 'u', enabled: false } }, [200, 400]);
      await probe('flow.rules delete', 'DELETE', `${base}/${id}`, { token: A.owner.token }, [200, 204]);
      await probe('flow.rules delete (tekrar)', 'DELETE', `${base}/${id}`, { token: A.owner.token }, [404]);
    }
    await probe('flow.rules misafir yazamaz', 'POST', base, { token: A.guest.token, body: cases[0] }, [403]);
    await probe('flow.rules baska evin kurallari (IDOR)', 'GET', `/homes/${X.home.id}/scheduled-rules`, { token: A.owner.token }, [403, 404]);
  });

  flow('flow.label-reissue', async () => {
    const d = await mkDevice();
    const r = await probe('flow.reissue IN_STOCK', 'POST', `/admin/inventory/${d.uid}/reissue-label`, { token: S2.token }, [200, 429]);
    if (r.status !== 200) return;
    const out = dataOf(r) || {};
    const newPin = first(out, 'setup_pin');
    if (!newPin || newPin === d.pin) add({ kind: 'BEKLENMEYEN_DURUM', label: 'flow.reissue yeni PIN yok ya da eskisiyle ayni', method: 'POST', path: '/admin/inventory/:uuid/reissue-label' });
    const owner = await mkUser('reissueO');
    await probe('flow.reissue eski PIN ile claim reddedilir', 'POST', '/devices/claim', { token: owner.token, body: { device_uuid: d.uid, setup_pin: d.pin, home_name: 'Eski PIN' } }, [400, 401, 403, 409, 429]);
    await probe('flow.reissue yeni PIN ile claim', 'POST', '/devices/claim', { token: owner.token, body: { device_uuid: d.uid, setup_pin: newPin, home_name: 'Yeni PIN' } }, [200]);
    await probe('flow.reissue sahiplenilmis cihaz 409', 'POST', `/admin/inventory/${d.uid}/reissue-label`, { token: S2.token }, [409, 429]);
    await probe('flow.reissue staff 403', 'POST', `/admin/inventory/${RE.uid}/reissue-label`, { token: T.staff }, [403]);
    if (API_KEY) await probe('flow.reissue API anahtari KABUL EDILMEZ', 'POST', `/admin/inventory/${RE.uid}/reissue-label`, { headers: { 'X-Admin-Api-Key': API_KEY, Authorization: `Bearer ${API_KEY}` } }, [401, 403]);
  });

  flow('flow.join-preview', async () => {
    const P = await mkUser('prevU');
    const inv = await http.call('POST', `/homes/${A.home.id}/invitations`, { token: A.owner.token, body: { role: 'resident' } });
    const code = first(dataOf(inv), 'code', 'invite_code');
    if (!code) { add({ kind: 'SUPURME_AKIS_HATASI', label: 'flow.join-preview', error: 'davet kodu uretilemedi' }); return; }
    const pv = await probe('flow.join-preview gecerli kod', 'POST', '/homes/join-preview', { token: P.token, body: { code } }, [200]);
    if (pv.status === 200) {
      const pd = dataOf(pv) || {};
      if (!pd.home_name || pd.kind === undefined) add({ kind: 'BEKLENMEYEN_DURUM', label: 'flow.join-preview yanit alanlari (home_name/kind) eksik', method: 'POST', path: '/homes/join-preview' });
    }
    await probe('flow.join-preview ikinci onizleme (kod TUKETILMEDI)', 'POST', '/homes/join-preview', { token: P.token, body: { code } }, [200]);
    await probe('flow.join-preview anonim 401', 'POST', '/homes/join-preview', { body: { code } }, [401]);
    await probe('flow.join-preview katil', 'POST', '/homes/join', { token: P.token, body: { code } }, [200]);
    await probe('flow.join-preview kullanilmis kod 410', 'POST', '/homes/join-preview', { token: P.token, body: { code } }, [410]);
  });

  flow('flow.account-delete', async () => {
    const U1 = await mkUser('delSole');
    await mkHome(U1, 'Silinecek Ev');
    const r1 = await probe('flow.account-delete tek sahip (ev var) 409', 'DELETE', '/auth/account', { token: U1.token, body: { password: U1.password } }, [409]);
    if (r1.status === 409 && !(r1.json && r1.json.code === 'SOLE_OWNER')) add({ kind: 'BEKLENMEYEN_DURUM', label: 'flow.account-delete 409 kodu SOLE_OWNER degil', method: 'DELETE', path: '/auth/account', code: r1.json && r1.json.code });
    const U2 = await mkUser('delFree');
    await probe('flow.account-delete yanlis parola', 'DELETE', '/auth/account', { token: U2.token, body: { password: 'yanlis-parola-1' } }, [400, 401, 403]);
    await probe('flow.account-delete parolasiz', 'DELETE', '/auth/account', { token: U2.token }, [400, 401, 403]);
    await probe('flow.account-delete dogru parola', 'DELETE', '/auth/account', { token: U2.token, body: { password: U2.password } }, [200]);
    await probe('flow.account-delete silinen hesapla giris', 'POST', '/auth/login', { body: { identifier: U2.email, password: U2.password } }, [401, 403]);
    await probe('flow.account-delete eski jeton gecersiz', 'GET', '/auth/me', { token: U2.token }, [401]);
    const re = await probe('flow.account-delete ayni e-posta yeniden kayit (serbest kalmali)', 'POST', '/auth/register', { body: { full_name: 'Sweep delFree', email: U2.email, password: U2.password, phone: `+9055${num8()}` } }, [201]);
    if (re.status === 201) await probe('flow.account-delete yeniden kayitli hesap girisi', 'POST', '/auth/login', { body: { identifier: U2.email, password: U2.password } }, [200]);
    await probe('flow.account-delete staff 403', 'DELETE', '/auth/account', { token: T.staff, body: { password: 'x' } }, [403]);
  });

  flow('flow.service-panel', async () => {
    const H = await mkActor('svc', { members: false });
    const lst = await probe('flow.svc abone listesi', 'GET', '/service/subscribers?limit=5&q=Sweep', { token: S2.token }, [200]);
    const subs = first(dataOf(lst), 'subscribers');
    if (lst.status === 200 && !Array.isArray(subs)) add({ kind: 'BEKLENMEYEN_DURUM', label: 'flow.svc abone listesi: subscribers dizisi yok', method: 'GET', path: '/service/subscribers' });
    await probe('flow.svc abone listesi sahip 403', 'GET', '/service/subscribers', { token: A.owner.token }, [403]);
    await probe('flow.svc abone listesi staff (uyeligi olmayan evler gorunmez)', 'GET', '/service/subscribers?limit=5', { token: T.staff }, [200]);
    const tgt = `svc.t.${rnd(3)}@example.com`;
    const otp = await probe('flow.svc OTP iste (mevcut sahibe)', 'POST', `/service/subscribers/${H.home.id}/assign-admin/request-otp`, { token: S2.token, body: { full_name: 'Yeni Yonetici', email: tgt } }, [200, 429]);
    const dbg = first(dataOf(otp), 'debug_code');
    await probe('flow.svc kodsuz atama reddedilir', 'POST', `/service/subscribers/${H.home.id}/assign-admin`, { token: S2.token, body: { full_name: 'Yeni Yonetici', email: tgt } }, [400, 401, 403, 409, 429]);
    if (dbg) {
      await probe('flow.svc yanlis kodla atama', 'POST', `/service/subscribers/${H.home.id}/assign-admin`, { token: S2.token, body: { full_name: 'Yeni Yonetici', email: tgt, otp_code: dbg === '000000' ? '111111' : '000000' } }, [400, 401, 403, 409, 429]);
      await probe('flow.svc dogru kodla atama', 'POST', `/service/subscribers/${H.home.id}/assign-admin`, { token: S2.token, body: { full_name: 'Yeni Yonetici', email: tgt, otp_code: dbg } }, [200, 429]);
    }
    await probe('flow.svc staff zorla atama 403', 'POST', `/service/subscribers/${H.home.id}/assign-admin`, { token: T.staff, body: { full_name: 'Yeni Yonetici', email: `svc.s.${rnd(3)}@example.com`, force: true, reason: 'yetkisiz zorlama denemesi' } }, [403]);
    await probe('flow.svc super zorla atama (gerekce kisa) 400', 'POST', `/service/subscribers/${H.home.id}/assign-admin`, { token: S2.token, body: { full_name: 'Yeni Yonetici', email: `svc.f.${rnd(3)}@example.com`, force: true, reason: 'x' } }, [400]);
    await probe('flow.svc super zorla atama', 'POST', `/service/subscribers/${H.home.id}/assign-admin`, { token: S2.token, body: { full_name: 'Zorla Yonetici', email: `svc.z.${rnd(3)}@example.com`, force: true, reason: 'sweep: servis panelinden gerekceli zorla atama' } }, [200, 429]);
    await probe('flow.svc eski sahibin ev erisimi kalkti', 'GET', `/homes/${H.home.id}/devices`, { token: H.owner.token }, [403, 404]);
  });

  flow('flow.idor', async () => {
    const hx = X.home;
    const targets = [
      ['GET', `/homes/${hx.id}/devices`], ['GET', `/homes/${hx.id}/endpoints`], ['GET', `/homes/${hx.id}/members`], ['GET', `/homes/${hx.id}/devices/${hx.uid}/local-key`],
      ['POST', `/homes/${hx.id}/mqtt-credentials`], ['GET', `/devices/child-lock/${hx.id}`], ['GET', `/devices/diagnostic/${hx.id}`], ['GET', `/devices/peace-notification/${hx.id}`],
      ['GET', `/homes/${hx.id}/service-tokens`], ['GET', `/homes/${hx.id}/transfer-status`], ['POST', `/homes/${hx.id}/invitations`], ['GET', `/homes/${hx.id}/scheduled-rules`],
      ['POST', `/homes/${hx.id}/devices/${hx.uid}/mqtt-credential`], ['POST', `/homes/${hx.id}/service-token`],
    ];
    for (const [m, p] of targets) {
      const r = await probe(`flow.idor ${m} ${p.replace(hx.id, ':X').replace(hx.uid, ':uid')}`, m, p, { token: A.owner.token, body: m === 'POST' ? {} : undefined }, [403, 404]);
      if (r.status === 200 || r.status === 201) add({ kind: 'GUVENLIK_IDOR', label: `${m} ${p}`, status: r.status });
    }
    await probe('flow.idor komut baska eve', 'POST', `/devices/${hx.uid}/command`, { token: A.owner.token, body: { home_id: A.home.id, command: { relay: 5, state: true } } }, [403, 404]);
    await probe('flow.idor komut (home_id baskasi)', 'POST', `/devices/${A.home.uid}/command`, { token: A.owner.token, body: { home_id: hx.id, command: { relay: 5, state: true } } }, [403, 404]);
    await probe('flow.idor misafir panjur kalibrasyonu', 'PUT', `/homes/${A.home.id}/endpoints/${A.ep1 && A.ep1.id}`, { token: A.guest.token, body: { shutter_duration_sec: 30 } }, [403]);
    await probe('flow.idor misafir toplu komut', 'POST', `/devices/${A.home.uid}/command`, { token: A.guest.token, body: { home_id: A.home.id, command: { cmd: 'all_off' } } }, [403]);
    await probe('flow.idor aile uyesi kalibrasyon', 'PUT', `/homes/${A.home.id}/endpoints/${A.ep1 && A.ep1.id}`, { token: A.member.token, body: { shutter_duration_sec: 30 } }, [403]);
    await probe('flow.idor aile uyesi uye cikarma', 'DELETE', `/homes/${A.home.id}/members/${A.guest.id}`, { token: A.member.token }, [403]);
  });

  // gecerli akislar ONCE (hiz sinirlayici kotalari tuketilmeden), sonra dusman girdi taramasi
  for (const [name, fn] of flows) {
    stats.flows++;
    try {
      await fn();
    } catch (e) {
      add({ kind: 'SUPURME_AKIS_HATASI', label: name, error: e.message });
    }
  }
  for (const s of specs) {
    try {
      await fuzz(s);
    } catch (e) {
      add({ kind: 'SUPURME_ICI_HATA', label: s.id, error: e.message });
    }
  }

  // ---------------------------------------------------------------- api.log analizi
  await sleep(300);
  const logText = readNew(logFile, logStart);
  const an = analyzeApiLog(logText);
  for (const f of findings) {
    if (f.ref && an.errors[f.ref]) Object.assign(f, { server_log: an.errors[f.ref] });
  }
  const seen = new Set(refs);
  for (const [ref, e] of Object.entries(an.errors)) if (!seen.has(ref)) findings.push({ kind: 'SUNUCU_HATASI_LOGDA', ref, method: e.method, path: e.path, status: e.status, server_log: e });
  for (const d of an.dbErrors) findings.push({ kind: 'DB_SORGU_HATASI', ...d });
  for (const o of an.other) findings.push({ kind: 'SUNUCU_LOG_UYARISI', line: o });

  const bySig = {};
  for (const f of findings) {
    const norm = (f.path || '').replace(/[0-9a-f]{8}-[0-9a-f-]{27}/gi, ':id').replace(/AHBU-[A-Z0-9-]+/g, ':uid');
    const sig = [f.kind, f.method, norm, f.server_log && f.server_log.own_frame, f.error || f.message || (f.server_log && f.server_log.message) || f.code, f.sql && f.sql.slice(0, 120)].join('|');
    (bySig[sig] ||= { ...f, count: 0, labels: [] });
    bySig[sig].count++;
    if (f.label && bySig[sig].labels.length < 6) bySig[sig].labels.push(f.label);
  }
  const grouped = Object.values(bySig).sort((a, b) => (a.kind > b.kind ? 1 : -1));
  const report = { at: new Date().toISOString(), api: apiBase, quick, only, stats, findings: grouped, raw_findings: findings.length };
  fs.writeFileSync(`${rt.dir}/sweep_report.json`, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
  return report;
}
