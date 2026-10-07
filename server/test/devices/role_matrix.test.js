'use strict';

// utils/role_matrix.js - CONTRACTS §1.4 matrisi (WP-B satirlari): rol x yetenek tablosu

const test = require('node:test');
const assert = require('node:assert');

const { ROLES, ALL_ROLES, CAPABILITIES, rolesFor, effectiveRole, can, isGuest } = require('../../src/utils/role_matrix');

const S = ROLES.SUPER;
const F = ROLES.STAFF;
const P = ROLES.SESSION;
const O = ROLES.OWNER;
const R = ROLES.RESIDENT;
const G = ROLES.GUEST;

// CONTRACTS §1.4 (satir -> [super, staff, service_session, owner, resident, guest(gecerli)])
const MATRIX = {
  view: [true, true, true, true, true, true],
  control: [true, true, true, true, true, true],
  group: [true, true, true, true, true, false],
  child_lock: [true, true, true, true, true, false],
  calibrate: [true, true, true, true, false, false],
  commission: [true, true, true, false, false, false],
  replace_board: [true, true, true, true, false, false],
  // CONTRACTS §1.5: yerel anahtar owner/resident/staff/service_session (super listede degil)
  local_key: [false, true, true, true, true, false],
  device_credential: [true, true, true, true, false, false],
  mqtt_credentials: [true, true, true, true, true, true],
  // Guvenlik modulu (WP-S4, tasarim §5.2.4; misafir §7.2b-4: kapatir, acamaz/onaylayamaz, bildirim almaz)
  actuator_close: [true, true, true, true, true, true],
  safety_ack: [true, true, true, true, true, false],
  actuator_control: [true, true, true, true, true, false],
  safety_test: [true, true, true, true, false, false],
  safety_config: [true, true, true, true, false, false],
  // Faz 2 F2.B.6 (karar F2-3): hirsiz alarmi kurma/cozme yalniz owner + resident
  safety_arm: [false, false, false, true, true, false],
};
const ORDER = [S, F, P, O, R, G];

test('matris: her yetenek x her rol sozlesmeyle birebir ayni', () => {
  for (const [capability, expected] of Object.entries(MATRIX)) {
    ORDER.forEach((role, i) => {
      assert.strictEqual(
        can(capability, role),
        expected[i],
        `${capability} / ${role}: beklenen ${expected[i]}`
      );
    });
  }
  // beklenmeyen yetenek tanimli kalmasin
  assert.deepStrictEqual(Object.keys(CAPABILITIES).sort(), Object.keys(MATRIX).sort());
});

test('rolesFor: requireHomeAccess listesi icin bilinen rol adlari (kopya doner)', () => {
  const known = new Set(ALL_ROLES);
  for (const cap of Object.keys(MATRIX)) {
    const list = rolesFor(cap);
    assert.ok(Array.isArray(list) && list.length > 0);
    for (const role of list) assert.ok(known.has(role), `${cap}: bilinmeyen rol ${role}`);
    list.push('hacked');
    assert.ok(!rolesFor(cap).includes('hacked'), 'dis degisiklik matrisi bozmamali');
  }
  assert.throws(() => rolesFor('yok'), /Bilinmeyen yetenek/);
});

test('beyaz liste: bilinmeyen rol / yetenek / bos deger = hicbir yetki', () => {
  assert.strictEqual(can('control', 'admin'), false);
  assert.strictEqual(can('control', ''), false);
  assert.strictEqual(can('control', null), false);
  assert.strictEqual(can('control', undefined), false);
  assert.strictEqual(can('olmayan_yetenek', S), false);
  assert.strictEqual(can('view', { role: 'hacker' }), false);
});

test('effectiveRole: is_super / is_service_session rol alanindan ONCE degerlendirilir', () => {
  assert.strictEqual(effectiveRole({ role: 'owner', is_super: true }), S);
  assert.strictEqual(effectiveRole({ role: 'owner', is_service_session: true }), P);
  assert.strictEqual(effectiveRole({ role: 'super_user', is_super: false }), S);
  assert.strictEqual(effectiveRole({ role: 'service_session' }), P);
  assert.strictEqual(effectiveRole({ role: 'guest' }), G);
  assert.strictEqual(effectiveRole({ role: 'service_user' }), F);
  assert.strictEqual(effectiveRole(null), null);
  assert.strictEqual(effectiveRole(undefined), null);
  assert.strictEqual(effectiveRole('owner'), null);
});

test('can: homeAccess nesnesi ve rol dizgisi ayni sonucu verir', () => {
  assert.strictEqual(can('calibrate', { role: 'owner', is_super: false, is_service_session: false }), true);
  assert.strictEqual(can('calibrate', { role: 'resident' }), false);
  assert.strictEqual(can('group', { role: 'guest' }), false);
  assert.strictEqual(can('group', { role: 'service_session', is_service_session: true }), true);
  assert.strictEqual(can('commission', { role: 'owner' }), false);
  assert.strictEqual(isGuest({ role: 'guest' }), true);
  assert.strictEqual(isGuest('guest'), true);
  assert.strictEqual(isGuest({ role: 'owner' }), false);
});

test('A paketinin auth_middleware HOME_ROLE_SETS ile uyumlu (varsa)', (t) => {
  // A'nin middleware'i db.js'i yukler; sahte DATABASE_URL ile yalnizca modul yuklenir (baglanti acilmaz).
  const prev = process.env.DATABASE_URL;
  process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgres://test:test@127.0.0.1:1/test';
  let mw;
  try {
    mw = require('../../src/middlewares/auth_middleware');
  } catch (err) {
    t.skip(`auth_middleware yuklenemedi: ${err.message}`);
    return;
  } finally {
    if (prev === undefined) delete process.env.DATABASE_URL;
  }
  const sets = mw.HOME_ROLE_SETS;
  if (!sets) {
    t.skip('HOME_ROLE_SETS disa acilmamis');
    return;
  }
  const norm = (a) => [...a].sort();
  const map = {
    view: 'VIEW',
    control: 'CONTROL',
    group: 'GROUP_COMMAND',
    child_lock: 'CHILD_LOCK',
    calibrate: 'CALIBRATE',
    commission: 'COMMISSION',
    replace_board: 'REPLACE_BOARD',
    local_key: 'LOCAL_KEY',
  };
  for (const [capability, key] of Object.entries(map)) {
    assert.deepStrictEqual(norm(rolesFor(capability)), norm(sets[key]), `${capability} != A:${key}`);
  }
});
