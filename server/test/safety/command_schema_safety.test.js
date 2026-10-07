'use strict';

// WP-S4 - Guvenlik komutlari: sema (actuator `to`, alarm_ack `aid`, alarm_test, ZORUNLU `uid`) ve rol matrisi
// (misafir kapatir ama acamaz; onay/test/yapilandirma yetenekleri; gaz vanasi acma HICBIR rolde yok).
// Tasarim §3.3 ve §5.2.4.

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  validateCommand,
  capabilityForKind,
  capabilityForCommand,
  KINDS,
} = require('../../src/utils/command_schema');
const { can, CAPABILITIES, ROLES, ALL_ROLES } = require('../../src/utils/role_matrix');

const UID = 'AHBU-S3-1A2B3C';

test('actuator: {actuator:a1..a16, to, uid, id?} dogrulanir ve yeniden uretilir', () => {
  const r = validateCommand({ actuator: 'a1', to: 'closed', uid: UID, id: 'c81f' });
  assert.equal(r.ok, true, r.error);
  assert.equal(r.kind, KINDS.ACTUATOR);
  assert.deepEqual(r.command, { actuator: 'a1', to: 'closed', uid: UID, id: 'c81f' });
  for (const to of ['open', 'closed', 'on', 'off']) {
    assert.equal(validateCommand({ actuator: 'a16', to, uid: UID }).ok, true, to);
  }
  // uid kucuk harfle gelse de buyuk harfe normalize edilir (firmware buyuk/kucuk harf duyarsiz eslesir)
  assert.equal(validateCommand({ actuator: 'a2', to: 'on', uid: 'ahbu-s3-1a2b3c' }).command.uid, UID);
});

test('actuator: uid ZORUNLU; bilinmeyen alan, gecersiz kimlik, state anahtari (to yerine) reddedilir', () => {
  const bad = [
    { actuator: 'a1', to: 'closed' }, // uid yok
    { actuator: 'a1', to: 'closed', uid: '' },
    { actuator: 'a1', to: 'closed', uid: 'x' },
    { actuator: 'a0', to: 'closed', uid: UID },
    { actuator: 'a17', to: 'closed', uid: UID },
    { actuator: 'A1', to: 'closed', uid: UID },
    { actuator: 1, to: 'closed', uid: UID },
    { actuator: 'a1', to: 'half', uid: UID },
    { actuator: 'a1', state: true, uid: UID }, // [D1] state yalniz boolean ve role icindir
    { actuator: 'a1', to: 'closed', uid: UID, extra: 1 },
    { actuator: 'a1', to: 'closed', uid: UID, relay: 5 },
  ];
  for (const c of bad) assert.equal(validateCommand(c).ok, false, JSON.stringify(c));
});

test('alarm_ack: {cmd, zone 1..4, aid <bn>-<n>, uid, id?}; aid ve uid zorunlu', () => {
  const r = validateCommand({ cmd: 'alarm_ack', zone: 1, aid: '9f3a11c0-3', uid: UID, id: 'c820' });
  assert.equal(r.ok, true, r.error);
  assert.equal(r.kind, KINDS.ALARM_ACK);
  assert.deepEqual(r.command, { cmd: 'alarm_ack', zone: 1, aid: '9f3a11c0-3', uid: UID, id: 'c820' });
  for (const c of [
    { cmd: 'alarm_ack', zone: 1, uid: UID },
    { cmd: 'alarm_ack', zone: 1, aid: '9f3a11c0-3' },
    { cmd: 'alarm_ack', zone: 0, aid: '9f3a11c0-3', uid: UID },
    { cmd: 'alarm_ack', zone: 5, aid: '9f3a11c0-3', uid: UID },
    { cmd: 'alarm_ack', zone: 1, aid: 'bogus', uid: UID },
    { cmd: 'alarm_ack', zone: 1, aid: '9f3a11c0-123456', uid: UID },
    { cmd: 'alarm_ack', zone: 1, aid: '9f3a11c0-3', uid: UID, force: 1 },
  ]) {
    assert.equal(validateCommand(c).ok, false, JSON.stringify(c));
  }
});

test('alarm_test: {cmd, zone, uid, id?}', () => {
  const r = validateCommand({ cmd: 'alarm_test', zone: 2, uid: UID });
  assert.equal(r.ok, true, r.error);
  assert.equal(r.kind, KINDS.ALARM_TEST);
  assert.deepEqual(r.command, { cmd: 'alarm_test', zone: 2, uid: UID });
  assert.equal(validateCommand({ cmd: 'alarm_test', zone: 2 }).ok, false, 'uid zorunlu');
  assert.equal(validateCommand({ cmd: 'alarm_test', zone: 2, uid: UID, aid: '9f3a11c0-1' }).ok, false);
});

test('event_ack / cfg_* uygulamadan GONDERILEMEZ (sema bilmez): yalniz backend uretir', () => {
  assert.equal(validateCommand({ cmd: 'event_ack', eids: ['9f3a11c0-1'], uid: UID }).ok, false);
  assert.equal(validateCommand({ cmd: 'cfg_patch', module: 'safety', uid: UID }).ok, false);
  assert.equal(validateCommand({ cmd: 'safety_arm', mode: 'away', uid: UID }).ok, false, 'modul 2.5 gelene kadar yok');
});

test('mevcut komutlar AYNEN: relay/shutter/group/child_lock/runtime ciktilari degismedi', () => {
  assert.deepEqual(validateCommand({ relay: 5, state: true, id: 'x1' }), { ok: true, kind: 'relay', command: { relay: 5, state: true, id: 'x1' } });
  assert.deepEqual(validateCommand({ shutter: 1, cmd: 'up' }), { ok: true, kind: 'shutter', command: { shutter: 1, cmd: 'up' } });
  assert.deepEqual(validateCommand({ cmd: 'all_lights_off' }), { ok: true, kind: 'group', command: { cmd: 'all_lights_off' } });
  assert.equal(validateCommand({ relay: 5, state: true, uid: UID }).ok, false, 'relay komutu uid tasimaz (v:2 sozlesmesi)');
});

test('yetenek: actuator kapatma yonu actuator_close, acma yonu actuator_control; ack/test ayri', () => {
  const close = validateCommand({ actuator: 'a1', to: 'closed', uid: UID });
  const off = validateCommand({ actuator: 'a2', to: 'off', uid: UID });
  const open = validateCommand({ actuator: 'a1', to: 'open', uid: UID });
  const on = validateCommand({ actuator: 'a2', to: 'on', uid: UID });
  assert.equal(capabilityForCommand(close), 'actuator_close');
  assert.equal(capabilityForCommand(off), 'actuator_close');
  assert.equal(capabilityForCommand(open), 'actuator_control');
  assert.equal(capabilityForCommand(on), 'actuator_control');
  assert.equal(capabilityForCommand(validateCommand({ cmd: 'alarm_ack', zone: 1, aid: '9f3a11c0-3', uid: UID })), 'safety_ack');
  assert.equal(capabilityForCommand(validateCommand({ cmd: 'alarm_test', zone: 1, uid: UID })), 'safety_test');
  // eski tur -> yetenek esleme AYNEN
  assert.equal(capabilityForKind('relay'), 'control');
  assert.equal(capabilityForCommand(validateCommand({ relay: 1, state: true })), 'control');
  assert.equal(capabilityForCommand(validateCommand({ cmd: 'set_runtime', shutter: 1, sec: 20 })), 'calibrate');
});

test('rol matrisi: misafir kapatir ama acamaz/onaylayamaz/test edemez; test ve yapilandirma resident\'ta yok', () => {
  assert.deepEqual([...CAPABILITIES.actuator_close], [...ALL_ROLES]);
  const staffOwnerResident = [ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER, ROLES.RESIDENT];
  assert.deepEqual([...CAPABILITIES.safety_ack], staffOwnerResident);
  assert.deepEqual([...CAPABILITIES.actuator_control], staffOwnerResident);
  assert.deepEqual([...CAPABILITIES.safety_test], [ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER]);
  assert.deepEqual([...CAPABILITIES.safety_config], [ROLES.SUPER, ROLES.STAFF, ROLES.SESSION, ROLES.OWNER]);
  assert.equal(can('actuator_close', 'guest'), true);
  assert.equal(can('actuator_control', 'guest'), false);
  assert.equal(can('safety_ack', 'guest'), false);
  assert.equal(can('safety_test', 'resident'), false);
  assert.equal(can('safety_config', 'resident'), false);
  // Gaz vanasi acma icin bir yetenek YOKTUR (yalniz yerinde, tasarim §2.4 [K-4])
  assert.equal(Object.keys(CAPABILITIES).some((k) => /gas/i.test(k)), false);
  for (const k of Object.keys(CAPABILITIES)) assert.ok(Object.isFrozen(CAPABILITIES[k]), k);
});

test('guvenlik komutlarinda istemci id\'si dogrulanir ve korunur (state.last_id / last_rej.id yankisi icin)', () => {
  const ok = validateCommand({ actuator: 'a1', to: 'closed', uid: 'AHBU-S3-1A2B3C', id: 'c81f' });
  assert.equal(ok.ok, true);
  assert.equal(ok.command.id, 'c81f');
  const bad = validateCommand({ actuator: 'a1', to: 'closed', uid: 'AHBU-S3-1A2B3C', id: 'x'.repeat(25) });
  assert.equal(bad.ok, false);
});
