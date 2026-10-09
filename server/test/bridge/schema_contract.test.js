'use strict';

// C9 - SEMA-SOZLESME testi: kodun (kopru, zamanlayici, tum servisler, betikler) kullandigi tablo ve
// sutunlar migration'larda VAR MI? PostgreSQL gerektirmez; ayni denetim gercek bir PostgreSQL'e
// karsi `node scripts/check_schema_contract.js --live` ile calistirilabilir (QA yigini).
//
// Neden: kopru `devices.last_ack_id` yazarken bunu yaratan migration olmasa HER canli state 42703 ile
// geri alinir, saglikli pano 120 sn sonra "cevrimdisi" supurulur ve komutlar 409 doner. Mock'lu
// testler bunu gormez. Bu test o hata sinifini yakalar (olumsuz kontrol testi bunu kanitlar).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const contract = require('../../scripts/lib/sql_contract');
const { check, loadSchema, main, formatViolation } = require('../../scripts/check_schema_contract');
const { captureWpCStatements } = require('../../scripts/lib/sql_capture');

const MIGRATIONS = path.join(__dirname, '..', '..', 'migrations');

// Kucuk, elle yazilmis sema: cozumleyici testleri migration'lardan bagimsiz kalsin
const SCHEMA = new Map([
  ['homes', new Set(['id', 'name', 'mqtt_username', 'timezone', 'child_lock_enabled'])],
  ['devices', new Set(['id', 'home_id', 'device_uuid', 'is_online', 'last_seen_at', 'last_ack_id', 'last_ack_at', 'ip_address'])],
  ['users', new Set(['id', 'full_name', 'email', 'role'])],
  ['endpoints', new Set(['id', 'device_id', 'channel_index', 'current_state', 'updated_at'])],
]);

const unknownOf = (sql, schema = SCHEMA) => {
  const r = contract.analyzeSql(sql, schema);
  return {
    tables: r.unknownTables,
    columns: r.unknownColumns.map((c) => `${c.table}.${c.column}`),
    skipped: r.skipped,
  };
};

// ------------------------------------------------------------------------------
// Cozumleyici: eksik sutun/tablo YAKALAR
// ------------------------------------------------------------------------------
test('analyzeSql: UPDATE ... SET\'te olmayan sutun yakalanir (last_ack_id sinifi hata)', () => {
  assert.deepEqual(unknownOf('UPDATE devices SET last_ack_idx = $2 WHERE id = $1').columns, ['devices.last_ack_idx']);
  assert.deepEqual(unknownOf('UPDATE devices d SET is_online = TRUE, nope = $2 FROM homes h WHERE d.home_id = h.id').columns, ['devices.nope']);
  assert.deepEqual(unknownOf('UPDATE devices SET is_online = TRUE, last_seen_at = CURRENT_TIMESTAMP WHERE id = $1').columns, []);
});

test('analyzeSql: INSERT sutun listesi, ON CONFLICT, DO UPDATE SET ve EXCLUDED', () => {
  assert.deepEqual(unknownOf('INSERT INTO homes (name, nope) VALUES ($1, $2)').columns, ['homes.nope']);
  assert.deepEqual(unknownOf('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) ON CONFLICT (mqtt_username) DO NOTHING').columns, []);
  assert.deepEqual(unknownOf('INSERT INTO homes (name) VALUES ($1) ON CONFLICT (nope) DO NOTHING').columns, ['homes.nope']);
  assert.deepEqual(
    unknownOf('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) ON CONFLICT (mqtt_username) DO UPDATE SET name = EXCLUDED.name, nope = EXCLUDED.nope').columns.sort(),
    ['homes.nope']
  );
  assert.deepEqual(unknownOf('INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) ON CONFLICT (mqtt_username) DO UPDATE SET name = EXCLUDED.name').columns, []);
});

test('analyzeSql: nitelikli basvuru (takma ad ve tablo adi), bilinmeyen tablo, yalin sutun', () => {
  assert.deepEqual(unknownOf('SELECT h.nope FROM homes h').columns, ['homes.nope']);
  assert.deepEqual(unknownOf('SELECT d.nope FROM devices d JOIN homes h ON h.id = d.home_id').columns, ['devices.nope']);
  assert.deepEqual(unknownOf('SELECT devices.nope FROM devices').columns, ['devices.nope']);
  assert.deepEqual(unknownOf('SELECT 1 FROM no_such_table').tables, ['no_such_table']);
  assert.deepEqual(unknownOf('SELECT id FROM homes WHERE nope = $1').columns, ['homes.nope']);
  assert.deepEqual(unknownOf('SELECT id, name FROM homes WHERE mqtt_username = $1 ORDER BY name').columns, []);
  assert.deepEqual(unknownOf('DELETE FROM homes WHERE nope = $1').columns, ['homes.nope']);
});

test('analyzeSql: CTE, VALUES, unnest, IS DISTINCT FROM, EXTRACT, FOR UPDATE OF, string sabitleri YANLIS POZITIF vermez', () => {
  const ok = [
    'WITH ins AS (INSERT INTO homes (name, mqtt_username) VALUES ($1, $2) RETURNING *) SELECT ins.*, u.full_name FROM ins LEFT JOIN users u ON u.id = ins.id',
    'UPDATE endpoints e SET current_state = v.state, updated_at = CURRENT_TIMESTAMP FROM (VALUES ($2::int, $3::boolean), ($4::int, $5::boolean)) AS v(channel, state) WHERE e.device_id = $1 AND e.channel_index = v.channel AND e.current_state IS DISTINCT FROM v.state',
    'SELECT sr.id FROM homes sr WHERE (sr.id, sr.name) IN (SELECT t.h, t.m FROM unnest($1::int[], $2::int[]) AS t(h, m))',
    'UPDATE homes h SET child_lock_enabled = s.v FROM (SELECT bool_and(COALESCE(d.is_online, FALSE)) AS v FROM devices d WHERE d.home_id = $1) s WHERE h.id = $1 AND s.v IS NOT NULL AND h.child_lock_enabled IS DISTINCT FROM s.v',
    "SELECT GREATEST(1, CEIL($3 - EXTRACT(EPOCH FROM (NOW() - last_seen_at))))::int AS wait_seconds FROM devices WHERE id = $1",
    "SELECT id FROM devices WHERE device_uuid = 'nope_column_in_string' AND last_ack_id <> 'x y z' FOR UPDATE",
    'SELECT h.id FROM homes h JOIN devices d ON d.home_id = h.id WHERE h.id = $1 FOR UPDATE OF h',
    "UPDATE devices SET last_seen_at = CURRENT_TIMESTAMP - (make_interval(secs => $2)) WHERE id = $1",
    "SELECT id FROM devices WHERE last_seen_at < CURRENT_TIMESTAMP - ($1::int * INTERVAL '1 second')",
  ];
  for (const sql of ok) {
    const r = unknownOf(sql);
    assert.deepEqual([r.tables, r.columns], [[], []], `yanlis pozitif: ${sql}`);
  }
});

test('analyzeSql: katalog sorgulari (information_schema, pg_*) sema denetimi disi', () => {
  assert.equal(unknownOf("SELECT 1 FROM information_schema.columns WHERE table_name = 'x'").skipped, true);
  assert.equal(unknownOf("SELECT to_regclass('public.x') AS t").skipped, true);
});

test('analyzeSql: dinamik parca (__EXPR__) icin yalin sutun denetimi atlanir ama nitelikli/INSERT yine denetlenir', () => {
  const r = contract.analyzeSql(`UPDATE devices SET ${contract.EXPR} WHERE id = $1`, SCHEMA);
  assert.deepEqual(r.unknownColumns, []);
  const r2 = contract.analyzeSql(`SELECT d.nope, ${contract.EXPR} FROM devices d`, SCHEMA);
  assert.deepEqual(r2.unknownColumns.map((c) => c.column), ['nope']);
});

// ------------------------------------------------------------------------------
// JS sozcuk cozumleyici
// ------------------------------------------------------------------------------
test('extractSqlLiterals: tirnak/sablon/birlestirme/yorum/regex ve satir numarasi', () => {
  const src = [
    "const a = 'SELECT 1 FROM homes'; // SELECT yorum FROM x",
    '/* UPDATE homes SET x = 1 */',
    'const re = /[\'"`]/g; const b = "UPDATE homes SET name = $1 " +',
    "  'WHERE id = $2';",
    'const c = `SELECT ${a} FROM ${`homes`} WHERE x = ${fn("]")}`;',
    "const d = x + 'baska';",
  ].join('\n');
  const lits = contract.extractSqlLiterals(src);
  const texts = lits.map((l) => l.text);
  assert.ok(texts.includes('SELECT 1 FROM homes'));
  assert.ok(!texts.some((t) => /yorum|UPDATE homes SET x = 1/.test(t)), 'yorumlar atlanmali');
  const joined = lits.find((l) => l.text.startsWith('UPDATE homes SET name'));
  assert.equal(joined.text, 'UPDATE homes SET name = $1 WHERE id = $2', '+ ile birlestirilen metin tek ifade');
  assert.equal(joined.line, 3);
  const tpl = lits.find((l) => l.text.startsWith('SELECT __EXPR__ FROM'));
  assert.ok(tpl && tpl.dynamic, 'sablon ifadeleri __EXPR__ olur');
  assert.ok(texts.includes('baska'));
});

test('looksLikeSql: SQL ifadelerini ayirir, diger metinleri almaz', () => {
  for (const sql of ['SELECT * FROM homes', 'UPDATE homes SET name = $1', 'INSERT INTO homes (name) VALUES ($1)', 'DELETE FROM homes WHERE id = $1', 'WITH x AS (SELECT 1) SELECT * FROM x']) {
    assert.equal(contract.looksLikeSql(sql), true, sql);
  }
  for (const txt of ['Gecersiz kanal', 'Update failed', 'select * from homes', 'SELECT', 'Kullanici silindi', '[SCHEDULER] Tur hatasi']) {
    assert.equal(contract.looksLikeSql(txt), false, txt);
  }
});

// ------------------------------------------------------------------------------
// Migration semasi
// ------------------------------------------------------------------------------
test('loadMigrationSchema: CREATE TABLE, cok kolonlu ALTER ADD COLUMN, DO blogu ve EXECUTE format metni', () => {
  const s = contract.loadMigrationSchema(MIGRATIONS);
  assert.ok(s.get('homes').has('mqtt_username'), '001 CREATE TABLE');
  assert.ok(s.get('homes').has('child_lock_enabled'), '010 cok kolonlu ALTER');
  assert.ok(s.get('homes').has('timezone'), '022');
  assert.ok(s.get('devices').has('last_ack_id') && s.get('devices').has('last_ack_at'), '023');
  assert.ok(s.get('scheduled_rules').has('last_run_at'), '022 (DO blogu icinde ALTER)');
  assert.ok(s.get('scheduled_rule_runs').has('slot_at'), '022 (EXECUTE format icindeki CREATE TABLE)');
  assert.ok(s.get('mqtt_credentials').has('is_superuser'), '020');
  assert.ok(s.get('users').has('account_status'), '018');
  assert.equal(s.has('schema_migrations'), false, 'runner tablosu migration degil (RUNTIME_TABLES)');
  assert.ok(loadSchema().has('schema_migrations'));
});

// ------------------------------------------------------------------------------
// GERCEK sozlesme: tum kod <-> migration
// ------------------------------------------------------------------------------
test('SOZLESME: src/** ve scripts/** SQL metinleri + WP-C modullerinin CALISAN SQL\'i migration semasiyla UYUMLU', async () => {
  const r = await check();
  assert.deepEqual(
    [...r.strict, ...r.advisory].map(formatViolation),
    [],
    'kod, migration\'larda olmayan tablo/sutun kullaniyor (baska paketin dosyasiysa SCHEMA_CONTRACT_SOFT=1 ile gecici uyari yapilabilir)'
  );
  assert.ok(r.statementCount >= 250, `yeterli kapsam: ${r.statementCount} ifade`);
  assert.ok(r.analyzed >= 250);
});

test('SOZLESME kapsami: kopru/zamanlayici/servis kolonlari gercekten denetleniyor', async () => {
  const r = await check();
  const need = {
    devices: ['child_lock_enabled', 'device_uuid', 'firmware_version', 'ip_address', 'is_online', 'last_ack_at', 'last_ack_id', 'last_seen_at'],
    endpoints: ['channel_index', 'current_position', 'current_state', 'shutter_pair_index', 'type'],
    homes: ['child_lock_enabled', 'mqtt_username', 'timezone'],
    scheduled_rules: ['channel', 'channel_type', 'days_of_week', 'last_run_at', 'schedule_changed_at', 'created_by'],
    scheduled_rule_runs: ['attempts', 'command_id', 'rule_id', 'slot_at', 'status'],
    users: ['is_active', 'role', 'terms_version', 'terms_accepted_at', 'phone_verified'], // 041: hesap-uyelik-3
    home_users: ['installer_expires_at', 'role'],
    // 039 (yasal metin kabulleri): services/legal_service.js
    legal_acceptances: ['accepted_at', 'document', 'ip_address', 'user_agent', 'user_id', 'version'],
    // 040 (sko-1): kuyruktaki alarm onayini isteyen servis oturumu (services/alarm_service.js)
    alarms: ['ack_requested_at', 'ack_requested_by', 'ack_requested_sid'],
  };
  for (const [table, cols] of Object.entries(need)) {
    for (const c of cols) assert.ok(r.refs.get(table) && r.refs.get(table).has(c), `${table}.${c} denetim kapsaminda degil`);
  }
});

test('OLUMSUZ KONTROL: 023 migration\'i olmasa kopru/test last_ack_* nedeniyle YAKALANIR (orijinal hata sinifi)', async () => {
  const hide = (name) => ({
    readdirSync: (dir, opts) => fs.readdirSync(dir, opts).filter((e) => e.name !== name),
    readFileSync: fs.readFileSync,
  });
  const schema = contract.loadMigrationSchema(MIGRATIONS, hide('023_bridge_device_telemetry.sql'));
  schema.set('schema_migrations', new Set(['name', 'version', 'checksum', 'baseline', 'applied_at', 'execution_ms']));
  assert.equal(schema.get('devices').has('last_ack_id'), false, 'on kosul: 023 gizli');

  const r = await check({ schema });
  const found = [...r.strict, ...r.advisory].filter((v) => v.table === 'devices' && /^last_ack_/.test(v.column || ''));
  assert.deepEqual(found.map((v) => v.column).sort().filter((c, i, a) => a.indexOf(c) === i), ['last_ack_at', 'last_ack_id']);
  assert.ok(found.some((v) => /mqtt_bridge/.test(v.where) || /capture:mqtt_bridge/.test(v.where)), 'ihlal kopruye isaret etmeli');
});

test('OLUMSUZ KONTROL: 022 olmasa zamanlayici/servis sutunlari ve gunluk tablosu YAKALANIR', async () => {
  const fsApi = {
    readdirSync: (dir, opts) => fs.readdirSync(dir, opts).filter((e) => e.name !== '022_scheduled_rules_fix.sql'),
    readFileSync: fs.readFileSync,
  };
  const schema = contract.loadMigrationSchema(MIGRATIONS, fsApi);
  schema.set('schema_migrations', new Set(['name', 'version', 'checksum', 'baseline', 'applied_at', 'execution_ms']));
  const r = await check({ schema });
  const all = [...r.strict, ...r.advisory];
  assert.ok(all.some((v) => v.kind === 'unknown-table' && v.table === 'scheduled_rule_runs'));
  assert.ok(all.some((v) => v.table === 'scheduled_rules' && v.column === 'last_run_at'));
  assert.ok(all.some((v) => v.table === 'homes' && v.column === 'timezone'));
});

// ------------------------------------------------------------------------------
// Dinamik yakalama
// ------------------------------------------------------------------------------
test('captureWpCStatements: kopru, zamanlayici ve servis tum dallardan gecer (cocuk kilidi esitleme, release, schedule reset dahil)', async () => {
  const st = await captureWpCStatements();
  const all = st.map((s) => s.sql.replace(/\s+/g, ' ')).join('\n');
  assert.ok(st.length >= 40);
  for (const frag of [
    'UPDATE homes h SET child_lock_enabled = s.v', // cocuk kilidi esitleme
    'is_online IS NOT TRUE', // retained uzlastirma
    'last_ack_at = CASE WHEN last_ack_id IS DISTINCT FROM', // ack
    'SET is_online = FALSE', // supurucu
    'UPDATE scheduled_rules SET last_run_at = $3::timestamptz', // release
    'INSERT INTO scheduled_rule_runs', // gunluk
    'schedule_changed_at = CURRENT_TIMESTAMP, last_run_at = NULL', // zamanlama degisikligi
    'DELETE FROM scheduled_rule_runs WHERE home_id', // temizlik kancasi
  ]) {
    assert.ok(all.includes(frag), `yakalanan SQL'de yok: ${frag}`);
  }
  assert.ok(st.every((s) => s.where.startsWith('capture:')));
});

// ------------------------------------------------------------------------------
// Canli PostgreSQL dogrulamasi (sahte istemciyle) ve CLI
// ------------------------------------------------------------------------------
test('verifyLiveSchema: eksik tablo ve sutunlari raporlar', async () => {
  const refs = new Map([
    ['devices', new Set(['id', 'last_ack_id', 'last_ack_at'])],
    ['ghost', new Set(['x'])],
  ]);
  const db = {
    query: async (text, params) => {
      assert.match(text, /information_schema\.columns/);
      assert.deepEqual(params, [['devices', 'ghost']]);
      return { rows: [{ table_name: 'devices', column_name: 'id' }, { table_name: 'devices', column_name: 'last_ack_id' }] };
    },
  };
  const problems = await contract.verifyLiveSchema(db, refs);
  assert.deepEqual(problems, [
    { table: 'devices', column: 'last_ack_at', problem: 'sutun yok' },
    { table: 'ghost', column: null, problem: 'tablo yok' },
  ]);
  assert.deepEqual(await contract.verifyLiveSchema(db, new Map()), []);
});

const cleanCheck = async () => ({ strict: [], advisory: [], refs: new Map([['devices', new Set(['id'])]]), analyzed: 1, skipped: 0, statementCount: 1 });
const violation = { kind: 'unknown-column', table: 'devices', column: 'nope', via: 'set', where: 'src/x.js:1', sql: 'UPDATE devices SET nope = 1' };

function cli(argv, deps = {}) {
  const out = [];
  const err = [];
  return main({ argv, env: {}, check: cleanCheck, log: (...a) => out.push(a.join(' ')), errLog: (...a) => err.push(a.join(' ')), ...deps }).then((code) => ({ code, out, err }));
}

test('CLI: temiz -> 0; ihlal -> 1 ve acik mesaj; baska paket ihlali SCHEMA_CONTRACT_SOFT=1 ile uyari', async () => {
  const clean = await cli([]);
  assert.equal(clean.code, 0);
  assert.match(clean.out.join('\n'), /Sema sozlesmesi TEMIZ/);

  const bad = await cli([], { check: async () => ({ ...(await cleanCheck()), strict: [violation] }) });
  assert.equal(bad.code, 1);
  assert.match(bad.err.join('\n'), /IHLAL: sutun yok: devices\.nope \(set\)/);

  const other = { ...violation, where: 'src/services/baska.js:9' };
  const advisory = async () => ({ ...(await cleanCheck()), advisory: [other] });
  assert.equal((await cli([], { check: advisory })).code, 1, 'varsayilan: tum paketler zorunlu');
  const soft = await cli([], { check: advisory, env: { SCHEMA_CONTRACT_SOFT: '1' } });
  assert.equal(soft.code, 0);
  assert.match(soft.out.join('\n'), /UYARI \(baska paket\)/);
});

test('CLI --live: DATABASE_URL zorunlu (2); canli ihlal -> 1; temiz -> 0; --json cikti; parola yazdirilmaz', async () => {
  assert.equal((await cli(['--live'])).code, 2);

  const secret = 'rnd-' + Math.random().toString(36).slice(2) + Date.now();
  const env = { DATABASE_URL: `postgresql://u:${secret}@127.0.0.1:5434/ev_otomasyon` };
  const mkClient = (rows) =>
    class {
      async connect() {}
      async end() {}
      async query(text) {
        return /information_schema/.test(text) ? { rows } : { rows: [] };
      }
    };

  const missing = await cli(['--live'], { env, Client: mkClient([]) });
  assert.equal(missing.code, 1);
  assert.match(missing.err.join('\n'), /CANLI IHLAL: devices - tablo yok/);
  assert.match(missing.out.join('\n'), /Canli hedef: u@127\.0\.0\.1:5434\/ev_otomasyon/);
  assert.ok(![...missing.out, ...missing.err].join('\n').includes(secret), 'parola yazdirilmamali');

  const ok = await cli(['--live'], { env, Client: mkClient([{ table_name: 'devices', column_name: 'id' }]) });
  assert.equal(ok.code, 0);

  const json = await cli(['--live', '--json'], { env, Client: mkClient([{ table_name: 'devices', column_name: 'id' }]) });
  const parsed = JSON.parse(json.out.join('\n').replace(/^Canli hedef:.*\n/, ''));
  assert.deepEqual(parsed.live, []);
  assert.deepEqual(parsed.refs, { devices: ['id'] });

  assert.equal((await cli(['--bogus'])).code, 2);
});
