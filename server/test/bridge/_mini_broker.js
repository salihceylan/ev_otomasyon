'use strict';

// Test icin MINIMAL MQTT 3.1.1 broker (yalnizca loopback, bellek ici). Kopruyu GERCEK `mqtt`
// kutuphanesiyle uctan uca denemek icindir (retain bayragi, QoS1 PUBACK, kalici oturum,
// yeniden baglanma). EMQX'in yerine GECMEZ: yetkilendirme/ACL, QoS2, will, v5 yoktur.
//
// Dosya adi `_` ile basladigi icin `node --test` bunu test olarak CALISTIRMAZ.

const net = require('node:net');
const mqttPacket = require('mqtt-packet');

function topicMatches(filter, topic) {
  const f = filter.split('/');
  const t = topic.split('/');
  for (let i = 0; i < f.length; i++) {
    if (f[i] === '#') return true;
    if (f[i] === '+') {
      if (t[i] === undefined) return false;
      continue;
    }
    if (f[i] !== t[i]) return false;
  }
  return f.length === t.length;
}

class MiniBroker {
  /**
   * @param {object} [opts]
   * @param {boolean} [opts.ackPublishes=true]   false: QoS1 yayinlara PUBACK VERILMEZ (yine de iletilir)
   * @param {(filter:string, clientId:string)=>boolean} [opts.rejectSubscribe]  true -> SUBACK 0x80
   */
  constructor(opts = {}) {
    this.ackPublishes = opts.ackPublishes !== false;
    this.rejectSubscribe = opts.rejectSubscribe || (() => false);
    this.clients = new Set();
    this.retained = new Map(); // topic -> { payload:Buffer }
    this.sessions = new Set(); // clientId'ler (clean=false oturumu var)
    this.sessionSubs = new Map(); // clientId -> kalici oturumun abonelikleri
    this.connects = []; // { clientId, username, password, clean, sessionPresent }
    this.subscribes = []; // { clientId, connectSeq, filters:[{topic, qos}] }  connectSeq = bu baglantinin connects[] dizisindeki sirasi
    this.published = []; // { clientId, topic, payload(string), qos, retain, dup }
    this.server = null;
    this.port = null;
    this._nextId = 1;
  }

  listen(port = 0) {
    return new Promise((resolve, reject) => {
      this.server = net.createServer((socket) => this._onSocket(socket));
      this.server.once('error', reject);
      this.server.listen(port, '127.0.0.1', () => {
        this.port = this.server.address().port;
        resolve(this.port);
      });
    });
  }

  _onSocket(socket) {
    const parser = mqttPacket.parser({ protocolVersion: 4 });
    const client = { socket, clientId: null, subs: [], msgId: 1 };
    this.clients.add(client);
    parser.on('packet', (p) => this._onPacket(client, p));
    parser.on('error', () => socket.destroy());
    socket.on('data', (d) => {
      try {
        parser.parse(d);
      } catch (_) {
        socket.destroy();
      }
    });
    socket.on('error', () => {});
    socket.on('close', () => this.clients.delete(client));
  }

  _send(client, packet) {
    if (client.socket.destroyed) return;
    client.socket.write(mqttPacket.generate(packet));
  }

  _onPacket(client, p) {
    switch (p.cmd) {
      case 'connect': {
        client.clientId = p.clientId;
        client.connectSeq = this.connects.length; // connects.push'tan ONCE: bu baglantinin dizideki indeksi
        const sessionPresent = !p.clean && this.sessions.has(p.clientId);
        if (p.clean) {
          this.sessions.delete(p.clientId);
          this.sessionSubs.delete(p.clientId);
          client.subs = [];
        } else {
          this.sessions.add(p.clientId);
          // kalici oturum: abonelikler broker'da KALIR (gercek broker davranisi)
          if (!this.sessionSubs.has(p.clientId)) this.sessionSubs.set(p.clientId, []);
          client.subs = this.sessionSubs.get(p.clientId);
        }
        this.connects.push({
          clientId: p.clientId,
          username: p.username,
          password: p.password ? p.password.toString() : undefined,
          clean: p.clean,
          sessionPresent,
        });
        this._send(client, { cmd: 'connack', returnCode: 0, sessionPresent });
        break;
      }
      case 'subscribe': {
        const granted = [];
        const accepted = [];
        for (const s of p.subscriptions) {
          if (this.rejectSubscribe(s.topic, client.clientId)) {
            granted.push(0x80);
          } else {
            const qos = Math.min(s.qos, 1);
            granted.push(qos);
            client.subs.push({ topic: s.topic, qos });
            accepted.push({ topic: s.topic, qos });
          }
        }
        this.subscribes.push({ clientId: client.clientId, connectSeq: client.connectSeq, filters: p.subscriptions.map((s) => ({ topic: s.topic, qos: s.qos })) });
        this._send(client, { cmd: 'suback', messageId: p.messageId, granted });
        // retained mesajlari abonelik aninda teslim et (retain bayragi = 1)
        for (const [topic, msg] of this.retained) {
          if (accepted.some((a) => topicMatches(a.topic, topic))) {
            this._send(client, { cmd: 'publish', topic, payload: msg.payload, qos: 0, retain: true, dup: false });
          }
        }
        break;
      }
      case 'publish': {
        const payload = Buffer.isBuffer(p.payload) ? p.payload : Buffer.from(p.payload || '');
        this.published.push({ clientId: client.clientId, topic: p.topic, payload: payload.toString('utf8'), qos: p.qos, retain: p.retain, dup: p.dup });
        if (p.retain) {
          if (payload.length === 0) this.retained.delete(p.topic);
          else this.retained.set(p.topic, { payload });
        }
        if (p.qos === 1 && this.ackPublishes) this._send(client, { cmd: 'puback', messageId: p.messageId });
        for (const other of this.clients) {
          const sub = other.subs.find((s) => topicMatches(s.topic, p.topic));
          if (!sub) continue;
          const qos = Math.min(p.qos, sub.qos);
          const out = { cmd: 'publish', topic: p.topic, payload, qos, retain: false, dup: false };
          if (qos > 0) out.messageId = (other.msgId = (other.msgId % 65535) + 1);
          this._send(other, out);
        }
        break;
      }
      case 'puback':
        break;
      case 'pingreq':
        this._send(client, { cmd: 'pingresp' });
        break;
      case 'disconnect':
        client.socket.end();
        break;
      default:
        break;
    }
  }

  /** Broker yeniden baslamis gibi: kalici oturumlar ve abonelikleri unutulur (retained KALIR). */
  forgetSessions() {
    this.sessions.clear();
    this.sessionSubs.clear();
  }

  /**
   * Baglantilari kopar (ag arizasi taklidi); dinleme surer.
   * @param {(client:{clientId:string})=>boolean} [filter]  verilirse yalnizca eslesenler kopar
   */
  dropConnections(filter = null) {
    for (const c of [...this.clients]) {
      if (!filter || filter(c)) c.socket.destroy();
    }
  }

  /** Dinlemeyi durdur + baglantilari kopar. Ayni portta tekrar listen(port) ile acilabilir. */
  async stop() {
    this.dropConnections();
    if (this.server) {
      await new Promise((resolve) => this.server.close(() => resolve()));
      this.server = null;
    }
  }

  publishedOn(topic) {
    return this.published.filter((p) => p.topic === topic);
  }
}

module.exports = { MiniBroker, topicMatches };
