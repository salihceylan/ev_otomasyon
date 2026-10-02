#!/usr/bin/env node
// Yerel QA yigini komut satiri: up | down | status | reset | logs  (+ accounts | seed | mails)
//
//   node tools/qa_stack/run.js up [--stage2] [--public-host H] [--devices 2|3] [--time-scale N] [--keep-secrets]
//   node tools/qa_stack/run.js status
//   node tools/qa_stack/run.js logs [daemon|broker|pg|api|sim|mail|migrate] [-n 50] [-f]
//   node tools/qa_stack/run.js down
//   node tools/qa_stack/run.js reset          # down + .runtime silinir (veritabani, sirlar, hesaplar)
//
// Her sey 127.0.0.1 uzerindedir. Sirlar yalnizca .runtime/ (gitignore'lu) altina yazilir.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { pathToFileURL } from 'node:url';
import { readAccounts } from './lib/accounts.js';
import { DEFAULT_CORS_ORIGINS, DEFAULT_PUBLIC_MQTT_HOST, DB, HOST, PORTS } from './lib/config.js';
import { checkDrift } from './lib/fwcheck.js';
import { mailsCommand } from './lib/mails.js';
import { PgManager, stopPgByDataDir } from './lib/pg.js';
import { ROOT, runtimePaths } from './lib/paths.js';
import { formatSeedSummary, formatStepLine } from './lib/seed_report.js';
import { DEFAULT_OPTIONS, runDaemon } from './lib/supervisor.js';
import { ensureDir, fetchJson, killTree, pidAlive, readJson, sleep, tcpProbe, waitForExit } from './lib/util.js';

const SELF = path.resolve(process.argv[1] || '');
const RUN_JS = path.join(ROOT, 'run.js');

// ------------------------------------------------------------------------------------------------ yardim
const HELP = `AHBU ev otomasyonu - yerel QA yigini (127.0.0.1)

KOMUTLAR
  up [secenekler]     PG -> MQTT broker -> cihaz simulatorleri baslatir (arka planda), .runtime/stack.json yazar
      --stage2             + SMTP cukuru, migration, sunucu (server/) ve REST tohumlama (Asama Q2)
      --no-seed            stage2'de tohumlamayi atla
      --public-host H      istemciye bildirilen MQTT adresi (varsayilan ${DEFAULT_PUBLIC_MQTT_HOST} = emulator;
                           Windows/Chrome icin 127.0.0.1)
      --devices 2|3        simulator sayisi (3. = 16 role provizyonsuz)               [2]
      --time-scale N       panjur sureleri N kat hizli (olu zaman sabit 500 ms)       [1]
      --keep-secrets       JWT/MQTT/yonetici anahtarlarini onceki up'tan koru (varsayilan: her up'ta yenilenir)
      --pg-port N          PostgreSQL portu                                           [${PORTS.pg}]
      --cors-origins a,b   Flutter web (Chrome) kokenleri [${DEFAULT_CORS_ORIGINS.join(',')}]
      --foreground         arka plana gecme (Ctrl+C ile durdur)
      --timeout SN         hazir olmayi bekleme suresi                                [300]
  status [--json]     bilesenlerin durumu (cikis kodu 0 = hepsi calisiyor)
  logs [ad] [-n N] [-f]   daemon|broker|pg|api|sim|mail|migrate (varsayilan: daemon)
  down                temiz kapatir; oksuz postgres.exe / sunucu surecini temizler
  reset               down + .runtime'i siler (veritabani, sirlar, hesaplar, simulator durumu)
  accounts            .runtime/accounts.json'u okunur bicimde yazdirir (PAROLALAR icerir; yalniz yerel)
  seed                calisan yiginda REST tohumlamayi yeniden calistirir: IDEMPOTENT (var olani cogaltmaz/yeniden uretmez;
                      yalnizca eksik, suresi dolmus ya da bozulmus olani yapar; adim adim "YAPILDI/ATLANDI/DOGRULANDI" yazar)
  smoke               calisan yiginda uctan uca duman testi (REST + MQTT + simulator; yan etkileri geri alinir)
  sqlcheck [--all] [--json]   server/src+scripts icindeki SQL'leri GERCEK PostgreSQL'e karsi PREPARE ile denetler
  sweep [--quick] [--only ON_EK] [-v]   GERCEK PG + sunucuya dusman girdi / akis supurmesi (gecici kullanici-ev-cihazlarla); 5xx'leri api.log yiginina baglar
  sql "<SORGU>"       calisan PostgreSQL'e tek bir SELECT/UPDATE calistirir (psql yok); sonuc JSON
  fwcheck [--update] [--json]   simulatorun portlandigi firmware kaynaklarinin (SHA-256) suruklenmesini denetler; --update ozetleri yeniler
  mails [N]           SMTP cukuruna dusen EN YENI en cok 30 e-postayi numarali listeler (1 = en yeni); \`mails N\` N. e-postanin
                      ham govdesini yazar (OTP/etkinlestirme kodlari); N yoksa hata + cikis kodu 1
`;

// ------------------------------------------------------------------------------------------------ yardimcilar
const UP_OPTIONS = {
  stage2: { type: 'boolean' },
  'no-seed': { type: 'boolean' },
  'public-host': { type: 'string' },
  devices: { type: 'string' },
  'time-scale': { type: 'string' },
  'keep-secrets': { type: 'boolean' },
  'pg-port': { type: 'string' },
  'cors-origins': { type: 'string' },
  foreground: { type: 'boolean' },
  'strict-migrations': { type: 'boolean' },
  timeout: { type: 'string' },
};

export function parseUpOptions(argv) {
  const { values } = parseArgs({ args: argv, options: UP_OPTIONS, allowPositionals: false });
  const num = (v, name, min, max) => {
    if (v === undefined) return undefined;
    const n = Number(v);
    if (!Number.isFinite(n) || n < min || n > max) throw new Error(`--${name} ${min}..${max} araliginda sayi olmali`);
    return n;
  };
  const o = {};
  if (values.stage2) o.stage2 = true;
  if (values['no-seed']) o.noSeed = true;
  if (values['public-host']) o.publicHost = values['public-host'];
  if (values.devices !== undefined) o.devices = num(values.devices, 'devices', 2, 3);
  if (values['time-scale'] !== undefined) o.timeScale = num(values['time-scale'], 'time-scale', 1, 1000);
  if (values['keep-secrets']) o.keepSecrets = true;
  if (values['pg-port'] !== undefined) o.pgPort = num(values['pg-port'], 'pg-port', 1024, 65535);
  if (values['cors-origins']) o.corsOrigins = values['cors-origins'].split(',').map((s) => s.trim()).filter(Boolean);
  if (values.foreground) o.foreground = true;
  if (values['strict-migrations']) o.strictMigrations = true;
  o.timeout = values.timeout !== undefined ? num(values.timeout, 'timeout', 10, 1800) : 300;
  return o;
}

/** Secenek nesnesini daemon bayraklarina cevirir. */
export function daemonArgs(o) {
  const a = [];
  if (o.stage2) a.push('--stage2');
  if (o.noSeed) a.push('--no-seed');
  if (o.publicHost) a.push('--public-host', o.publicHost);
  if (o.devices) a.push('--devices', String(o.devices));
  if (o.timeScale) a.push('--time-scale', String(o.timeScale));
  if (o.keepSecrets) a.push('--keep-secrets');
  if (o.pgPort) a.push('--pg-port', String(o.pgPort));
  if (o.corsOrigins) a.push('--cors-origins', o.corsOrigins.join(','));
  if (o.strictMigrations) a.push('--strict-migrations');
  return a;
}

const rt = () => runtimePaths();
const readStack = () => readJson(rt().stackFile, null);
const readPids = () => readJson(rt().pidsFile, null);

async function controlHealth(port) {
  try {
    const r = await fetchJson(`http://${HOST}:${port}/health`, { timeoutMs: 1500 });
    return r.status === 200 ? r.json : null;
  } catch (_) {
    return null;
  }
}

function printSummary(stack) {
  const c = stack.components || {};
  const lines = [];
  lines.push(`QA yigini: ${stack.status.toUpperCase()}  (daemon PID ${stack.daemon_pid})`);
  if (c.postgres) lines.push(`  PostgreSQL     ${c.postgres.host}:${c.postgres.port}  veritabani ${c.postgres.database}  PID ${c.postgres.pid}`);
  if (c.broker) lines.push(`  MQTT broker    ${c.broker.host}:${c.broker.mqtt_port} (TCP)  ws://${c.broker.host}:${c.broker.ws_port}  kontrol http://${c.broker.host}:${c.broker.control_port}  (tablolar hazir: ${c.broker.store_ready})`);
  for (const s of c.simulators || []) lines.push(`  Simulator      ${s.name.padEnd(6)} ${s.uid.padEnd(16)} http://127.0.0.1:${s.http_port}  emulator: ${s.emulator_url}  role=${s.relays}`);
  if (c.smtp) lines.push(`  SMTP cukuru    127.0.0.1:${c.smtp.port}  -> ${c.smtp.mail_dir}`);
  if (c.migrations) lines.push(`  Migration      ${c.migrations.ok ? 'tamam' : 'BASARISIZ'}  (${c.migrations.method})`);
  if (c.api) lines.push(c.api.error ? `  REST API       BASLATILAMADI: ${c.api.error.split('\n')[0]}` : `  REST API       ${c.api.base_url}  emulator: ${c.api.emulator_url}  PID ${c.api.pid}`);
  if (c.seed) {
    lines.push(`  Tohumlama      ${formatSeedSummary(c.seed.steps)}`);
    for (const n of c.seed.notes || []) lines.push(`  Tohumlama notu: ${n}`);
  }
  for (const w of stack.warnings || []) lines.push(`  UYARI: ${w}`);
  try {
    const drift = checkDrift();
    if (!drift.ok) lines.push(`  UYARI: ${drift.changed.length} firmware kaynagi simulatorun portlandigi surumden FARKLI -> \`node run.js fwcheck\``);
  } catch (_) { /* surukleme denetimi yardimcidir; yigini engellemez */ }
  lines.push('');
  lines.push('Emulator (Android) icin:');
  lines.push(`  flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:${PORTS.api}/api --dart-define=MQTT_TLS=false --dart-define=DEVICE_AP_HOST=10.0.2.2:${PORTS.sims[0]}`);
  lines.push('Windows/Chrome icin MQTT adresini 127.0.0.1 yapin: `up --public-host 127.0.0.1`');
  lines.push(`Hesaplar/PIN'ler: ${stack.files.accounts}   (node run.js accounts)`);
  lines.push(`Loglar: ${stack.files.runtime_dir}\\*.log   (node run.js logs broker -f)`);
  console.log(lines.join('\n'));
}

// ------------------------------------------------------------------------------------------------ up
async function cmdUp(argv) {
  const opts = parseUpOptions(argv);
  const existing = readPids();
  if (existing && pidAlive(existing.daemon)) {
    const health = await controlHealth(PORTS.supervisor);
    if (health) {
      console.log('QA yigini zaten calisiyor.');
      const st = readStack();
      if (st) printSummary(st);
      return 0;
    }
  }
  // onceki calismadan kalan oksuz surecleri temizle (kendi veri dizinimiz/PID'lerimiz)
  if (existing || fs.existsSync(path.join(rt().pgData, 'postmaster.pid'))) {
    await cleanup({ quiet: true });
  }

  if (opts.foreground) {
    const res = await runDaemon({ ...DEFAULT_OPTIONS, ...opts, foreground: true });
    if (!res) return 1;
    console.log('\n(on planda calisiyor; Ctrl+C ile durdurun)');
    return new Promise(() => {}); // sinyal/kontrol ucu process.exit cagirir
  }

  let res = await startDaemonAndWait(opts);
  if (res.crashed) {
    // Windows/libuv: node sureci aralikli olarak ANIDEN cokebilir (cikis kodu 0xC0000409; hata kaydi birakmaz). Tohum/migration
    // idempotenttir: kalintilari temizleyip BIR KEZ daha denemek guvenlidir (gercek bir hata ikinci denemede de gorulur).
    console.error('Daemon ani olarak coktu (Windows/libuv yerel cokmesi olabilir): kalintilar temizleniyor ve bir kez daha deneniyor...');
    await cleanup({ quiet: true });
    res = await startDaemonAndWait(opts);
  }
  return res.code;
}

/**
 * Daemon'u arka planda baslatir ve hazir olmasini bekler.
 * @returns {Promise<{code:number, crashed:boolean}>} crashed: daemon hata kaydi birakmadan ani cikti (yeniden denenebilir)
 */
async function startDaemonAndWait(opts) {
  ensureDir(rt().dir);
  try { fs.rmSync(rt().stackFile, { force: true }); } catch (_) { /* yok say */ }
  const fd = fs.openSync(rt().logs.daemon, 'a');
  fs.writeSync(fd, `\n===== ${new Date().toISOString()} up ${daemonArgs(opts).join(' ')}\n`);
  const child = spawn(process.execPath, [RUN_JS, '__daemon', ...daemonArgs(opts)], {
    detached: true, stdio: ['ignore', fd, fd], windowsHide: true, cwd: ROOT,
  });
  child.unref();
  fs.closeSync(fd);
  console.log(`Daemon baslatildi (PID ${child.pid}); hazir olmasi bekleniyor (ilk calistirmada initdb ~20-60 sn)...`);

  const deadline = Date.now() + opts.timeout * 1000;
  let last = '';
  for (;;) {
    await sleep(500);
    const st = readStack();
    if (st && ['ready', 'degraded', 'failed'].includes(st.status)) {
      if (st.status === 'failed') {
        console.error(`\nQA yigini BASLATILAMADI: ${st.error}`);
        console.error(`Ayrinti: ${rt().logs.daemon}`);
        return { code: 1, crashed: false };
      }
      console.log('');
      printSummary(st);
      return { code: st.status === 'degraded' ? 2 : 0, crashed: false };
    }
    if (!pidAlive(child.pid) && !(st && st.status === 'ready')) {
      const st2 = readStack();
      console.error(`\nDaemon beklenmedik sekilde cikti. ${st2 && st2.error ? `Hata: ${st2.error}` : ''}\nLog: ${rt().logs.daemon}`);
      // hata kaydi yok ('failed'/error) ve gozeticinin PID dosyasi duruyorsa surec ANI oldu: yerel cokme -> yeniden denenebilir
      const crashed = !(st2 && (st2.error || st2.status === 'failed')) && !!readPids();
      return { code: 1, crashed };
    }
    const progress = st ? Object.keys(st.components || {}).join(',') : 'baslatiliyor';
    if (progress !== last) { process.stdout.write(`  [${progress}]\n`); last = progress; }
    if (Date.now() > deadline) {
      console.error(`\nZaman asimi (${opts.timeout} sn). Log: ${rt().logs.daemon}`);
      return { code: 1, crashed: false };
    }
  }
}

// ------------------------------------------------------------------------------------------------ down
async function cleanup({ quiet = false } = {}) {
  const say = (m) => { if (!quiet) console.log(m); };
  const pids = readPids();
  const stack = readStack();
  let any = false;

  if (pids && pidAlive(pids.daemon)) {
    any = true;
    const port = (stack && stack.components && stack.components.supervisor && stack.components.supervisor.control_port) || PORTS.supervisor;
    try {
      const r = await fetchJson(`http://${HOST}:${port}/shutdown`, { method: 'POST', headers: { 'X-QA-Token': pids.token }, body: {}, timeoutMs: 3000 });
      say(`  kontrol ucu: temiz kapanis istendi (HTTP ${r.status})`);
    } catch (e) {
      say(`  kontrol ucu yanit vermedi (${e.message})`);
    }
    if (!(await waitForExit(pids.daemon, 60000))) {
      say(`  daemon (PID ${pids.daemon}) kapanmadi: zorla sonlandiriliyor`);
      killTree(pids.daemon);
      await waitForExit(pids.daemon, 10000);
    } else {
      say('  daemon temiz kapandi');
    }
  }

  // daemon olmeden kalan alt surecler
  const apiPid = stack && stack.components && stack.components.api && stack.components.api.pid;
  if (apiPid && pidAlive(apiPid)) {
    any = true;
    killTree(apiPid);
    say(`  sunucu sureci (PID ${apiPid}) sonlandirildi`);
  }
  // PostgreSQL: yalniz KENDI veri dizinimiz
  if (fs.existsSync(path.join(rt().pgData, 'postmaster.pid'))) {
    const r = await stopPgByDataDir(rt().pgData);
    if (r.stopped) { any = true; say(`  PostgreSQL durduruldu (PID ${r.pid}${r.forced ? ', zorla' : ', temiz'})`); }
    else if (r.reason === 'stale_pid_file') say('  eski postmaster.pid (surec yok)');
  }
  try { fs.rmSync(rt().pidsFile, { force: true }); } catch (_) { /* yok say */ }
  try { fs.rmSync(rt().stackFile, { force: true }); } catch (_) { /* yok say */ }
  return any;
}

async function cmdDown() {
  console.log('QA yigini kapatiliyor...');
  const any = await cleanup();
  console.log(any ? 'Kapatildi.' : 'Calisan QA bileseni yoktu.');
  return 0;
}

// ------------------------------------------------------------------------------------------------ reset
function assertSafeRuntimeDir(dir) {
  const norm = path.resolve(dir);
  const ok = path.basename(norm) === '.runtime' || path.basename(norm).startsWith('qa_runtime') || norm.startsWith(path.resolve(os.tmpdir()));
  if (!ok) throw new Error(`guvenlik: ${norm} bir QA calisma dizini gibi gorunmuyor; silinmedi`);
  return norm;
}

async function cmdReset() {
  await cmdDown();
  const dir = assertSafeRuntimeDir(rt().dir);
  if (fs.existsSync(dir)) {
    fs.rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    console.log(`Silindi: ${dir}`);
  } else {
    console.log('Silinecek calisma dizini yok.');
  }
  return 0;
}

// ------------------------------------------------------------------------------------------------ status
async function cmdStatus(argv) {
  const { values } = parseArgs({ args: argv, options: { json: { type: 'boolean' } }, allowPositionals: false });
  const stack = readStack();
  const pids = readPids();
  const rows = [];
  const add = (name, ok, detail) => rows.push({ name, ok, detail });

  const daemonAlive = !!(pids && pidAlive(pids.daemon));
  add('daemon', daemonAlive, daemonAlive ? `PID ${pids.daemon}${stack ? `, durum ${stack.status}` : ''}` : 'calismiyor');

  if (stack && daemonAlive) {
    const c = stack.components || {};
    const pgm = new PgManager({ dataDir: rt().pgData, password: 'x', port: c.postgres ? c.postgres.port : PORTS.pg });
    const pgs = await pgm.status().catch(() => ({ running: false }));
    add('postgresql', pgs.running, `${HOST}:${c.postgres ? c.postgres.port : PORTS.pg}${pgs.pid ? ` PID ${pgs.pid}` : ''}`);

    if (c.broker) {
      const tcp = await tcpProbe(HOST, c.broker.mqtt_port);
      const ws = c.broker.ws_port ? await tcpProbe(HOST, c.broker.ws_port) : true;
      const ctl = await fetchJson(`http://${HOST}:${c.broker.control_port}/__qa/stats`, { timeoutMs: 1500 }).catch(() => null);
      add('mqtt broker', tcp && ws && !!ctl, `tcp:${c.broker.mqtt_port}=${tcp} ws:${c.broker.ws_port}=${ws}${ctl && ctl.json ? ` istemci=${ctl.json.clients} tablolar=${ctl.json.store_ready}` : ''}`);
    }
    for (const s of c.simulators || []) {
      const r = await fetchJson(`http://${HOST}:${s.http_port}/api/status`, { timeoutMs: 1500 }).catch(() => null);
      add(`sim ${s.name}`, !!(r && r.status === 200), r && r.json ? `${r.json.device} :${s.http_port} provizyonlu=${r.json.provisioned} wifi=${r.json.wifi_connected}` : `:${s.http_port} yanit yok`);
    }
    if (c.smtp) add('smtp cukuru', await tcpProbe(HOST, c.smtp.port), `:${c.smtp.port}`);
    if (c.api && !c.api.error) {
      const r = await fetchJson(`http://${HOST}:${c.api.port}/health`, { timeoutMs: 2000 }).catch(() => null);
      const ready = await fetchJson(`http://${HOST}:${c.api.port}/ready`, { timeoutMs: 2000 }).catch(() => null);
      add('rest api', !!(r && r.status === 200), `:${c.api.port} PID ${c.api.pid}${ready && ready.json ? ` hazir=${ready.json.status} mqtt_koprusu=${ready.json.components && ready.json.components.mqtt_bridge}` : ''}`);
    } else if (c.api && c.api.error) {
      add('rest api', false, 'baslatilamadi');
    }
    if (stack.warnings && stack.warnings.length) for (const w of stack.warnings) add('uyari', false, w);
  }

  const allOk = rows.filter((r) => r.name !== 'uyari').every((r) => r.ok) && daemonAlive;
  if (values.json) {
    console.log(JSON.stringify({ ok: allOk, status: stack ? stack.status : 'stopped', components: rows }, null, 2));
  } else {
    if (!daemonAlive) console.log('QA yigini calismiyor.  (node run.js up)');
    for (const r of rows) console.log(`${r.ok ? 'OK  ' : 'HATA'}  ${r.name.padEnd(12)} ${r.detail}`);
  }
  return allOk ? 0 : 1;
}

// ------------------------------------------------------------------------------------------------ logs
async function cmdLogs(argv) {
  const { values, positionals } = parseArgs({ args: argv, options: { n: { type: 'string', short: 'n' }, f: { type: 'boolean', short: 'f' } }, allowPositionals: true });
  const name = positionals[0] || 'daemon';
  const logs = rt().logs;
  if (!logs[name]) throw new Error(`bilinmeyen log: ${name} (${Object.keys(logs).join('|')})`);
  const file = logs[name];
  const n = Number.parseInt(values.n || '50', 10);
  const tail = () => {
    try { return fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean).slice(-n); } catch (_) { return []; }
  };
  for (const l of tail()) console.log(l);
  if (!values.f) return 0;
  let pos = fs.existsSync(file) ? fs.statSync(file).size : 0;
  for (;;) {
    await sleep(500);
    if (!fs.existsSync(file)) continue;
    const size = fs.statSync(file).size;
    if (size < pos) pos = 0;
    if (size > pos) {
      const fd = fs.openSync(file, 'r');
      const buf = Buffer.alloc(size - pos);
      fs.readSync(fd, buf, 0, buf.length, pos);
      fs.closeSync(fd);
      process.stdout.write(buf.toString('utf8'));
      pos = size;
    }
  }
}

// ------------------------------------------------------------------------------------------------ accounts / mails / seed
function cmdAccounts() {
  const acc = readAccounts(rt());
  if (!acc) { console.log('accounts.json yok (once `up`).'); return 1; }
  console.log('# QA hesaplari (yalniz yerel; repoya yazilmaz)\n');
  console.log(`Wi-Fi (simulator ev agi): ${acc.wifi.ssid} / ${acc.wifi.password}\n`);
  console.log('CIHAZLAR');
  for (const [k, d] of Object.entries(acc.devices)) {
    console.log(`  ${k.padEnd(7)} ${d.uid.padEnd(16)} setup_pin=${d.setup_pin} role=${d.relays} ${d.local_url ? `http=${d.local_url} (emulator ${d.emulator_url})` : '(simulator yok)'}  [${d.expected_final_status}]`);
    console.log(`          ${d.purpose}`);
    if (d.local_key) console.log(`          X-Device-Key=${d.local_key}`);
  }
  console.log('\nKULLANICILAR');
  for (const [k, u] of Object.entries(acc.users || {})) console.log(`  ${k.padEnd(14)} ${u.email.padEnd(34)} ${u.password}   (${u.role})`);
  if (!Object.keys(acc.users || {}).length) console.log('  (henuz tohumlanmadi: `up --stage2`)');
  if (acc.service_pin) console.log(`\nSERVIS PIN (${acc.service_pin.home}): ${acc.service_pin.pin}   ${acc.service_pin.note || ''}`);
  for (const [k, h] of Object.entries(acc.homes || {})) console.log(`EV ${k}: ${h.id} "${h.name}" (sahip: ${h.owner})`);
  return 0;
}

/** mails: en yeni <=30 e-posta (numarali liste) | mails N: N. e-postanin ham govdesi; yoksa hata + cikis kodu 1 (lib/mails.js). */
function cmdMails(argv) {
  const r = mailsCommand(rt().mailDir, argv);
  if (r.out !== undefined) console.log(r.out);
  if (r.err !== undefined) console.error(r.err);
  return r.code;
}

/** Calisan yiginin PostgreSQL baglanti dizesi (parola secrets.json'dan; ekrana YAZILMAZ). */
function dbUrlOfRunningStack() {
  const stack = readStack();
  const secrets = readJson(rt().secretsFile, null);
  if (!stack || !stack.components.postgres || !secrets) return null;
  return `postgresql://${DB.user}:${encodeURIComponent(secrets.db_password)}@${HOST}:${stack.components.postgres.port}/${DB.name}`;
}

async function cmdSeed() {
  const stack = readStack();
  if (!stack || !stack.components.api || stack.components.api.error) { console.error('REST API calismiyor (`up --stage2`).'); return 1; }
  const dbUrl = dbUrlOfRunningStack();
  const { runSeed } = await import('./lib/seed.js');
  const res = await runSeed({ rt: rt(), dbUrl, log: () => {}, verifyOnline: true });
  for (const s of res.steps) console.log(formatStepLine(s));
  for (const n of res.notes) console.log(`NOT  ${n}`);
  console.log(`\nTohumlama ${formatSeedSummary(res.steps)}`);
  return res.ok ? 0 : 2;
}

async function cmdSqlcheck(argv) {
  const { values } = parseArgs({ args: argv, options: { json: { type: 'boolean' }, all: { type: 'boolean' } }, allowPositionals: false });
  const dbUrl = dbUrlOfRunningStack();
  if (!dbUrl) { console.error('PostgreSQL calismiyor (`up`).'); return 1; }
  const { runSqlCheck } = await import('./lib/sqlcheck.js');
  const { summary, results } = await runSqlCheck({ connectionString: dbUrl });
  if (values.json) { console.log(JSON.stringify({ summary, results: results.filter((r) => values.all || r.status === 'error') }, null, 2)); return summary.errors ? 2 : 0; }
  const errs = results.filter((r) => r.status === 'error');
  for (const r of errs) {
    console.log(`HATA  ${r.file}:${r.line}  [${r.code}] ${r.message}${r.snippet ? `
        konum: ...${r.snippet}` : ''}`);
  }
  if (values.all) {
    for (const r of results.filter((x) => x.status === 'dynamic')) console.log(`DINAMIK ${r.file}:${r.line}  (${r.dynamic})`);
  }
  console.log(`
SQL denetimi: ${summary.total} sorgu cagrisi | dogrulanan ${summary.ok} | HATALI ${summary.errors} | dinamik (denetlenmedi) ${summary.dynamic} | atlanan ${summary.skipped}`);
  return summary.errors ? 2 : 0;
}

async function cmdSweep(argv) {
  const { values } = parseArgs({ args: argv, options: { quick: { type: 'boolean' }, only: { type: 'string' }, v: { type: 'boolean', short: 'v' } }, allowPositionals: false });
  const stack = readStack();
  if (!stack || !stack.components.api || stack.components.api.error) { console.error('REST API calismiyor (`up --stage2`).'); return 1; }
  const { runSweep } = await import('./lib/sweep.js');
  const report = await runSweep({ rt: rt(), quick: !!values.quick, only: values.only || '', verbose: !!values.v, log: (t, f) => console.log(`  ${t} ${JSON.stringify(f).slice(0, 300)}`) });
  console.log(`
SUPURME: ${report.stats.requests} istek, ${report.stats.specs} spec, taban hatasi ${report.stats.base_fail}; durumlar ${JSON.stringify(report.stats.by_status)}`);
  const sev = { SUNUCU_HATASI_5XX: 0, SUNUCU_HATASI_LOGDA: 0, DB_SORGU_HATASI: 0, GUVENLIK_IDOR: 0, BEKLENMEYEN_DURUM: 0 };
  for (const f of report.findings) {
    sev[f.kind] = (sev[f.kind] || 0) + f.count;
    const where = f.server_log && f.server_log.own_frame ? `  ${f.server_log.own_frame}` : '';
    console.log(`${f.kind.padEnd(20)} x${String(f.count).padEnd(4)} ${f.method || ''} ${f.path || ''} ${f.status || ''} ${f.code || ''}${where}
      ${(f.labels || [f.label]).filter(Boolean).slice(0, 3).join(' | ')}${f.sql ? `
      SQL: ${f.sql}` : ''}${f.error ? `
      ${String(f.error).slice(0, 200)}` : ''}${f.server_log ? `
      ${f.server_log.message}` : ''}`);
  }
  console.log(`
Ozet: ${JSON.stringify(sev)}  | rapor: ${rt().dir}/sweep_report.json`);
  return (sev.SUNUCU_HATASI_5XX || sev.SUNUCU_HATASI_LOGDA || sev.DB_SORGU_HATASI || sev.GUVENLIK_IDOR) ? 2 : 0;
}

async function cmdFwcheck(argv) {
  const { values } = parseArgs({ args: argv, options: { update: { type: 'boolean' }, json: { type: 'boolean' } }, allowPositionals: false });
  const fc = await import('./lib/fwcheck.js');
  if (values.update) {
    const m = fc.writeManifest();
    console.log(`Ozetler yenilendi: ${Object.keys(m.files).length} kaynak (firmware ${m.fw_version || '?'}) -> ${fc.MANIFEST}`);
    return 0;
  }
  const r = fc.checkDrift();
  if (values.json) { console.log(JSON.stringify(r, null, 2)); return r.ok ? 0 : 3; }
  if (!r.recorded_at) console.log('UYARI: referans ozet dosyasi yok (sim/fw/SOURCES.json). Simulatoru firmware ile esitledikten sonra `node run.js fwcheck --update`.');
  const notPorted = `Bilincli PORTLANMAYAN (izlenmez): ${fc.NOT_PORTED.join(', ')} -- bkz. docs/QA_STACK.md 5.1`;
  if (r.ok) {
    console.log(`Firmware kaynaklari simulatorun portlandigi surumle AYNI (kayit: ${r.recorded_at}, firmware ${r.fw_version || '?'}).`);
    console.log(notPorted);
    return 0;
  }
  for (const c of r.changed) console.log(`${c.state.toUpperCase().padEnd(8)} ${c.file}  ->  ${c.feeds}`);
  console.log(`
${r.changed.length} firmware kaynagi simulatorun portlandigi surumden FARKLI: ilgili sim/fw/* modulunu ve test/fw_*.test.js dosyasini yeniden esitleyin, sonra \`node run.js fwcheck --update\`.
${notPorted}`);
  return 3;
}

async function cmdSql(argv) {
  const dbUrl = dbUrlOfRunningStack();
  if (!dbUrl) { console.error('PostgreSQL calismiyor (`up`).'); return 1; }
  const text = argv.join(' ').trim();
  if (!text) { console.error('kullanim: node run.js sql "SELECT ..."'); return 2; }
  const pg = (await import('pg')).default;
  const c = new pg.Client({ connectionString: dbUrl });
  await c.connect();
  try {
    const r = await c.query(text);
    console.log(JSON.stringify(r.command === 'SELECT' || r.rows.length ? r.rows : { command: r.command, rowCount: r.rowCount }, null, 1));
  } finally {
    await c.end().catch(() => {});
  }
  return 0;
}

async function cmdSmoke() {
  const stack = readStack();
  if (!stack || !stack.components.api || stack.components.api.error) { console.error('REST API calismiyor (`up --stage2`).'); return 1; }
  const { runSmoke } = await import('./lib/smoke.js');
  const res = await runSmoke({ rt: rt(), log: () => {} });
  for (const c of res.checks) console.log(`${c.ok ? 'OK  ' : 'HATA'}  ${c.name}${c.detail ? `
        -> ${c.detail}` : ''}`);
  console.log(`
${res.checks.filter((c) => c.ok).length}/${res.checks.length} denetim gecti.`);
  return res.ok ? 0 : 2;
}

// ------------------------------------------------------------------------------------------------ giris
export async function main(argv = process.argv.slice(2)) {
  const [cmd, ...rest] = argv;
  switch (cmd) {
    case 'up': return cmdUp(rest);
    case '__daemon': {
      const opts = parseUpOptions(rest);
      await runDaemon({ ...DEFAULT_OPTIONS, ...opts });
      return new Promise(() => {}); // sinyal / kontrol ucu process.exit cagirir
    }
    case 'down': return cmdDown();
    case 'status': return cmdStatus(rest);
    case 'reset': return cmdReset();
    case 'logs': return cmdLogs(rest);
    case 'accounts': return cmdAccounts();
    case 'mails': return cmdMails(rest);
    case 'seed': return cmdSeed();
    case 'smoke': return cmdSmoke();
    case 'sqlcheck': return cmdSqlcheck(rest);
    case 'sweep': return cmdSweep(rest);
    case 'sql': return cmdSql(rest);
    case 'fwcheck': return cmdFwcheck(rest);
    case undefined:
    case '-h':
    case '--help':
    case 'help':
      console.log(HELP);
      return cmd === undefined ? 2 : 0;
    default:
      console.error(`Bilinmeyen komut: ${cmd}\n\n${HELP}`);
      return 2;
  }
}

/**
 * DOGAL cikis: cikis kodu `process.exitCode`'a yazilir, olay dongusu bosalinca surec kendiliginden biter.
 * Windows/libuv'de acik tutamac/is parcacigi varken `process.exit()` bazen 'UV_HANDLE_CLOSING' assert cokmesi verir
 * (cikis kodu 3221226505 = 0xC0000409; yuk altinda `seed`/`smoke`te de gorulur) - cikti dogru olsa bile kod bozulur.
 * Dongu bosalmazsa (kalan bir soket vb.) 5 sn sonra zorla cikilir (dongu bosaldiysa bu zamanlayici hic calismaz: unref).
 */
function finish(code) {
  process.exitCode = code ?? 0;
  setTimeout(() => process.exit(process.exitCode), 5000).unref();
}

if (process.argv[1] && import.meta.url === pathToFileURL(SELF).href) {
  main().then(finish, (err) => {
    console.error(`HATA: ${err && err.message ? err.message : err}`);
    finish(1);
  });
}

