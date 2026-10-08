-- ==============================================================================
-- Migration 036: Pano bootstrap nonce kaydi (CONTRACTS bolum 3f, 2026-10-08)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 036_device_bootstrap_nonces.sql
--
-- Kapsam
--   device_bootstrap_nonces: POST /devices/bootstrap isteginin (kart, nonce) ikilisi; tekrar oynatma korumasi.
--   Imzali istek ts +-300 sn icinde gecerli oldugu icin 600 sn'den eski kayitlar islevsizdir: servis her istekte o
--   kartin eski kayitlarini siler (ayri bakim isi gerekmez; created_at indeksi toplu temizlik icin).
--   Veritabaninda tutulur (bellek ici degil): surec yeniden baslasa da / birden cok surec calissa da tekrar reddedilir.
--
-- Bagimlilik: yok (device_uuid FK DEGIL: bilinmeyen kart icin satir yazilmaz, envanter silinse de kayit zarar vermez).
-- Rolling deploy: yeni tablo; eski kod kullanmaz. Sira: once migration, sonra sunucu (036'siz veritabaninda bootstrap
-- 500 doner; pano 30 dk sonra yeniden dener, baska yol etkilenmez).
-- ==============================================================================

CREATE TABLE IF NOT EXISTS device_bootstrap_nonces (
  device_uuid  VARCHAR(64) NOT NULL,
  nonce        CHAR(32) NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (device_uuid, nonce)
);
CREATE INDEX IF NOT EXISTS idx_device_bootstrap_nonces_created ON device_bootstrap_nonces (created_at);

COMMENT ON TABLE device_bootstrap_nonces IS 'CONTRACTS 3f: bootstrap tekrar oynatma korumasi (kart, nonce); 600 sn sonra islevsiz, servis temizler';
