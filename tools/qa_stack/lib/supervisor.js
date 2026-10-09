// QA yigini gozeticisi (daemon): PG -> broker -> simulatorler -> [stage2: SMTP cukuru -> migration -> sunucu -> tohum].
// `run.js up` bunu detached surec olarak baslatir (veya --foreground ile bu surecte calistirir).
// Sinyal/kontrol uclu temiz kapanis: SIGINT/SIGTERM/SIGBREAK ve 127.0.0.1:18090 POST /shutdown (X-QA-Token).
// Windows'ta dis surecten SIGTERM zorla oldurur; bu yuzden `down` once kontrol ucunu kullanir.
import fs from 'node:fs';
import http from 'node:http';
import { DeviceFleet } from '../sim/run_devices.js';
import { QA_MQTT_HOST_ALLOW } from '../sim/device_sim.js';
import { ensureDeviceAccounts, DEVICE_PLAN } from './accounts.js';
import { applyMigrations, buildServerEnv, quarantineMigrationUsers, startApiServer } from './api_server.js';
import { startBroker } from './broker.js';
import { DEFAULT_CORS_ORIGINS, DEFAULT_PUBLIC_MQTT_HOST, HOST, PORTS } from './config.js';
import { PgCredentialStore } from './credstore.js';
import { ensureMailTls, startMailSink } from './mail_sink.js';
import { describeOwners, portStatus } from './netutil.js';
import { PgManager } from './pg.js';
import { runtimePaths, SERVER_DIR } from './paths.js';
import { loadOrCreateSecrets } from './secrets.js';
import { runSeed } from './seed.js';
import { createLogger, ensureDir, randomHex, rotateIfBig, writeJsonAtomic } from './util.js';

export const DEFAULT_OPTIONS = {
  stage2: false,
  noSeed: false,
  publicHost: DEFAULT_PUBLIC_MQTT_HOST,
  pgPort: PORTS.pg,
  keepSecrets: false,
  devices: 2,
  timeScale: 1,
  corsOrigins: DEFAULT_CORS_ORIGINS,
  strictMigrations: false,
  foreground: false,
};

/**
 * @param {Partial<typeof DEFAULT_OPTIONS>} options
 */
export async function runDaemon(options = {}) {
  const o = { ...DEFAULT_OPTIONS, ...options };
  const rt = runtimePaths();
  ensureDir(rt.dir);
  for (const f of Object.values(rt.logs)) rotateIfBig(f);
  const log = createLogger(rt.logs.daemon, { echo: o.foreground });
  const token = randomHex(16);
  const startedAt = new Date().toISOString();
  writeJsonAtomic(rt.pidsFile, { daemon: process.pid, token, started_at: startedAt });

  const stack = {
    status: 'starting',
    started_at: startedAt,
    ready_at: null,
    daemon_pid: process.pid,
    options: { stage2: o.stage2, public_host: o.publicHost, devices: o.devices, time_scale: o.timeScale, keep_secrets: o.keepSecrets },
    components: {},
    warnings: [],
    error: null,
    files: {
      runtime_dir: rt.dir,
      secrets: rt.secretsFile,
      accounts: rt.accountsFile,
      pids: rt.pidsFile,
      logs: rt.logs,
      sim_state_dir: rt.simState,
    },
  };
  const flush = () => writeJsonAtomic(rt.stackFile, stack, { mode: 0o644 });
  flush();

  const closers = [];
  let shuttingDown = null;
  async function shutdown(reason, code = 0) {
    if (shuttingDown) return shuttingDown;
    shuttingDown = (async () => {
      log('shutdown_begin', { reason });
      stack.status = 'stopping';
      try { flush(); } catch (_) { /* yok say */ }
      for (const { name, fn } of [...closers].reverse()) {
        try {
          await fn();
          log('shutdown_step', { step: name });
        } catch (err) {
          log('shutdown_step_failed', { step: name, error: err && err.message });
        }
      }
      stack.status = code === 0 ? 'stopped' : 'failed';
      try { flush(); } catch (_) { /* yok say */ }
      log('shutdown_done', { reason });
      process.exit(code);
    })();
    return shuttingDown;
  }
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK']) process.on(sig, () => { shutdown(sig); });
  process.on('uncaughtException', (err) => { log('uncaught_exception', { error: err && err.message, stack: err && err.stack }); shutdown('uncaughtException', 1); });
  process.on('unhandledRejection', (err) => { log('unhandled_rejection', { error: err && err.message }); });

  try {
    // ------------------------------------------------------------------ on kontroller
    const hadSecrets = fs.existsSync(rt.secretsFile);
    if (fs.existsSync(rt.pgData) && !hadSecrets) {
      throw new Error('.runtime/pgdata var ama secrets.json yok (veritabani parolasi bilinmiyor). `node run.js reset` calistirin.');
    }
    const { secrets, created, rotated } = loadOrCreateSecrets(rt, { keepSecrets: o.keepSecrets });
    log('secrets_ready', { created, rotated: rotated.join(',') || '-' });
    const accounts = ensureDeviceAccounts(rt, { devices: o.devices });

    const pgm = new PgManager({ dataDir: rt.pgData, password: secrets.db_password, port: o.pgPort, logFile: rt.logs.pg, log });
    const pgRunning = (await pgm.status()).running;
    const portChecks = [
      ...(pgRunning ? [] : [['PostgreSQL', o.pgPort, '--pg-port N']]),
      ['MQTT', PORTS.mqtt, 'QA_MQTT_PORT'],
      ['MQTT WebSocket', PORTS.mqttWs, 'QA_MQTT_WS_PORT'],
      ['broker kontrol', PORTS.brokerControl, 'QA_BROKER_CONTROL_PORT'],
      ['gozeticisi kontrol', PORTS.supervisor, 'QA_SUPERVISOR_PORT'],
      ...DEVICE_PLAN.filter((d) => d.sim).slice(0, o.devices).map((d) => [`simulator ${d.key}`, PORTS.sims[d.portIndex], `QA_SIM_PORT_${d.portIndex + 1}`]),
      ...(o.stage2 ? [['REST API', PORTS.api, 'QA_API_PORT'], ['SMTP cukuru', PORTS.smtp, 'QA_SMTP_PORT']] : []),
    ];
    const busy = [];
    for (const [name, port, hint] of portChecks) {
      const st = await portStatus(port);
      if (st.busy) busy.push(`${name} :${port} dolu -> ${describeOwners(st.owners)} (degistirmek icin ${hint})`);
    }
    if (busy.length) throw new Error(`Port cakismasi:\n  - ${busy.join('\n  - ')}`);

    // ------------------------------------------------------------------ PostgreSQL
    const pgState = await pgm.start();
    closers.push({ name: 'postgresql', fn: () => pgm.stop() });
    stack.components.postgres = { port: o.pgPort, pid: pgState.pid, database: pgm.database, user: pgm.user, data_dir: rt.pgData, host: HOST };
    flush();

    // ------------------------------------------------------------------ MQTT broker (EMQX taklidi)
    const store = new PgCredentialStore({ connectionString: pgm.connectionString });
    closers.push({ name: 'credential-store', fn: () => store.close() });
    const broker = await startBroker({
      store,
      backend: { username: secrets.mqtt_backend_user, password: secrets.mqtt_backend_pass },
      host: HOST,
      port: PORTS.mqtt,
      wsPort: PORTS.mqttWs,
      controlPort: PORTS.brokerControl,
      emqxApiKey: secrets.emqx_api_key,
      emqxApiSecret: secrets.emqx_api_secret,
      logFile: rt.logs.broker,
    });
    closers.push({ name: 'broker', fn: () => broker.close() });
    stack.components.broker = {
      host: HOST, mqtt_port: broker.port, ws_port: broker.wsPort, control_port: broker.controlPort,
      store_ready: broker.isStoreReady(), log: rt.logs.broker,
    };
    flush();

    // ------------------------------------------------------------------ cihaz simulatorleri
    const simLog = createLogger(rt.logs.sim);
    const fleet = new DeviceFleet({ log: simLog, stateDir: rt.simState });
    for (const d of DEVICE_PLAN.filter((x) => x.sim).slice(0, o.devices)) {
      const info = accounts.devices[d.key];
      fleet.add(d.key, {
        uid: d.uid,
        relays: d.relays,
        httpPort: PORTS.sims[d.portIndex],
        timeScale: o.timeScale,
        homeWifi: { ssid: accounts.wifi.ssid, pass: accounts.wifi.password },
        wifiConnected: d.key === 'home1',
        localKey: d.key === 'home1' ? info.bootstrap_local_key : '',
        // firmware sunucu kilidi (MqttHostPolicy.h): QA test sunuculari + istemciye bildirilen MQTT adresi (seed bunu /api/mqtt/config'e yazar)
        mqttHostAllow: `${QA_MQTT_HOST_ALLOW},${o.publicHost}`,
        // firmware >= 1.3.0 bootstrap'i (kimlik dondurulunce / yokken): istek yerel sunucuya gider
        bootstrapApi: `http://127.0.0.1:${PORTS.api}`,
      });
    }
    await fleet.startAll();
    closers.push({ name: 'simulators', fn: () => fleet.stopAll() });
    stack.components.simulators = fleet.list().map((s) => ({
      name: s.name, uid: s.uid, http_port: s.http_port, relays: s.relays,
      emulator_url: `http://10.0.2.2:${s.http_port}`, log: rt.logs.sim,
    }));
    flush();

    // ------------------------------------------------------------------ Asama Q2 (stage2)
    let degraded = false;
    if (o.stage2) {
      const mailTls = await ensureMailTls(rt.mailTlsDir);
      const mail = await startMailSink({ dir: rt.mailDir, port: PORTS.smtp, logFile: rt.logs.mail, tls: mailTls });
      closers.push({ name: 'smtp-sink', fn: () => mail.close() });
      stack.components.smtp = { port: mail.port, mail_dir: rt.mailDir, starttls: true };

      const mig = await applyMigrations({ rt, dbUrl: pgm.connectionString, serverDir: SERVER_DIR, log, strict: o.strictMigrations });
      stack.components.migrations = { method: mig.method, ok: mig.ok, ...(mig.failed ? { failed: mig.failed } : {}), ...(mig.code !== undefined ? { exit_code: mig.code } : {}), log: rt.logs.migrate };
      if (!mig.ok) { degraded = true; stack.warnings.push(`migration basarisiz (${mig.method}); ayrinti: ${rt.logs.migrate}`); }
      flush();

      await quarantineMigrationUsers({ rt, dbUrl: pgm.connectionString, log }).catch((e) => stack.warnings.push(`kullanici karantinasi: ${e.message}`));
      await broker.refreshStore();
      stack.components.broker.store_ready = broker.isStoreReady();

      try {
        const env = buildServerEnv({ secrets, dbUrl: pgm.connectionString, publicHost: o.publicHost, corsOrigins: o.corsOrigins, mailCaFile: mail.caFile });
        const api = await startApiServer({ rt, serverDir: SERVER_DIR, env, port: PORTS.api, log });
        closers.push({ name: 'api-server', fn: () => api.stop() });
        stack.components.api = { port: PORTS.api, pid: api.pid, base_url: `http://127.0.0.1:${PORTS.api}/api/v1`, emulator_url: `http://10.0.2.2:${PORTS.api}/api`, log: rt.logs.api };
        flush();

        if (!o.noSeed) {
          const res = await runSeed({ rt, dbUrl: pgm.connectionString, log, verifyOnline: true });
          stack.components.seed = { ok: res.ok, summary: res.summary, steps: res.steps, ...(res.notes.length ? { notes: res.notes } : {}) };
          if (!res.ok) { degraded = true; stack.warnings.push('tohumlama kismen basarisiz (stack.json components.seed.steps)'); }
        }
      } catch (err) {
        degraded = true;
        stack.components.api = { port: PORTS.api, error: err.message };
        stack.warnings.push(`sunucu baslatilamadi: ${err.message.split('\n')[0]}`);
        log('api_start_failed', { error: err.message });
      }
    }

    // ------------------------------------------------------------------ kontrol ucu
    const control = http.createServer((req, res) => {
      const send = (status, body) => {
        const text = JSON.stringify(body);
        res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(text), 'Cache-Control': 'no-store' });
        res.end(text);
      };
      if (req.method === 'GET' && req.url === '/health') {
        return send(200, { status: stack.status, daemon_pid: process.pid, components: Object.keys(stack.components), warnings: stack.warnings });
      }
      if (req.method === 'POST' && req.url === '/shutdown') {
        if (req.headers['x-qa-token'] !== token) return send(403, { error: 'forbidden' });
        send(200, { ok: true });
        setTimeout(() => { shutdown('control-endpoint'); }, 50);
        return undefined;
      }
      return send(404, { error: 'not_found' });
    });
    await new Promise((resolve, reject) => {
      control.once('error', reject);
      control.listen(PORTS.supervisor, HOST, () => { control.off('error', reject); resolve(); });
    });
    closers.push({ name: 'control', fn: () => new Promise((resolve) => { control.close(() => resolve()); control.closeAllConnections?.(); }) });
    stack.components.supervisor = { control_port: PORTS.supervisor, pid: process.pid };

    stack.status = degraded ? 'degraded' : 'ready';
    stack.ready_at = new Date().toISOString();
    flush();
    log('stack_ready', { status: stack.status });
    return { stack, shutdown };
  } catch (err) {
    stack.status = 'failed';
    stack.error = err.message;
    try { flush(); } catch (_) { /* yok say */ }
    log('startup_failed', { error: err.message });
    await shutdown('startup_failed', 1);
    return undefined;
  }
}

