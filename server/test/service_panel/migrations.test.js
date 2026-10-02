'use strict';

// WP-B2: migration 027 (hesap silme), 028 (Home Admin atama), 029 (etiket yeniden uretimi) - STATIK denetimler.
// (Gercek PostgreSQL davranisi `pg_live.test.js` ile ve `scripts/migrate.js` ile dogrulanir; burada yalnizca
// idempotentlik, calistirici uyumu, sir yoklugu ve kod <-> sema sozlesmesi denetlenir.)

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const migrate = require('../../scripts/migrate');
const contract = require('../../scripts/lib/sql_contract');
const { check, loadSchema, formatViolation } = require('../../scripts/check_schema_contract');

const DIR = path.join(__dirname, '..', '..', 'migrations');
const FILES = ['027_account_deletion.sql', '028_home_admin_assignment.sql', '029_inventory_label_reissue.sql'];
const read = (f) => fs.readFileSync(path.join(DIR, f), 'utf8');
const stripComments = (sql) => sql.replace(/--[^\n]*/g, '');

function splitStatements(sql) {
  const clean = stripComments(sql);
  const out = [];
  let cur = '';
  let inStr = false;
  for (let i = 0; i < clean.length; i++) {
    const ch = clean[i];
    if (ch === "'") inStr = !inStr;
    if (!inStr && ch === ';') {
      if (cur.trim()) out.push(cur.trim());
      cur = '';
    } else cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return { statements: out, balancedQuote: !inStr };
}

for (const file of FILES) {
  test(`${file}: sözdizimi sağlığı, BEGIN/COMMIT yok (çalıştırıcı tek transaction'da çalıştırır), IDEMPOTENT notu`, () => {
    const sql = read(file);
    const { statements, balancedQuote } = splitStatements(sql);
    assert.ok(balancedQuote, 'tırnak dengesiz');
    assert.ok(statements.length >= 2);
    for (const stmt of statements) {
      let depth = 0;
      for (const ch of stmt.replace(/'(?:[^']|'')*'/g, "''")) {
        if (ch === '(') depth++;
        if (ch === ')') depth--;
        assert.ok(depth >= 0, `fazla ')' : ${stmt.slice(0, 80)}`);
      }
      assert.equal(depth, 0, `parantez dengesiz: ${stmt.slice(0, 80)}`);
      assert.match(stmt, /^(CREATE|ALTER|UPDATE|DELETE|DROP|COMMENT)\b/i, `beklenmeyen ifade: ${stmt.slice(0, 60)}`);
    }
    assert.ok(!/^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im.test(stripComments(sql)));
    assert.ok(/IDEMPOTENT/i.test(sql));
    // çalıştırıcı uyumu
    assert.deepEqual(migrate.findTransactionControl(sql), []);
    assert.equal(migrate.stripTransactionWrapper(sql).stripped, false);
    assert.equal(migrate.hasNoTransactionDirective(sql), false);
  });

  test(`${file}: IDEMPOTENT - CREATE/ADD COLUMN/INDEX IF NOT EXISTS; DROP IF EXISTS; kısıt ekleme öncesinde aynı adlı DROP`, () => {
    const sql = read(file);
    const { statements } = splitStatements(sql);
    for (const stmt of statements) {
      if (/^CREATE\s+(UNIQUE\s+)?(TABLE|INDEX)\b/i.test(stmt)) assert.match(stmt, /\bIF\s+NOT\s+EXISTS\b/i, stmt.slice(0, 80));
      if (/^ALTER\s+TABLE\b/i.test(stmt) && /\bADD\s+COLUMN\b/i.test(stmt)) assert.match(stmt, /\bADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\b/i, stmt.slice(0, 80));
      if (/^DROP\b/i.test(stmt)) assert.match(stmt, /\bIF\s+EXISTS\b/i, stmt.slice(0, 80));
      const add = /^ALTER\s+TABLE\s+(\w+)\s+ADD\s+CONSTRAINT\s+(\w+)/i.exec(stmt);
      if (add) {
        assert.ok(
          new RegExp(`ALTER\\s+TABLE\\s+${add[1]}\\s+DROP\\s+CONSTRAINT\\s+IF\\s+EXISTS\\s+${add[2]}\\b`, 'i').test(stripComments(sql)),
          `${add[2]}: ADD CONSTRAINT öncesinde DROP CONSTRAINT IF EXISTS yok (yeniden çalıştırmada hata verir)`
        );
      }
    }
  });

  test(`${file}: sır/parola/anahtar/özet DEĞERİ içermez`, () => {
    const sql = read(file);
    assert.ok(!/\$2[aby]\$\d\d\$/.test(sql), 'bcrypt özeti yok');
    assert.ok(!/\b[0-9a-f]{64}\b/i.test(sql), '64 onaltılık özet değeri yok');
    assert.ok(!/password\s*=\s*'[^']{6,}'/i.test(sql));
    assert.ok(!/\bh1\$[0-9a-f]{8,}/i.test(sql), 'PIN özeti değeri yok');
  });
}

test('numaralandırma: 027-029 mevcut ve çalıştırıcı bunları 026\'dan sonra, (030\'dan önce) sıralı listeler', () => {
  const files = migrate.listMigrationFiles(DIR).map((f) => f.name);
  for (const f of FILES) assert.ok(files.includes(f), f);
  assert.ok(files.indexOf('026_devices_heartbeat_hot_updates.sql') < files.indexOf(FILES[0]));
  assert.ok(files.indexOf(FILES[2]) < files.indexOf('030_peace_reminder.sql'));
  const versions = migrate.listMigrationFiles(DIR).map((f) => f.version);
  for (const v of [27, 28, 29]) assert.equal(versions.filter((x) => x === v).length, 1, `${v} numarası tek`);
});

test('027: users.deleted_at + account_status CHECK (018 kümesi + deleted) + tutarlılık CHECK + kısmi indeks', () => {
  const sql = read('027_account_deletion.sql');
  assert.match(sql, /ALTER TABLE users ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ/);
  assert.match(sql, /CHECK \(account_status IN \('active', 'pending_invite', 'suspended', 'deleted'\)\)/);
  assert.match(sql, /CHECK \(\(account_status = 'deleted'\) = \(deleted_at IS NOT NULL\)\)/);
  assert.match(sql, /CREATE INDEX IF NOT EXISTS idx_users_deleted_at ON users \(deleted_at\) WHERE deleted_at IS NOT NULL/);
  // 018'deki durumlar korunur
  const m018 = /account_status IN \(([^)]*)\)/.exec(read('018_auth_hardening.sql'));
  for (const s of m018[1].split(',').map((x) => x.trim())) assert.ok(sql.includes(s), `${s} 018'de vardı; 027'de korunmalı`);
});

test('028: OTP tablosu (ev başına tek satır, hedefe bağlı, YALNIZCA özet) + atama günlüğü (mod CHECK, FK davranışları)', () => {
  const sql = read('028_home_admin_assignment.sql');
  assert.match(sql, /CREATE TABLE IF NOT EXISTS home_admin_assign_otps/);
  assert.match(sql, /home_id\s+UUID NOT NULL REFERENCES homes\(id\) ON DELETE CASCADE/);
  assert.match(sql, /owner_user_id\s+UUID REFERENCES users\(id\) ON DELETE CASCADE/);
  assert.match(sql, /requested_by\s+UUID REFERENCES users\(id\) ON DELETE SET NULL/);
  assert.match(sql, /target_identifier\s+VARCHAR\(255\) NOT NULL/);
  assert.match(sql, /otp_hash\s+VARCHAR\(255\) NOT NULL/);
  assert.match(sql, /CONSTRAINT uq_home_admin_assign_otps_home UNIQUE \(home_id\)/);
  assert.ok(!/\botp(_code)?\s+(VARCHAR|TEXT|CHAR)/i.test(stripComments(sql)), 'düz metin kod kolonu yok');
  assert.match(sql, /CREATE TABLE IF NOT EXISTS home_admin_assignment_logs/);
  assert.match(sql, /mode\s+VARCHAR\(20\) NOT NULL CHECK \(mode IN \('no_owner', 'owner_consent', 'forced'\)\)/);
  assert.match(sql, /home_id\s+UUID REFERENCES homes\(id\) ON DELETE SET NULL/);
  assert.match(sql, /actor_user_id\s+UUID REFERENCES users\(id\) ON DELETE SET NULL/);
  assert.match(sql, /previous_owner_ids\s+JSONB NOT NULL DEFAULT/);
});

test('029: device_inventory.label_reissued_at + label_reissue_count (NOT NULL DEFAULT 0); PIN/anahtar değeri kolonu YOK', () => {
  const sql = read('029_inventory_label_reissue.sql');
  assert.match(sql, /ALTER TABLE device_inventory ADD COLUMN IF NOT EXISTS label_reissued_at TIMESTAMPTZ/);
  assert.match(sql, /ALTER TABLE device_inventory ADD COLUMN IF NOT EXISTS label_reissue_count INT NOT NULL DEFAULT 0/);
  assert.ok(!/\b(pin|local_key)\s+(VARCHAR|TEXT)/i.test(stripComments(sql)));
});

test('şema yükleyicisi 027-029\'u okur (kod <-> migration sözleşmesi bunlara dayanır)', () => {
  const schema = loadSchema();
  assert.ok(schema.get('users').has('deleted_at'));
  for (const c of ['home_id', 'owner_user_id', 'target_identifier', 'target_name', 'otp_hash', 'expires_at', 'attempts', 'window_started_at', 'requested_by', 'created_at']) {
    assert.ok(schema.get('home_admin_assign_otps').has(c), `home_admin_assign_otps.${c}`);
  }
  for (const c of ['home_id', 'home_name', 'actor_user_id', 'actor_role', 'ip_address', 'mode', 'previous_owner_ids', 'new_owner_id', 'account_created', 'reason', 'created_at']) {
    assert.ok(schema.get('home_admin_assignment_logs').has(c), `home_admin_assignment_logs.${c}`);
  }
  assert.ok(schema.get('device_inventory').has('label_reissued_at') && schema.get('device_inventory').has('label_reissue_count'));
});

test('SÖZLEŞME: WP-B2 servis/rota SQL\'i migration şemasıyla UYUMLU (tablo/sütun var)', async () => {
  const r = await check();
  const mine = [...r.strict, ...r.advisory].filter((v) => /service_panel|account_deletion|join_preview|inventory_service|inventory_routes|auth_routes|auth_service/.test(v.where));
  assert.deepEqual(mine.map(formatViolation), []);
  // kapsam: kullandığımız sütunlar gerçekten denetim kapsamında
  const need = {
    home_admin_assign_otps: ['home_id', 'owner_user_id', 'target_identifier', 'otp_hash', 'attempts', 'window_started_at', 'requested_by'],
    home_admin_assignment_logs: ['mode', 'previous_owner_ids', 'new_owner_id', 'account_created', 'reason'],
    users: ['deleted_at', 'account_status', 'created_by_user_id', 'token_version'],
    device_inventory: ['label_reissued_at', 'label_reissue_count', 'pin_hash', 'local_key_enc'],
  };
  for (const [table, cols] of Object.entries(need)) {
    for (const c of cols) assert.ok(r.refs.get(table) && r.refs.get(table).has(c), `${table}.${c} sözleşme kapsamında değil`);
  }
  assert.ok(typeof contract.analyzeSql === 'function');
});

test('OLUMSUZ KONTROL: 027 olmasa hesap silme SQL\'i (users.deleted_at) YAKALANIR', async () => {
  const fsApi = {
    readdirSync: (dir, opts) => fs.readdirSync(dir, opts).filter((e) => e.name !== '027_account_deletion.sql'),
    readFileSync: fs.readFileSync,
  };
  const schema = contract.loadMigrationSchema(DIR, fsApi);
  schema.set('schema_migrations', new Set(['name', 'version', 'checksum', 'baseline', 'applied_at', 'execution_ms']));
  const r = await check({ schema });
  const found = [...r.strict, ...r.advisory].filter((v) => v.table === 'users' && v.column === 'deleted_at');
  assert.ok(found.length > 0, 'deleted_at eksikliği yakalanmalı');
  assert.ok(found.some((v) => /account_deletion/.test(v.where)));
});
