-- ==============================================================================
-- Migration 044: Cihaz MQTT kimliginin panonun istemci kimligine baglanmasi (client_id), 2026-10-09
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 044_mqtt_client_binding.sql
--
-- Kapsam (sahip karari 17B)
--   mqtt_credentials.client_id (020'den beri var, NULL olabilir) ANLAM degistirir: NULL = baglama yok; dolu = EMQX
--   kimlik sorgusu (emqx_config/emqx.conf) yalniz bu MQTT istemci kimligiyle gelen baglantiyi kabul eder. Ayni kullanici
--   adiyla baska istemci kimligi kullanan ikinci baglanti reddedilir (kimligi kopyalayan eski uye sessizce dinleyemez).
--     uygulama kimlikleri (kind='app')   -> NULL (uygulama istemci kimligi serbest)
--     cihaz kimlikleri (kind='device')   -> evde TEK pano varsa firmware'in kullandigi istemci kimligi:
--                                           "ESP32S3_" + MAC'in 12 hanesi (buyuk harf, ayracsiz; MqttManager.cpp,
--                                           esp_read_mac(WIFI_STA)); MAC 12 hane degilse ya da evde birden fazla pano
--                                           varsa NULL (baglama yok)
--   Eski deger (kullanici adiyla ayni 'd_...' / 'a_...') baglama olarak YORUMLANMAMALI: hepsi yeniden yazilir.
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 020 (mqtt_credentials), 001 (devices.mac_address).
-- Rolling deploy: kolon zaten var; yalniz veri. Canli EMQX kimlik sorgusu degismeden bu dosyanin etkisi YOKTUR. Sira:
--   once migration + sunucu, sonra (bagli panolarin istemci kimligi client_id ile karsilastirildiktan sonra) EMQX
--   sorgusu (docs/CONTRACTS.md 3j).
-- ==============================================================================

-- mqtt_credentials UPDATE'i canli trafikte uzun kilit beklemesin: 5 sn'de vazgec, yeniden denenir.
SET LOCAL lock_timeout = '5s';

UPDATE mqtt_credentials
   SET client_id = NULL
 WHERE kind = 'app'
   AND client_id IS NOT NULL;

UPDATE mqtt_credentials c
   SET client_id = x.bound
  FROM (
    SELECT h.home_id,
           CASE WHEN h.n = 1 AND h.hex ~ '^[0-9A-F]{12}$' THEN 'ESP32S3_' || h.hex END AS bound
      FROM (
        SELECT home_id,
               COUNT(*) AS n,
               MIN(upper(regexp_replace(mac_address, '[^0-9A-Fa-f]', '', 'g'))) AS hex
          FROM devices
         WHERE home_id IS NOT NULL
         GROUP BY home_id
      ) h
  ) x
 WHERE c.kind = 'device'
   AND c.home_id = x.home_id
   AND c.client_id IS DISTINCT FROM x.bound;

-- Panosu olmayan evin (ya da evsiz) cihaz kimligi: baglama yok.
UPDATE mqtt_credentials c
   SET client_id = NULL
 WHERE c.kind = 'device'
   AND c.client_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM devices d WHERE d.home_id = c.home_id);

COMMENT ON COLUMN mqtt_credentials.client_id IS 'Karar 17B: dolu ise EMQX yalniz bu MQTT istemci kimligini kabul eder (cihaz: ESP32S3_<MAC>); NULL = baglama yok (uygulama)';
