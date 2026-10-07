'use strict';

// WP-S2 [Y2][O6] - Yerlesim esitlemesinde eylemci: `relays[].act` -> endpoints.actuator_type; act imzaya ve tabana girer
// (lambadan vanaya cevirme esitlemeyi tetikler); eylemciye donen kanaldaki zamanli kurallar kapatilir. v:2 yuku
// (act yok) icin imza, taban ve plan BIREBIR eskisi gibi kalir (esdegerlik).

const test = require('node:test');
const assert = require('node:assert/strict');

const L = require('../../src/utils/endpoint_layout');
const { createEndpointLayoutSync, SQL } = require('../../src/services/endpoint_layout_sync');
const { fwState, makeWorld, makeLogger } = require('../layout/_helpers');
const { KeyedWorkQueue } = require('../../src/mqtt_bridge');

function withAct(state, acts) {
  const s = JSON.parse(JSON.stringify(state));
  s.v = 3;
  for (const [id, act] of Object.entries(acts)) s.relays[Number(id) - 1].act = act;
  return s;
}

test('extract: act okunur (valve/siren/fan/generic); v:2 yukunde act null ve imza ESKISIYLE AYNI', () => {
  const plain = fwState();
  const l2 = L.extractReportedLayout(plain);
  assert.ok(l2);
  assert.ok(l2.relays.every((r) => !('act' in r)), 'v:2 role nesnesi eskisiyle ayni (act anahtari yok)');
  assert.equal(l2.signature, JSON.stringify(l2.relays.map((r) => [r.id, r.type, r.name])), 'v:2 imzasi degismez');

  const l3 = L.extractReportedLayout(withAct(plain, { 5: 'valve', 6: 'siren' }));
  assert.ok(l3);
  assert.equal(l3.relays[4].act, 'valve');
  assert.equal(l3.relays[5].act, 'siren');
  assert.equal('act' in l3.relays[6], false);
  assert.notEqual(l3.signature, l2.signature, 'lambadan vanaya cevirme imzayi degistirir');
});

test('extract: bilinmeyen act metni "generic" sayilir (eylemci = guvenli taraf); dizge olmayan act -> null (supheli yuk)', () => {
  const l = L.extractReportedLayout(withAct(fwState(), { 7: 'pump' }));
  assert.equal(l.relays[6].act, 'generic');
  assert.equal(L.extractReportedLayout(withAct(fwState(), { 7: 5 })), null);
  assert.equal(L.extractReportedLayout(withAct(fwState(), { 7: '' })), null);
});

test('taban: act yalniz varsa yazilir; parseBase/sameBase act\'i tasir; eski taban gecerli kalir', () => {
  const l2 = L.extractReportedLayout(fwState());
  const b2 = L.serializeBase(l2);
  assert.ok(b2.relays.every((r) => !('act' in r)), 'v:2 tabani eskisiyle ayni bicim');
  const l3 = L.extractReportedLayout(withAct(fwState(), { 5: 'valve' }));
  const b3 = L.serializeBase(l3);
  assert.equal(b3.relays[4].act, 'valve');
  assert.deepEqual(L.parseBase(JSON.stringify(b3)), b3);
  assert.equal(L.sameBase(b2, b3), false);
  assert.equal(L.sameBase(b3, L.parseBase(b3)), true);
  assert.equal(L.parseBase({ v: 1, relays: [{ id: 1, type: 'light', name: 'x', act: 3 }] }), null);
});

test('fabrika yerlesimi: eylemci tasiyan pano GECICI (D1) sayilmaz (eylemci atamasi ertelenmesin)', () => {
  assert.equal(L.isFactoryLayout(L.extractReportedLayout(fwState())), true);
  assert.equal(L.isFactoryLayout(L.extractReportedLayout(withAct(fwState(), { 5: 'valve' }))), false);
});

function setup() {
  const w = makeWorld(SQL);
  const logger = makeLogger();
  const svc = createEndpointLayoutSync({ db: w.db, logger, now: () => w.now, QueueClass: KeyedWorkQueue });
  return { w, svc };
}

test('servis: act -> actuator_type yazilir, o kanala bagli role kurali kapatilir, denetim kaydi sayar', async () => {
  const { w, svc } = setup();
  const d = w.addDevice({ commissioned: true });
  w.seed(d, 8);
  const r5 = w.addRule(d, 'relay', 5);
  const r6 = w.addRule(d, 'relay', 6);
  // once v:2 ile esitlenmis taban
  const first = await svc.syncNow({ homeId: d.home_id, deviceId: d.id, layout: L.extractReportedLayout(fwState()) });
  assert.equal(first.status === 'applied' || first.status === 'noop', true);
  assert.equal(w.find('syncActuators').length, 0, 'act yokken yeni sorgu CALISMAZ (v:2 aynen)');

  const out = await svc.syncNow({ homeId: d.home_id, deviceId: d.id, layout: L.extractReportedLayout(withAct(fwState(), { 5: 'valve' })) });
  assert.equal(out.status, 'applied');
  assert.equal(w.row(d, 5).actuator_type, 'valve');
  assert.equal(w.row(d, 5).type, 'light', 'type DEGISMEZ (E1)');
  assert.equal(w.row(d, 6).actuator_type || null, null);
  assert.equal(r5.enabled, false, 'vana kanalindaki zamanli kural kapatildi [O6]');
  assert.equal(r6.enabled, true);
  assert.equal(out.summary.actuators, 1);
  const audit = w.audits[w.audits.length - 1];
  assert.deepEqual(audit.details.actuators, [{ channel: 5, actuator_type: 'valve' }]);
  assert.equal(d.reported_layout.relays[4].act, 'valve');

  // act kaldirilinca (vana -> lamba) kolon NULL olur; kural yeniden ACILMAZ
  const back = await svc.syncNow({ homeId: d.home_id, deviceId: d.id, layout: L.extractReportedLayout(fwState()) });
  assert.equal(back.status, 'applied');
  assert.equal(w.row(d, 5).actuator_type, null);
  assert.equal(r5.enabled, false);
});
