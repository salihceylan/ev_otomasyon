#!/usr/bin/env node
'use strict';

// ==============================================================================
// AHBU Akilli Ev - Migration calistiricisi (WP-C)                    [plan C4]
// ==============================================================================
//
// Eski `run_011.js`, `run_migration_007..010.js` gibi tek tek betiklerin YERINE gecer
// (hepsi silindi; sabit baglanti dizeleri/parolalar iceriyorlardi).
//
// KULLANIM (server/ dizininden):
//   node scripts/migrate.js --status            Durumu goster (salt okunur)
//   node scripts/migrate.js --dry-run           Bekleyenleri goster, DEGISTIRME
//   MIGRATE_CONFIRM=<veritabani_adi> node scripts/migrate.js            Bekleyenleri uygula
//   MIGRATE_CONFIRM=<veritabani_adi> node scripts/migrate.js --to 022   022'ye (dahil) kadar uygula
//   MIGRATE_CONFIRM=<veritabani_adi> node scripts/migrate.js --baseline 17
//        Mevcut (elle migrate edilmis) canli veritabanini 17'ye KADAR "uygulanmis" olarak isaretler
//        (dosyalari CALISTIRMAZ). Yalnizca schema_migrations bossa ve bilinen tablolar varsa.
//
// GUVENLIK
//   - Hedef `DATABASE_URL`'den okunur (sabit baglanti dizesi YOK); hedef sunucu:port/veritabani
//     ACIKCA yazdirilir (parola yazdirilmaz).
//   - Degisiklik yapan her mod `MIGRATE_CONFIRM=<veritabani_adi>` ister. Aksi halde islem YAPILMAZ.
//   - Her migration dosyasi TEK transaction'da calisir ve schema_migrations kaydi ayni transaction'dadir.
//     Dosya icindeki BEGIN/COMMIT sarmalayicilari (eski dosyalarda var) otomatik sokulur.
//     Transaction disi gereken nadir komutlar icin dosyanin ilk satirlarina `-- migrate:no-transaction`.
//   - Ayni anda tek calistirici (pg_try_advisory_lock). Uygulanmis dosyanin icerigi degistiyse
//     (checksum) durur. `lock_timeout` 15 sn (MIGRATE_LOCK_TIMEOUT_MS), statement_timeout KAPALI.
//   - migrations/dev_seeds/ burada ASLA calismaz (yalnizca `scripts/seed_dev.js`).
//
// Dosya adi siralamasi: duz metin (kod birimi) siralamasi. Ornek: 010_... < 010b_... < 011_...
// Cikis kodlari: 0 basarili, 1 hata, 2 kullanim/onay hatasi.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { parseDatabaseUrl, describeTarget, assertConfirmed, TargetError } = require('./lib/target');

const MIGRATIONS_DIR = path.join(__dirname, '..', 'migrations');
const ADVISORY_LOCK_KEY = 727274; // 'EV' + 'MG' (keyfi sabit)
const NO_TX_DIRECTIVE = /^\s*--\s*migrate:no-transaction\b/m;
const BASELINE_REQUIRED_TABLES = ['users', 'homes', 'home_users', 'devices', 'endpoints'];

const CREATE_TABLE_SQL =
  'CREATE TABLE IF NOT EXISTS schema_migrations (' +
  'name TEXT PRIMARY KEY, version INTEGER NOT NULL, checksum TEXT, baseline BOOLEAN NOT NULL DEFAULT FALSE, ' +
  'applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), execution_ms INTEGER)';

// ------------------------------------------------------------------------------
// Saf yardimcilar
// ------------------------------------------------------------------------------

/** Satir sonlari normalize edilmis metnin SHA-256 ozeti (Windows/Linux fark etmesin). */
function checksum(sql) {
  return crypto.createHash('sha256').update(String(sql).replace(/\r\n/g, '\n'), 'utf8').digest('hex');
}

/** "010b_x.sql" -> 10 ; sayiyla baslamiyorsa null. */
function versionOf(name) {
  const m = /^(\d+)/.exec(name);
  return m ? parseInt(m[1], 10) : null;
}

/**
 * migrations/ dizinindeki UST DUZEY *.sql dosyalari (alt dizinler, ornegin dev_seeds, DAHIL DEGIL).
 * Siralama: duz metin (localeCompare KULLANILMAZ: yerel ayara gore degismesin).
 * @returns {Array<{name:string, version:number}>}
 */
function listMigrationFiles(dir = MIGRATIONS_DIR, fsApi = fs) {
  const names = fsApi
    .readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && /\.sql$/i.test(e.name))
    .map((e) => e.name);
  const files = names.map((name) => {
    const version = versionOf(name);
    if (version === null) {
      throw new Error(`Migration dosya adi sayiyla baslamali: ${name}`);
    }
    return { name, version };
  });
  files.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return files;
}

/**
 * SQL metninde yorumlari, tirnakli metinleri ve dolar-tirnakli govdeleri bosluga cevirir
 * (konumlar korunur). Yalnizca statik denetim icindir.
 */
function maskSql(sql) {
  const n = sql.length;
  let out = '';
  let i = 0;
  while (i < n) {
    const c = sql[i];
    const d = sql[i + 1];
    if (c === '-' && d === '-') {
      let j = sql.indexOf('\n', i);
      if (j === -1) j = n;
      out += ' '.repeat(j - i);
      i = j;
      continue;
    }
    if (c === '/' && d === '*') {
      let depth = 1;
      let j = i + 2;
      while (j < n && depth > 0) {
        if (sql[j] === '/' && sql[j + 1] === '*') {
          depth++;
          j += 2;
        } else if (sql[j] === '*' && sql[j + 1] === '/') {
          depth--;
          j += 2;
        } else {
          j++;
        }
      }
      out += ' '.repeat(j - i);
      i = j;
      continue;
    }
    if (c === "'") {
      let j = i + 1;
      while (j < n) {
        if (sql[j] === "'" && sql[j + 1] === "'") {
          j += 2;
          continue;
        }
        if (sql[j] === "'") {
          j++;
          break;
        }
        j++;
      }
      out += ' '.repeat(j - i);
      i = j;
      continue;
    }
    if (c === '$') {
      const m = /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(i, i + 80));
      if (m) {
        const tag = m[0];
        const end = sql.indexOf(tag, i + tag.length);
        const j = end === -1 ? n : end + tag.length;
        out += ' '.repeat(j - i);
        i = j;
        continue;
      }
    }
    out += c;
    i++;
  }
  return out;
}

/**
 * Dosyanin basindaki `BEGIN;` ve sonundaki `COMMIT;` sarmalayicilarini sokar (yorumlar korunur);
 * migrate.js zaten dosyayi tek transaction'da calistirir.
 * @returns {{sql:string, stripped:boolean}}
 */
function stripTransactionWrapper(sql) {
  let text = String(sql);
  let stripped = false;

  const head = /^((?:\s|--[^\n]*\n|\/\*[\s\S]*?\*\/)*)(?:BEGIN|START\s+TRANSACTION)(?:\s+(?:WORK|TRANSACTION))?\s*;/i;
  const h = head.exec(text);
  if (h) {
    text = h[1] + text.slice(h[0].length);
    stripped = true;
  }

  const tail = /\bCOMMIT(?:\s+(?:WORK|TRANSACTION))?\s*;((?:\s|--[^\n]*(?:\n|$)|\/\*[\s\S]*?\*\/)*)$/i;
  const t = tail.exec(text);
  if (t) {
    text = text.slice(0, t.index) + t[1];
    stripped = true;
  }
  return { sql: text, stripped };
}

/** Sokulemeyen (orta) BEGIN/COMMIT/ROLLBACK ifadeleri: atomikligi bozarlar. */
function findTransactionControl(sql) {
  const masked = maskSql(sql);
  const re = /(?:^|;)\s*(BEGIN|COMMIT|ROLLBACK|START\s+TRANSACTION|END)(?:\s+(?:WORK|TRANSACTION))?\s*;/gi;
  const found = [];
  let m;
  while ((m = re.exec(masked)) !== null) found.push(m[1].toUpperCase().replace(/\s+/g, ' '));
  return found;
}

function hasNoTransactionDirective(sql) {
  return NO_TX_DIRECTIVE.test(String(sql).split('\n').slice(0, 15).join('\n'));
}

/**
 * Hangi dosyalar bekliyor?
 * @param {Array<{name:string,version:number}>} files
 * @param {Map<string,{checksum:string|null,baseline:boolean,applied_at:any}>} applied
 */
function planMigrations(files, applied, { to = null } = {}) {
  const pending = files.filter((f) => !applied.has(f.name) && (to === null || f.version <= to));
  const known = new Set(files.map((f) => f.name));
  const missing = [...applied.keys()].filter((n) => !known.has(n));
  let lastApplied = null;
  for (const f of files) if (applied.has(f.name)) lastApplied = f.name;
  const outOfOrder = pending.filter((f) => lastApplied !== null && f.name < lastApplied).map((f) => f.name);
  return { pending, missing, outOfOrder };
}

function parseArgs(argv) {
  const opts = { status: false, dryRun: false, baseline: null, to: null, force: false, help: false, errors: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const num = (flag) => {
      const v = argv[++i];
      if (v === undefined || !/^\d+$/.test(v)) {
        opts.errors.push(`${flag} bir sayi bekler (ornek: ${flag} 17)`);
        return null;
      }
      return parseInt(v, 10);
    };
    if (a === '--status') opts.status = true;
    else if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--baseline') opts.baseline = num('--baseline');
    else if (a === '--to') opts.to = num('--to');
    else if (a === '--force') opts.force = true;
    else if (a === '--help' || a === '-h') opts.help = true;
    else opts.errors.push(`Bilinmeyen secenek: ${a}`);
  }
  if (opts.baseline !== null && opts.to !== null) opts.errors.push('--baseline ile --to birlikte kullanilamaz');
  return opts;
}

const USAGE = `Kullanim: node scripts/migrate.js [--status | --dry-run | --baseline N | --to N]
  --status        Durumu goster (salt okunur)
  --dry-run       Bekleyen migration'lari goster, uygulama
  --to N          N numarasina (dahil) kadar uygula
  --baseline N    Mevcut veritabanini N'ye kadar "uygulanmis" isaretle (dosyalari CALISTIRMAZ)
  --force         Baseline'da bilinen tablo denetimini atla
Degisiklik yapan modlar MIGRATE_CONFIRM=<veritabani_adi> ister. Hedef DATABASE_URL'den okunur.`;

// ------------------------------------------------------------------------------
// Calistirici
// ------------------------------------------------------------------------------

async function tableExists(client, name) {
  const r = await client.query('SELECT to_regclass($1) AS t', [`public.${name}`]);
  return Boolean(r.rows && r.rows[0] && r.rows[0].t);
}

async function loadApplied(client) {
  if (!(await tableExists(client, 'schema_migrations'))) return new Map();
  const r = await client.query('SELECT name, checksum, baseline, applied_at FROM schema_migrations ORDER BY name');
  return new Map(r.rows.map((row) => [row.name, row]));
}

/**
 * @param {object} deps
 * @param {string[]} [deps.argv]
 * @param {object}   [deps.env]
 * @param {Function} [deps.Client]    pg.Client (test icin sahte)
 * @param {string}   [deps.dir]       migration dizini
 * @param {object}   [deps.fsApi]     { readdirSync, readFileSync }
 * @param {Function} [deps.log]
 * @param {Function} [deps.errLog]
 * @returns {Promise<number>} cikis kodu
 */
async function main(deps = {}) {
  const argv = deps.argv || process.argv.slice(2);
  const env = deps.env || process.env;
  const dir = deps.dir || MIGRATIONS_DIR;
  const fsApi = deps.fsApi || fs;
  const log = deps.log || ((...a) => console.log(...a));
  const errLog = deps.errLog || ((...a) => console.error(...a));
  const nowMs = deps.nowMs || (() => Date.now());

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

  const readOnly = opts.status || opts.dryRun;
  let target;
  try {
    target = parseDatabaseUrl(env.DATABASE_URL);
  } catch (err) {
    errLog(`HATA: ${err.message}`);
    return 2;
  }
  log(`Hedef: ${describeTarget(target)}`);

  let files;
  try {
    files = listMigrationFiles(dir, fsApi);
  } catch (err) {
    errLog(`HATA: ${err.message}`);
    return 2;
  }
  log(`Migration dizini: ${dir} (${files.length} dosya; dev_seeds dahil DEGIL)`);

  if (!readOnly) {
    try {
      assertConfirmed(env, target);
    } catch (err) {
      errLog(`HATA: ${err.message}`);
      return 2;
    }
  }

  const Client = deps.Client || require('pg').Client;
  const client = new Client({
    connectionString: env.DATABASE_URL,
    application_name: 'ev_migrate',
    connectionTimeoutMillis: 10000,
  });

  let lockHeld = false;
  try {
    await client.connect();
    // Uzun migration'lar src/db.js'teki 15 sn statement_timeout'a takilmasin; kilit beklemesi sinirli.
    await client.query('SET statement_timeout = 0');
    const lockMs = Number.parseInt(env.MIGRATE_LOCK_TIMEOUT_MS || '15000', 10);
    await client.query(`SET lock_timeout = ${Number.isFinite(lockMs) && lockMs >= 0 ? lockMs : 15000}`);

    if (!readOnly) {
      const lock = await client.query('SELECT pg_try_advisory_lock($1) AS ok', [ADVISORY_LOCK_KEY]);
      if (!lock.rows[0] || lock.rows[0].ok !== true) {
        errLog('HATA: Baska bir migrate islemi calisiyor (advisory lock alinamadi).');
        return 1;
      }
      lockHeld = true;
      await client.query(CREATE_TABLE_SQL);
    }

    const applied = await loadApplied(client);

    // --- Durum / checksum denetimi -------------------------------------------------
    const mismatches = [];
    for (const f of files) {
      const row = applied.get(f.name);
      if (row && row.checksum) {
        const current = checksum(fsApi.readFileSync(path.join(dir, f.name), 'utf8'));
        if (current !== row.checksum) mismatches.push(f.name);
      }
    }

    // --- STATUS ---------------------------------------------------------------------
    if (opts.status) {
      for (const f of files) {
        const row = applied.get(f.name);
        const state = row ? (row.baseline ? 'baseline ' : 'uygulandi') : 'bekliyor ';
        const when = row && row.applied_at ? ` (${new Date(row.applied_at).toISOString()})` : '';
        const bad = mismatches.includes(f.name) ? '  !! ICERIK DEGISMIS' : '';
        log(`  [${state}] ${f.name}${when}${bad}`);
      }
      const plan = planMigrations(files, applied);
      for (const m of plan.missing) log(`  [!! diskte yok] ${m}`);
      log(`Ozet: ${files.length - plan.pending.length} uygulanmis, ${plan.pending.length} bekliyor.`);
      return mismatches.length > 0 ? 1 : 0;
    }

    // --- BASELINE -------------------------------------------------------------------
    if (opts.baseline !== null) {
      if (applied.size > 0) {
        errLog('HATA: schema_migrations zaten kayit iceriyor; baseline yalnizca bos tabloda yapilir.');
        return 1;
      }
      if (!opts.force) {
        const missingTables = [];
        for (const t of BASELINE_REQUIRED_TABLES) if (!(await tableExists(client, t))) missingTables.push(t);
        if (missingTables.length > 0) {
          errLog(`HATA: Baseline icin beklenen tablolar yok (${missingTables.join(', ')}). Bu bir CANLI/mevcut veritabani degil gibi; --force ile zorlayabilirsiniz.`);
          return 1;
        }
      }
      const toMark = files.filter((f) => f.version <= opts.baseline);
      log(`Baseline ${opts.baseline}: ${toMark.length} dosya "uygulanmis" isaretlenecek (CALISTIRILMAZ; sema durumu DOGRULANMAZ).`);
      await client.query('BEGIN');
      try {
        for (const f of toMark) {
          await client.query(
            'INSERT INTO schema_migrations (name, version, checksum, baseline, execution_ms) VALUES ($1, $2, NULL, TRUE, 0)',
            [f.name, f.version]
          );
          log(`  baseline: ${f.name}`);
        }
        await client.query('COMMIT');
      } catch (err) {
        await client.query('ROLLBACK').catch(() => {});
        throw err;
      }
      log('Baseline tamam. Bekleyenler icin: node scripts/migrate.js --dry-run');
      return 0;
    }

    // --- UYGULA / DRY-RUN -----------------------------------------------------------
    if (mismatches.length > 0 && env.MIGRATE_ALLOW_CHECKSUM_MISMATCH !== 'true') {
      errLog(`HATA: Uygulanmis migration dosyasinin icerigi degismis: ${mismatches.join(', ')}.`);
      errLog('Uygulanmis dosyalar degistirilmez; duzeltme icin YENI migration yazin. (Bilincli ise MIGRATE_ALLOW_CHECKSUM_MISMATCH=true)');
      return 1;
    }

    const plan = planMigrations(files, applied, { to: opts.to });
    for (const m of plan.missing) log(`UYARI: uygulanmis kayit diskte yok: ${m}`);
    for (const n of plan.outOfOrder) log(`UYARI: ${n} uygulanmis son migration'dan ONCE siralanir (sira disi).`);

    if (plan.pending.length === 0) {
      log('Bekleyen migration yok.');
      return 0;
    }
    log(`${plan.pending.length} bekleyen migration:`);
    for (const f of plan.pending) log(`  - ${f.name}`);
    if (opts.dryRun) {
      log('(--dry-run: hicbir sey uygulanmadi)');
      return 0;
    }

    for (const f of plan.pending) {
      const raw = fsApi.readFileSync(path.join(dir, f.name), 'utf8');
      const noTx = hasNoTransactionDirective(raw);
      const prepared = noTx ? { sql: raw, stripped: false } : stripTransactionWrapper(raw);
      if (!noTx) {
        const control = findTransactionControl(prepared.sql);
        if (control.length > 0) {
          errLog(`HATA: ${f.name} kendi transaction'ini yonetiyor (${control.join(', ')}). Atomik uygulanamaz; ifadeleri kaldirin veya dosyanin basina "-- migrate:no-transaction" ekleyin.`);
          return 1;
        }
      }

      const started = nowMs();
      log(`Uygulaniyor: ${f.name}${prepared.stripped ? ' (BEGIN/COMMIT sarmalayicisi sokuldu)' : ''}${noTx ? ' (transaction disi)' : ''}`);
      try {
        if (!noTx) await client.query('BEGIN');
        await client.query(prepared.sql);
        await client.query(
          'INSERT INTO schema_migrations (name, version, checksum, baseline, execution_ms) VALUES ($1, $2, $3, FALSE, $4)',
          [f.name, f.version, checksum(raw), Math.max(0, nowMs() - started)]
        );
        if (!noTx) await client.query('COMMIT');
      } catch (err) {
        if (!noTx) await client.query('ROLLBACK').catch(() => {});
        errLog(`HATA: ${f.name} uygulanamadi${noTx ? '' : ' (geri alindi)'}: ${err.message}`);
        if (err.position) errLog(`  konum: ${err.position}`);
        return 1;
      }
    }
    log('Tum bekleyen migration\'lar uygulandi.');
    return 0;
  } catch (err) {
    errLog(`HATA: ${err instanceof TargetError ? err.message : err.message || err}`);
    return 1;
  } finally {
    if (lockHeld) {
      try {
        await client.query('SELECT pg_advisory_unlock($1)', [ADVISORY_LOCK_KEY]);
      } catch (_) {
        /* baglanti kapaninca kilit zaten birakilir */
      }
    }
    try {
      await client.end();
    } catch (_) {
      /* yut */
    }
  }
}

module.exports = {
  main,
  parseArgs,
  listMigrationFiles,
  checksum,
  versionOf,
  maskSql,
  stripTransactionWrapper,
  findTransactionControl,
  hasNoTransactionDirective,
  planMigrations,
  MIGRATIONS_DIR,
  BASELINE_REQUIRED_TABLES,
  ADVISORY_LOCK_KEY,
};

if (require.main === module) {
  // `.env` yalnizca CALISTIRICI olarak kullanildiginda yuklenir (testler/require'da DEGIL).
  try {
    require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
  } catch (_) {
    /* dotenv yoksa ortam degiskenleri zaten disaridan gelir */
  }
  main().then(
    (code) => process.exit(code),
    (err) => {
      console.error(`HATA: ${err && err.message ? err.message : err}`);
      process.exit(1);
    }
  );
}
