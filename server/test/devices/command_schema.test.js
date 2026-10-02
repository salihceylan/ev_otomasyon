'use strict';

// B0: utils/command_schema.js - CONTRACTS §2.3 komut sema dogrulayicisi

const test = require('node:test');
const assert = require('node:assert');

const {
  validateCommand,
  capabilityForKind,
  KINDS,
  MAX_RELAY,
  MAX_SHUTTER_PAIR,
} = require('../../src/utils/command_schema');

function ok(input, expectedCommand, expectedKind) {
  const r = validateCommand(input);
  assert.strictEqual(r.ok, true, `kabul edilmeliydi: ${JSON.stringify(input)} -> ${r.error}`);
  assert.deepStrictEqual(r.command, expectedCommand);
  if (expectedKind) assert.strictEqual(r.kind, expectedKind);
  return r;
}
function bad(input, message) {
  const r = validateCommand(input);
  assert.strictEqual(r.ok, false, `reddedilmeliydi: ${JSON.stringify(input)}`);
  assert.strictEqual(typeof r.error, 'string');
  assert.ok(r.error.length > 0);
  if (message) assert.match(r.error, message);
  return r;
}

test('sozlesmedeki tum gecerli komut ornekleri kabul edilir', () => {
  ok({ relay: 3, state: true }, { relay: 3, state: true }, KINDS.RELAY);
  ok({ relay: 3, state: false }, { relay: 3, state: false }, KINDS.RELAY);
  ok({ relay: 3, cmd: 'toggle' }, { relay: 3, cmd: 'toggle' }, KINDS.RELAY);
  for (const cmd of ['up', 'down', 'stop', 'step']) {
    ok({ shutter: 2, cmd }, { shutter: 2, cmd }, KINDS.SHUTTER);
  }
  ok({ shutter: 2, pos: 40 }, { shutter: 2, pos: 40 }, KINDS.SHUTTER);
  ok({ cmd: 'all_lights_off' }, { cmd: 'all_lights_off' }, KINDS.GROUP);
  ok({ cmd: 'all_off' }, { cmd: 'all_off' }, KINDS.GROUP);
  ok({ cmd: 'all_shutters_up' }, { cmd: 'all_shutters_up' }, KINDS.GROUP);
  ok({ cmd: 'all_shutters_down' }, { cmd: 'all_shutters_down' }, KINDS.GROUP);
  ok({ cmd: 'all_shutters_stop' }, { cmd: 'all_shutters_stop' }, KINDS.GROUP);
  ok({ cmd: 'set_child_lock', enabled: true }, { cmd: 'set_child_lock', enabled: true }, KINDS.CHILD_LOCK);
  ok({ cmd: 'set_child_lock', enabled: false }, { cmd: 'set_child_lock', enabled: false }, KINDS.CHILD_LOCK);
  ok({ cmd: 'set_runtime', shutter: 2, sec: 24 }, { cmd: 'set_runtime', shutter: 2, sec: 24 }, KINDS.RUNTIME);
});

test('sinir degerleri: relay 1..40, shutter 1..20, pos 0..100, sec 1..300', () => {
  ok({ relay: 1, state: true }, { relay: 1, state: true });
  ok({ relay: MAX_RELAY, state: true }, { relay: MAX_RELAY, state: true });
  bad({ relay: 0, state: true });
  bad({ relay: MAX_RELAY + 1, state: true });
  bad({ relay: -1, state: true });

  ok({ shutter: 1, pos: 0 }, { shutter: 1, pos: 0 });
  ok({ shutter: MAX_SHUTTER_PAIR, pos: 100 }, { shutter: MAX_SHUTTER_PAIR, pos: 100 });
  bad({ shutter: 0, pos: 10 });
  bad({ shutter: MAX_SHUTTER_PAIR + 1, pos: 10 });
  bad({ shutter: 1, pos: -1 }, /pos/);
  bad({ shutter: 1, pos: 101 }, /pos/);

  ok({ cmd: 'set_runtime', shutter: 1, sec: 1 }, { cmd: 'set_runtime', shutter: 1, sec: 1 });
  ok({ cmd: 'set_runtime', shutter: 1, sec: 300 }, { cmd: 'set_runtime', shutter: 1, sec: 300 });
  bad({ cmd: 'set_runtime', shutter: 1, sec: 0 }, /sec/);
  bad({ cmd: 'set_runtime', shutter: 1, sec: 301 }, /sec/);
});

test('1 tabanli indeks: relay 0 ve shutter 0 reddedilir (0 tabanli sizinti yok)', () => {
  bad({ relay: 0, cmd: 'toggle' });
  bad({ shutter: 0, cmd: 'up' });
});

test('tip uyusmazligi reddedilir: "ON", 1, "3", ondalik, NaN, null', () => {
  bad({ relay: 3, state: 'ON' }, /state/);
  bad({ relay: 3, state: 'true' }, /state/);
  bad({ relay: 3, state: 1 }, /state/);
  bad({ relay: 3, state: 0 }, /state/);
  bad({ relay: 3, state: null }, /state/);
  bad({ relay: '3', state: true }, /Röle numarası/);
  bad({ relay: 3.5, state: true });
  bad({ relay: NaN, state: true });
  bad({ relay: null, state: true });
  bad({ shutter: 2, pos: '40' }, /pos/);
  bad({ shutter: 2, pos: 40.5 }, /pos/);
  bad({ shutter: 2, pos: null }, /pos/);
  bad({ shutter: 2, pos: true }, /pos/);
  bad({ cmd: 'set_child_lock', enabled: 'true' }, /enabled/);
  bad({ cmd: 'set_child_lock', enabled: 1 }, /enabled/);
  bad({ cmd: 'set_child_lock' }, /enabled/);
  bad({ cmd: 'set_runtime', shutter: 1, sec: '24' }, /sec/);
  bad({ cmd: 'set_runtime', shutter: 1, sec: 24.2 }, /sec/);
  bad({ cmd: 123 });
  bad({ cmd: ['all_off'] });
});

test('bilinmeyen alan reddedilir (sessizce yutulmaz)', () => {
  bad({ relay: 3, state: true, extra: 1 }, /Bilinmeyen alan: extra/);
  bad({ shutter: 2, cmd: 'up', sec: 5 }, /Bilinmeyen alan: sec/);
  bad({ cmd: 'all_off', channels: [1, 2] }, /Bilinmeyen alan: channels/);
  bad({ cmd: 'set_child_lock', enabled: true, timestamp: 1 }, /Bilinmeyen alan: timestamp/);
  bad({ cmd: 'set_runtime', shutter: 1, sec: 5, relay: 2 });
  bad({ relay: 3, shutter: 1, state: true }, /relay/);
});

test('bilinmeyen komut / eksik veya fazla secenek reddedilir', () => {
  bad({ cmd: 'reboot' }, /Bilinmeyen komut/);
  bad({ cmd: 'sync_full_config' }, /Bilinmeyen komut/);
  bad({ cmd: 'factory_reset' }, /Bilinmeyen komut/);
  bad({ cmd: 'toggle' }, /Bilinmeyen komut/);
  bad({ relay: 3 }, /state|toggle/);
  bad({ relay: 3, state: true, cmd: 'toggle' });
  bad({ relay: 3, cmd: 'on' }, /toggle/);
  bad({ shutter: 2 });
  bad({ shutter: 2, cmd: 'up', pos: 10 });
  bad({ shutter: 2, cmd: 'open' }, /Panjur komutu/);
  bad({ shutter: 2, cmd: 'UP' }, /Panjur komutu/);
  bad({ cmd: 'set_runtime' }, /Panjur numarası/);
  bad({ cmd: 'ALL_OFF' }, /Bilinmeyen komut/);
});

test('JSON nesnesi olmayan veya bos girdi reddedilir', () => {
  for (const input of [null, undefined, 'relay', 5, true, [], [{ relay: 1, state: true }], {}]) {
    bad(input);
  }
});

test('__proto__ / prototype kirletme girisimleri reddedilir', () => {
  const polluted = JSON.parse('{"relay": 1, "state": true, "__proto__": {"admin": true}}');
  bad(polluted, /Bilinmeyen alan/);
  assert.strictEqual({}.admin, undefined);
  bad(JSON.parse('{"cmd":"all_off","constructor":{"prototype":{"x":1}}}'), /Bilinmeyen alan/);
});

test('istege bagli id: <= 24 karakter, guvenli karakter kumesi; komutla birlikte korunur', () => {
  ok({ relay: 3, state: true, id: 'abc123' }, { relay: 3, state: true, id: 'abc123' });
  ok({ shutter: 2, pos: 40, id: 'a'.repeat(24) }, { shutter: 2, pos: 40, id: 'a'.repeat(24) });
  ok({ cmd: 'all_off', id: 'cmd-1_2.3:4' }, { cmd: 'all_off', id: 'cmd-1_2.3:4' });
  bad({ relay: 3, state: true, id: 'a'.repeat(25) }, /id/);
  bad({ relay: 3, state: true, id: '' }, /id/);
  bad({ relay: 3, state: true, id: 'bağlı' }, /id/);
  bad({ relay: 3, state: true, id: 'a b' }, /id/);
  bad({ relay: 3, state: true, id: 123 }, /id/);
  bad({ relay: 3, state: true, id: { x: 1 } }, /id/);
  bad({ relay: 3, state: true, id: 'a"b' }, /id/);
});

test('dogrulanmis komut girdiden YENIDEN uretilir (referans paylasilmaz, fazladan alan tasinmaz)', () => {
  const input = { relay: 2, state: true };
  const r = validateCommand(input);
  assert.notStrictEqual(r.command, input);
  input.state = false;
  assert.strictEqual(r.command.state, true);
});

test('hata mesajlarinda kullanici girdisi sizmaz/enjekte edilemez (alan adi temizlenir)', () => {
  const r = validateCommand({ relay: 1, state: true, 'x\n"<script>': 1 });
  assert.strictEqual(r.ok, false);
  assert.ok(!/[\n"<>]/.test(r.error));
});

test('capabilityForKind: yetki matrisi sozlugune esler', () => {
  assert.strictEqual(capabilityForKind(KINDS.RELAY), 'control');
  assert.strictEqual(capabilityForKind(KINDS.SHUTTER), 'control');
  assert.strictEqual(capabilityForKind(KINDS.GROUP), 'group');
  assert.strictEqual(capabilityForKind(KINDS.CHILD_LOCK), 'child_lock');
  assert.strictEqual(capabilityForKind(KINDS.RUNTIME), 'calibrate');
  assert.strictEqual(capabilityForKind('nope'), null);
});

test('yalnizca "id" iceren / bos / nesne olmayan komut anlasilir hata ile reddedilir', () => {
  const fail = (input) => {
    const r = validateCommand(input);
    assert.strictEqual(r.ok, false, JSON.stringify(input));
    return r.error;
  };
  assert.match(fail({ id: 'abc' }), /"relay", "shutter" veya "cmd" alanlarından birini içermeli/);
  assert.match(fail({}), /Komut boş olamaz/);
  assert.match(fail([1, 2]), /JSON nesnesi olmalı/);
  assert.match(fail({ relay: 1, shutter: 1, state: true }), /hem "relay" hem "shutter"/);
  assert.match(fail({ cmd: 'set_runtime', relay: 1, shutter: 1, sec: 5 }), /"relay" alanı olamaz/);
  assert.match(fail({ cmd: 7 }), /"cmd" alanı metin olmalı/);
});
