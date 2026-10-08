-- ==============================================================================
-- Migration 037: Yerel anahtar tutarliligi (pano-5) ve anahtar rotasyonu izleri (pano-6), 2026-10-08
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 037_local_key_consistency.sql
--
-- Kapsam
--   1. devices.local_key_fp / local_key_fp_at: firmware 1.3.1'in state'te bildirdigi yerel anahtar parmak izi
--      (CONTRACTS: HMAC-SHA256(local_key, 'ahbu-lk-fp/1|' + UID) hex ilk 8). Anahtarin kendisi DEGILDIR; yalniz
--      canli (retained olmayan) state'ten yazilir. NULL = eski firmware (fp bildirmez): eski davranis (PUBACK'te takas).
--      Iz bildiren panoda bekleyen anahtar takasi ancak pano yeni anahtarin izini bildirince kesinlesir.
--   2. service_sessions.local_key_read_at: servis (PIN) oturumu yerel anahtari okudu (GET .../local-key).
--      service_sessions.key_rotated_at: oturum bittikten sonra evin anahtari rotasyona alindi (supurucu bir kez yapar).
--
-- Bilincli olarak YOK: ONCEKI yerel anahtar saklanmaz (inceleme). Bootstrap internetten erisilebilir; saklanan onceki
--   anahtar, onu bilen kisinin (cikarilan uye, biten servis oturumu, acil sifirlamadan onceki sahip) rotasyonu ya da
--   sifirlamayi geri aldirip evin cihaz MQTT kimligini almasina yol acardi. Takasi kacirmis eski firmware'li panonun
--   kurtarma yolu seri konsol RESETKEY + FACTORYINIT'tir.
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001 (devices), 006/014 (service_sessions), 021 (local_key_enc), 032
--   (local_key_pending_enc + trg_devices_pending_key_superseded).
-- 032 tetikleyicisi ile etkilesim: tetikleyici yalniz SAHIPSIZ (home_id NULL) kayitta, bekleyen anahtara dokunmadan
--   local_key_enc degisirse bekleyeni temizler. fp kolonlari tetikleyicinin UPDATE OF listesinde degildir.
-- Rolling deploy: tum kolonlar NULL'dur ve varsayilansizdir (tablo yeniden yazilmaz). Eski kod yeni kolonlari
--   gormezden gelir (devices / service_sessions INSERT/UPDATE'leri kolon adlarini acikca sayar). Sira: once migration,
--   sonra sunucu.
-- ==============================================================================

-- devices ALTER'i canli trafikte (kopru UPDATE'leri) uzun kilit beklemesin: 5 sn'de vazgec, migration yeniden denenir.
SET LOCAL lock_timeout = '5s';

ALTER TABLE devices ADD COLUMN IF NOT EXISTS local_key_fp TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS local_key_fp_at TIMESTAMPTZ;

COMMENT ON COLUMN devices.local_key_fp IS 'pano-5: panonun canli statete bildirdigi yerel anahtar parmak izi (8 hex; anahtar DEGIL); NULL = eski firmware';
COMMENT ON COLUMN devices.local_key_fp_at IS 'pano-5: local_key_fp son degisim zamani';

ALTER TABLE service_sessions ADD COLUMN IF NOT EXISTS local_key_read_at TIMESTAMPTZ;
ALTER TABLE service_sessions ADD COLUMN IF NOT EXISTS key_rotated_at TIMESTAMPTZ;

COMMENT ON COLUMN service_sessions.local_key_read_at IS 'pano-6: servis oturumu evin yerel anahtarini okudu (son okuma)';
COMMENT ON COLUMN service_sessions.key_rotated_at IS 'pano-6: oturum bittikten sonra evin yerel anahtari rotasyona alindi (supurucu bir kez)';
