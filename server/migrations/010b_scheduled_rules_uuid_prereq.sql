-- ==============================================================================
-- Migration 010b: scheduled_rules tablosunu DOGRU (UUID) tiplerle onceden olusturur
--                 (WP-C, denetim 2026-10-01: "migration-surukleme")
-- ==============================================================================
-- Siralama: 010_night_peace... < 010b_... < 011_scheduled_rules.sql (duz metin siralamasi).
--
-- NEDEN: 011_scheduled_rules.sql home_id/device_id/created_by kolonlarini INTEGER olarak ve
-- homes/devices/users (PK'lari UUID) tablolarina FOREIGN KEY ile tanimlar. Temiz bir
-- veritabaninda bu, "foreign key constraint ... cannot be implemented (integer vs uuid)"
-- hatasiyla DUSER. Canli veritabaninda tablo elle duzeltildi (eski run_011.js). Eski
-- migration dosyalarini DEGISTIRMEMEK icin duzeltme yeni dosyada yapilir: bu dosya 011'den
-- ONCE calisir ve tabloyu dogru tiplerle olusturur; 011'in `CREATE TABLE IF NOT EXISTS`
-- komutu tabloyu mevcut bularak atlar (indeks/tetikleyici kismi calismaya devam eder).
--
-- Mevcut (canli) veritabanlari `scripts/migrate.js --baseline 17` ile bu dosyayi
-- "uygulanmis" sayar; yani canlida CALISMAZ. Sonraki duzeltmeler 022_scheduled_rules_fix.sql'dedir.
--
-- IDEMPOTENT. Icinde BEGIN/COMMIT YOKTUR (migrate.js tek transaction icinde calistirir).

CREATE TABLE IF NOT EXISTS scheduled_rules (
  id            SERIAL PRIMARY KEY,
  home_id       UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  device_id     UUID REFERENCES devices(id) ON DELETE CASCADE,
  channel       INTEGER NOT NULL,
  channel_type  VARCHAR(20) NOT NULL DEFAULT 'relay',
  action        VARCHAR(20) NOT NULL,
  hour          SMALLINT NOT NULL CHECK (hour >= 0 AND hour <= 23),
  minute        SMALLINT NOT NULL CHECK (minute >= 0 AND minute <= 59),
  days_of_week  JSONB NOT NULL DEFAULT '[0,1,2,3,4,5,6]',
  label         VARCHAR(100),
  enabled       BOOLEAN NOT NULL DEFAULT TRUE,
  created_by    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
