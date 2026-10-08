'use strict';

// Faz 1 / IP-1.1: migration 035 GERCEK PostgreSQL'de (yalitilmis gecici veritabani; paylasilan veritabaninda DDL kosulmaz):
// migrate.js 001..035, ardindan 035 dosyasi IKI KEZ daha elle calistirilir; surum satiri degismez (UPDATE/DELETE red),
// kullanici silinince created_by NULL olur, CHECK kumeleri (durum, via, sonuc) ve tek-daire-tek-kart kisiti calisir.
// Varsayilan olarak ATLANIR. Etkinlestirmek: EV_PG_TEST_URL=postgresql://... (CREATE DATABASE yetkisi gerekir).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const URL_ = process.env.EV_PG_TEST_URL;
const SKIP = URL_ ? false : 'EV_PG_TEST_URL tanimli degil (gercek PostgreSQL gerekir)';
const SQL_FILE = path.join(__dirname, '..', '..', 'migrations', '035_sites_templates.sql');

function withDatabase(url, name) {
  const u = new URL(url);
  u.pathname = `/${name}`;
  return u.toString();
}

async function admin(fn) {
  const { Client } = require('pg');
  const c = new Client({ connectionString: URL_, connectionTimeoutMillis: 15000 });
  await c.connect();
  try {
    return await fn(c);
  } finally {
    await c.end().catch(() => {});
  }
}

test('035 gercek PG: migrate.js + dosya iki kez daha; degismez surum, SET NULL, CHECK ve benzersizlik', { skip: SKIP }, async () => {
  const base = new URL(URL_).pathname.replace(/^\//, '') || 'postgres';
  const name = `${base}_t035_${process.pid}`.toLowerCase().replace(/[^a-z0-9_]/g, '_').slice(0, 60);
  let created = false;
  try {
    created = await admin(async (c) => {
      await c.query(`DROP DATABASE IF EXISTS ${name}`);
      await c.query(`CREATE DATABASE ${name}`);
      return true;
    }).catch(() => false);
    if (!created) return;
    const url = withDatabase(URL_, name);
    const { main } = require('../../scripts/migrate');
    const env = { DATABASE_URL: url, MIGRATE_CONFIRM: name };
    assert.equal(await main({ argv: [], env, log: () => {}, errLog: () => {} }), 0, 'ilk kurulum');

    const { Client } = require('pg');
    const c = new Client({ connectionString: url });
    await c.connect();
    try {
      const applied = await c.query("SELECT name FROM schema_migrations WHERE name LIKE '035%'");
      assert.deepEqual(applied.rows.map((r) => r.name), ['035_sites_templates.sql']);

      const sql = fs.readFileSync(SQL_FILE, 'utf8');
      const user = (await c.query("INSERT INTO users (full_name, email, password_hash, role) VALUES ('S', 's035@example.test', 'x', 'service_user') RETURNING id")).rows[0];
      const site = (await c.query("INSERT INTO sites (name, created_by) VALUES ('Güneş Sitesi', $1) RETURNING id", [user.id])).rows[0];
      const tpl = (await c.query("INSERT INTO install_templates (site_id, name, flat_type, current_version, created_by) VALUES ($1, 'A', '2+1', 1, $2) RETURNING id", [site.id, user.id])).rows[0];
      await c.query("INSERT INTO install_template_versions (template_id, version, body, sha256, created_by) VALUES ($1, 1, '{\"a\":1}', $2, $3)", [tpl.id, 'a'.repeat(64), user.id]);
      await c.query("INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model) VALUES ('AHBU-T035-1', 'E8:F6:0A:35:35:01', 'x', 'M')");

      // Iki kez daha: idempotent, veri korunur
      for (let i = 0; i < 2; i += 1) {
        await c.query('BEGIN');
        await c.query(sql);
        await c.query('COMMIT');
      }
      assert.equal((await c.query('SELECT COUNT(*)::int AS n FROM install_template_versions')).rows[0].n, 1);
      const trg = await c.query("SELECT COUNT(*)::int AS n FROM pg_trigger WHERE tgname = 'trg_install_template_versions_immutable'");
      assert.equal(trg.rows[0].n, 1, 'tek tetikleyici');

      // Degismezlik
      await assert.rejects(c.query("UPDATE install_template_versions SET body = '{\"a\":2}' WHERE template_id = $1", [tpl.id]), (e) => e.code === '55000');
      await assert.rejects(c.query('DELETE FROM install_template_versions WHERE template_id = $1', [tpl.id]), (e) => e.code === '55000');

      // Daire + yazim
      const flat = (await c.query("INSERT INTO site_flats (site_id, block, number, template_id, device_uuid) VALUES ($1, 'A', '12', $2, 'AHBU-T035-1') RETURNING id, status", [site.id, tpl.id])).rows[0];
      assert.equal(flat.status, 'planned');
      await assert.rejects(c.query("INSERT INTO site_flats (site_id, block, number, device_uuid) VALUES ($1, 'A', '13', 'AHBU-T035-1')", [site.id]), (e) => e.code === '23505', 'bir kart bir daire');
      await assert.rejects(c.query("INSERT INTO site_flats (site_id, block, number) VALUES ($1, 'A', '12')", [site.id]), (e) => e.code === '23505', 'blok+no benzersiz');
      await assert.rejects(c.query("UPDATE site_flats SET status = 'bogus' WHERE id = $1", [flat.id]), (e) => e.code === '23514');
      for (const via of ['usb', 'eth', 'lan']) {
        await c.query("INSERT INTO template_writes (device_uuid, template_id, version, flat_id, via, result, written_by) VALUES ('AHBU-T035-1', $1, 1, $2, $3, 'ok', $4)", [tpl.id, flat.id, via, user.id]);
      }
      await assert.rejects(c.query("INSERT INTO template_writes (device_uuid, template_id, version, via, result) VALUES ('X', $1, 1, 'wifi', 'ok')", [tpl.id]), (e) => e.code === '23514');
      await assert.rejects(c.query("INSERT INTO template_writes (device_uuid, template_id, version, via, result) VALUES ('X', $1, 9, 'usb', 'ok')", [tpl.id]), (e) => e.code === '23503', 'surum FK');

      // Kullanici silinince surum satiri kalir, created_by NULL (tetikleyici istisnasi)
      await c.query('DELETE FROM users WHERE id = $1', [user.id]);
      const v = await c.query('SELECT created_by, body FROM install_template_versions WHERE template_id = $1', [tpl.id]);
      assert.equal(v.rows[0].created_by, null);
      assert.deepEqual(v.rows[0].body, { a: 1 });

      // devices.template_version CHECK
      await assert.rejects(c.query("INSERT INTO devices (device_uuid, mac_address, template_version) VALUES ('AHBU-T035-2', 'E8:F6:0A:35:35:02', 0)"), (e) => e.code === '23514');
      await c.query("INSERT INTO devices (device_uuid, mac_address, template_id, template_version) VALUES ('AHBU-T035-3', 'E8:F6:0A:35:35:03', $1, 4)", [tpl.id]);
    } finally {
      await c.end().catch(() => {});
    }
  } finally {
    if (created) await admin((c) => c.query(`DROP DATABASE IF EXISTS ${name}`)).catch(() => {});
  }
});
