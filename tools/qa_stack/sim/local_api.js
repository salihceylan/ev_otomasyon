// WebPortal.cpp (firmware) JavaScript portu: yerel HTTP API (CONTRACTS §3) + /__sim/* QA kontrol ucu.
//
// FIRMWARE DAVRANISI (kaynak: WebPortal.cpp + ApAccess.h + NetTime.h):
//  * Kimlik: "X-Device-Key" (sabit zamanli karsilastirma). IP basina 5 HATALI anahtar -> 60 sn kilit; 5. hatali istek hala 401, SONRAKI istekler
//    423 {"error":"locked","retry_after":N} + Retry-After basligi (kilit dogru anahtari da engeller). Anahtarsiz istek 401'dir ama deneme sayilmaz.
//    Tum kaynaklardan 60 sn'de 20 hatali anahtar -> tum anahtarli erisim 60 sn kilitli (NetUtil::AuthLimiter portu: sim/fw/net_time.js).
//  * Provizyonsuz cihaz (local_key yok): yalniz POST /api/factory/init ve kisitli GET /api/status; anahtarli uclar 403 "unprovisioned".
//  * Wi-Fi servis akisi (CONTRACTS 3d): GET /api/wifi/scan, POST /api/wifi/connect ve YENI GET /api/wifi/status "AP_OR_KEYED"dir: gecerli X-Device-Key
//    YA DA (istemci SoftAP arayuzunde + AP su an FIILEN WPA2 + gecerli ap_pass >= 8 + cihaz provizyonlu; karar sim/fw/ap_access.js). Digerleri (20 uc)
//    yalniz anahtarla acilir (AP istemcisi 401). AP kaynakli yolda yanlis anahtar hata sayacina islenmez ve 423 yoklanmaz; hiz siniri yalniz AP kaynakli
//    ANAHTARSIZ POST /api/wifi/connect icin: GLOBAL kayan 60 sn'de en cok 6 istek (gecersiz govdeli dahil) -> 429 {"error":"rate_limited","retry_after":N}.
//    SIMULATORDE istemcinin ag konumu (SoftAP mi, LAN mi) gercek soket adresinden (hepsi 127.0.0.1) cikarilamaz: DeviceSimulator.clientNet modelidir
//    (/__sim/client-net {mode: ap|lan}); karar yine gercek clientOnSoftAp(AP/STA alt aglari) fonksiyonundan gecer.
//  * CORS basligi YOKTUR (hatalarda ve OPTIONS'ta da); bilinmeyen yol/YONTEM (OPTIONS dahil) 404 -- 405 yoktur.
//  * Host (IPv4 sabiti / localhost / *.local) ve Origin (http://<Host> olmali) dogrulanir: 400 bad_host / 403 bad_origin (AP kaynakli yolda da AYNEN).
//  * JSON govdeli POST'larda Content-Type: application/json zorunlu (415), govde bos 400 empty_body, > 24576 bayt 413 too_large.
//  * Role/panjur komutlari kuyruga yazilir; yanit {"status":"queued"} (uygulama sonucu durum yayininda gorulur).
// QA ucu (/__sim/*) firmware'de YOKTUR; yalniz 127.0.0.1'den erisilir.
import http from 'node:http';
import { CmdType } from './command_schema.js';
import { makeCommand, CmdSource } from './fw/automation.js';
import {
  MAX_TOTAL_RELAYS, MAX_TOTAL_DIS, RelayType, DIMode, SHUTTER_RUNTIME_MIN_SEC, SHUTTER_RUNTIME_MAX_SEC, IMPULSE_MS_DEFAULT, IMPULSE_MS_MAX,
  LOCAL_KEY_MIN_LEN, LOCAL_KEY_MAX_LEN, AP_PASS_MIN_LEN, AP_PASS_MAX_LEN, CAP, isValidExtChannelCount,
} from './fw/sysconfig.js';
import {
  cStrLen, constantTimeEquals, copyUtf8Truncated, isCleanUtf8, isPrintableAsciiNoSpace, parseIntStrict, sanitizeInto, sanitizeUtf8,
} from './fw/netutil.js';
import { ConnectRequest } from './fw/wifi_manager.js';
import { isInt } from './command_schema.js';
import { AuthLimiter, ScanGate, ScanDriver, ScanPoll, ScanDecision } from './fw/net_time.js';
import { ConnectLimiter, apOrigin, clientOnSoftAp, ipToU32, via, VIA_AP } from './fw/ap_access.js';

export const MAX_BODY_BYTES = 24576;
export const AUTH_MAX_FAILS = AuthLimiter.MAX_FAILS;
export const AUTH_LOCK_MS = AuthLimiter.LOCK_MS;
export const AUTH_FAIL_FORGET_MS = AuthLimiter.FORGET_MS;
export const AUTH_GLOBAL_MAX_FAILS = AuthLimiter.GLOBAL_MAX_FAILS;
export const SCAN_MIN_INTERVAL_MS = ScanGate.MIN_INTERVAL_MS;
export const SCAN_CACHE_TTL_MS = ScanGate.CACHE_TTL_MS;
export const SCAN_TIMEOUT_MS = ScanGate.TIMEOUT_MS;
export const AP_CONNECT_MAX_PER_WINDOW = ConnectLimiter.MAX_PER_WINDOW;
export const AP_CONNECT_WINDOW_MS = ConnectLimiter.WINDOW_MS;
export const MAX_SCAN_RESULTS = 20;
export const RESTART_DELAY_MS = 600;

const CSP_HEADER = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
const LOOPBACK = new Set(['127.0.0.1', '::1', '::ffff:127.0.0.1']);

/** /__sim/* ucuna yalniz yerel makineden erisilir. */
export const isLoopbackAddress = (addr) => LOOPBACK.has(addr);

// ====================================================================== WebPortal calisma durumu (her acilista sifirlanir)
export class PortalState {
  constructor() {
    this.auth = new AuthLimiter();             // IP basina kimlik hatasi kilidi (5 hata -> 60 sn) + genel kilit (60 sn'de 20 hata)
    this.scan = new ScanGate();                // /api/wifi/scan: hiz siniri (10 sn), onbellek omru (120 sn), takilmis tarama (15 sn)
    this.apConnect = new ConnectLimiter();     // AP kaynakli ANAHTARSIZ POST /api/wifi/connect: 60 sn'de en cok 6 (GLOBAL)
    this.wifiRestorePending = false;
    this.cachedNetworks = [];
  }

  /** WebTask her turda (housekeeping): dolan kilit/hiz siniri/tarama sayaclari sonlandirilir (N6: bayat kilit/"scanning" kalmaz). */
  housekeeping(now) {
    this.auth.service(now);
    this.apConnect.service(now);
    this.scan.service(now);
  }

  /** QA ozeti: en yuksek IP hata sayaci ve en uzun kalan kilit (ms). */
  authSummary(now) {
    let failCount = 0;
    let lockedFor = this.auth.gLock.remaining(now);
    for (const s of this.auth.slots) {
      if (s.ip === 0) continue;
      failCount = Math.max(failCount, s.fails);
      lockedFor = Math.max(lockedFor, s.lock.remaining(now));
    }
    return { fail_count: failCount, locked_for_ms: lockedFor };
  }
}

// ====================================================================== yardimcilar
const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Cache-Control': 'no-store',
  Connection: 'close',
};

function sendRaw(res, status, contentType, text, headers = {}) {
  res.writeHead(status, { 'Content-Type': contentType, 'Content-Length': Buffer.byteLength(text), ...SECURITY_HEADERS, ...headers });
  res.end(text);
}

function sendJson(res, status, body, headers = {}) {
  sendRaw(res, status, 'application/json', typeof body === 'string' ? body : JSON.stringify(body), headers);
}

const err = (status, error, extra = {}) => ({ status, body: { error, ...extra } });
const ok = () => ({ status: 200, body: { status: 'ok' } });
const queued = () => ({ status: 200, body: { status: 'queued' } });

const fieldString = (o, key) => {
  if (!Object.prototype.hasOwnProperty.call(o, key)) return { s: 'missing' };
  const v = o[key];
  return typeof v === 'string' ? { s: 'ok', v } : { s: 'bad' };
};
const fieldBool = (o, key) => {
  if (!Object.prototype.hasOwnProperty.call(o, key)) return { s: 'missing' };
  return typeof o[key] === 'boolean' ? { s: 'ok', v: o[key] } : { s: 'bad' };
};
const fieldInt = (o, key) => {
  if (!Object.prototype.hasOwnProperty.call(o, key)) return { s: 'missing' };
  return isInt(o[key]) ? { s: 'ok', v: o[key] } : { s: 'bad' };
};

// ---- Host / Origin
const isDigits = (s) => /^[0-9]+$/.test(s);
function isIpv4Literal(s) {
  const parts = s.split('.');
  if (parts.length !== 4) return false;
  return parts.every((p) => isDigits(p) && p.length <= 3 && Number.parseInt(p, 10) <= 255);
}
export function isAllowedHost(hostHeader) {
  const h = String(hostHeader).trim().toLowerCase();
  if (h.length === 0 || h.length > 80) return false;
  let name = h;
  const colon = h.lastIndexOf(':');
  if (colon >= 0) {
    name = h.slice(0, colon);
    const port = h.slice(colon + 1);
    if (!isDigits(port) || port.length > 5) return false;
  }
  if (name === 'localhost') return true;
  if (isIpv4Literal(name)) return true;
  if (name.length > 6 && name.endsWith('.local')) return /^[a-z0-9.-]+$/.test(name);
  return false;
}
const stripDefaultPort = (hp) => {
  let h = String(hp).trim().toLowerCase();
  if (h.endsWith(':80')) h = h.slice(0, -3);
  return h;
};
export function originMatchesHost(origin, host) {
  const o = String(origin).trim().toLowerCase();
  if (!o.startsWith('http://')) return false;
  return stripDefaultPort(o.slice(7)) === stripDefaultPort(host);
}

// ---- gorunum
function cfgView(cfg) {
  return {
    deviceName: sanitizeInto(CAP.device_name, cfg.device_name),
    wifiSsid: sanitizeInto(CAP.wifi_ssid, cfg.wifi_ssid),
    extEnabled: cfg.ext_module_enabled,
    extChannels: cfg.ext_module_channels,
    extAddress: cfg.ext_module_address,
    rs485Baud: cfg.rs485_baud,
    staEnabled: cfg.wifi_sta_enabled,
    relays: cfg.relays.map((r) => ({ name: sanitizeInto(CAP.relay_name, r.name), type: r.type, runtime: r.runtime_sec })),
    dis: cfg.dis.map((d) => ({ name: sanitizeInto(CAP.di_name, d.name), target: d.target_relay, mode: d.mode })),
    totalRelays: cfg.totalRelays(),
    totalDIs: cfg.totalDIs(),
    provisioned: cfg.hasLocalKey(),
    mqttConfigured: cfg.hasMqttCredentials() && cfg.mqtt_enabled,
  };
}

const CONNECT_STATE_NAME = ['idle', 'connecting', 'success', 'failed'];

// ---- yapilandirma dogrulamasi (parseConfigInto)
/** root'u c (gecici kopya) icine uygular. @returns {string|null} hata kodu (null = basarili) */
export function parseConfigInto(root, c) {
  let f = fieldString(root, 'device_name');
  if (f.s === 'bad') return 'invalid_device_name';
  if (f.s === 'ok') {
    if (Buffer.byteLength(f.v) === 0 || !isCleanUtf8(f.v)) return 'invalid_device_name';
    c.device_name = copyUtf8Truncated(CAP.device_name, f.v);
  }

  f = fieldBool(root, 'ext_module_enabled');
  if (f.s === 'bad') return 'invalid_value';
  if (f.s === 'ok') c.ext_module_enabled = f.v;

  f = fieldInt(root, 'ext_module_channels');
  if (f.s === 'bad') return 'invalid_ext_channels';
  if (f.s === 'ok') {
    if (f.v < 0 || f.v > 255 || !isValidExtChannelCount(f.v)) return 'invalid_ext_channels';
    c.ext_module_channels = f.v;
  }
  if (c.ext_module_enabled && c.ext_module_channels === 0) c.ext_module_channels = 8;

  f = fieldInt(root, 'ext_module_address');
  if (f.s === 'bad') return 'invalid_ext_address';
  if (f.s === 'ok') {
    if (f.v < 1 || f.v > 247) return 'invalid_ext_address';
    c.ext_module_address = f.v;
  }

  if (Object.prototype.hasOwnProperty.call(root, 'relays')) {
    if (!Array.isArray(root.relays)) return 'invalid_value';
    const ra = root.relays;
    if (ra.length > MAX_TOTAL_RELAYS) return 'too_large';
    for (let i = 0; i < ra.length; i++) {
      const r = ra[i];
      if (r === null || typeof r !== 'object' || Array.isArray(r)) return 'invalid_value';
      const rc = c.relays[i];
      let g = fieldString(r, 'name');
      if (g.s === 'bad') return 'invalid_name';
      if (g.s === 'ok') {
        if (!isCleanUtf8(g.v)) return 'invalid_name';
        rc.name = copyUtf8Truncated(CAP.relay_name, g.v);
      }
      let type = rc.type;
      g = fieldInt(r, 'type');
      if (g.s === 'bad' || (g.s === 'ok' && (g.v < 0 || g.v > RelayType.IMPULSE))) return 'invalid_type';
      if (g.s === 'ok') type = g.v;
      let runtime = rc.runtime_sec;
      g = fieldInt(r, 'runtime_sec');
      if (g.s === 'bad' || (g.s === 'ok' && (g.v < 0 || g.v > 65535))) return 'invalid_runtime';
      if (g.s === 'ok') runtime = g.v;
      if (type === RelayType.SHUTTER_UP || type === RelayType.SHUTTER_DOWN) {
        if (runtime < SHUTTER_RUNTIME_MIN_SEC || runtime > SHUTTER_RUNTIME_MAX_SEC) return 'invalid_runtime';
      } else if (type === RelayType.IMPULSE) {
        if (runtime === 0) runtime = IMPULSE_MS_DEFAULT;
        if (runtime > IMPULSE_MS_MAX) return 'invalid_runtime';
      } else {
        runtime = 0;   // lamba: sure anlamsiz
      }
      rc.type = type;
      rc.runtime_sec = runtime;
    }
    // Panjur rolelerinin (Yukari/Asagi) eslesmesi: yetim panjur rolesi kabul edilmez
    const activeR = c.totalRelays();
    for (let p = 0; p < Math.floor(activeR / 2); p++) {
      const t1 = c.relays[2 * p].type;
      const t2 = c.relays[2 * p + 1].type;
      const up1 = t1 === RelayType.SHUTTER_UP;
      const down2 = t2 === RelayType.SHUTTER_DOWN;
      if (up1 !== down2) return 'invalid_shutter_pair';
      if (t1 === RelayType.SHUTTER_DOWN || t2 === RelayType.SHUTTER_UP) return 'invalid_shutter_pair';
    }
  }

  const totalR = c.totalRelays();
  const totalD = c.totalDIs();
  if (Object.prototype.hasOwnProperty.call(root, 'dis')) {
    if (!Array.isArray(root.dis)) return 'invalid_value';
    const da = root.dis;
    if (da.length > MAX_TOTAL_DIS) return 'too_large';
    for (let i = 0; i < da.length; i++) {
      const d = da[i];
      if (d === null || typeof d !== 'object' || Array.isArray(d)) return 'invalid_value';
      const dc = c.dis[i];
      let g = fieldString(d, 'name');
      if (g.s === 'bad') return 'invalid_name';
      if (g.s === 'ok') {
        if (!isCleanUtf8(g.v)) return 'invalid_name';
        dc.name = copyUtf8Truncated(CAP.di_name, g.v);
      }
      g = fieldInt(d, 'target_relay');
      const limit = i < totalD ? totalR : MAX_TOTAL_RELAYS;
      if (g.s === 'bad' || (g.s === 'ok' && (g.v < 0 || g.v > limit))) return 'invalid_target_relay';
      if (g.s === 'ok') dc.target_relay = g.v;
      g = fieldInt(d, 'mode');
      if (g.s === 'bad' || (g.s === 'ok' && (g.v < 0 || g.v > DIMode.SHUTTER_DOWN))) return 'invalid_mode';
      if (g.s === 'ok') dc.mode = g.v;
    }
  }
  // Ek modul kapatilir/kuculurse artik var olmayan role hedefleri (istekte acikca gelmeyenler) devre disi birakilir
  for (let i = 0; i < MAX_TOTAL_DIS; i++) {
    const limit = i < totalD ? totalR : MAX_TOTAL_RELAYS;
    if (c.dis[i].target_relay > limit) c.dis[i].target_relay = 0;
  }
  return null;
}

function shutterRelevantChange(a, b) {
  if (a.ext_module_enabled !== b.ext_module_enabled || a.ext_module_channels !== b.ext_module_channels || a.ext_module_address !== b.ext_module_address) return true;
  for (let i = 0; i < MAX_TOTAL_RELAYS; i++) if (a.relays[i].type !== b.relays[i].type || a.relays[i].runtime_sec !== b.relays[i].runtime_sec) return true;
  return false;
}

/** Host adi: harf/rakam/'.'/'-', 1..63, '.' veya '-' ile baslamaz/bitmez */
function validMqttHost(s) {
  if (typeof s !== 'string') return false;
  const n = Buffer.byteLength(s);
  if (n < 1 || n > 63) return false;
  if (s[0] === '.' || s[0] === '-' || s[s.length - 1] === '.' || s[s.length - 1] === '-') return false;
  return /^[A-Za-z0-9.-]+$/.test(s);
}

// ====================================================================== WebPortal islemcileri
/** @param {object} sim DeviceSimulator  @param {object} fw guncel acilis bilesenleri {cm, automation, wifi, mqtt, portal} */
function makeHandlers(sim, fw, ctx) {
  const { cm, automation, wifi, mqtt, portal } = fw;
  const now = () => sim.millis();
  const cfg = () => cm.config;

  const postOrFail = (cmd) => {
    if (!sim.postCommand(cmd)) return err(503, 'queue_full');
    mqtt.triggerPublish(now());
    return null;
  };

  // ---- JSON govdesi
  const readJson = () => {
    const ct = String(ctx.req.headers['content-type'] || '').toLowerCase();
    if (!ct.startsWith('application/json')) return { e: err(415, 'unsupported_media_type') };
    const raw = ctx.raw;
    if (raw === null || raw.length === 0) return { e: err(400, 'empty_body') };
    if (raw.length > MAX_BODY_BYTES) return { e: err(413, 'too_large') };
    let doc;
    try { doc = JSON.parse(raw.toString('utf8')); } catch (_) { return { e: err(400, 'invalid_json') }; }
    if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) return { e: err(400, 'invalid_json') };
    return { doc };
  };

  // ---- durum
  const restrictedStatus = (provisioned) => ({
    status: 200,
    body: {
      device: wifi.getDeviceUid(),
      name: sanitizeInto(CAP.device_name, cfg().device_name),
      fw: sim.fw_version,
      provisioned,
      wifi_connected: wifi.isConnected(),
    },
  });

  const fullStatus = () => {
    const snap = automation.getSnapshot();
    const v = cfgView(cfg());
    const staConnected = wifi.isConnected();
    const staIp = wifi.getLocalIP();
    const apIp = wifi.apIp();
    const ipStr = staConnected ? staIp : apIp;
    const staSsidRaw = staConnected ? wifi.getSSID() : (v.staEnabled ? v.wifiSsid : '');
    const cs = wifi.getConnectStatus();
    const nR = Math.min(snap.totalRelays, MAX_TOTAL_RELAYS);
    const nP = Math.floor(nR / 2);
    const nD = Math.min(snap.totalDIs, MAX_TOTAL_DIS);
    return {
      status: 200,
      body: {
        device: wifi.getDeviceUid(),
        name: v.deviceName,
        device_name: v.deviceName,
        fw: sim.fw_version,
        provisioned: true,
        ip: ipStr,
        wifi_rssi: staConnected ? wifi.getRSSI() : 0,
        uptime_sec: sim.uptimeSec(),
        wifi_connected: staConnected,
        wifi_sta_ssid: sanitizeUtf8(staSsidRaw, 32),
        wifi_sta_ip: staConnected ? staIp : '',
        wifi_sta_rssi: staConnected ? wifi.getRSSI() : 0,
        wifi_ap_active: wifi.isRecoveryApActive(),
        wifi_ap_ip: apIp,
        wifi_ap_ssid: wifi.getRecoveryApSSID(),
        wifi_last_reason: wifi.getLastDisconnectReason(),
        wifi_connect_state: CONNECT_STATE_NAME[cs.state] || 'idle',
        wifi_connect_reason: cs.reason,
        time_synced: wifi.isTimeSynced(),
        mqtt_configured: v.mqttConfigured,
        mqtt_connected: mqtt.isConnected(),
        ext_module_enabled: v.extEnabled,
        ext_module_channels: v.extChannels,
        ext_module_address: v.extAddress,
        ext_module_responding: snap.extModuleResponding,
        total_relays: v.totalRelays,
        total_dis: v.totalDIs,
        child_lock: snap.childLock,
        last_id: snap.lastId,
        relays: Array.from({ length: nR }, (_, i) => ({ id: i + 1, name: v.relays[i].name, type: v.relays[i].type, state: !!snap.relays[i] })),
        shutters: Array.from({ length: nP }, (_, p) => {
          const sh = snap.shutters[p];
          return { pair: p + 1, is_shutter: sh.configured, is_moving: sh.moving, moving: sh.moving, dir: sh.dir, pos: sh.pos, target: sh.target };
        }),
        dis: Array.from({ length: nD }, (_, i) => ({ id: i + 1, name: v.dis[i].name, state: !!snap.dis[i] })),
      },
    };
  };

  // ---- kimlik
  const remoteIp = () => sim.clientRemoteIp();

  /**
   * X-Device-Key denetimi (yanit URETMEZ; firmware WebPortal::checkKey). enforceLockAndCount=true: IP kilidi (423) yoklanir, dogru anahtar sayaci
   * sifirlar, YANLIS anahtar hata sayacina islenir (5 hata -> 60 sn kilit). false (AP kaynakli yol): kilit ve sayac islemez (yalniz "gecerli
   * anahtar sunuldu mu" sorulur; sonuc erisimi zaten AP yetkisi belirlediginden bir sizinti/oracle olusmaz).
   * @returns {{r:'UNPROVISIONED'|'LOCKED'|'MISSING'|'WRONG'|'VALID', sec?:number}}
   */
  const checkKey = (enforceLockAndCount) => {
    if (!cm.hasLocalKey()) return { r: 'UNPROVISIONED' };
    const t = now();
    const ip = ipToU32(remoteIp());
    portal.auth.service(t);   // (bu istek handleClient icindeyken tur yoklamasi atlanmis olabilir)

    // Kilit: IP basina veya genel (kalan sure = bekleme - gecen sure; saklanmis hedef yok)
    if (enforceLockAndCount) {
      const sec = portal.auth.locked(ip, t);
      if (sec > 0) return { r: 'LOCKED', sec };
    }
    const hv = ctx.req.headers['x-device-key'];
    const presented = Array.isArray(hv) ? hv.join(', ') : (hv ?? '');
    if (presented.length === 0) return { r: 'MISSING' };   // anahtarsiz istek hatali deneme sayilmaz
    if (constantTimeEquals(Buffer.from(presented, 'latin1'), cfg().local_key)) {
      if (enforceLockAndCount) portal.auth.success(ip);
      return { r: 'VALID' };
    }
    // hatali anahtar
    if (enforceLockAndCount) {
      const before = portal.auth.gLock.armed;
      portal.auth.failure(ip, t);
      const lockSec = portal.auth.locked(ip, t);
      sim.event('auth_failed', { locked: lockSec > 0 });
      if (lockSec > 0) sim.event('auth_locked', { for_ms: AuthLimiter.LOCK_MS });
      if (!before && portal.auth.gLock.armed) sim.event('auth_global_locked', { for_ms: AuthLimiter.GLOBAL_LOCK_MS });
    }
    return { r: 'WRONG' };
  };

  /** X-Device-Key dogrulamasi (KEYED uclar). @returns {object|null} hata yaniti (null = yetkili) */
  const authorize = () => {
    const k = checkKey(true);
    switch (k.r) {
      case 'VALID': return null;
      case 'UNPROVISIONED': return err(403, 'unprovisioned');
      case 'LOCKED':
        sim.counters.http_locked++;
        return { status: 423, body: { error: 'locked', retry_after: k.sec }, headers: { 'Retry-After': String(k.sec) } };
      default: return err(401, 'unauthorized');
    }
  };

  /** (a) Istemci SoftAP arayuzunde mi? Karar clientOnSoftAp'ta (saf, testli); burada yalniz girdiler toplanir. */
  const remoteOnSoftAp = () => clientOnSoftAp(
    wifi.isRecoveryApActive(), ipToU32(remoteIp()), ipToU32(wifi.apIp()), ipToU32(wifi.apMask()), ipToU32(wifi.getLocalIP()), ipToU32(wifi.staMask()),
  );

  /**
   * AP_OR_KEYED uclar (wifi scan/connect/status): gecerli X-Device-Key YA DA AP kaynakli yetki (CONTRACTS 3d): (a) istemci SoftAP arayuzunde,
   * (b) AP su an WPA2 + gecerli ap_pass var, (c) cihaz provizyonlu. AP kaynakli yol acik degilse (AP disi, ACIK kurulum AP'si, ap_pass yok) istek
   * KEYED gibi islenir (401/403/423). AP kaynakli yolda anahtar gerekmez: gecerli anahtar sunulduysa "anahtarli" sayilir (hiz siniri yok), aksi halde
   * (yok/yanlis) anahtarsiz AP yolu (ctx.viaApOrigin; connect icin hiz siniri) -- yanlis anahtar bu yolda hata sayacina islenmez.
   * @returns {object|null} hata yaniti (null = yetkili)
   */
  const authorizeApOrKeyed = () => {
    const provisioned = cm.hasLocalKey();
    const hasApPass = cStrLen(cfg().ap_pass) >= AP_PASS_MIN_LEN;
    if (!provisioned) return err(403, 'unprovisioned');   // provizyonsuz (ACIK kurulum AP'si dahil): yalniz factory/init + kisitli status
    const onAp = remoteOnSoftAp();
    const wpa2 = wifi.isRecoveryApSecured();
    if (!apOrigin(onAp, wpa2, hasApPass, provisioned)) return authorize();
    const keyOk = checkKey(false).r === 'VALID';
    ctx.viaApOrigin = via(onAp, wpa2, hasApPass, provisioned, keyOk) === VIA_AP;
    return null;
  };

  const h = {};

  h.root = () => ({ status: 200, html: ROOT_HTML(sim, wifi), headers: { 'Content-Security-Policy': CSP_HEADER } });

  h.status = () => {
    const provisioned = cm.hasLocalKey();
    // arduino-esp32 WebServer::hasHeader() YALNIZ bos olmayan deger icin true doner: bos "X-Device-Key:" basligi = baslik YOK (kisitli ozet, 401 degil)
    const hv = ctx.req.headers['x-device-key'];
    const hasKeyHeader = (Array.isArray(hv) ? hv.join(', ') : (hv ?? '')).length > 0;
    if (provisioned && hasKeyHeader) {
      const e = authorize();
      if (e) return e;
      return fullStatus();
    }
    return restrictedStatus(provisioned);
  };

  h.authCheck = () => ok();

  // ---- role / panjur
  h.relay = () => {
    const totalR = cfg().totalRelays();
    const totalPairs = Math.floor(totalR / 2);
    const a = ctx.args;
    const hasPair = a.has('pair');
    const hasCh = a.has('ch');
    if (hasPair === hasCh) return err(400, 'invalid_command');
    const arg = (k) => (a.has(k) ? a.get(k) : '');

    if (hasPair) {
      const pair = parseIntStrict(arg('pair'));
      if (pair === null || pair < 1 || pair > totalPairs) return err(400, 'invalid_pair');
      const cmd = arg('cmd');
      let c;
      if (cmd === 'up') c = makeCommand(CmdType.SHUTTER_UP, CmdSource.WEB, pair);
      else if (cmd === 'down') c = makeCommand(CmdType.SHUTTER_DOWN, CmdSource.WEB, pair);
      else if (cmd === 'stop') c = makeCommand(CmdType.SHUTTER_STOP, CmdSource.WEB, pair);
      else if (cmd === 'step') c = makeCommand(CmdType.SHUTTER_STEP, CmdSource.WEB, pair);
      else if (cmd === 'pos') {
        const val = a.has('val') ? parseIntStrict(arg('val')) : null;
        if (val === null || val < 0 || val > 100) return err(400, 'invalid_value');
        c = makeCommand(CmdType.SHUTTER_POS, CmdSource.WEB, pair, val);
      } else return err(400, 'unknown_command');
      return postOrFail(c) || queued();
    }

    const ch = parseIntStrict(arg('ch'));
    if (ch === null || ch < 1 || ch > totalR) return err(400, 'invalid_channel');
    const hasCmd = a.has('cmd');
    const hasState = a.has('state');
    if (hasCmd === hasState) return err(400, 'invalid_command');
    let c;
    if (hasCmd) {
      if (arg('cmd') !== 'toggle') return err(400, 'unknown_command');
      c = makeCommand(CmdType.RELAY_TOGGLE, CmdSource.WEB, ch);
    } else {
      const st = arg('state');
      if (st !== '0' && st !== '1') return err(400, 'invalid_value');
      c = makeCommand(CmdType.RELAY_SET, CmdSource.WEB, ch, st === '1' ? 1 : 0);
    }
    return postOrFail(c) || queued();
  };

  h.all = () => {
    const a = ctx.args;
    const cmd = a.has('cmd') ? a.get('cmd') : '';
    const map = { lightsoff: CmdType.ALL_LIGHTS_OFF, shuttersdown: CmdType.ALL_SHUTTERS_DOWN, shuttersup: CmdType.ALL_SHUTTERS_UP, shuttersstop: CmdType.ALL_SHUTTERS_STOP };
    if (!Object.prototype.hasOwnProperty.call(map, cmd)) return err(400, a.has('cmd') ? 'unknown_command' : 'invalid_command');
    return postOrFail(makeCommand(map[cmd], CmdSource.WEB)) || queued();
  };

  h.childLockGet = () => ({ status: 200, body: { child_lock: automation.getSnapshot().childLock } });

  h.childLockPost = () => {
    const j = readJson();
    if (j.e) return j.e;
    const keys = Object.keys(j.doc);
    const f = fieldBool(j.doc, 'enabled');
    if (keys.length !== 1 || f.s !== 'ok') return err(400, 'invalid_value');
    return postOrFail(makeCommand(CmdType.SET_CHILD_LOCK, CmdSource.WEB, 0, f.v ? 1 : 0)) || queued();
  };

  // ---- yapilandirma
  h.configGet = () => {
    const v = cfgView(cfg());
    return {
      status: 200,
      body: {
        device_name: v.deviceName,
        wifi_ssid: v.wifiSsid,
        wifi_sta_enabled: v.staEnabled,
        rs485_baud: v.rs485Baud,
        ext_module_enabled: v.extEnabled,
        ext_module_channels: v.extChannels,
        ext_module_address: v.extAddress,
        total_relays: v.totalRelays,
        total_dis: v.totalDIs,
        relays: v.relays.map((r, i) => ({ id: i + 1, name: r.name, type: r.type, runtime_sec: r.runtime })),
        dis: v.dis.map((d, i) => ({ id: i + 1, name: d.name, target_relay: d.target, mode: d.mode })),
      },
    };
  };

  h.configSave = () => {
    const j = readJson();
    if (j.e) return j.e;
    const tmp = cfg().clone();
    const e = parseConfigInto(j.doc, tmp);
    if (e) return err(e === 'too_large' ? 413 : 400, e);
    // canli yapilandirmaya yazma adimi (loopTask): panjur hareket halindeyse sure/tip/ek modul degisimi reddedilir
    const snap = automation.getSnapshot();
    let busy = false;
    for (let p = 0; p < snap.totalPairs && p < 20; p++) if (snap.shutters[p].moving || snap.shutters[p].waiting) busy = true;
    if (busy && shutterRelevantChange(cfg(), tmp)) return err(409, 'busy');
    const live = cfg();
    live.device_name = tmp.device_name;
    live.ext_module_enabled = tmp.ext_module_enabled;
    live.ext_module_channels = tmp.ext_module_channels;
    live.ext_module_address = tmp.ext_module_address;
    live.relays = tmp.relays;
    live.dis = tmp.dis;
    live.validate();
    if (!cm.save()) return err(500, 'storage_error');
    sim.event('config_saved', { relays: live.totalRelays() });
    return ok();
  };

  // ---- Wi-Fi
  const storeScanResults = (list) => {
    portal.cachedNetworks = [];
    for (const net of list) {
      const raw = net.ssid;
      if (cStrLen(raw) === 0) continue;
      const ssid = sanitizeUtf8(raw, 32);
      const dup = portal.cachedNetworks.find((n) => n.ssid === ssid);
      if (dup) { if (net.rssi > dup.rssi) dup.rssi = net.rssi; continue; }
      portal.cachedNetworks.push({ ssid, rssi: net.rssi, enc: !!net.enc });
    }
    portal.cachedNetworks.sort((x, y) => y.rssi - x.rssi);
    if (portal.cachedNetworks.length > MAX_SCAN_RESULTS) portal.cachedNetworks.length = MAX_SCAN_RESULTS;
  };

  /** Tarama zamanlamasi (hiz siniri >= 10 sn, onbellek omru 120 sn, takilmis tarama 15 sn) ScanGate'tedir (NetTime.h portu). */
  h.wifiScan = () => {
    const t = now();
    const refresh = ctx.args.has('refresh');
    portal.scan.service(t);

    // Surmekte olan tarama
    if (portal.scan.inProgress) {
      const st = wifi.scanComplete(t);
      const drv = st >= 0 ? ScanDriver.DONE : (st === -2 ? ScanDriver.FAILED : ScanDriver.RUNNING);   // -2 = WIFI_SCAN_FAILED
      const pr = portal.scan.poll(t, drv);
      if (pr === ScanPoll.DONE) {
        storeScanResults(wifi.scanResults());
        wifi.scanDelete();
        portal.scan.cacheStored(t);
      } else if (pr === ScanPoll.FAILED) {
        wifi.scanDelete();   // takilmis/basarisiz tarama sonsuza dek "scanning" dondurmez
      } else {
        return { status: 200, body: { status: 'scanning' } };
      }
    }

    // Onbellek bayatladiysa (veya refresh isteniyorsa) yeni tarama; en sik 10 sn'de bir
    const d = portal.scan.decide(t, refresh, wifi.isConnecting(), portal.cachedNetworks.length > 0);
    if (d.decision === ScanDecision.START) {
      wifi.scanDelete();
      wifi.scanStart(t);
      return { status: 200, body: { status: 'scanning' } };
    }
    if (d.decision === ScanDecision.SCANNING) return { status: 200, body: { status: 'scanning' } };   // hiz siniri bitince tarama baslayacak
    return {
      status: 200,
      body: { status: 'done', cached: d.cached, networks: portal.cachedNetworks.map((n) => ({ ssid: n.ssid, rssi: n.rssi, enc: n.enc })) },
    };
  };

  h.wifiConnect = () => {
    // AP kaynakli ANAHTARSIZ yol: global hiz siniri (herhangi bir 60 sn'de en cok 6 istek; Retry-After). Gecerli X-Device-Key ile gelen istekler
    // sinira girmez. Her istek sayilir (gecersiz govdeli de): kotuye kullanim siniri.
    if (ctx.viaApOrigin) {
      const r = portal.apConnect.tryAcquire(now());
      if (!r.ok) {
        sim.counters.http_rate_limited = (sim.counters.http_rate_limited || 0) + 1;
        sim.event('wifi_connect_rate_limited', { retry_after: r.retryAfterSec });
        return { status: 429, body: { error: 'rate_limited', retry_after: r.retryAfterSec }, headers: { 'Retry-After': String(r.retryAfterSec) } };
      }
      sim.event('wifi_connect_ap_origin', {});   // denetim izi (SSID/parola yazilmaz)
    }
    const j = readJson();
    if (j.e) return j.e;
    const s = fieldString(j.doc, 'ssid');
    if (s.s !== 'ok') return err(400, 'invalid_ssid');
    let pass = '';
    if (Object.prototype.hasOwnProperty.call(j.doc, 'pass') && j.doc.pass !== null) {
      const p = fieldString(j.doc, 'pass');
      if (p.s !== 'ok') return err(400, 'invalid_password');
      pass = p.v;
    }
    const sl = Buffer.byteLength(s.v);
    const pl = Buffer.byteLength(pass);
    if (sl < 1 || sl > 32) return err(400, 'invalid_ssid');
    if (pl !== 0 && (pl < 8 || pl > 63)) return err(400, 'invalid_password');
    const r = wifi.requestConnect(s.v, pass);
    if (r === ConnectRequest.INVALID_SSID) return err(400, 'invalid_ssid');
    if (r === ConnectRequest.INVALID_PASS) return err(400, 'invalid_password');
    if (r === ConnectRequest.BUSY) return err(409, 'busy');
    // Yanit simdi gider; WiFiManager ~0,5 sn sonra baglanir ve yalnizca dogrulaninca NVS'e kaydeder. (200 "connecting" BAGLANDI DEMEK DEGILDIR.)
    return { status: 200, body: { status: 'connecting' } };
  };

  /**
   * GET /api/wifi/status -- Wi-Fi servis akisi icin DAR durum (AP_OR_KEYED): baglanti denemesinin sonucu ve STA/AP ozeti. Basari YALNIZ
   * wifi_connect_state == "success" (POST /api/wifi/connect 200 "connecting" baglandi demek DEGILDIR).
   */
  h.wifiStatus = () => {
    const connected = wifi.isConnected();
    const cs = wifi.getConnectStatus();
    return {
      status: 200,
      body: {
        wifi_connect_state: CONNECT_STATE_NAME[cs.state] || 'idle',
        wifi_connect_reason: cs.reason,
        wifi_connected: connected,
        wifi_sta_ssid: sanitizeUtf8(connected ? wifi.getSSID() : '', 32),
        wifi_sta_ip: connected ? wifi.getLocalIP() : '',
        wifi_rssi: connected ? wifi.getRSSI() : 0,
        ap_active: wifi.isRecoveryApActive(),
      },
    };
  };

  h.wifiDisconnect = () => (wifi.clearCredentials() ? ok() : err(500, 'storage_error'));

  // ---- RS485 (yalniz anahtarli): firmware SmartAutomation_Rs485.cpp portu (Automation) uzerinden; ek modul QA donanim modeli gercek
  // Modbus RTU cerceveleriyle konusur. WebPortal islemleri loop-affine isler: rs485Relay/rs485Baud loopTask'ta yurutulur (burada: tek is parcacigi).
  h.rs485Send = () => {
    const j = readJson();
    if (j.e) return j.e;
    const d = fieldString(j.doc, 'data');
    if (d.s !== 'ok' || Buffer.byteLength(d.v) === 0 || Buffer.byteLength(d.v) > 256) return err(400, 'invalid_value');
    const hx = fieldBool(j.doc, 'isHex');
    if (hx.s === 'bad') return err(400, 'invalid_value');
    if (!automation.rs485Send(d.v, hx.v, now())) return err(502, 'send_failed');
    return ok();
  };

  h.rs485Logs = () => ({ status: 200, text: automation.rs485GetLogs() });

  h.rs485Clear = () => { automation.rs485ClearLogs(); return ok(); };

  h.rs485Baud = () => {
    const j = readJson();
    if (j.e) return j.e;
    const b = fieldInt(j.doc, 'baud');
    if (b.s !== 'ok') return err(400, 'invalid_baud');
    if (![9600, 19200, 38400, 115200].includes(b.v)) return err(400, 'invalid_baud');   // beyaz liste
    cfg().rs485_baud = b.v;
    automation.rs485Begin(b.v, now());
    if (!cm.save()) return err(500, 'storage_error');
    return ok();
  };

  h.rs485ScanStart = () => {
    if (automation.rs485ScanState() === 'running') return { status: 202, body: { status: 'scanning' } };
    // FW-core: ek modul panjuru hareket halindeyken tarama baslatilmaz (hat tarama suresince tutulur); hata kodu "busy", nedeni "message" duz metniyle
    if (!automation.rs485StartScan(now())) return err(503, 'busy', { message: 'ek modul panjuru hareket ediyor; tarama baslatilamadi' });
    return { status: 202, body: { status: 'scanning' } };
  };

  h.rs485ScanResult = () => {
    const st = automation.rs485ScanState();
    if (st === 'idle') return { status: 200, body: { status: 'idle' } };
    if (st === 'running') return { status: 202, body: { status: 'scanning' } };
    const r = automation.rs485ScanResult();
    return {
      status: 200,
      body: { status: 'done', found: r.found, slaveId: r.slaveId, baud: r.baud, relayStatus: r.relayStatus, rawHex: r.rawHex.slice(0, 200), info: r.info.slice(0, 200) },
    };
  };

  h.rs485Relay = () => {
    const j = readJson();
    if (j.e) return j.e;
    let sid = 1; let ch = 1; let action = 2;   // action: 1 ACIK, 0 KAPALI, 2 DEGISTIR
    let f = fieldInt(j.doc, 'slaveId');
    if (f.s === 'bad' || (f.s === 'ok' && (f.v < 1 || f.v > 247))) return err(400, 'invalid_value');
    if (f.s === 'ok') sid = f.v;
    f = fieldInt(j.doc, 'channel');
    if (f.s === 'bad' || (f.s === 'ok' && (f.v < 0 || f.v > 32))) return err(400, 'invalid_channel');
    if (f.s === 'ok') ch = f.v;
    f = fieldInt(j.doc, 'action');
    if (f.s === 'bad' || (f.s === 'ok' && (f.v < 0 || f.v > 2))) return err(400, 'invalid_value');
    if (f.s === 'ok') action = f.v;
    if (ch === 0 && action !== 0) return err(400, 'invalid_channel');   // toplu ACMA ve panjur kanallari ham komutla surulmez
    if (ch > 0) {
      const c = cfg();
      const relayIdx = 8 + (ch - 1);
      if (c.ext_module_enabled && sid === c.ext_module_address && relayIdx < MAX_TOTAL_RELAYS) {
        const t = c.relays[relayIdx].type;
        if (t === RelayType.SHUTTER_UP || t === RelayType.SHUTTER_DOWN) return err(400, 'shutter_channel');
      }
    }
    const r = automation.rs485ControlExtRelay(sid, ch, action, now());
    const body = { success: r.ok, responseHex: r.responseHex.slice(0, 160) };
    if (!r.ok) body.error = 'no_response';
    return { status: r.ok ? 200 : 502, body };
  };

  // ---- sistem
  h.reboot = () => ({ status: 200, body: { status: 'rebooting' }, after: () => automation.requestRestart(RESTART_DELAY_MS, now()) });

  h.reset = () => {
    sim.postCommand(makeCommand(CmdType.ALL_SHUTTERS_STOP, CmdSource.WEB));
    // resetToDefaults loopTask'ta calisir; yanit cikmadan once uygulanir (kimlik/MQTT/yerel anahtar KORUNUR)
    if (!cm.resetToDefaults()) return err(500, 'storage_error');
    portal.wifiRestorePending = true;
    sim.event('reset_to_defaults', {});
    return { status: 200, body: { status: 'reset_ok' }, after: () => automation.requestRestart(RESTART_DELAY_MS + 200, now()) };
  };

  // ---- kimlik / provizyon
  h.factoryInit = () => {
    if (cm.hasLocalKey()) return err(403, 'already_provisioned');
    const j = readJson();
    if (j.e) return j.e;
    const k = fieldString(j.doc, 'local_key');
    if (k.s !== 'ok') return err(400, 'invalid_key');
    const ap = fieldString(j.doc, 'ap_pass');
    if (ap.s !== 'ok') return err(400, 'invalid_ap_pass');
    const kl = Buffer.byteLength(k.v);
    const al = Buffer.byteLength(ap.v);
    if (kl < LOCAL_KEY_MIN_LEN || kl > LOCAL_KEY_MAX_LEN || !isPrintableAsciiNoSpace(k.v)) return err(400, 'invalid_key');
    if (al < AP_PASS_MIN_LEN || al > AP_PASS_MAX_LEN) return err(400, 'invalid_ap_pass');
    if (!cm.setLocalKey(k.v)) return err(400, 'invalid_key');
    if (!cm.setApPass(ap.v)) { cm.clearLocalKey(); return err(400, 'invalid_ap_pass'); }
    sim.event('provisioned', {});
    wifi.applyApConfigChange();   // acik kurulum AP'si WPA2 + ap_pass ile ~1,5 sn sonra yeniden baslar
    return ok();
  };

  h.rekey = () => {
    const j = readJson();
    if (j.e) return j.e;
    let f = fieldString(j.doc, 'local_key');
    if (f.s === 'missing') f = fieldString(j.doc, 'new_key');
    if (f.s !== 'ok') return err(400, 'invalid_key');
    const kl = Buffer.byteLength(f.v);
    if (kl < LOCAL_KEY_MIN_LEN || kl > LOCAL_KEY_MAX_LEN || !isPrintableAsciiNoSpace(f.v)) return err(400, 'invalid_key');
    if (!cm.setLocalKey(f.v)) return err(500, 'storage_error');
    sim.event('rekeyed', {});
    return ok();
  };

  h.mqttConfig = () => {
    const j = readJson();
    if (j.e) return j.e;
    const s = fieldString(j.doc, 'server');
    if (s.s !== 'ok' || !validMqttHost(s.v)) return err(400, 'invalid_value');
    const p = fieldInt(j.doc, 'port');
    if (p.s !== 'ok' || p.v < 1 || p.v > 65535) return err(400, 'invalid_value');
    const u = fieldString(j.doc, 'user');
    if (u.s !== 'ok' || Buffer.byteLength(u.v) < 1) return err(400, 'invalid_value');
    const pw = fieldString(j.doc, 'pass');
    if (pw.s !== 'ok' || Buffer.byteLength(pw.v) < 1) return err(400, 'invalid_value');
    if (!cm.setMqttCredentials(s.v, p.v, u.v, pw.v)) return err(400, 'invalid_value');
    sim.event('mqtt_config_set', { server: s.v, port: p.v, user: u.v });
    mqtt.reconfigure();
    return ok();
  };

  return { h, authorize, authorizeApOrKeyed };
}

const ROOT_HTML = (sim, wifi) => `<!doctype html><html lang="tr"><head><meta charset="utf-8"><title>AHBU cihaz simulatoru</title></head>
<body style="font-family:sans-serif;max-width:40rem;margin:2rem auto"><h1>AHBU cihaz simulatoru</h1>
<p><b>${wifi.getDeviceUid()}</b> &mdash; QA simulatoru (firmware degildir). Yerel API: <code>/api/status</code>.</p>
<p>QA kontrol ucu yalnizca 127.0.0.1: <code>/__sim/state</code></p></body></html>`;

// route tablosu: [yol, yontem] -> {handler, access: PUBLIC|KEYED|FACTORY|AP_OR_KEYED} (firmware setupRoutes: 26 rota, 3'u AP_OR_KEYED)
//   PUBLIC: anahtarsiz. KEYED: yalniz gecerli X-Device-Key. FACTORY: provizyonsuz cihazda factory/init.
//   AP_OR_KEYED: gecerli X-Device-Key YA DA AP kaynakli yetki (ApAccess::via) -- yalniz wifi/scan|connect|status.
export const ROUTES = [
  ['/', 'GET', 'root', 'PUBLIC'],
  ['/api/status', 'GET', 'status', 'PUBLIC'],
  ['/api/factory/init', 'POST', 'factoryInit', 'FACTORY'],
  ['/api/auth/check', 'GET', 'authCheck', 'KEYED'],
  ['/api/auth/check', 'POST', 'authCheck', 'KEYED'],
  ['/api/auth/rekey', 'POST', 'rekey', 'KEYED'],
  ['/api/mqtt/config', 'POST', 'mqttConfig', 'KEYED'],
  ['/api/relay', 'POST', 'relay', 'KEYED'],
  ['/api/all', 'POST', 'all', 'KEYED'],
  ['/api/child-lock', 'GET', 'childLockGet', 'KEYED'],
  ['/api/child-lock', 'POST', 'childLockPost', 'KEYED'],
  ['/api/config', 'GET', 'configGet', 'KEYED'],
  ['/api/config', 'POST', 'configSave', 'KEYED'],
  // Wi-Fi servis akisi: gecerli X-Device-Key YA DA AP kaynakli yetki (CONTRACTS 3d). Yalniz bu UC uc; digerleri KEYED.
  ['/api/wifi/scan', 'GET', 'wifiScan', 'AP_OR_KEYED'],
  ['/api/wifi/connect', 'POST', 'wifiConnect', 'AP_OR_KEYED'],
  ['/api/wifi/status', 'GET', 'wifiStatus', 'AP_OR_KEYED'],
  ['/api/wifi/disconnect', 'POST', 'wifiDisconnect', 'KEYED'],
  ['/api/rs485/send', 'POST', 'rs485Send', 'KEYED'],
  ['/api/rs485/logs', 'GET', 'rs485Logs', 'KEYED'],
  ['/api/rs485/clear', 'POST', 'rs485Clear', 'KEYED'],
  ['/api/rs485/baud', 'POST', 'rs485Baud', 'KEYED'],
  ['/api/rs485/scan', 'POST', 'rs485ScanStart', 'KEYED'],
  ['/api/rs485/scan', 'GET', 'rs485ScanResult', 'KEYED'],
  ['/api/rs485/relay', 'POST', 'rs485Relay', 'KEYED'],
  ['/api/system/reboot', 'POST', 'reboot', 'KEYED'],
  ['/api/system/reset', 'POST', 'reset', 'KEYED'],
];

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let done = false;
    const finish = (fn, v) => { if (!done) { done = true; fn(v); } };
    req.on('data', (c) => {
      const before = size;
      size += c.length;
      // en fazla limit+1 bayt tutulur (413 icin yeterli); fazlasi atilir
      if (before <= limit) chunks.push(size <= limit + 1 ? c : c.subarray(0, limit + 1 - before));
    });
    req.on('end', () => finish(resolve, Buffer.concat(chunks)));
    req.on('error', (e) => finish(reject, e));
    req.on('aborted', () => finish(reject, Object.assign(new Error('aborted'), { status: 400 })));
  });
}

// ====================================================================== QA ucu (/__sim/*) -- firmware'de YOKTUR
async function handleQa(sim, req, res, url, path) {
  if (!isLoopbackAddress(req.socket.remoteAddress)) return sendJson(res, 403, { error: 'forbidden', detail: 'QA ucu yalnizca 127.0.0.1' });
  const method = req.method;
  const readJsonBody = async () => {
    const raw = (await readBody(req, MAX_BODY_BYTES)).toString('utf8');
    if (!raw) return {};
    try { return JSON.parse(raw); } catch (_) { throw Object.assign(new Error('invalid_json'), { status: 400 }); }
  };

  if (method === 'GET' && path === '/__sim/state') return sendJson(res, 200, sim.qaState());
  if (method === 'GET' && path === '/__sim/client-net') return sendJson(res, 200, { client_net: sim.qaClientNet() });
  if (method === 'GET' && path === '/__sim/log') {
    const since = Number.parseInt(url.searchParams.get('since') || '0', 10) || 0;
    const limit = Math.min(500, Number.parseInt(url.searchParams.get('limit') || '200', 10) || 200);
    return sendJson(res, 200, { entries: sim.eventsSince(since, limit), last: sim.eventSeq });
  }

  const di = /^\/__sim\/di\/(\d{1,2})\/(press|down|up)$/.exec(path);
  if (di && method === 'POST') {
    const n = Number.parseInt(di[1], 10);
    const body = await readJsonBody();
    try {
      if (di[2] === 'press') sim.pressDi(n, Number.isFinite(body.hold_ms) ? body.hold_ms : 150);
      else sim.setDi(n, di[2] === 'down');
    } catch (e) {
      return sendJson(res, 400, { error: e.message });
    }
    return sendJson(res, 200, { ok: true });
  }

  if (method === 'POST') {
    switch (path) {
      case '/__sim/offline': sim.forceOffline(); return sendJson(res, 200, { ok: true });
      case '/__sim/online': sim.forceOnline(); return sendJson(res, 200, { ok: true });
      case '/__sim/crash': sim.crash(); return sendJson(res, 200, { ok: true });
      case '/__sim/power-cycle': sim.powerCycle(); return sendJson(res, 200, { ok: true });
      case '/__sim/slow': return sendJson(res, 200, { ok: true, slow: sim.setSlow(await readJsonBody()) });
      case '/__sim/factory-reset': sim.factoryReset(); return sendJson(res, 200, { ok: true });
      case '/__sim/unprovision': sim.unprovision(); return sendJson(res, 200, { ok: true });
      case '/__sim/wifi': {
        const b = await readJsonBody();
        try { return sendJson(res, 200, { ok: true, wifi: sim.setWifiWorld(b) }); } catch (e) { return sendJson(res, 400, { error: e.message }); }
      }
      case '/__sim/ap': {
        const b = await readJsonBody();
        try { return sendJson(res, 200, { ok: true, ap: sim.setServiceAp(b) }); } catch (e) { return sendJson(res, 400, { error: e.message }); }
      }
      case '/__sim/client-net': {
        const b = await readJsonBody();
        try { return sendJson(res, 200, { ok: true, client_net: sim.setClientNet(b) }); } catch (e) { return sendJson(res, 400, { error: e.message }); }
      }
      case '/__sim/hw-fail': {
        const b = await readJsonBody();
        try { return sendJson(res, 200, { ok: true, hw_fail: sim.setHwFail(b) }); } catch (e) { return sendJson(res, 400, { error: e.message }); }
      }
      case '/__sim/ext': {
        const b = await readJsonBody();
        try { return sendJson(res, 200, { ok: true, ext: sim.setExt(b) }); } catch (e) { return sendJson(res, 400, { error: e.message }); }
      }
      case '/__sim/tca': {
        const b = await readJsonBody();
        try { return sendJson(res, 200, { ok: true, tca: sim.tcaFault(b) }); } catch (e) { return sendJson(res, 400, { error: e.message }); }
      }
      case '/__sim/provision': {
        const b = await readJsonBody();
        const r = sim.qaProvision(b.local_key, b.ap_pass);
        return sendJson(res, r.ok ? 200 : r.status, r.ok ? { ok: true, rekeyed: !!r.rekeyed } : { error: r.error });
      }
      default: break;
    }
  }
  if (method === 'DELETE' && path === '/__sim/slow') return sendJson(res, 200, { ok: true, slow: sim.setSlow({}) });
  return sendJson(res, 404, { error: 'not_found' });
}

// ====================================================================== sunucu
async function handle(sim, req, res) {
  if (sim.booting) { req.socket.destroy(); return; }   // cihaz yeniden aciliyor: yanit yok

  const url = new URL(req.url, 'http://device');
  const path = url.pathname;
  const method = req.method;

  if (path.startsWith('/__sim/')) {
    try {
      return await handleQa(sim, req, res, url, path);
    } catch (e) {
      return sendJson(res, e.status || 500, { error: e.message });
    }
  }

  const fw = sim.fw;
  const route = ROUTES.find((r) => r[0] === path && r[1] === method);
  if (!route) {
    // CORS/OPTIONS yok: bilinmeyen her yol/yontem (OPTIONS dahil) 404
    if (path.startsWith('/api/')) return sendJson(res, 404, { error: 'not_found' });
    return sendRaw(res, 404, 'text/plain', 'Not Found');
  }
  const [, , name, access] = route;

  // govdeyi oku (ESP32 WebServer govdeyi dispatch'ten once okur)
  let raw = null;
  try {
    raw = method === 'POST' ? await readBody(req, MAX_BODY_BYTES) : null;
  } catch (e) {
    return sendJson(res, 400, { error: 'invalid_request' });
  }
  const args = new URLSearchParams(url.search);
  const ct = String(req.headers['content-type'] || '').toLowerCase();
  if (raw && raw.length > 0 && ct.startsWith('application/x-www-form-urlencoded')) {
    for (const [k, v] of new URLSearchParams(raw.toString('utf8'))) args.append(k, v);
  }
  // (ctx.viaApOrigin her istekte sifirlanir; yalniz authorizeApOrKeyed() anahtarsiz AP yolunda kurar)
  const ctx = { req, raw, args, socketIp: req.socket.remoteAddress || '', viaApOrigin: false };
  const { h, authorize, authorizeApOrKeyed } = makeHandlers(sim, fw, ctx);

  // ---- guardRequest: Host / Origin
  const host = String(req.headers.host || '');
  if (host.length > 0 && !isAllowedHost(host)) return sendJson(res, 400, { error: 'bad_host' });
  const origin = String(req.headers.origin || '');
  if (origin.length > 0 && !originMatchesHost(origin, host)) return sendJson(res, 403, { error: 'bad_origin' });

  // ---- kimlik
  if (access === 'KEYED' || access === 'AP_OR_KEYED') {
    const e = access === 'KEYED' ? authorize() : authorizeApOrKeyed();
    if (e) return sendJson(res, e.status, e.body, e.headers || {});
  }

  const result = h[name]();
  if (result.html !== undefined) sendRaw(res, result.status, 'text/html; charset=utf-8', result.html, result.headers || {});
  else if (result.text !== undefined) sendRaw(res, result.status, 'text/plain; charset=utf-8', result.text, result.headers || {});
  else sendJson(res, result.status, result.body, result.headers || {});
  if (result.after && result.status === 200) res.once('finish', () => setTimeout(() => result.after(), 20));
  return undefined;
}

export function createLocalApiServer(sim) {
  const server = http.createServer((req, res) => {
    handle(sim, req, res).catch((e) => {
      sim.event('http_error', { error: e && e.message });
      if (!res.headersSent) sendJson(res, 500, { error: 'internal' });
      else res.end();
    });
  });
  server.keepAliveTimeout = 1000;
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  return server;
}

