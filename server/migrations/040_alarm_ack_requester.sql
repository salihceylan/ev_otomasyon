-- ==============================================================================
-- Migration 040: Cevrimdisi panoya kuyruklanan alarm onayini isteyen servis oturumu, 2026-10-09
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 040_alarm_ack_requester.sql
--
-- Kapsam (sko-1, sozlesme C11)
--   alarms.ack_requested_sid: cevrimdisi panoya onay istegini yapan servis (PIN) oturumunun kimligi (servis
--   oturumunda kullanici satiri yoktur: ack_requested_by NULL kalir). Uzlastirici (services/alarm_service.js) kuyruktaki
--   istegi panoya iletmeden once isteyenin hala yetkili oldugunu denetler: oturum var, iptal edilmemis, suresi
--   dolmamis. ack_requested_* alanlarini temizleyen her ifade bu kolonu da NULL'lar.
--   YABANCI ANAHTAR YOK (bilincli): oturum satiri silinse de kimlik kalir ve istek "revoked" ile duser; ON DELETE SET
--   NULL istegi kimliksiz eski-satir kuralina dusurup onayi iletebilirdi.
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 033 (alarms), 018 (service_sessions).
-- Rolling deploy: yeni kolon NULL ve varsayilansizdir (tablo yeniden yazilmaz); eski kod gormezden gelir. Yeni kod
--   040'siz veritabaninda alarm uzlastirmasinda 42703 alir. Sira: once migration, sonra sunucu.
-- ==============================================================================

-- alarms ALTER'i canli trafikte (kopru UPDATE'leri) uzun kilit beklemesin: 5 sn'de vazgec, yeniden denenir.
SET LOCAL lock_timeout = '5s';

ALTER TABLE alarms ADD COLUMN IF NOT EXISTS ack_requested_sid UUID NULL;

COMMENT ON COLUMN alarms.ack_requested_sid IS 'Cevrimdisi onay istegini yapan servis (PIN) oturumu; kullanici isteginde NULL';
