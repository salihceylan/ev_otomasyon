-- ==============================================================================
-- Migration 025: Cocuk kilidi NOT NULL + gece huzur saati bicim kisiti (WP-C, C9)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR (migrate.js tek transaction).
--
-- 1. homes.child_lock_enabled / devices.child_lock_enabled: NULL "bilinmiyor" ile "kapali"yi
--    karistiriyordu (010'da DEFAULT FALSE var ama NOT NULL yoktu; acik NULL yazimi mumkundu).
--    Cocuk kilidi TEK DOGRULUK KAYNAGI cihaz bildirimidir (state.child_lock): kopru
--    devices.child_lock_enabled'i yazar ve homes.child_lock_enabled'i bool_and(devices...) ile
--    esitler (src/mqtt_bridge.js). Her iki kolon da ARTIK bos olamaz: once geri doldurma, sonra NOT NULL.
-- 2. homes.peace_notification_time: "HH:MM" (24 saat) bicimi. NULL olabilir (ayarlanmamis).
--    Mevcut degerler once normalize edilir ("9:5" -> "09:05"), duzeltilemeyenler NULL yapilir.

-- ------------------------------------------------------------------------------
-- 1. COCUK KILIDI: geri doldurma + NOT NULL DEFAULT FALSE
-- ------------------------------------------------------------------------------
UPDATE homes SET child_lock_enabled = FALSE WHERE child_lock_enabled IS NULL;
ALTER TABLE homes ALTER COLUMN child_lock_enabled SET DEFAULT FALSE;
ALTER TABLE homes ALTER COLUMN child_lock_enabled SET NOT NULL;

UPDATE devices SET child_lock_enabled = FALSE WHERE child_lock_enabled IS NULL;
ALTER TABLE devices ALTER COLUMN child_lock_enabled SET DEFAULT FALSE;
ALTER TABLE devices ALTER COLUMN child_lock_enabled SET NOT NULL;

-- ------------------------------------------------------------------------------
-- 2. GECE HUZUR SAATI: HH:MM CHECK (NULL olabilir)
-- ------------------------------------------------------------------------------
-- "9:5" gibi duzeltilebilir degerler sifir dolgulanir ("09:05")
UPDATE homes
   SET peace_notification_time = lpad(split_part(peace_notification_time, ':', 1), 2, '0')
                                 || ':' || lpad(split_part(peace_notification_time, ':', 2), 2, '0')
 WHERE peace_notification_time ~ '^[0-9]{1,2}:[0-9]{1,2}$'
   AND peace_notification_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$';

-- hala gecersiz olanlar (25:61, "yok", bos metin ...) NULL: hicbir hatirlatma bunlari yorumlayamaz
UPDATE homes
   SET peace_notification_time = NULL
 WHERE peace_notification_time IS NOT NULL
   AND peace_notification_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$';

ALTER TABLE homes DROP CONSTRAINT IF EXISTS homes_peace_time_format_check;
ALTER TABLE homes ADD CONSTRAINT homes_peace_time_format_check
  CHECK (peace_notification_time IS NULL OR peace_notification_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$');
