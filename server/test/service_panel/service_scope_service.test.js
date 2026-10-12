'use strict';

// services/service_scope_service.js: kapsamlar arasi AKTARIM (yalniz KOK). Sahte db / sahte yan servisler.
//   - aktor kok degilse (servis sorumlusu, API anahtari, kimliksiz, dahili cagri) 403; hicbir sorgu calismaz
//   - service_user_id ZORUNLU (undefined -> 400), null = koke al, hedef aktif service_user olmali (404/409)
//   - ev aktarimi: ev + evdeki kartlar + eski servis uyeligi/MQTT kimligi iptal + yeni servis suresiz uyelik + kimlik/anahtar donmesi
//   - kart aktarimi: kurulu kart 409; site aktarimi: silinmis site 404

const test = require('node:test');
const assert = require('node:assert');
const { ServiceScopeService } = require('../../src/services/service_scope_service');

const ROOT = { userId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', role: 'super_user', type: 'super_user', ip: '10.0.0.1' };
const SVC_OLD = '11111111-1111-4111-8111-111111111111';
const SVC_NEW = '22222222-2222-4222-8222-222222222222';
const HOME = '33333333-3333-4333-8333-333333333333';
const SITE = '44444444-4444-4444-8444-444444444444';

function build({ homeOwner = SVC_OLD, users = {}, card = null, site = null } = {}) {
  const log = [];
  const state = { homeOwner };
  const userRows = {
    [SVC_NEW]: { id: SVC_NEW, email: 'yeni@x.test', full_name: 'Yeni', role: 'service_user', is_active: true, account_status: 'active' },
    [SVC_OLD]: { id: SVC_OLD, email: 'eski@x.test', full_name: 'Eski', role: 'service_user', is_active: true, account_status: 'active' },
    ...users,
  };
  const q = async (text, params) => {
    const sql = String(text).replace(/\s+/g, ' ').trim();
    log.push({ sql, params });
    if (sql.startsWith('SELECT id, email, full_name, role, is_active, account_status FROM users')) return { rows: userRows[params[0]] ? [userRows[params[0]]] : [] };
    if (sql.startsWith('SELECT id, name, service_owner_id FROM homes')) return { rows: [{ id: HOME, name: 'Ev', service_owner_id: state.homeOwner }] };
    if (sql.startsWith('UPDATE homes SET service_owner_id')) { state.homeOwner = params[1]; return { rows: [] }; }
    if (sql.startsWith('UPDATE device_inventory SET service_owner_id = $2 WHERE claimed_home_id')) return { rows: [{ device_uuid: 'AHBU-X-1' }, { device_uuid: 'AHBU-X-2' }] };
    // hedef disindaki servis uyelikleri silinir: eski servisin uyeligi vardi
    if (sql.startsWith('DELETE FROM home_users')) return { rows: params[1] !== SVC_OLD ? [{ user_id: SVC_OLD }] : [] };
    if (sql.startsWith('SELECT di.id, di.status')) return { rows: card ? [card] : [] };
    if (sql.startsWith('SELECT id, name, service_owner_id FROM sites')) return { rows: site ? [site] : [] };
    return { rows: [], rowCount: 0 };
  };
  const db = { query: q, withTransaction: async (fn) => fn({ query: q }) };
  const extra = { revoked: [], kicked: [], rotations: [], credRot: [], after: [] };
  const svc = new ServiceScopeService({
    db,
    mqtt: {
      async revokeUserAccess(a) { extra.revoked.push(a.userId); return { usernames: [`a_${a.userId}`] }; },
      async kickUsernames(u) { extra.kicked.push(...u); return { failed: 0 }; },
    },
    localKeyRotation: {
      async scheduleRotation(h, o) { extra.rotations.push([h, o.reason]); return { scheduled: true, topicId: 't' }; },
      afterCommit(r) { extra.after.push(['lk', r.scheduled]); },
    },
    deviceCredRotation: {
      async rotate(h, o) { extra.credRot.push([h, o.reason]); return { rotated: true, usernames: ['d_x'] }; },
      async afterCommit(r) { extra.after.push(['cred', r.rotated]); },
    },
  });
  return { svc, log, state, extra };
}

async function rejects(p, status, code) {
  let err = null;
  try { await p; } catch (e) { err = e; }
  assert.ok(err, `HTTP ${status} ${code || ''} bekleniyordu`);
  assert.strictEqual(err.status, status, err.message);
  if (code) assert.strictEqual(err.code, code);
  return err;
}

test('kok degilse 403 ve HICBIR sorgu calismaz: servis sorumlusu, API anahtari, kimliksiz, dahili cagri, servis oturumu', async () => {
  for (const actor of [
    { userId: SVC_NEW, role: 'service_user', type: 'service_user' },
    { userId: SVC_NEW, globalRole: 'service_user' },
    { userId: null, type: 'api_key' },
    { userId: SVC_NEW, role: 'user' },
    null,
    undefined,
    {},
  ]) {
    const { svc, log } = build();
    await rejects(svc.transferHome({ homeId: HOME, serviceUserId: SVC_NEW, actor }), 403, 'FORBIDDEN');
    await rejects(svc.transferInventory({ deviceUuid: 'AHBU-S3-0001', serviceUserId: SVC_NEW, actor }), 403, 'FORBIDDEN');
    await rejects(svc.transferSite({ siteId: SITE, serviceUserId: SVC_NEW, actor }), 403, 'FORBIDDEN');
    assert.strictEqual(log.length, 0, `sorgu calismadi (${JSON.stringify(actor)})`);
  }
});

test('dogrulama: service_user_id zorunlu (undefined 400), gecersiz kimlik 400, hedef service_user olmali / aktif olmali', async () => {
  const { svc } = build({ users: {
    ['55555555-5555-4555-8555-555555555555']: { id: '55555555-5555-4555-8555-555555555555', role: 'user', is_active: true, account_status: 'active' },
    ['66666666-6666-4666-8666-666666666666']: { id: '66666666-6666-4666-8666-666666666666', role: 'service_user', is_active: false, account_status: 'suspended' },
  } });
  await rejects(svc.transferHome({ homeId: HOME, serviceUserId: undefined, actor: ROOT }), 400, 'VALIDATION');
  await rejects(svc.transferHome({ homeId: 'gecersiz', serviceUserId: SVC_NEW, actor: ROOT }), 400, 'VALIDATION');
  await rejects(svc.transferHome({ homeId: HOME, serviceUserId: 'x', actor: ROOT }), 400, 'VALIDATION');
  await rejects(svc.transferHome({ homeId: HOME, serviceUserId: '55555555-5555-4555-8555-555555555555', actor: ROOT }), 404, 'NOT_FOUND');
  await rejects(svc.transferHome({ homeId: HOME, serviceUserId: '77777777-7777-4777-8777-777777777777', actor: ROOT }), 404, 'NOT_FOUND');
  await rejects(svc.transferHome({ homeId: HOME, serviceUserId: '66666666-6666-4666-8666-666666666666', actor: ROOT }), 409, 'CONFLICT');
});

test('ev aktarimi: ev + kartlar + uyelikler; eski servis MQTT/anahtar/cihaz kimligi donar; yeni servis suresiz uyelik; denetim', async () => {
  const { svc, log, state, extra } = build();
  const out = await svc.transferHome({ homeId: HOME, serviceUserId: SVC_NEW, actor: ROOT });
  assert.strictEqual(out.changed, true);
  assert.strictEqual(out.service_owner_id, SVC_NEW);
  assert.strictEqual(out.previous_service_owner_id, SVC_OLD);
  assert.strictEqual(out.cards_moved, 2);
  assert.strictEqual(state.homeOwner, SVC_NEW);
  assert.deepStrictEqual(extra.revoked, [SVC_OLD], 'eski servisin uygulama MQTT kimligi iptal');
  assert.deepStrictEqual(extra.kicked, [`a_${SVC_OLD}`]);
  assert.deepStrictEqual(extra.rotations, [[HOME, 'service_changed']]);
  assert.deepStrictEqual(extra.credRot, [[HOME, 'service_changed']]);
  assert.ok(log.some((l) => l.sql.startsWith('INSERT INTO home_users') && l.sql.includes("'service_user', NULL")), 'yeni servise suresiz uyelik');
  const audit = log.find((l) => l.sql.startsWith('INSERT INTO device_audit_logs'));
  assert.strictEqual(audit.params[0], 'home_service_owner_changed');
  assert.strictEqual(audit.params[4], 'super_user');
  assert.deepStrictEqual(JSON.parse(audit.params[6]), { from: SVC_OLD, to: SVC_NEW, cards_moved: 2 });
});

test('ev aktarimi: ayni kapsam no-op (yazim yok); koke alma (null) uyelikleri kaldirir ve yeni uyelik acmaz', async () => {
  const same = build();
  const r = await same.svc.transferHome({ homeId: HOME, serviceUserId: SVC_OLD, actor: ROOT });
  assert.strictEqual(r.changed, false);
  assert.ok(!same.log.some((l) => /^(UPDATE|INSERT|DELETE)/.test(l.sql)), 'no-op: yazim yok');

  const toRoot = build();
  const r2 = await toRoot.svc.transferHome({ homeId: HOME, serviceUserId: null, actor: ROOT });
  assert.strictEqual(r2.changed, true);
  assert.strictEqual(r2.service_owner_id, null);
  assert.strictEqual(toRoot.state.homeOwner, null);
  assert.ok(!toRoot.log.some((l) => l.sql.startsWith('INSERT INTO home_users')), 'koke alirken uyelik acilmaz');
  assert.deepStrictEqual(toRoot.extra.revoked, [SVC_OLD]);

  const rootToRoot = build({ homeOwner: null });
  assert.strictEqual((await rootToRoot.svc.transferHome({ homeId: HOME, serviceUserId: null, actor: ROOT })).changed, false);
});

test('kart aktarimi: kurulu / daireye bagli kart 409; stoktaki kart aktarilir; site aktarimi: silinmis/olmayan site 404', async () => {
  const installed = build({ card: { id: 'c1', status: 'CLAIMED', claimed_home_id: HOME, service_owner_id: SVC_OLD, attached: 1 } });
  await rejects(installed.svc.transferInventory({ deviceUuid: 'ahbu-s3-0001', serviceUserId: SVC_NEW, actor: ROOT }), 409, 'CONFLICT');
  await rejects(installed.svc.transferInventory({ deviceUuid: 'gecersiz', serviceUserId: SVC_NEW, actor: ROOT }), 400, 'VALIDATION');
  const stock = build({ card: { id: 'c2', status: 'IN_STOCK', claimed_home_id: null, service_owner_id: null, attached: 0 } });
  const out = await stock.svc.transferInventory({ deviceUuid: 'AHBU-S3-0001', serviceUserId: SVC_NEW, actor: ROOT });
  assert.deepStrictEqual([out.changed, out.service_owner_id, out.previous_service_owner_id], [true, SVC_NEW, null]);
  assert.ok(stock.log.some((l) => l.sql.startsWith('UPDATE device_inventory SET service_owner_id = $2, updated_at')));
  await rejects(build().svc.transferInventory({ deviceUuid: 'AHBU-S3-0001', serviceUserId: SVC_NEW, actor: ROOT }), 404, 'NOT_FOUND');

  await rejects(build().svc.transferSite({ siteId: SITE, serviceUserId: SVC_NEW, actor: ROOT }), 404, 'NOT_FOUND');
  const withSite = build({ site: { id: SITE, name: 'S', service_owner_id: null } });
  const so = await withSite.svc.transferSite({ siteId: SITE, serviceUserId: SVC_NEW, actor: ROOT });
  assert.deepStrictEqual([so.changed, so.service_owner_id], [true, SVC_NEW]);
  assert.ok(withSite.log.some((l) => l.sql.startsWith('UPDATE sites SET service_owner_id')));
});
