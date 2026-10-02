-- ==============================================================================
-- Migration 024: Eski (legacy) MQTT kullanici tablosu - YALNIZCA SEMA (WP-C, denetim 2026-10-01)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR (migrate.js tek transaction).
--
-- EMQX'in kimlik sorgusu (emqx_config/emqx.conf) gecis doneminde eski paylasilan kimlikleri bu
-- tablodan da okur, ANCAK yalnizca bcrypt'e yukseltilmis ($2...) ve superuser OLMAYAN satirlari
-- kabul eder (EMQX tek PostgreSQL authenticator + tek ozet algoritmasi destekler). Eski SHA-256
-- satirlari scripts/upgrade_legacy_mqtt_user.js ile (gercek parola ortamdan verilerek) yukseltilir.
-- Tablo daha once repo kokundeki init_mqtt_users.sql ile (sabit parolalarla birlikte) elle
-- olusturuluyordu; o dosya SILINDI. Burada yalnizca sema tanimlanir: KULLANICI SATIRI EKLENMEZ.
-- Canli veritabaninda tablo ve satirlari zaten vardir (IF NOT EXISTS -> degismez); temiz
-- kurulumlarda legacy kimlik gerekmez.
--
-- Legacy yolun kapatilmasi (docs/DEPLOY_RUNBOOK.md): tum cihazlar yeni firmware ile yeniden
-- flash edildikten sonra acl.conf'taki LEGACY blogu ve emqx.conf sorgusundaki mqtt_users kolu
-- kaldirilir, bu tablodaki satirlar silinir.

CREATE TABLE IF NOT EXISTS mqtt_users (
  username      VARCHAR(100) PRIMARY KEY,
  password_hash VARCHAR(100) NOT NULL,
  is_superuser  BOOLEAN NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE mqtt_users IS 'LEGACY: eski paylasilan SHA-256 MQTT kimlikleri (gecis donemi). Yeni kimlikler mqtt_credentials tablosundadir.';
