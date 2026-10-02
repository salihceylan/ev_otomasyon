// Gomulu PostgreSQL 18 yasam dongusu (embedded-postgres paketinin ikili dosyalari).
//
//  - Turkce Windows yerel adi initdb'yi bozdugu icin: --locale=C --encoding=UTF8 --no-locale
//  - Baslatma/durdurma pg_ctl ile yapilir: embedded-postgres.stop() Windows'ta `taskkill /f` ile ZORLA oldurur
//    (kirli kapanis); pg_ctl stop -m fast temiz kapanis saglar.
//  - Sureç cikisinda (exit) senkron `pg_ctl stop` son care olarak calisir; sinyal isleyicileri opt-in
//    (installProcessCleanup) cunku supervisor kendi sirali kapanisini yonetir.
//  - Oksuz sureç temizligi: stopPgByDataDir() (run.js down) postmaster.pid + pg_ctl ile durdurur.
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import pg from 'pg';
import { DB, HOST, PORTS } from './config.js';
import { ensureDir, killTree, pidAlive, randomHex, sleep, waitFor } from './util.js';

export const INITDB_FLAGS = ['--locale=C', '--encoding=UTF8', '--no-locale'];

let binCache = null;
async function loadBinaries() {
  if (binCache) return binCache;
  const plat = process.platform === 'win32' ? 'windows' : process.platform;
  const pkg = `@embedded-postgres/${plat}-${process.arch}`;
  let mod;
  try {
    mod = await import(pkg);
  } catch (err) {
    throw new Error(`PostgreSQL ikili paketi yuklenemedi (${pkg}): ${err.message}. 'npm install' calistirin.`);
  }
  binCache = { postgres: mod.postgres, initdb: mod.initdb, pg_ctl: mod.pg_ctl };
  return binCache;
}

/** Komutu calistirir; 'exit' olayini bekler (yavru postgres boru tutsa bile takilmaz). */
function run(cmd, args, { timeoutMs = 120000, env } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
      env: { ...process.env, LC_MESSAGES: 'C', ...env },
    });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => { out += d.toString('utf8'); });
    child.stderr.on('data', (d) => { err += d.toString('utf8'); });
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`${path.basename(cmd)} ${timeoutMs} ms icinde bitmedi`));
    }, timeoutMs);
    child.once('error', (e) => { clearTimeout(timer); reject(e); });
    child.once('exit', (code) => {
      clearTimeout(timer);
      // boru tutan yavru surecler (postgres) icin akislari birakiyoruz
      setTimeout(() => { child.stdout.destroy(); child.stderr.destroy(); }, 50);
      resolve({ code, stdout: out, stderr: err });
    });
  });
}

function runSync(cmd, args, timeoutMs = 60000) {
  return spawnSync(cmd, args, { windowsHide: true, encoding: 'utf8', timeout: timeoutMs, env: { ...process.env, LC_MESSAGES: 'C' } });
}

export function readPostmasterPid(dataDir) {
  try {
    const first = fs.readFileSync(path.join(dataDir, 'postmaster.pid'), 'utf8').split(/\r?\n/)[0];
    const pid = Number.parseInt(first, 10);
    return Number.isInteger(pid) ? pid : null;
  } catch (_) {
    return null;
  }
}

export class PgManager {
  /**
   * @param {{dataDir:string, password:string, port?:number, user?:string, database?:string, host?:string, logFile?:string, log?:Function}} o
   */
  constructor(o) {
    if (!o || !o.dataDir || !o.password) throw new Error('PgManager: dataDir ve password zorunlu');
    this.dataDir = path.resolve(o.dataDir);
    this.password = o.password;
    this.port = o.port ?? PORTS.pg;
    this.user = o.user ?? DB.user;
    this.database = o.database ?? DB.name;
    this.host = o.host ?? HOST;
    this.logFile = o.logFile ?? path.join(path.dirname(this.dataDir), 'pg.log');
    this.log = o.log || (() => {});
    this.startedByUs = false;
    this.stopped = false;
    this.pgCtlPath = null;
    this.exitHandler = null;
  }

  get connectionString() {
    return `postgresql://${encodeURIComponent(this.user)}:${encodeURIComponent(this.password)}@${this.host}:${this.port}/${this.database}`;
  }

  get adminConnectionString() {
    return `postgresql://${encodeURIComponent(this.user)}:${encodeURIComponent(this.password)}@${this.host}:${this.port}/postgres`;
  }

  isInitialised() {
    return fs.existsSync(path.join(this.dataDir, 'PG_VERSION'));
  }

  async initdb() {
    const { initdb } = await loadBinaries();
    ensureDir(path.dirname(this.dataDir));
    const pwFile = path.join(os.tmpdir(), `qa-pgpw-${randomHex(6)}`);
    fs.writeFileSync(pwFile, `${this.password}\n`, { mode: 0o600 });
    try {
      this.log('pg_initdb', { dir: this.dataDir });
      const r = await run(initdb, [
        `--pgdata=${this.dataDir}`,
        '--auth=scram-sha-256',
        `--username=${this.user}`,
        `--pwfile=${pwFile}`,
        '--lc-messages=C',
        ...INITDB_FLAGS,
      ], { timeoutMs: 180000 });
      if (r.code !== 0) {
        throw new Error(`initdb basarisiz (kod ${r.code}): ${(r.stderr || r.stdout).trim().slice(0, 600)}`);
      }
    } finally {
      try { fs.unlinkSync(pwFile); } catch (_) { /* yok say */ }
    }
  }

  /** {running, pid} */
  async status() {
    const { pg_ctl } = await loadBinaries();
    this.pgCtlPath = pg_ctl;
    if (!fs.existsSync(path.join(this.dataDir, 'postmaster.pid'))) return { running: false, pid: null };
    const r = await run(pg_ctl, ['status', '-D', this.dataDir], { timeoutMs: 20000 });
    const m = /PID:\s*(\d+)/.exec(`${r.stdout}\n${r.stderr}`);
    return { running: r.code === 0, pid: m ? Number.parseInt(m[1], 10) : readPostmasterPid(this.dataDir) };
  }

  /** Gerekirse initdb yapar, sunucuyu baslatir (zaten calisiyorsa yeniden kullanir) ve veritabanini garanti eder. */
  async start({ timeoutSec = 90 } = {}) {
    const { pg_ctl } = await loadBinaries();
    this.pgCtlPath = pg_ctl;
    if (!this.isInitialised()) await this.initdb();

    const st = await this.status();
    if (st.running) {
      this.log('pg_reuse', { pid: st.pid, port: this.port });
    } else {
      ensureDir(path.dirname(this.logFile));
      const opts = [
        `-p ${this.port}`,
        `-c listen_addresses=${this.host}`,
        '-c max_connections=60',
        '-c shared_buffers=64MB',
        '-c synchronous_commit=off',
        '-c timezone=UTC',
        '-c log_timezone=UTC',
      ].join(' ');
      this.log('pg_starting', { port: this.port });
      const r = await run(pg_ctl, ['start', '-D', this.dataDir, '-w', '-t', String(timeoutSec), '-s', '-l', this.logFile, '-o', opts],
        { timeoutMs: (timeoutSec + 30) * 1000 });
      if (r.code !== 0) {
        throw new Error(`pg_ctl start basarisiz (kod ${r.code}): ${(r.stderr || r.stdout).trim().slice(0, 600)} (log: ${this.logFile})`);
      }
      this.startedByUs = true;
      this.stopped = false;
      this.#installExitHandler();
    }
    await this.ensureDatabase();
    const after = await this.status();
    this.log('pg_started', { pid: after.pid, port: this.port, db: this.database });
    return after;
  }

  async #adminClient() {
    const client = new pg.Client({ connectionString: this.adminConnectionString, connectionTimeoutMillis: 5000 });
    client.on('error', () => {});
    await client.connect();
    return client;
  }

  async ensureDatabase() {
    // pg_ctl -w hazir oldugunu soyler; yine de baglanti kabul edene kadar kisa bir yoklama
    const client = await waitFor(async () => {
      try { return await this.#adminClient(); } catch (_) { return null; }
    }, { timeoutMs: 30000, intervalMs: 250, label: 'PostgreSQL baglanti kabul etmedi' });
    try {
      const ex = await client.query('SELECT 1 FROM pg_database WHERE datname = $1', [this.database]);
      if (ex.rowCount === 0) {
        await client.query(`CREATE DATABASE ${client.escapeIdentifier(this.database)} ENCODING 'UTF8' TEMPLATE template0`);
        this.log('pg_db_created', { db: this.database });
      }
    } finally {
      await client.end().catch(() => {});
    }
  }

  /** Tek seferlik sorgu (yeni baglanti). */
  async query(sql, params, database = this.database) {
    const client = new pg.Client({
      connectionString: this.connectionString.replace(/\/[^/]*$/, `/${database}`),
      connectionTimeoutMillis: 5000,
    });
    client.on('error', () => {});
    await client.connect();
    try {
      return await client.query(sql, params);
    } finally {
      await client.end().catch(() => {});
    }
  }

  /** Temiz kapanis (pg_ctl stop -m fast). Zaten kapaliysa zararsiz. */
  async stop() {
    this.stopped = true;
    return stopPgByDataDir(this.dataDir, { log: this.log });
  }

  /** Veritabani dizinini siler (once durdurur). */
  async reset() {
    await this.stop();
    fs.rmSync(this.dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    this.log('pg_reset', { dir: this.dataDir });
  }

  #installExitHandler() {
    if (this.exitHandler) return;
    this.exitHandler = () => {
      if (!this.startedByUs || this.stopped) return;
      // exit olayinda yalniz senkron islem yapilabilir: son care temiz kapanis
      try {
        if (this.pgCtlPath && fs.existsSync(path.join(this.dataDir, 'postmaster.pid'))) {
          runSync(this.pgCtlPath, ['stop', '-D', this.dataDir, '-m', 'fast', '-w', '-t', '30', '-s'], 45000);
        }
      } catch (_) { /* yok say */ }
    };
    process.on('exit', this.exitHandler);
  }

  /**
   * Opt-in: SIGINT/SIGTERM/SIGBREAK/yakalanmayan hata durumunda temiz kapanis, sonra process.exit.
   * (Supervisor kendi sirali kapanisini yonetir ve bunu cagirmaz.)
   */
  installProcessCleanup() {
    const handler = (sig) => {
      this.stop().finally(() => process.exit(sig === 'uncaughtException' ? 1 : 0));
    };
    for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK']) process.once(sig, () => handler(sig));
    process.once('uncaughtException', (e) => { console.error(e); handler('uncaughtException'); });
  }
}

/**
 * Veri dizinindeki PostgreSQL'i durdurur: pg_ctl stop -m fast; olmazsa postmaster.pid'deki surec agaci zorla kapatilir.
 * Yonetici sureci olmadan da calisir (run.js down / oksuz temizligi).
 * @returns {Promise<{stopped:boolean, forced:boolean, reason?:string, pid?:number|null}>}
 */
export async function stopPgByDataDir(dataDir, { log = () => {} } = {}) {
  const dir = path.resolve(dataDir);
  const pidFile = path.join(dir, 'postmaster.pid');
  if (!fs.existsSync(pidFile)) return { stopped: false, forced: false, reason: 'not_running', pid: null };
  const pid = readPostmasterPid(dir);
  let bins;
  try { bins = await loadBinaries(); } catch (e) { bins = null; log('pg_stop_nobin', { error: e.message }); }

  if (bins) {
    const st = await run(bins.pg_ctl, ['status', '-D', dir], { timeoutMs: 20000 }).catch(() => ({ code: 1 }));
    if (st.code !== 0) {
      // eski/bozuk pid dosyasi: surec yok
      if (!pidAlive(pid)) return { stopped: false, forced: false, reason: 'stale_pid_file', pid };
    }
    const r = await run(bins.pg_ctl, ['stop', '-D', dir, '-m', 'fast', '-w', '-t', '45', '-s'], { timeoutMs: 75000 }).catch((e) => ({ code: 1, stderr: e.message }));
    if (r.code === 0) {
      log('pg_stopped', { pid, mode: 'fast' });
      return { stopped: true, forced: false, pid };
    }
    log('pg_stop_failed', { code: r.code, detail: String(r.stderr || r.stdout || '').trim().slice(0, 300) });
  }
  if (pid && pidAlive(pid)) {
    killTree(pid);
    for (let i = 0; i < 40 && pidAlive(pid); i++) await sleep(100);
    log('pg_killed', { pid });
    return { stopped: !pidAlive(pid), forced: true, pid };
  }
  return { stopped: true, forced: false, pid };
}
