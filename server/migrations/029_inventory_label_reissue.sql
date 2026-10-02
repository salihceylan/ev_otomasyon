-- ==============================================================================
-- Migration 029: Envanter etiketi yeniden uretimi - denetim sutunlari (WP-B2)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 029_inventory_label_reissue.sql
--
-- POST /admin/inventory/:uid/reissue-label (yalniz super_user, yalniz IN_STOCK ve hicbir daireye
-- baglanmamis cihaz): kayip/hasarli etiketin yerine YENI kurulum PIN'i + YENI yerel anahtar uretilir
-- (PIN: pin.js HMAC ozeti; yerel anahtar: secret_box ile sifreli). Eski PIN ozeti uzerine yazilir
-- (eski etiket gecersiz olur).
--   * label_reissued_at   : son yeniden uretim zamani (NULL = hic yeniden uretilmedi)
--   * label_reissue_count : kac kez yeniden uretildi (operasyonel denetim; PIN/anahtar DEGERI saklanmaz)
-- Her yeniden uretim ayrica device_audit_logs'a 'inventory_label_reissued' olayi olarak yazilir.

ALTER TABLE device_inventory ADD COLUMN IF NOT EXISTS label_reissued_at TIMESTAMPTZ;
ALTER TABLE device_inventory ADD COLUMN IF NOT EXISTS label_reissue_count INT NOT NULL DEFAULT 0;

COMMENT ON COLUMN device_inventory.label_reissued_at IS 'Etiket (PIN + yerel anahtar) en son yeniden uretildigi an; NULL = hic';
COMMENT ON COLUMN device_inventory.label_reissue_count IS 'Etiket yeniden uretim sayisi (denetim); degerler saklanmaz';
