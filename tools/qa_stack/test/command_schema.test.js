// Firmware MqttManager::parseCommand portu (CONTRACTS §2.3): SIKI dogrulama. Bilinmeyen alan/komut/tip/aralik disi -> UYGULANMAZ.
// Beklenen neden metinleri firmware kaynagindaki donus dizeleridir.
import test from 'node:test';
import assert from 'node:assert/strict';
import { validateCommand, parseCommandPayload, CmdType, isInt, isValidCommandId } from '../sim/command_schema.js';

const LIM = { totalRelays: 8, totalPairs: 4 };
const ok = (obj) => {
  const r = validateCommand(obj, LIM);
  assert.equal(r.ok, true, `kabul bekleniyordu: ${JSON.stringify(obj)} -> ${r.reason}`);
  return r.cmd;
};
const bad = (obj, reason) => {
  const r = validateCommand(obj, LIM);
  assert.equal(r.ok, false, `red bekleniyordu: ${JSON.stringify(obj)}`);
  if (reason) assert.equal(r.reason, reason, JSON.stringify(obj));
};

test('gecerli yukler normalize edilir (1 tabanli indeksler)', () => {
  assert.deepEqual(ok({ relay: 3, state: true }), { type: CmdType.RELAY_SET, index: 3, value: 1, id: '' });
  assert.deepEqual(ok({ relay: 3, state: false, id: 'abc' }), { type: CmdType.RELAY_SET, index: 3, value: 0, id: 'abc' });
  assert.deepEqual(ok({ relay: 8, cmd: 'toggle' }), { type: CmdType.RELAY_TOGGLE, index: 8, value: 0, id: '' });
  assert.equal(ok({ shutter: 2, cmd: 'up' }).type, CmdType.SHUTTER_UP);
  assert.equal(ok({ shutter: 2, cmd: 'down' }).type, CmdType.SHUTTER_DOWN);
  assert.equal(ok({ shutter: 4, cmd: 'stop' }).type, CmdType.SHUTTER_STOP);
  assert.equal(ok({ shutter: 1, cmd: 'step' }).type, CmdType.SHUTTER_STEP);
  assert.deepEqual(ok({ shutter: 2, pos: 40 }), { type: CmdType.SHUTTER_POS, index: 2, value: 40, id: '' });
  assert.equal(ok({ shutter: 2, pos: 0 }).value, 0);
  assert.equal(ok({ shutter: 2, pos: 100 }).value, 100);
  assert.equal(ok({ cmd: 'all_lights_off' }).type, CmdType.ALL_LIGHTS_OFF);
  assert.equal(ok({ cmd: 'all_off' }).type, CmdType.ALL_LIGHTS_OFF, 'all_off es anlamli');
  assert.equal(ok({ cmd: 'all_shutters_up' }).type, CmdType.ALL_SHUTTERS_UP);
  assert.equal(ok({ cmd: 'all_shutters_down' }).type, CmdType.ALL_SHUTTERS_DOWN);
  assert.equal(ok({ cmd: 'all_shutters_stop' }).type, CmdType.ALL_SHUTTERS_STOP);
  assert.deepEqual(ok({ cmd: 'set_child_lock', enabled: true }), { type: CmdType.SET_CHILD_LOCK, index: 0, value: 1, id: '' });
  assert.deepEqual(ok({ cmd: 'set_runtime', shutter: 2, sec: 24 }), { type: CmdType.SET_RUNTIME, index: 2, value: 24, id: '' });
  assert.equal(ok({ relay: 1, state: true, id: 'x'.repeat(24) }).id.length, 24, 'id 24 karakter sinirda kabul');
  assert.equal(ok({ relay: 1, state: true, id: 'a.B_c:d-9' }).id, 'a.B_c:d-9', 'id deseni [A-Za-z0-9._:-]');
});

test('tip uyusmazligi: state/enabled boolean olmali ("ON"/1 kabul edilmez), indeksler 32 bit tamsayi', () => {
  bad({ relay: 3, state: 'ON' }, 'state boolean olmali');
  bad({ relay: 3, state: 1 }, 'state boolean olmali');
  bad({ relay: 3, state: 'true' }, 'state boolean olmali');
  bad({ relay: '3', state: true }, 'relay tamsayi olmali');
  bad({ relay: 3.5, state: true }, 'relay tamsayi olmali');
  bad({ relay: null, state: true }, 'relay tamsayi olmali');
  bad({ relay: 2147483648, state: true }, 'relay tamsayi olmali');   // ArduinoJson is<int>() 32 bit
  bad({ shutter: 2, pos: '40' }, 'pos tamsayi olmali');
  bad({ shutter: 2, pos: 40.5 }, 'pos tamsayi olmali');
  bad({ shutter: 2, pos: null }, 'pos tamsayi olmali');
  bad({ cmd: 'set_child_lock', enabled: 'true' }, 'enabled boolean olmali');
  bad({ cmd: 'set_child_lock', enabled: 1 }, 'enabled boolean olmali');
  bad({ cmd: 'set_runtime', shutter: 1, sec: '20' }, 'sec tamsayi olmali');
  bad({ cmd: 5 }, 'cmd metin olmali');
  assert.equal(isInt(5), true);
  assert.equal(isInt(5.0), true);
  assert.equal(isInt(-2147483648), true);
  assert.equal(isInt(1e12), false);
});

test('aralik disi degerler reddedilir (sessizce varsayilana dusmez)', () => {
  bad({ relay: 0, state: true }, 'relay araligi');       // 1 tabanli: 0 gecersiz
  bad({ relay: 9, state: true }, 'relay araligi');       // 8 role var
  bad({ relay: -1, cmd: 'toggle' }, 'relay araligi');
  bad({ shutter: 0, cmd: 'up' }, 'shutter araligi');
  bad({ shutter: 5, cmd: 'up' }, 'shutter araligi');
  bad({ shutter: 2, pos: 101 }, 'pos araligi (0..100)');
  bad({ shutter: 2, pos: -1 }, 'pos araligi (0..100)');
  bad({ shutter: 2, pos: 256 }, 'pos araligi (0..100)');  // 256 -> 0'a kesilmez
  bad({ cmd: 'set_runtime', shutter: 1, sec: 0 }, 'sec araligi (1..300)');
  bad({ cmd: 'set_runtime', shutter: 1, sec: 301 }, 'sec araligi (1..300)');
  bad({ cmd: 'set_runtime', shutter: 9, sec: 20 }, 'shutter araligi');
  ok({ cmd: 'set_runtime', shutter: 1, sec: 1 });
  ok({ cmd: 'set_runtime', shutter: 1, sec: 300 });
});

test('bilinmeyen komut/alan ve belirsiz yukler reddedilir', () => {
  bad({ cmd: 'reboot' }, 'bilinmeyen komut');
  bad({ cmd: 'ALL_OFF' }, 'bilinmeyen komut');           // buyuk/kucuk harf duyarli
  bad({ cmd: 'scenario' }, 'bilinmeyen komut');
  bad({ shutter: 1, cmd: 'open' }, 'bilinmeyen komut');
  bad({ relay: 1, cmd: 'on' }, 'bilinmeyen komut');
  bad({ relay: 1, state: true, extra: 1 }, 'bilinmeyen alan');
  bad({ shutter: 1, pos: 5, percent: 5 }, 'bilinmeyen alan');
  bad({ cmd: 'all_off', foo: 'bar' }, 'bilinmeyen alan');
  bad({ relay: 1, state: true, cmd: 'toggle' }, 'toggle yalnizca relay ile');          // belirsiz: hem state hem cmd
  bad({ relay: 1 }, 'gecersiz komut bicimi');
  bad({ shutter: 1 }, 'gecersiz komut bicimi');
  bad({ shutter: 1, cmd: 'up', pos: 10 }, 'panjur komutu yalnizca shutter ile');
  bad({ cmd: 'all_off', relay: 1 }, 'toplu komut baska alan almaz');
  bad({ cmd: 'set_child_lock' }, 'set_child_lock enabled(boolean) ister');
  bad({ cmd: 'set_runtime', shutter: 1 }, 'set_runtime shutter ve sec ister');
  bad({ cmd: 'set_runtime', sec: 20 }, 'set_runtime shutter ve sec ister');
  bad({}, 'gecersiz komut bicimi');
  bad({ id: 'abc' }, 'gecersiz komut bicimi');
  bad({ shutter: 1, action: 'up' }, 'bilinmeyen alan');   // eski/sozlesme disi bicimler
  bad({ scenario: 'leave_home' }, 'bilinmeyen alan');
  bad({ relay: 1, pos: 3 }, 'gecersiz komut bicimi');
  bad({ __proto__x: 1, constructor: 1 }, 'bilinmeyen alan');
});

test('id: 1..24 karakter [A-Za-z0-9._:-]; metin olmayan/bos/gecersiz karakter reddedilir', () => {
  bad({ relay: 1, state: true, id: 'x'.repeat(25) }, 'id gecersiz (1..24, [A-Za-z0-9._:-])');
  bad({ relay: 1, state: true, id: '' }, 'id gecersiz (1..24, [A-Za-z0-9._:-])');
  bad({ relay: 1, state: true, id: 'bosluk var' }, 'id gecersiz (1..24, [A-Za-z0-9._:-])');
  bad({ relay: 1, state: true, id: 'tr-ç' }, 'id gecersiz (1..24, [A-Za-z0-9._:-])');
  bad({ relay: 1, state: true, id: 5 }, 'id metin olmali');
  bad({ relay: 1, state: true, id: null }, 'id metin olmali');
  assert.equal(isValidCommandId('ok-1'), true);
  assert.equal(isValidCommandId('a/b'), false);
});

test('govde: nesne olmayan yukler reddedilir; parseCommandPayload JSON hatalarini ve boyut sinirini (1..512 bayt) ayirir', () => {
  bad(null, 'kok nesne olmali');
  bad([], 'kok nesne olmali');
  bad('x', 'kok nesne olmali');
  bad(5, 'kok nesne olmali');
  assert.equal(parseCommandPayload('{"relay":1,"state":true}', LIM).ok, true);
  assert.equal(parseCommandPayload('{bozuk', LIM).reason, 'JSON hatasi');
  assert.equal(parseCommandPayload('', LIM).reason, 'gecersiz yuk boyutu');
  assert.equal(parseCommandPayload(Buffer.from('{"cmd":"all_off"}'), LIM).ok, true);
  assert.equal(parseCommandPayload('x'.repeat(513), LIM).reason, 'gecersiz yuk boyutu');
  const at512 = `{"relay":1,"state":true,"id":"a"}${' '.repeat(512 - 33)}`;
  assert.equal(Buffer.byteLength(at512), 512);
  assert.equal(parseCommandPayload(at512, LIM).ok, true, '512 bayt kabul');
  assert.equal(parseCommandPayload(`${at512} `, LIM).reason, 'gecersiz yuk boyutu', '513 bayt red');
  assert.equal(parseCommandPayload('[1,2]', LIM).reason, 'kok nesne olmali');
});

test('role sayisi sinirlari config ile degisir (16 role -> 8 cift; totalPairs verilmezse role/2)', () => {
  const lim16 = { totalRelays: 16, totalPairs: 8 };
  assert.equal(validateCommand({ relay: 16, state: true }, lim16).ok, true);
  assert.equal(validateCommand({ shutter: 8, cmd: 'up' }, lim16).ok, true);
  assert.equal(validateCommand({ shutter: 9, cmd: 'up' }, lim16).ok, false);
  assert.equal(validateCommand({ shutter: 8, cmd: 'up' }, { totalRelays: 16 }).ok, true);
});
