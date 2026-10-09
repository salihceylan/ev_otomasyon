'use strict';

// WP-L - Uc nokta YERLESIM esitleme: SAF cekirdek testleri (src/utils/endpoint_layout.js).
//
// Beklenen degerler TASARIM BELGESINDEN turetilmistir (koddan degil):
//   docs/superpowers/specs/2026-10-03-uc-nokta-yerlesim-esitleme-design.md  §5.1 - §5.7
// Her kural tablosu satiri icin en az bir test vardir. Her `run(...)` cagrisi ayrica su genel kurallari denetler:
//   * girdiler (rows / base / reported) DEGISMEZ,
//   * ayni girdi -> ayni cikti,
//   * plan satirlara uygulaninca ikinci plan BOS olur (idempotent),
//   * satir kumesi / tip / cift / kural listeleri belgedeki kurallarla tutarlidir.
//
// Gercek veritabani YOKTUR. Gorunmez karakterler kaynakta YAZILMAZ; String.fromCharCode ile uretilir.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { isDeepStrictEqual } = require('node:util');
const L = require('../../src/utils/endpoint_layout');

// ------------------------------------------------------------------------------
// Yardimcilar
// ------------------------------------------------------------------------------
const FW_NAMES = ['Salon Panjur (Yukari)', 'Salon Panjur (Asagi)', 'Oda Panjur (Yukari)', 'Oda Panjur (Asagi)',
  'Salon Aydinlatma', 'Mutfak Aydinlatma', 'Koridor Aydinlatma', 'Balkon Aydinlatma'];
const FW_TYPES = ['shutter_up', 'shutter_down', 'shutter_up', 'shutter_down', 'light', 'light', 'light', 'light'];

// Bulut tohum sablonu. Sahip karari (2026-10-09): HICBIR rolenin sabit gorevi yok -> 1-8 "Röle N" lamba (oda Genel),
// firmware v1.3.2 fabrika varsayilaniyla ayni; panjur yalniz servisin sablonundan gelir. 9+ "Ek Modül Röle N".
const SEED_EXPECTED = [
  null,
  ...[1, 2, 3, 4, 5, 6, 7, 8].map((n) => ({ name: `Röle ${n}`, type: 'light', room: 'Genel', pair: null, durationSec: null })),
];

const ROW_FIELDS = ['id', 'channel_index', 'name', 'type', 'room', 'shutter_pair_index', 'shutter_duration_sec'];
const SET_FIELDS = ['name', 'type', 'room', 'shutter_pair_index', 'shutter_duration_sec', 'current_position'];

/** Panonun fabrika adlari (ConfigManager.cpp applyDefaults): 1-8 ASCII, 9+ "Ek Modül Röle N". */
function fwNames(n) {
  const out = [];
  for (let i = 0; i < n; i += 1) out.push(i < 8 ? FW_NAMES[i] : 'Ek Modül Röle ' + (i - 7));
  return out;
}

/** Varsayilan pano yuku (plan Task 1 Step 1); `pos` tum ciftlerin bildirilen konumu. */
function fwState({ names = FW_NAMES, types = FW_TYPES, v = 2, shutters, pos = 0 } = {}) {
  const relays = types.map((type, i) => ({ id: i + 1, name: names[i], type, state: false }));
  const pairs = [];
  for (let p = 1; p <= Math.floor(types.length / 2); p += 1) if (types[2 * p - 2] === 'shutter_up') pairs.push(p);
  return {
    v,
    uid: 'AHBU-S3-A1B2C3',
    relays,
    shutters: shutters || pairs.map((pair) => ({ pair, pos, moving: false, dir: 0, target: 255 })),
    dis: [],
  };
}

function seedOf(channel) {
  const s = L.seedDefaults(channel);
  assert.ok(s && typeof s === 'object', 'seedDefaults(' + channel + ') bir nesne dondurmeli');
  return s;
}

// Duzenek: 2026-10-09 oncesi tohumla acilmis ev (1-2 Salon / 3-4 Oda panjuru, 5-8 aydinlatma). Varsayilan pano bildirimi
// (FW_NAMES / FW_TYPES, eski fabrika yerlesimi) ile birebir eslesir; plan testleri bu duzenegi kullanir. 9+ guncel tohum.
const LEGACY_SEED = [
  null,
  { name: 'Salon Panjur Yukarı', type: 'shutter', room: 'Salon', pair: 1, durationSec: 20 },
  { name: 'Salon Panjur Aşağı', type: 'shutter', room: 'Salon', pair: 1, durationSec: 20 },
  { name: 'Oda Panjur Yukarı', type: 'shutter', room: 'Oda', pair: 2, durationSec: 20 },
  { name: 'Oda Panjur Aşağı', type: 'shutter', room: 'Oda', pair: 2, durationSec: 20 },
  { name: 'Salon Aydınlatma', type: 'light', room: 'Salon', pair: null, durationSec: null },
  { name: 'Mutfak Aydınlatma', type: 'light', room: 'Mutfak', pair: null, durationSec: null },
  { name: 'Koridor Aydınlatma', type: 'light', room: 'Koridor', pair: null, durationSec: null },
  { name: 'Balkon Aydınlatma', type: 'light', room: 'Balkon', pair: null, durationSec: null },
];

/** Duzenek satirlari: eski tohumla acilmis ev (bkz. LEGACY_SEED). */
function seedRows(n = 8) {
  const rows = [];
  for (let c = 1; c <= n; c += 1) {
    const s = c <= 8 ? LEGACY_SEED[c] : seedOf(c);
    rows.push({
      id: 'ep-' + c,
      channel_index: c,
      name: s.name,
      type: s.type,
      room: s.room,
      shutter_pair_index: s.pair,
      shutter_duration_sec: s.durationSec,
    });
  }
  return rows;
}

/** Gecerli yuk: null donmemeli. */
function extract(obj) {
  const rep = L.extractReportedLayout(obj);
  assert.ok(rep && typeof rep === 'object', 'gecerli yuk kabul edilmeli (extractReportedLayout null dondu)');
  return rep;
}

/**
 * Bozulmamis yukun kabul edildigini (on kosul), `mutate` ile bozulunca `null` dondugunu dogrular.
 * Boylece `null` sonucunun nedeni tam olarak o bozulmadir.
 */
function rejects(mutate, base = fwState()) {
  assert.ok(L.extractReportedLayout(structuredClone(base)), 'on kosul: bozulmamis yuk kabul edilmeli');
  const bad = structuredClone(base);
  const replaced = mutate(bad);
  const target = replaced === undefined ? bad : replaced;
  assert.equal(L.extractReportedLayout(target), null);
}

function deepFreeze(value) {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const key of Object.keys(value)) deepFreeze(value[key]);
  }
  return value;
}

const pairOf = (channel) => Math.ceil(channel / 2);
const cloudClass = (type) => (type === 'shutter' ? 'shutter' : 'relay');
const reportedClass = (type) => (type === 'shutter_up' || type === 'shutter_down' ? 'shutter' : 'relay');
const at = (rows, channel) => rows.find((r) => r.channel_index === channel);
const core = (row) => {
  const out = {};
  for (const f of ROW_FIELDS) out[f] = row[f];
  return out;
};
const sortedNums = (list) => list.slice().sort((a, b) => a - b);
/** Karakter (kod noktasi) sayisi: endpoints.name VARCHAR(100) karakter sayar, UTF-16 birimi degil. */
const cpLen = (text) => Array.from(text).length;

/** Plani satirlara uygular (servisin yaptigi is: mevcut degerlerin ustune `set` bindirilir). */
function applyPlan(rows, plan) {
  let out = rows.map((r) => ({ ...r }));
  if (plan.deleteAbove !== null && plan.deleteAbove !== undefined) {
    out = out.filter((r) => r.channel_index <= plan.deleteAbove);
  }
  for (const u of plan.updates) {
    const row = out.find((r) => r.id === u.id);
    assert.ok(row, 'guncelleme var olan (silinmemis) bir satira ait olmali: ' + u.id);
    for (const key of Object.keys(u.set)) row[key] = u.set[key];
  }
  for (const ins of plan.inserts) {
    out.push({
      id: 'new-' + ins.channel_index,
      channel_index: ins.channel_index,
      name: ins.name,
      type: ins.type,
      room: ins.room,
      shutter_pair_index: ins.shutter_pair_index,
      shutter_duration_sec: ins.shutter_duration_sec,
      current_position: ins.current_position,
    });
  }
  return out.sort((a, b) => a.channel_index - b.channel_index);
}

/** Belgedeki genel kurallar: her plan icin gecerli (tek tek senaryolardan bagimsiz). */
function checkInvariants({ rows, reported, base, confirmShrink, plan }) {
  const n = reported.count;
  for (const key of ['inserts', 'updates', 'deletes', 'ruleRelayChannels', 'ruleShutterPairs']) {
    assert.ok(Array.isArray(plan[key]), key + ' dizi olmali');
  }
  for (const key of ['pendingShrink', 'baseChanged', 'changed']) assert.equal(typeof plan[key], 'boolean', key);

  // changed = satir yazan bir is var
  assert.equal(plan.changed, plan.inserts.length + plan.updates.length + plan.deletes.length > 0, 'changed');

  // taban (§5.7): her zaman bu bildirimin tabani; baseChanged = eski tabandan farkli
  assert.deepEqual(plan.newBase, L.serializeBase(reported), 'newBase = serializeBase(reported)');
  assert.equal(plan.baseChanged, base === null || !isDeepStrictEqual(base, plan.newBase), 'baseChanged');

  // guncellemeler: yalniz bildirilen kanallardaki var olan satirlar, yerinde (kimlik korunur), gercek degisiklik
  const seenUpdate = new Set();
  for (const u of plan.updates) {
    const row = rows.find((r) => r.id === u.id);
    assert.ok(row, 'guncelleme var olan satira ait olmali');
    assert.equal(u.channel_index, row.channel_index, 'guncelleme kanali satirin kanali olmali');
    assert.ok(u.channel_index >= 1 && u.channel_index <= n, 'bildirilmeyen kanala guncelleme yapilmaz');
    assert.ok(!seenUpdate.has(u.id), 'ayni satira iki guncelleme olmaz');
    seenUpdate.add(u.id);
    const keys = Object.keys(u.set);
    assert.ok(keys.length > 0, 'bos guncelleme olmaz');
    for (const key of keys) assert.ok(SET_FIELDS.includes(key), 'bilinmeyen alan: ' + key);
    assert.ok(
      keys.some((key) => key !== 'current_position' && u.set[key] !== row[key]),
      'guncelleme en az bir alani gercekten degistirmeli (kanal ' + u.channel_index + ')'
    );
    if ('name' in u.set) {
      assert.equal(typeof u.set.name, 'string');
      assert.ok(cpLen(u.set.name) >= 1 && cpLen(u.set.name) <= 100, 'ad 1..100 karakter');
    }
  }

  // eklemeler (§5.5): bildirilen 1..N icindeki EKSIK kanallarin tamami
  const have = new Set(rows.map((r) => r.channel_index));
  const missing = [];
  for (let c = 1; c <= n; c += 1) if (!have.has(c)) missing.push(c);
  assert.deepEqual(sortedNums(plan.inserts.map((i) => i.channel_index)), missing, 'eksik satirlar acilir');
  for (const ins of plan.inserts) {
    assert.equal(typeof ins.name, 'string');
    assert.ok(cpLen(ins.name) >= 1 && cpLen(ins.name) <= 100, 'yeni satir adi 1..100 karakter');
    assert.equal(typeof ins.room, 'string');
    assert.ok(ins.room.length >= 1, 'yeni satirin odasi bos olmaz');
    assert.equal(typeof ins.current_state, 'boolean');
    assert.ok(Number.isInteger(ins.current_position) && ins.current_position >= 0 && ins.current_position <= 100);
  }

  // silmeler (§5.5): yalniz N'den buyuk kanallar, yalniz onayla
  const above = rows.filter((r) => r.channel_index > n);
  if (confirmShrink && above.length > 0) {
    assert.deepEqual(sortedNums(plan.deletes.map((d) => d.channel_index)), sortedNums(above.map((r) => r.channel_index)));
    assert.deepEqual(plan.deletes.map((d) => d.id).sort(), above.map((r) => r.id).sort());
    assert.equal(plan.deleteAbove, n);
    assert.equal(plan.pendingShrink, false);
  } else {
    assert.deepEqual(plan.deletes, []);
    assert.equal(plan.deleteAbove, null);
    assert.equal(plan.pendingShrink, above.length > 0);
  }

  // ozet sayaclari
  const s = plan.summary;
  assert.equal(s.inserted, plan.inserts.length, 'summary.inserted');
  assert.equal(s.deleted, plan.deletes.length, 'summary.deleted');
  const count = (field) => plan.updates.filter((u) => field in u.set).length;
  assert.equal(s.retyped, count('type'), 'summary.retyped');
  assert.equal(s.renamed, count('name'), 'summary.renamed');
  assert.equal(s.reroomed, count('room'), 'summary.reroomed');

  // uygulanmis durum (§5.2): tip ve cift panoyla ayni
  const after = applyPlan(rows, plan);
  for (let c = 1; c <= n; c += 1) {
    const matches = after.filter((r) => r.channel_index === c);
    assert.equal(matches.length, 1, 'kanal ' + c + ' icin tam bir satir olmali');
    const row = matches[0];
    const before = at(rows, c);
    const rt = reported.relays[c - 1].type;
    if (reportedClass(rt) === 'shutter') {
      assert.equal(row.type, 'shutter', 'kanal ' + c + ' panjur olmali');
      assert.equal(row.shutter_pair_index, pairOf(c), 'kanal ' + c + ' cift numarasi');
      if (before && before.type === 'shutter') {
        assert.equal(row.shutter_duration_sec, before.shutter_duration_sec, 'panjur suresi korunur');
      } else {
        assert.equal(row.shutter_duration_sec, 20, 'yeni panjur suresi 20 sn');
      }
    } else {
      if (rt === 'impulse') assert.equal(row.type, 'impulse', 'kanal ' + c + ' darbe olmali');
      else if (before && before.type === 'plug') assert.equal(row.type, 'plug', 'priz korunur (kanal ' + c + ')');
      else assert.equal(row.type, 'light', 'kanal ' + c + ' aydinlatma olmali');
      assert.equal(row.shutter_pair_index, null, 'role satirinda cift olmaz');
      assert.equal(row.shutter_duration_sec, null, 'role satirinda sure olmaz');
    }
    if (!before || cloudClass(before.type) !== reportedClass(rt)) {
      assert.ok(typeof row.room === 'string' && row.room.length >= 1, 'yeni/sinifi degisen satirin odasi bos olmaz');
    }
  }
  // N'den buyuk, silinmemis satirlara DOKUNULMAZ
  for (const row of after.filter((r) => r.channel_index > n)) {
    assert.deepEqual(core(row), core(rows.find((r) => r.id === row.id)));
  }

  // zamanli kurallar (§5.6)
  const mustRelay = new Set();
  const mayRelay = new Set();
  const mustPair = new Set();
  const mayPair = new Set();
  for (const row of rows) {
    const c = row.channel_index;
    if (c > n) {
      if (plan.deletes.length === 0) continue;
      if (cloudClass(row.type) === 'relay') mustRelay.add(c);
      else mustPair.add(pairOf(c));
      mayRelay.add(c);
      mayPair.add(pairOf(c));
      continue;
    }
    const rc = reportedClass(reported.relays[c - 1].type);
    if (cloudClass(row.type) === 'relay' && rc === 'shutter') {
      mustRelay.add(c);
      mayRelay.add(2 * pairOf(c) - 1);
      mayRelay.add(2 * pairOf(c));
    }
    if (cloudClass(row.type) === 'shutter' && rc === 'relay') {
      mustPair.add(pairOf(c)); // satirdaki shutter_pair_index'ten degil KANALDAN (kural cifti boyle adresler)
    }
    // D2: role sinifi icinde darbe <-> lamba/priz degisimi de role kurallarini kapatir (light <-> plug kozmetik)
    if (cloudClass(row.type) === 'relay' && rc === 'relay' &&
      (row.type === 'impulse') !== (reported.relays[c - 1].type === 'impulse')) {
      mustRelay.add(c);
    }
  }
  const checkList = (name, list, must, may) => {
    for (const x of list) assert.ok(Number.isInteger(x), name + ' tamsayi olmali');
    assert.deepEqual(list, sortedNums(Array.from(new Set(list))), name + ' sirali ve yinelemesiz olmali');
    for (const x of must) assert.ok(list.includes(x), name + ' icinde ' + x + ' olmali');
    for (const x of list) assert.ok(must.has(x) || may.has(x), name + ' icinde fazladan ' + x + ' var');
  };
  checkList('ruleRelayChannels', plan.ruleRelayChannels, mustRelay, mayRelay);
  checkList('ruleShutterPairs', plan.ruleShutterPairs, mustPair, mayPair);

  return after;
}

/**
 * Plani hesaplar + genel kurallari denetler + idempotency'yi dogrular.
 * @returns {{reported:object, plan:object, after:Array<object>}}
 */
function runWith({ reported, base = null, rows = [], confirmShrink = false }) {
  const snapshot = structuredClone({ reported, base, rows });
  deepFreeze(reported);
  deepFreeze(base);
  deepFreeze(rows);

  const plan = L.planLayoutSync({ reported, base, rows, confirmShrink });
  assert.ok(plan && typeof plan === 'object', 'planLayoutSync bir plan nesnesi dondurmeli');

  // (a) girdiler degismez
  assert.deepEqual({ reported, base, rows }, snapshot, 'planLayoutSync girdilerini degistirmemeli');
  // (b) ayni girdi -> ayni cikti
  const again = L.planLayoutSync(structuredClone({ reported, base, rows, confirmShrink }));
  assert.deepEqual(again, plan, 'ayni girdi ayni plani vermeli');

  const after = checkInvariants({ rows, reported, base, confirmShrink, plan });

  // (b) plan uygulaninca ikinci plan bos
  const second = L.planLayoutSync({ reported, base: plan.newBase, rows: after.map(core), confirmShrink });
  assert.equal(second.changed, false, 'uygulanmis plandan sonra ikinci plan degisiklik uretmemeli');
  assert.deepEqual(second.updates, [], 'ikinci planda guncelleme olmamali');
  assert.deepEqual(second.inserts, [], 'ikinci planda ekleme olmamali');
  assert.deepEqual(second.deletes, [], 'ikinci planda silme olmamali');
  assert.equal(second.baseChanged, false, 'ikinci planda taban degismemeli');
  assert.deepEqual(second.ruleRelayChannels, [], 'ikinci planda kural listesi bos olmali');
  assert.deepEqual(second.ruleShutterPairs, [], 'ikinci planda kural listesi bos olmali');

  return { reported, plan, after };
}

function run({ names = FW_NAMES, types = FW_TYPES, pos = 0, state, rows = seedRows(), base = null,
  confirmShrink = false } = {}) {
  const reported = extract(state || fwState({ names, types, pos }));
  return runWith({ reported, base, rows, confirmShrink });
}

/** Bir pano bildiriminin tabani (bir onceki UYGULANAN bildirim, §5.7). */
function baseOf({ names = FW_NAMES, types = FW_TYPES } = {}) {
  const base = L.serializeBase(extract(fwState({ names, types })));
  assert.ok(base && typeof base === 'object', 'serializeBase bir nesne dondurmeli');
  return structuredClone(base);
}

const withName = (index1, name, names = FW_NAMES) => {
  const out = names.slice();
  out[index1 - 1] = name;
  return out;
};
const withRow = (rows, channel, patch) => rows.map((r) => (r.channel_index === channel ? { ...r, ...patch } : r));

const NUL = String.fromCharCode(0);
const RLO = String.fromCharCode(0x202e);
const ZWSP = String.fromCharCode(0x200b);
const BOM = String.fromCharCode(0xfeff);
const TAB = String.fromCharCode(9);
const LF = String.fromCharCode(10);

// ------------------------------------------------------------------------------
// Arayuz (§8)
// ------------------------------------------------------------------------------
test('arayuz: tasarim §8 fonksiyonlari ve sabitleri disa aktarilir', () => {
  for (const name of ['extractReportedLayout', 'planLayoutSync', 'parseBase', 'serializeBase', 'seedDefaults',
    'firmwareDefaultName', 'deriveRoom', 'foldName', 'sanitizeReportedName']) {
    assert.equal(typeof L[name], 'function', name);
  }
  assert.equal(L.MAX_CHANNELS, 40);
  assert.equal(L.NAME_MAX, 100);
  assert.equal(L.DEFAULT_ROOM, 'Genel');
  assert.equal(L.DEFAULT_SHUTTER_SEC, 20);
  assert.deepEqual(Array.from(L.RELAY_TYPES).sort(), ['impulse', 'light', 'shutter_down', 'shutter_up']);
});

// ------------------------------------------------------------------------------
// §5.1 extractReportedLayout
// ------------------------------------------------------------------------------
test('extract: varsayilan pano yuku -> count 8, pairs [1,2], roleler oldugu gibi', () => {
  const rep = extract(fwState());
  assert.equal(rep.count, 8);
  assert.deepEqual(rep.pairs, [1, 2]);
  assert.deepEqual(rep.relays[4], { id: 5, type: 'light', name: 'Salon Aydinlatma', state: false });
  assert.deepEqual(rep.relays.map((r) => r.id), [1, 2, 3, 4, 5, 6, 7, 8]);
  assert.deepEqual(rep.relays.map((r) => r.type), FW_TYPES);
  assert.deepEqual(rep.relays.map((r) => r.name), FW_NAMES);
  assert.equal(typeof rep.signature, 'string');
  assert.ok(rep.signature.length > 0);
});

test('extract: role durumu (state) aynen tasinir', () => {
  const st = fwState();
  st.relays[5].state = true;
  const rep = extract(st);
  assert.equal(rep.relays[5].state, true);
  assert.equal(rep.relays[4].state, false);
});

test('extract: v >= 2 kabul edilir (v 3 dahil)', () => {
  assert.equal(extract(fwState({ v: 3 })).count, 8);
});

test('extract: v 1 -> null', () => {
  rejects((s) => { s.v = 1; });
});

test('extract: v yok -> null', () => {
  rejects((s) => { delete s.v; });
});

test('extract: relays dizi degil -> null', () => {
  rejects((s) => { s.relays = { 0: s.relays[0] }; });
  rejects((s) => { s.relays = null; });
  rejects((s) => { s.relays = 'relays'; });
  rejects((s) => { delete s.relays; });
});

test('extract: shutters yok ya da dizi degil -> null', () => {
  rejects((s) => { delete s.shutters; });
  rejects((s) => { s.shutters = null; });
  rejects((s) => { s.shutters = { pair: 1 }; });
  // panjursuz yerlesimde de zorunlu (cift kumesi bos diye atlanmaz)
  const noShutter = fwState({ types: ['light', 'impulse', 'light'], names: ['A', 'B', 'C'] });
  rejects((s) => { delete s.shutters; }, noShutter);
  rejects((s) => { s.shutters = null; }, noShutter);
  rejects((s) => { s.shutters = {}; }, noShutter);
  rejects((s) => { s.shutters = 'yok'; }, noShutter);
});

test('extract: yuk nesne degil -> null (hata firlatmaz)', () => {
  for (const bad of [null, undefined, 0, 7, '', 'state', true, [], [1, 2], {}, { v: 2 }, { v: 2, relays: [] },
    { v: 2, relays: [], shutters: [] }, { v: 2, relays: [null], shutters: [] },
    { v: 2, relays: [7], shutters: [] }, { v: 2, relays: [[]], shutters: [] }]) {
    assert.equal(L.extractReportedLayout(bad), null, JSON.stringify(bad));
  }
});

test('extract: 40 role kabul, 41 role -> null', () => {
  const types40 = new Array(40).fill('light');
  const ok = fwState({ types: types40, names: fwNames(40) });
  assert.equal(extract(ok).count, 40);
  rejects((s) => { s.relays.push({ id: 41, name: 'Fazla', type: 'light', state: false }); }, ok);
});

test('extract: 0 role -> null', () => {
  rejects((s) => { s.relays = []; s.shutters = []; });
});

test('extract: yinelenen id -> null', () => {
  rejects((s) => { s.relays[7].id = 7; });
});

test('extract: id 0 -> null', () => {
  rejects((s) => { s.relays[0].id = 0; });
});

test('extract: id N+1 -> null', () => {
  rejects((s) => { s.relays[7].id = 9; });
});

test('extract: bosluklu id (1,2,4) -> null', () => {
  const ok = fwState({ types: ['light', 'light', 'light'], names: ['A', 'B', 'C'] });
  rejects((s) => { s.relays[2].id = 4; }, ok);
});

test('extract: tamsayi olmayan id -> null', () => {
  rejects((s) => { s.relays[4].id = 5.5; });
  rejects((s) => { s.relays[4].id = '5'; });
  rejects((s) => { delete s.relays[4].id; });
  rejects((s) => { s.relays[4].id = -5; });
});

test('extract: role kaydi nesne degil -> null', () => {
  rejects((s) => { s.relays[4] = null; });
  rejects((s) => { s.relays[4] = 'light'; });
});

test('extract: bilinmeyen type -> null', () => {
  rejects((s) => { s.relays[4].type = 'plug'; });
  rejects((s) => { s.relays[4].type = 'shutter'; });
  rejects((s) => { s.relays[4].type = 7; });
  rejects((s) => { s.relays[4].type = 'LIGHT'; });
});

test('extract: type alani eksik (eski yazilim, §6) -> null', () => {
  rejects((s) => { delete s.relays[4].type; });
  rejects((s) => { for (const r of s.relays) delete r.type; });
});

test('extract: state boolean degil -> null', () => {
  rejects((s) => { s.relays[4].state = 1; });
  rejects((s) => { s.relays[4].state = 'true'; });
  rejects((s) => { s.relays[4].state = null; });
  rejects((s) => { delete s.relays[4].state; });
});

test('extract: yetim panjur (1 = shutter_up, 2 = light) -> null', () => {
  rejects((s) => { s.relays[1].type = 'light'; });
  rejects((s) => { s.relays[1].type = 'light'; s.shutters = s.shutters.filter((x) => x.pair !== 1); });
});

test('extract: yetim panjur (1 = light, 2 = shutter_down) -> null', () => {
  rejects((s) => { s.relays[0].type = 'light'; });
  rejects((s) => { s.relays[0].type = 'light'; s.shutters = s.shutters.filter((x) => x.pair !== 1); });
});

test('extract: ters cift (1 = shutter_down, 2 = shutter_up) -> null', () => {
  rejects((s) => { s.relays[0].type = 'shutter_down'; s.relays[1].type = 'shutter_up'; });
});

test('extract: ayni yonlu cift (up+up, down+down) -> null', () => {
  rejects((s) => { s.relays[1].type = 'shutter_up'; });
  rejects((s) => { s.relays[0].type = 'shutter_down'; });
});

test('extract: cift sinirina oturmayan panjur (2 = shutter_up, 3 = shutter_down) -> null', () => {
  const ok = fwState({ types: ['light', 'light', 'light', 'light'], names: ['A', 'B', 'C', 'D'] });
  rejects((s) => { s.relays[1].type = 'shutter_up'; s.relays[2].type = 'shutter_down'; }, ok);
  rejects((s) => {
    s.relays[1].type = 'shutter_up';
    s.relays[2].type = 'shutter_down';
    s.shutters = [{ pair: 1, pos: 0 }];
  }, ok);
});

test('extract: 9 role, 9. role shutter_up (esi yok) -> null', () => {
  const ok = fwState({ types: FW_TYPES.concat(['light']), names: fwNames(9) });
  assert.equal(extract(ok).count, 9);
  rejects((s) => { s.relays[8].type = 'shutter_up'; }, ok);
  rejects((s) => { s.relays[8].type = 'shutter_up'; s.shutters.push({ pair: 5, pos: 0 }); }, ok);
});

test('extract: shutters[] fazla cift -> null', () => {
  rejects((s) => { s.shutters.push({ pair: 3, pos: 0, moving: false, dir: 0, target: 255 }); });
});

test('extract: shutters[] eksik cift -> null', () => {
  rejects((s) => { s.shutters = s.shutters.filter((x) => x.pair !== 2); });
  rejects((s) => { s.shutters = []; });
});

test('extract: shutters[] yinelenen cift -> null', () => {
  rejects((s) => { s.shutters.push({ ...s.shutters[0] }); });
  rejects((s) => { s.shutters[1].pair = 1; });
});

test('extract: shutters[] gecersiz cift numarasi / kayit -> null', () => {
  rejects((s) => { s.shutters[0].pair = 0; });
  rejects((s) => { s.shutters[0].pair = 1.5; });
  rejects((s) => { s.shutters[0].pair = '1'; });
  rejects((s) => { delete s.shutters[0].pair; });
  rejects((s) => { s.shutters[0] = null; });
  rejects((s) => { s.shutters[0].pair = 21; });
});

test('extract: tipler panjur bildirmiyorken shutters[] dolu -> null', () => {
  const ok = fwState({ types: ['light', 'light'], names: ['A', 'B'] });
  assert.deepEqual(extract(ok).pairs, []);
  rejects((s) => { s.shutters = [{ pair: 1, pos: 0 }]; }, ok);
});

test('extract: gecerli pos shutterPos icine girer', () => {
  const st = fwState();
  st.shutters[0].pos = 0;
  st.shutters[1].pos = 100;
  const rep = extract(st);
  assert.deepEqual({ ...rep.shutterPos }, { 1: 0, 2: 100 });
});

test('extract: pos gecersizse cift yine sayilir ama shutterPos icine girmez', () => {
  for (const badPos of ['x', 101, -1, 50.5, null, undefined, true, Number.NaN]) {
    const st = fwState();
    st.shutters[0].pos = badPos;
    st.shutters[1].pos = 77;
    const rep = extract(st);
    assert.deepEqual(rep.pairs, [1, 2], 'pos=' + String(badPos));
    assert.deepEqual({ ...rep.shutterPos }, { 2: 77 }, 'pos=' + String(badPos));
  }
});

test('extract: ad temizligi - NUL, yon degistirici ve fazla bosluk atilir', () => {
  const dirty = '  Mutfak' + NUL + '   ' + RLO + ' Spot  ';
  const rep = extract(fwState({ names: withName(6, dirty) }));
  assert.equal(rep.relays[5].name, 'Mutfak Spot');
});

test('extract: ad temizligi - 150 karakter -> 100', () => {
  const rep = extract(fwState({ names: withName(6, 'x'.repeat(150)) }));
  assert.equal(rep.relays[5].name, 'x'.repeat(100));
});

test('extract: name yok -> bos dizge', () => {
  const st = fwState();
  delete st.relays[5].name;
  assert.equal(extract(st).relays[5].name, '');
});

// D15 (2026-10-04): tasarim §5.1 "en kucuk suphede null" -> "ya o ya bu" testleri tek sonuca baglandi.
test('extract: name dizge degilse (null dahil) yuk REDDEDILIR (null); alan hic yoksa ad bos sayilir', () => {
  for (const badName of [7, true, { a: 1 }, ['Mutfak'], null]) {
    rejects((st) => {
      st.relays[5].name = badName;
    });
  }
});

test('extract: imza ad ya da tip degisince degisir, state / konum degisince degismez', () => {
  const baseSig = extract(fwState()).signature;
  assert.equal(extract(fwState()).signature, baseSig, 'ayni yuk ayni imza');

  assert.notEqual(extract(fwState({ names: withName(6, 'Mutfak Spot') })).signature, baseSig, 'ad');

  const types = FW_TYPES.slice();
  types[7] = 'impulse';
  assert.notEqual(extract(fwState({ types })).signature, baseSig, 'tip');

  const st = fwState();
  st.relays[5].state = true;
  st.relays[0].state = true;
  assert.equal(extract(st).signature, baseSig, 'state imzayi degistirmemeli');

  assert.equal(extract(fwState({ pos: 63 })).signature, baseSig, 'konum imzayi degistirmemeli');

  const more = extract(fwState({ types: FW_TYPES.concat(['light']), names: fwNames(9) })).signature;
  assert.notEqual(more, baseSig, 'role sayisi');
});

test('extract: girdiyi degistirmez', () => {
  const st = fwState({ names: withName(6, ' Mutfak   Spot ') });
  const snapshot = structuredClone(st);
  deepFreeze(st);
  extract(st);
  assert.deepEqual(st, snapshot);
});

test('extract: sirasiz roleler -> null (pano her zaman 1..N sirasiyla yayinlar; sira disi yuk supheli sayilir)', () => {
  rejects((st) => {
    st.relays.reverse();
  });
  rejects((st) => {
    [st.relays[4], st.relays[5]] = [st.relays[5], st.relays[4]]; // yalniz iki komsu yer degistirdi
  });
});

test('extract (c): 40 role / 20 panjur cifti', () => {
  const types = [];
  const names = [];
  for (let p = 1; p <= 20; p += 1) {
    types.push('shutter_up', 'shutter_down');
    names.push('Perde ' + p + ' (Yukari)', 'Perde ' + p + ' (Asagi)');
  }
  const rep = extract(fwState({ types, names, pos: 12 }));
  assert.equal(rep.count, 40);
  assert.deepEqual(rep.pairs, Array.from({ length: 20 }, (_, i) => i + 1));
  assert.equal(Object.keys(rep.shutterPos).length, 20);
  assert.equal(rep.shutterPos[20], 12);
});

// ------------------------------------------------------------------------------
// §5.2 - §5.6 planLayoutSync (plan Task 1 Step 3, madde 1-20)
// ------------------------------------------------------------------------------
test('plan 1: tohum satirlari + varsayilan pano -> degisiklik yok, taban ilk kez yazilir', () => {
  const { plan } = run();
  assert.equal(plan.changed, false);
  assert.deepEqual(plan.updates, []);
  assert.deepEqual(plan.inserts, []);
  assert.deepEqual(plan.deletes, []);
  assert.equal(plan.baseChanged, true);
  assert.equal(plan.pendingShrink, false);
  assert.deepEqual(plan.ruleRelayChannels, []);
  assert.deepEqual(plan.ruleShutterPairs, []);
});

test('plan 2: ayni girdi + taban = yeni taban -> changed false, baseChanged false (idempotent)', () => {
  const first = run().plan;
  const { plan } = run({ base: structuredClone(first.newBase) });
  assert.equal(plan.changed, false);
  assert.equal(plan.baseChanged, false);
  assert.deepEqual(plan.updates, []);
  assert.deepEqual(plan.inserts, []);
});

test('plan 2b: taban JSONB dizgesinden parseBase ile okunursa da baseChanged false', () => {
  const first = run().plan;
  const base = L.parseBase(JSON.stringify(first.newBase));
  const { plan } = run({ base });
  assert.equal(plan.baseChanged, false);
  assert.equal(plan.changed, false);
});

test('plan 3: 5-6 panjur yapildi (pano adlariyla) -> iki satir yerinde panjur olur', () => {
  const names = withName(5, 'Salon (Yukari)', withName(6, 'Salon (Asagi)'));
  const types = FW_TYPES.slice();
  types[4] = 'shutter_up';
  types[5] = 'shutter_down';
  const { plan, after } = run({ names, types, pos: 40 });

  assert.equal(plan.changed, true);
  assert.deepEqual(plan.updates.map((u) => u.channel_index).sort(), [5, 6]);
  assert.deepEqual(plan.updates.map((u) => u.id).sort(), ['ep-5', 'ep-6'], 'satir yerinde guncellenir (kimlik korunur)');
  assert.deepEqual(plan.inserts, []);
  assert.deepEqual(plan.deletes, []);

  for (const c of [5, 6]) {
    const row = at(after, c);
    assert.equal(row.id, 'ep-' + c);
    assert.equal(row.type, 'shutter');
    assert.equal(row.shutter_pair_index, 3);
    assert.equal(row.shutter_duration_sec, 20);
    assert.equal(row.room, 'Salon');
    assert.equal(row.current_position, 40, 'panjur olan satirda konum panonun bildirdigi deger');
  }
  assert.equal(at(after, 5).name, 'Salon (Yukari)');
  assert.equal(at(after, 6).name, 'Salon (Asagi)');

  assert.deepEqual(plan.ruleRelayChannels, [5, 6]);
  assert.deepEqual(plan.ruleShutterPairs, []);
  assert.deepEqual(plan.summary, { inserted: 0, retyped: 2, renamed: 2, reroomed: 1, deleted: 0 });

  const seed = seedRows();
  for (const c of [1, 2, 3, 4, 7, 8]) assert.deepEqual(core(at(after, c)), at(seed, c), 'kanal ' + c + ' degismemeli');
});

test('plan 4: 1-2 iki lambaya cevrildi (pano adlariyla) -> light, cift/sure null, konum 0, oda Genel', () => {
  const names = withName(1, 'Röle 1 Aydınlatma', withName(2, 'Röle 2 Aydınlatma'));
  const types = FW_TYPES.slice();
  types[0] = 'light';
  types[1] = 'light';
  const { plan, after } = run({ names, types, pos: 55 });

  assert.deepEqual(plan.updates.map((u) => u.channel_index).sort(), [1, 2]);
  for (const c of [1, 2]) {
    const row = at(after, c);
    assert.equal(row.id, 'ep-' + c);
    assert.equal(row.type, 'light');
    assert.equal(row.shutter_pair_index, null);
    assert.equal(row.shutter_duration_sec, null);
    assert.equal(row.current_position, 0);
    assert.equal(row.room, 'Genel');
    assert.equal(row.name, 'Röle ' + c + ' Aydınlatma');
  }
  assert.deepEqual(plan.ruleShutterPairs, [1]);
  assert.deepEqual(plan.ruleRelayChannels, []);
});

test('plan 5: sinif degisti ama pano adi fabrika adi (1-2 lamba) -> "Röle 1", "Röle 2"', () => {
  const types = FW_TYPES.slice();
  types[0] = 'light';
  types[1] = 'light';
  const { after, plan } = run({ types });
  assert.equal(at(after, 1).name, 'Röle 1');
  assert.equal(at(after, 2).name, 'Röle 2');
  assert.equal(at(after, 1).room, 'Genel');
  assert.equal(at(after, 2).room, 'Genel');
  assert.equal(at(after, 1).type, 'light');
  assert.deepEqual(plan.ruleShutterPairs, [1]);
});

test('plan 5b: sinif degisti, pano adi fabrika adi (5-6 panjur) -> "Panjur 3 Yukarı" / "Panjur 3 Aşağı"', () => {
  const types = FW_TYPES.slice();
  types[4] = 'shutter_up';
  types[5] = 'shutter_down';
  const { after } = run({ types });
  assert.equal(at(after, 5).name, 'Panjur 3 Yukarı');
  assert.equal(at(after, 6).name, 'Panjur 3 Aşağı');
  assert.equal(at(after, 5).room, 'Genel');
  assert.equal(at(after, 6).room, 'Genel');
});

test('plan 5c: sinif degisti, pano adi BOS -> varsayilan ad', () => {
  const types = FW_TYPES.slice();
  types[4] = 'shutter_up';
  types[5] = 'shutter_down';
  types[0] = 'light';
  types[1] = 'impulse';
  const names = withName(5, '', withName(6, '', withName(1, '', withName(2, ''))));
  const { after } = run({ types, names });
  assert.equal(at(after, 5).name, 'Panjur 3 Yukarı');
  assert.equal(at(after, 6).name, 'Panjur 3 Aşağı');
  assert.equal(at(after, 1).name, 'Röle 1');
  assert.equal(at(after, 2).name, 'Röle 2');
  assert.equal(at(after, 2).type, 'impulse');
});

test('plan 5d: sinif sablondaki sinifa GERI dondu, pano adi fabrika adi -> sablon adi ve odasi', () => {
  // Satirlar: 1-2 daha once lambaya cevrilmis ("Röle 1/2", Genel). Pano yeniden 1-2 panjur bildiriyor.
  let rows = seedRows();
  rows = withRow(rows, 1, { name: 'Röle 1', type: 'light', room: 'Genel', shutter_pair_index: null, shutter_duration_sec: null });
  rows = withRow(rows, 2, { name: 'Röle 2', type: 'light', room: 'Genel', shutter_pair_index: null, shutter_duration_sec: null });
  const { after, plan } = run({ rows });
  assert.deepEqual(core(at(after, 1)), { id: 'ep-1', channel_index: 1, ...rowOfSeed(1) });
  assert.deepEqual(core(at(after, 2)), { id: 'ep-2', channel_index: 2, ...rowOfSeed(2) });
  assert.deepEqual(plan.ruleRelayChannels, [1, 2]);
});

/** Eski fabrika panosu (FW_NAMES) bildiriminde beklenen bulut satiri: eski tohum (LEGACY_SEED). */
function rowOfSeed(channel) {
  const s = LEGACY_SEED[channel];
  return { name: s.name, type: s.type, room: s.room, shutter_pair_index: s.pair, shutter_duration_sec: s.durationSec };
}

// D2 (2026-10-04): lamba/priz <-> darbe degisimi o kanalin ROLE kurallarini kapatir ("lambayi ac" kurali kapi/kilit
// darbesini tetiklemesin; "Tetikle" kurali lambayi kalici cekili birakmasin). Onceki beklenti (kural listesi bos) D2
// karariyla tersine cevrildi.
test('plan 6: role 7 impulse -> type impulse; ad/oda degismez; kanal 7 role kurallari kapatilir (D2)', () => {
  const types = FW_TYPES.slice();
  types[6] = 'impulse';
  const { plan, after } = run({ types });
  assert.equal(plan.updates.length, 1);
  assert.equal(plan.updates[0].id, 'ep-7');
  assert.deepEqual(plan.updates[0].set, { type: 'impulse' });
  assert.equal(at(after, 7).name, 'Koridor Aydınlatma');
  assert.equal(at(after, 7).room, 'Koridor');
  assert.deepEqual(plan.ruleRelayChannels, [7]);
  assert.deepEqual(plan.ruleShutterPairs, []);
});

test('plan 6b: impulse satiri, pano light -> type light (ayni sinif; konum yazilmaz); role kurali kapatilir (D2)', () => {
  const rows = withRow(seedRows(), 7, { type: 'impulse' });
  const { plan, after } = run({ rows });
  assert.equal(at(after, 7).type, 'light');
  assert.deepEqual(plan.updates[0].set, { type: 'light' });
  assert.deepEqual(plan.ruleRelayChannels, [7]);
  assert.deepEqual(plan.ruleShutterPairs, []);
});

test('plan 6c (D2): light <-> plug kozmetiktir -> kural kapatma YOK; impulse ayni kaldiysa kapatma YOK', () => {
  // plug satir + pano light: priz korunur, hicbir sey degismez
  const a = run({ rows: withRow(seedRows(), 6, { type: 'plug' }) });
  assert.equal(a.plan.changed, false);
  assert.deepEqual(a.plan.ruleRelayChannels, []);
  // impulse satir + pano impulse: degisiklik yok
  const types = FW_TYPES.slice();
  types[6] = 'impulse';
  const b = run({ types, rows: withRow(seedRows(), 7, { type: 'impulse' }) });
  assert.equal(b.plan.changed, false);
  assert.deepEqual(b.plan.ruleRelayChannels, []);
});

test('plan 7: satir plug, pano light -> degisiklik yok (priz korunur)', () => {
  const rows = withRow(seedRows(), 6, { type: 'plug' });
  const { plan, after } = run({ rows });
  assert.equal(plan.changed, false);
  assert.deepEqual(plan.updates, []);
  assert.equal(at(after, 6).type, 'plug');
});

test('plan 7b: satir plug, pano impulse -> impulse; role kurali kapatilir (D2)', () => {
  const rows = withRow(seedRows(), 6, { type: 'plug' });
  const types = FW_TYPES.slice();
  types[5] = 'impulse';
  const { plan, after } = run({ rows, types });
  assert.equal(at(after, 6).type, 'impulse');
  assert.deepEqual(plan.updates.map((u) => u.id), ['ep-6']);
  assert.deepEqual(plan.ruleRelayChannels, [6]);
});

test('plan 7c (e): satir plug, pano panjur -> shutter (panjur satirinda plug olmaz); role kurallari kapatilir', () => {
  const rows = withRow(withRow(seedRows(), 5, { type: 'plug' }), 6, { type: 'plug' });
  const types = FW_TYPES.slice();
  types[4] = 'shutter_up';
  types[5] = 'shutter_down';
  const { plan, after } = run({ rows, types });
  assert.equal(at(after, 5).type, 'shutter');
  assert.equal(at(after, 6).type, 'shutter');
  assert.equal(at(after, 5).shutter_pair_index, 3);
  assert.deepEqual(plan.ruleRelayChannels, [5, 6]);
});

test('plan 7d (e): plug yalniz VAR OLAN plug satirinda korunur; light satir ve yeni satir light olur', () => {
  // light satir + pano light -> light kalir (plug uretilmez)
  const a = run();
  assert.equal(at(a.after, 5).type, 'light');
  // yeni satir -> light
  const b = run({ rows: seedRows(4) });
  assert.deepEqual(b.plan.inserts.map((i) => i.type), ['light', 'light', 'light', 'light']);
  // panjurdan lambaya donen satir -> light (plug degil)
  const types = FW_TYPES.slice();
  types[2] = 'light';
  types[3] = 'light';
  const c = run({ types });
  assert.equal(at(c.after, 3).type, 'light');
  assert.equal(at(c.after, 4).type, 'light');
});

test('plan 8: yalniz ad - pano 6 = "Mutfak Spot", bulut sablon adi, taban yok -> ad alinir, oda Mutfak', () => {
  const { plan, after } = run({ names: withName(6, 'Mutfak Spot') });
  assert.deepEqual(plan.updates.map((u) => u.id), ['ep-6']);
  assert.equal(at(after, 6).name, 'Mutfak Spot');
  assert.equal(at(after, 6).room, 'Mutfak');
  assert.equal(at(after, 6).type, 'light');
  assert.ok(!('current_position' in plan.updates[0].set), 'sinif degismedi: konum yazilmaz');
  assert.deepEqual(plan.ruleRelayChannels, []);
});

test('plan 8b: bulut adi fabrika (ASCII) adi / "Röle N" / "Panjur P Yukarı" ise otomatik sayilir -> pano adi alinir', () => {
  for (const cloudName of ['Mutfak Aydinlatma', 'Röle 6', 'MUTFAK AYDINLATMA', 'mutfak aydınlatma', '']) {
    const rows = withRow(seedRows(), 6, { name: cloudName });
    const { after } = run({ rows, names: withName(6, 'Mutfak Spot') });
    assert.equal(at(after, 6).name, 'Mutfak Spot', 'bulut adi: ' + JSON.stringify(cloudName));
  }
  for (const [channel, cloudName] of [[1, 'Panjur 1 Yukarı'], [2, 'Panjur 1 Aşağı'], [1, 'Salon Panjur (Yukari)']]) {
    const rows = withRow(seedRows(), channel, { name: cloudName });
    const { after } = run({ rows, names: withName(channel, 'Teras Perde') });
    assert.equal(at(after, channel).name, 'Teras Perde', 'bulut adi: ' + cloudName);
  }
});

test('plan 9: pano adi ozel, bulut adi kullaniciya ait ("Tezgah"), taban yok -> korunur', () => {
  const rows = withRow(seedRows(), 6, { name: 'Tezgah' });
  const { plan, after } = run({ rows, names: withName(6, 'Mutfak Spot') });
  assert.equal(plan.changed, false);
  assert.equal(at(after, 6).name, 'Tezgah');
});

test('plan 10: taban "Mutfak Spot", pano "Mutfak Tezgah", bulut "Tezgah" -> pano adi (son yazan kazanir)', () => {
  const rows = withRow(seedRows(), 6, { name: 'Tezgah' });
  const { after } = run({
    rows,
    base: baseOf({ names: withName(6, 'Mutfak Spot') }),
    names: withName(6, 'Mutfak Tezgah'),
  });
  assert.equal(at(after, 6).name, 'Mutfak Tezgah');
  assert.equal(at(after, 6).room, 'Mutfak');
});

test('plan 10b: taban fabrika adi, pano ilk kez ozel ad aldi, bulut kullaniciya ait -> pano adi (panoda ad degisti)', () => {
  const rows = withRow(seedRows(), 6, { name: 'Tezgah' });
  const { after } = run({ rows, base: baseOf(), names: withName(6, 'Mutfak Spot') });
  assert.equal(at(after, 6).name, 'Mutfak Spot');
});

test('plan 11: taban = pano = "Mutfak Spot", bulut "Tezgah" -> korunur', () => {
  const rows = withRow(seedRows(), 6, { name: 'Tezgah' });
  const names = withName(6, 'Mutfak Spot');
  const { plan, after } = run({ rows, base: baseOf({ names }), names });
  assert.equal(plan.changed, false);
  assert.equal(plan.baseChanged, false);
  assert.equal(at(after, 6).name, 'Tezgah');
});

test('plan 12: taban "Mutfak Spot", pano fabrika adina dondu, bulut "Mutfak Spot" -> "Mutfak Aydınlatma", oda Mutfak', () => {
  const rows = withRow(seedRows(), 6, { name: 'Mutfak Spot' });
  const { plan, after } = run({ rows, base: baseOf({ names: withName(6, 'Mutfak Spot') }) });
  assert.equal(at(after, 6).name, 'Mutfak Aydınlatma');
  assert.equal(at(after, 6).room, 'Mutfak');
  assert.deepEqual(plan.updates.map((u) => u.id), ['ep-6']);
});

test('plan 12b: ayni durum, oda eski addan turetilmis ("Teras Spot" / Teras) -> sablon adi ve sablon odasi', () => {
  const rows = withRow(seedRows(), 6, { name: 'Teras Spot', room: 'Teras' });
  const { after } = run({ rows, base: baseOf({ names: withName(6, 'Teras Spot') }) });
  assert.equal(at(after, 6).name, 'Mutfak Aydınlatma');
  assert.equal(at(after, 6).room, 'Mutfak');
});

test('plan 12c: pano varsayilana dondu ama bulut adi kullaniciya ait (taban adi degil) -> korunur', () => {
  const rows = withRow(seedRows(), 6, { name: 'Tezgah' });
  const { plan, after } = run({ rows, base: baseOf({ names: withName(6, 'Mutfak Spot') }) });
  assert.equal(plan.changed, false);
  assert.equal(at(after, 6).name, 'Tezgah');
});

test('plan 12e: taban da pano da varsayilan ad (bicimi farkli), bulut ASCII fabrika adini gosteriyor -> korunur', () => {
  // "Varsayilana dondu" kurali yalniz taban adi OZEL idiyse gecerlidir; aksi "Diger -> bulut adi korunur".
  for (const boardName of ['', 'MUTFAK AYDINLATMA', 'Mutfak Aydınlatma']) {
    const rows = withRow(seedRows(), 6, { name: 'Mutfak Aydinlatma' });
    const { plan, after } = run({ rows, base: baseOf(), names: withName(6, boardName) });
    assert.equal(plan.changed, false, 'pano adi: ' + JSON.stringify(boardName));
    assert.equal(at(after, 6).name, 'Mutfak Aydinlatma');
  }
});

test('plan 12d: pano varsayilana dondu, sinif sablondan farkli (5-6 panjur) -> "Panjur 3 ..." varsayilani', () => {
  const types = FW_TYPES.slice();
  types[4] = 'shutter_up';
  types[5] = 'shutter_down';
  const custom = withName(5, 'Salon (Yukari)', withName(6, 'Salon (Asagi)'));
  let rows = seedRows();
  rows = withRow(rows, 5, { name: 'Salon (Yukari)', type: 'shutter', room: 'Salon', shutter_pair_index: 3, shutter_duration_sec: 31 });
  rows = withRow(rows, 6, { name: 'Salon (Asagi)', type: 'shutter', room: 'Salon', shutter_pair_index: 3, shutter_duration_sec: 31 });
  const { after } = run({ rows, types, base: baseOf({ names: custom, types }) });
  assert.equal(at(after, 5).name, 'Panjur 3 Yukarı');
  assert.equal(at(after, 6).name, 'Panjur 3 Aşağı');
  assert.equal(at(after, 5).shutter_duration_sec, 31, 'sure korunur');
  assert.equal(at(after, 5).room, 'Genel', 'oda eski addan turetilmisti -> yeniden hesaplanir');
});

test('plan 13: oda kullaniciya ait ("Teras"), ad degisti -> oda korunur', () => {
  const rows = withRow(seedRows(), 6, { room: 'Teras' });
  const { plan, after } = run({ rows, names: withName(6, 'Mutfak Spot') });
  assert.equal(at(after, 6).name, 'Mutfak Spot');
  assert.equal(at(after, 6).room, 'Teras');
  assert.deepEqual(plan.updates[0].set, { name: 'Mutfak Spot' });
});

test('plan 13b: oda eski addan turetilmis (otomatik) -> yeni addan yeniden turetilir', () => {
  const rows = withRow(seedRows(), 6, { name: 'Balkon Lamba', room: 'Balkon' });
  const { after } = run({
    rows,
    base: baseOf({ names: withName(6, 'Balkon Lamba') }),
    names: withName(6, 'Teras Lamba'),
  });
  assert.equal(at(after, 6).name, 'Teras Lamba');
  assert.equal(at(after, 6).room, 'Teras');
});

test('plan 13d: oda sablon odasi (eski addan turetilemiyor) -> otomatik sayilir, yeni addan turetilir', () => {
  // Kanal 6: ad kullaniciya ait ("Tezgah"), oda hala sablon odasi ("Mutfak"). Panoda ad degisti -> pano adi + yeni oda.
  const rows = withRow(seedRows(), 6, { name: 'Tezgah' });
  const { after } = run({
    rows,
    base: baseOf({ names: withName(6, 'Mutfak Spot') }),
    names: withName(6, 'Teras Lamba'),
  });
  assert.equal(at(after, 6).name, 'Teras Lamba');
  assert.equal(at(after, 6).room, 'Teras');
});

test('plan 13e: oda kullaniciya ait ve eski ad baska odadan -> korunur (sablon odasi baska kanalin odasi olsa da)', () => {
  // Kanal 6 icin "Salon" ne sablon odasi (Mutfak) ne de eski addan ("Tezgah") turetilmis: kullanicinin secimi.
  const rows = withRow(seedRows(), 6, { name: 'Tezgah', room: 'Salon' });
  const { after } = run({
    rows,
    base: baseOf({ names: withName(6, 'Mutfak Spot') }),
    names: withName(6, 'Teras Lamba'),
  });
  assert.equal(at(after, 6).name, 'Teras Lamba');
  assert.equal(at(after, 6).room, 'Salon');
});

test('plan 13c: ad DEGISMEDIYSE oda yeniden hesaplanmaz (bos oda dahil)', () => {
  for (const room of ['', 'Genel', 'Teras']) {
    const rows = withRow(seedRows(), 6, { room });
    const { plan, after } = run({ rows });
    assert.equal(plan.changed, false, 'oda: ' + JSON.stringify(room));
    assert.equal(at(after, 6).room, room);
  }
});

test('plan 14: ad "Yatak Odası Lamba" -> oda "Yatak Odası"; ad "Spot 3" -> oda "Genel"', () => {
  const { after } = run({ names: withName(7, 'Yatak Odası Lamba', withName(8, 'Spot 3')) });
  assert.equal(at(after, 7).name, 'Yatak Odası Lamba');
  assert.equal(at(after, 7).room, 'Yatak Odası');
  assert.equal(at(after, 8).name, 'Spot 3');
  assert.equal(at(after, 8).room, 'Genel');
});

test('plan 14b (g): "Genel", bos ve null oda otomatik sayilir -> ad degisince yeniden turetilir', () => {
  for (const room of ['Genel', '', null, '  ']) {
    const rows = withRow(seedRows(), 7, { room });
    const { after } = run({ rows, names: withName(7, 'Yatak Odası Lamba') });
    assert.equal(at(after, 7).room, 'Yatak Odası', 'oda: ' + JSON.stringify(room));
  }
});

test('plan 14c: ad "Genel Lamba" -> oda "Genel"', () => {
  const { after } = run({ names: withName(7, 'Genel Lamba') });
  assert.equal(at(after, 7).room, 'Genel');
});

test('plan 15: 16 role bildirildi, 8 satir var -> 8 ekleme ("Ek Modül Röle 1..8", light, Genel)', () => {
  const types = FW_TYPES.concat(new Array(8).fill('light'));
  const { plan } = run({ types, names: fwNames(16), rows: seedRows(8) });
  assert.equal(plan.changed, true);
  assert.deepEqual(plan.updates, []);
  assert.equal(plan.inserts.length, 8);
  const inserts = plan.inserts.slice().sort((a, b) => a.channel_index - b.channel_index);
  inserts.forEach((ins, i) => {
    assert.equal(ins.channel_index, 9 + i);
    assert.equal(ins.name, 'Ek Modül Röle ' + (i + 1));
    assert.equal(ins.type, 'light');
    assert.equal(ins.room, 'Genel');
    assert.equal(ins.shutter_pair_index, null);
    assert.equal(ins.shutter_duration_sec, null);
    assert.equal(ins.current_state, false);
    assert.equal(ins.current_position, 0);
  });
  assert.equal(plan.summary.inserted, 8);
  assert.deepEqual(plan.ruleRelayChannels, []);
});

test('plan 15b: yeni satir, pano adi ozel -> pano adi, tip ve addan turetilen oda; durum bildirimden', () => {
  const types = FW_TYPES.concat(['impulse', 'light']);
  const names = fwNames(10);
  names[8] = 'Garaj Kapısı';
  names[9] = 'Spot 3';
  const st = fwState({ types, names });
  st.relays[9].state = true;
  const { plan } = run({ state: st, rows: seedRows(8) });
  const ins9 = plan.inserts.find((i) => i.channel_index === 9);
  const ins10 = plan.inserts.find((i) => i.channel_index === 10);
  assert.equal(ins9.name, 'Garaj Kapısı');
  assert.equal(ins9.type, 'impulse');
  assert.equal(ins9.room, 'Garaj');
  assert.equal(ins9.current_state, false);
  assert.equal(ins10.name, 'Spot 3');
  assert.equal(ins10.type, 'light');
  assert.equal(ins10.room, 'Genel');
  assert.equal(ins10.current_state, true);
});

test('plan 15c: yeni satir panjur (9-10), pano adi fabrika adi -> "Panjur 5 Yukarı/Aşağı", cift 5, sure 20', () => {
  const types = FW_TYPES.concat(['shutter_up', 'shutter_down']);
  const { plan } = run({ types, names: fwNames(10), rows: seedRows(8), pos: 30 });
  const ins9 = plan.inserts.find((i) => i.channel_index === 9);
  const ins10 = plan.inserts.find((i) => i.channel_index === 10);
  assert.equal(ins9.name, 'Panjur 5 Yukarı');
  assert.equal(ins10.name, 'Panjur 5 Aşağı');
  for (const ins of [ins9, ins10]) {
    assert.equal(ins.type, 'shutter');
    assert.equal(ins.shutter_pair_index, 5);
    assert.equal(ins.shutter_duration_sec, 20);
    assert.equal(ins.room, 'Genel');
    assert.equal(ins.current_position, 30);
  }
  assert.deepEqual(plan.ruleRelayChannels, [], 'yeni satir icin kural kapatilmaz');
});

test('plan 15d: hic satir yok + varsayilan pano -> 8 ekleme tohum sablonuyla ayni (ASCII fabrika adlari tasinmaz)', () => {
  const { plan } = run({ rows: [] });
  const inserts = plan.inserts.slice().sort((a, b) => a.channel_index - b.channel_index);
  assert.equal(inserts.length, 8);
  inserts.forEach((ins, i) => {
    assert.deepEqual(
      { name: ins.name, type: ins.type, room: ins.room, shutter_pair_index: ins.shutter_pair_index,
        shutter_duration_sec: ins.shutter_duration_sec },
      rowOfSeed(i + 1)
    );
  });
});

test('plan 15e: aradaki eksik satir (kanal 3) acilir', () => {
  const rows = seedRows().filter((r) => r.channel_index !== 3);
  const { plan } = run({ rows });
  assert.deepEqual(plan.inserts.map((i) => i.channel_index), [3]);
  assert.equal(plan.inserts[0].name, 'Oda Panjur Yukarı');
  assert.equal(plan.inserts[0].shutter_pair_index, 2);
  assert.deepEqual(plan.updates, []);
});

test('plan 16: 8 role bildirildi, 16 satir var, confirmShrink false -> silme yok, pendingShrink true', () => {
  const { plan } = run({ rows: seedRows(16), confirmShrink: false });
  assert.deepEqual(plan.deletes, []);
  assert.equal(plan.deleteAbove, null);
  assert.equal(plan.pendingShrink, true);
  assert.equal(plan.changed, false);
  assert.deepEqual(plan.ruleRelayChannels, [], 'satir silinmeden kural kapatilmaz');
  assert.deepEqual(plan.ruleShutterPairs, []);
});

test('plan 17: ayni, confirmShrink true -> 8 silme, deleteAbove 8, ruleRelayChannels [9..16]', () => {
  const { plan, after } = run({ rows: seedRows(16), confirmShrink: true });
  assert.equal(plan.deletes.length, 8);
  assert.deepEqual(sortedNums(plan.deletes.map((d) => d.channel_index)), [9, 10, 11, 12, 13, 14, 15, 16]);
  assert.equal(plan.deleteAbove, 8);
  assert.equal(plan.pendingShrink, false);
  assert.equal(plan.changed, true);
  assert.deepEqual(plan.ruleRelayChannels, [9, 10, 11, 12, 13, 14, 15, 16]);
  assert.deepEqual(plan.ruleShutterPairs, []);
  assert.equal(plan.summary.deleted, 8);
  assert.equal(after.length, 8);
});

test('plan 17b: silinen satirlar panjursa cift kurallari da listelenir', () => {
  let rows = seedRows(12);
  rows = withRow(rows, 9, { type: 'shutter', shutter_pair_index: 5, shutter_duration_sec: 25 });
  rows = withRow(rows, 10, { type: 'shutter', shutter_pair_index: 5, shutter_duration_sec: 25 });
  const { plan } = run({ rows, confirmShrink: true });
  assert.deepEqual(plan.ruleShutterPairs, [5]);
  for (const c of [11, 12]) assert.ok(plan.ruleRelayChannels.includes(c));
});

test('plan 17c: satir fazlasi yokken confirmShrink true -> silme yok', () => {
  const { plan } = run({ confirmShrink: true });
  assert.deepEqual(plan.deletes, []);
  assert.equal(plan.deleteAbove, null);
  assert.equal(plan.changed, false);
});

test('plan 17d: kuculme beklerken bildirilen kanallardaki degisiklik yine uygulanir; fazla satirlara dokunulmaz', () => {
  const types = FW_TYPES.slice();
  types[7] = 'impulse';
  const { plan, after } = run({ rows: seedRows(16), types, confirmShrink: false });
  assert.equal(plan.pendingShrink, true);
  assert.deepEqual(plan.updates.map((u) => u.id), ['ep-8']);
  assert.equal(after.length, 16);
});

test('plan 18: mevcut panjur satirinda sure 37 korunur; shutter_pair_index null ise cift numarasi yazilir', () => {
  let rows = seedRows();
  rows = withRow(rows, 1, { shutter_duration_sec: 37, shutter_pair_index: null });
  rows = withRow(rows, 2, { shutter_duration_sec: 37 });
  rows = withRow(rows, 3, { shutter_pair_index: null });
  const { plan, after } = run({ rows, pos: 70 });
  assert.equal(at(after, 1).shutter_duration_sec, 37);
  assert.equal(at(after, 2).shutter_duration_sec, 37);
  assert.equal(at(after, 1).shutter_pair_index, 1);
  assert.equal(at(after, 3).shutter_pair_index, 2);
  assert.equal(at(after, 3).shutter_duration_sec, 20);
  assert.deepEqual(plan.updates.map((u) => u.id).sort(), ['ep-1', 'ep-3']);
  for (const u of plan.updates) {
    assert.deepEqual(u.set, { shutter_pair_index: pairOf(u.channel_index) }, 'yalniz cift numarasi yazilir');
  }
  assert.deepEqual(plan.ruleRelayChannels, []);
  assert.deepEqual(plan.ruleShutterPairs, []);
});

test('plan 18b: panjur satirinda YANLIS cift numarasi -> panonun cift numarasiyla duzeltilir', () => {
  const rows = withRow(seedRows(), 3, { shutter_pair_index: 7 });
  const { after } = run({ rows });
  assert.equal(at(after, 3).shutter_pair_index, 2);
});

test('plan 18c: panjur -> role, satirdaki cift numarasi yanlis (7) -> kural panonun ciftine (1) gore kapatilir', () => {
  // §5.6: zamanli kural "kanal numarasi + kanal tipi" ile baglidir, uc nokta satirina bakmaz. Panjur kurali
  // cift p = kanal 2p-1 / 2p olarak dogrulanir ve panoya oyle gonderilir.
  let rows = withRow(seedRows(), 1, { shutter_pair_index: 7 });
  rows = withRow(rows, 2, { shutter_pair_index: 7 });
  const types = FW_TYPES.slice();
  types[0] = 'light';
  types[1] = 'light';
  const { plan } = run({ rows, types });
  assert.deepEqual(plan.ruleShutterPairs, [1]);
  assert.deepEqual(plan.ruleRelayChannels, []);
});

test('plan 18d: silinen panjur satirinda cift numarasi yanlis / bos -> kural kanaldan turetilen cifte gore', () => {
  let rows = seedRows(12);
  rows = withRow(rows, 11, { type: 'shutter', shutter_pair_index: 2, shutter_duration_sec: 25 });
  rows = withRow(rows, 12, { type: 'shutter', shutter_pair_index: null, shutter_duration_sec: 25 });
  const { plan } = run({ rows, confirmShrink: true });
  assert.deepEqual(plan.ruleShutterPairs, [6]);
  for (const c of [9, 10]) assert.ok(plan.ruleRelayChannels.includes(c));
});

test('plan 18e: role satirinda kalmis eski sure (37) panjura donunce KORUNMAZ -> 20 sn (§5.2: "degilse 20 sn")', () => {
  let rows = withRow(seedRows(), 5, { shutter_duration_sec: 37 });
  rows = withRow(rows, 6, { shutter_duration_sec: 37 });
  const types = FW_TYPES.slice();
  types[4] = 'shutter_up';
  types[5] = 'shutter_down';
  const { after } = run({ rows, types });
  assert.equal(at(after, 5).shutter_duration_sec, 20);
  assert.equal(at(after, 6).shutter_duration_sec, 20);
});

test('plan 19: pano degisimi - taban null, satir adlari ozel, pano fabrika adlari -> adlar korunur', () => {
  const custom = ['Büyük Perde Yukarı', 'Büyük Perde Aşağı', 'Çalışma Perdesi Yukarı', 'Çalışma Perdesi Aşağı',
    'Avize', 'Tezgah', 'Vestiyer', 'Fener'];
  const rows = seedRows().map((r, i) => ({ ...r, name: custom[i], room: 'Bizim Oda' }));
  const { plan, after } = run({ rows, base: null });
  assert.equal(plan.changed, false);
  assert.equal(plan.baseChanged, true);
  assert.deepEqual(after.map((r) => r.name), custom);
  assert.deepEqual(after.map((r) => r.room), new Array(8).fill('Bizim Oda'));
});

test('plan 20: yeniden tohumlama - taban = pano (ozel adlar), satirlar sablon adlari -> pano adlari yeniden alinir', () => {
  const names = ['Teras Perde (Yukari)', 'Teras Perde (Asagi)', 'Ofis Perde (Yukari)', 'Ofis Perde (Asagi)',
    'Salon Avize', 'Mutfak Spot', 'Hol Aplik', 'Balkon Fener'];
  const { plan, after } = run({ names, base: baseOf({ names }) });
  assert.equal(plan.baseChanged, false);
  assert.equal(plan.changed, true);
  assert.deepEqual(after.map((r) => r.name), names);
  assert.deepEqual(after.map((r) => r.room), ['Teras', 'Teras', 'Ofis', 'Ofis', 'Salon', 'Mutfak', 'Hol', 'Balkon']);
  assert.equal(plan.summary.renamed, 8);
});

// ------------------------------------------------------------------------------
// D1 (2026-10-04): gecici (fabrika) pano korumasi. Servis `provisional` girdisini cihaz devreye alinmamis + taban
// bos + bildirim tam fabrika yerlesimi ise verir; cekirdek yikici/geri donulmez adimlari erteler.
// ------------------------------------------------------------------------------
/** Pano degisimi oncesi kullanicinin satirlari: 16 kanal, 5-6 panjur (olculmus 35 sn), 7 darbe, 9-16 ek modul. */
function movedRows() {
  let rows = seedRows(16);
  rows = withRow(rows, 1, { name: 'Büyük Perde Yukarı', room: 'Salon' });
  rows = withRow(rows, 5, { name: 'Mutfak Stor Yukarı', type: 'shutter', room: 'Mutfak', shutter_pair_index: 3, shutter_duration_sec: 35 });
  rows = withRow(rows, 6, { name: 'Mutfak Stor Aşağı', type: 'shutter', room: 'Mutfak', shutter_pair_index: 3, shutter_duration_sec: 35 });
  rows = withRow(rows, 7, { name: 'Garaj Kapısı', type: 'impulse', room: 'Garaj' });
  rows = withRow(rows, 9, { name: 'Bahçe Sulama', room: 'Bahçe' });
  rows = withRow(rows, 12, { name: 'Havuz Işığı', room: 'Bahçe' });
  return rows;
}

function planProvisional({ reported, base = null, rows, confirmShrink = false }) {
  const snapshot = structuredClone({ reported, base, rows });
  const plan = L.planLayoutSync({ reported, base, rows, confirmShrink, provisional: true });
  assert.deepEqual({ reported, base, rows }, snapshot, 'girdiler degismez');
  assert.deepEqual(L.planLayoutSync(structuredClone({ reported, base, rows, confirmShrink, provisional: true })), plan, 'deterministik');
  return plan;
}

test('D1 isFactoryLayout: yalniz tam 8 role + fabrika tipleri + her ad varsayilan (fabrika/tohum/bos) ise true', () => {
  assert.equal(typeof L.isFactoryLayout, 'function');
  assert.equal(L.isFactoryLayout(extract(fwState())), true);
  assert.equal(L.isFactoryLayout(extract(fwState({ names: FW_NAMES.map((n) => n.toUpperCase()) }))), true, 'harf farki');
  assert.equal(L.isFactoryLayout(extract(fwState({ names: seedRows().map((r) => r.name) }))), true, 'tohum adlari');
  assert.equal(L.isFactoryLayout(extract(fwState({ names: new Array(8).fill('') }))), true, 'bos adlar');
  assert.equal(L.isFactoryLayout(extract(fwState({ names: withName(6, 'Mutfak Spot') }))), false, 'ozel ad');
  assert.equal(L.isFactoryLayout(extract(fwState({ names: withName(6, BULB) }))), false, 'simge ad ozeldir (D8)');
  const imp = FW_TYPES.slice();
  imp[6] = 'impulse';
  assert.equal(L.isFactoryLayout(extract(fwState({ types: imp }))), false, 'darbe');
  const lights = FW_TYPES.slice();
  lights[0] = 'light';
  lights[1] = 'light';
  assert.equal(L.isFactoryLayout(extract(fwState({ types: lights }))), false, '1-2 lamba');
  const sh = FW_TYPES.slice();
  sh[4] = 'shutter_up';
  sh[5] = 'shutter_down';
  assert.equal(L.isFactoryLayout(extract(fwState({ types: sh }))), false, '5-6 panjur');
  assert.equal(L.isFactoryLayout(extract(fwState({ types: FW_TYPES.concat(['light', 'light']), names: fwNames(10) }))), false, '10 role');
  assert.equal(L.isFactoryLayout(extract(fwState({ types: FW_TYPES.slice(0, 4), names: FW_NAMES.slice(0, 4) }))), false, '4 role');
  // v1.3.2+ fabrika yerlesimi (sahip karari 2026-10-09: sabit rol yok): 8 lamba, "Röle N" ya da bos ad
  const allLights = new Array(8).fill('light');
  const releNames = Array.from({ length: 8 }, (_, i) => 'Röle ' + (i + 1));
  assert.equal(L.isFactoryLayout(extract(fwState({ types: allLights, names: releNames }))), true, 'v1.3.2 fabrika');
  assert.equal(L.isFactoryLayout(extract(fwState({ types: allLights, names: new Array(8).fill('') }))), true, 'v1.3.2 bos adlar');
  const releCustom = releNames.slice();
  releCustom[2] = 'Mutfak Spot';
  assert.equal(L.isFactoryLayout(extract(fwState({ types: allLights, names: releCustom }))), false, 'v1.3.2 ozel ad');
  const releShutter = allLights.slice();
  releShutter[0] = 'shutter_up';
  releShutter[1] = 'shutter_down';
  assert.equal(L.isFactoryLayout(extract(fwState({ types: releShutter, names: releNames }))), false, 'v1.3.2 + servis panjuru');
  assert.equal(L.isFactoryLayout(null), false);
  assert.equal(L.isFactoryLayout({}), false);
});

test('D1 plan: normal modda deferred 0; gecici modda ertelenecek bir sey yoksa plan normal planla BIREBIR ayni', () => {
  const reported = extract(fwState());
  const normal = L.planLayoutSync({ reported, base: null, rows: seedRows() });
  assert.equal(normal.deferred, 0);
  for (const rows of [seedRows(), seedRows(6), withRow(seedRows(), 6, { name: 'Tezgah', room: 'Bizim Oda' }), withRow(seedRows(), 6, { type: 'plug' })]) {
    const a = L.planLayoutSync({ reported, base: null, rows });
    const b = planProvisional({ reported, rows });
    assert.equal(b.deferred, 0);
    assert.deepEqual(b, a, 'deferred === 0 -> birebir normal (taban yazilir)');
    assert.equal(b.baseChanged, true);
    assert.deepEqual(b.newBase, L.serializeBase(reported));
  }
});

test('D1 plan: pano degisimi + fabrika pano -> panjurdan roleye donus, silme, ad/oda ve taban ERTELENIR; darbe->lamba uygulanir', () => {
  const reported = extract(fwState());
  const rows = movedRows();
  const normal = L.planLayoutSync({ reported, base: null, rows, confirmShrink: true });
  assert.ok(normal.deletes.length === 8 && normal.ruleShutterPairs.includes(3), 'on kosul: normal mod yikicidir');

  for (const confirmShrink of [false, true]) {
    const plan = planProvisional({ reported, rows, confirmShrink });
    // satir silme yok, kuculme kaydi yok
    assert.deepEqual(plan.deletes, []);
    assert.equal(plan.deleteAbove, null);
    assert.equal(plan.pendingShrink, false);
    // 5-6 panjur kalir: hicbir alani degismez, cift 3 kurali kapatilmaz
    assert.deepEqual(plan.updates.filter((u) => u.channel_index === 5 || u.channel_index === 6), []);
    assert.deepEqual(plan.ruleShutterPairs, []);
    // 7 darbe -> lamba (D2 guvenlik yonu): tip uygulanir, ad/oda korunur, role kurali kapatilir
    assert.deepEqual(plan.updates, [{ id: 'ep-7', channel_index: 7, set: { type: 'light' } }]);
    assert.deepEqual(plan.ruleRelayChannels, [7]);
    assert.equal(plan.changed, true);
    // taban yazilmaz
    assert.equal(plan.baseChanged, false);
    assert.equal(plan.newBase, null);
    // ertelenen: 5 ve 6 sinif degisimi (2) + 9-16 silme (8)
    assert.equal(plan.deferred, 10);
    assert.deepEqual(plan.inserts, []);
  }
});

test('D1 plan: gecici modda role -> panjur sinif degisimi UYGULANIR (motor guvenligi) ama ad/oda korunur ve ertelenir', () => {
  const lights = FW_TYPES.slice(); // satirlarda 1-2 lamba (kullanici adlariyla), fabrika pano 1-2 panjur bildiriyor
  let rows = seedRows();
  rows = withRow(rows, 1, { name: 'Avize', type: 'light', room: 'Bizim Oda', shutter_pair_index: null, shutter_duration_sec: null });
  rows = withRow(rows, 2, { name: 'Aplik', type: 'light', room: 'Bizim Oda', shutter_pair_index: null, shutter_duration_sec: null });
  const reported = extract(fwState({ types: lights, pos: 30 }));
  const plan = planProvisional({ reported, rows });
  assert.deepEqual(plan.updates.map((u) => [u.channel_index, u.set]), [
    [1, { type: 'shutter', shutter_pair_index: 1, shutter_duration_sec: 20, current_position: 30 }],
    [2, { type: 'shutter', shutter_pair_index: 1, shutter_duration_sec: 20, current_position: 30 }],
  ]);
  assert.deepEqual(plan.ruleRelayChannels, [1, 2], 'lamba kurali motoru surmesin');
  assert.equal(plan.deferred, 4, 'iki satirin ad + oda degisimi ertelendi');
  assert.equal(plan.baseChanged, false);
  assert.equal(plan.summary.renamed, 0);
  assert.equal(plan.summary.reroomed, 0);
  assert.equal(plan.summary.retyped, 2);
});

test('D1 plan: gecici plan uygulandiktan sonra ayni bildirim yeni yazma uretmez ama erteleme surer (taban yine yazilmaz)', () => {
  const reported = extract(fwState());
  const rows = movedRows();
  const first = planProvisional({ reported, rows, confirmShrink: true });
  const after = applyPlan(rows, first).map(core);
  const second = planProvisional({ reported, rows: after, confirmShrink: true });
  assert.equal(second.changed, false);
  assert.deepEqual(second.ruleRelayChannels, []);
  assert.equal(second.deferred, 10);
  assert.equal(second.baseChanged, false);
  assert.equal(after.length, 16);
  assert.equal(at(after, 5).shutter_duration_sec, 35);
  assert.equal(at(after, 9).name, 'Bahçe Sulama');
});

test('D1 plan: gecici mod eksik kanallari ACAR (ekleme guvenlidir)', () => {
  const reported = extract(fwState());
  const rows = movedRows().filter((r) => r.channel_index !== 8);
  const plan = planProvisional({ reported, rows });
  assert.deepEqual(plan.inserts.map((i) => [i.channel_index, i.name, i.type]), [[8, 'Balkon Aydınlatma', 'light']]);
  assert.ok(plan.deferred > 0);
});

// ------------------------------------------------------------------------------
// Ek kenar durumlari (gorev maddesi 4)
// ------------------------------------------------------------------------------
test('ek (a): planLayoutSync dondurulmus (frozen) girdilerle calisir ve hicbirini degistirmez', () => {
  // runWith her cagrida bunu denetler; burada en "yazan" senaryo acikca kosulur.
  const types = ['light', 'light', 'shutter_up', 'shutter_down', 'shutter_up', 'shutter_down', 'impulse', 'light',
    'light', 'light'];
  const names = ['A', 'B', 'Oda Panjur (Yukari)', 'Oda Panjur (Asagi)', 'Kiler (Yukari)', 'Kiler (Asagi)', 'Kapi',
    'Balkon Aydinlatma', 'Depo 1', 'Depo 2'];
  const rows = seedRows(16).filter((r) => r.channel_index !== 10);
  const { plan } = run({ types, names, rows, base: baseOf(), confirmShrink: true });
  assert.equal(plan.changed, true);
  assert.ok(plan.updates.length > 0 && plan.inserts.length > 0 && plan.deletes.length > 0);
});

test('ek (a2): varsayilan parametreler - yalniz reported verilirse tum satirlar eklenir', () => {
  const reported = extract(fwState());
  const plan = L.planLayoutSync({ reported });
  assert.ok(plan && typeof plan === 'object');
  assert.equal(plan.inserts.length, 8);
  assert.deepEqual(plan.deletes, []);
  assert.equal(plan.baseChanged, true);
});

test('ek (a3): satir sirasi sonucu degistirmez', () => {
  const names = withName(6, 'Mutfak Spot', withName(5, 'Salon (Yukari)'));
  const types = FW_TYPES.slice();
  types[0] = 'light';
  types[1] = 'impulse';
  const ordered = run({ names, types, rows: seedRows(12), confirmShrink: true });
  const shuffled = run({ names, types, rows: seedRows(12).reverse(), confirmShrink: true });
  assert.deepEqual(shuffled.after.map(core), ordered.after.map(core));
  assert.deepEqual(shuffled.plan.ruleRelayChannels, ordered.plan.ruleRelayChannels);
  assert.deepEqual(shuffled.plan.ruleShutterPairs, ordered.plan.ruleShutterPairs);
});

test('ek (c): 40 role / 20 panjur cifti - tohum satirlarindan', () => {
  const types = [];
  for (let p = 1; p <= 20; p += 1) types.push('shutter_up', 'shutter_down');
  const { plan, after } = run({ types, names: fwNames(40), rows: seedRows(8), pos: 9 });
  assert.equal(after.length, 40);
  assert.equal(plan.inserts.length, 32);
  assert.deepEqual(plan.updates.map((u) => u.channel_index).sort((a, b) => a - b), [5, 6, 7, 8]);
  for (const row of after) {
    assert.equal(row.type, 'shutter');
    assert.equal(row.shutter_pair_index, pairOf(row.channel_index));
    assert.equal(row.shutter_duration_sec, 20);
  }
  assert.deepEqual(after.slice(0, 4).map((r) => r.name), seedRows(4).map((r) => r.name));
  assert.equal(at(after, 5).name, 'Panjur 3 Yukarı');
  assert.equal(at(after, 8).name, 'Panjur 4 Aşağı');
  assert.equal(at(after, 39).name, 'Panjur 20 Yukarı');
  assert.equal(at(after, 40).name, 'Panjur 20 Aşağı');
  assert.deepEqual(plan.ruleRelayChannels, [5, 6, 7, 8]);
});

test('ek (c2): 40 role / 20 cift - bos satir kumesinden 40 ekleme; 40 lamba -> 20 cift kurali', () => {
  const types = [];
  for (let p = 1; p <= 20; p += 1) types.push('shutter_up', 'shutter_down');
  const a = run({ types, names: fwNames(40), rows: [] });
  assert.equal(a.plan.inserts.length, 40);

  // Tersi: 40 panjur satiri, pano 40 lamba bildiriyor -> hepsi lamba, 20 cift kurali kapatilir
  const lights = new Array(40).fill('light');
  const b = run({ types: lights, names: fwNames(40), rows: a.after.map(core) });
  assert.equal(b.plan.updates.length, 40);
  assert.deepEqual(b.plan.ruleShutterPairs, Array.from({ length: 20 }, (_, i) => i + 1));
  for (const row of b.after) {
    assert.equal(row.type, 'light');
    assert.equal(row.shutter_pair_index, null);
    assert.equal(row.current_position, 0);
  }
});

test('ek (d): pano adinda buyuk-kucuk harf / aksan farki "varsayilan ad" sayilir -> bulut adi degismez', () => {
  const names = withName(5, 'SALON AYDINLATMA', withName(6, 'mutfak aydınlatma',
    withName(1, 'salon panjur yukarı', withName(2, 'SALON PANJUR ASAGI'))));
  const { plan, after } = run({ names });
  assert.equal(plan.changed, false);
  assert.deepEqual(after.map((r) => r.name), seedRows().map((r) => r.name));
});

test('ek (d2): varsayilan sayilan pano adi kullanicinin bulut adini da ezmez', () => {
  const rows = withRow(seedRows(), 5, { name: 'Avize' });
  const { plan, after } = run({ rows, names: withName(5, 'SALON AYDINLATMA'), base: baseOf() });
  assert.equal(plan.changed, false);
  assert.equal(at(after, 5).name, 'Avize');
});

test('ek (f): sinif degisen kanalda kullanicinin verdigi ad pano adiyla degisir (§5.3 ilk satir)', () => {
  let rows = seedRows();
  rows = withRow(rows, 5, { name: 'Avize', room: 'Bizim Oda' });
  rows = withRow(rows, 6, { name: 'Tezgah', room: 'Bizim Oda' });
  const types = FW_TYPES.slice();
  types[4] = 'shutter_up';
  types[5] = 'shutter_down';
  const { after } = run({ rows, types, names: withName(5, 'Teras Perde (Yukari)', withName(6, 'Teras Perde (Asagi)')) });
  assert.equal(at(after, 5).name, 'Teras Perde (Yukari)');
  assert.equal(at(after, 6).name, 'Teras Perde (Asagi)');
  assert.equal(at(after, 5).room, 'Teras', 'sinif degisince oda da yeniden hesaplanir (kullanici odasi dahil)');
  assert.equal(at(after, 6).room, 'Teras');
});

test('ek (f2): sinif degisen kanalda kullanicinin verdigi ad varsayilanla degisir (§5.3 ikinci satir)', () => {
  let rows = seedRows();
  rows = withRow(rows, 5, { name: 'Avize', room: 'Bizim Oda' });
  rows = withRow(rows, 6, { name: 'Tezgah', room: 'Bizim Oda' });
  rows = withRow(rows, 1, { name: 'Büyük Perde Yukarı', room: 'Bizim Oda' });
  rows = withRow(rows, 2, { name: 'Büyük Perde Aşağı', room: 'Bizim Oda' });
  const types = ['light', 'light', 'shutter_up', 'shutter_down', 'shutter_up', 'shutter_down', 'light', 'light'];
  const { after } = run({ rows, types });
  assert.equal(at(after, 5).name, 'Panjur 3 Yukarı');
  assert.equal(at(after, 6).name, 'Panjur 3 Aşağı');
  assert.equal(at(after, 1).name, 'Röle 1');
  assert.equal(at(after, 2).name, 'Röle 2');
  for (const c of [1, 2, 5, 6]) assert.equal(at(after, c).room, 'Genel');
});

test('ek: taban bu kanali icermiyorsa (D yok) kullanicinin bulut adi korunur', () => {
  // Taban 8 roleli; pano simdi 10 role bildiriyor. Kanal 9 satiri var ve kullanici ad vermis.
  const types = FW_TYPES.concat(['light', 'light']);
  const names = fwNames(10);
  names[8] = 'Depo Lamba';
  const rows = withRow(seedRows(10), 9, { name: 'Kazan Dairesi', room: 'Bodrum' });
  const { after } = run({ rows, types, names, base: baseOf() });
  assert.equal(at(after, 9).name, 'Kazan Dairesi');
  assert.equal(at(after, 9).room, 'Bodrum');
});

test('ek: panjura donen satirda konum bildirilmemisse (gecersiz pos) konum 0 yazilir (§5.2 rolede konum 0 ile ayni deger)', () => {
  const types = FW_TYPES.slice();
  types[4] = 'shutter_up';
  types[5] = 'shutter_down';
  const st = fwState({ types });
  st.shutters.find((x) => x.pair === 3).pos = 'bilinmiyor';
  const { plan } = run({ state: st });
  assert.deepEqual(plan.updates.map((u) => [u.channel_index, u.set.current_position]), [[5, 0], [6, 0]]);
});

test('ek: uzun ve kirli pano adi satira temizlenmis ve en cok 100 karakter olarak yazilir', () => {
  const dirty = 'Mutfak' + ZWSP + ' ' + 'ş'.repeat(150);
  const { after } = run({ names: withName(6, dirty) });
  assert.equal(at(after, 6).name, ('Mutfak ' + 'ş'.repeat(150)).slice(0, 100));
  assert.equal(at(after, 6).name.length, 100);
});

// ------------------------------------------------------------------------------
// Ozellik testi: sabit tohumlu LCG ile 200 rastgele yerlesim
// ------------------------------------------------------------------------------
function makeLcg(seed) {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
}

function makeGen(seed) {
  const rnd = makeLcg(seed);
  const int = (lo, hi) => lo + Math.floor(rnd() * (hi - lo + 1));
  const pick = (list) => list[int(0, list.length - 1)];
  const chance = (p) => rnd() < p;

  const boardName = (channel) => {
    const fw = fwNames(40)[channel - 1];
    return pick([
      fw, fw, fw,
      fw.toUpperCase(),
      '',
      'Mutfak Spot',
      'Yatak Odası Lamba',
      'Salon (Yukari)',
      'Salon (Asagi)',
      'Röle ' + channel,
      'Panjur ' + pairOf(channel) + ' Yukarı',
      'Panjur ' + pairOf(channel) + ' Aşağı',
      'Tezgah ' + channel,
      'Garaj Kapısı',
      'Spot 3',
      'Ek Modül Röle 3',
      'Salon Aydınlatma',
      'Çok Uzun Ad ' + 'x'.repeat(140),
      ' Hol' + NUL + '  Aplik' + RLO,
    ]);
  };
  const cloudName = (channel) => {
    const s = seedOf(channel);
    return pick([s.name, s.name, s.name, boardName(channel), 'Avize ' + channel, 'Röle ' + channel,
      'Panjur ' + pairOf(channel) + ' Yukarı', 'Tezgah']);
  };

  const layout = () => {
    const n = pick([int(1, 40), int(1, 40), 8, 8, 16, 40]);
    const types = [];
    for (let p = 1; 2 * p - 1 <= n; p += 1) {
      if (2 * p <= n && chance(0.4)) {
        types.push('shutter_up', 'shutter_down');
      } else {
        types.push(pick(['light', 'light', 'impulse']));
        if (2 * p <= n) types.push(pick(['light', 'light', 'impulse']));
      }
    }
    const names = types.map((_, i) => boardName(i + 1));
    const st = fwState({ types, names, pos: int(0, 100) });
    for (const r of st.relays) r.state = chance(0.5);
    return st;
  };

  const rows = () => {
    const count = pick([0, 8, 8, 16, int(0, 40), int(0, 40)]);
    const out = [];
    for (let c = 1; c <= count; c += 1) {
      if (chance(0.08)) continue; // eksik satir
      const s = seedOf(c);
      const type = chance(0.6) ? s.type : pick(['light', 'plug', 'impulse', 'shutter']);
      const isShutter = type === 'shutter';
      out.push({
        id: 'ep-' + c,
        channel_index: c,
        name: cloudName(c),
        type,
        room: chance(0.5) ? s.room : pick(['', null, 'Genel', 'Salon', 'Teras', 'Mutfak', 'Yatak Odası', 'Bizim Oda']),
        shutter_pair_index: isShutter ? pick([pairOf(c), pairOf(c), pairOf(c), null, int(1, 20)]) : null,
        shutter_duration_sec: isShutter ? int(5, 120) : null,
      });
    }
    return out;
  };

  return { rnd, int, pick, chance, layout, rows };
}

test('ek (b): 200 rastgele yerlesim - girdiler degismez, deterministik, ikinci plan bos, kurallar tutarli', () => {
  const gen = makeGen(20261003);
  let withChange = 0;
  let withShrink = 0;
  for (let i = 0; i < 200; i += 1) {
    const reported = extract(gen.layout());
    const kind = gen.int(0, 3);
    let base = null;
    if (kind === 1) base = structuredClone(L.serializeBase(reported));
    else if (kind >= 2) base = structuredClone(L.serializeBase(extract(gen.layout())));
    const rows = gen.rows();
    const confirmShrink = gen.chance(0.5);
    let result;
    try {
      result = runWith({ reported, base, rows, confirmShrink });
    } catch (err) {
      err.message = 'yerlesim #' + i + ' (roller ' + reported.count + ', satir ' + rows.length + ', taban turu ' + kind +
        ', onay ' + confirmShrink + '): ' + err.message;
      throw err;
    }
    if (result.plan.changed) withChange += 1;
    if (result.plan.pendingShrink || result.plan.deletes.length > 0) withShrink += 1;
  }
  // Uretecin gercekten ilginc durumlar urettigini dogrula (bos gecen bir ozellik testi olmasin).
  assert.ok(withChange >= 100, 'degisiklik ureten yerlesim sayisi: ' + withChange);
  assert.ok(withShrink >= 20, 'kuculme iceren yerlesim sayisi: ' + withShrink);
});

test('ek (b2): ayni bildirim art arda 3 kez uygulanir -> yalniz ilki yazar', () => {
  const types = ['light', 'impulse', 'shutter_up', 'shutter_down', 'shutter_up', 'shutter_down', 'light', 'light',
    'light', 'light'];
  const names = ['Giriş Lamba', '', 'Oda Panjur (Yukari)', 'Oda Panjur (Asagi)', 'Kiler (Yukari)', 'Kiler (Asagi)',
    'Koridor Aydinlatma', 'Fener', 'Ek Modül Röle 1', 'Depo'];
  const reported = extract(fwState({ types, names, pos: 80 }));
  let rows = seedRows(12);
  let base = null;
  const changes = [];
  for (let round = 0; round < 3; round += 1) {
    const plan = L.planLayoutSync({ reported, base, rows, confirmShrink: true });
    changes.push([plan.changed, plan.baseChanged]);
    rows = applyPlan(rows, plan).map(core);
    base = L.parseBase(JSON.stringify(plan.newBase));
  }
  assert.deepEqual(changes, [[true, true], [false, false], [false, false]]);
});

// ------------------------------------------------------------------------------
// Yardimci fonksiyonlar (plan Task 1 Step 4)
// ------------------------------------------------------------------------------
test('foldName: yon eki / parantez / aksan farki ayni anahtara duser', () => {
  assert.equal(L.foldName('Salon Panjur (Yukari)'), L.foldName('Salon Panjur Yukarı'));
  assert.equal(L.foldName('Salon Panjur (Asagi)'), L.foldName('Salon Panjur Aşağı'));
  assert.equal(L.foldName('Salon Panjur (Yukari)'), 'salon panjur yukari');
  assert.notEqual(L.foldName('Salon Panjur (Yukari)'), L.foldName('Salon Panjur (Asagi)'));
});

test('foldName: Turkce buyuk/kucuk harf ve aksan katlanir', () => {
  assert.equal(L.foldName('IŞIK'), 'isik');
  assert.equal(L.foldName('ışık'), 'isik');
  assert.equal(L.foldName('İÇ'), 'ic');
  assert.equal(L.foldName('ÇĞÖŞÜ çğöşü'), 'cgosu cgosu');
  assert.equal(L.foldName('SALON AYDINLATMA'), L.foldName('salon aydınlatma'));
  assert.equal(L.foldName('Salon Aydinlatma'), L.foldName('Salon Aydınlatma'));
});

test('foldName: sapkali / aksanli harfler tek harfe katlanir (sozcuk bolunmez)', () => {
  assert.equal(L.foldName('Kâğıt Dükkânı'), 'kagit dukkani');
  assert.equal(L.foldName('Café Îmâ'), 'cafe ima');
});

test('foldName: panonun fabrika adi ile bulut sablon adi her kanalda (1..40) ayni anahtara duser', () => {
  // "Varsayilan pano + tohum satirlari -> degisiklik yok" kuralinin dayanagi (§5.3: fabrika adlari buluta tasinmaz).
  for (let c = 1; c <= 40; c += 1) {
    const legacyCloud = c <= 8 ? LEGACY_SEED[c].name : seedOf(c).name;
    assert.equal(L.foldName(L.legacyFirmwareDefaultName(c)), L.foldName(legacyCloud), 'eski surum, kanal ' + c);
    assert.equal(L.foldName(L.firmwareDefaultName(c)), L.foldName(seedOf(c).name), 'v1.3.2+, kanal ' + c);
    assert.equal(L.isBoardDefaultName(c, L.firmwareDefaultName(c)), true, 'v1.3.2+ fabrika adi varsayilan, kanal ' + c);
  }
});

test('foldName: noktalama ve bosluklar tek bosluga iner; bos / dizge olmayan girdi bos doner', () => {
  assert.equal(L.foldName('  Mutfak --  Spot!  '), 'mutfak spot');
  assert.equal(L.foldName('Röle 6'), 'role 6');
  assert.equal(L.foldName(''), '');
  assert.equal(L.foldName(null), '');
  assert.equal(L.foldName(undefined), '');
});

test('sanitizeReportedName: kontrol ve gorunmez bicim karakterleri atilir, bosluklar birlesir', () => {
  assert.equal(L.sanitizeReportedName('  Mutfak' + NUL + '   ' + RLO + ' Spot  '), 'Mutfak Spot');
  assert.equal(L.sanitizeReportedName(BOM + 'Hol' + ZWSP + ' Aplik'), 'Hol Aplik');
  assert.equal(L.sanitizeReportedName('Hol' + TAB + 'Aplik' + LF + 'Sol'), 'Hol Aplik Sol');
  assert.equal(L.sanitizeReportedName('Çalışma Odası Işığı'), 'Çalışma Odası Işığı');
  assert.equal(L.sanitizeReportedName(NUL + RLO + '   '), '');
});

test('sanitizeReportedName: en cok 100 karakter; sonda bosluk birakmaz', () => {
  assert.equal(L.sanitizeReportedName('x'.repeat(150)), 'x'.repeat(100));
  assert.equal(L.sanitizeReportedName('x'.repeat(100)), 'x'.repeat(100));
  const cut = L.sanitizeReportedName('a'.repeat(99) + ' bbb');
  assert.ok(cut.length <= 100);
  assert.equal(cut, cut.trim());
  assert.ok(cut.startsWith('a'.repeat(99)));
});

test('sanitizeReportedName: 100 siniri bir karakteri (vekil cifti) ortadan bolmez', () => {
  const emoji = String.fromCodePoint(0x1f4a1);
  const out = L.sanitizeReportedName('a'.repeat(99) + emoji + 'b');
  assert.equal(out, 'a'.repeat(99) + emoji, '100 KARAKTER (kod noktasi): 99 harf + 1 simge');
  assert.equal(cpLen(out), 100);
  assert.equal(out.isWellFormed(), true, 'yarim vekil (lone surrogate) kalmamali');
  const many = L.sanitizeReportedName(emoji.repeat(150));
  assert.equal(cpLen(many), 100);
  assert.equal(many.isWellFormed(), true);
});

// D9 (2026-10-04): Unicode kategorisine gore temizlik (Cc, Cf, Zl, Zp, Cs) + Hangul dolgulari. Kaynakta kacis
// YAZILMAZ: kod noktasi sayilari ve String.fromCodePoint / fromCharCode kullanilir.
test('D9 sanitizeReportedName: bidi yalitimlari, ALM, yumusak tire, Mongol ayirici, ilistirme, etiket, Hangul dolgu, Zl/Zp atilir', () => {
  const cps = [0x2066, 0x2067, 0x2068, 0x2069, 0x061c, 0x00ad, 0x180e, 0xfff9, 0xfffa, 0xfffb, 0xe0001, 0xe0041, 0xe007f,
    0x115f, 0x1160, 0x3164, 0xffa0, 0x2028, 0x2029, 0x202a, 0x202e, 0x200b, 0x200d, 0x2060, 0x206f, 0xfeff, 0x0085, 0x0000];
  for (const cp of cps) {
    const out = L.sanitizeReportedName('Salon' + String.fromCodePoint(cp) + 'Lamba');
    assert.equal(out, 'Salon Lamba', 'U+' + cp.toString(16));
  }
  // yalniz gorunmez karakterlerden olusan ad bos olur (= varsayilan)
  assert.equal(L.sanitizeReportedName(String.fromCodePoint(0x3164, 0x2066, 0x00ad)), '');
  // Turkce harfler, emoji (gecerli vekil cifti) ve Kiril korunur
  assert.equal(L.sanitizeReportedName('Çalışma ' + BULB + ' Кухня'), 'Çalışma ' + BULB + ' Кухня');
});

test('D9 sanitizeReportedName: tek (eslesmemis) vekil bosluga cevrilir; sonuc iyi bicimli UTF-16', () => {
  const lone = [0xd800, 0xdbff, 0xdc00, 0xdfff];
  for (const unit of lone) {
    const raw = 'Mutfak ' + String.fromCharCode(unit) + ' Spot';
    assert.equal(raw.isWellFormed(), false, 'on kosul: girdi bozuk UTF-16');
    const out = L.sanitizeReportedName(raw);
    assert.equal(out, 'Mutfak Spot', 'U+' + unit.toString(16));
    assert.equal(out.isWellFormed(), true);
  }
  // ters sirali vekiller (dusuk + yuksek) de cift sayilmaz
  const reversed = L.sanitizeReportedName('A' + String.fromCharCode(0xdc00, 0xd800) + 'B');
  assert.equal(reversed.isWellFormed(), true);
  assert.equal(reversed, 'A B');
  // extract yolu: tek vekilli ad iyi bicimli ada doner (JSONB taban yazimi 22P02 vermez)
  const rep = extract(fwState({ names: withName(6, 'Mutfak ' + String.fromCharCode(0xd800) + ' Spot') }));
  assert.equal(rep.relays[5].name, 'Mutfak Spot');
  assert.equal(rep.relays[5].name.isWellFormed(), true);
  assert.equal(JSON.stringify(L.serializeBase(rep)).includes(String.fromCharCode(92) + 'ud800'), false);
});

test('sanitizeReportedName: dizge olmayan girdi -> bos dizge', () => {
  for (const bad of [undefined, null, 7, true, {}, ['Ad']]) assert.equal(L.sanitizeReportedName(bad), '');
});

test('deriveRoom: adin basindaki bilinen oda adi', () => {
  assert.equal(L.deriveRoom('Yatak Odası Panjur (Yukari)'), 'Yatak Odası');
  assert.equal(L.deriveRoom('Oda Panjur Aşağı'), 'Oda');
  assert.equal(L.deriveRoom('Odak Lamba'), null);
  assert.equal(L.deriveRoom(''), null);
  assert.equal(L.deriveRoom('Spot 3'), null);
  assert.equal(L.deriveRoom('Salon (Yukari)'), 'Salon');
  assert.equal(L.deriveRoom('Mutfak Spot'), 'Mutfak');
});

test('deriveRoom: harf buyuklugu / aksan duyarsiz; yalniz BASTAKI tam sozcuk', () => {
  assert.equal(L.deriveRoom('yatak odasi lamba'), 'Yatak Odası');
  assert.equal(L.deriveRoom('SALON AVIZE'), 'Salon');
  assert.equal(L.deriveRoom('Çocuk Odası Gece Lambası'), 'Çocuk Odası');
  assert.equal(L.deriveRoom('Salon'), 'Salon');
  assert.equal(L.deriveRoom('Kilerci Lamba'), null);
  assert.equal(L.deriveRoom('Büyük Salon Lamba'), null);
  assert.equal(L.deriveRoom(null), null);
  assert.equal(L.deriveRoom(undefined), null);
});

test('seedDefaults(1..9): tohum sablonu (tasarim §1)', () => {
  for (let c = 1; c <= 8; c += 1) assert.deepEqual({ ...L.seedDefaults(c) }, SEED_EXPECTED[c], 'kanal ' + c);
  assert.deepEqual({ ...L.seedDefaults(9) },
    { name: 'Ek Modül Röle 1', type: 'light', room: 'Genel', pair: null, durationSec: null });
  assert.deepEqual({ ...L.seedDefaults(40) },
    { name: 'Ek Modül Röle 32', type: 'light', room: 'Genel', pair: null, durationSec: null });
});

test('eski bulut tohumu (2026-10-09 oncesi evler): ad ve oda hala otomatik sayilir, pano yerlesimi ustune yazabilir', () => {
  const legacy = [null, ['Salon Panjur Yukarı', 'Salon'], ['Salon Panjur Aşağı', 'Salon'], ['Oda Panjur Yukarı', 'Oda'],
    ['Oda Panjur Aşağı', 'Oda'], ['Salon Aydınlatma', 'Salon'], ['Mutfak Aydınlatma', 'Mutfak'],
    ['Koridor Aydınlatma', 'Koridor'], ['Balkon Aydınlatma', 'Balkon']];
  for (let c = 1; c <= 8; c += 1) {
    const [name, room] = legacy[c];
    assert.equal(L.isCloudAutoName(c, name), true, 'kanal ' + c + ' eski tohum adi otomatik');
    assert.equal(L.isBoardDefaultName(c, name), true, 'kanal ' + c + ' eski tohum adi panoda da varsayilan');
    assert.equal(L.isAutoRoom(c, room, 'Kullanici Adi'), true, 'kanal ' + c + ' eski tohum odasi otomatik');
  }
  // Baska kanalin eski tohum adi otomatik DEGIL (kullanici adi gibi davranir).
  assert.equal(L.isCloudAutoName(5, 'Salon Panjur Yukarı'), false);
});

test('firmwareDefaultName: panonun fabrika adlari', () => {
  for (let c = 1; c <= 8; c += 1) assert.equal(L.firmwareDefaultName(c), 'Röle ' + c);
  for (let c = 1; c <= 8; c += 1) assert.equal(L.legacyFirmwareDefaultName(c), FW_NAMES[c - 1], 'v1.3.1- kanal ' + c);
  assert.equal(L.legacyFirmwareDefaultName(9), 'Ek Modül Röle 1');
  assert.equal(L.firmwareDefaultName(9), 'Ek Modül Röle 1');
  assert.equal(L.firmwareDefaultName(16), 'Ek Modül Röle 8');
});

test('serializeBase: §5.7 bicimi {"v":1,"relays":[{id,type,name}]} (state ve konum YOK)', () => {
  const rep = extract(fwState({ names: withName(6, 'Mutfak Spot'), pos: 33 }));
  const base = L.serializeBase(rep);
  assert.ok(base && typeof base === 'object');
  assert.deepEqual(Object.keys(base).sort(), ['relays', 'v']);
  assert.equal(base.v, 1);
  assert.equal(base.relays.length, 8);
  assert.deepEqual(base.relays[0], { id: 1, type: 'shutter_up', name: 'Salon Panjur (Yukari)' });
  assert.deepEqual(base.relays[5], { id: 6, type: 'light', name: 'Mutfak Spot' });
  assert.equal(JSON.stringify(base).includes('state'), false);
});

test('parseBase: nesne ve dizge ayni sonucu verir', () => {
  const base = L.serializeBase(extract(fwState()));
  assert.deepEqual(L.parseBase(structuredClone(base)), base);
  assert.deepEqual(L.parseBase(JSON.stringify(base)), base);
});

test('parseBase: bozuk girdi -> null (= bu panoyla hic esitlenmedi)', () => {
  const good = structuredClone(L.serializeBase(extract(fwState())));
  assert.ok(L.parseBase(good), 'on kosul: gecerli taban kabul edilmeli');
  const broken = (mutate) => {
    const b = structuredClone(good);
    mutate(b);
    return b;
  };
  const bads = [
    null, undefined, '', 'bozuk json {', '[]', 'null', 7, true, [], {},
    { v: 1 },
    { v: 1, relays: 'x' },
    broken((b) => { b.v = 99; }),
    broken((b) => { delete b.v; }),
    broken((b) => { b.relays[3] = null; }),
    broken((b) => { b.relays[3].type = 7; }),
    broken((b) => { b.relays[3].id = 0; }),
    broken((b) => { b.relays[3].id = 41; }),
    broken((b) => { b.relays[3].id = 2.5; }),
    broken((b) => { delete b.relays[3].type; }),
    broken((b) => { b.relays[3].id = 'dort'; }),
    broken((b) => { delete b.relays[3].id; }),
    broken((b) => { b.relays[3].name = 7; }),
  ];
  for (const bad of bads) assert.equal(L.parseBase(bad), null, JSON.stringify(bad));
});

test('ek (h): parseBase(serializeBase(x)) gidis-donus (nesne ve JSON dizgesi; 1, 8 ve 40 role)', () => {
  const gen = makeGen(77);
  const states = [fwState(), fwState({ types: ['impulse'], names: ['Kapı'] })];
  for (let i = 0; i < 25; i += 1) states.push(gen.layout());
  for (const st of states) {
    const rep = extract(st);
    const base = L.serializeBase(rep);
    const snapshot = structuredClone(base);
    assert.deepEqual(L.parseBase(base), snapshot);
    assert.deepEqual(L.parseBase(JSON.stringify(base)), snapshot);
    assert.deepEqual(L.serializeBase(rep), snapshot, 'serializeBase deterministik');
    assert.deepEqual(base, snapshot, 'parseBase girdisini degistirmez');
    // gidis-donusten gecen taban, plan icin ozgun tabanla esdegerdir
    const plan = L.planLayoutSync({ reported: rep, base: L.parseBase(JSON.stringify(base)), rows: [] });
    assert.equal(plan.baseChanged, false);
  }
});

test('ad siniflandirma yardimcilari: pano adi "ozel" mi, bulut adi "otomatik" mi (§5.3 tanimlari)', () => {
  // pano adi ozel DEGIL: bos / fabrika adi / sablon adi (harf-aksan-noktalama duyarsiz)
  for (const name of ['', 'Mutfak Aydinlatma', 'Mutfak Aydınlatma', 'MUTFAK AYDINLATMA', 'mutfak  aydinlatma']) {
    assert.equal(L.isBoardDefaultName(6, name), true, JSON.stringify(name));
  }
  assert.equal(L.isBoardDefaultName(1, 'Salon Panjur Yukarı'), true);
  assert.equal(L.isBoardDefaultName(1, 'Salon Panjur (Yukari)'), true);
  assert.equal(L.isBoardDefaultName(9, 'Ek Modül Röle 1'), true);
  for (const name of ['Mutfak Spot', 'Tezgah', 'Röle 1 Aydınlatma']) {
    assert.equal(L.isBoardDefaultName(6, name), false, name);
  }

  // bulut adi otomatik: sablon adi, fabrika adi, "Röle N", "Panjur P Yukarı|Aşağı"
  for (const name of ['Mutfak Aydınlatma', 'Mutfak Aydinlatma', 'Röle 6', 'röle 6', 'Panjur 3 Aşağı']) {
    assert.equal(L.isCloudAutoName(6, name), true, name);
  }
  assert.equal(L.isCloudAutoName(5, 'Panjur 3 Yukarı'), true);
  assert.equal(L.isCloudAutoName(9, 'Ek Modül Röle 1'), true);
  for (const name of ['Tezgah', 'Mutfak Spot', 'Avize 6']) assert.equal(L.isCloudAutoName(6, name), false, name);
});

// D8 (2026-10-04): katlama Unicode harf/rakami korur; "bos ad" yalniz temizlenmis HAM ad bossa.
const BULB = String.fromCodePoint(0x1f4a1);
const HOUSE = String.fromCodePoint(0x1f3e0);
const ARABIC_KITCHEN = String.fromCodePoint(0x645, 0x637, 0x628, 0x62e);

test('D8 foldName: Kiril / Arap / CJK harfleri korunur; Turkce katlama ve aksan atma aynen surer', () => {
  assert.equal(L.foldName('Кухня Свет'), 'кухня свет');
  assert.equal(L.foldName('灯 2'), '灯 2');
  assert.equal(L.foldName(ARABIC_KITCHEN), ARABIC_KITCHEN);
  assert.notEqual(L.foldName('Кухня'), L.foldName('Спальня'), 'farkli Kiril adlar farkli anahtar');
  assert.equal(L.foldName('ÇĞÖŞÜ İı'), 'cgosu ii');
  assert.equal(L.foldName('Café Îmâ'), 'cafe ima');
  assert.equal(L.foldName(BULB + ' --- ' + BULB), '', 'yalniz simge/noktalama katlamada bos kalir');
});

test('D8 ad siniflandirma: ham ad doluysa ama katlama bossa (emoji/noktalama) ad OZELDIR; bos yalniz ham ad bossa', () => {
  for (const name of [BULB, '---', BULB + '!!', 'Кухня свет', ARABIC_KITCHEN, '灯']) {
    assert.equal(L.isBoardDefaultName(6, name), false, 'pano: ' + name);
    assert.equal(L.isCloudAutoName(6, name), false, 'bulut: ' + name);
  }
  for (const empty of ['', '   ', null, undefined, NUL + RLO]) {
    assert.equal(L.isBoardDefaultName(6, empty), true, 'bos pano adi: ' + JSON.stringify(empty));
    assert.equal(L.isCloudAutoName(6, empty), true, 'bos bulut adi: ' + JSON.stringify(empty));
  }
  // oda da ayni kural: yalniz simgeden olusan kullanici odasi otomatik sayilmaz
  assert.equal(L.isAutoRoom(6, HOUSE, 'Tezgah'), false);
  assert.equal(L.isAutoRoom(6, 'Кухня', 'Tezgah'), false);
  assert.equal(L.isAutoRoom(6, '', 'Tezgah'), true);
  assert.equal(L.isAutoRoom(6, null, 'Tezgah'), true);
});

test('D8 plan: kullanicinin emoji / Kiril bulut adi pano tarafi degismeden EZILMEZ; panonun Kiril ozel adi ALINIR', () => {
  const names = withName(6, 'Mutfak Spot');
  for (const userName of [BULB, 'Кухня', '---']) {
    const rows = withRow(seedRows(), 6, { name: userName });
    const { plan, after } = run({ rows, names, base: baseOf({ names }) });
    assert.equal(plan.changed, false, JSON.stringify(userName));
    assert.equal(at(after, 6).name, userName);
  }
  // pano Kiril ad verdi, bulut sablon adinda -> pano adi alinir (onceden "varsayilan" sayilip atiliyordu)
  const cyr = run({ names: withName(6, 'Кухня свет') });
  assert.equal(at(cyr.after, 6).name, 'Кухня свет');
  assert.equal(at(cyr.after, 6).room, 'Genel', 'sablon odasi otomatik; yeni addan oda turetilemez -> Genel');
  // pano yalniz simgeden olusan ad verdi -> ozel ad, alinir
  const emo = run({ names: withName(6, BULB) });
  assert.equal(at(emo.after, 6).name, BULB);
});

test('sinif ve varsayilan ad yardimcilari', () => {
  assert.equal(L.classOf('shutter'), 'shutter');
  assert.equal(L.classOf('shutter_up'), 'shutter');
  assert.equal(L.classOf('shutter_down'), 'shutter');
  for (const t of ['light', 'impulse', 'plug']) assert.equal(L.classOf(t), 'relay', t);

  assert.equal(L.genericName(5, 'shutter_up'), 'Panjur 3 Yukarı');
  assert.equal(L.genericName(6, 'shutter_down'), 'Panjur 3 Aşağı');
  assert.equal(L.genericName(2, 'light'), 'Röle 2');
  assert.equal(L.genericName(2, 'impulse'), 'Röle 2');

  // sinif sablonla ayniysa sablon adi, degilse tarafsiz ad
  // Guncel tohum (sabit rol yok): 1-8 "Röle N" lamba; panjur bildiren kanal genel panjur adi alir.
  assert.equal(L.defaultNameFor(1, 'shutter_up'), 'Panjur 1 Yukarı');
  assert.equal(L.defaultNameFor(1, 'light'), 'Röle 1');
  assert.equal(L.defaultNameFor(6, 'light'), 'Röle 6');
  assert.equal(L.defaultNameFor(6, 'impulse'), 'Röle 6');
  // Eski surum pano kendi eski fabrika adini bildiriyorsa eski tohum adi korunur (mevcut evlerde ad degismez).
  assert.equal(L.defaultNameFor(1, 'shutter_up', 'Salon Panjur (Yukari)'), 'Salon Panjur Yukarı');
  assert.equal(L.defaultNameFor(6, 'light', 'Mutfak Aydinlatma'), 'Mutfak Aydınlatma');
  assert.equal(L.defaultNameFor(6, 'light', 'Röle 6'), 'Röle 6');
  assert.equal(L.defaultNameFor(1, 'light', 'Salon Panjur (Yukari)'), 'Röle 1', 'sinif uymuyorsa eski ad kullanilmaz');
  assert.equal(L.defaultNameFor(6, 'shutter_down'), 'Panjur 3 Aşağı');
  assert.equal(L.defaultNameFor(9, 'light'), 'Ek Modül Röle 1');
  assert.equal(L.defaultNameFor(9, 'shutter_up'), 'Panjur 5 Yukarı');
});

test('sameBase: ayni taban true, farkli ad / tip / uzunluk / null false', () => {
  const a = L.serializeBase(extract(fwState()));
  const b = L.parseBase(JSON.stringify(a));
  assert.equal(L.sameBase(a, b), true);
  assert.equal(L.sameBase(a, L.serializeBase(extract(fwState({ names: withName(6, 'Mutfak Spot') })))), false);
  const types = FW_TYPES.slice();
  types[7] = 'impulse';
  assert.equal(L.sameBase(a, L.serializeBase(extract(fwState({ types })))), false);
  const longer = L.serializeBase(extract(fwState({ types: FW_TYPES.concat(['light']), names: fwNames(9) })));
  assert.equal(L.sameBase(a, longer), false);
  assert.equal(L.sameBase(null, a), false);
  assert.equal(L.sameBase(a, null), false);
});

// ------------------------------------------------------------------------------
// Tohum / fabrika / oda tablolarinin kaynaklariyla tutarliligi (plan Task 1 Step 5)
// ------------------------------------------------------------------------------
test('tohum tutarliligi: seedDefaults, device_service.js SEED_ENDPOINTS_SQL ile birebir ayni', () => {
  const file = path.join(__dirname, '..', '..', 'src', 'services', 'device_service.js');
  const src = fs.readFileSync(file, 'utf8');
  const start = src.indexOf('const SEED_ENDPOINTS_SQL = `');
  assert.ok(start >= 0, 'SEED_ENDPOINTS_SQL bulunamadi');
  const end = src.indexOf('`;', start);
  assert.ok(end > start);
  const sql = src.slice(start, end);

  // Sahip karari (2026-10-09): tohumda sabit rol yok -> panjur yok, hepsi lamba, oda Genel.
  assert.ok(sql.includes("CASE WHEN g.n <= 8 THEN 'Röle ' || g.n ELSE 'Ek Modül Röle ' || (g.n - 8) END"), 'ad kurali degismis');
  assert.ok(/'light',\s*'Genel',\s*NULL::int,\s*NULL::int\s/.test(sql), 'tip/oda/cift/sure kurali degismis');
  assert.ok(!sql.includes("'shutter'"), 'tohumda panjur olmamali');
  assert.equal(seedOf(9).name, 'Ek Modül Röle ' + (9 - 8));
  for (let c = 1; c <= 40; c += 1) {
    const expected = {
      name: c <= 8 ? 'Röle ' + c : 'Ek Modül Röle ' + (c - 8),
      type: 'light',
      room: 'Genel',
      pair: null,
      durationSec: null,
    };
    assert.deepEqual({ ...L.seedDefaults(c) }, expected, 'kanal ' + c);
  }
});

test('fabrika adi tutarliligi: firmwareDefaultName(1..8) = "Röle N", pano SystemConfig.h applyFactoryRelayDefaults ile ayni', (t) => {
  const dir = path.join(__dirname, '..', '..', '..', 'ev_otomasyon_servis_yazilimi', 'waveshare_s3_demo', 'src');
  const sys = path.join(dir, 'SystemConfig.h');
  const cfgMgr = path.join(dir, 'ConfigManager.cpp');
  if (!fs.existsSync(sys) || !fs.existsSync(cfgMgr)) {
    t.skip('pano kaynagi bu agacta yok (yalniz server/ cikarilmis)');
    return;
  }
  // Sahip karari (2026-10-09): sabit rol yok. Pano adlari onek + kanal numarasi; tipler hepsi RELAY_TYPE_LIGHT.
  const src = fs.readFileSync(sys, 'utf8');
  assert.ok(src.includes('numberedName(r.name, "Röle ", (unsigned)(i + 1))'), '1-8 fabrika adi kurali degismis');
  assert.ok(src.includes('numberedName(r.name, "Ek Modül Röle ", (unsigned)(i - 7))'), '9+ fabrika adi kurali degismis');
  assert.ok(/applyFactoryRelayDefaults[\s\S]*?r\.type = RELAY_TYPE_LIGHT;/.test(src), 'fabrika tipi lamba degil');
  assert.ok(fs.readFileSync(cfgMgr, 'utf8').includes('applyFactoryRelayDefaults(config);'), 'ConfigManager fabrika tablosunu kullanmiyor');
  for (let c = 1; c <= 8; c += 1) assert.equal(L.firmwareDefaultName(c), 'Röle ' + c);
  assert.equal(L.firmwareDefaultName(9), 'Ek Modül Röle 1');
});

test('oda tutarliligi: deriveRoom, Flutter labels.dart _knownRooms kumesini (+ "Oda") tanir', (t) => {
  const file = path.join(__dirname, '..', '..', '..', 'lib', 'ui', 'dashboard', 'labels.dart');
  if (!fs.existsSync(file)) {
    t.skip('Flutter kaynagi bu agacta yok (yalniz server/ cikarilmis)');
    return;
  }
  const src = fs.readFileSync(file, 'utf8');
  const start = src.indexOf('_knownRooms = <String, String>{');
  assert.ok(start >= 0, '_knownRooms bulunamadi');
  const block = src.slice(start, src.indexOf('};', start));
  const entries = Array.from(block.matchAll(/'([^']+)':\s*'([^']+)'/g)).map((m) => [m[1], m[2]]);
  assert.ok(entries.length >= 20, '_knownRooms ayristirilamadi');
  for (const [key, label] of entries) {
    if (key === 'genel') continue; // "Genel" zaten varsayilan odadir
    assert.equal(L.deriveRoom(label + ' Lamba'), label, label);
    assert.equal(L.deriveRoom(key + ' lamba'), label, key);
  }
  assert.equal(L.deriveRoom('Oda Lamba'), 'Oda');
});
