// Test yardimcilari (bu dosya test olarak kosulmaz: ad *.test.js degil).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import mqtt from 'mqtt';
import bcrypt from 'bcryptjs';
import { startBroker } from '../lib/broker.js';
import { MemoryCredentialStore } from '../lib/credstore.js';
import { createLogger, randomB64Url, sleep, waitFor } from '../lib/util.js';

export { sleep, waitFor };

export const hashPw = (pw) => bcrypt.hashSync(pw, 4); // test icin dusuk maliyet

export function tmpDir(prefix = 'qa_stack_test_') {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

/** Bellek ici depo + rastgele sirlarla bir test brokeri baslatir (rastgele portlar). */
export async function startTestBroker({ store = new MemoryCredentialStore(), logFile, trace = false, emqxApiKey, emqxApiSecret } = {}) {
  const backend = { username: 'backend_service', password: randomB64Url(18) };
  const broker = await startBroker({
    store,
    backend,
    host: '127.0.0.1',
    port: 0,
    wsPort: null,
    controlPort: 0,
    logFile,
    log: createLogger(logFile || null),
    trace,
    storePollMs: 100,
    emqxApiKey,
    emqxApiSecret,
  });
  return { broker, store, backend, port: broker.port, controlPort: broker.controlPort, log: broker.log };
}

/** Baglanir; reddedilirse hata nesnesi `code` (CONNACK donus kodu) tasir. */
export function connect({ port, username, password, clientId, will, clean = true, keepalive = 30, protocolVersion = 4 }) {
  return new Promise((resolve, reject) => {
    const c = mqtt.connect(`mqtt://127.0.0.1:${port}`, {
      username, password, clientId, will, clean, keepalive, protocolVersion,
      reconnectPeriod: 0, connectTimeout: 5000,
    });
    const onError = (e) => { c.removeListener('connect', onConnect); c.end(true); reject(e); };
    const onConnect = () => { c.removeListener('error', onError); c.on('error', () => {}); resolve(c); };
    c.once('connect', onConnect);
    c.once('error', onError);
  });
}

/** Abonelik: { granted:boolean, qos } doner (0x80 = reddedildi). */
export function subscribe(client, topic, qos = 1) {
  return new Promise((resolve) => {
    client.subscribe(topic, { qos }, (err, granted) => {
      if (err) return resolve({ granted: false, qos: 128, error: err });
      const g = granted && granted[0];
      resolve({ granted: !!g && g.qos !== 128, qos: g ? g.qos : 128 });
    });
  });
}

/** Gelen mesajlari bir diziye toplar. */
export function collect(client) {
  const msgs = [];
  client.on('message', (topic, payload, packet) => {
    msgs.push({ topic, payload: payload.toString('utf8'), retain: !!packet.retain, qos: packet.qos });
  });
  return msgs;
}

export function publish(client, topic, payload, opts = {}) {
  return new Promise((resolve, reject) => {
    client.publish(topic, typeof payload === 'string' ? payload : JSON.stringify(payload), { qos: 1, ...opts }, (err) => {
      if (err) reject(err); else resolve();
    });
  });
}

export async function closeClient(c) {
  if (!c) return;
  await new Promise((resolve) => c.end(true, {}, resolve));
}

export function endClients(...clients) {
  return Promise.all(clients.flat().filter(Boolean).map(closeClient));
}
