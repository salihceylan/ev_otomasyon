-- ==============================================================================
-- Migration 043: Sahiplik donemi, kabul kayitlarinin silinmeden kalmasi, servis oturumu cihaz kimligi isareti, 2026-10-09
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 043_access_end_hardening.sql
--
-- Kapsam (sahip kararlari 14, 15, 17A)
--   homes.ownership_epoch (karar 14): evin sahipligi en son ne zaman el degistirdi (devir kabulu, acil sifirlama,
--     Home Admin atamasi). Alarm gecmisi listesi yalniz bu andan sonra baslayan YA DA hala acik (cleared/lost olmayan)
--     alarmlari gosterir: eski ailenin gecmisi yeni sahibe gorunmez. NULL = sahiplik hic el degistirmedi (filtre yok).
--     Doldurma: tamamlanmis son devir (accepted_at) ve son acil sifirlama kaydi (created_at) - hangisi yeniyse.
--   legal_acceptances.user_id (karar 15): NOT NULL + ON DELETE CASCADE -> NULL olabilir + ON DELETE SET NULL. Yonetici
--     kalici silmesinde kabul satiri ispat amacli kalir, kullanici baglantisi kopar (anonim).
--   service_sessions.device_cred_rotated_at (karar 17A): biten (iptal / suresi dolmus) servis oturumu icin evin cihaz
--     MQTT kimligi dondurulduyse zamani (supurucu bir kez isler). Doldurma: zaten bitmis oturumlar NOW() ile isaretlenir
--     (dagitimda toplu kimlik dondurmesi olmaz).
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001 (homes), 008 (home_transfers, emergency_reset_logs), 018 (service_sessions),
--   039 (legal_acceptances).
-- Rolling deploy: yeni kolonlar NULL ve varsayilansizdir (tablolar yeniden yazilmaz); eski kod gormezden gelir. FK
--   degisimi kisa ACCESS EXCLUSIVE kilidi alir (kucuk tablo). Yeni kod 043'suz veritabaninda alarm listesinde ve
--   servis oturumu supurmesinde 42703 alir. Sira: once migration, sonra sunucu.
-- ==============================================================================

-- ALTER'lar canli trafikte uzun kilit beklemesin: 5 sn'de vazgec, yeniden denenir.
SET LOCAL lock_timeout = '5s';

-- --- Karar 14: sahiplik donemi -------------------------------------------------
ALTER TABLE homes ADD COLUMN IF NOT EXISTS ownership_epoch TIMESTAMPTZ NULL;
COMMENT ON COLUMN homes.ownership_epoch IS 'Sahipligin son el degistirdigi an (devir kabulu / acil sifirlama / Home Admin atamasi); alarm gecmisi bu andan sonrasini ya da acik alarmlari gosterir';

UPDATE homes h
   SET ownership_epoch = x.epoch
  FROM (
    SELECT home_id, MAX(at) AS epoch
      FROM (
        SELECT home_id, accepted_at AS at FROM home_transfers WHERE status = 'COMPLETED' AND accepted_at IS NOT NULL
        UNION ALL
        SELECT home_id, created_at AS at FROM emergency_reset_logs WHERE home_id IS NOT NULL AND created_at IS NOT NULL
      ) s
     GROUP BY home_id
  ) x
 WHERE h.id = x.home_id
   AND h.ownership_epoch IS NULL;

-- --- Karar 15: kabul kaydi kalici silmede kalir (anonim) -------------------------
ALTER TABLE legal_acceptances ALTER COLUMN user_id DROP NOT NULL;
ALTER TABLE legal_acceptances DROP CONSTRAINT IF EXISTS legal_acceptances_user_id_fkey;
ALTER TABLE legal_acceptances
  ADD CONSTRAINT legal_acceptances_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL;
COMMENT ON COLUMN legal_acceptances.user_id IS 'Kabul eden kullanici; hesap kalici silinince NULL (kabul satiri ispat icin kalir)';

-- --- Karar 17A: servis oturumu bitince cihaz MQTT kimligi dondurmesi -----------------
ALTER TABLE service_sessions ADD COLUMN IF NOT EXISTS device_cred_rotated_at TIMESTAMPTZ NULL;
COMMENT ON COLUMN service_sessions.device_cred_rotated_at IS 'Oturum bittikten sonra evin cihaz MQTT kimligi donduruldu (supurucu bir kez isler); NULL = islenmedi';

UPDATE service_sessions
   SET device_cred_rotated_at = NOW()
 WHERE device_cred_rotated_at IS NULL
   AND (revoked_at IS NOT NULL OR expires_at <= NOW());
