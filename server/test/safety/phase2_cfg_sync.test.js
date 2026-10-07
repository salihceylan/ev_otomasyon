'use strict';

// Faz 2 / WP-C2 (F2.D.1-D.3): buluttan yapilandirma yazimi - REST yolu ve cevrimdisi pano kuyrugu (services/safety_cfg_sync.js).
// Sahte veritabani device_configs (rev, crc, body, pending) ve devices (caps, safety_state, is_online) satirlarini tutar.

const test = require('node:test');
const assert = require('node:assert/strict');

const { SafetyCfgSync, SQL, markPending, _resetEmptyCache } = require('../../src/services/safety_cfg_sync');

const HOME = '11111111-1111-4111-8111-111111111111';
const DEV = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const UID = 'AHBU-S3-1A2B3C';
const TOPIC = 'h_topic';
const OWNER = { userId: 'u-owner', access: 'owner', ip: '203.0.113.7' };
const STAFF = { userId: 'u-staff', access: 'service_user', ip: '203.0.113.8' };
const T0 = Date.parse('2026-10-07T10:00:00.000Z');

const COPY = {
  policy: { on: true, dry_hold_ms: 10000 },
  zones: [{ id: 1, name: 'Ev' }],
  lights: [],
  sensors: [{ id: 'd3', kind: 'water', zone: 1, active_open: 0, flags: 1, confirm_ms: 1000, name: 'Evye' }],
  actuators: [{ id: 'a1', relay: 5, kind: 'valve', close_mode: 'energize', medium: 'water', zones: [1], fb_di: 0, fb_closed_active: 1, fb_timeout_s: 60, run_limit_s: 0, exproof: false, name: 'Ana vana' }],
};

function world({ online = true, stateRev = 7, copyRev = 7, copy = true, pending = null, caps = ['safety', 'actuator', 'event', 'cfg'], members = { 'u-owner': true, 'u-staff': true } } = {}) {
  const w = {
    now: T0,
    device: { caps, is_online: online, safety_state: stateRev === null ? { mode: 'normal' } : { mode: 'normal', cfg: { rev: stateRev, crc: '0000000a' } } },
    cfg: copy ? { rev: copyRev, crc: '0000000a', body: JSON.parse(JSON.stringify(COPY)), pending } : null,
    audits: [],
    queries: [],
    members,
  };
  const run = async (text, params) => {
    w.queries.push({ text, params });
    if (text === SQL.lock || text === SQL.peek) return { rows: w.cfg ? [JSON.parse(JSON.stringify(w.cfg))] : [] };
    if (text === SQL.device) return { rows: [JSON.parse(JSON.stringify(w.device))] };
    if (text === SQL.setPending) {
      if (w.cfg) w.cfg.pending = params[1] === null ? null : JSON.parse(params[1]);
      return { rows: [], rowCount: w.cfg ? 1 : 0 };
    }
    if (text === SQL.view) {
      return { rows: [{ safety_state: w.device.safety_state, copy_rev: w.cfg ? w.cfg.rev : null, pending: w.cfg ? w.cfg.pending : null }] };
    }
    if (text === SQL.access) {
      const id = params[0];
      return { rows: id in w.members ? [{ id, is_active: true, account_status: null, global_role: 'user', member: w.members[id] }] : [] };
    }
    if (text === SQL.audit) {
      w.audits.push({ event: params[0], device_uuid: params[1], home_id: params[2], actor_user_id: params[3], actor_role: params[4], ip: params[5], details: JSON.parse(params[6]) });
      return { rows: [], rowCount: 1 };
    }
    throw new Error(`beklenmeyen sorgu: ${text.slice(0, 60)}`);
  };
  w.db = { query: run, withTransaction: async (fn) => fn({ query: run }) };
  return w;
}

function bridgeStub({ outcome = { ok: true, cfg: { rev: 8, crc: '0000000b' } }, connected = true, publishError = null } = {}) {
  const b = {
    order: [],
    sys: [],
    waits: [],
    cancelled: [],
    cfgGets: [],
    pushes: [],
    isConnected: () => connected,
    expectOutcome(topicId, id, ms, opts) {
      b.order.push('wait');
      b.waits.push({ topicId, id, ms, opts });
      return Promise.resolve(typeof outcome === 'function' ? outcome() : outcome);
    },
    async publishSys(topicId, obj) {
      b.order.push('publish');
      if (publishError) throw publishError;
      b.sys.push({ topicId, obj });
    },
    cancelAck(t, id) {
      b.cancelled.push(id);
    },
    async requestConfig(args) {
      b.cfgGets.push(args);
      return true;
    },
    async pushInfo(args) {
      b.pushes.push(args);
      return 'sent';
    },
  };
  return b;
}

function make(w, b) {
  return new SafetyCfgSync({
    db: w.db,
    publishSys: (t, o) => b.publishSys(t, o),
    expectOutcome: (...a) => b.expectOutcome(...a),
    cancelAck: (t, id) => b.cancelAck(t, id),
    isConnected: () => b.isConnected(),
    requestConfig: (a) => b.requestConfig(a),
    pushInfo: (a) => b.pushInfo(a),
    now: () => w.now,
    newCommandId: () => 'gen-id-1',
    logger: { log() {}, warn() {}, error() {} },
  });
}

const DEVICE = (over = {}) => ({ id: DEV, device_uuid: UID, is_online: true, topic_id: TOPIC, caps: ['safety', 'actuator', 'event', 'cfg'], ...over });
const ZONE_BODY = (rev = 7, id) => ({ base_rev: rev, set: { zone: { id: 1, name: 'Gizli Mutfak' } }, ...(id ? { id } : {}) });

async function rejects(p, status, code) {
  let err = null;
  try {
    await p;
  } catch (e) {
    err = e;
  }
  assert.ok(err, 'hata bekleniyordu');
  assert.equal(err.status, status, `${err.code}: ${err.message}`);
  assert.equal(err.code, code);
  return err;
}

// ------------------------------------------------------------------------------
// REST: cevrimici
// ------------------------------------------------------------------------------
test('cevrimici: bekleyici YAYINDAN ONCE (uid + cfgRev = base_rev+1), sys yuku, 200 {applied, rev, crc, command_id}', async () => {
  const w = world();
  const b = bridgeStub();
  const out = await make(w, b).patch({ actor: STAFF, homeId: HOME, device: DEVICE(), body: ZONE_BODY(7, 'c-9') });
  assert.deepEqual(out, { applied: true, rev: 8, crc: '0000000b', command_id: 'c-9' });
  assert.deepEqual(b.order, ['wait', 'publish']);
  assert.deepEqual(b.waits[0], { topicId: TOPIC, id: 'c-9', ms: 10000, opts: { uid: UID, cfgRev: 8 } });
  assert.deepEqual(b.sys[0], { topicId: TOPIC, obj: { cmd: 'cfg_patch', module: 'safety', uid: UID, id: 'c-9', base_rev: 7, set: { zone: { id: 1, name: 'Gizli Mutfak' } } } });
  assert.equal(w.cfg.pending, null, 'ucus isareti temizlendi');
  assert.equal(b.cfgGets.length, 1, 'kopya tazelenir (adlar)');
  assert.equal(b.cfgGets[0].force, true);
  const a = w.audits.find((x) => x.event === 'safety_config_patch');
  assert.equal(a.actor_user_id, 'u-staff');
  assert.equal(a.actor_role, 'service_user');
  assert.deepEqual(a.details, { op: 'set', item: 'zone', target: '1', loosening: false, result: 'applied', via: 'cloud', command_id: 'c-9' });
  assert.equal(JSON.stringify(w.audits).includes('Gizli'), false, 'denetim kaydinda ad/deger yok');
});

test('cevrimici: kimlik verilmezse sunucu uretir; gevsetme (politika kapatma) denetimde isaretlenir', async () => {
  const w = world();
  const b = bridgeStub();
  const out = await make(w, b).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: { base_rev: 7, set: { policy: { on: false } } } });
  assert.equal(out.command_id, 'gen-id-1');
  assert.equal(w.audits[0].details.loosening, true);
});

test('cevrimici ret eslemesi: cfg_conflict 409 (+data), cfg_invalid 400, zone_latched 409, cfg_storage 507, busy 503; ucus temizlenir', async () => {
  const cases = [
    ['cfg_conflict', 409, 'CONFIG_CHANGED_ON_DEVICE'],
    ['cfg_invalid', 400, 'CONFIG_INVALID'],
    ['zone_latched', 409, 'ZONE_ALARM_ACTIVE'],
    ['cfg_storage', 507, 'DEVICE_STORAGE_FULL'],
    ['busy', 503, 'DEVICE_BUSY'],
    ['bad_cmd', 409, 'DEVICE_REJECTED'],
  ];
  for (const [code, status, err] of cases) {
    const w = world();
    const b = bridgeStub({ outcome: { ok: false, rejected: code, cfg: { rev: 9, crc: '0000000c' } } });
    const e = await rejects(make(w, b).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: ZONE_BODY() }), status, err);
    assert.equal(w.cfg.pending, null, code);
    if (code === 'cfg_conflict') {
      assert.deepEqual(e.extra.data, { rev: 9, crc: '0000000c', copy_rev: 7 });
      assert.equal(b.cfgGets.length, 1);
    }
    if (code === 'bad_cmd') assert.equal(e.extra.reason, 'bad_cmd');
    assert.equal(w.audits.filter((x) => x.event === 'safety_config_patch').length, 0, 'uygulanmayan yama denetime "applied" yazilmaz');
  }
});

test('cevrimici: 10 sn icinde sonuc yok -> 202 {applied:null}; yayin hatasi -> 502 + bekleyici iptal + ucus temizlenir', async () => {
  const w = world();
  const out = await make(w, bridgeStub({ outcome: { ok: false, timeout: true } })).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: ZONE_BODY(7, 'c-1') });
  assert.deepEqual(out, { applied: null, command_id: 'c-1' });
  assert.equal(w.cfg.pending, null);
  const w2 = world();
  const b2 = bridgeStub({ publishError: Object.assign(new Error('broker'), { name: 'BrokerUnavailableError' }) });
  await rejects(make(w2, b2).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: ZONE_BODY(7, 'c-2') }), 502, 'BROKER_UNAVAILABLE');
  assert.deepEqual(b2.cancelled, ['c-2']);
  assert.equal(w2.cfg.pending, null);
});

test('on denetimler: caps cfg yok 409 FIRMWARE_UNSUPPORTED; kopya yok 409 CONFIG_NOT_AVAILABLE (+cfg_get); state rev yok ayni', async () => {
  let w = world();
  let b = bridgeStub();
  await rejects(make(w, b).patch({ actor: OWNER, homeId: HOME, device: DEVICE({ caps: ['safety'] }), body: ZONE_BODY() }), 409, 'FIRMWARE_UNSUPPORTED');
  assert.equal(b.sys.length, 0);
  w = world({ copy: false });
  b = bridgeStub();
  await rejects(make(w, b).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: ZONE_BODY() }), 409, 'CONFIG_NOT_AVAILABLE');
  assert.equal(b.cfgGets.length, 1);
  w = world({ stateRev: null });
  await rejects(make(w, bridgeStub()).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: ZONE_BODY() }), 409, 'CONFIG_NOT_AVAILABLE');
  // gecersiz govde: 400 (agdan once)
  await rejects(make(world(), bridgeStub()).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: { base_rev: 7 } }), 400, 'VALIDATION');
});

test('on cakisma: base_rev != panonun son rev\'i -> 409 CONFIG_CHANGED_ON_DEVICE {rev, crc, copy_rev}; ag yok; kopya bayatsa cfg_get', async () => {
  const w = world({ stateRev: 9, copyRev: 7 });
  const b = bridgeStub();
  const e = await rejects(make(w, b).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: ZONE_BODY(7) }), 409, 'CONFIG_CHANGED_ON_DEVICE');
  assert.deepEqual(e.extra.data, { rev: 9, crc: '0000000a', copy_rev: 7 });
  assert.equal(b.sys.length, 0);
  assert.equal(b.waits.length, 0);
  assert.equal(b.cfgGets.length, 1);
});

test('cevrimici ama kuyruk dolu ya da ucusta yama var -> 409 CONFIG_PENDING', async () => {
  const item = { id: 'q1', base_rev: 7, patch: { del: { sensor: 'd3' } }, by: 'u-owner', role: 'owner', at: new Date(T0).toISOString(), loosening: true };
  await rejects(make(world({ pending: { v: 1, items: [item] } }), bridgeStub()).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: ZONE_BODY() }), 409, 'CONFIG_PENDING');
  const fly = { v: 1, items: [], inflight: { id: 'x', at: new Date(T0 - 5000).toISOString() } };
  await rejects(make(world({ pending: fly }), bridgeStub()).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: ZONE_BODY() }), 409, 'CONFIG_PENDING');
  // suresi gecmis ucus isareti (surec coktu) engel degildir
  const stale = { v: 1, items: [], inflight: { id: 'x', at: new Date(T0 - 60000).toISOString() } };
  const out = await make(world({ pending: stale }), bridgeStub()).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: ZONE_BODY(7, 'c-3') });
  assert.equal(out.applied, true);
});

// ------------------------------------------------------------------------------
// REST: cevrimdisi kuyruk
// ------------------------------------------------------------------------------
test('cevrimdisi: kuyruga eklenir (202 queued, sira, 24 sa omur); base_rev zinciri (son + 1); dolu kuyruk 409', async () => {
  _resetEmptyCache();
  const w = world({ online: false });
  const b = bridgeStub();
  const sync = make(w, b);
  const r1 = await sync.patch({ actor: OWNER, homeId: HOME, device: DEVICE({ is_online: false }), body: ZONE_BODY(7, 'q-1') });
  assert.deepEqual(r1, { queued: true, position: 1, expires_at: new Date(T0 + 24 * 3600 * 1000).toISOString(), command_id: 'q-1' });
  assert.equal(b.sys.length, 0);
  assert.equal(w.cfg.pending.items.length, 1);
  assert.deepEqual(w.cfg.pending.items[0], { id: 'q-1', base_rev: 7, patch: { set: { zone: { id: 1, name: 'Gizli Mutfak' } } }, by: 'u-owner', role: 'owner', at: new Date(T0).toISOString(), loosening: false });
  await rejects(sync.patch({ actor: OWNER, homeId: HOME, device: DEVICE({ is_online: false }), body: ZONE_BODY(7, 'q-2') }), 409, 'CONFIG_CHANGED_ON_DEVICE');
  const r2 = await sync.patch({ actor: OWNER, homeId: HOME, device: DEVICE({ is_online: false }), body: ZONE_BODY(8, 'q-2') });
  assert.equal(r2.position, 2);
  assert.equal(w.audits.filter((x) => x.details.result === 'queued').length, 2);
  for (let i = 3; i <= 16; i += 1) await sync.patch({ actor: OWNER, homeId: HOME, device: DEVICE({ is_online: false }), body: ZONE_BODY(i + 6, `q-${i}`) });
  await rejects(sync.patch({ actor: OWNER, homeId: HOME, device: DEVICE({ is_online: false }), body: ZONE_BODY(23, 'q-17') }), 409, 'CONFIG_QUEUE_FULL');
});

test('view: state_rev, next_base_rev ve (yetkiliye) bekleyen ozeti; iptal kuyrugu bosaltir ve denetim yazar', async () => {
  const w = world({ online: false });
  const sync = make(w, bridgeStub());
  await sync.patch({ actor: OWNER, homeId: HOME, device: DEVICE({ is_online: false }), body: ZONE_BODY(7, 'q-1') });
  const v = await sync.view({ deviceId: DEV, includePending: true });
  assert.equal(v.state_rev, 7);
  assert.equal(v.next_base_rev, 8);
  assert.deepEqual(v.pending, [{ id: 'q-1', op: 'set', item: 'zone', target: '1', at: new Date(T0).toISOString(), role: 'owner', loosening: false }]);
  const hidden = await sync.view({ deviceId: DEV, includePending: false });
  assert.equal(Object.prototype.hasOwnProperty.call(hidden, 'pending'), false);
  const c = await sync.cancel({ actor: OWNER, homeId: HOME, device: DEVICE({ is_online: false }) });
  assert.deepEqual(c, { dropped: 1 });
  assert.equal(w.cfg.pending, null);
  const d = w.audits.find((x) => x.event === 'safety_config_pending_dropped');
  assert.deepEqual(d.details, { reason: 'cancelled', count: 1 });
  assert.deepEqual(await sync.cancel({ actor: OWNER, homeId: HOME, device: DEVICE() }), { dropped: 0 });
});

// ------------------------------------------------------------------------------
// Kuyruk uzlastirmasi (kopru canli state'i -> uzlastirici -> onLiveState)
// ------------------------------------------------------------------------------
const ITEM = (id, rev, over = {}) => ({ id, base_rev: rev, patch: { set: { zone: { id: 1, name: `Z${id}` } } }, by: 'u-owner', role: 'owner', at: new Date(T0).toISOString(), loosening: false, ...over });
const LIVE = (rev, caps = ['safety', 'actuator', 'event', 'cfg']) => ({ topicId: TOPIC, homeId: HOME, deviceId: DEV, uid: UID, caps, summary: { cfg: { rev, crc: '0000000a' } } });

test('kuyruk: bas oge gonderilir (bekleyici uid + cfgRev), uygulaninca cikar; tur basina TEK oge', async () => {
  _resetEmptyCache();
  const w = world({ pending: { v: 1, items: [ITEM('q1', 7), ITEM('q2', 8), ITEM('q3', 9)] } });
  const b = bridgeStub({ outcome: { ok: true, cfg: { rev: 8, crc: '0000000b' } } });
  await make(w, b).onLiveState(LIVE(7));
  assert.deepEqual(b.sys.map((x) => x.obj.id), ['q1']);
  assert.deepEqual(b.waits[0].opts, { uid: UID, cfgRev: 8 });
  assert.deepEqual(w.cfg.pending.items.map((i) => i.id), ['q2', 'q3']);
});

test('kuyruk zinciri (dogru sira): her canli state yeni rev ile -> ucu de sirayla uygulanir; denetim aktoru isteyen kullanici', async () => {
  _resetEmptyCache();
  const w = world({ pending: { v: 1, items: [ITEM('q1', 7), ITEM('q2', 8), ITEM('q3', 9, { by: 'u-staff', role: 'service_user' })] } });
  let rev = 8;
  const b = bridgeStub({ outcome: () => ({ ok: true, cfg: { rev: rev++, crc: '0000000b' } }) });
  const sync = make(w, b);
  await sync.onLiveState(LIVE(7));
  await sync.onLiveState(LIVE(8));
  await sync.onLiveState(LIVE(9));
  assert.deepEqual(b.sys.map((x) => [x.obj.id, x.obj.base_rev]), [['q1', 7], ['q2', 8], ['q3', 9]]);
  assert.equal(w.cfg.pending, null);
  const applied = w.audits.filter((x) => x.event === 'safety_config_patch');
  assert.deepEqual(applied.map((x) => [x.actor_user_id, x.actor_role, x.details.result, x.details.via]), [
    ['u-owner', 'owner', 'applied', 'queue'], ['u-owner', 'owner', 'applied', 'queue'], ['u-staff', 'service_user', 'applied', 'queue'],
  ]);
  assert.equal(b.pushes.length, 0);
  // kuyruk bos: sonraki state'lerde SORGU YOK (bellek ici onbellek)
  const n = w.queries.length;
  await sync.onLiveState(LIVE(10));
  await sync.onLiveState(LIVE(10));
  assert.equal(w.queries.length, n);
  markPending(DEV); // REST yeni oge ekledi
  await sync.onLiveState(LIVE(10));
  assert.ok(w.queries.length > n);
});

test('pano kazanir: bas ogenin base_rev\'i panonun rev\'inden farkli -> butun kuyruk duser + owner\'a bilgi push\'u + denetim', async () => {
  _resetEmptyCache();
  const w = world({ pending: { v: 1, items: [ITEM('q1', 7), ITEM('q2', 8)] } });
  const b = bridgeStub();
  await make(w, b).onLiveState(LIVE(9)); // kurulumcu yerelde degistirdi
  assert.equal(b.sys.length, 0);
  assert.equal(w.cfg.pending, null);
  assert.deepEqual(w.audits.map((x) => [x.event, x.details.reason, x.details.count]), [['safety_config_pending_dropped', 'conflict', 2]]);
  assert.deepEqual(b.pushes, [{ homeId: HOME, deviceId: DEV, deviceUuid: UID, alarmId: null, reason: 'cfg_pending_dropped' }]);
});

test('suresi dolan oge atilir (expired); erisimi kalmayan isteyenin ogesi ve sonrakiler atilir (revoked)', async () => {
  _resetEmptyCache();
  const old = new Date(T0 - 25 * 3600 * 1000).toISOString();
  const w = world({ pending: { v: 1, items: [ITEM('q0', 6, { at: old }), ITEM('q1', 7)] } });
  const b = bridgeStub();
  await make(w, b).onLiveState(LIVE(7));
  assert.deepEqual(w.audits[0].details, { reason: 'expired', count: 1 });
  assert.deepEqual(b.sys.map((x) => x.obj.id), ['q1']);

  _resetEmptyCache();
  const w2 = world({ pending: { v: 1, items: [ITEM('q1', 7), ITEM('q2', 8, { by: 'u-gone' }), ITEM('q3', 9)] }, members: { 'u-owner': true } });
  let rev = 8;
  const b2 = bridgeStub({ outcome: () => ({ ok: true, cfg: { rev: rev++, crc: '0000000b' } }) });
  const s2 = make(w2, b2);
  await s2.onLiveState(LIVE(7));
  assert.deepEqual(w2.cfg.pending, null, 'q2 erisimi yok: q2 ve q3 duser');
  assert.ok(w2.audits.find((x) => x.event === 'safety_config_pending_dropped' && x.details.reason === 'revoked' && x.details.count === 2));
  assert.deepEqual(b2.sys.map((x) => x.obj.id), ['q1']);
});

test('firmware reddi (cfg_invalid / zone_latched / cfg_conflict / cfg_storage) bas ogeyi ve sonrakileri dusurur + bilgi push\'u', async () => {
  for (const code of ['cfg_invalid', 'zone_latched', 'cfg_conflict', 'cfg_storage']) {
    _resetEmptyCache();
    const w = world({ pending: { v: 1, items: [ITEM('q1', 7), ITEM('q2', 8)] } });
    const b = bridgeStub({ outcome: { ok: false, rejected: code } });
    await make(w, b).onLiveState(LIVE(7));
    assert.equal(w.cfg.pending, null, code);
    assert.ok(w.audits.find((x) => x.details.reason === code && x.details.count === 2), code);
    assert.equal(b.pushes.length, 1, code);
  }
  _resetEmptyCache();
  const w = world({ pending: { v: 1, items: [ITEM('q1', 7)] } });
  const b = bridgeStub({ outcome: { ok: false, rejected: 'busy' } });
  await make(w, b).onLiveState(LIVE(7));
  assert.deepEqual(w.cfg.pending.items.map((i) => i.id), ['q1'], 'busy: oge kalir, yeniden denenir');
  assert.equal(b.pushes.length, 0);
});

test('zaman asimi: oge sent_at ile kalir; sonraki state rev = base_rev+1 ise UYGULANDI sayilir (cift uygulama yok, kuyruk dusmez)', async () => {
  _resetEmptyCache();
  const w = world({ pending: { v: 1, items: [ITEM('q1', 7), ITEM('q2', 8)] } });
  const b = bridgeStub({ outcome: { ok: false, timeout: true } });
  const sync = make(w, b);
  await sync.onLiveState(LIVE(7));
  assert.equal(w.cfg.pending.items[0].id, 'q1');
  assert.ok(w.cfg.pending.items[0].sent_at, 'gonderildi isareti');
  assert.equal(w.cfg.pending.inflight, undefined);
  b.waits.length = 0;
  await sync.onLiveState(LIVE(8)); // yanki kacti ama pano uyguladi
  assert.deepEqual(w.audits.filter((x) => x.event === 'safety_config_patch').map((x) => x.details.result), ['applied_inferred']);
  assert.equal(w.audits.filter((x) => x.event === 'safety_config_pending_dropped').length, 0, 'pano kazanir kurali tetiklenmez');
  // q2 (base 8) ayni turda gonderilir
  assert.deepEqual(b.sys.map((x) => x.obj.id), ['q1', 'q2']);
});

test('zaman asimi en cok 3 deneme; kopru bagli degilse gonderim denenmez; cfg yetenegi yoksa hicbir sey', async () => {
  _resetEmptyCache();
  const w = world({ pending: { v: 1, items: [ITEM('q1', 7)] } });
  const b = bridgeStub({ outcome: { ok: false, timeout: true } });
  const sync = make(w, b);
  for (let i = 0; i < 5; i += 1) await sync.onLiveState(LIVE(7));
  assert.equal(b.sys.length, 3);
  _resetEmptyCache();
  const w2 = world({ pending: { v: 1, items: [ITEM('q1', 7)] } });
  const b2 = bridgeStub({ connected: false });
  await make(w2, b2).onLiveState(LIVE(7));
  assert.equal(b2.sys.length, 0);
  assert.deepEqual(w2.cfg.pending.items.map((i) => i.id), ['q1']);
  const w3 = world({ pending: { v: 1, items: [ITEM('q1', 7)] } });
  await make(w3, bridgeStub()).onLiveState(LIVE(7, ['safety']));
  assert.equal(w3.queries.length, 0);
});

// ------------------------------------------------------------------------------
// Baglanti: uzlastirici ve guvenlik servisi
// ------------------------------------------------------------------------------
test('uzlastirici onSafetyState -> yapilandirma kuyrugu (cihaz basina sirali is); sys yayincisi yoksa kapali', async () => {
  const { DeviceReconciler } = require('../../src/services/device_reconciler');
  const calls = [];
  const cfgSync = { onLiveState: async (a) => { calls.push(a); return { status: 'empty' }; } };
  const r = new DeviceReconciler({ db: { query: async () => ({ rows: [] }) }, publishCommand: async () => {}, publishSys: async () => {}, cfgSync, logger: { log() {}, warn() {}, error() {} } });
  const args = LIVE(7);
  r.onSafetyState(args);
  await r.whenIdle();
  assert.deepEqual(calls, [args]);
  const off = new DeviceReconciler({ db: { query: async () => ({ rows: [] }) }, publishCommand: async () => {}, logger: { log() {}, warn() {}, error() {} } });
  off.onSafetyState(args); // firlatmaz, is yok
  await off.whenIdle();
  r.stop();
  off.stop();
});

test('SafetyService: patch/cancel safety_config yetenegi (resident/misafir 403); cihaz evde cozulur; GET ekleri', async () => {
  const { SafetyService } = require('../../src/services/safety_service');
  const seen = [];
  const cfgSync = {
    patch: async (a) => { seen.push(['patch', a]); return { applied: true }; },
    cancel: async (a) => { seen.push(['cancel', a]); return { dropped: 2 }; },
    view: async (a) => { seen.push(['view', a]); return { state_rev: 7, next_base_rev: 8, ...(a.includePending ? { pending: [] } : {}) }; },
  };
  const deviceService = { _findHomeDevice: async (homeId, ref) => ({ id: DEV, device_uuid: UID, is_online: true, topic_id: TOPIC, caps: ['cfg'], ref }) };
  const alarms = { getConfig: async () => ({ rev: 7, crc: '0000000a', policy: null, zones: [], lights: [], sensors: [], actuators: [] }) };
  const svc = new SafetyService({ deviceService, alarmService: alarms, cfgSync });
  for (const access of ['resident', 'guest']) {
    await rejects(svc.patchSafetyConfig({ actor: { access }, homeId: HOME, deviceRef: UID, body: {} }), 403, 'FORBIDDEN');
    await rejects(svc.cancelSafetyConfigPending({ actor: { access }, homeId: HOME, deviceRef: UID }), 403, 'FORBIDDEN');
  }
  assert.deepEqual(await svc.patchSafetyConfig({ actor: { access: 'owner' }, homeId: HOME, deviceRef: 'ahbu-s3-1a2b3c', body: { base_rev: 7 } }), { applied: true });
  assert.equal(seen[0][1].device.id, DEV);
  assert.deepEqual(seen[0][1].body, { base_rev: 7 });
  assert.deepEqual(await svc.cancelSafetyConfigPending({ actor: { access: 'service_session' }, homeId: HOME, deviceRef: UID }), { dropped: 2 });
  const owner = await svc.getSafetyConfig({ actor: { access: 'owner' }, homeId: HOME, deviceRef: UID });
  assert.deepEqual([owner.state_rev, owner.next_base_rev, owner.pending], [7, 8, []]);
  const guest = await svc.getSafetyConfig({ actor: { access: 'guest' }, homeId: HOME, deviceRef: UID });
  assert.equal(Object.prototype.hasOwnProperty.call(guest, 'pending'), false, 'bekleyen ozet yalniz safety_config yetkilisine');
  assert.equal(guest.state_rev, 7);
});

// ------------------------------------------------------------------------------
// Faz 2 incelemesi G-1: bulut yolunun yetki siniri (gaz vanasi uzaktan acilabilir kilinamaz; kurulu kipte hirsiz zayiflatilamaz)
// ------------------------------------------------------------------------------
const GAS_COPY = () => ({
  ...JSON.parse(JSON.stringify(COPY)),
  sensors: [
    { id: 'd3', kind: 'gas', zone: 1, active_open: 1, flags: 5, confirm_ms: 300, name: '' },
    { id: 'd4', kind: 'door', zone: 1, active_open: 1, flags: 9, confirm_ms: 0, name: '' },
    { id: 'd5', kind: 'window', zone: 1, active_open: 1, flags: 1, confirm_ms: 0, name: '' },
  ],
  actuators: [{ id: 'a1', relay: 5, relay2: 0, kind: 'valve', close_mode: 'energize', medium: 'gas', zones: [1], fb_di: 0, fb_closed_active: 1, fb_timeout_s: 60, run_limit_s: 0, exproof: false, name: '' }],
  intrusion: { exit_s: 30, entry_s: 20 },
});
const CAPS_I = ['safety', 'actuator', 'event', 'cfg', 'intrusion'];
function gasWorld(over = {}) {
  const w = world({ caps: CAPS_I, ...over });
  w.cfg.body = GAS_COPY();
  return w;
}

test('G-1a: gaz vanasini su yapan / silen bulut yamasi 403 GAS_VALVE_LOCAL_ONLY; panoya gitmez, kuyruga girmez; bolge degisimi gider', async () => {
  for (const online of [true, false]) {
    const w = gasWorld({ online });
    const b = bridgeStub();
    const sync = make(w, b);
    const dev = DEVICE({ is_online: online, caps: CAPS_I });
    const med = { base_rev: 7, set: { actuator: { id: 'a1', relay: 5, kind: 'valve', close_mode: 'energize', medium: 'water', zones: [1] } } };
    await rejects(sync.patch({ actor: OWNER, homeId: HOME, device: dev, body: med }), 403, 'GAS_VALVE_LOCAL_ONLY');
    await rejects(sync.patch({ actor: STAFF, homeId: HOME, device: dev, body: { base_rev: 7, del: { actuator: 'a1' } } }), 403, 'GAS_VALVE_LOCAL_ONLY');
    await rejects(sync.patch({ actor: STAFF, homeId: HOME, device: dev, body: { base_rev: 7, set: { sensor: { id: 'd4', kind: 'gas_reset', zone: 1 } } } }), 403, 'GAS_VALVE_LOCAL_ONLY');
    assert.equal(b.sys.length, 0, `panoya gitmedi (cevrimici=${online})`);
    assert.equal(w.cfg.pending, null, `kuyruga girmedi (cevrimici=${online})`);
    const audit = w.audits.find((x) => x.details.result === 'rejected_gas_local');
    assert.ok(audit, 'ret denetime yazilir');
    assert.equal(JSON.stringify(w.audits).includes('water'), false, 'denetimde deger yok');
  }
  const w = gasWorld();
  const b = bridgeStub();
  const zone = { base_rev: 7, set: { actuator: { id: 'a1', relay: 5, kind: 'valve', close_mode: 'energize', medium: 'gas', zones: [1, 2] } } };
  const out = await make(w, b).patch({ actor: STAFF, homeId: HOME, device: DEVICE({ caps: CAPS_I }), body: zone });
  assert.equal(out.applied, true);
});

test('G-1b: kurulu kipte hirsiz zayiflatmasi 409 INTRUSION_ARMED (cevrimici ve kuyruk); cozuluyken gider ve gevsetme olarak denetlenir', async () => {
  const flags0 = { base_rev: 7, set: { sensor: { id: 'd5', kind: 'window', zone: 1, active_open: 1, flags: 0 } } };
  const longer = { base_rev: 7, set: { intrusion: { entry_s: 90 } } };
  for (const online of [true, false]) {
    const w = gasWorld({ online });
    w.device.safety_state.arm = { mode: 'away', st: 'idle', ok: true };
    const b = bridgeStub();
    const dev = DEVICE({ is_online: online, caps: CAPS_I });
    await rejects(make(w, b).patch({ actor: STAFF, homeId: HOME, device: dev, body: flags0 }), 409, 'INTRUSION_ARMED');
    await rejects(make(w, b).patch({ actor: OWNER, homeId: HOME, device: dev, body: longer }), 409, 'INTRUSION_ARMED');
    assert.equal(b.sys.length, 0);
    assert.equal(w.cfg.pending, null);
    // zayiflatmayan yama (gecikme kisaltma) kurulu kipte de gider
    const out = await make(w, b).patch({ actor: OWNER, homeId: HOME, device: dev, body: { base_rev: 7, set: { intrusion: { entry_s: 5 } } } });
    assert.ok(out.applied === true || out.queued === true);
  }
  const w = gasWorld();
  w.device.safety_state.arm = { mode: 'off', st: 'idle', ok: true };
  const b = bridgeStub();
  const out = await make(w, b).patch({ actor: STAFF, homeId: HOME, device: DEVICE({ caps: CAPS_I }), body: flags0 });
  assert.equal(out.applied, true);
  assert.equal(w.audits.find((x) => x.details.result === 'applied').details.loosening, true, 'hirsiz zayiflatmasi gevsetme olarak denetlenir');
});

test('G-1: firmware ret kodlari gas_local_only -> 403 GAS_VALVE_LOCAL_ONLY, armed -> 409 INTRUSION_ARMED; kuyrukta bas oge ve sonrakiler duser', async () => {
  for (const [code, status, ecode] of [['gas_local_only', 403, 'GAS_VALVE_LOCAL_ONLY'], ['armed', 409, 'INTRUSION_ARMED']]) {
    const w = world();
    const b = bridgeStub({ outcome: { ok: false, rejected: code } });
    await rejects(make(w, b).patch({ actor: OWNER, homeId: HOME, device: DEVICE(), body: ZONE_BODY(7) }), status, ecode);
    _resetEmptyCache();
    const w2 = world({ pending: { v: 1, items: [ITEM('q1', 7), ITEM('q2', 8)] } });
    const b2 = bridgeStub({ outcome: { ok: false, rejected: code } });
    await make(w2, b2).onLiveState(LIVE(7));
    assert.equal(w2.cfg.pending, null, code);
    assert.equal(b2.pushes.length, 1, code);
  }
});

// Faz 2 incelemesi R2: firmware 1.2.1 (caps 'intrusion') cfg_patch basarisinda last_id yankisi verir; kuyrukta "uygulandi" cikarimi
// yalniz state.last_id bas ogenin kimligiyse yapilir (baska kaynakli rev artisi uygulandi sayilmaz -> pano kazanir).
test('R2: last_id yankili firmware kuyrukta rev cikarimini last_id ile yapar; yabanci rev artisi uygulandi sayilmaz', async () => {
  _resetEmptyCache();
  const w = world({ caps: CAPS_I, pending: { v: 1, items: [ITEM('q1', 7, { sent_at: new Date(T0).toISOString() }), ITEM('q2', 8)] } });
  const b = bridgeStub({ outcome: { ok: false, timeout: true } });
  await make(w, b).onLiveState({ ...LIVE(8, CAPS_I), lastId: 'lan-77' });
  assert.equal(w.audits.filter((x) => x.details.result === 'applied_inferred').length, 0, 'yabanci rev artisi');
  assert.ok(w.audits.find((x) => x.event === 'safety_config_pending_dropped' && x.details.reason === 'conflict'), 'pano kazanir');
  assert.equal(b.pushes.length, 1);
  _resetEmptyCache();
  const w2 = world({ caps: CAPS_I, pending: { v: 1, items: [ITEM('q1', 7, { sent_at: new Date(T0).toISOString() })] } });
  const b2 = bridgeStub();
  await make(w2, b2).onLiveState({ ...LIVE(8, CAPS_I), lastId: 'q1' });
  assert.deepEqual(w2.audits.filter((x) => x.event === 'safety_config_patch').map((x) => x.details.result), ['applied_inferred']);
});

// Faz 2 incelemesi RG-2: yapilandirma kuyrugu isi (yanit icin <= 10 sn bekler) ev uzlastirmasinin kuyrugunu (es zamanlilik 2)
// tikamaz: ayri seritte calisir; whenIdle ikisini de bekler, stop ikisini de bosaltir.
test('RG-2: yavas yapilandirma kuyrugu isleri ev uzlastirmasini bekletmez (ayri serit)', async () => {
  const { createDeviceReconciler } = require('../../src/services/device_reconciler');
  const SLOW = 400;
  let done = 0;
  const r = createDeviceReconciler({
    db: { query: async () => ({ rows: [] }) },
    publishCommand: async () => {},
    logger: { log() {}, warn() {}, error() {} },
    cfgSync: { onLiveState: () => new Promise((res) => setTimeout(() => { done += 1; res(); }, SLOW)) },
  });
  r.onSafetyState({ topicId: 'h_a', deviceId: 'dev-a' });
  r.onSafetyState({ topicId: 'h_b', deviceId: 'dev-b' });
  const t0 = Date.now();
  await r.checkNow('h_c');
  const waited = Date.now() - t0;
  assert.ok(waited < SLOW / 2, `ev uzlastirmasi cfg isleri yuzunden ${waited} ms bekledi`);
  await r.whenIdle(3000);
  assert.equal(done, 2, 'whenIdle yapilandirma seridini de bekler');
  r.stop();
  r.onSafetyState({ topicId: 'h_a', deviceId: 'dev-a' });
  assert.equal(r.stats().safety_cfg_queue.pending, 0, 'durdurulmus uzlastirici yapilandirma isi almaz');
});
