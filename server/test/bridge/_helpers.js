'use strict';

// Ortak test yardimcilari (WP-C). Dosya adi `_` ile basladigi icin `node --test` bunu
// test olarak CALISTIRMAZ ("*.test.js" deseni).
//
// Gercek veritabani / broker KULLANILMAZ: sahte db, sahte MQTT istemcisi ve sahte
// zamanlayicilar.

const { EventEmitter } = require('node:events');

/** Sessiz logger; cagrilari saklar (testlerde "sir sizmadi mi" denetimi icin). */
function makeLogger() {
  const lines = [];
  const push = (level) => (...args) => lines.push(`${level}: ${args.map(String).join(' ')}`);
  return { log: push('log'), warn: push('warn'), error: push('error'), lines };
}

/**
 * Sahte veritabani.
 * rules: [{ match: RegExp | (text)=>boolean, reply: object | (text, params)=>object }]
 * Ilk eslesen kural yanit verir; eslesme yoksa { rows: [], rowCount: 0 }.
 */
function makeFakeDb(rules = []) {
  const calls = [];
  const txLog = [];
  const ruleList = [...rules];

  function run(text, params, inTx) {
    calls.push({ text, params, inTx });
    for (const r of ruleList) {
      const ok = r.match instanceof RegExp ? r.match.test(text) : r.match(text, params);
      if (ok) {
        const out = typeof r.reply === 'function' ? r.reply(text, params) : r.reply;
        if (out instanceof Error) return Promise.reject(out);
        return Promise.resolve(out === undefined ? { rows: [], rowCount: 0 } : out);
      }
    }
    return Promise.resolve({ rows: [], rowCount: 0 });
  }

  return {
    calls,
    txLog,
    addRule(rule) {
      ruleList.unshift(rule);
    },
    query: (text, params) => run(text, params, false),
    async withTransaction(fn) {
      txLog.push('BEGIN');
      try {
        const tx = { query: (text, params) => run(text, params, true) };
        const result = await fn(tx);
        txLog.push('COMMIT');
        return result;
      } catch (err) {
        txLog.push('ROLLBACK');
        throw err;
      }
    },
    /** Belirli bir kalip iceren sorgulari dondurur. */
    find(re) {
      return calls.filter((c) => re.test(c.text));
    },
  };
}

/** Sahte zamanlayicilar: kendiliginden ilerlemez, testler `fire*` ile tetikler. */
function makeFakeTimers() {
  let seq = 0;
  const timeouts = new Map();
  const intervals = new Map();
  const mk = (map, fn, ms) => {
    const id = ++seq;
    const handle = { id, fn, ms, unref() { return handle; } };
    map.set(id, handle);
    return handle;
  };
  return {
    setTimeout: (fn, ms) => mk(timeouts, fn, ms),
    clearTimeout: (h) => { if (h) timeouts.delete(h.id); },
    setInterval: (fn, ms) => mk(intervals, fn, ms),
    clearInterval: (h) => { if (h) intervals.delete(h.id); },
    pendingTimeouts: () => [...timeouts.values()],
    pendingIntervals: () => [...intervals.values()],
    fireTimeout(h) {
      if (timeouts.has(h.id)) {
        timeouts.delete(h.id);
        h.fn();
      }
    },
    fireInterval(h) {
      if (intervals.has(h.id)) h.fn();
    },
  };
}

/** Sahte mqtt.js istemcisi (yalnizca kopruye gereken yuzey). */
function makeFakeClient({ autoAck = true } = {}) {
  const ee = new EventEmitter();
  ee.connected = false;
  ee.options = {};
  ee.outgoing = {};
  ee.published = [];
  ee.subscribed = [];
  ee.removed = [];
  ee.ended = false;
  ee.autoAck = autoAck;
  ee.publishError = null;
  ee._lastId = 0;
  ee.grant = null; // (topics) => granted[]

  ee.publish = (topic, payload, opts, cb) => {
    const id = ++ee._lastId;
    ee.outgoing[id] = { cb };
    ee.published.push({ topic, payload, opts, id });
    if (ee.autoAck) {
      setImmediate(() => {
        delete ee.outgoing[id];
        if (cb) cb(ee.publishError || null);
      });
    }
    return ee;
  };
  ee.getLastMessageId = () => ee._lastId;
  ee.removeOutgoingMessage = (id) => {
    const entry = ee.outgoing[id];
    delete ee.outgoing[id];
    ee.removed.push(id);
    if (entry && entry.cb) entry.cb(new Error('Message removed'));
    return ee;
  };
  ee.subscribe = (topics, opts, cb) => {
    ee.subscribed.push({ topics, opts });
    setImmediate(() => cb(null, ee.grant ? ee.grant(topics) : topics.map((t) => ({ topic: t, qos: 1 }))));
    return ee;
  };
  ee.end = (force, opts, cb) => {
    ee.ended = true;
    ee.connected = false;
    setImmediate(() => cb && cb());
    return ee;
  };
  return ee;
}

function makeFakeMqttLib(client) {
  const lib = {
    calls: [],
    connect(url, options) {
      lib.calls.push({ url, options });
      return client;
    },
  };
  return lib;
}

/** Bekleyen mikro/makro gorevlerin bitmesi icin kisa bekleme (setImmediate + setTimeout). */
async function flush(ms = 0) {
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setTimeout(resolve, ms));
  await new Promise((resolve) => setImmediate(resolve));
}

module.exports = {
  makeLogger,
  makeFakeDb,
  makeFakeTimers,
  makeFakeClient,
  makeFakeMqttLib,
  flush,
};
