'use strict';

// Migration 020 / 021 (WP-B): gercek PostgreSQL bu makinede YOK; bu testler yalnizca STATIK kontrollerdir
// (idempotentlik, sozdizimi sagligi, sir yoklugu, karar icerigi). Gercek dogrulama hazirlik ortaminda yapilmalidir.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const DIR = path.join(__dirname, '..', '..', 'migrations');
const FILES = ['020_mqtt_credentials.sql', '021_device_security_hardening.sql'];

const read = (f) => fs.readFileSync(path.join(DIR, f), 'utf8');
const stripComments = (sql) => sql.replace(/--[^\n]*/g, '');

/** $$ ... $$ govdelerini ayiklayip geri kalan ifadeleri ';' ile boler. */
function splitStatements(sql) {
  const clean = stripComments(sql);
  const out = [];
  let i = 0;
  let cur = '';
  let inDollar = false;
  let inStr = false;
  while (i < clean.length) {
    if (!inStr && clean.startsWith('$$', i)) {
      inDollar = !inDollar;
      cur += '$$';
      i += 2;
      continue;
    }
    const ch = clean[i];
    if (!inDollar && ch === "'") inStr = !inStr;
    if (!inDollar && !inStr && ch === ';') {
      if (cur.trim()) out.push(cur.trim());
      cur = '';
    } else {
      cur += ch;
    }
    i++;
  }
  if (cur.trim()) out.push(cur.trim());
  return { statements: out, balancedDollar: !inDollar, balancedQuote: !inStr };
}

for (const file of FILES) {
  test(`${file}: sozdizimi sagligi (dengeli $$, tirnak, parantez; her ifade ; ile biter) ve BEGIN/COMMIT yok`, () => {
    const sql = read(file);
    const { statements, balancedDollar, balancedQuote } = splitStatements(sql);
    assert.ok(balancedDollar, '$$ cifti dengesiz');
    assert.ok(balancedQuote, 'tirnak dengesiz');
    assert.ok(statements.length >= 8);

    for (const stmt of statements) {
      // $$ govdesi disinda parantez dengesi
      const outside = stmt.replace(/\$\$[\s\S]*?\$\$/g, '').replace(/'(?:[^']|'')*'/g, "''");
      let depth = 0;
      for (const ch of outside) {
        if (ch === '(') depth++;
        if (ch === ')') depth--;
        assert.ok(depth >= 0, `fazla ')' : ${stmt.slice(0, 80)}`);
      }
      assert.strictEqual(depth, 0, `parantez dengesiz: ${stmt.slice(0, 80)}`);
      // ilk anahtar kelime tanidik olmali
      assert.match(stmt, /^(CREATE|ALTER|UPDATE|DELETE|DO|DROP|INSERT)\b/i, `beklenmeyen ifade: ${stmt.slice(0, 60)}`);
    }
    assert.ok(!/^\s*(BEGIN|COMMIT|ROLLBACK)\s*;/im.test(stripComments(sql)), 'migration kendi transaction\'ini acmamali (runner sarmalar)');
    assert.ok(/IDEMPOTENT/i.test(sql), 'basliktaki idempotentlik notu');
  });

  test(`${file}: IDEMPOTENT - CREATE/ADD COLUMN/INDEX IF NOT EXISTS, DROP IF EXISTS, tetikleyici DROP+CREATE`, () => {
    const { statements } = splitStatements(read(file));
    for (const stmt of statements) {
      if (/^CREATE\s+(UNIQUE\s+)?(TABLE|INDEX)\b/i.test(stmt)) {
        assert.match(stmt, /\bIF\s+NOT\s+EXISTS\b/i, `IF NOT EXISTS yok: ${stmt.slice(0, 80)}`);
      }
      if (/^ALTER\s+TABLE\b/i.test(stmt) && /\bADD\s+COLUMN\b/i.test(stmt)) {
        assert.match(stmt, /\bADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\b/i, `ADD COLUMN IF NOT EXISTS yok: ${stmt.slice(0, 80)}`);
      }
      if (/^DROP\s+(TRIGGER|INDEX|TABLE|CONSTRAINT)\b/i.test(stmt)) {
        assert.match(stmt, /\bIF\s+EXISTS\b/i, `DROP IF EXISTS yok: ${stmt.slice(0, 80)}`);
      }
      if (/^CREATE\s+TRIGGER\b/i.test(stmt)) {
        // her CREATE TRIGGER'in oncesinde ayni adli DROP TRIGGER IF EXISTS olmali
        const name = /CREATE\s+TRIGGER\s+(\w+)/i.exec(stmt)[1];
        assert.ok(new RegExp(`DROP\\s+TRIGGER\\s+IF\\s+EXISTS\\s+${name}\\b`, 'i').test(read(file)), `${name}: DROP TRIGGER IF EXISTS yok`);
      }
      if (/^CREATE\s+(OR\s+REPLACE\s+)?FUNCTION\b/i.test(stmt)) {
        assert.match(stmt, /^CREATE\s+OR\s+REPLACE\s+FUNCTION\b/i);
      }
    }
  });

  test(`${file}: sir/parola/anahtar degeri ICERMEZ`, () => {
    const sql = read(file);
    assert.ok(!/\$2[aby]\$\d\d\$/.test(sql), 'bcrypt ozeti yok');
    assert.ok(!/password\s*=\s*'[^']{6,}'/i.test(sql));
    assert.ok(!/(?:secret|token|key)\s*=\s*'[A-Za-z0-9+/]{16,}'/i.test(sql));
    assert.ok(!/\b[0-9a-f]{64}\b/i.test(sql), '64 onaltilik (SHA-256 benzeri) ozet degeri yok: PIN/anahtar ozetleri migration\'a yazilmaz');
  });
}

test('020: mqtt_credentials/mqtt_acl EMQX sozlesmesi (username, password_hash bcrypt, expires_at, topic, action...)', () => {
  const sql = read('020_mqtt_credentials.sql');
  assert.match(sql, /CREATE TABLE IF NOT EXISTS mqtt_credentials/);
  assert.match(sql, /password_hash\s+VARCHAR\(100\)\s+NOT NULL/);
  assert.match(sql, /kind\s+VARCHAR\(10\)\s+NOT NULL CHECK \(kind IN \('device', 'app', 'backend'\)\)/);
  assert.match(sql, /CONSTRAINT uq_mqtt_credentials_username UNIQUE \(username\)/);
  assert.match(sql, /home_id\s+UUID REFERENCES homes\(id\) ON DELETE CASCADE/);
  assert.match(sql, /user_id\s+UUID REFERENCES users\(id\) ON DELETE CASCADE/);
  assert.match(sql, /CREATE UNIQUE INDEX IF NOT EXISTS uq_mqtt_credentials_home_device ON mqtt_credentials \(home_id\) WHERE kind = 'device'/);
  assert.match(sql, /CREATE TABLE IF NOT EXISTS mqtt_acl/);
  assert.match(sql, /credential_id\s+UUID REFERENCES mqtt_credentials\(id\) ON DELETE CASCADE/);
  assert.match(sql, /permission\s+VARCHAR\(5\) NOT NULL CHECK \(permission IN \('allow', 'deny'\)\)/);
  assert.match(sql, /action\s+VARCHAR\(10\) NOT NULL CHECK \(action IN \('publish', 'subscribe', 'all'\)\)/);
  // EMQX icin onerilen sorgular belgelenmis
  assert.match(sql, /SELECT password_hash, is_superuser FROM mqtt_credentials/);
  assert.match(sql, /SELECT permission, action, topic FROM mqtt_acl WHERE username = \$\{username\}/);
  // duz metin parola kolonu yok
  assert.ok(!/\bpassword\s+(VARCHAR|TEXT)/i.test(stripComments(sql)));
});

test('021: kararlar - setup_pin bosaltilir, yerel anahtar sifreli kolon, atomik sayac icin NOT NULL, OTP penceresi, kontrol sonuclari', () => {
  const sql = read('021_device_security_hardening.sql');
  assert.match(sql, /ALTER TABLE devices ALTER COLUMN setup_pin DROP NOT NULL/);
  assert.match(sql, /UPDATE devices SET setup_pin = NULL WHERE setup_pin IS NOT NULL/);
  const dropIdx = sql.indexOf('ALTER COLUMN setup_pin DROP NOT NULL');
  const updIdx = sql.indexOf('UPDATE devices SET setup_pin = NULL');
  assert.ok(dropIdx >= 0 && updIdx > dropIdx, 'NOT NULL once kaldirilmali, sonra NULL yazilmali');

  assert.match(sql, /ALTER TABLE devices ADD COLUMN IF NOT EXISTS local_key_enc TEXT/);
  assert.match(sql, /ALTER TABLE device_inventory ADD COLUMN IF NOT EXISTS local_key_enc TEXT/);
  assert.match(sql, /UPDATE device_inventory SET failed_attempts = 0 WHERE failed_attempts IS NULL/);
  assert.match(sql, /ALTER COLUMN failed_attempts SET NOT NULL/);

  // OTP: tekil satir + deneme penceresi
  assert.match(sql, /ADD COLUMN IF NOT EXISTS window_started_at TIMESTAMPTZ NOT NULL DEFAULT NOW\(\)/);
  assert.match(sql, /CREATE UNIQUE INDEX IF NOT EXISTS uq_device_claim_otps_target ON device_claim_otps \(device_uuid, target_identifier\)/);
  const dedupe = sql.indexOf('DELETE FROM device_claim_otps a');
  const unique = sql.indexOf('uq_device_claim_otps_target');
  assert.ok(dedupe >= 0 && dedupe < unique, 'tekil indeks oncesinde mukerrer satirlar temizlenmeli');
  assert.match(sql, /DELETE FROM device_claim_otps WHERE otp_hash NOT LIKE 'h1\$%'/, 'eski tuzsuz OTP ozetleri temizlenmeli');

  // kontrol sonuclari (B9)
  assert.match(sql, /CREATE TABLE IF NOT EXISTS commissioning_checks/);
  assert.match(sql, /check_name\s+VARCHAR\(20\) NOT NULL CHECK \(check_name IN \('relays', 'buttons', 'shutters', 'network', 'cloud'\)\)/);
  assert.match(sql, /CONSTRAINT uq_commissioning_checks_log_name UNIQUE \(commissioning_log_id, check_name\)/);
  assert.match(sql, /commissioning_log_id\s+UUID NOT NULL REFERENCES commissioning_logs\(id\) ON DELETE CASCADE/);
  assert.match(sql, /ALTER TABLE commissioning_logs ALTER COLUMN tests_passed SET DEFAULT FALSE/);
  assert.match(sql, /ALTER TABLE commissioning_logs ALTER COLUMN technician_id DROP NOT NULL/);

  // gunlukler: servis oturumu kullanici satiri olusturmaz; IP kaydi
  assert.match(sql, /ALTER TABLE device_replacement_logs ALTER COLUMN replaced_by_user_id DROP NOT NULL/);
  assert.match(sql, /ALTER TABLE emergency_reset_logs ALTER COLUMN installer_user_id DROP NOT NULL/);
  assert.match(sql, /ALTER TABLE emergency_reset_logs ADD COLUMN IF NOT EXISTS ip_address VARCHAR\(64\)/);

  // denetim kaydi
  assert.match(sql, /CREATE TABLE IF NOT EXISTS device_audit_logs/);
  assert.match(sql, /details\s+JSONB/);

  // B12: cocuk kilidi NIYETI (istenen deger); gercek durum devices/homes.child_lock_enabled'da kalir (cihaz bildirimi)
  assert.match(sql, /ALTER TABLE homes ADD COLUMN IF NOT EXISTS child_lock_requested BOOLEAN;/);
  assert.match(sql, /ALTER TABLE homes ADD COLUMN IF NOT EXISTS child_lock_requested_at TIMESTAMPTZ;/);
  assert.match(sql, /ALTER TABLE homes ADD COLUMN IF NOT EXISTS child_lock_requested_by UUID REFERENCES users\(id\) ON DELETE SET NULL;/);
  assert.ok(!/child_lock_enabled\s+(BOOLEAN|SET)/i.test(stripComments(sql)), '021 gercek durum kolonuna (child_lock_enabled) dokunmaz; o WP-C 025 konusudur');
});

test('021: FK/ON DELETE kararlari - kullanici silinince denetim kaydi kalir (SET NULL); ev silinince cihaz/envanter yetim kalmaz', () => {
  const sql = read('021_device_security_hardening.sql');
  // FK yeniden kurulumu katalogdan, tum ilgili tablo/sutunlar icin
  for (const pair of ["'devices', 'claimed_by'", "'devices', 'commissioned_by'", "'emergency_reset_logs', 'installer_user_id'",
    "'device_replacement_logs', 'replaced_by_user_id'", "'commissioning_logs', 'technician_id'"]) {
    assert.ok(sql.includes(pair), `FK listesinde yok: ${pair}`);
  }
  assert.match(sql, /REFERENCES users\(id\) ON DELETE SET NULL/);
  assert.match(sql, /pg_constraint/);
  assert.match(sql, /DROP CONSTRAINT %I/);

  // yetim cihaz/envanter tetikleyicisi
  assert.match(sql, /CREATE OR REPLACE FUNCTION release_devices_on_home_delete\(\)/);
  assert.match(sql, /RETURNS TRIGGER/);
  assert.match(sql, /CASE WHEN status = 'CLAIMED' THEN 'SUSPENDED' ELSE status END/);
  assert.match(sql, /device_status = 'ORPHANED'/);
  assert.match(sql, /BEFORE DELETE ON homes/);
  assert.match(sql, /FOR EACH ROW EXECUTE FUNCTION release_devices_on_home_delete\(\)/);
  assert.match(sql, /RETURN OLD;/, 'BEFORE DELETE tetikleyicisi OLD donmeli (silmeyi engellemez)');
  // 'SUSPENDED' envanter durumu CHECK ile izinli (004)
  assert.match(fs.readFileSync(path.join(DIR, '004_device_inventory_serial_and_status.sql'), 'utf8'), /'SUSPENDED'/);
});

test('021: eksik indeksler eklenir', () => {
  const sql = read('021_device_security_hardening.sql');
  for (const idx of [
    'idx_device_inventory_claimed_home', 'idx_device_inventory_claimed_user', 'idx_devices_claimed_by',
    'idx_commissioning_logs_device', 'idx_emergency_reset_home', 'idx_home_users_home_role', 'idx_endpoints_home_type',
  ]) {
    assert.match(sql, new RegExp(`CREATE INDEX IF NOT EXISTS ${idx} ON`), idx);
  }
});

test('migration numaralari: 020 ve 021 mevcut, onceki numaralarla cakismaz', () => {
  const files = fs.readdirSync(DIR).filter((f) => /^\d+_.*\.sql$/.test(f));
  for (const prefix of ['020_', '021_']) {
    assert.strictEqual(files.filter((f) => f.startsWith(prefix)).length, 1, `${prefix} tek dosya olmali`);
  }
});
