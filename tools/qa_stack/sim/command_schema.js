// MQTT `cmd` yuklerinin SIKI dogrulamasi: firmware MqttManager.cpp `parseCommand()` + `onMessage()` yuk siniri portu
// (CONTRACTS §2.3). Bilinmeyen alan/komut, tip uyusmazligi, aralik disi deger -> komut UYGULANMAZ (sessiz varsayilan yok).
// Tum indeksler 1 tabanlidir. Cikti, DeviceCommand.h (CmdType) ile ayni adlari kullanir.
//
// ArduinoJson tip anlambilimi: `is<int>()` = 32 bit sinirinda tamsayi (kesirli/dev sayi DEGIL), `is<bool>()` = yalniz boolean,
// `is<const char*>()` = yalniz metin (null DEGIL). `state`/`enabled` icin 0/1 sayisi boolean degildir.
import { SHUTTER_RUNTIME_MIN_SEC, SHUTTER_RUNTIME_MAX_SEC } from './fw/sysconfig.js';

export const CmdType = Object.freeze({
  RELAY_SET: 'RELAY_SET',
  RELAY_TOGGLE: 'RELAY_TOGGLE',
  SHUTTER_UP: 'SHUTTER_UP',
  SHUTTER_DOWN: 'SHUTTER_DOWN',
  SHUTTER_STOP: 'SHUTTER_STOP',
  SHUTTER_STEP: 'SHUTTER_STEP',
  SHUTTER_POS: 'SHUTTER_POS',
  ALL_LIGHTS_OFF: 'ALL_LIGHTS_OFF',
  ALL_SHUTTERS_UP: 'ALL_SHUTTERS_UP',
  ALL_SHUTTERS_DOWN: 'ALL_SHUTTERS_DOWN',
  ALL_SHUTTERS_STOP: 'ALL_SHUTTERS_STOP',
  SET_CHILD_LOCK: 'SET_CHILD_LOCK',
  SET_RUNTIME: 'SET_RUNTIME',
});

export const MAX_ID_LENGTH = 24;
/** firmware MAX_CMD_PAYLOAD: 0 bayt veya > 512 bayt yuk SESSIZCE yok sayilir */
export const MAX_PAYLOAD_BYTES = 512;
export const RUNTIME_MIN_SEC = SHUTTER_RUNTIME_MIN_SEC;
export const RUNTIME_MAX_SEC = SHUTTER_RUNTIME_MAX_SEC;

// bayraklar (firmware ile ayni bitler)
const F_RELAY = 1;
const F_SHUTTER = 2;
const F_CMD = 4;
const F_STATE = 8;
const F_POS = 16;
const F_ENABLED = 32;
const F_SEC = 64;
const F_ID = 128;

const FLAG_OF = { relay: F_RELAY, shutter: F_SHUTTER, cmd: F_CMD, state: F_STATE, pos: F_POS, enabled: F_ENABLED, sec: F_SEC, id: F_ID };

const fail = (reason) => ({ ok: false, reason });
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
/** ArduinoJson is<int>() (ESP32: 32 bit) */
export const isInt = (v) => typeof v === 'number' && Number.isInteger(v) && v >= -2147483648 && v <= 2147483647;

/** Komut kimligi: 1..24 karakter, [A-Za-z0-9._:-] */
export const isValidCommandId = (id) => typeof id === 'string' && /^[A-Za-z0-9._:-]{1,24}$/.test(id);

const SHUTTER_CMDS = { up: CmdType.SHUTTER_UP, down: CmdType.SHUTTER_DOWN, stop: CmdType.SHUTTER_STOP, step: CmdType.SHUTTER_STEP };
const GLOBAL_CMDS = {
  all_lights_off: CmdType.ALL_LIGHTS_OFF,
  all_off: CmdType.ALL_LIGHTS_OFF,
  all_shutters_up: CmdType.ALL_SHUTTERS_UP,
  all_shutters_down: CmdType.ALL_SHUTTERS_DOWN,
  all_shutters_stop: CmdType.ALL_SHUTTERS_STOP,
};

/**
 * @param {unknown} obj  ayristirilmis JSON
 * @param {{totalRelays:number, totalPairs?:number}} limits
 * @returns {{ok:true, cmd:{type:string,index:number,value:number,id:string}} | {ok:false, reason:string}}
 */
export function validateCommand(obj, limits) {
  if (!isObj(obj)) return fail('kok nesne olmali');
  const totalRelays = limits.totalRelays;
  const totalPairs = limits.totalPairs ?? Math.floor(totalRelays / 2);

  let flags = 0;
  for (const k of Object.keys(obj)) {
    const f = FLAG_OF[k];
    if (f === undefined || !Object.prototype.hasOwnProperty.call(FLAG_OF, k)) return fail('bilinmeyen alan');
    flags |= f;
  }
  const body = flags & ~F_ID & 0xFF;

  if ((flags & F_RELAY) && !isInt(obj.relay)) return fail('relay tamsayi olmali');
  if ((flags & F_SHUTTER) && !isInt(obj.shutter)) return fail('shutter tamsayi olmali');
  if ((flags & F_POS) && !isInt(obj.pos)) return fail('pos tamsayi olmali');
  if ((flags & F_SEC) && !isInt(obj.sec)) return fail('sec tamsayi olmali');
  if ((flags & F_STATE) && typeof obj.state !== 'boolean') return fail('state boolean olmali');
  if ((flags & F_ENABLED) && typeof obj.enabled !== 'boolean') return fail('enabled boolean olmali');
  if ((flags & F_CMD) && typeof obj.cmd !== 'string') return fail('cmd metin olmali');

  const relay = flags & F_RELAY ? obj.relay : 0;
  const shutter = flags & F_SHUTTER ? obj.shutter : 0;
  const pos = flags & F_POS ? obj.pos : 0;
  const sec = flags & F_SEC ? obj.sec : 0;
  let cmd = null;

  if (flags & F_CMD) {
    const c = obj.cmd;
    if (c === 'toggle') {
      if (body !== (F_CMD | F_RELAY)) return fail('toggle yalnizca relay ile');
      if (relay < 1 || relay > totalRelays) return fail('relay araligi');
      cmd = { type: CmdType.RELAY_TOGGLE, index: relay, value: 0 };
    } else if (Object.prototype.hasOwnProperty.call(SHUTTER_CMDS, c)) {
      if (body !== (F_CMD | F_SHUTTER)) return fail('panjur komutu yalnizca shutter ile');
      if (shutter < 1 || shutter > totalPairs) return fail('shutter araligi');
      cmd = { type: SHUTTER_CMDS[c], index: shutter, value: 0 };
    } else if (Object.prototype.hasOwnProperty.call(GLOBAL_CMDS, c)) {
      if (body !== F_CMD) return fail('toplu komut baska alan almaz');
      cmd = { type: GLOBAL_CMDS[c], index: 0, value: 0 };
    } else if (c === 'set_child_lock') {
      if (body !== (F_CMD | F_ENABLED)) return fail('set_child_lock enabled(boolean) ister');
      cmd = { type: CmdType.SET_CHILD_LOCK, index: 0, value: obj.enabled ? 1 : 0 };
    } else if (c === 'set_runtime') {
      if (body !== (F_CMD | F_SHUTTER | F_SEC)) return fail('set_runtime shutter ve sec ister');
      if (shutter < 1 || shutter > totalPairs) return fail('shutter araligi');
      if (sec < RUNTIME_MIN_SEC || sec > RUNTIME_MAX_SEC) return fail('sec araligi (1..300)');
      cmd = { type: CmdType.SET_RUNTIME, index: shutter, value: sec };
    } else {
      return fail('bilinmeyen komut');
    }
  } else if (body === (F_RELAY | F_STATE)) {
    if (relay < 1 || relay > totalRelays) return fail('relay araligi');
    cmd = { type: CmdType.RELAY_SET, index: relay, value: obj.state ? 1 : 0 };
  } else if (body === (F_SHUTTER | F_POS)) {
    if (shutter < 1 || shutter > totalPairs) return fail('shutter araligi');
    if (pos < 0 || pos > 100) return fail('pos araligi (0..100)');
    cmd = { type: CmdType.SHUTTER_POS, index: shutter, value: pos };
  } else {
    return fail('gecersiz komut bicimi');
  }

  let id = '';
  if (flags & F_ID) {
    if (typeof obj.id !== 'string') return fail('id metin olmali');
    if (!isValidCommandId(obj.id)) return fail('id gecersiz (1..24, [A-Za-z0-9._:-])');
    id = obj.id;
  }
  return { ok: true, cmd: { ...cmd, id } };
}

/**
 * Ham yuk (string/Buffer) -> dogrulanmis komut. onMessage siniri: 0 bayt veya > 512 bayt yuk reddedilir ('gecersiz yuk boyutu').
 * (Abonelik penceresi / kimlik tekillestirme MqttManager katmanindadir.)
 */
export function parseCommandPayload(payload, limits) {
  const buf = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload ?? ''), 'utf8');
  if (buf.length === 0 || buf.length > MAX_PAYLOAD_BYTES) return fail('gecersiz yuk boyutu');
  let obj;
  try {
    obj = JSON.parse(buf.toString('utf8'));
  } catch (_) {
    return fail('JSON hatasi');
  }
  return validateCommand(obj, limits);
}

/** Yerel anahtar (X-Device-Key): 8..32 karakter, yalnizca yazdirilabilir ASCII (0x21..0x7E), bosluk yok. */
export function isValidLocalKey(key) {
  return typeof key === 'string' && key.length >= 8 && key.length <= 32 && /^[\x21-\x7E]+$/.test(key);
}

/** AP parolasi: 8..32 karakter, 0x20..0x7E. */
export function isValidApPass(pass) {
  return typeof pass === 'string' && pass.length >= 8 && pass.length <= 32 && /^[\x20-\x7E]+$/.test(pass);
}
