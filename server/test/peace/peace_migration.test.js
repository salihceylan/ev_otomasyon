'use strict';

// WP-H / evaluator - STATIK migration testi (030_peace_reminder.sql). Gercek veritabani YOK:
// dosya okunur; idempotent ifadeler, BEGIN/COMMIT yoklugu, beklenen sutun/indeks/tablo adlari,
// `homes` tablosuna ALTER olmamasi ve degerlendirici SQL'inin kullandigi sutunlarin tanimi denetlenir.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { SQL: REMINDER_SQL } = require('../../src/peace_reminder');

const DIR = path.join(__dirname, '..', '..', 'migrations');
const FILE = '030_peace_reminder.sql';
const raw = fs.readFileSync(path.join(DIR, FILE), 'utf8');

/** `-- ...` satir yorumlarini atar (dize icinde `--` kullanmiyoruz). */
const code = raw.replace(/--.*$/gm, '');
const statements = code
  .split(';')
  .map((s) => s.replace(/\s+/g, ' ').trim())
  .filter(Boolean);

test('numara: 030 yalnizca bu dosyada, 025\'ten sonra; baska 030 onekli migration yok', () => {
  const names = fs.readdirSync(DIR).filter((n) => /\.sql$/.test(n));
  assert.deepEqual(names.filter((n) => n.startsWith('030')), [FILE]);
  assert.ok(names.includes('025_child_lock_and_peace_constraints.sql'), 'onkosul 025 mevcut');
  assert.ok(names.sort().indexOf(FILE) > names.indexOf('025_child_lock_and_peace_constraints.sql'));
});

test('baslik: IDEMPOTENT ve BEGIN/COMMIT YOK notu; kod govdesinde islem kontrolu yok', () => {
  const head = raw.split('\n').slice(0, 8).join('\n');
  assert.match(head, /IDEMPOTENT/);
  assert.match(head, /BEGIN\/COMMIT YOKTUR/);
  assert.doesNotMatch(code, /\b(BEGIN|COMMIT|ROLLBACK|START\s+TRANSACTION)\b/i);
  try {
    const { findTransactionControl } = require('../../scripts/migrate');
    assert.deepEqual(findTransactionControl(raw), []);
  } catch (err) {
    if (err && err.code === 'MODULE_NOT_FOUND') return; // calistirici henuz yok: yukaridaki denetim yeterli
    throw err;
  }
});

test('idempotent: her ADD COLUMN / CREATE TABLE / CREATE INDEX "IF NOT EXISTS" tasir', () => {
  for (const s of statements) {
    if (/^ALTER TABLE \S+ ADD COLUMN/i.test(s)) assert.match(s, /ADD COLUMN IF NOT EXISTS/i, s);
    if (/^CREATE (UNIQUE )?INDEX/i.test(s)) assert.match(s, /INDEX IF NOT EXISTS/i, s);
    if (/^CREATE TABLE/i.test(s)) assert.match(s, /^CREATE TABLE IF NOT EXISTS/i, s);
  }
  assert.ok(statements.filter((s) => /ADD COLUMN/i.test(s)).length >= 11);
});

test('kisitlar: DROP CONSTRAINT IF EXISTS -> ADD ... NOT VALID -> VALIDATE sirasi', () => {
  for (const [table, name] of [
    ['peace_notification_logs', 'peace_logs_status_check'],
    ['push_tokens', 'push_tokens_platform_check'],
  ]) {
    const drop = statements.findIndex((s) => s === `ALTER TABLE ${table} DROP CONSTRAINT IF EXISTS ${name}`);
    const add = statements.findIndex((s) => s.startsWith(`ALTER TABLE ${table} ADD CONSTRAINT ${name}`));
    const validate = statements.findIndex((s) => s === `ALTER TABLE ${table} VALIDATE CONSTRAINT ${name}`);
    assert.ok(drop >= 0 && add > drop && validate > add, `${name}: drop < add < validate`);
    assert.match(statements[add], /NOT VALID$/);
  }
  const status = statements.find((s) => s.startsWith('ALTER TABLE peace_notification_logs ADD CONSTRAINT peace_logs_status_check'));
  for (const v of ['manual', 'claimed', 'sending', 'clear', 'sent', 'no_recipients', 'skipped_offline', 'failed', 'resolved']) {
    assert.ok(status.includes(`'${v}'`), `durum ${v}`);
  }
  // degerlendiricinin yazdigi her durum (markSending dahil) CHECK kumesinde ve VARCHAR(20)'ye sigar
  const allowed = [...status.matchAll(/'([a-z_]+)'/g)].map((m) => m[1]);
  assert.match(REMINDER_SQL.markSending, /SET status = 'sending'/);
  assert.ok(allowed.includes('sending'));
  for (const v of allowed) assert.ok(v.length <= 20, v);
});

test('peace_notification_logs: beklenen yeni sutunlar, tipler, NULL/DEFAULT ve FK', () => {
  const col = (name) => statements.find((s) => new RegExp(`^ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS ${name} `, 'i').test(s));
  const expected = {
    local_date: /DATE$/i,
    scheduled_for: /TIMESTAMPTZ$/i,
    status: /VARCHAR\(20\) NOT NULL DEFAULT 'manual'$/i,
    attempts: /SMALLINT NOT NULL DEFAULT 0$/i,
    details: /JSONB$/i,
    push_sent_count: /INTEGER NOT NULL DEFAULT 0$/i,
    evaluated_at: /TIMESTAMPTZ$/i,
    resolved_by_user_id: /UUID REFERENCES users\(id\) ON DELETE SET NULL$/i,
    resolved_via: /VARCHAR\(16\)$/i,
    command_id: /VARCHAR\(32\)$/i,
    updated_at: /TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP$/i,
  };
  for (const [name, re] of Object.entries(expected)) {
    const s = col(name);
    assert.ok(s, `sutun yok: ${name}`);
    assert.match(s, re, name);
  }
  // rolling deploy: eski INSERT yeni sutunlari vermez -> NOT NULL olanlarin hepsi DEFAULT'lu
  for (const s of statements.filter((x) => /ADD COLUMN/i.test(x) && /NOT NULL/i.test(x))) assert.match(s, /DEFAULT/i, s);
  assert.equal(col('local_date').includes('NOT NULL'), false, 'local_date NULL olabilir (elle kapatma satirlari)');
});

test('UNIQUE (home_id, local_date) KISMI DEGIL (ON CONFLICT cikarimi icin) ve (home_id, triggered_at DESC) indeksi', () => {
  const uq = statements.find((s) => /ux_peace_logs_home_date/.test(s));
  assert.equal(uq, 'CREATE UNIQUE INDEX IF NOT EXISTS ux_peace_logs_home_date ON peace_notification_logs (home_id, local_date)');
  assert.doesNotMatch(uq, /WHERE/i, 'kismi indeks ON CONFLICT (home_id, local_date) ile eslesmez');
  const idx = statements.find((s) => /idx_peace_logs_home_triggered/.test(s));
  assert.equal(idx, 'CREATE INDEX IF NOT EXISTS idx_peace_logs_home_triggered ON peace_notification_logs (home_id, triggered_at DESC)');
  // talep sorgusu bu anahtara dayanir
  assert.match(REMINDER_SQL.claim, /ON CONFLICT \(home_id, local_date\)/);
});

test('push_tokens: sutunlar, UNIQUE(token), platform kisiti, kismi indeks', () => {
  const create = statements.find((s) => /^CREATE TABLE IF NOT EXISTS push_tokens/i.test(s));
  assert.ok(create);
  for (const piece of [
    'id UUID PRIMARY KEY DEFAULT gen_random_uuid()',
    'user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE',
    'token VARCHAR(512) NOT NULL',
    'platform VARCHAR(10) NOT NULL',
    'app_version VARCHAR(32)',
    'created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP',
    'last_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP',
    'disabled_at TIMESTAMPTZ',
    'CONSTRAINT uq_push_tokens_token UNIQUE (token)',
  ]) {
    assert.ok(create.includes(piece), `eksik: ${piece}`);
  }
  const plat = statements.find((s) => s.startsWith('ALTER TABLE push_tokens ADD CONSTRAINT push_tokens_platform_check'));
  assert.match(plat, /CHECK \(platform IN \('android', 'ios'\)\)/);
  assert.ok(statements.includes('CREATE INDEX IF NOT EXISTS idx_push_tokens_user_active ON push_tokens (user_id) WHERE disabled_at IS NULL'));
});

test('kapsam siniri: homes/devices/users tablolarina ALTER YOK; veri silen/degistiren ifade YOK', () => {
  for (const s of statements) {
    assert.doesNotMatch(s, /^ALTER TABLE (IF EXISTS )?(ONLY )?(public\.)?(homes|devices|users|endpoints|home_users)\b/i, s);
    assert.doesNotMatch(s, /^(DELETE|UPDATE|TRUNCATE|DROP TABLE|DROP COLUMN|INSERT)\b/i, s);
    assert.doesNotMatch(s, /\bDROP COLUMN\b/i, s);
  }
  // yalnizca bu iki tabloya dokunur
  const tables = new Set();
  for (const s of statements) {
    const m = /^(?:ALTER TABLE|CREATE TABLE IF NOT EXISTS|COMMENT ON TABLE)\s+(\w+)/i.exec(s);
    if (m) tables.add(m[1].toLowerCase());
  }
  assert.deepEqual([...tables].sort(), ['peace_notification_logs', 'push_tokens']);
});

test('degerlendirici SQL\'inin yazdigi/okudugu peace_notification_logs sutunlari (010 + 030) tanimli', () => {
  const base = fs.readFileSync(path.join(DIR, '010_night_peace_and_child_lock.sql'), 'utf8');
  const known = new Set(['id', 'home_id', 'triggered_at', 'open_lights_count', 'open_shutters_count', 'summary_text', 'resolved_by_user', 'resolved_at']);
  assert.ok(/CREATE TABLE IF NOT EXISTS peace_notification_logs/.test(base));
  for (const m of code.matchAll(/ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS (\w+)/g)) known.add(m[1]);

  const used = new Set();
  const collect = (sql, re) => {
    for (const m of sql.matchAll(re)) used.add(m[1]);
  };
  // INSERT sutun listesi
  const ins = /INSERT INTO peace_notification_logs \(([^)]*)\)/.exec(REMINDER_SQL.claim);
  ins[1].split(',').forEach((c) => used.add(c.trim()));
  collect(REMINDER_SQL.claim, /peace_notification_logs\.(\w+)/g);
  collect(REMINDER_SQL.finish, /\b(status|open_lights_count|open_shutters_count|summary_text|details|push_sent_count|evaluated_at|updated_at|attempts)\s*=/g);
  collect(REMINDER_SQL.candidates, /\bl\.(\w+)/g);
  collect(REMINDER_SQL.purgeLogs, /WHERE (\w+) </g);
  assert.ok(used.size >= 12, `yeterli kapsam: ${[...used].join(',')}`);
  for (const c of used) assert.ok(known.has(c), `peace_notification_logs.${c} migration'larda tanimli degil`);
});

test('degerlendirici ve snapshot SQL\'i push_tokens/homes sutunlarini 025-030 sonrasi semayla kullanir', () => {
  // zones/candidates: homes.timezone (022), peace_notification_enabled/time (010/025)
  for (const col of ['timezone', 'peace_notification_enabled', 'peace_notification_time']) {
    assert.match(REMINDER_SQL.candidates, new RegExp(`h\\.${col}`));
  }
  // oz-denetim bu migration'in olusturdugu varlıkları gerektirir
  const { helpers } = require('../../src/peace_reminder');
  for (const [table, cols] of Object.entries(helpers.REQUIRED_SCHEMA)) {
    for (const c of cols) {
      const defined =
        table === 'homes' ||
        (table === 'push_tokens' && new RegExp(`\\b${c}\\b`).test(code)) ||
        (table === 'peace_notification_logs' && new RegExp(`ADD COLUMN IF NOT EXISTS ${c}\\b`).test(code));
      assert.ok(defined, `${table}.${c} 030 tarafindan olusturulmuyor`);
    }
  }
});
