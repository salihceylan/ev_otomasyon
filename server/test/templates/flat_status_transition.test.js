'use strict';

// servis_kurulum-10 + atolye-7 (sahte db; gercek PostgreSQL karsiligi site_flats_g2_pg.test.js):
//   - daire durumu yalniz ileri (planned -> written -> installed -> handed_over); ayni durum serbest
//   - installed / handed_over icin daireye kart bagli olmali
//   - geri alma yalniz super_user; aksi 409 INVALID_STATUS_TRANSITION 'Daire durumu bu şekilde değiştirilemez.'
//   - sablon degisince 'written' -> 'planned' (installed / handed_over'a dokunulmaz)

const test = require('node:test');
const assert = require('node:assert/strict');

const { SiteTemplateService } = require('../../src/services/site_template_service');

const SITE = '11111111-2222-4333-8444-555555555555';
const FLAT = '8c1d2e3f-4a5b-4c6d-8e7f-0123456789ab';
const TPL_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const TPL_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const STAFF = { userId: 'u-staff', globalRole: 'service_user' };
const SUPER = { userId: 'u-super', globalRole: 'super_user' };

function makeSvc(flat) {
  const updates = [];
  const q = async (text, params) => {
    const sql = String(text).replace(/\s+/g, ' ').trim();
    if (sql.startsWith('SELECT id, name FROM sites WHERE id = $1')) return { rows: [{ id: SITE, name: 'S' }] };
    if (sql.startsWith('SELECT id, site_id FROM install_templates WHERE id = $1')) return { rows: [{ id: params[0], site_id: SITE }] };
    if (sql.startsWith('SELECT id, site_id, block, number, flat_type, template_id, device_uuid, status FROM site_flats WHERE id = $1 AND site_id = $2 FOR UPDATE')) {
      return { rows: [{ ...flat }] };
    }
    if (sql.startsWith('UPDATE site_flats SET')) {
      updates.push({ sql, params });
      const cols = sql.slice('UPDATE site_flats SET '.length, sql.indexOf(', updated_at')).split(', ').map((x) => x.split(' = ')[0]);
      cols.forEach((c, i) => { flat[c] = params[i + 1]; });
      return { rows: [], rowCount: 1 };
    }
    if (sql.includes('FROM site_flats f')) return { rows: [{ ...flat, site_id: SITE, lw_template_id: null, lok_version: null }] };
    throw new Error(`beklenmeyen sorgu: ${sql.slice(0, 80)}`);
  };
  const db = { query: q, withTransaction: async (fn) => fn({ query: q }) };
  return { svc: new SiteTemplateService({ db }), updates, flat };
}

async function rejects(p, status, code) {
  let err = null;
  try {
    await p;
  } catch (e) {
    err = e;
  }
  assert.ok(err, 'hata bekleniyordu');
  assert.equal(err.status, status, err.message);
  assert.equal(err.code, code);
  return err;
}

const base = (over = {}) => ({ id: FLAT, site_id: SITE, block: 'A', number: '1', flat_type: '2+1', template_id: TPL_A, device_uuid: null, status: 'planned', ...over });

test('ileri gecis serbest (atlayarak da); ayni durum serbest', async () => {
  const { svc, flat } = makeSvc(base());
  assert.equal((await svc.updateFlat(SITE, FLAT, { status: 'written' }, STAFF)).status, 'written');
  assert.equal((await svc.updateFlat(SITE, FLAT, { status: 'written' }, STAFF)).status, 'written');
  flat.device_uuid = 'AHBU-S3-0001';
  assert.equal((await svc.updateFlat(SITE, FLAT, { status: 'handed_over' }, STAFF)).status, 'handed_over');
});

test('geri alma yalniz super_user; aksi 409 INVALID_STATUS_TRANSITION (Turkce mesaj)', async () => {
  const { svc } = makeSvc(base({ status: 'installed', device_uuid: 'AHBU-S3-0001' }));
  const e = await rejects(svc.updateFlat(SITE, FLAT, { status: 'written' }, STAFF), 409, 'INVALID_STATUS_TRANSITION');
  assert.equal(e.message, 'Daire durumu bu şekilde değiştirilemez.');
  await rejects(svc.updateFlat(SITE, FLAT, { status: 'planned' }), 409, 'INVALID_STATUS_TRANSITION');
  assert.equal((await svc.updateFlat(SITE, FLAT, { status: 'planned' }, SUPER)).status, 'planned');
});

test('installed / handed_over icin kart sart (super icin de)', async () => {
  const { svc, updates } = makeSvc(base({ status: 'written' }));
  await rejects(svc.updateFlat(SITE, FLAT, { status: 'installed' }, STAFF), 409, 'INVALID_STATUS_TRANSITION');
  await rejects(svc.updateFlat(SITE, FLAT, { status: 'handed_over' }, SUPER), 409, 'INVALID_STATUS_TRANSITION');
  assert.equal(updates.length, 0, 'hicbir yazim yok');
});

test('atolye-7: sablon degisince written -> planned; installed korunur; ayni sablon ya da planned dokunulmaz', async () => {
  let s = makeSvc(base({ status: 'written' }));
  assert.equal((await s.svc.updateFlat(SITE, FLAT, { template_id: TPL_B }, STAFF)).status, 'planned');
  assert.match(s.updates[0].sql, /status = \$\d/);
  s = makeSvc(base({ status: 'installed', device_uuid: 'AHBU-S3-0001' }));
  assert.equal((await s.svc.updateFlat(SITE, FLAT, { template_id: TPL_B }, STAFF)).status, 'installed');
  s = makeSvc(base({ status: 'written' }));
  assert.equal((await s.svc.updateFlat(SITE, FLAT, { template_id: TPL_A }, STAFF)).status, 'written', 'ayni sablon');
});
