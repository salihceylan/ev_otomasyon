-- ==============================================================================
-- Migration 031: Uc nokta yerlesim esitleme - panonun bildirdigi yerlesim tabani (WP-L)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 031_endpoint_layout_sync.sql
--
-- Kapsam
--   1. devices.reported_layout: bu panonun en son UYGULANAN yerlesim bildirimi (taban).
--      Bicim: {"v":1,"relays":[{"id":1,"type":"shutter_up","name":"..."}, ...]}
--      (src/utils/endpoint_layout.js serializeBase / parseBase). Ad kuralindaki "onceki pano adi"
--      buradan okunur. NULL = bu panoyla hic esitlenmedi (ilk esitlemede yazilir).
--      Taban CIHAZ satirinda tutulur: pano degisiminde (yeni cihaz satiri, taban bos) tasinan uc
--      noktalarin ozel adlari yeni panonun fabrika adlariyla ezilmez.
--   2. devices.reported_layout_at: tabanin son yazilma zamani (tani/bakim icin).
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001 (devices, endpoints), 011/022 (scheduled_rules),
--   021 (device_audit_logs). Bu migration `endpoints`, `homes` ve `scheduled_rules` tablolarina
--   DOKUNMAZ; uc nokta satirlarini calisma aninda src/services/endpoint_layout_sync.js uzlastirir.
--
-- Rolling deploy: iki kolon da NULL olabilir ve varsayilansizdir; mevcut satirlar degismez, tablo
-- yeniden yazilmaz (yalniz katalog degisikligi, kisa ACCESS EXCLUSIVE kilidi). Eski kod yeni
-- kolonlari gormezden gelir (devices INSERT/UPDATE'leri kolon adlarini acikca sayar). Esitleme
-- ENDPOINT_LAYOUT_SYNC=off ile bu migration geri alinmadan kapatilabilir.
-- ==============================================================================

ALTER TABLE devices ADD COLUMN IF NOT EXISTS reported_layout JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS reported_layout_at TIMESTAMPTZ;

COMMENT ON COLUMN devices.reported_layout IS 'Panonun en son UYGULANAN yerlesim bildirimi (WP-L): {"v":1,"relays":[{"id","type","name"}]}; NULL = bu panoyla hic esitlenmedi';
COMMENT ON COLUMN devices.reported_layout_at IS 'reported_layout son yazilma zamani';
