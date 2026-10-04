-- ==============================================================================
-- Migration 032: Bekleyen yerel anahtar - acil sifirlamada panoya iletilemeyen anahtar (SERVIS-01)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 032_local_key_pending.sql
--
-- Kapsam
--   1. devices.local_key_pending_enc: acil sifirlama yeni yerel anahtari panoya SIMDI iletemiyorsa (pano cevrimdisi
--      ya da MQTT koprusu bagli degil) yeni anahtar burada BEKLER (secret_box ile sifreli, local_key_enc ile ayni
--      bicim). local_key_enc panodaki GERCEK anahtar olarak kalir: servis sihirbazi LAN'dan bununla baglanir.
--      Kopru uzlastiricisi (src/services/device_reconciler.js) pano CANLI olarak cevrimici olunca
--      `ev/{t}/sys {cmd:"set_local_key"}` yayinlar ve PUBACK sonrasi CAS ile takas eder
--      (local_key_enc = bekleyen, bekleyen = NULL; envanter ayni degere). NULL = bekleyen anahtar yok.
--   2. devices.local_key_pending_at: bekleyen anahtarin yazilma zamani (tani/bakim icin).
--   3. Tetikleyici trg_devices_pending_key_superseded: SAHIPSIZ (home_id NULL) cihaz kaydinin local_key_enc'i
--      bekleyen anahtara DOKUNMADAN degistirilirse (etiket yeniden uretimi: inventory_service.reissueLabel; yeni
--      etiket anahtari esastir) bekleyen anahtar temizlenir. Bekleyeni ACIKCA yazan guncellemeler (acil sifirlama,
--      telafi, uzlastirici takasi) ve eve bagli kayitlar (claim, pano degisimi) KAPSAM DISIDIR.
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001 (devices), 021 (devices.local_key_enc TEXT, device_inventory.local_key_enc).
--   Bu migration yalniz `devices` tablosuna dokunur; mevcut satirlarin degerleri degismez.
--
-- Rolling deploy: iki kolon da NULL olabilir ve varsayilansizdir; tablo yeniden yazilmaz (yalniz katalog
-- degisikligi, kisa ACCESS EXCLUSIVE kilidi). Eski kod yeni kolonlari gormezden gelir (devices INSERT/UPDATE'leri
-- kolon adlarini acikca sayar). Tetikleyici yalniz local_key_enc guncellemesinde ve WHEN kosulu dogruysa calisir:
-- kalp atisi guncellemeleri (is_online / last_seen_at) icin ek maliyet yoktur.
-- ==============================================================================

ALTER TABLE devices ADD COLUMN IF NOT EXISTS local_key_pending_enc TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS local_key_pending_at TIMESTAMPTZ;

COMMENT ON COLUMN devices.local_key_pending_enc IS 'SERVIS-01: panoya henuz iletilemeyen yeni yerel anahtar (secret_box ile sifreli, local_key_enc bicimi); kopru uzlastiricisi pano cevrimici olunca iletir ve local_key_enc ile takas eder; NULL = bekleyen yok';
COMMENT ON COLUMN devices.local_key_pending_at IS 'local_key_pending_enc yazilma zamani; NULL = bekleyen yok';

CREATE OR REPLACE FUNCTION devices_clear_superseded_pending_key()
RETURNS TRIGGER AS $$
BEGIN
  NEW.local_key_pending_enc := NULL;
  NEW.local_key_pending_at := NULL;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_devices_pending_key_superseded ON devices;
CREATE TRIGGER trg_devices_pending_key_superseded
  BEFORE UPDATE OF local_key_enc ON devices
  FOR EACH ROW
  WHEN (OLD.local_key_pending_enc IS NOT NULL
        AND NEW.home_id IS NULL
        AND NEW.local_key_enc IS DISTINCT FROM OLD.local_key_enc
        AND NEW.local_key_pending_enc IS NOT DISTINCT FROM OLD.local_key_pending_enc)
  EXECUTE FUNCTION devices_clear_superseded_pending_key();
