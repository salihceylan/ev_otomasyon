// BootstrapCore.h (firmware) JavaScript portu: panonun bulut (MQTT) kimligini kendisi almasi. SAF MANTIK (HTTP/MQTT yok).
// Baglayici: sim/fw/mqtt_manager.js (#maybeBootstrap / #runBootstrap = MqttManager.cpp maybeBootstrap / runBootstrap).
//
//  * Istek: POST https://<mqtt_server>/api/v1/devices/bootstrap
//      {"device_uuid","ts","nonce","fw","sig"}; sig = hex(HMAC-SHA256(local_key, "ahbu-bootstrap/1|" + uid + "|" + ts + "|" + nonce)),
//      nonce = 16 rastgele bayt (32 hex), ts = UNIX saniye.
//  * Tetik: provizyonlu + ag + saat senkron + MQTT etkin + (MQTT kimligi yok YA DA broker art arda 3 kez CONNACK 4/5) + bekleme dolmus.
//  * Bekleme: 202 -> 10 dk, 401 -> 60 dk, 429 / ag / bozuk yanit -> 30 dk. 200 -> kimlik yazilir, bekleme yok.
//  * 200 yaniti siki ayristirilir; host ayrica derleme izin listesinde olmali (MqttHostPolicy.h, sahip karari 2026-10-09).
import crypto from 'node:crypto';
import { DEFAULT_MQTT_SERVER } from './sysconfig.js';
import { allowedIn, validSyntax } from './mqtt_host_policy.js';

export const SIGN_PREFIX = 'ahbu-bootstrap/1|';
export const Status = Object.freeze({ IDLE: 'idle', WAITING_CLAIM: 'waiting_claim', OK: 'ok', DENIED: 'denied', ERROR: 'error' });
export const Result = Object.freeze({ OK: 'ok', PENDING: 'pending', DENIED: 'denied', RATE_LIMITED: 'rate_limited', NET_ERROR: 'net_error', BAD_RESPONSE: 'bad_response' });
export const WAIT_PENDING_MS = 600000;
export const WAIT_DENIED_MS = 3600000;
export const WAIT_ERROR_MS = 1800000;
export const WAIT_MAX_MS = 3600000;
export const AUTH_REJECT_TRIGGER = 3;
export const MAX_RESPONSE_BYTES = 1024;   // MqttManager.cpp: daha buyuk 200 govdesi okunmaz (bos -> BAD_RESPONSE)

export function waitFor(r) {
  if (r === Result.OK) return 0;
  if (r === Result.PENDING) return WAIT_PENDING_MS;
  if (r === Result.DENIED) return WAIT_DENIED_MS;
  return WAIT_ERROR_MS;
}

/** boot::Fsm: durum + "baslangic + sure" bekleme (uint32 millis sarmasina dayanikli). */
export class BootFsm {
  constructor() { this.status = Status.IDLE; this.armed = false; this.start = 0; this.dur = 0; }
  service(now) { if (this.armed && ((now - this.start) >>> 0) >= this.dur) this.armed = false; }
  /** @param {{enabled:boolean, provisioned:boolean, netUp:boolean, timeSynced:boolean, haveCreds:boolean, authRejects:number}} i */
  needed(i) { return i.enabled && i.provisioned && i.netUp && i.timeSynced && (!i.haveCreds || i.authRejects >= AUTH_REJECT_TRIGGER); }
  due(now, i) { this.service(now); return !this.armed && this.needed(i); }
  onResult(now, r) {
    this.status = r === Result.OK ? Status.OK : r === Result.PENDING ? Status.WAITING_CLAIM : r === Result.DENIED ? Status.DENIED : Status.ERROR;
    const w = Math.min(waitFor(r), WAIT_MAX_MS);
    if (w) { this.armed = true; this.start = now >>> 0; this.dur = w; } else this.armed = false;
  }
}

export const signString = (uid, ts, nonceHex) => `${SIGN_PREFIX}${uid}|${ts >>> 0}|${nonceHex}`;
export const sign = (localKey, uid, ts, nonceHex) => crypto.createHmac('sha256', localKey).update(signString(uid, ts, nonceHex)).digest('hex');
export const buildBody = (uid, ts, nonceHex, fw, sigHex) =>
  `{"device_uuid":"${uid}","ts":${ts >>> 0},"nonce":"${nonceHex}","fw":"${fw}","sig":"${sigHex}"}`;

const printable = (s, minLen, maxLen, lo) => {
  if (typeof s !== 'string') return false;
  const b = Buffer.from(s, 'utf8');
  if (b.length < minLen || b.length > maxLen) return false;
  return b.every((c) => c >= lo && c <= 0x7e);
};

/**
 * boot::parseResponse. httpCode < 0: ag/TLS hatasi. hostAllow = derleme bayragi AHBU_MQTT_HOST_ALLOW karsiligi.
 * @returns {{result:string, creds:{host:string,port:number,user:string,pass:string}|null}}
 */
export function parseResponse(httpCode, body, hostAllow = '') {
  const fail = (result) => ({ result, creds: null });
  if (httpCode < 0) return fail(Result.NET_ERROR);
  if (httpCode === 202) return fail(Result.PENDING);
  if (httpCode === 401) return fail(Result.DENIED);
  if (httpCode === 429) return fail(Result.RATE_LIMITED);
  if (httpCode !== 200 || typeof body !== 'string' || body === '') return fail(Result.BAD_RESPONSE);
  let doc;
  try { doc = JSON.parse(body); } catch (_) { return fail(Result.BAD_RESPONSE); }
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return fail(Result.BAD_RESPONSE);
  const m = doc.mqtt;
  if (doc.status !== 'ok' || !m || typeof m !== 'object' || Array.isArray(m)) return fail(Result.BAD_RESPONSE);
  const { host, port, username: user, password: pass } = m;
  if (!Number.isInteger(port)) return fail(Result.BAD_RESPONSE);
  if (!validSyntax(host) || !allowedIn(host, DEFAULT_MQTT_SERVER, hostAllow) || port < 1 || port > 65535 ||
      !printable(user, 1, 47, 0x21) || !printable(pass, 1, 63, 0x20)) {
    return fail(Result.BAD_RESPONSE);
  }
  return { result: Result.OK, creds: { host, port, user, pass } };
}
