-- ==============================================================================
-- AHBU Akıllı Ev & Bina Otomasyonu - Envanter Sıra No ve Askıya Alma (SUSPENDED)
-- ==============================================================================

-- 1. Sıra No (Serial No) Sütunu Ekle (Otomatik artan sekans)
ALTER TABLE device_inventory 
ADD COLUMN IF NOT EXISTS serial_no BIGSERIAL;

-- 2. Durum Kontrol Kısıtlamasını Güncelle (SUSPENDED Ekle)
ALTER TABLE device_inventory 
DROP CONSTRAINT IF EXISTS device_inventory_status_check;

ALTER TABLE device_inventory 
ADD CONSTRAINT device_inventory_status_check 
CHECK (status IN ('IN_STOCK', 'INSTALLED', 'CLAIMED', 'REVOKED', 'SUSPENDED'));

-- 3. İndeksler
CREATE INDEX IF NOT EXISTS idx_inventory_serial_no ON device_inventory(serial_no);
