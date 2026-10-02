#!/usr/bin/env node
'use strict';

// ==============================================================================
// AHBU Akilli Ev - SEMA-SOZLESME denetimi (kod SQL'i <-> migration / canli veritabani)   [WP-C, C9]
// ==============================================================================
//
// Kodun (kopru, zamanlayici, tum servisler, betikler) kullandigi tablo ve sutunlarin migration'larda
// var olup olmadigini denetler. Ornek hata sinifi: kopru `devices.last_ack_id` yazarken bunu yaratan
// migration yoktu -> her canli state 42703 ile geri alinir, pano "cevrimdisi" supurulur.
//
// KULLANIM (server/ dizininden):
//   node scripts/check_schema_contract.js              Statik: src/** + scripts/** SQL metinleri ve
//                                                      WP-C modullerinin CALISAN SQL'i, migration semasina karsi
//   node scripts/check_schema_contract.js --live       + DATABASE_URL'deki GERCEK PostgreSQL'in
//                                                      information_schema'sina karsi (salt-okunur sorgu)
//   node scripts/check_schema_contract.js --json       Makine okunur cikti
//   SCHEMA_CONTRACT_SOFT=1 ...                         Baska paketlerin dosyalarindaki ihlaller UYARI olur (cikis 0)
// Cikis kodu: 0 temiz, 1 ihlal, 2 kullanim/baglanti hatasi.
//
// QA yigini (gercek PostgreSQL): migration'lari uyguladiktan sonra
//   DATABASE_URL=postgresql://... node scripts/check_schema_contract.js --live
//
// SINIR: sezgisel tarayicidir (bkz. scripts/lib/sql_contract.js); calisan veritabaninin gercek
// davranisinin yerini TUTMAZ.

const path = require('path');
const sqlContract = require('./lib/sql_contract');
const { parseDatabaseUrl, describeTarget } = require('./lib/target');

const SERVER = path.join(__dirname, '..');
const WP_C_SRC = ['mqtt_bridge.js', path.join('services', 'scheduled_rules_service.js'), path.join('routes', 'scheduled_rules_routes.js'), 'scheduler.js'];

// migration'larda degil, calistiricinin kendisinin olusturdugu tablolar
const RUNTIME_TABLES = { schema_migrations: ['name', 'version', 'checksum', 'baseline', 'applied_at', 'execution_ms'] };

function loadSchema(dir = path.join(SERVER, 'migrations')) {
  const schema = sqlContract.loadMigrationSchema(dir);
  for (const [t, cols] of Object.entries(RUNTIME_TABLES)) schema.set(t, new Set(cols));
  return schema;
}

/**
 * Tum denetimi calistirir.
 * @param {{ soft?:boolean, includeCapture?:boolean, srcDir?:string, scriptsDir?:string, schema?:Map }} [opts]
 * @returns {Promise<{ schema, strict:Array, advisory:Array, refs:Map, analyzed:number, skipped:number, statementCount:number }>}
 */
async function check(opts = {}) {
  const schema = opts.schema || loadSchema();
  const srcDir = opts.srcDir || path.join(SERVER, 'src');
  const scriptsDir = opts.scriptsDir || path.join(SERVER, 'scripts');

  const strictStatements = [];
  const advisoryStatements = [];

  for (const st of sqlContract.collectStaticStatements(srcDir)) {
    const rel = st.where.split(':')[0];
    (WP_C_SRC.some((f) => rel === f) ? strictStatements : advisoryStatements).push(st);
  }
  // betikler: kendi SQL'imiz (sql_contract.js'in kendi katalog sorgusu analiz disi atlanir)
  // (sql_contract.js'in kendi anahtar sozcuk listesi SQL metni gibi gorunur: analiz disi)
  const ignoreSelf = [path.join('lib', 'sql_contract.js')];
  for (const st of sqlContract.collectStaticStatements(scriptsDir, { ignore: ignoreSelf })) strictStatements.push({ ...st, where: `scripts/${st.where}` });

  if (opts.includeCapture !== false) {
    const { captureWpCStatements } = require('./lib/sql_capture');
    strictStatements.push(...(await captureWpCStatements()));
  }

  const strictRes = sqlContract.checkStatements(strictStatements, schema);
  const advisoryRes = sqlContract.checkStatements(advisoryStatements, schema);

  const refs = new Map();
  for (const res of [strictRes, advisoryRes]) {
    for (const [t, cols] of res.refs) {
      if (!refs.has(t)) refs.set(t, new Set());
      for (const c of cols) refs.get(t).add(c);
    }
  }
  return {
    schema,
    strict: strictRes.violations,
    advisory: advisoryRes.violations,
    refs,
    analyzed: strictRes.analyzed + advisoryRes.analyzed,
    skipped: strictRes.skipped + advisoryRes.skipped,
    statementCount: strictStatements.length + advisoryStatements.length,
  };
}

function formatViolation(v) {
  const what = v.kind === 'unknown-table' ? `tablo yok: ${v.table}` : `sutun yok: ${v.table}.${v.column} (${v.via})`;
  return `${what}  [${v.where}]  ${v.sql.replace(/\s+/g, ' ').slice(0, 100)}`;
}

async function main(deps = {}) {
  const argv = deps.argv || process.argv.slice(2);
  const env = deps.env || process.env;
  const log = deps.log || ((...a) => console.log(...a));
  const errLog = deps.errLog || ((...a) => console.error(...a));
  const flags = new Set(argv);
  if (flags.has('--help') || flags.has('-h')) {
    log('Kullanim: node scripts/check_schema_contract.js [--live] [--json]   (SCHEMA_CONTRACT_SOFT=1: baska paketlerin ihlalleri uyari)');
    return 0;
  }
  for (const a of argv) {
    if (!['--live', '--json', '--help', '-h'].includes(a)) {
      errLog(`HATA: bilinmeyen secenek: ${a}`);
      return 2;
    }
  }
  const soft = env.SCHEMA_CONTRACT_SOFT === '1';

  const result = await (deps.check || check)({ soft });
  const failing = soft ? result.strict : [...result.strict, ...result.advisory];
  const warnings = soft ? result.advisory : [];

  let live = null;
  if (flags.has('--live')) {
    let target;
    try {
      target = parseDatabaseUrl(env.DATABASE_URL);
    } catch (err) {
      errLog(`HATA: ${err.message}`);
      return 2;
    }
    log(`Canli hedef: ${describeTarget(target)} (yalnizca information_schema okunur)`);
    const Client = deps.Client || require('pg').Client;
    const client = new Client({ connectionString: env.DATABASE_URL, application_name: 'ev_schema_contract', connectionTimeoutMillis: 10000 });
    try {
      await client.connect();
      await client.query('SET statement_timeout = 15000');
      live = await sqlContract.verifyLiveSchema(client, result.refs);
    } catch (err) {
      errLog(`HATA: canli dogrulama yapilamadi: ${err.message}`);
      return 2;
    } finally {
      try {
        await client.end();
      } catch (_) {
        /* yut */
      }
    }
  }

  if (flags.has('--json')) {
    log(
      JSON.stringify(
        {
          statements: result.statementCount,
          analyzed: result.analyzed,
          violations: failing,
          warnings,
          live,
          refs: Object.fromEntries([...result.refs].map(([t, c]) => [t, [...c].sort()])),
        },
        null,
        2
      )
    );
  } else {
    log(`SQL ifadesi: ${result.statementCount} (cozumlenen ${result.analyzed}, atlanan ${result.skipped}); tablo: ${result.refs.size}`);
    for (const [t, cols] of [...result.refs].sort()) log(`  ${t}: ${[...cols].sort().join(', ')}`);
    for (const w of warnings) log(`UYARI (baska paket): ${formatViolation(w)}`);
    for (const v of failing) errLog(`IHLAL: ${formatViolation(v)}`);
    if (live) for (const p of live) errLog(`CANLI IHLAL: ${p.table}${p.column ? '.' + p.column : ''} - ${p.problem}`);
    if (failing.length === 0 && (!live || live.length === 0)) log('Sema sozlesmesi TEMIZ.');
  }
  return failing.length > 0 || (live && live.length > 0) ? 1 : 0;
}

module.exports = { check, loadSchema, main, formatViolation, WP_C_SRC, RUNTIME_TABLES };

if (require.main === module) {
  try {
    require('dotenv').config({ path: path.join(SERVER, '.env') });
  } catch (_) {
    /* yut */
  }
  main().then(
    (code) => process.exit(code),
    (err) => {
      console.error(`HATA: ${err && err.message ? err.message : err}`);
      process.exit(2);
    }
  );
}
