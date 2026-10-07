-- ==============================================================================
-- Migration 034: Gece hatirlatmasi - gaz alarminda atlanan bildirim durumu (Faz 2, WP-G1)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 034_peace_skipped_hazard.sql
-- Tasarim: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md "Faz 2 tasarimi" F2.A.4.
--
-- Kapsam
--   peace_notification_logs.status CHECK kumesine 'skipped_hazard' eklenir: evde acik gaz alarmi varken (alarms
--   kind='gas', status latched|fault|silenced) gece "lambalari kapat" hatirlatmasi gonderilmez (anahtarlama kivilcim
--   kaynagidir). Satir 'skipped_offline' gibi pencere icinde yeniden denenir (alarm kapanirsa bildirim yine gider).
--   Diger durumlar (030) AYNEN kalir; mevcut satirlar degismez.
--
-- Rolling deploy: once migration, sonra yeni kod (yeni kod 'skipped_hazard' yazar; eski kod yazmaz). Eski kod yeni
-- degeri gorurse satiri nihai sayar (aday elemesi yalniz bildigi durumlari yeniden dener): en kotu durumda o gece
-- bildirim gitmez (guvenli taraf).
--
-- Bagimlilik: 030 (peace_logs_status_check). 033 ile iliskisi yok (alarms tablosu yalniz okunur).
-- ==============================================================================

ALTER TABLE peace_notification_logs DROP CONSTRAINT IF EXISTS peace_logs_status_check;
ALTER TABLE peace_notification_logs ADD CONSTRAINT peace_logs_status_check
  CHECK (status IN ('manual', 'claimed', 'sending', 'clear', 'sent', 'no_recipients', 'skipped_offline', 'skipped_hazard', 'failed', 'resolved')) NOT VALID;
ALTER TABLE peace_notification_logs VALIDATE CONSTRAINT peace_logs_status_check;

COMMENT ON COLUMN peace_notification_logs.status IS 'manual | claimed | sending | clear | sent | no_recipients | skipped_offline | skipped_hazard | failed | resolved';
