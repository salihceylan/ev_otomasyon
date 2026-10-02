// ASAMA Q2 (stage2): migration'lar + sunucu (server/) alt sureci. Q1'de ONAYLANMADI: sunucu kodu paralel yaziliyordu.
// Q2'de dogrulanacak maddeler docs/QA_STACK.md "Asama Q2" bolumundedir.
//
// Guvenlik: sunucu alt sureci MINIMAL ortamla (process.env kopyalanmaz) ve bos bir cwd'de calisir; boylece
// server/.env (uretim degerleri/SMTP) hicbir sekilde yuklenmez ve disariya e-posta cikmaz.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import bcrypt from 'bcryptjs';
import pg from 'pg';
import { DB, DEFAULT_CORS_ORIGINS, PORTS } from './config.js';
import { SERVER_DIR } from './paths.js';
import { ensureDir, fetchJson, killTree, pidAlive, randomB64Url, sleep, waitFor, writeJsonAtomic, readJson } from './util.js';

const KEEP_ENV = ['PATH', 'Path', 'SystemRoot', 'SYSTEMROOT', 'windir', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR', 'HOME', 'USERPROFILE',
  'COMSPEC', 'PATHEXT', 'LANG', 'OS', 'PROCESSOR_ARCHITECTURE', 'NUMBER_OF_PROCESSORS'];

/** Ust surecin ortamindan yalnizca calismak icin gerekenler (uretim sirlari/DATABASE_URL tasinmaz). */
export function minimalBaseEnv(src = process.env) {
  const out = {};
  for (const k of KEEP_ENV) if (src[k] !== undefined) out[k] = src[k];
  return out;
}

/**
 * CONTRACTS §6'daki sunucu ortami. Degerler yalnizca alt surece verilir (diske/loga yazilmaz).
 * @param {{secrets:object, dbUrl:string, publicHost:string, corsOrigins?:string[], ports?:typeof PORTS, mailCaFile?:string|null}} o
 */
export function buildServerEnv({ secrets, dbUrl, publicHost, corsOrigins = DEFAULT_CORS_ORIGINS, ports = PORTS, mailCaFile = null }) {
  return {
    ...minimalBaseEnv(),
    NODE_ENV: 'development',
    PORT: String(ports.api),
    BIND_HOST: '127.0.0.1',
    DATABASE_URL: dbUrl,
    JWT_SECRET: secrets.jwt_secret,
    PIN_PEPPER: secrets.pin_pepper,
    LOCAL_KEY_SECRET: secrets.local_key_secret,
    ADMIN_API_KEY: secrets.admin_api_key,
    // MQTT koprusu (backend_service superuser) - yeni adlar + gecis donemi eski adlar
    MQTT_HOST: '127.0.0.1',
    MQTT_PORT: String(ports.mqtt),
    MQTT_BACKEND_USER: secrets.mqtt_backend_user,
    MQTT_BACKEND_PASS: secrets.mqtt_backend_pass,
    MQTT_USER: secrets.mqtt_backend_user,
    MQTT_PASS: secrets.mqtt_backend_pass,
    // istemciye bildirilen adres (emulator: 10.0.2.2; Windows/Chrome: --public-host 127.0.0.1)
    MQTT_PUBLIC_HOST: publicHost,
    MQTT_PUBLIC_PORT: String(ports.mqtt),
    // kick: QA brokerinin EMQX v5 uyumlu kontrol ucu
    EMQX_API_URL: `http://127.0.0.1:${ports.brokerControl}`,
    EMQX_API_KEY: secrets.emqx_api_key,
    EMQX_API_SECRET: secrets.emqx_api_secret,
    ALLOW_DEBUG_OTP: 'true',
    CORS_ORIGINS: corsOrigins.join(','),
    // e-posta: yerel SMTP cukuruna (disari cikmaz)
    SMTP_HOST: '127.0.0.1',
    SMTP_PORT: String(ports.smtp),
    SMTP_SECURE: 'false',
    SMTP_USER: 'qa',
    SMTP_PASSWORD: secrets.smtp_pass,
    SMTP_PASS: secrets.smtp_pass,
    SMTP_FROM: 'AHBU QA <qa@qa.local>',
    // sunucunun mailer'i STARTTLS ister ve dogrulamayi kapatmaz: yalniz bu surec QA cukurunun sertifikasina guvenir
    ...(mailCaFile ? { NODE_EXTRA_CA_CERTS: mailCaFile } : {}),
  };
}

// ------------------------------------------------------------------------------------------------ migration
function runNode(args, { cwd, env, logFile, timeoutMs = 300000 }) {
  return new Promise((resolve) => {
    ensureDir(path.dirname(logFile));
    const out = fs.openSync(logFile, 'a');
    fs.writeSync(out, `\n=== ${new Date().toISOString()} node ${args.map((a) => path.basename(a)).join(' ')}\n`);
    const child = spawn(process.execPath, args, { cwd, env, stdio: ['ignore', out, out], windowsHide: true });
    const timer = setTimeout(() => { killTree(child.pid); }, timeoutMs);
    child.once('exit', (code, signal) => {
      clearTimeout(timer);
      fs.closeSync(out);
      resolve({ code, signal });
    });
    child.once('error', (err) => { clearTimeout(timer); fs.closeSync(out); resolve({ code: -1, error: err.message }); });
  });
}

/** dev_seeds / demo tohum dosyalari QA'da UYGULANMAZ (sabit parolali demo hesaplari). */
const isSeedFile = (name) => /seed/i.test(name);

/**
 * Bir alt surec YEREL OLARAK coktu mu? Windows/libuv: `process.exit()` bazen 'UV_HANDLE_CLOSING' assert cokmesi verir ve
 * surec NT hata koduyla biter (0xC0000409 = 3221226505); POSIX'te sinyalle olur. Normal basarisizlik (kod 1, 2 ...) DEGILDIR.
 */
export const isNativeCrash = (r) => !!r && (!!r.signal || (typeof r.code === 'number' && r.code >= 0xC0000000));

/**
 * Migration'lari uygular.
 *  - server/scripts/migrate.js varsa onu calistirir (MIGRATE_CONFIRM=ev_qa).
 *  - yoksa server/migrations/*.sql dosyalarini duz metin siralamasiyla (010 < 010b < 011) dosya basina bir
 *    transaction'da uygular; basarisizlari kaydeder ve DEVAM eder (strict=true ise durur).
 * @returns {Promise<{method:string, ok:boolean, applied?:string[], failed?:{file:string,error:string}[], code?:number}>}
 */
export async function applyMigrations({ rt, dbUrl, serverDir = SERVER_DIR, log = () => {}, strict = false }) {
  const migrateJs = path.join(serverDir, 'scripts', 'migrate.js');
  const env = { ...minimalBaseEnv(), NODE_ENV: 'development', DATABASE_URL: dbUrl, MIGRATE_CONFIRM: DB.name };
  ensureDir(rt.apiCwd);

  if (fs.existsSync(migrateJs)) {
    log('migrate_start', { method: 'scripts/migrate.js' });
    let r = await runNode([migrateJs], { cwd: rt.apiCwd, env, logFile: rt.logs.migrate });
    // migrate.js sonunda process.exit() cagirir: Windows'ta aralikli yerel cokme (kod 3221226505) olabilir. Migration'lar
    // idempotenttir ve dosya basina kaydedilir (yarim kalan tekrarda tamamlanir): yeniden calistirmak guvenlidir.
    for (let attempt = 1; attempt <= 2 && isNativeCrash(r); attempt++) {
      log('migrate_crashed_retry', { attempt, code: r.code, signal: r.signal });
      fs.appendFileSync(rt.logs.migrate, `${new Date().toISOString()} migrate.js yerel olarak coktu (kod ${r.code}); idempotent: yeniden deneniyor (${attempt}/2)\n`);
      r = await runNode([migrateJs], { cwd: rt.apiCwd, env, logFile: rt.logs.migrate });
    }
    log('migrate_done', { method: 'scripts/migrate.js', code: r.code });
    return { method: 'scripts/migrate.js', ok: r.code === 0, code: r.code };
  }

  // ---- yedek: dosyalari sirayla uygula
  const dir = path.join(serverDir, 'migrations');
  const files = fs.readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && /^\d.*\.sql$/i.test(e.name) && !isSeedFile(e.name))
    .map((e) => e.name)
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const client = new pg.Client({ connectionString: dbUrl });
  client.on('error', () => {});
  await client.connect();
  const applied = [];
  const failed = [];
  try {
    await client.query('CREATE TABLE IF NOT EXISTS qa_migrations_applied (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())');
    const done = new Set((await client.query('SELECT name FROM qa_migrations_applied')).rows.map((r) => r.name));
    for (const f of files) {
      if (done.has(f)) continue;
      const sql = fs.readFileSync(path.join(dir, f), 'utf8');
      const hasOwnTx = /^\s*(BEGIN|COMMIT)\s*;/im.test(sql);
      try {
        if (!hasOwnTx) await client.query('BEGIN');
        await client.query(sql);
        if (!hasOwnTx) await client.query('COMMIT');
        await client.query('INSERT INTO qa_migrations_applied (name) VALUES ($1) ON CONFLICT DO NOTHING', [f]);
        applied.push(f);
        log('migrate_file_ok', { file: f });
      } catch (err) {
        await client.query('ROLLBACK').catch(() => {});
        failed.push({ file: f, error: err.message });
        log('migrate_file_failed', { file: f, error: err.message });
        fs.appendFileSync(rt.logs.migrate, `${new Date().toISOString()} FAILED ${f}: ${err.message}\n`);
        if (strict) break;
      }
    }
  } finally {
    await client.end().catch(() => {});
  }
  return { method: 'fallback:server/migrations/*.sql (duz metin siralamasi, seed dosyalari haric)', ok: failed.length === 0, applied, failed };
}

/**
 * Migration'larla gelebilecek TUM kullanicilari (ornegin eski demo/sabit parolali hesaplar) etkisizlestirir:
 * pasif + rastgele parola. Yalnizca bir kez (state.json bayragi) ve tohumlamadan ONCE calisir.
 */
export async function quarantineMigrationUsers({ rt, dbUrl, log = () => {} }) {
  const state = readJson(rt.stateFile, {}) || {};
  if (state.users_quarantined) return { skipped: true };
  const client = new pg.Client({ connectionString: dbUrl });
  client.on('error', () => {});
  await client.connect();
  try {
    const t = await client.query("SELECT to_regclass('users') IS NOT NULL AS ok");
    if (!t.rows[0].ok) return { skipped: true, reason: 'users tablosu yok' };
    const hash = bcrypt.hashSync(randomB64Url(24), 10);
    const hasStatus = (await client.query("SELECT 1 FROM information_schema.columns WHERE table_name='users' AND column_name='account_status'")).rowCount > 0;
    const r = await client.query(
      `UPDATE users SET is_active = FALSE, password_hash = $1${hasStatus ? ", account_status = 'suspended'" : ''}`,
      [hash],
    );
    log('users_quarantined', { count: r.rowCount });
    writeJsonAtomic(rt.stateFile, { ...state, users_quarantined: true });
    return { skipped: false, count: r.rowCount };
  } finally {
    await client.end().catch(() => {});
  }
}

// ------------------------------------------------------------------------------------------------ sunucu sureci
export function tailFile(file, lines = 25) {
  try {
    const text = fs.readFileSync(file, 'utf8');
    return text.split(/\r?\n/).filter(Boolean).slice(-lines).join('\n');
  } catch (_) {
    return '';
  }
}

/**
 * node server/src/server.js'i alt surec olarak baslatir ve /health 200 donene kadar bekler.
 * @returns {Promise<{child:import('node:child_process').ChildProcess, pid:number, stop:()=>Promise<void>}>}
 */
export async function startApiServer({ rt, serverDir = SERVER_DIR, env, port = PORTS.api, log = () => {}, timeoutMs = 90000 }) {
  const entry = path.join(serverDir, 'src', 'server.js');
  if (!fs.existsSync(entry)) throw new Error(`sunucu girisi yok: ${entry}`);
  ensureDir(rt.apiCwd);
  const out = fs.openSync(rt.logs.api, 'a');
  fs.writeSync(out, `\n=== ${new Date().toISOString()} server baslatiliyor (QA ortami; sirlar loglanmaz)\n`);
  // Tanilama: yerel (native) cokmede / yakalanmayan istisnada Node tanilama raporu (JSON, yigin dahil) .runtime/api_reports/ altina yazilir.
  const reportDir = path.join(rt.dir, 'api_reports');
  ensureDir(reportDir);
  const nodeOptions = `--report-on-fatalerror --report-uncaught-exception --report-directory=${reportDir.split(path.sep).join('/')}`;
  const child = spawn(process.execPath, [entry], { cwd: rt.apiCwd, env: { ...env, NODE_OPTIONS: nodeOptions }, stdio: ['ignore', out, out], windowsHide: true });
  let exited = null;
  child.once('exit', (code, signal) => { exited = { code, signal }; log('api_exited', { code, signal }); });
  log('api_spawned', { pid: child.pid, port });

  const stop = async () => {
    if (!pidAlive(child.pid)) return;
    killTree(child.pid);
    for (let i = 0; i < 50 && pidAlive(child.pid); i++) await sleep(100);
  };

  try {
    await waitFor(async () => {
      if (exited) throw Object.assign(new Error(`sunucu cikti (kod ${exited.code})`), { fatal: true });
      try {
        const r = await fetchJson(`http://127.0.0.1:${port}/health`, { timeoutMs: 2000 });
        return r.status === 200;
      } catch (_) { return false; }
    }, { timeoutMs, intervalMs: 300, label: 'sunucu /health' });
  } catch (err) {
    await stop();
    const tail = tailFile(rt.logs.api, 25);
    throw new Error(`${err.message}\n--- api.log (son satirlar) ---\n${tail}`);
  }
  return { child, pid: child.pid, stop };
}
