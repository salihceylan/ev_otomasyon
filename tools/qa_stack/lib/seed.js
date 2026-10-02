// ASAMA Q2 (stage2): gercek REST API uzerinden tohumlama. Her adim bagimsizdir; basarisiz adim raporlanir ve
// (bagimlilik yoksa) diger adimlar surer.
//
// TOHUMLAMA IDEMPOTENTTIR: ayni yiginda ikinci/ucuncu `up --stage2` veya `seed` var olan hicbir varligi
// cogaltmaz, yeniden uretmez ve accounts.json'u degistirmez. Her adim once mevcut durumu OKUR; istenen durumdaysa
// hicbir sey yazmaz ("atlandi (zaten var)"). Yalnizca eksik / suresi dolmus / bozulmus olan yapilir:
//   - kullanici: accounts.json parolasiyla giris basariliysa dokunulmaz; hesap var ama parola uymuyorsa
//     (uygulamada degistirilmis) parola SQL ile accounts.json degerine GERI ALINIR
//   - zamanli kural: benzersizlik anahtari = ev + kural adi (label); ayni adli kural varsa eklenmez, ESKI
//     tohum calistirmalarinin biraktigi yinelenenler (ayni ad, en kucuk id korunur) silinir
//   - uyelik/davet: uye zaten dogru rolde ise davet URETILMEZ; 24 saatlik gecerli misafirin suresi dolduysa yenilenir
//   - servis PIN'i: accounts.json'daki PIN sunucuda hala "active" ise yenisi uretilmez (kullanilmis/suresi dolmus/
//     15 dk'dan az kalmis ise yenilenir)
//   - cihaz simulatoru: zaten bulutta cevrimiciyse MQTT kimligi yeniden uretilmez
//
// Uretilenler (hepsi .runtime/accounts.json'a yazilir, repoya DEGIL):
//   super_user (SQL, bcrypt)          : qa.super@example.com
//   kalici servis personeli           : qa.servis@example.com      (users.role='service_user' + home_users 'service_user')
//                                       admin API ile PAROLAYLA acilir (sunucu must_change_password=TRUE yazar);
//                                       tohum bunu SQL ile FALSE yapar: ilk giriste zorunlu parola ekrani CIKMAZ
//   sahip 1 + ev 1 + sahiplenilmis cihaz (simulatorle eslesen UID, 8 role, 2 panjur) + zamanli kurallar
//   aile uyesi (resident), gecerli misafir, SURESI DOLMUS misafir (SQL ile valid_until gecmise cekilir)
//   sahip 2 + ev 2 (baska ev; IDOR denemeleri)
//   envanterde IN_STOCK iki cihaz (biri provizyonsuz simulatorle eslesir: servis kurulum sihirbazi)
//   sahip 1'in urettigi servis PIN'i (2 saat gecerli; tek kullanimlik)
import bcrypt from 'bcryptjs';
import pg from 'pg';
import { PORTS } from './config.js';
import { fetchJson, randomPassword, waitFor } from './util.js';
import { DEVICE_PLAN, readAccounts, writeAccountsIfChanged } from './accounts.js';
import { STEP_STATUS, normalizeStepResult, summarizeSteps } from './seed_report.js';

export { STEP_STATUS, formatSeedSummary, formatStepLine, summarizeSteps } from './seed_report.js';

export class SeedError extends Error {
  constructor(message, detail) {
    super(message);
    this.name = 'SeedError';
    this.detail = detail;
  }
}

const first = (obj, ...keys) => {
  for (const k of keys) if (obj && obj[k] !== undefined && obj[k] !== null) return obj[k];
  return undefined;
};
const dataOf = (res) => (res.json && typeof res.json === 'object' && 'data' in res.json ? res.json.data : res.json);
const listOf = (d, key) => (Array.isArray(d) ? d : first(d, key) || []);

/** REST istemcisi: hata mesajlarina istek govdesi (parola) KONMAZ. */
export class QaApi {
  constructor(baseUrl) {
    this.base = baseUrl.replace(/\/+$/, '');
  }

  async request(method, path, { token, body, ok = [200, 201, 204], headers = {} } = {}) {
    const h = { ...headers };
    if (token) h.Authorization = `Bearer ${token}`;
    let res;
    try {
      res = await fetchJson(`${this.base}${path}`, { method, headers: h, body, timeoutMs: 20000 });
    } catch (e) {
      throw new SeedError(`${method} ${path}: istek basarisiz (${e.message})`);
    }
    if (!ok.includes(res.status)) {
      const code = res.json && res.json.code ? ` code=${res.json.code}` : '';
      const msg = res.json && res.json.message ? ` "${res.json.message}"` : '';
      throw new SeedError(`${method} ${path}: HTTP ${res.status}${code}${msg}`, { status: res.status, code: res.json && res.json.code });
    }
    return res;
  }
}

/** Cihaz simulatorunun yerel API'si (X-Device-Key). */
async function simCall(port, method, path, { key, body } = {}) {
  const headers = {};
  if (key) headers['X-Device-Key'] = key;
  return fetchJson(`http://127.0.0.1:${port}${path}`, { method, headers, body, timeoutMs: 8000 });
}

const PHONES = {
  super: '+905550001001', staff: '+905550001002', owner1: '+905550001003', owner2: '+905550001004',
  resident: '+905550001005', guest_valid: '+905550001006', guest_expired: '+905550001007',
};

export const USER_PLAN = [
  { key: 'super', name: 'QA Super Kullanici', email: 'qa.super@example.com', role: 'super_user' },
  { key: 'staff', name: 'QA Servis Personeli', email: 'qa.servis@example.com', role: 'service_user' },
  { key: 'owner1', name: 'QA Sahip Bir', email: 'qa.sahip1@example.com', role: 'user' },
  { key: 'owner2', name: 'QA Sahip Iki', email: 'qa.sahip2@example.com', role: 'user' },
  { key: 'resident', name: 'QA Aile Uyesi', email: 'qa.aile@example.com', role: 'user' },
  { key: 'guest_valid', name: 'QA Misafir Gecerli', email: 'qa.misafir@example.com', role: 'user' },
  { key: 'guest_expired', name: 'QA Misafir Suresi Dolmus', email: 'qa.misafir.eski@example.com', role: 'user' },
];

/** Ev 1'in zamanli kurallari. Benzersizlik anahtari: ev + `label` (planScheduledRules). */
export const SCHEDULED_RULES = Object.freeze([
  { channel: 5, channel_type: 'relay', action: 'on', hour: 19, minute: 30, days_of_week: [0, 1, 2, 3, 4, 5, 6], label: 'Aksam lambasi', enabled: true },
  { channel: 5, channel_type: 'relay', action: 'off', hour: 23, minute: 0, days_of_week: [0, 1, 2, 3, 4, 5, 6], label: 'Gece kapat', enabled: true },
  { channel: 1, channel_type: 'shutter', action: 'close', hour: 21, minute: 0, days_of_week: [1, 2, 3, 4, 5], label: 'Hafta ici panjur kapat', enabled: true },
  { channel: 1, channel_type: 'shutter', action: 'open', hour: 7, minute: 0, days_of_week: [0, 6], label: 'Hafta sonu panjur ac', enabled: false },
]);

/** Servis PIN'i bu sureden az kaliyorsa (veya yoksa/kullanildiysa) yenilenir; aksi halde dokunulmaz. */
export const SERVICE_PIN_REFRESH_MARGIN_MS = 15 * 60 * 1000;

// ------------------------------------------------------------------------------------------------ saf planlayicilar (test edilir)
/**
 * Zamanli kurallar icin eylem plani. Anahtar: `label` (ev zaten tek). Ayni adli birden fazla kural varsa
 * EN KUCUK id korunur, digerleri `remove`a girer (eski tohum calistirmalarinin biraktigi yinelenenler).
 * Plan disi (kullanicinin kendi ekledigi) kurallara dokunulmaz.
 * @param {{id:number,label?:string|null}[]} existing  GET /homes/:id/scheduled-rules
 * @param {readonly object[]} desired
 * @returns {{keep:{label:string,id:number}[], create:object[], remove:{label:string,id:number}[]}}
 */
export function planScheduledRules(existing, desired) {
  const byLabel = new Map();
  for (const r of existing || []) {
    if (!r || typeof r.label !== 'string') continue;
    if (!byLabel.has(r.label)) byLabel.set(r.label, []);
    byLabel.get(r.label).push(r);
  }
  const keep = [];
  const create = [];
  const remove = [];
  for (const d of desired) {
    const found = (byLabel.get(d.label) || []).slice().sort((a, b) => Number(a.id) - Number(b.id));
    if (found.length === 0) { create.push(d); continue; }
    keep.push({ label: d.label, id: found[0].id });
    for (const extra of found.slice(1)) remove.push({ label: d.label, id: extra.id });
  }
  return { keep, create, remove };
}

/**
 * accounts.json'daki servis PIN'i hala kullanilabilir mi? Sunucu PIN'i yalnizca ozet olarak sakladigindan eslestirme
 * `expires_at` ile yapilir: ayni bitis zamanli "active" kayit varsa (kullanilmamis, iptal edilmemis, suresi dolmamis)
 * ve en az `marginMs` kaldiysa true.
 * @param {{pin?:string, expires_at?:string}|null|undefined} servicePin
 * @param {{status?:string, expires_at?:string}[]} tokens  GET /homes/:id/service-tokens
 */
export function isServicePinUsable(servicePin, tokens, nowMs = Date.now(), marginMs = SERVICE_PIN_REFRESH_MARGIN_MS) {
  if (!servicePin || !servicePin.pin || !servicePin.expires_at) return false;
  const exp = Date.parse(servicePin.expires_at);
  if (!Number.isFinite(exp) || exp - nowMs < marginMs) return false;
  return (tokens || []).some((t) => t && t.status === 'active' && Math.abs(Date.parse(t.expires_at) - exp) < 2000);
}

// ------------------------------------------------------------------------------------------------ tohumlama
/**
 * @param {object} o
 * @param {object} o.rt              runtimePaths()
 * @param {string} o.dbUrl           PostgreSQL baglanti dizesi (super kullanici SQL'i + sure ayarlari icin)
 * @param {string} [o.apiBase]       varsayilan http://127.0.0.1:5000/api/v1
 * @param {Function} [o.log]
 * @param {boolean} [o.verifyOnline] cihazin bulutta cevrimici gorunmesini bekle (varsayilan true)
 * @returns {Promise<{ok:boolean, steps:{name:string, ok:boolean, status:string, detail?:string}[], summary:object, notes:string[]}>}
 */
export async function runSeed({ rt, dbUrl, apiBase = `http://127.0.0.1:${PORTS.api}/api/v1`, log = () => {}, verifyOnline = true }) {
  const api = new QaApi(apiBase);
  const acc = readAccounts(rt);
  if (!acc || !acc.devices) throw new SeedError('accounts.json (cihaz bolumu) yok: once `up` calistirin');
  acc.users ||= {};
  acc.homes ||= {};
  const steps = [];
  const notes = []; // dikkat gerektiren onarimlar (ornegin parolanin geri alinmasi): up/seed ozetinde gosterilir
  const save = () => writeAccountsIfChanged(rt, acc);

  const applied = (detail) => ({ status: STEP_STATUS.APPLIED, detail });
  const unchanged = (detail) => ({ status: STEP_STATUS.UNCHANGED, detail });
  const verified = (detail) => ({ status: STEP_STATUS.VERIFIED, detail });

  async function step(name, fn, { needs = [] } = {}) {
    const missing = needs.filter((n) => !steps.find((s) => s.name === n && s.ok));
    if (missing.length) {
      steps.push({ name, ok: false, status: STEP_STATUS.BLOCKED, detail: `engellendi (once basarisiz/eksik: ${missing.join(', ')})` });
      log('seed_step_blocked', { step: name, missing: missing.join(',') });
      return undefined;
    }
    // ara kayit (kismi ilerleme kaybolmasin): yazim hatasi adimi basarisiz SAYMAZ ve ayni adimi iki kez raporlamaz; son kayit siki
    const saveQuietly = () => {
      try { save(); } catch (e) { log('seed_save_failed', { step: name, error: e.message }); }
    };
    let r;
    try {
      r = normalizeStepResult(await fn());
    } catch (e) {
      steps.push({ name, ok: false, status: STEP_STATUS.FAILED, detail: e.message });
      log('seed_step_failed', { step: name, error: e.message });
      saveQuietly();
      return undefined;
    }
    steps.push({ name, ok: true, status: r.status, detail: r.detail });
    log('seed_step_ok', { step: name, status: r.status });
    saveQuietly();
    return r;
  }

  /** Tek kullanimlik SQL baglantisi. */
  async function withDb(fn) {
    const client = new pg.Client({ connectionString: dbUrl });
    client.on('error', () => {});
    await client.connect();
    try {
      return await fn(client);
    } finally {
      await client.end().catch(() => {});
    }
  }

  const user = (key) => acc.users[key];
  async function login(key) {
    const u = user(key);
    const res = await api.request('POST', '/auth/login', { body: { identifier: u.email, password: u.password } });
    const d = dataOf(res);
    u.id = u.id || first(d && d.user, 'id') || first(d, 'user_id');
    return first(d, 'access_token', 'token');
  }
  /** accounts.json parolasiyla giris; yalnizca 401 (parola uymuyor / hesap yok) -> null, diger hatalar yukari. */
  async function tryLogin(key) {
    try {
      return await login(key);
    } catch (e) {
      if (e.detail && e.detail.status === 401) return null;
      throw e;
    }
  }
  /**
   * accounts.json parolasi VERITABANINDAKI ozetle uyusuyor mu (ve hesap etkin mi)? REST girisi gerektirmez: sunucu girisi
   * IP basina 15 dk'da 30 istekle sinirlidir; tekrarlanan `seed`/`smoke` bu siniri tuketmesin. -> kullanici id | null
   */
  async function dbCredentialId(key) {
    const u = user(key);
    const row = (await withDb((c) => c.query(
      'SELECT id, password_hash, is_active, account_status FROM users WHERE LOWER(email) = LOWER($1)',
      [u.email],
    ))).rows[0];
    if (!row || row.is_active !== true || row.account_status !== 'active') return null;
    return bcrypt.compareSync(u.password, row.password_hash) ? row.id : null;
  }
  /**
   * Hesap VAR ama accounts.json parolasi uymuyor (uygulamada degistirilmis, ya da accounts.json yeniden uretilmis):
   * parola SQL ile accounts.json degerine geri alinir ve zorunlu parola degisimi bayragi kapatilir. Sonraki
   * `smoke`/giris denetimleri accounts.json'a guvenebilsin diye; QA veritabaninda sahte @example.com hesaplari icindir.
   */
  async function restorePassword(key) {
    const u = user(key);
    const hash = bcrypt.hashSync(u.password, 12);
    const r = await withDb((c) => c.query(
      'UPDATE users SET password_hash = $1, must_change_password = FALSE WHERE LOWER(email) = LOWER($2)',
      [hash, u.email],
    ));
    if (r.rowCount !== 1) throw new SeedError(`${key}: hesap veritabaninda bulunamadi (${r.rowCount}); \`node run.js reset\` gerekebilir`);
    notes.push(`${key} (${u.email}): accounts.json parolasi gecersizdi (uygulamada degistirilmis olabilir) -> accounts.json degerine geri alindi`);
    log('seed_password_restored', { user: key });
  }
  const tokens = {};
  /** Oturumu `kullanici_*` adiminda (her kosuda) acilan hesaplar: owner1, owner2. */
  const tok = (key) => tokens[key];
  /** Tembel giris: yalnizca gercekten gerektiginde (ilk kurulumda register yaniti zaten token verir). */
  async function tokenOf(key) {
    if (!tokens[key]) tokens[key] = await login(key);
    return tokens[key];
  }

  const homeId = () => acc.homes.home1.id;
  const listHomes = async (key) => listOf(dataOf(await api.request('GET', '/homes', { token: tok(key) })), 'homes');

  // ---------------------------------------------------------------- 0) sunucu hazir mi
  await step('api_hazir', async () => {
    await waitFor(async () => (await fetchJson(`${apiBase.replace(/\/api\/v1$/, '')}/health`, { timeoutMs: 3000 }).catch(() => ({ status: 0 }))).status === 200,
      { timeoutMs: 60000, label: 'sunucu /health' });
    return verified('sunucu /health 200');
  });

  // ---------------------------------------------------------------- 1) super kullanici (SQL, bcrypt)
  await step('super_kullanici_sql', async () => {
    const u = (acc.users.super ||= { email: USER_PLAN[0].email, password: randomPassword(), role: 'super_user', name: USER_PLAN[0].name });
    const wrote = await withDb(async (client) => {
      const cols = (await client.query("SELECT column_name FROM information_schema.columns WHERE table_name='users'")).rows.map((x) => x.column_name);
      const hasVerified = cols.includes('email_verified');
      const hasStatus = cols.includes('account_status');
      const cur = (await client.query(
        `SELECT id, password_hash, role, is_active${hasVerified ? ', email_verified' : ''}${hasStatus ? ', account_status' : ''} FROM users WHERE email = $1`,
        [u.email],
      )).rows[0];
      const inSync = cur && cur.role === 'super_user' && cur.is_active === true
        && (!hasVerified || cur.email_verified === true)
        && (!hasStatus || cur.account_status === 'active')
        && bcrypt.compareSync(u.password, cur.password_hash);
      if (inSync) { u.id = cur.id; return false; }
      const hash = bcrypt.hashSync(u.password, 12);
      const r = await client.query(
        `INSERT INTO users (email, password_hash, full_name, phone, role, is_active)
         VALUES ($1, $2, $3, $4, 'super_user', TRUE)
         ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash, role = 'super_user', is_active = TRUE
         RETURNING id`,
        [u.email, hash, u.name, PHONES.super],
      );
      u.id = r.rows[0].id;
      if (hasVerified) await client.query('UPDATE users SET email_verified = TRUE WHERE id = $1', [u.id]);
      if (hasStatus) await client.query("UPDATE users SET account_status = 'active' WHERE id = $1", [u.id]);
      return true;
    });
    return wrote ? applied('super_user olusturuldu/esitlendi') : unchanged('super_user zaten hazir (parola dogrulandi)');
  });

  // ---------------------------------------------------------------- 2) kalici servis personeli (admin API)
  // Admin API parolayla acilan hesaba must_change_password=TRUE yazar (ilk giriste zorunlu parola ekrani). QA'da servis
  // personeli ile dogrudan denemek icin bayrak SQL ile kapatilir; zorunlu parola akisi YENI olusturulan hesaplarla sinanir.
  await step('servis_personeli', async () => {
    const existed = !!acc.users.staff;
    const u = (acc.users.staff ||= { email: USER_PLAN[1].email, password: randomPassword(), role: 'service_user', name: USER_PLAN[1].name });
    const did = [];
    const knownId = existed ? await dbCredentialId('staff') : null;
    if (knownId) {
      u.id = knownId;
    } else {
      try {
        const res = await api.request('POST', '/admin/users', {
          token: await tokenOf('super'),
          body: { full_name: u.name, email: u.email, password: u.password, phone: PHONES.staff, role: 'service_user' },
        });
        u.id = first(dataOf(res), 'id');
        did.push('admin API ile olusturuldu');
      } catch (e) {
        if (!(e.detail && e.detail.status === 409)) throw e;
        await restorePassword('staff'); // hesap var, parola uyusmuyor
        did.push('parola accounts.json degerine geri alindi');
      }
    }
    const cleared = await withDb((c) => c.query(
      'UPDATE users SET must_change_password = FALSE WHERE LOWER(email) = LOWER($1) AND must_change_password IS TRUE',
      [u.email],
    ));
    if (cleared.rowCount > 0) did.push('zorunlu parola degisimi bayragi kapatildi');
    return did.length ? applied(did.join('; ')) : unchanged('service_user zaten hazir (parola dogrulandi, zorunlu degisim bayragi kapali)');
  }, { needs: ['super_kullanici_sql'] });

  // ---------------------------------------------------------------- 3) normal kullanicilar (kayit)
  // owner1/owner2'nin tokeni her kosuda gerekir (gercek REST girisi). Digerleri (aile/misafirler) yalnizca davet
  // katilimi icin gerekir: hesap var ve parolasi veritabaniyla uyusuyorsa giris YAPILMAZ.
  for (const key of ['owner1', 'owner2', 'resident', 'guest_valid', 'guest_expired']) {
    await step(`kullanici_${key}`, async () => {
      const plan = USER_PLAN.find((p) => p.key === key);
      const existed = !!acc.users[key];
      const u = (acc.users[key] ||= { email: plan.email, password: randomPassword(), role: 'user', name: plan.name });
      if (existed) {
        if (key === 'owner1' || key === 'owner2') {
          const t = await tryLogin(key);
          if (t) { tokens[key] = t; return unchanged('mevcut hesapla giris'); }
        } else {
          const id = await dbCredentialId(key);
          if (id) { u.id = id; return unchanged('mevcut hesap (parola dogrulandi; giris gerekmedi)'); }
        }
      }
      let how = 'kayit';
      try {
        const res = await api.request('POST', '/auth/register', { body: { full_name: u.name, email: u.email, password: u.password, phone: PHONES[key] } });
        const d = dataOf(res);
        u.id = first(d && d.user, 'id') || u.id;
        tokens[key] = first(d, 'access_token', 'token'); // kayit yaniti oturum verir: ayrica giris gerekmez
      } catch (e) {
        if (!(e.detail && e.detail.status === 409)) throw e;
        await restorePassword(key); // hesap var, accounts.json parolasi uymuyor
        how = 'parola accounts.json degerine geri alindi';
      }
      if (key === 'owner1' || key === 'owner2') tokens[key] ||= await login(key);
      return applied(how);
    });
  }

  // ---------------------------------------------------------------- 4) envanter (super JWT)
  await step('envanter', async () => {
    const notesInv = [];
    let registered = 0;
    // kayitli olanlar SQL ile bulunur: REST kaydi yalnizca eksik cihazlar icin (409 gurultusu ve super girisi gerekmez)
    const present = new Set((await withDb((c) => c.query(
      'SELECT UPPER(device_uuid) AS uid FROM device_inventory WHERE UPPER(device_uuid) = ANY($1::text[])',
      [DEVICE_PLAN.map((d) => String(acc.devices[d.key].uid).toUpperCase())],
    ))).rows.map((r) => r.uid));
    for (const d of DEVICE_PLAN) {
      const info = acc.devices[d.key];
      if (present.has(String(info.uid).toUpperCase())) { notesInv.push(`${d.key}:zaten var`); continue; }
      try {
        const res = await api.request('POST', '/admin/inventory/register', {
          token: await tokenOf('super'),
          body: { device_uuid: info.uid, mac_address: info.mac, pin: info.setup_pin, model: d.relays > 8 ? 'ESP32-S3-POE-ETH-8DI-8RO-EXT8' : 'ESP32-S3-POE-ETH-8DI-8RO', batch_no: 'BATCH-QA' },
        });
        const key = first(dataOf(res), 'local_key');
        if (key) info.local_key = key;
        save(); // yerel anahtar yanitta YALNIZ BIR KEZ doner: hemen kalicilastir
        registered += 1;
        notesInv.push(`${d.key}:kaydedildi`);
      } catch (e) {
        if (e.detail && e.detail.status === 409) notesInv.push(`${d.key}:zaten var`);
        else throw e;
      }
    }
    return registered ? applied(notesInv.join(' ')) : unchanged(notesInv.join(' '));
  }, { needs: ['super_kullanici_sql'] });

  // ---------------------------------------------------------------- 5) sahiplenme (claim)
  async function claim(ownerKey, deviceKey, homeName) {
    const info = acc.devices[deviceKey];
    const slot = deviceKey === 'home1' ? 'home1' : 'home2';
    const known = acc.homes[slot];
    // accounts.json'daki ev hala sahibin listesindeyse claim ISTENMEZ (gereksiz 409 + sayac gurultusu yok)
    if (known && known.id && (await listHomes(ownerKey)).some((h) => h.id === known.id)) return { homeId: known.id, cred: null, already: true };
    try {
      const res = await api.request('POST', '/devices/claim', {
        token: tok(ownerKey),
        body: { device_uuid: info.uid, setup_pin: info.setup_pin, home_name: homeName },
      });
      const d = dataOf(res);
      const newHomeId = first(d, 'home_id');
      acc.homes[slot] = { id: newHomeId, name: first(d, 'home_name') || homeName, owner: ownerKey, device: deviceKey };
      const cred = first(d, 'device_credential', 'mqtt_credentials', 'device_mqtt', 'mqtt');
      return { homeId: newHomeId, cred };
    } catch (e) {
      if (e.detail && e.detail.status === 409 && known) return { homeId: known.id, cred: null, already: true };
      throw e;
    }
  }
  let home1Cred = null;
  await step('claim_home1', async () => {
    const r = await claim('owner1', 'home1', 'QA Daire 1');
    home1Cred = r.cred;
    if (!r.homeId) throw new SeedError('claim yaniti home_id icermiyor');
    return r.already ? unchanged('zaten sahiplenilmis') : applied('sahiplenildi');
  }, { needs: ['envanter', 'kullanici_owner1'] });
  await step('claim_home2', async () => {
    const r = await claim('owner2', 'own2', 'QA Daire 2 (baska ev)');
    if (!r.homeId) throw new SeedError('claim yaniti home_id icermiyor');
    return r.already ? unchanged('zaten sahiplenilmis') : applied('sahiplenildi');
  }, { needs: ['envanter', 'kullanici_owner2'] });

  // ---------------------------------------------------------------- 6) hazir cihaz simulatorunu provizyonla + bulut kimligi
  await step('home1_simulator', async () => {
    const info = acc.devices.home1;
    const port = info.http_port;
    const home = acc.homes.home1;
    const did = [];
    // sunucudaki yerel anahtar: envanter yanitindan, yoksa sahibin GET local-key ucundan
    let serverKey = info.local_key;
    if (!serverKey) {
      const res = await api.request('GET', `/homes/${home.id}/devices/${encodeURIComponent(info.uid)}/local-key`, { token: tok('owner1') });
      serverKey = first(dataOf(res), 'local_key');
    }
    if (!serverKey) throw new SeedError('sunucunun yerel anahtari alinamadi');
    info.local_key = serverKey;
    const st = (await simCall(port, 'GET', '/api/status')).json;
    if (!st) throw new SeedError(`simulator ${port} cevap vermiyor`);
    if (st.provisioned === false) {
      const r = await simCall(port, 'POST', '/api/factory/init', { body: { local_key: serverKey, ap_pass: `ap-${serverKey}`.slice(0, 32) } });
      if (r.status !== 200) throw new SeedError(`factory/init HTTP ${r.status}`);
      did.push('provizyonlandi');
    } else if ((await simCall(port, 'GET', '/api/auth/check', { key: serverKey })).status !== 200) {
      const r = await simCall(port, 'POST', '/api/auth/rekey', { key: info.bootstrap_local_key, body: { new_key: serverKey } });
      if (r.status !== 200) throw new SeedError(`rekey HTTP ${r.status} (bootstrap anahtari uyusmuyor olabilir: reset)`);
      did.push('yerel anahtar sunucununkiyle degistirildi');
    }

    // bulut kimligi: simulator ZATEN bu evin konusuna bagli ve cevrimiciyse yeniden URETILMEZ (eski kimlik silinir, cihaz atilir)
    if (!did.length && !home1Cred && home.mqtt_topic_id) {
      const mqttOf = async () => {
        const r = await simCall(port, 'GET', '/__sim/state').catch(() => null);
        return r && r.json && r.json.mqtt;
      };
      let m = await mqttOf();
      if (m && m.configured && m.topic_id === home.mqtt_topic_id) {
        // yigin yeniden baslatildiysa simulator kayitli kimlikle baglaniyor olabilir: kimligi bozmadan kisa sure bekle
        if (!m.connected) {
          await waitFor(async () => { m = await mqttOf(); return !!(m && m.connected); }, { timeoutMs: 10000, intervalMs: 500, label: 'simulator bulut baglantisi' }).catch(() => null);
        }
        if (m && m.connected) return unchanged('simulator zaten provizyonlu ve bulutta cevrimici (bulut kimligi yeniden uretilmedi)');
      }
    }
    // bulut kimligi (claim yaniti tek seferliktir; yoksa mevcut kimlik yeniden uretilir)
    let cred = home1Cred;
    if (!cred) {
      const res = await api.request('POST', `/homes/${home.id}/devices/${encodeURIComponent(info.uid)}/mqtt-credential`, { token: tok('owner1') }).catch(() => null);
      if (res) cred = first(dataOf(res), 'device_credential') || dataOf(res);
    }
    if (!cred || !first(cred, 'username')) return applied('simulator provizyonlandi (bulut kimligi YOK: claim yaniti tek seferlik; reset gerekir)');
    const r = await simCall(port, 'POST', '/api/mqtt/config', {
      key: serverKey,
      body: { server: first(cred, 'host') || '10.0.2.2', port: Number(first(cred, 'port')) || PORTS.mqtt, user: first(cred, 'username'), pass: first(cred, 'password') },
    });
    if (r.status !== 200) throw new SeedError(`mqtt/config HTTP ${r.status}`);
    home.mqtt_topic_id = first(cred, 'topic_id');
    return applied(`${did.length ? `${did.join(', ')}; ` : ''}simulator bulut kimligi yazildi`);
  }, { needs: ['claim_home1'] });

  // ---------------------------------------------------------------- 7) aile uyesi ve misafirler (davet)
  async function invite(role, extra = {}) {
    const res = await api.request('POST', `/homes/${homeId()}/invitations`, { token: tok('owner1'), body: { role, ...extra } });
    const code = first(dataOf(res), 'code', 'invite_code');
    if (!code) throw new SeedError('davet kodu alinamadi');
    return code;
  }
  async function join(key, code) {
    try {
      await api.request('POST', '/homes/join', { token: await tokenOf(key), body: { code } });
    } catch (e) {
      if (!(e.detail && e.detail.status === 409)) throw e;
    }
  }
  /** Ev 1 uye listesi (sahip gorunumu: e-posta dahil). Uye zaten dogru roldeyse davet URETILMEZ. */
  async function memberOf(key) {
    const members = listOf(dataOf(await api.request('GET', `/homes/${homeId()}/members`, { token: tok('owner1') })), 'members');
    const u = user(key);
    const email = String(u.email).toLowerCase();
    return members.find((m) => (u.id && m.user_id === u.id) || String(m.email || '').toLowerCase() === email);
  }
  const roleMismatch = (key, m, expected) => {
    notes.push(`${key}: ev 1 uyeligi beklenmeyen rolde (${m.role}, beklenen ${expected}); dokunulmadi`);
    return unchanged(`uyelik var (rol=${m.role}, beklenen ${expected}); dokunulmadi`);
  };

  await step('aile_uyesi', async () => {
    const m = await memberOf('resident');
    if (m && m.role === 'resident') return unchanged('resident zaten aile uyesi (davet uretilmedi)');
    if (m) return roleMismatch('resident', m, 'resident');
    await join('resident', await invite('resident'));
    return applied('resident olarak katildi');
  }, { needs: ['claim_home1', 'kullanici_resident'] });

  await step('misafir_gecerli', async () => {
    const m = await memberOf('guest_valid');
    if (m && m.role === 'guest' && !m.is_expired) return unchanged(`misafir zaten gecerli (bitis ${m.valid_until}; davet uretilmedi)`);
    if (m && m.role !== 'guest') return roleMismatch('guest_valid', m, 'guest');
    await join('guest_valid', await invite('guest', { durationHours: 24, guestName: 'QA Misafir' }));
    return applied(m ? '24 saatlik misafir suresi dolmustu: yenilendi' : '24 saat gecerli misafir');
  }, { needs: ['claim_home1', 'kullanici_guest_valid'] });

  await step('misafir_suresi_dolmus', async () => {
    const m = await memberOf('guest_expired');
    if (m && m.role !== 'guest') return roleMismatch('guest_expired', m, 'guest');
    let joined = false;
    if (!m) {
      await join('guest_expired', await invite('guest', { durationHours: 2, guestName: 'QA Eski Misafir' }));
      joined = true;
    }
    const u = acc.users.guest_expired;
    const r = await withDb((c) => c.query(
      `UPDATE home_users SET valid_from = now() - interval '3 hours', valid_until = now() - interval '1 hour'
        WHERE home_id = $1 AND user_id = (SELECT id FROM users WHERE email = $2) AND role = 'guest'
          AND (valid_until IS NULL OR valid_until > now())`,
      [homeId(), u.email],
    ));
    if (r.rowCount === 1) return applied(`valid_until gecmise cekildi${joined ? '' : ' (uye vardi ama suresi dolmamisti)'}`);
    if (joined) throw new SeedError(`suresi dolmus misafir kaydi bulunamadi (${r.rowCount})`);
    return unchanged('misafir zaten suresi dolmus (davet uretilmedi)');
  }, { needs: ['claim_home1', 'kullanici_guest_expired'] });

  // ---------------------------------------------------------------- 8) kalici servis personeli ev uyeligi (SQL)
  await step('servis_personeli_uyeligi', async () => {
    const wrote = await withDb(async (client) => {
      const cur = await client.query(
        'SELECT role FROM home_users WHERE home_id = $1 AND user_id = (SELECT id FROM users WHERE email = $2)',
        [homeId(), acc.users.staff.email],
      );
      if (cur.rows[0] && cur.rows[0].role === 'service_user') return false;
      await client.query(
        `INSERT INTO home_users (home_id, user_id, role)
         VALUES ($1, (SELECT id FROM users WHERE email = $2), 'service_user')
         ON CONFLICT (home_id, user_id) DO UPDATE SET role = 'service_user'`,
        [homeId(), acc.users.staff.email],
      );
      return true;
    });
    return wrote ? applied('service_user olarak ev 1 uyesi yapildi') : unchanged('service_user olarak ev 1 uyesi (zaten)');
  }, { needs: ['claim_home1', 'servis_personeli'] });

  // ---------------------------------------------------------------- 9) zamanli kurallar (sahip 1): benzersizlik = ev + kural adi
  await step('zamanli_kurallar', async () => {
    const base = `/homes/${homeId()}/scheduled-rules`;
    const existing = listOf(dataOf(await api.request('GET', base, { token: tok('owner1') })), 'rules');
    const plan = planScheduledRules(existing, SCHEDULED_RULES);
    const idByLabel = new Map(plan.keep.map((k) => [k.label, k.id]));
    for (const r of plan.remove) await api.request('DELETE', `${base}/${r.id}`, { token: tok('owner1') });
    for (const r of plan.create) {
      const d = dataOf(await api.request('POST', base, { token: tok('owner1'), body: r }));
      idByLabel.set(r.label, first(d, 'id') || first(d && d.rule, 'id'));
    }
    acc.homes.home1.scheduled_rule_ids = SCHEDULED_RULES.map((r) => idByLabel.get(r.label));
    if (!plan.create.length && !plan.remove.length) return unchanged(`${SCHEDULED_RULES.length} kural zaten var`);
    return applied(`${plan.create.length} eklendi, ${plan.remove.length} yinelenen silindi, ${plan.keep.length} zaten vardi`);
  }, { needs: ['claim_home1'] });

  // ---------------------------------------------------------------- 10) servis PIN'i (ev sahibi uretir)
  await step('servis_pin', async () => {
    const tokensRes = dataOf(await api.request('GET', `/homes/${homeId()}/service-tokens`, { token: tok('owner1') }));
    const existing = acc.service_pin;
    if (isServicePinUsable(existing, listOf(tokensRes, 'tokens'))) {
      const left = Math.round((Date.parse(existing.expires_at) - Date.now()) / 60000);
      return unchanged(`PIN hala gecerli (~${left} dk kaldi; yenisi uretilmedi)`);
    }
    const res = await api.request('POST', `/homes/${homeId()}/service-token`, { token: tok('owner1') });
    const d = dataOf(res);
    const pin = first(d, 'service_pin', 'pin');
    if (!pin) throw new SeedError('servis PIN yanitta yok');
    acc.service_pin = { home: 'home1', pin, expires_at: first(d, 'expires_at'), note: '2 saat gecerli, tek kullanimlik (servis girisinde tuketilir)' };
    return applied(existing ? 'PIN kullanilmis/suresi dolmus: yenisi uretildi' : 'PIN uretildi');
  }, { needs: ['claim_home1'] });

  // ---------------------------------------------------------------- 11) dogrulama (okuma): uctan uca boru hatti
  await step('dogrulama_ev_listesi', async () => {
    const arr = await listHomes('owner1');
    if (!arr.find((h) => h.id === acc.homes.home1.id)) throw new SeedError('GET /homes sahip 1 icin ev 1 icermiyor');
    const arr2 = await listHomes('owner2');
    if (arr2.find((h) => h.id === acc.homes.home1.id)) throw new SeedError('GUVENLIK: sahip 2 ev 1\'i goruyor');
    return verified(`sahip 1: ${arr.length} ev, sahip 2: ${arr2.length} ev (izolasyon tamam)`);
  }, { needs: ['claim_home1', 'claim_home2'] });

  if (verifyOnline) {
    await step('dogrulama_cihaz_cevrimici', async () => {
      const uid = acc.devices.home1.uid;
      await waitFor(async () => {
        const res = await api.request('GET', `/homes/${homeId()}/devices`, { token: tok('owner1'), ok: [200] }).catch(() => null);
        if (!res) return false;
        const arr = listOf(dataOf(res), 'devices');
        const dev = arr.find((x) => first(x, 'device_uuid') === uid);
        return dev && (dev.online === true || dev.is_online === true);
      }, { timeoutMs: 30000, intervalMs: 1000, label: 'cihaz bulutta cevrimici gorunmedi' });
      return verified('cihaz bulutta cevrimici (MQTT -> kopru -> DB -> REST)');
    }, { needs: ['home1_simulator'] });
  }

  const summary = summarizeSteps(steps);
  // seeded_at = ILK basarili tohumlama zamani (tekrarlarda degismez: accounts.json'u gereksiz degistirmez)
  if (summary.ok && !acc.seeded_at) acc.seeded_at = new Date().toISOString();
  save();
  log('seed_done', { ok: summary.ok, failed: summary.failed + summary.blocked, applied: summary.applied, unchanged: summary.unchanged, verified: summary.verified });
  return { ok: summary.ok, steps, summary, notes };
}
