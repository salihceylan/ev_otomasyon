-- ==============================================================================
-- Migration 045 geri doldurma ONIZLEMESI (SALT-OKUNUR; hicbir satiri degistirmez)
-- ==============================================================================
-- Dagitimdan ONCE canli veritabaninda calistirin (045 uygulanmadan; kolonlar henuz yok):
--   psql -v ON_ERROR_STOP=1 -f service_scope_backfill_preview.sql "<baglanti>"
-- (yalniz SELECT; tek bir salt-okunur transaction icinde calistirmak icin: psql --single-transaction
--  ya da basa "BEGIN READ ONLY;" sonuna "ROLLBACK;" ekleyin.)
-- Kurallar 045_service_scope.sql ile AYNIDIR:
--   Ev   : role = 'service_user' olan en eski home_users uyesi (kullanicinin kuresel rolu hala 'service_user');
--          yoksa evdeki en eski kartin claimed_by_user_id'si servis ise o; yoksa kok (NULL).
--   Kart : kurulu kart -> evinin servisi; stoktaki kart -> kok (NULL).
--   Site : sites.created_by hala 'service_user' ise o; yoksa kok.
-- Sonuc kumeleri: (1) ev basina secilecek servis, (2) ayni evde BIRDEN FAZLA servis adayi (elle bakilmali),
-- (3) servis basina ozet, (4) kart sayilari, (5) site basina secim.
-- ==============================================================================

-- (1) EV BASINA: secilecek servis e-postasi, kural, tum servis adaylari, sahip, kart sayisi
WITH cand AS (
  SELECT hu.home_id, hu.user_id, u.email, hu.created_at, hu.id AS hu_id,
         (hu.installer_expires_at IS NULL OR hu.installer_expires_at > NOW()) AS window_open
    FROM home_users hu
    JOIN users u ON u.id = hu.user_id
   WHERE hu.role = 'service_user' AND u.role = 'service_user'
),
rule1 AS (
  SELECT DISTINCT ON (home_id) home_id, user_id, email
    FROM cand
   ORDER BY home_id, created_at ASC NULLS LAST, hu_id ASC
),
rule2 AS (
  SELECT DISTINCT ON (di.claimed_home_id) di.claimed_home_id AS home_id, u.id AS user_id, u.email
    FROM device_inventory di
    JOIN users u ON u.id = di.claimed_by_user_id
   WHERE di.claimed_home_id IS NOT NULL AND u.role = 'service_user'
   ORDER BY di.claimed_home_id, di.claimed_at ASC NULLS LAST, di.id ASC
)
SELECT h.id AS home_id,
       h.name AS home_name,
       COALESCE(r1.email, r2.email) AS secilecek_servis_eposta,
       CASE WHEN r1.user_id IS NOT NULL THEN 'kural1:uyelik'
            WHEN r2.user_id IS NOT NULL THEN 'kural2:kart_sahiplenen'
            ELSE 'kok(NULL)' END AS kural,
       (SELECT string_agg(c.email || CASE WHEN c.window_open THEN '' ELSE ' (pencere bitmis)' END, ', ' ORDER BY c.created_at)
          FROM cand c WHERE c.home_id = h.id) AS tum_servis_adaylari,
       (SELECT string_agg(ou.email, ', ') FROM home_users o JOIN users ou ON ou.id = o.user_id
         WHERE o.home_id = h.id AND o.role = 'owner') AS ev_sahibi_eposta,
       (SELECT COUNT(*) FROM devices d WHERE d.home_id = h.id) AS pano_sayisi,
       h.created_at
  FROM homes h
  LEFT JOIN rule1 r1 ON r1.home_id = h.id
  LEFT JOIN rule2 r2 ON r2.home_id = h.id
 ORDER BY secilecek_servis_eposta NULLS FIRST, h.created_at;

-- (2) BIRDEN FAZLA SERVIS ADAYI olan evler (en eskisi secilir; yanlissa dagitimdan sonra kok aktarir)
SELECT hu.home_id, h.name AS home_name, COUNT(*) AS servis_uyesi_sayisi,
       string_agg(u.email, ', ' ORDER BY hu.created_at) AS adaylar_eskiden_yeniye
  FROM home_users hu
  JOIN users u ON u.id = hu.user_id AND u.role = 'service_user'
  JOIN homes h ON h.id = hu.home_id
 WHERE hu.role = 'service_user'
 GROUP BY hu.home_id, h.name
HAVING COUNT(*) > 1
 ORDER BY servis_uyesi_sayisi DESC, h.name;

-- (3) SERVIS BASINA OZET: kac ev atanacak (kural1 + kural2), kac ev koke kalacak
WITH r1 AS (
  SELECT DISTINCT ON (hu.home_id) hu.home_id, hu.user_id
    FROM home_users hu JOIN users u ON u.id = hu.user_id
   WHERE hu.role = 'service_user' AND u.role = 'service_user'
   ORDER BY hu.home_id, hu.created_at ASC NULLS LAST, hu.id ASC
),
r2 AS (
  SELECT DISTINCT ON (di.claimed_home_id) di.claimed_home_id AS home_id, di.claimed_by_user_id AS user_id
    FROM device_inventory di JOIN users u ON u.id = di.claimed_by_user_id
   WHERE di.claimed_home_id IS NOT NULL AND u.role = 'service_user'
   ORDER BY di.claimed_home_id, di.claimed_at ASC NULLS LAST, di.id ASC
),
pick AS (
  SELECT h.id AS home_id, COALESCE(r1.user_id, r2.user_id) AS service_id
    FROM homes h LEFT JOIN r1 ON r1.home_id = h.id LEFT JOIN r2 ON r2.home_id = h.id
)
SELECT COALESCE(u.email, '(kok - atanmayacak)') AS servis_eposta,
       COUNT(*) AS ev_sayisi,
       COALESCE(SUM((SELECT COUNT(*) FROM device_inventory di WHERE di.claimed_home_id = p.home_id)), 0) AS kurulu_kart_sayisi
  FROM pick p
  LEFT JOIN users u ON u.id = p.service_id
 GROUP BY u.email
 ORDER BY ev_sayisi DESC;

-- (4) KART SAYILARI: stoktaki kartlar koke kalir; kurulu kartlar evinin servisine gider
SELECT status,
       COUNT(*) AS toplam,
       COUNT(*) FILTER (WHERE claimed_home_id IS NULL) AS evsiz_kok_stogu,
       COUNT(*) FILTER (WHERE claimed_home_id IS NOT NULL) AS evli_servise_gidecek_veya_kok
  FROM device_inventory
 GROUP BY status
 ORDER BY status;

-- (5) SITE BASINA: sites.created_by hala servis ise o secilir
SELECT s.id AS site_id, s.name AS site_name, s.deleted_at IS NOT NULL AS silinmis,
       CASE WHEN u.role = 'service_user' THEN u.email ELSE NULL END AS secilecek_servis_eposta,
       u.email AS olusturan_eposta, u.role AS olusturan_rol
  FROM sites s
  LEFT JOIN users u ON u.id = s.created_by
 ORDER BY secilecek_servis_eposta NULLS FIRST, s.name;
