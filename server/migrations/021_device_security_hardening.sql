-- ==============================================================================
-- Migration 021: Cihaz / sahiplenme / devreye alma sertlestirmesi (WP-B, denetim 2026-10-01)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -f 021_device_security_hardening.sql
-- Bagimlilik: 018 (users.account_status vb.) ve 020 (mqtt_credentials) once uygulanmis olmalidir.
--
-- Kapsam:
--   1. devices.setup_pin (DUZ METIN PIN) kolonu bosaltilir; yerel anahtar sifreli saklanir (local_key_enc)
--   2. device_inventory: local_key_enc, atomik sayac icin failed_attempts NOT NULL
--   3. device_claim_otps: tekil satir, deneme penceresi (yeniden istek sayaci SIFIRLAMAZ), ozetli kod
--   4. commissioning_checks (kontrol sonuclari ayri kayit), commissioning_logs/replacement/reset gunlukleri
--      (servis oturumu kullanici satiri olmadigi icin teknisyen kimligi bos olabilir; IP kaydi)
--   5. device_audit_logs (hassas islemler icin genel denetim kaydi)
--   6. FK / ON DELETE kararlari: kullanici silinince denetim kayitlari KALIR (SET NULL);
--      ev silinince cihazlar/envanter YETIM kalmaz (tetikleyici, asagida)
--   7. Cocuk kilidi niyeti (homes.child_lock_requested*): istenen deger; gercek durum cihazdan gelir
--   8. Eksik indeksler
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. DEVICES
-- ------------------------------------------------------------------------------
ALTER TABLE devices ADD COLUMN IF NOT EXISTS local_key_enc TEXT;           -- AES-256-GCM (secret_box), LAN anahtari
ALTER TABLE devices ADD COLUMN IF NOT EXISTS name VARCHAR(100);            -- kullanicinin verdigi pano adi (bos olabilir)

-- Duz metin kurulum PIN'i artik HICBIR yerde saklanmaz (PIN ozeti device_inventory.pin_hash'tedir).
ALTER TABLE devices ALTER COLUMN setup_pin DROP NOT NULL;
UPDATE devices SET setup_pin = NULL WHERE setup_pin IS NOT NULL;

-- ------------------------------------------------------------------------------
-- 2. DEVICE_INVENTORY
-- ------------------------------------------------------------------------------
ALTER TABLE device_inventory ADD COLUMN IF NOT EXISTS local_key_enc TEXT;

-- PIN deneme sayaci SQL icinde atomik artirilir (failed_attempts + 1): NULL olmamali.
UPDATE device_inventory SET failed_attempts = 0 WHERE failed_attempts IS NULL;
ALTER TABLE device_inventory ALTER COLUMN failed_attempts SET DEFAULT 0;
ALTER TABLE device_inventory ALTER COLUMN failed_attempts SET NOT NULL;

-- ------------------------------------------------------------------------------
-- 3. DEVICE_CLAIM_OTPS (servis personelinin musteri adina sahiplenme onay kodu)
-- ------------------------------------------------------------------------------
-- Eski kodlar tuzsuz SHA-256 ozetliydi (6 hane = aninda kirilir): kisa omurlu zaten, silinir.
DELETE FROM device_claim_otps WHERE otp_hash NOT LIKE 'h1$%';

ALTER TABLE device_claim_otps ADD COLUMN IF NOT EXISTS window_started_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE device_claim_otps ADD COLUMN IF NOT EXISTS requested_by UUID REFERENCES users(id) ON DELETE SET NULL;

UPDATE device_claim_otps SET target_identifier = LOWER(target_identifier) WHERE target_identifier <> LOWER(target_identifier);

-- (cihaz, hedef) basina tek satir: tekrarlari temizle (en yeni kalir), sonra tekil indeks.
DELETE FROM device_claim_otps a
 USING device_claim_otps b
 WHERE a.device_uuid = b.device_uuid
   AND a.target_identifier = b.target_identifier
   AND a.id < b.id;

CREATE UNIQUE INDEX IF NOT EXISTS uq_device_claim_otps_target ON device_claim_otps (device_uuid, target_identifier);

-- ------------------------------------------------------------------------------
-- 4. DEVREYE ALMA / PANO DEGISIMI / ACIL SIFIRLAMA GUNLUKLERI
-- ------------------------------------------------------------------------------
-- Servis oturumu (PIN) kullanici satiri olusturmaz: teknisyen kimligi bos olabilir.
ALTER TABLE commissioning_logs ALTER COLUMN technician_id DROP NOT NULL;
ALTER TABLE commissioning_logs ADD COLUMN IF NOT EXISTS technician_label VARCHAR(100);
ALTER TABLE commissioning_logs ADD COLUMN IF NOT EXISTS service_session_id UUID;
ALTER TABLE commissioning_logs ADD COLUMN IF NOT EXISTS device_uuid VARCHAR(64);
-- "Varsayilan: testler gecti" HATALI bir varsayilandi; sonuc her zaman sunucuda hesaplanip yazilir.
ALTER TABLE commissioning_logs ALTER COLUMN tests_passed SET DEFAULT FALSE;

-- Kontrol sonuclari ayri kayit: her devreye alma gunlugu icin 5 zorunlu kontrolun her biri.
CREATE TABLE IF NOT EXISTS commissioning_checks (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  commissioning_log_id  UUID NOT NULL REFERENCES commissioning_logs(id) ON DELETE CASCADE,
  check_name            VARCHAR(20) NOT NULL CHECK (check_name IN ('relays', 'buttons', 'shutters', 'network', 'cloud')),
  ok                    BOOLEAN NOT NULL,
  detail                TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT uq_commissioning_checks_log_name UNIQUE (commissioning_log_id, check_name)
);
CREATE INDEX IF NOT EXISTS idx_commissioning_checks_log ON commissioning_checks (commissioning_log_id);

ALTER TABLE device_replacement_logs ALTER COLUMN replaced_by_user_id DROP NOT NULL;
ALTER TABLE device_replacement_logs ADD COLUMN IF NOT EXISTS replaced_by_label VARCHAR(100);
ALTER TABLE device_replacement_logs ADD COLUMN IF NOT EXISTS service_session_id UUID;
ALTER TABLE device_replacement_logs ADD COLUMN IF NOT EXISTS ip_address VARCHAR(64);

ALTER TABLE emergency_reset_logs ALTER COLUMN installer_user_id DROP NOT NULL;
ALTER TABLE emergency_reset_logs ADD COLUMN IF NOT EXISTS ip_address VARCHAR(64);
ALTER TABLE emergency_reset_logs ADD COLUMN IF NOT EXISTS actor_role VARCHAR(30);
ALTER TABLE emergency_reset_logs ADD COLUMN IF NOT EXISTS action VARCHAR(20);   -- REASSIGNED | UNCLAIMED

-- ------------------------------------------------------------------------------
-- 5. GENEL DENETIM KAYDI (talep, sahiplenme, sifirlama, pano degisimi, anahtar okuma...)
-- ------------------------------------------------------------------------------
-- details alani SIR ICERMEZ (PIN, OTP, parola, local key, jeton yazilmaz).
CREATE TABLE IF NOT EXISTS device_audit_logs (
  id             BIGSERIAL PRIMARY KEY,
  event          VARCHAR(40) NOT NULL,
  device_uuid    VARCHAR(64),
  home_id        UUID REFERENCES homes(id) ON DELETE SET NULL,
  actor_user_id  UUID REFERENCES users(id) ON DELETE SET NULL,
  actor_role     VARCHAR(30),
  ip_address     VARCHAR(64),
  details        JSONB,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_device_audit_device ON device_audit_logs (device_uuid, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_device_audit_home ON device_audit_logs (home_id, created_at DESC);

-- ------------------------------------------------------------------------------
-- 6. FK / ON DELETE KARARLARI
-- ------------------------------------------------------------------------------
-- Karar 1: Kullanici silinince denetim/gunluk kayitlari SILINMEZ ve silmeyi ENGELLEMEZ;
--          kullanici referansi NULL'a doner (SET NULL). (Onceden NO ACTION: kullanici silinemiyordu;
--          commissioning_logs'ta CASCADE: denetim kaydi kayboluyordu.)
-- FK adi varsayima baglanmasin diye mevcut kisitlar katalogdan bulunup yeniden kurulur.
DO $$
DECLARE
  spec TEXT[][] := ARRAY[
    ['devices', 'claimed_by'],
    ['devices', 'commissioned_by'],
    ['emergency_reset_logs', 'installer_user_id'],
    ['device_replacement_logs', 'replaced_by_user_id'],
    ['commissioning_logs', 'technician_id']
  ];
  i INT;
  r RECORD;
BEGIN
  FOR i IN 1 .. array_length(spec, 1) LOOP
    IF to_regclass(spec[i][1]) IS NULL THEN
      CONTINUE;
    END IF;
    FOR r IN
      SELECT con.conname
        FROM pg_constraint con
        JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY (con.conkey)
       WHERE con.contype = 'f'
         AND con.conrelid = to_regclass(spec[i][1])
         AND att.attname = spec[i][2]
    LOOP
      EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I', spec[i][1], r.conname);
    END LOOP;
    EXECUTE format(
      'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES users(id) ON DELETE SET NULL',
      spec[i][1], spec[i][1] || '_' || spec[i][2] || '_fkey', spec[i][2]
    );
  END LOOP;
END $$;

-- Karar 2: Ev silinince cihazlar/envanter YETIM kalmasin.
--   devices.home_id ve device_inventory.claimed_home_id zaten ON DELETE SET NULL; ancak bu, envanteri
--   "CLAIMED ama evi yok" gibi tutarsiz birakir (kimse sahiplenemez, kimse yonetemez).
--   Tetikleyici: ev silinirken ilgili CLAIMED envanter satirlari SUSPENDED olur (super yonetici incelemesi /
--   acil sifirlama ile stoga alinir) ve cihaz kaydi sahipsiz isaretlenir. Uygulama kimlikleri
--   mqtt_credentials.home_id ON DELETE CASCADE ile silinir (baglanti atma servis katmaninda yapilir).
CREATE OR REPLACE FUNCTION release_devices_on_home_delete()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE device_inventory
     SET status = CASE WHEN status = 'CLAIMED' THEN 'SUSPENDED' ELSE status END,
         claimed_home_id = NULL
   WHERE claimed_home_id = OLD.id;

  UPDATE devices
     SET is_claimed = FALSE,
         claimed_by = NULL,
         is_online = FALSE,
         is_commissioned = FALSE,
         device_status = 'ORPHANED'
   WHERE home_id = OLD.id;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_homes_release_devices ON homes;
CREATE TRIGGER trg_homes_release_devices
  BEFORE DELETE ON homes
  FOR EACH ROW EXECUTE FUNCTION release_devices_on_home_delete();

-- ------------------------------------------------------------------------------
-- 7. COCUK KILIDI: ISTENEN DEGER (niyet) - GERCEK durum cihazin state.child_lock bildirimidir
-- ------------------------------------------------------------------------------
-- REST, broker PUBACK sonrasi "kilitlendi" diye DURUM yazmaz (PUBACK cihaza UYGULANDI demek degildir).
-- Yalnizca niyet kaydedilir: (a) arka arkaya iki istek ters sirada yayinlanirsa "zaten istenen degerde"
-- kisa devresi yanlis calismasin, (b) pano degisiminde onceki kilit yeni panoya yeniden uygulanabilsin,
-- (c) kopru, cihaz cevrimici olunca niyet ile bildirilen durumu uzlastirabilsin (WP-C).
-- homes.child_lock_enabled = bool_and(devices.child_lock_enabled) degerini KOPRU esitler (state bildirimi).
ALTER TABLE homes ADD COLUMN IF NOT EXISTS child_lock_requested BOOLEAN;
ALTER TABLE homes ADD COLUMN IF NOT EXISTS child_lock_requested_at TIMESTAMPTZ;
ALTER TABLE homes ADD COLUMN IF NOT EXISTS child_lock_requested_by UUID REFERENCES users(id) ON DELETE SET NULL;

-- ------------------------------------------------------------------------------
-- 8. EKSIK INDEKSLER
-- ------------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_device_inventory_claimed_home ON device_inventory (claimed_home_id);
CREATE INDEX IF NOT EXISTS idx_device_inventory_claimed_user ON device_inventory (claimed_by_user_id);
CREATE INDEX IF NOT EXISTS idx_devices_claimed_by ON devices (claimed_by);
CREATE INDEX IF NOT EXISTS idx_commissioning_logs_device ON commissioning_logs (device_id);
CREATE INDEX IF NOT EXISTS idx_emergency_reset_home ON emergency_reset_logs (home_id);
CREATE INDEX IF NOT EXISTS idx_home_users_home_role ON home_users (home_id, role);
CREATE INDEX IF NOT EXISTS idx_endpoints_home_type ON endpoints (home_id, type);
