'use strict';

// WP-S2 [Y3][O6] - "Vana lamba sayilmaz": endpoints.actuator_type dolu kanal
//   - gece huzur ozetinde acik lamba sayilmaz (NC selenoidin normal "role acik" konumu her gece "1 lamba acik" uretirdi),
//   - "hepsini kapat" / toplu isik kapatma onu lamba olarak kapatmaz; cok panolu evde o numara cakisma sayilir,
//   - zamanli kural calistirilmaz (scheduler _checkTarget) ve yeni kural olusturulamaz.
// Kolon NULL iken (bugunku tum saha) sonuclar BIREBIR eskisi gibidir.

const test = require('node:test');
const assert = require('node:assert/strict');

const snapshot = require('../../src/services/peace_snapshot');
const peace = require('../../src/services/peace_service');
const { Scheduler, SQL: SCHED_SQL } = require('../../src/scheduler');
const { helpers: ruleHelpers } = require('../../src/services/scheduled_rules_service');

test('gece huzur anlik goruntusu: SQL lamba kosulu actuator_type IS NULL ister; JS de eylemci satirini lamba saymaz', async () => {
  assert.match(snapshot.SQL.snapshot, /e\.type = 'light' AND e\.actuator_type IS NULL AND e\.current_state IS TRUE/);
  const rows = [
    { device_id: 'd1', live: true, endpoint_id: 'e5', type: 'light', channel_index: 5, pair: 3, name: 'Ana Vana', room: 'Mutfak', current_state: true, current_position: 0, actuator_type: 'valve' },
    { device_id: 'd1', live: true, endpoint_id: 'e6', type: 'light', channel_index: 6, pair: 3, name: 'Salon', room: 'Salon', current_state: true, current_position: 0, actuator_type: null },
  ];
  const db = { query: async () => ({ rows }) };
  const snap = await snapshot.loadLiveSnapshot(db, 'home-1');
  assert.deepEqual(snap.lights.map((l) => l.channel), [6]);
  // Kolonu dondurmeyen eski sorgu sonucu (actuator_type anahtari yok) AYNEN sayilir
  const legacy = await snapshot.loadLiveSnapshot({ query: async () => ({ rows: [{ ...rows[1], actuator_type: undefined }] }) }, 'h');
  assert.deepEqual(legacy.lights.map((l) => l.channel), [6]);
});

test('cok panolu ev: eylemci kanal numarasi cakisma sayilir (relay:N baska panonun vanasini surmesin)', () => {
  assert.match(peace.SQL.layout, /actuator_type/);
  const { findSharedConflicts } = peace.helpers;
  const rows = [
    { device_id: 'A', type: 'light', channel_index: 5, shutter_pair_index: null, current_position: 0, actuator_type: null },
    { device_id: 'B', type: 'light', channel_index: 5, shutter_pair_index: null, current_position: 0, actuator_type: 'valve' },
    { device_id: 'A', type: 'light', channel_index: 6, shutter_pair_index: null, current_position: 0, actuator_type: null },
    { device_id: 'B', type: 'light', channel_index: 6, shutter_pair_index: null, current_position: 0 },
  ];
  const c = findSharedConflicts(rows);
  assert.equal(c.relays.has(5), true);
  assert.equal(c.relays.has(6), false, 'eylemci olmayan lamba kanali eskisi gibi cakisma DEGIL');
});

test('scheduler: target SQL actuator_type okur; eylemci kanalina role kurali CALISTIRILMAZ (skipped_invalid)', async () => {
  assert.match(SCHED_SQL.target, /^SELECT channel_index, type, actuator_type FROM endpoints WHERE device_id = \$1::uuid AND channel_index = ANY\(\$2::int\[\]\)$/);
  const s = new Scheduler();
  s.db = { query: async () => ({ rows: [{ channel_index: 5, type: 'light', actuator_type: 'valve' }] }) };
  assert.match(await s._checkTarget({ id: 'd' }, { relay: 5, state: true }), /eylemci/);
  s.db = { query: async () => ({ rows: [{ channel_index: 5, type: 'light', actuator_type: null }] }) };
  assert.equal(await s._checkTarget({ id: 'd' }, { relay: 5, state: true }), null);
  s.db = { query: async () => ({ rows: [{ channel_index: 5, type: 'light' }] }) };
  assert.equal(await s._checkTarget({ id: 'd' }, { relay: 5, state: true }), null, 'kolon gelmezse eskisi gibi');
});

test('zamanli kural olusturma: eylemci kanalina role kurali reddedilir; diger kanallar aynen', () => {
  const eps = [
    { channel_index: 5, type: 'light', actuator_type: 'valve' },
    { channel_index: 6, type: 'light', actuator_type: null },
    { channel_index: 7, type: 'light' },
  ];
  const err = ruleHelpers.checkChannelAgainstEndpoints('relay', 5, eps);
  assert.equal(err.field, 'channel');
  assert.match(err.message, /güvenlik/i);
  assert.equal(ruleHelpers.checkChannelAgainstEndpoints('relay', 6, eps), null);
  assert.equal(ruleHelpers.checkChannelAgainstEndpoints('relay', 7, eps), null);
});

test('uc nokta listesi: actuator_type / dimmable / dimmer_source doner (Flutter EndpointModel); kolon gelmezse anahtar yok', async () => {
  const { EndpointService } = require('../../src/services/endpoint_service');
  const HOME = '11111111-1111-4111-8111-111111111111';
  const base = { id: 'e5', home_id: HOME, device_id: 'd1', channel_index: 5, name: 'Vana', type: 'light', room: 'Mutfak', shutter_pair_index: null, shutter_duration_sec: null, current_state: false, current_position: 0, device_uuid: 'AHBU-S3-1A2B3C', device_online: true };
  let sql = '';
  const svc = new EndpointService({ db: { query: async (t) => { sql = t; return { rows: [{ ...base, actuator_type: 'valve', dimmable: false, dimmer_source: null }] }; } } });
  const [ep] = await svc.getEndpointsByHome(HOME);
  assert.match(sql, /e\.actuator_type, e\.dimmable, e\.dimmer_source/);
  assert.equal(ep.actuator_type, 'valve');
  assert.equal(ep.dimmable, false);
  assert.equal(ep.dimmer_source, null);
  assert.equal(ep.type, 'light', 'type degismez');
  const old = new EndpointService({ db: { query: async () => ({ rows: [base] }) } });
  const [ep2] = await old.getEndpointsByHome(HOME);
  assert.equal('actuator_type' in ep2, false);
});
