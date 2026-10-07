'use strict';

// WP-S1 - STATIK migration testi (033_safety_alarms.sql). Gercek veritabani YOK (gercek PostgreSQL davranisi:
// migration_033_pg.test.js). Tasarim: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md §5.2.1.
// Denetlenenler: numara/sira, baslik notlari, BEGIN/COMMIT yoklugu, UUID kimlik turleri [Y1][B5], idempotent ifadeler,
// CHECK'lerin NOT VALID + VALIDATE deseni, endpoints.type CHECK'ine DOKUNULMAMASI, mqtt_acl satirinin NOT EXISTS ile
// (ON CONFLICT degil; tabloda benzersiz kisit yok) ve kind='device' ile eklenmesi [O9], sema sozlesmesine girmesi.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SERVER = path.join(__dirname, '..', '..');
const DIR = path.join(SERVER, 'migrations');
const FILE = '033_safety_alarms.sql';
const PREV = '032_local_key_pending.sql';

function readRaw() {
  return fs.readFileSync(path.join(DIR, FILE), 'utf8');
}

/** Yorumlari atar, tek tirnakli dizeleri tanir, `;` ile boler; bosluklari teke indirir. */
function parseSql(sql) {
  const statements = [];
  let current = '';
  let i = 0;
  while (i < sql.length) {
    const c = sql[i];
    if (c === '-' && sql[i + 1] === '-') {
      const end = sql.indexOf('\n', i);
      i = end === -1 ? sql.length : end;
      continue;
    }
    if (c === "'") {
      let j = i + 1;
      for (;;) {
        const k = sql.indexOf("'", j);
        assert.ok(k > 0, 'kapanmamis dize');
        if (sql[k + 1] === "'") {
          j = k + 2;
          continue;
        }
        current += sql.slice(i, k + 1);
        i = k + 1;
        break;
      }
      continue;
    }
    if (c === ';') {
      statements.push(current);
      current = '';
      i += 1;
      continue;
    }
    current += c;
    i += 1;
  }
  statements.push(current);
  return statements.map((s) => s.replace(/\s+/g, ' ').trim()).filter(Boolean);
}

test('numara: 033 yalnizca bu dosyada; 032\'den hemen sonra; calistirici surum 33 olarak listeler', () => {
  const names = fs.readdirSync(DIR).filter((n) => /\.sql$/.test(n));
  assert.deepEqual(names.filter((n) => n.startsWith('033')), [FILE]);
  const sorted = names.slice().sort();
  assert.equal(sorted.indexOf(FILE), sorted.indexOf(PREV) + 1, '032 ile 033 arasinda baska dosya yok');
  const { listMigrationFiles, versionOf, planMigrations } = require('../../scripts/migrate');
  assert.equal(versionOf(FILE), 33);
  const files = listMigrationFiles(DIR);
  const upTo032 = files.filter((f) => f.version <= 32).map((f) => f.name);
  const plan = planMigrations(files, new Map(upTo032.map((n) => [n, { checksum: null, baseline: false }])));
  assert.equal(plan.pending[0].name, FILE);
  assert.deepEqual(plan.outOfOrder, []);
});

test('baslik: IDEMPOTENT, BEGIN/COMMIT YOK, kapsam/bagimlilik/rolling deploy; govdede islem kontrolu yok', () => {
  const raw = readRaw();
  const lines = raw.split('\n');
  assert.match(lines[1], /^-- Migration 033: .*\(WP-S1\)$/);
  const head = lines.slice(0, 8).join('\n');
  assert.match(head, /IDEMPOTENT/);
  assert.match(head, /BEGIN\/COMMIT YOKTUR/);
  assert.ok(head.includes(`psql -1 -v ON_ERROR_STOP=1 -f ${FILE}`));
  const header = raw.slice(0, raw.indexOf('CREATE TABLE'));
  assert.match(header, /^-- Kapsam$/m);
  assert.match(header, /^-- Bagimlilik/m);
  assert.match(header, /^-- Rolling deploy:/m);
  const { findTransactionControl, hasNoTransactionDirective } = require('../../scripts/migrate');
  assert.deepEqual(findTransactionControl(raw), []);
  assert.equal(hasNoTransactionDirective(raw), false, 'tek transaction icinde calisir');
});

test('tablolar: alarms / device_events / device_configs IF NOT EXISTS; kimlikler UUID ve CASCADE/SET NULL', () => {
  const statements = parseSql(readRaw());
  const table = (name) => statements.find((s) => s.startsWith(`CREATE TABLE IF NOT EXISTS ${name} (`));
  const alarms = table('alarms');
  assert.ok(alarms, 'alarms yok');
  assert.match(alarms, /home_id UUID NOT NULL REFERENCES homes\(id\) ON DELETE CASCADE/);
  assert.match(alarms, /device_id UUID NOT NULL REFERENCES devices\(id\) ON DELETE CASCADE/);
  assert.match(alarms, /acked_by UUID REFERENCES users\(id\) ON DELETE SET NULL/);
  assert.match(alarms, /ack_requested_by UUID REFERENCES users\(id\) ON DELETE SET NULL/);
  for (const col of ['aid', 'zone', 'kind', 'status', 'origin', 'sources', 'raised_at', 'device_epoch', 'acked_at',
    'ack_requested_at', 'cleared_at', 'cleared_by', 'push_status', 'push_attempts', 'fault_push_status', 'updated_at']) {
    assert.match(alarms, new RegExp(`\\b${col}\\b`), `alarms.${col} yok`);
  }
  assert.match(alarms, /CONSTRAINT alarms_device_aid_uniq UNIQUE \(device_id, aid\)/);
  assert.match(alarms, /CHECK \(zone BETWEEN 1 AND 4\)/);
  assert.match(alarms, /CONSTRAINT alarms_status_check CHECK \(status IN \('latched', 'fault', 'silenced', 'cleared', 'lost'\)\)/);
  assert.match(alarms, /CONSTRAINT alarms_origin_check CHECK \(origin IN \('event', 'state', 'tomb'\)\)/);

  const events = table('device_events');
  assert.ok(events, 'device_events yok');
  assert.match(events, /device_id UUID NOT NULL REFERENCES devices\(id\) ON DELETE CASCADE/);
  assert.match(events, /PRIMARY KEY \(device_id, eid\)/);

  const configs = table('device_configs');
  assert.ok(configs, 'device_configs yok');
  assert.match(configs, /device_id UUID NOT NULL REFERENCES devices\(id\) ON DELETE CASCADE/);
  assert.match(configs, /PRIMARY KEY \(device_id, module\)/);
  // BIGSERIAL disinda tamsayi kimlik (eski taslaktaki INT FK hatasi) YOK
  assert.doesNotMatch(readRaw(), /\b(home_id|device_id|user_id) (INT|INTEGER|BIGINT)\b/i);
});

test('kolonlar: devices.caps/safety_state, endpoints.actuator_type/dimmable/dimmer_source (ADD COLUMN IF NOT EXISTS)', () => {
  const adds = parseSql(readRaw()).filter((s) => /ADD COLUMN/i.test(s));
  assert.deepEqual(adds, [
    'ALTER TABLE devices ADD COLUMN IF NOT EXISTS caps JSONB',
    'ALTER TABLE devices ADD COLUMN IF NOT EXISTS safety_state JSONB',
    'ALTER TABLE endpoints ADD COLUMN IF NOT EXISTS actuator_type VARCHAR(10)',
    'ALTER TABLE endpoints ADD COLUMN IF NOT EXISTS dimmable BOOLEAN NOT NULL DEFAULT FALSE',
    'ALTER TABLE endpoints ADD COLUMN IF NOT EXISTS dimmer_source VARCHAR(8)',
  ]);
});

test('CHECK: endpoints eklerinde NOT VALID + VALIDATE (030 deseni); endpoints.type CHECK\'ine DOKUNULMAZ', () => {
  const statements = parseSql(readRaw());
  for (const name of ['endpoints_actuator_type_check', 'endpoints_dimmer_source_check']) {
    const drop = statements.findIndex((s) => s === `ALTER TABLE endpoints DROP CONSTRAINT IF EXISTS ${name}`);
    const add = statements.findIndex((s) => s.startsWith(`ALTER TABLE endpoints ADD CONSTRAINT ${name} CHECK`));
    const validate = statements.findIndex((s) => s === `ALTER TABLE endpoints VALIDATE CONSTRAINT ${name}`);
    assert.ok(drop >= 0 && add > drop && validate > add, `${name}: DROP IF EXISTS -> ADD NOT VALID -> VALIDATE`);
    assert.match(statements[add], /NOT VALID$/);
  }
  const act = statements.find((s) => s.startsWith('ALTER TABLE endpoints ADD CONSTRAINT endpoints_actuator_type_check'));
  assert.match(act, /actuator_type IS NULL OR actuator_type IN \('valve', 'siren', 'fan', 'generic'\)/);
  const dim = statements.find((s) => s.startsWith('ALTER TABLE endpoints ADD CONSTRAINT endpoints_dimmer_source_check'));
  assert.match(dim, /dimmer_source IS NULL OR dimmer_source IN \('modbus', 'bridge'\)/);
  for (const s of statements) {
    assert.doesNotMatch(s, /endpoints_type_check|CHECK \(type IN/i, 'endpoints.type CHECK degismez (E2)');
  }
});

test('mqtt_acl: mevcut cihaz kimliklerine ev/{t}/event yayini; NOT EXISTS (ON CONFLICT YOK), kind=device, LIKE d_% YOK', () => {
  const statements = parseSql(readRaw());
  const ins = statements.filter((s) => /^INSERT INTO mqtt_acl\b/i.test(s));
  assert.equal(ins.length, 1);
  const s = ins[0];
  assert.match(s, /^INSERT INTO mqtt_acl \(credential_id, username, permission, action, topic\) SELECT/);
  assert.match(s, /'allow', 'publish'/);
  assert.match(s, /c\.kind = 'device'/);
  assert.match(s, /NOT EXISTS \(SELECT 1 FROM mqtt_acl/);
  assert.match(s, /'\/event'/);
  assert.doesNotMatch(s, /ON CONFLICT/i);
  assert.doesNotMatch(s, /LIKE 'd_%'/);
  // konu kimligi mevcut ev/{t}/state satirindan gelir (020 / mqtt_credential_service ile ayni kaynak)
  assert.match(s, /'ev\/%\/state'/);
});

test('kapsam siniri: veri silen/yeniden yazan ifade YOK; yalniz beklenen tablolar degisir; indeksler IF NOT EXISTS', () => {
  const statements = parseSql(readRaw());
  for (const s of statements) {
    assert.doesNotMatch(s, /^(DELETE|UPDATE|TRUNCATE|GRANT|REVOKE)\b/i, s);
    assert.doesNotMatch(s, /\bDROP (COLUMN|TABLE|INDEX)\b/i, s);
    assert.doesNotMatch(s, /^ALTER TABLE (?!devices\b|endpoints\b)/i, s);
    if (/^CREATE (UNIQUE )?INDEX/i.test(s)) assert.match(s, /IF NOT EXISTS/, s);
  }
  const idx = statements.filter((s) => /^CREATE (UNIQUE )?INDEX/i.test(s));
  assert.ok(idx.some((s) => /ON alarms \(home_id\) WHERE status NOT IN \('cleared', 'lost'\)/.test(s)), 'acik alarm indeksi');
  assert.ok(idx.some((s) => /ON device_events \(received_at\)/.test(s)), 'saklama (90 gun) indeksi');
});

test('sema sozlesmesi: yeni tablo ve kolonlar migration semasinda gorunur', () => {
  const sqlContract = require('../../scripts/lib/sql_contract');
  const schema = sqlContract.loadMigrationSchema(DIR);
  for (const [t, cols] of Object.entries({
    alarms: ['id', 'home_id', 'device_id', 'aid', 'zone', 'kind', 'status', 'origin', 'push_status', 'fault_push_status'],
    device_events: ['device_id', 'eid', 'type', 'body', 'received_at'],
    device_configs: ['device_id', 'module', 'rev', 'crc', 'body', 'pending', 'updated_at'],
    devices: ['caps', 'safety_state'],
    endpoints: ['actuator_type', 'dimmable', 'dimmer_source'],
  })) {
    assert.ok(schema.has(t), `tablo yok: ${t}`);
    for (const c of cols) assert.ok(schema.get(t).has(c), `${t}.${c} yok`);
  }
});

test('yeni cihaz kimligi de event yayin satirini alir (mqtt_credential_service ile ayni konu sozlugu)', () => {
  const src = fs.readFileSync(path.join(SERVER, 'src', 'services', 'mqtt_credential_service.js'), 'utf8');
  assert.match(src, /`ev\/\$\{topic\}\/event`/);
});
