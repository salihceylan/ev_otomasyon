// EMQX davranisini taklit eden aedes tabanli MQTT broker (CONTRACTS §2.2). YALNIZCA QA icindir:
// TLS yok, tek dugum, bellek ici kalicilik (retained mesajlar broker yeniden baslayinca silinir).
//
//  Kimlik dogrulama : backend_service (ortamdan, superuser) + PostgreSQL mqtt_credentials (bcrypt, expires_at)
//  Yetkilendirme    : mqtt_acl tablosu; deny onceliklidir; kural yoksa deny; yetkisiz abonelik SUBACK 0x80,
//                     yetkisiz yayin DUSURULUR (baglanti kapanmaz, EMQX deny_action=ignore gibi) ve loglanir
//  Kontrol ucu      : 127.0.0.1:18083 -> POST /kick, EMQX v5 uyumlu alt kume (DELETE /api/v5/clients/:id ...)
//  Log              : parola yazilmaz
import http from 'node:http';
import net from 'node:net';
import bcrypt from 'bcryptjs';
import { Aedes } from 'aedes';
import aedesServerFactory from 'aedes-server-factory';
import { evaluateAcl } from './acl.js';
import { StoreUnavailableError } from './credstore.js';
import { createLogger, safeEqual } from './util.js';

const { createServer } = aedesServerFactory;

// Yetkisiz yayinlar bu konuya cevrilip etkisizlestirilir ($ ile baslayan konulara joker abone olamaz).
export const DROP_TOPIC = '$SYS/qa/dropped';

// Bilinmeyen kullanici icin de bcrypt maliyeti odenir (zamanlama farkini azaltir).
const DUMMY_HASH = bcrypt.hashSync('qa-dummy-password', 10);

const fmtIp = (client) => {
  const c = client && client.conn;
  const addr = (c && (c.remoteAddress || (c.socket && c.socket.remoteAddress) || (c._socket && c._socket.remoteAddress))) || '-';
  return String(addr).replace(/^::ffff:/, '');
};

function readBody(req, limit = 4096) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(Object.assign(new Error('govde cok buyuk'), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function sendJson(res, status, obj) {
  const body = obj === undefined ? '' : JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

/**
 * @param {object} opts
 * @param {import('./credstore.js').PgCredentialStore} opts.store
 * @param {{username:string, password:string}} opts.backend  superuser (ortamdan)
 * @param {string} [opts.host]            varsayilan 127.0.0.1
 * @param {number} [opts.port]            MQTT TCP (0 = rastgele); varsayilan 1883
 * @param {number|null} [opts.wsPort]     MQTT over WebSocket (null = kapali)
 * @param {number|null} [opts.controlPort] kontrol HTTP ucu (null = kapali); varsayilan 18083
 * @param {string} [opts.emqxApiKey]      EMQX-uyumlu uclar icin Basic auth (verilmezse dogrulama yok)
 * @param {string} [opts.emqxApiSecret]
 * @param {string} [opts.logFile]
 * @param {Function} [opts.log]           createLogger() ciktisi
 * @param {boolean} [opts.trace]          kabul edilen yayin/abonelikleri de logla (yalniz konu + boyut)
 * @param {number} [opts.storePollMs]
 */
export async function startBroker(opts) {
  const {
    store,
    backend,
    host = '127.0.0.1',
    port = 1883,
    wsPort = null,
    controlPort = 18083,
    emqxApiKey,
    emqxApiSecret,
    logFile,
    trace = false,
    storePollMs = 2000,
  } = opts;
  if (!store) throw new Error('startBroker: store zorunlu');
  if (!backend || !backend.username || !backend.password) throw new Error('startBroker: backend kimligi zorunlu');
  const log = opts.log || createLogger(logFile || null);

  let storeReady = null; // null = bilinmiyor
  const stats = { connects: 0, denied: 0, pubDenied: 0, subDenied: 0, kicks: 0 };

  // ------------------------------------------------------------------ kimlik dogrulama
  async function authenticateImpl(client, username, password) {
    if (!username) return { ok: false, code: 4, reason: 'no_username' };

    if (username === backend.username) {
      if (!safeEqual(password, backend.password)) return { ok: false, code: 4, reason: 'bad_password' };
      client.qa = { username, kind: 'backend', superuser: true };
      return { ok: true };
    }

    let row;
    try {
      row = await store.findCredential(username);
    } catch (err) {
      if (err instanceof StoreUnavailableError) return { ok: false, code: 3, reason: `store_unavailable:${err.reason}` };
      return { ok: false, code: 3, reason: `store_error:${err && err.code ? err.code : 'unknown'}` };
    }
    if (!row) {
      await bcrypt.compare(password || 'x', DUMMY_HASH);
      return { ok: false, code: 4, reason: 'unknown_user' };
    }
    const hash = String(row.password_hash || '');
    if (!hash.startsWith('$2')) return { ok: false, code: 4, reason: 'bad_hash_format' };
    let match = false;
    try {
      match = await bcrypt.compare(password || '', hash);
    } catch (_) {
      match = false;
    }
    if (!match) return { ok: false, code: 4, reason: 'bad_password' };
    if (row.expires_at && new Date(row.expires_at).getTime() <= Date.now()) {
      return { ok: false, code: 4, reason: 'expired' };
    }
    client.qa = {
      username,
      kind: row.kind || 'unknown',
      home_id: row.home_id ?? null,
      user_id: row.user_id ?? null,
      device_id: row.device_id ?? null,
      expires_at: row.expires_at ?? null,
      // EMQX authn sorgusu is_superuser dondurur; DB'de superuser isaretli satir ACL'yi atlar
      superuser: row.is_superuser === true,
    };
    return { ok: true };
  }

  function authenticate(client, username, password, callback) {
    const u = typeof username === 'string' ? username : '';
    const p = password ? Buffer.from(password).toString('utf8') : '';
    authenticateImpl(client, u, p).then((res) => {
      if (res.ok) return callback(null, true);
      stats.denied++;
      log('connect_denied', { client: client.id, user: u || '-', reason: res.reason, ip: fmtIp(client) });
      const err = new Error(res.reason);
      err.returnCode = res.code;
      return callback(err, false);
    }, (err) => {
      stats.denied++;
      log('connect_denied', { client: client.id, user: u || '-', reason: 'internal_error', detail: err && err.message });
      const e = new Error('server unavailable');
      e.returnCode = 3;
      callback(e, false);
    });
  }

  // ------------------------------------------------------------------ yetkilendirme
  async function checkAcl(client, action, topic) {
    if (!client || !client.qa) return { allowed: false, reason: 'no_identity' };
    if (client.qa.superuser) return { allowed: true, reason: 'superuser' };
    let rules;
    try {
      rules = await store.listAcl(client.qa.username);
    } catch (err) {
      const reason = err instanceof StoreUnavailableError ? `store_unavailable:${err.reason}` : 'store_error';
      return { allowed: false, reason };
    }
    return evaluateAcl(rules, { action, topic });
  }

  function authorizePublish(client, packet, callback) {
    // broker'in kendi yayinlari (client = null) ve superuser dogrudan gecer
    if (!client) return callback(null);
    checkAcl(client, 'publish', packet.topic).then((res) => {
      if (res.allowed) return callback(null);
      stats.pubDenied++;
      log('pub_denied', {
        client: client.id, user: client.qa ? client.qa.username : '-', topic: packet.topic,
        qos: packet.qos, retain: !!packet.retain, bytes: packet.payload ? packet.payload.length : 0, reason: res.reason,
      });
      // EMQX deny_action=ignore: mesaj dusurulur, baglanti kapanmaz (QoS 1/2 icin PUBACK/PUBREC yine gider).
      packet.topic = DROP_TOPIC;
      packet.retain = false;
      packet.payload = Buffer.alloc(0);
      return callback(null);
    }, () => {
      packet.topic = DROP_TOPIC;
      packet.retain = false;
      packet.payload = Buffer.alloc(0);
      callback(null);
    });
  }

  function authorizeSubscribe(client, sub, callback) {
    checkAcl(client, 'subscribe', sub.topic).then((res) => {
      if (res.allowed) {
        if (trace) log('sub_ok', { client: client.id, user: client.qa.username, topic: sub.topic, qos: sub.qos });
        return callback(null, sub);
      }
      stats.subDenied++;
      log('sub_denied', {
        client: client.id, user: client.qa ? client.qa.username : '-', topic: sub.topic, qos: sub.qos, reason: res.reason,
      });
      return callback(null, null); // SUBACK 0x80
    }, () => callback(null, null));
  }

  // ------------------------------------------------------------------ aedes
  const aedes = await Aedes.createBroker({
    authenticate,
    authorizePublish,
    authorizeSubscribe,
    maxClientsIdLength: 256,
    heartbeatInterval: 60000,
  });

  aedes.on('clientReady', (client) => {
    stats.connects++;
    log('connect_ok', {
      client: client.id, user: client.qa ? client.qa.username : '-', kind: client.qa ? client.qa.kind : '-',
      ip: fmtIp(client), clean: client.clean, proto: client.version,
    });
  });
  aedes.on('clientDisconnect', (client) => {
    log('disconnect', { client: client.id, user: client.qa ? client.qa.username : '-', clean_disconnect: !!client._disconnected });
  });
  aedes.on('clientError', (client, err) => {
    log('client_error', { client: client.id, user: client.qa ? client.qa.username : '-', error: err && err.message });
  });
  aedes.on('connectionError', (client, err) => {
    log('connection_error', { client: client && client.id, error: err && err.message });
  });
  aedes.on('keepaliveTimeout', (client) => {
    log('keepalive_timeout', { client: client.id, user: client.qa ? client.qa.username : '-' });
  });
  if (trace) {
    aedes.on('publish', (packet, client) => {
      if (!client || packet.topic.startsWith('$SYS')) return;
      log('pub_ok', { client: client.id, topic: packet.topic, qos: packet.qos, retain: !!packet.retain, bytes: packet.payload ? packet.payload.length : 0 });
    });
  }
  aedes.on('error', (err) => log('broker_error', { error: err && err.message }));

  // ------------------------------------------------------------------ dinleyiciler
  const servers = [];
  function listen(server, p, h) {
    return new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(p, h, () => {
        server.off('error', reject);
        resolve(server.address().port);
      });
    });
  }

  const tcpServer = createServer(aedes);
  servers.push(tcpServer);
  const actualPort = await listen(tcpServer, port, host);

  let actualWsPort = null;
  if (wsPort !== null && wsPort !== undefined) {
    const wsServer = createServer(aedes, { ws: true });
    servers.push(wsServer);
    actualWsPort = await listen(wsServer, wsPort, host);
  }

  // ------------------------------------------------------------------ kick
  function listClients() {
    return Object.values(aedes.clients).filter((c) => c && c.connected !== false).map((c) => ({
      clientId: c.id,
      username: c.qa ? c.qa.username : null,
      kind: c.qa ? c.qa.kind : null,
      ip: fmtIp(c),
    }));
  }

  function kick({ username, clientId } = {}) {
    const kicked = [];
    if (!username && !clientId) return kicked;
    for (const c of Object.values(aedes.clients)) {
      if (!c) continue;
      if (clientId && c.id !== clientId) continue;
      if (username && !(c.qa && c.qa.username === username)) continue;
      kicked.push(c.id);
      stats.kicks++;
      log('kick', { client: c.id, user: c.qa ? c.qa.username : '-' });
      c.close();
    }
    return kicked;
  }

  // ------------------------------------------------------------------ kontrol HTTP ucu
  let controlServer = null;
  let actualControlPort = null;
  if (controlPort !== null && controlPort !== undefined) {
    const emqxAuthRequired = !!(emqxApiKey && emqxApiSecret);
    const expectedBasic = emqxAuthRequired ? `Basic ${Buffer.from(`${emqxApiKey}:${emqxApiSecret}`).toString('base64')}` : null;

    controlServer = http.createServer(async (req, res) => {
      try {
        const url = new URL(req.url, 'http://127.0.0.1');
        const path = url.pathname.replace(/\/+$/, '') || '/';
        const method = req.method;

        // EMQX v5 uyumlu uclar icin (yapilandirildiysa) Basic dogrulama
        if (path.startsWith('/api/v5/') && emqxAuthRequired && !safeEqual(req.headers.authorization || '', expectedBasic)) {
          return sendJson(res, 401, { code: 'BAD_USERNAME_OR_PWD', message: 'Bad username or password' });
        }

        if (method === 'GET' && (path === '/status' || path === '/api/v5/status')) {
          res.writeHead(200, { 'Content-Type': 'text/plain' });
          return res.end("Node 'qa-broker@127.0.0.1' is started\nemqx is running (QA taklidi: aedes)\n");
        }

        if (method === 'POST' && path === '/kick') {
          let body = {};
          try { body = JSON.parse((await readBody(req)) || '{}'); } catch (_) {
            return sendJson(res, 400, { error: 'gecersiz JSON' });
          }
          const username = typeof body.username === 'string' ? body.username : undefined;
          const clientId = [body.clientid, body.client_id, body.clientId].find((v) => typeof v === 'string');
          if (!username && !clientId) return sendJson(res, 400, { error: 'username veya clientid zorunlu' });
          const clients = kick({ username, clientId });
          return sendJson(res, 200, { kicked: clients.length, clients });
        }

        // EMQX v5 REST: istemci atma / listeleme
        const mClient = /^\/api\/v5\/clients\/([^/]+)$/.exec(path);
        if (method === 'DELETE' && mClient) {
          const id = decodeURIComponent(mClient[1]);
          const clients = kick({ clientId: id });
          if (clients.length === 0) return sendJson(res, 404, { code: 'CLIENTID_NOT_FOUND', message: 'Client ID not found' });
          res.writeHead(204);
          return res.end();
        }
        if (method === 'GET' && mClient) {
          const id = decodeURIComponent(mClient[1]);
          const c = listClients().find((x) => x.clientId === id);
          if (!c) return sendJson(res, 404, { code: 'CLIENTID_NOT_FOUND', message: 'Client ID not found' });
          return sendJson(res, 200, { clientid: c.clientId, username: c.username, connected: true, ip_address: c.ip });
        }
        if (method === 'GET' && path === '/api/v5/clients') {
          const qUser = url.searchParams.get('username');
          const qId = url.searchParams.get('clientid');
          const data = listClients()
            .filter((c) => (!qUser || c.username === qUser) && (!qId || c.clientId === qId))
            .map((c) => ({ clientid: c.clientId, username: c.username, connected: true, ip_address: c.ip }));
          return sendJson(res, 200, { data, meta: { page: 1, limit: 100, count: data.length } });
        }
        if (method === 'POST' && path === '/api/v5/clients/kickout/bulk') {
          let body = {};
          try { body = JSON.parse((await readBody(req)) || '{}'); } catch (_) {
            return sendJson(res, 400, { code: 'BAD_REQUEST', message: 'invalid json' });
          }
          const ids = Array.isArray(body.clientids) ? body.clientids : [];
          for (const id of ids) if (typeof id === 'string') kick({ clientId: id });
          res.writeHead(204);
          return res.end();
        }

        // QA'ya ozel
        if (method === 'GET' && path === '/__qa/clients') return sendJson(res, 200, { clients: listClients() });
        if (method === 'GET' && path === '/__qa/stats') {
          return sendJson(res, 200, { ...stats, store_ready: storeReady, clients: Object.keys(aedes.clients).length });
        }
        return sendJson(res, 404, { error: 'not_found' });
      } catch (err) {
        return sendJson(res, err && err.status ? err.status : 500, { error: err && err.message ? err.message : 'hata' });
      }
    });
    servers.push(controlServer);
    actualControlPort = await listen(controlServer, controlPort, host);
  }

  // ------------------------------------------------------------------ depo hazirlik yoklamasi
  async function pollStore() {
    let ready = false;
    try { ready = await store.isReady(); } catch (_) { ready = false; }
    if (ready !== storeReady) {
      storeReady = ready;
      log(ready ? 'store_ready' : 'store_wait', { detail: ready ? 'mqtt_credentials/mqtt_acl hazir' : 'tablolar yok veya veritabani erisilemez; backend_service disindaki kimlikler reddedilir (CONNACK 3)' });
    }
  }
  await pollStore();
  const poller = setInterval(() => { pollStore().catch(() => {}); }, storePollMs);
  poller.unref();

  log('broker_started', { host, mqtt_port: actualPort, ws_port: actualWsPort, control_port: actualControlPort, trace });

  let closed = false;
  async function close() {
    if (closed) return;
    closed = true;
    clearInterval(poller);
    await new Promise((resolve) => aedes.close(resolve));
    await Promise.all(servers.map((s) => new Promise((resolve) => {
      if (!s.listening) return resolve();
      s.close(() => resolve());
      if (typeof s.closeAllConnections === 'function') s.closeAllConnections();
    })));
    log('broker_stopped', {});
  }

  return {
    aedes,
    log,
    host,
    port: actualPort,
    wsPort: actualWsPort,
    controlPort: actualControlPort,
    kick,
    listClients,
    stats: () => ({ ...stats, store_ready: storeReady }),
    isStoreReady: () => storeReady === true,
    refreshStore: pollStore,
    close,
  };
}

/** TCP portu acik mi? (status komutu icin) */
export function mqttPortOpen(host, port, timeoutMs = 1000) {
  return new Promise((resolve) => {
    const s = net.createConnection({ host, port });
    const done = (ok) => { s.destroy(); resolve(ok); };
    s.setTimeout(timeoutMs, () => done(false));
    s.once('connect', () => done(true));
    s.once('error', () => done(false));
  });
}
