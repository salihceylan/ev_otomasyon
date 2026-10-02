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
// ==============================================================================

const MAX_RELAY = 40; // firmware MAX_TOTAL_RELAYS
const MAX_SHUTTER_PAIR = MAX_RELAY / 2; // pair N = role 2N-1 (yukari) ve 2N (asagi)
const MAX_COMMAND_ID_LENGTH = 24;
const RUNTIME_MIN_SEC = 1;
const RUNTIME_MAX_SEC = 300;
const POS_MIN = 0;
const POS_MAX = 100;

const COMMAND_ID_PATTERN = /^[A-Za-z0-9_.:-]{1,24}$/;

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
    default:
      return null;
  }
}

module.exports = {
  validateCommand,
  capabilityForKind,
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
