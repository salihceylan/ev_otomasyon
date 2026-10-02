'use strict';

// A2: start() -> yapilandirma denetimi, BIND_HOST, MQTT koprusu + kimlik temizligi + zamanlayici
// (C: scheduler.start({ mqttBridge, db })) ve zarif kapanis sirasi:
// server.close -> scheduler.stop -> mqtt kimlik temizligi stop -> mqtt end -> pool.end.

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const { once } = require('events');
const { setTestEnv, installFakeDb, installModule } = require('./_helpers');

setTestEnv({ LOCAL_KEY_SECRET: crypto.randomBytes(32).toString('hex'), PORT: '0', BIND_HOST: '127.0.0.1' });

const events = [];
const fakeDb = installFakeDb();
fakeDb.pool = { end: async () => { events.push('db.end'); } };
installModule('mqtt_bridge.js', {
  init: () => events.push('mqtt.init'),
  isConnected: () => true,
  end: async () => { events.push('mqtt.end'); },
});
let schedulerArgs = null;
installModule('scheduler.js', {
  start: (deps) => { schedulerArgs = deps; events.push('scheduler.start'); },
  stop: async () => { events.push('scheduler.stop'); },
});
installModule('services/mqtt_credential_service.js', {
  startCleanup: () => events.push('cred.startCleanup'),
  stopCleanup: () => events.push('cred.stopCleanup'),
  kickUsernames: async () => ({}),
  revokeUserAccess: async () => ({ usernames: [] }),
  revokeHomeAccess: async () => ({ usernames: [] }),
});

const { start } = require('../../src/server');

test('start(): JWT_SECRET kisaysa BASLAMAZ', () => {
  const saved = process.env.JWT_SECRET;
  process.env.JWT_SECRET = 'kisa';
  try {
    assert.throws(() => start(), /JWT_SECRET/);
  } finally {
    process.env.JWT_SECRET = saved;
  }
});

test('start(): 127.0.0.1 e baglanir, kopru/temizlik/zamanlayici baslar; kapanis sirasi dogru', async () => {
  const listenersBefore = {};
  for (const ev of ['SIGTERM', 'SIGINT', 'unhandledRejection', 'uncaughtException']) listenersBefore[ev] = process.listeners(ev).slice();
  const realExit = process.exit;
  let exitCode = null;
  process.exit = (code) => { exitCode = code; };
  try {
    const { server, shutdown } = start();
    if (!server.listening) await once(server, 'listening');
    assert.strictEqual(server.address().address, '127.0.0.1');
    assert.deepStrictEqual(events.slice(0, 3), ['mqtt.init', 'cred.startCleanup', 'scheduler.start']);
    assert.strictEqual(schedulerArgs.db, fakeDb);
    assert.ok(schedulerArgs.mqttBridge && typeof schedulerArgs.mqttBridge.init === 'function');

    await shutdown('TEST');
    assert.strictEqual(server.listening, false);
    assert.deepStrictEqual(events.slice(3), ['scheduler.stop', 'cred.stopCleanup', 'mqtt.end', 'db.end']);
    assert.strictEqual(exitCode, 0);
  } finally {
    process.exit = realExit;
    for (const ev of Object.keys(listenersBefore)) {
      for (const l of process.listeners(ev)) {
        if (!listenersBefore[ev].includes(l)) process.removeListener(ev, l);
      }
    }
  }
});
