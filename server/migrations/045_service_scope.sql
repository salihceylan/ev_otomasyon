-- ==============================================================================
-- Migration 045: Servis sorumlusu kapsami (kiracilik): homes / device_inventory / sites.service_owner_id, 2026-10-12
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 045_service_scope.sql
-- Kolon/dizin ekleme tekrarda no-op'tur. GERI DOLDURMA yalniz kolonlar ILK KEZ eklendiginde calisir (tekrarda atlanir):
-- kok'un sonradan bilerek NULL biraktigi / baska servise aktardigi kayit yeniden atanmaz.
--
-- Kapsam (sahip karari 2026-10-12; tasarim: docs/superpowers/specs/2026-10-12-servis-kapsamli-super-yetki-design.md)
--   homes.service_owner_id, device_inventory.service_owner_id, sites.service_owner_id
--     UUID NULL REFERENCES users(id) ON DELETE SET NULL + dizin. NULL = kok yonetici (super_user) kapsami.
--     Servis hesabi silinirse kapsami koke duser (NULL).
--   Musteri kapsami KOLONSUZDUR: servisin evlerinde uyesi olan ya da users.created_by_user_id = servis olan 'user'.
--
-- Geri doldurma (eski kayitlar; her kural yalniz service_owner_id IS NULL satirlara dokunur):
--   Ev    : role = 'service_user' olan en eski home_users uyesi, kullanicinin KURESEL rolu hala 'service_user' ise;
--           yoksa evdeki en eski kartin claimed_by_user_id'si servis ise o; yoksa NULL (kok).
--   Kart  : kurulu kart (claimed_home_id dolu) -> evinin servisi; stoktaki kart -> NULL (kartlari bugune dek yalniz kok kaydetti).
--   Site  : sites.created_by kullanicisi hala 'service_user' ise o; yoksa NULL.
--   Uyelik: servisin kendi evindeki 'service_user' uyeliginin kurulum penceresi (installer_expires_at) kaldirilir ve
--           uyeligi olmayan servis sahibine suresiz uyelik acilir (kendi kapsaminda 72 saat siniri yoktur; uygulama ev
--           listesi, kurallar ve MQTT kimligi uyelik satirini okur).
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001 (homes, home_users), 003 (device_inventory), 014 (users.created_by_user_id),
--   035 (sites).
-- Rolling deploy: yeni kolonlar NULL ve varsayilansizdir (tablolar yeniden yazilmaz); eski kod gormezden gelir. Yeni
--   kod 045'siz veritabaninda 42703 alir. Sira: once migration, sonra sunucu. Geri alma: kolonlar NULL'a cekilir ya da
--   kod onceki surume doner (kolonlar zararsiz kalir).
-- Dagitimdan ONCE (salt-okunur) geri doldurma onizlemesi: server/scripts/service_scope_backfill_preview.sql
-- ==============================================================================

-- ALTER'lar canli trafikte uzun kilit beklemesin: 5 sn'de vazgec, yeniden denenir.
SET LOCAL lock_timeout = '5s';

-- Geri doldurma bayragi (oturum duzeyi: dosya transaction disinda calistirilsa da kalir): kolonlar HENUZ yoksa 'on'.
SELECT set_config(
  'migration.m045_fresh',
  CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns
                     WHERE table_schema = current_schema() AND table_name = 'homes' AND column_name = 'service_owner_id')
       THEN 'off' ELSE 'on' END,
  false
);

-- --- Kolonlar ve dizinler ------------------------------------------------------
ALTER TABLE homes ADD COLUMN IF NOT EXISTS service_owner_id UUID NULL REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE device_inventory ADD COLUMN IF NOT EXISTS service_owner_id UUID NULL REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE sites ADD COLUMN IF NOT EXISTS service_owner_id UUID NULL REFERENCES users(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_homes_service_owner ON homes (service_owner_id) WHERE service_owner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_device_inventory_service_owner ON device_inventory (service_owner_id) WHERE service_owner_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sites_service_owner ON sites (service_owner_id) WHERE service_owner_id IS NOT NULL;

COMMENT ON COLUMN homes.service_owner_id IS 'Evi kuran/devralan servis sorumlusu (kapsam sahibi); NULL = kok yonetici kapsami';
COMMENT ON COLUMN device_inventory.service_owner_id IS 'Karti stoguna kaydeden servis; kurulunca evin servisi; NULL = kok stogu';
COMMENT ON COLUMN sites.service_owner_id IS 'Siteyi acan servis sorumlusu; NULL = kok yonetici kapsami';

-- --- Geri doldurma: ev -----------------------------------------------------------
UPDATE homes h
   SET service_owner_id = x.user_id
  FROM (
    SELECT DISTINCT ON (hu.home_id) hu.home_id, hu.user_id
      FROM home_users hu
      JOIN users u ON u.id = hu.user_id
     WHERE hu.role = 'service_user'
       AND u.role = 'service_user'
     ORDER BY hu.home_id, hu.created_at ASC NULLS LAST, hu.id ASC
  ) x
 WHERE h.id = x.home_id
   AND h.service_owner_id IS NULL
   AND current_setting('migration.m045_fresh', true) = 'on';

UPDATE homes h
   SET service_owner_id = x.user_id
  FROM (
    SELECT DISTINCT ON (di.claimed_home_id) di.claimed_home_id AS home_id, di.claimed_by_user_id AS user_id
      FROM device_inventory di
      JOIN users u ON u.id = di.claimed_by_user_id
     WHERE di.claimed_home_id IS NOT NULL
       AND u.role = 'service_user'
     ORDER BY di.claimed_home_id, di.claimed_at ASC NULLS LAST, di.id ASC
  ) x
 WHERE h.id = x.home_id
   AND h.service_owner_id IS NULL
   AND current_setting('migration.m045_fresh', true) = 'on';

-- --- Geri doldurma: kart (kurulu kart evinin servisine; stok NULL kalir) ------------
UPDATE device_inventory di
   SET service_owner_id = h.service_owner_id
  FROM homes h
 WHERE di.claimed_home_id = h.id
   AND h.service_owner_id IS NOT NULL
   AND di.service_owner_id IS NULL
   AND current_setting('migration.m045_fresh', true) = 'on';

-- --- Geri doldurma: site -------------------------------------------------------------
UPDATE sites s
   SET service_owner_id = s.created_by
  FROM users u
 WHERE u.id = s.created_by
   AND u.role = 'service_user'
   AND s.service_owner_id IS NULL
   AND current_setting('migration.m045_fresh', true) = 'on';

-- --- Servis sahibinin kendi evindeki uyeligi suresiz --------------------------------
UPDATE home_users hu
   SET installer_expires_at = NULL
  FROM homes h
 WHERE hu.home_id = h.id
   AND hu.user_id = h.service_owner_id
   AND hu.role = 'service_user'
   AND hu.installer_expires_at IS NOT NULL
   AND current_setting('migration.m045_fresh', true) = 'on';

INSERT INTO home_users (home_id, user_id, role)
SELECT h.id, h.service_owner_id, 'service_user'
  FROM homes h
 WHERE h.service_owner_id IS NOT NULL
   AND current_setting('migration.m045_fresh', true) = 'on'
   AND NOT EXISTS (SELECT 1 FROM home_users m WHERE m.home_id = h.id AND m.user_id = h.service_owner_id)
ON CONFLICT (home_id, user_id) DO NOTHING;

SELECT set_config('migration.m045_fresh', '', false);
