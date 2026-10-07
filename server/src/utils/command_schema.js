'use strict';

// ==============================================================================
// Cihaz komut sema dogrulayicisi (CONTRACTS §2.3).
//
// Bulut -> cihaz `ev/{t}/cmd` yuklerinin TEK dogrulama noktasi. Uygulama MQTT'ye dogrudan
// yayin yapmaz; her komut REST (`POST /devices/:id/command`) uzerinden gelir ve burada
// dogrulanmadan broker'a gitmez. Kurallar:
//   - Tum indeksler 1 tabanlidir (relay, shutter/pair).
//   - Bilinmeyen alan / bilinmeyen komut / tip uyusmazligi / aralik disi deger -> komut REDDEDILIR.
//     (Firmware da sessizce varsayilana dusmez; burada ayni kati kural uygulanir.)
//   - `state` yalnizca JSON boolean'dir ("ON" string KABUL EDILMEZ).
//   - `pos` tamsayi 0..100; `sec` tamsayi 1..300.
//   - Istege bagli `id` (<= 24 karakter) cihazin state.last_id alaninda geri yankilanir.
//
// Donus:  { ok: true,  command, kind }   command: yalnizca dogrulanmis alanlardan yeniden uretilmis nesne
//         { ok: false, error, field }    error: ASCII Turkce, kullaniciya gosterilebilir
//
// kind (yetki matrisi icin, CONTRACTS §1.4):
//   'relay' | 'shutter'  -> normal kontrol           (misafir dahil herkes)
//   'group'              -> toplu komut (all_*)      (misafir YOK)
//   'child_lock'         -> cocuk kilidi             (misafir YOK)
//   'runtime'            -> panjur kalibrasyonu      (yalnizca owner/servis/super)
//   'actuator'           -> eylemci (vana/siren/fan/generic; WP-S4, tasarim §3.3): yetenek YONE gore secilir
//                           (closed/off -> actuator_close: misafir dahil; open/on -> actuator_control: misafir YOK)
//   'alarm_ack'          -> alarm onayi/susturma     (safety_ack: misafir YOK)
//   'alarm_test'         -> bolge testi              (safety_test: owner/servis/super)
//   'safety_arm'         -> hirsiz alarmi kurma/cozme (safety_arm: YALNIZ owner/resident; Faz 2 F2.B.6)
//
// Guvenlik komutlari (actuator, alarm_ack, alarm_test, safety_arm) `uid` ZORUNLU tasir: komut ev konusuna gider ve evdeki tum
// panolar alir; eylemci (a1..a16) ve bolge numaralari pano basinadir. uid eslesmeyen pano komutu SESSIZCE yok sayar.
// `event_ack` ve `cfg_*` YALNIZ backend'den cikar: bu sema onlari tanimaz (uygulama gonderemez).
// ==============================================================================

const MAX_RELAY = 40; // firmware MAX_TOTAL_RELAYS
const MAX_SHUTTER_PAIR = MAX_RELAY / 2; // pair N = role 2N-1 (yukari) ve 2N (asagi)
const MAX_COMMAND_ID_LENGTH = 24;
const RUNTIME_MIN_SEC = 1;
const RUNTIME_MAX_SEC = 300;
const POS_MIN = 0;
const POS_MAX = 100;

const COMMAND_ID_PATTERN = /^[A-Za-z0-9_.:-]{1,24}$/;
// Guvenlik komutlari (tasarim §3.3): eylemci kimligi a1..a16, bolge 1..4, alarm kimligi `<bn>-<n>` (bn 8 hex, n <= 5 hane)
const ACTUATOR_ID_PATTERN = /^a([1-9]|1[0-6])$/;
const AID_PATTERN = /^[0-9A-Fa-f]{8}-[0-9]{1,5}$/;
const UID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_.-]{2,63}$/; // mqtt_bridge UID_RE ile ayni
const ACTUATOR_TARGETS = Object.freeze(['closed', 'open', 'on', 'off']);
const SAFE_TARGETS = Object.freeze(['closed', 'off']); // guvenli yon: kapatmak / susturmak
const MAX_ZONE = 4;
const ARM_MODES = Object.freeze(['away', 'home', 'off']); // F2.B.7: off = cozme

const SHUTTER_ACTIONS = Object.freeze(['up', 'down', 'stop', 'step']);
const GROUP_COMMANDS = Object.freeze([
  'all_lights_off',
  'all_off', // all_lights_off ile esanlamli
  'all_shutters_up',
  'all_shutters_down',
  'all_shutters_stop',
]);

const KINDS = Object.freeze({
  RELAY: 'relay',
  SHUTTER: 'shutter',
  GROUP: 'group',
  CHILD_LOCK: 'child_lock',
  RUNTIME: 'runtime',
  ACTUATOR: 'actuator',
  ALARM_ACK: 'alarm_ack',
  ALARM_TEST: 'alarm_test',
  SAFETY_ARM: 'safety_arm',
});

function fail(error, field = null) {
  return { ok: false, error, field };
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function isIntInRange(value, min, max) {
  return typeof value === 'number' && Number.isInteger(value) && value >= min && value <= max;
}

/** Izin verilmeyen anahtar varsa o anahtarin adini doner (yoksa null). */
function findUnknownKey(keys, allowed) {
  for (const key of keys) {
    if (!allowed.includes(key)) return key;
  }
  return null;
}

/** Istege bagli `id` alanini dogrular; gecerliyse {ok:true, value|undefined}. */
function readOptionalId(input) {
  if (!Object.prototype.hasOwnProperty.call(input, 'id')) return { ok: true, value: undefined };
  const id = input.id;
  if (typeof id !== 'string' || !COMMAND_ID_PATTERN.test(id)) {
    return {
      ok: false,
      error: `Komut kimliği (id) en fazla ${MAX_COMMAND_ID_LENGTH} karakterlik harf, rakam, "_", ".", ":" veya "-" olmalı.`,
    };
  }
  return { ok: true, value: id };
}

function withId(command, id) {
  if (id !== undefined) command.id = id;
  return command;
}

function validateRelayCommand(input, keys, id) {
  const unknown = findUnknownKey(keys, ['relay', 'state', 'cmd', 'id']);
  if (unknown) return fail(`Bilinmeyen alan: ${safeKey(unknown)}`, unknown);

  if (!isIntInRange(input.relay, 1, MAX_RELAY)) {
    return fail(`Röle numarası 1 ile ${MAX_RELAY} arasında bir tamsayı olmalı.`, 'relay');
  }

  const hasState = Object.prototype.hasOwnProperty.call(input, 'state');
  const hasCmd = Object.prototype.hasOwnProperty.call(input, 'cmd');

  if (hasState === hasCmd) {
    return fail('Röle komutunda "state" (true/false) veya "cmd":"toggle" alanlarından tam olarak biri olmalı.');
  }

  if (hasState) {
    if (typeof input.state !== 'boolean') {
      return fail('"state" alanı true veya false (boolean) olmalı.', 'state');
    }
    return { ok: true, kind: KINDS.RELAY, command: withId({ relay: input.relay, state: input.state }, id) };
  }

  if (input.cmd !== 'toggle') {
    return fail('Röle için geçerli komut yalnızca "toggle" olabilir.', 'cmd');
  }
  return { ok: true, kind: KINDS.RELAY, command: withId({ relay: input.relay, cmd: 'toggle' }, id) };
}

function validateShutterCommand(input, keys, id) {
  const unknown = findUnknownKey(keys, ['shutter', 'cmd', 'pos', 'id']);
  if (unknown) return fail(`Bilinmeyen alan: ${safeKey(unknown)}`, unknown);

  if (!isIntInRange(input.shutter, 1, MAX_SHUTTER_PAIR)) {
    return fail(`Panjur numarası 1 ile ${MAX_SHUTTER_PAIR} arasında bir tamsayı olmalı.`, 'shutter');
  }

  const hasPos = Object.prototype.hasOwnProperty.call(input, 'pos');
  const hasCmd = Object.prototype.hasOwnProperty.call(input, 'cmd');

  if (hasPos === hasCmd) {
    return fail('Panjur komutunda "cmd" (up/down/stop/step) veya "pos" (0-100) alanlarından tam olarak biri olmalı.');
  }

  if (hasPos) {
    if (!isIntInRange(input.pos, POS_MIN, POS_MAX)) {
      return fail(`Panjur konumu (pos) ${POS_MIN} ile ${POS_MAX} arasında bir tamsayı olmalı.`, 'pos');
    }
    return { ok: true, kind: KINDS.SHUTTER, command: withId({ shutter: input.shutter, pos: input.pos }, id) };
  }

  if (typeof input.cmd !== 'string' || !SHUTTER_ACTIONS.includes(input.cmd)) {
    return fail(`Panjur komutu şu değerlerden biri olmalı: ${SHUTTER_ACTIONS.join(', ')}.`, 'cmd');
  }
  return { ok: true, kind: KINDS.SHUTTER, command: withId({ shutter: input.shutter, cmd: input.cmd }, id) };
}

function validateRuntimeCommand(input, keys, id) {
  const unknown = findUnknownKey(keys, ['cmd', 'shutter', 'sec', 'id']);
  if (unknown) return fail(`Bilinmeyen alan: ${safeKey(unknown)}`, unknown);

  if (!isIntInRange(input.shutter, 1, MAX_SHUTTER_PAIR)) {
    return fail(`Panjur numarası 1 ile ${MAX_SHUTTER_PAIR} arasında bir tamsayı olmalı.`, 'shutter');
  }
  if (!isIntInRange(input.sec, RUNTIME_MIN_SEC, RUNTIME_MAX_SEC)) {
    return fail(`Çalışma süresi (sec) ${RUNTIME_MIN_SEC} ile ${RUNTIME_MAX_SEC} saniye arasında bir tamsayı olmalı.`, 'sec');
  }
  return {
    ok: true,
    kind: KINDS.RUNTIME,
    command: withId({ cmd: 'set_runtime', shutter: input.shutter, sec: input.sec }, id),
  };
}

function validateChildLockCommand(input, keys, id) {
  const unknown = findUnknownKey(keys, ['cmd', 'enabled', 'id']);
  if (unknown) return fail(`Bilinmeyen alan: ${safeKey(unknown)}`, unknown);

  if (typeof input.enabled !== 'boolean') {
    return fail('"enabled" alanı true veya false (boolean) olmalı.', 'enabled');
  }
  return {
    ok: true,
    kind: KINDS.CHILD_LOCK,
    command: withId({ cmd: 'set_child_lock', enabled: input.enabled }, id),
  };
}

function validateGroupCommand(input, keys, id) {
  const unknown = findUnknownKey(keys, ['cmd', 'id']);
  if (unknown) return fail(`Bilinmeyen alan: ${safeKey(unknown)}`, unknown);
  return { ok: true, kind: KINDS.GROUP, command: withId({ cmd: input.cmd }, id) };
}

/** Zorunlu `uid` (guvenlik komutlari). Buyuk harfe normalize edilir (kopru ve firmware buyuk/kucuk harf duyarsiz). */
function readRequiredUid(input) {
  if (!Object.prototype.hasOwnProperty.call(input, 'uid')) {
    return { ok: false, error: 'Güvenlik komutlarında hedef pano kimliği (uid) zorunludur.' };
  }
  const uid = typeof input.uid === 'string' ? input.uid.trim() : '';
  if (!UID_PATTERN.test(uid)) return { ok: false, error: 'Pano kimliği (uid) geçersiz.' };
  return { ok: true, value: uid.toUpperCase() };
}

function validateActuatorCommand(input, keys, id) {
  const unknown = findUnknownKey(keys, ['actuator', 'to', 'uid', 'id']);
  if (unknown) return fail(`Bilinmeyen alan: ${safeKey(unknown)}`, unknown);
  if (typeof input.actuator !== 'string' || !ACTUATOR_ID_PATTERN.test(input.actuator)) {
    return fail('Eylemci kimliği "a1" ile "a16" arasında olmalı.', 'actuator');
  }
  if (typeof input.to !== 'string' || !ACTUATOR_TARGETS.includes(input.to)) {
    return fail(`Eylemci hedefi (to) şu değerlerden biri olmalı: ${ACTUATOR_TARGETS.join(', ')}.`, 'to');
  }
  const uid = readRequiredUid(input);
  if (!uid.ok) return fail(uid.error, 'uid');
  return { ok: true, kind: KINDS.ACTUATOR, command: withId({ actuator: input.actuator, to: input.to, uid: uid.value }, id) };
}

function readZone(input) {
  if (!isIntInRange(input.zone, 1, MAX_ZONE)) {
    return { ok: false, error: `Bölge (zone) 1 ile ${MAX_ZONE} arasında bir tamsayı olmalı.` };
  }
  return { ok: true, value: input.zone };
}

function validateAlarmAckCommand(input, keys, id) {
  const unknown = findUnknownKey(keys, ['cmd', 'zone', 'aid', 'uid', 'id']);
  if (unknown) return fail(`Bilinmeyen alan: ${safeKey(unknown)}`, unknown);
  const zone = readZone(input);
  if (!zone.ok) return fail(zone.error, 'zone');
  if (typeof input.aid !== 'string' || !AID_PATTERN.test(input.aid)) {
    return fail('Alarm kimliği (aid) geçersiz.', 'aid');
  }
  const uid = readRequiredUid(input);
  if (!uid.ok) return fail(uid.error, 'uid');
  return {
    ok: true,
    kind: KINDS.ALARM_ACK,
    command: withId({ cmd: 'alarm_ack', zone: zone.value, aid: input.aid.toLowerCase(), uid: uid.value }, id),
  };
}

function validateAlarmTestCommand(input, keys, id) {
  const unknown = findUnknownKey(keys, ['cmd', 'zone', 'uid', 'id']);
  if (unknown) return fail(`Bilinmeyen alan: ${safeKey(unknown)}`, unknown);
  const zone = readZone(input);
  if (!zone.ok) return fail(zone.error, 'zone');
  const uid = readRequiredUid(input);
  if (!uid.ok) return fail(uid.error, 'uid');
  return { ok: true, kind: KINDS.ALARM_TEST, command: withId({ cmd: 'alarm_test', zone: zone.value, uid: uid.value }, id) };
}

/** Faz 2 F2.B.7: {cmd:'safety_arm', mode:'away'|'home'|'off', uid, id?} (firmware ayristiricisi aynen). */
function validateSafetyArmCommand(input, keys, id) {
  const unknown = findUnknownKey(keys, ['cmd', 'mode', 'uid', 'id']);
  if (unknown) return fail(`Bilinmeyen alan: ${safeKey(unknown)}`, unknown);
  if (typeof input.mode !== 'string' || !ARM_MODES.includes(input.mode)) {
    return fail(`Alarm kipi (mode) şu değerlerden biri olmalı: ${ARM_MODES.join(', ')}.`, 'mode');
  }
  const uid = readRequiredUid(input);
  if (!uid.ok) return fail(uid.error, 'uid');
  return { ok: true, kind: KINDS.SAFETY_ARM, command: withId({ cmd: 'safety_arm', mode: input.mode, uid: uid.value }, id) };
}

// Hata mesajina girecek anahtar adini guvenli/kisa tut (log/yanit enjeksiyonunu onler).
function safeKey(key) {
  return String(key).replace(/[^A-Za-z0-9_.-]/g, '?').slice(0, 32);
}

/**
 * Bir komut nesnesini CONTRACTS §2.3'e gore dogrular.
 * @param {*} input  JSON'dan gelen ham deger
 */
function validateCommand(input) {
  if (!isPlainObject(input)) {
    return fail('Komut bir JSON nesnesi olmalı.');
  }

  const keys = Object.keys(input);
  if (keys.length === 0) return fail('Komut boş olamaz.');

  const idResult = readOptionalId(input);
  if (!idResult.ok) return fail(idResult.error, 'id');
  const id = idResult.value;

  const has = (k) => Object.prototype.hasOwnProperty.call(input, k);

  // {cmd:'set_runtime', shutter, sec} -> "shutter" alani cmd ile birlikte de gelir; once cmd'ye bak.
  if (has('cmd') && input.cmd === 'set_runtime') {
    if (has('relay')) return fail('"set_runtime" komutunda "relay" alanı olamaz.', 'relay');
    return validateRuntimeCommand(input, keys, id);
  }

  if (has('actuator')) {
    if (has('relay') || has('shutter') || has('cmd')) return fail('Eylemci komutu "relay", "shutter" veya "cmd" içeremez.');
    return validateActuatorCommand(input, keys, id);
  }

  if (has('relay')) {
    if (has('shutter')) return fail('Bir komut hem "relay" hem "shutter" içeremez.');
    return validateRelayCommand(input, keys, id);
  }

  if (has('shutter')) {
    return validateShutterCommand(input, keys, id);
  }

  if (!has('cmd')) {
    return fail('Komut "relay", "shutter" veya "cmd" alanlarından birini içermeli.');
  }

  if (typeof input.cmd !== 'string') {
    return fail('"cmd" alanı metin olmalı.', 'cmd');
  }

  if (GROUP_COMMANDS.includes(input.cmd)) {
    return validateGroupCommand(input, keys, id);
  }

  if (input.cmd === 'set_child_lock') {
    return validateChildLockCommand(input, keys, id);
  }

  if (input.cmd === 'alarm_ack') {
    return validateAlarmAckCommand(input, keys, id);
  }

  if (input.cmd === 'alarm_test') {
    return validateAlarmTestCommand(input, keys, id);
  }

  if (input.cmd === 'safety_arm') {
    return validateSafetyArmCommand(input, keys, id);
  }

  return fail('Bilinmeyen komut.', 'cmd');
}

/**
 * Yetki matrisindeki yetenek adi (role_matrix.js ile ayni sozluk).
 * relay/shutter -> 'control', group -> 'group', child_lock -> 'child_lock', runtime -> 'calibrate'
 */
function capabilityForKind(kind) {
  switch (kind) {
    case KINDS.RELAY:
    case KINDS.SHUTTER:
      return 'control';
    case KINDS.GROUP:
      return 'group';
    case KINDS.CHILD_LOCK:
      return 'child_lock';
    case KINDS.RUNTIME:
      return 'calibrate';
    case KINDS.ALARM_ACK:
      return 'safety_ack';
    case KINDS.ALARM_TEST:
      return 'safety_test';
    case KINDS.SAFETY_ARM:
      return 'safety_arm';
    default:
      return null; // ACTUATOR: yon komuttan okunur (capabilityForCommand)
  }
}

/**
 * Dogrulanmis komutun (validateCommand sonucu) yetenegi. Eylemcide YON belirler: kapatma/susturma (`closed`/`off`)
 * herkese aciktir (misafir dahil, mevcut `control` kumesi); acma/calistirma `actuator_control` ister.
 * Gaz vanasi acma icin yetenek YOKTUR: hedef denetimi (device_service) 409 GAS_LOCAL_ONLY doner.
 */
function capabilityForCommand(validated) {
  if (!validated || validated.ok !== true) return null;
  if (validated.kind === KINDS.ACTUATOR) {
    return SAFE_TARGETS.includes(validated.command.to) ? 'actuator_close' : 'actuator_control';
  }
  return capabilityForKind(validated.kind);
}

/** Eylemci hedefi guvenli yonde mi (kapat/sustur)? */
function isSafeTarget(to) {
  return SAFE_TARGETS.includes(to);
}

module.exports = {
  validateCommand,
  capabilityForKind,
  capabilityForCommand,
  isSafeTarget,
  isValidAid: (aid) => typeof aid === 'string' && AID_PATTERN.test(aid),
  ACTUATOR_TARGETS,
  SAFE_TARGETS,
  MAX_ZONE,
  ARM_MODES,
  isValidCommandId: (id) => typeof id === 'string' && COMMAND_ID_PATTERN.test(id),
  KINDS,
  MAX_RELAY,
  MAX_SHUTTER_PAIR,
  MAX_COMMAND_ID_LENGTH,
  RUNTIME_MIN_SEC,
  RUNTIME_MAX_SEC,
  SHUTTER_ACTIONS,
  GROUP_COMMANDS,
};
