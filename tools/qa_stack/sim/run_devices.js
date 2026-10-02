// Birden fazla cihaz simulatorunu TEK sureçte yonetir (farkli HTTP portlari: 8081, 8082, 8083 ...).
//
//   node sim/run_devices.js                       # varsayilan 3 cihaz (8081 provizyonsuz, 8082 hazir, 8083 provizyonsuz 16 role)
//   node sim/run_devices.js --config devices.json # [{ name, uid, httpPort, relays, localKey, mqtt, ... }]
//   node sim/run_devices.js --mqtt-host 127.0.0.1 --mqtt-port 1883 --time-scale 10 --state-dir .runtime/sim
//
// Programatik: const fleet = new DeviceFleet({ stateDir }); fleet.add('home1', { uid, httpPort, ... }); await fleet.startAll();
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { PORTS } from '../lib/config.js';
import { createLogger, ensureDir, randomToken } from '../lib/util.js';
import { DeviceSimulator } from './device_sim.js';

export class DeviceFleet {
  /** @param {{log?:Function, stateDir?:string|null}} [o] */
  constructor({ log = () => {}, stateDir = null } = {}) {
    this.log = log;
    this.stateDir = stateDir;
    /** @type {Map<string, DeviceSimulator>} */
    this.sims = new Map();
    this.started = false;
  }

  /** @returns {DeviceSimulator} */
  add(name, options) {
    if (this.sims.has(name)) throw new Error(`cihaz adi zaten var: ${name}`);
    for (const [n, s] of this.sims) {
      if (s.uid === options.uid) throw new Error(`UID zaten kullanimda: ${options.uid} (${n})`);
      if (options.httpPort && s.opts.httpPort === options.httpPort) throw new Error(`HTTP portu zaten kullanimda: ${options.httpPort} (${n})`);
    }
    const opts = { ...options, log: this.log };
    if (this.stateDir && !opts.stateFile) {
      ensureDir(this.stateDir);
      opts.stateFile = path.join(this.stateDir, `${options.uid}.json`);
    }
    const sim = new DeviceSimulator(opts);
    this.sims.set(name, sim);
    return sim;
  }

  get(nameOrUid) {
    if (this.sims.has(nameOrUid)) return this.sims.get(nameOrUid);
    for (const s of this.sims.values()) if (s.uid === nameOrUid) return s;
    return undefined;
  }

  async startAll() {
    const started = [];
    try {
      for (const [name, sim] of this.sims) {
        await sim.start();
        started.push(sim);
        this.log('fleet_started', { name, uid: sim.uid, http_port: sim.httpPort, relays: sim.totalRelays(), provisioned: sim.isProvisioned() });
      }
    } catch (err) {
      await Promise.all(started.map((s) => s.stop().catch(() => {})));
      throw err;
    }
    this.started = true;
    return this;
  }

  async stopAll() {
    await Promise.all([...this.sims.values()].map((s) => s.stop().catch(() => {})));
    this.started = false;
  }

  list() {
    return [...this.sims].map(([name, s]) => ({
      name,
      uid: s.uid,
      http_port: s.httpPort,
      relays: s.totalRelays(),
      provisioned: s.isProvisioned(),
      wifi_connected: s.wifi.connected,
      mqtt_state: s.mqttState,
    }));
  }
}

const OPTION_KEYS = ['time-scale', 'state-dir', 'config', 'log-file', 'help', 'print-keys', 'home-wifi-pass', 'home-wifi-ssid', 'base-port'];

const HELP = `node sim/run_devices.js [--config devices.json] [--state-dir DIR] [--time-scale N]
          [--base-port 8081] [--home-wifi-ssid S --home-wifi-pass P] [--log-file F] [--print-keys]
  --config  JSON dizisi: her oge DeviceSimulator secenekleri + "name" (uid, httpPort, relays, localKey, mqtt:{host,port,user,pass}, ...)
  Varsayilan plan: 3 cihaz -> new1 (provizyonsuz, 8 role), home1 (hazir, rastgele yerel anahtar), new2 (provizyonsuz, 16 role)
  Yerel anahtarlar <state-dir>/fleet_keys.json dosyasina yazilir (--print-keys ile konsola da).`;

/** Varsayilan 3 cihazli plan; yerel anahtar yalnizca hazir cihaz icin uretilir. */
export function defaultPlan({ basePort = PORTS.sims[0], timeScale = 1, homeSsid, homePass } = {}) {
  const homeWifi = { ssid: homeSsid || undefined, pass: homePass || '' };
  const common = { timeScale, homeWifi };
  // MQTT kimligi yoktur: cihazlar yerelde calisir; kimlik POST /api/mqtt/config ile verilir (veya --config ile).
  return [
    { name: 'new1', uid: 'AHBU-S3-0A0001', httpPort: basePort, relays: 8, ...common },
    { name: 'home1', uid: 'AHBU-S3-0A0002', httpPort: basePort + 1, relays: 8, localKey: randomToken(16), wifiConnected: true, ...common },
    { name: 'new2', uid: 'AHBU-S3-0A0003', httpPort: basePort + 2, relays: 16, ...common },
  ];
}

async function main() {
  const { parseArgs } = await import('node:util');
  const { values } = parseArgs({
    options: Object.fromEntries(OPTION_KEYS.map((k) => [k, k === 'help' || k === 'print-keys' ? { type: 'boolean' } : { type: 'string' }])),
  });
  if (values.help) { console.log(HELP); return; }

  const stateDir = values['state-dir'] ? path.resolve(values['state-dir']) : null;
  const log = createLogger(values['log-file'] || null, { echo: !values['log-file'] });
  let plan;
  if (values.config) {
    plan = JSON.parse(fs.readFileSync(values.config, 'utf8'));
    if (!Array.isArray(plan)) throw new Error('--config bir JSON dizisi olmali');
  } else {
    plan = defaultPlan({
      basePort: values['base-port'] ? Number(values['base-port']) : PORTS.sims[0],
      timeScale: values['time-scale'] ? Number(values['time-scale']) : 1,
      homeSsid: values['home-wifi-ssid'], homePass: values['home-wifi-pass'],
    });
  }

  const fleet = new DeviceFleet({ log, stateDir });
  const keys = {};
  for (const item of plan) {
    const { name, ...opts } = item;
    if (!name) throw new Error('her cihazda "name" zorunlu');
    if (values['time-scale'] && opts.timeScale === undefined) opts.timeScale = Number(values['time-scale']);
    fleet.add(name, opts);
    if (opts.localKey) keys[opts.uid] = opts.localKey;
  }
  await fleet.startAll();

  if (stateDir && Object.keys(keys).length) {
    ensureDir(stateDir);
    const keyFile = path.join(stateDir, 'fleet_keys.json');
    fs.writeFileSync(keyFile, `${JSON.stringify(keys, null, 2)}\n`, { mode: 0o600 });
    console.log(`[fleet] yerel anahtarlar: ${keyFile}`);
  }
  if (values['print-keys']) for (const [uid, k] of Object.entries(keys)) console.log(`[fleet] ${uid} X-Device-Key=${k}`);
  for (const d of fleet.list()) console.log(`[fleet] ${d.name.padEnd(6)} ${d.uid.padEnd(16)} http://127.0.0.1:${d.http_port} relays=${d.relays} provisioned=${d.provisioned}`);

  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    await fleet.stopAll();
    process.exit(0);
  };
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGBREAK']) process.on(sig, stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((e) => { console.error(`hata: ${e.message}`); process.exit(1); });
}
