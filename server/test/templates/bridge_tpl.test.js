'use strict';

// Faz 1 / IP-1.5: MQTT state `tpl {id, ver}` (firmware v1.3.0+, CONTRACTS §3e) -> devices.template_id / template_version /
// template_reported_at. Yalniz CANLI state yazar (retained bayat olabilir; caps ile ayni kural). Alan yoksa SQL AYNEN
// (eski panolar); bozuk alan atlanir (skipped++), digerleri islenir.

const test = require('node:test');
const assert = require('node:assert/strict');

const { validateStatePayload, buildDeviceUpdate } = require('../../src/mqtt_bridge').helpers;

const TID = '3f2a9c1e-5b7d-4e8f-9a01-23456789abcd';

test('validateStatePayload: gecerli tpl ayristirilir (id kucuk harfe)', () => {
  const r = validateStatePayload({ uid: 'AHBU-S3-0001', tpl: { id: TID.toUpperCase(), ver: 4 } });
  assert.equal(r.ok, true);
  assert.deepEqual(r.value.tpl, { id: TID, ver: 4 });
  assert.equal(r.value.skipped, 0);
});

test('validateStatePayload: tpl yok -> null; bozuk -> null + skipped', () => {
  assert.equal(validateStatePayload({ uid: 'AHBU-S3-0001' }).value.tpl, null);
  for (const bad of [{ id: 'x', ver: 1 }, { id: TID, ver: 0 }, { id: TID, ver: 1.5 }, { id: TID }, 'tpl', [TID, 1], null]) {
    const r = validateStatePayload({ uid: 'AHBU-S3-0001', tpl: bad });
    assert.equal(r.ok, true);
    assert.equal(r.value.tpl, null, JSON.stringify(bad));
    assert.equal(r.value.skipped, 1, JSON.stringify(bad));
  }
});

test('buildDeviceUpdate: canli state tpl kolonlarini yazar; retained yazmaz; tpl yoksa SQL degismez', () => {
  const v = validateStatePayload({ uid: 'AHBU-S3-0001', fw: '1.3.0', tpl: { id: TID, ver: 4 } }).value;
  const live = buildDeviceUpdate('dev-1', v, true);
  assert.match(live.text, /template_id = \$\d+/);
  assert.match(live.text, /template_version = \$\d+/);
  assert.match(live.text, /template_reported_at = CURRENT_TIMESTAMP/);
  assert.ok(live.values.includes(TID));
  assert.ok(live.values.includes(4));

  const retained = buildDeviceUpdate('dev-1', v, false);
  assert.doesNotMatch(retained.text, /template_/);

  const plain = validateStatePayload({ uid: 'AHBU-S3-0001', fw: '1.3.0' }).value;
  const withNull = { ...plain };
  delete withNull.tpl;
  assert.deepEqual(buildDeviceUpdate('dev-1', plain, true), buildDeviceUpdate('dev-1', withNull, true));
});
