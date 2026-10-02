-- ==============================================================================
-- Migration 030: Gece huzur hatirlatmasi - bildirim kaydi + push token tablosu (WP-H)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 030_peace_reminder.sql
--
-- Kapsam
--   1. peace_notification_logs: "elle kapat" tiklama gunlugunden GERCEK bildirim kaydina
--      (once-per-night): local_date, scheduled_for, status, attempts, details, push_sent_count,
--      evaluated_at, resolved_by_user_id, resolved_via, command_id, updated_at.
--      UNIQUE (home_id, local_date): ayni yerel gece icin en cok BIR kayit -> en cok bir push.
--      local_date NULL olan satirlar (eski/elle kapatma tiklamalari) birbiriyle CAKISMAZ
--      (PostgreSQL'de NULL'lar birbirinden farklidir).
--   2. push_tokens: FCM/APNs cihaz kayitlari (kullanici bazli, token benzersiz).
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001/010 (homes, users, peace_notification_logs),
--   022 (homes.timezone), 025 (homes.peace_notification_time HH:MM kisiti; NULL = ayarlanmamis,
--   servis katmani bunu 23:30 sayar). Bu migration `homes` tablosuna DOKUNMAZ.
--
-- Rolling deploy: yeni kolonlar bos olabilir ya da varsayilanlidir (status 'manual'); eski kod
-- yeni kolonlari vermeden INSERT etmeye devam eder. home_cleanup.js peace_notification_logs'u ev
-- bazinda zaten siler; push_tokens kullanici bazlidir (alicilar GUNCEL home_users'tan hesaplanir).
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. PEACE_NOTIFICATION_LOGS: bildirim kaydi kolonlari
-- ------------------------------------------------------------------------------
ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS local_date DATE;
ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS scheduled_for TIMESTAMPTZ;
ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS status VARCHAR(20) NOT NULL DEFAULT 'manual';
ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS attempts SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS details JSONB;
ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS push_sent_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS evaluated_at TIMESTAMPTZ;
ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS resolved_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS resolved_via VARCHAR(16);
ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS command_id VARCHAR(32);
ALTER TABLE peace_notification_logs ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP;

-- Durum kumesi: manual (eski tiklama kaydi) | claimed (degerlendirici sahiplendi) | clear (hicbir sey
-- acik degil) | sending (push gonderimi basladi: kira devri/yeniden deneme YOK, cift push olmasin) |
-- sent | no_recipients | skipped_offline (cihaz canli degil, yeniden denenir) |
-- failed (gecici gonderim hatasi, yeniden denenir) | resolved (kullanici kapatti).
-- NOT VALID: mevcut satirlar taranmaz (hepsi 'manual' varsayilani); sonra VALIDATE.
ALTER TABLE peace_notification_logs DROP CONSTRAINT IF EXISTS peace_logs_status_check;
ALTER TABLE peace_notification_logs ADD CONSTRAINT peace_logs_status_check
  CHECK (status IN ('manual', 'claimed', 'sending', 'clear', 'sent', 'no_recipients', 'skipped_offline', 'failed', 'resolved')) NOT VALID;
ALTER TABLE peace_notification_logs VALIDATE CONSTRAINT peace_logs_status_check;

-- Once-per-night: ayni (ev, yerel tarih) icin tek satir. ON CONFLICT (home_id, local_date) buna dayanir.
-- NULL local_date satirlari (elle kapatma) cakismaz.
CREATE UNIQUE INDEX IF NOT EXISTS ux_peace_logs_home_date ON peace_notification_logs (home_id, local_date);

-- "Son bildirim" / bakim sorgulari: ev bazinda yeniden eskiye
CREATE INDEX IF NOT EXISTS idx_peace_logs_home_triggered ON peace_notification_logs (home_id, triggered_at DESC);

COMMENT ON COLUMN peace_notification_logs.local_date IS 'Bildirimin ait oldugu EV yerel gecesi (homes.timezone); NULL = elle kapatma satiri';
COMMENT ON COLUMN peace_notification_logs.status IS 'manual | claimed | sending | clear | sent | no_recipients | skipped_offline | failed | resolved';
COMMENT ON COLUMN peace_notification_logs.details IS 'Kisisel veri/token icermez: {lights:[{endpoint_id,channel,room}], shutters:[{pair,room,pos}], reason?}';

-- ------------------------------------------------------------------------------
-- 2. PUSH_TOKENS
-- ------------------------------------------------------------------------------
-- Token benzersizdir: paylasilan telefonda baska hesapla giris yapilirsa kayit yeni kullaniciya
-- yeniden baglanir (INSERT ... ON CONFLICT (token) DO UPDATE). disabled_at: FCM "UNREGISTERED"
-- dondurdu ya da cikis yapildi; 30 gun sonra evaluator bakimi siler.
CREATE TABLE IF NOT EXISTS push_tokens (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token         VARCHAR(512) NOT NULL,
  platform      VARCHAR(10) NOT NULL,
  app_version   VARCHAR(32),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  disabled_at   TIMESTAMPTZ,
  CONSTRAINT uq_push_tokens_token UNIQUE (token)
);

ALTER TABLE push_tokens DROP CONSTRAINT IF EXISTS push_tokens_platform_check;
ALTER TABLE push_tokens ADD CONSTRAINT push_tokens_platform_check
  CHECK (platform IN ('android', 'ios')) NOT VALID;
ALTER TABLE push_tokens VALIDATE CONSTRAINT push_tokens_platform_check;

-- Alici sorgusu yalnizca etkin token'lari kullanici bazinda okur
CREATE INDEX IF NOT EXISTS idx_push_tokens_user_active ON push_tokens (user_id) WHERE disabled_at IS NULL;
-- Bakim: devre disi birakilmis eski token'lari silmek icin
CREATE INDEX IF NOT EXISTS idx_push_tokens_disabled ON push_tokens (disabled_at) WHERE disabled_at IS NOT NULL;

COMMENT ON TABLE push_tokens IS 'FCM/APNs cihaz kayitlari (WP-H); token degeri asla loglanmaz';
