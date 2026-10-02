-- ==============================================================================
-- AHBU Akıllı Ev & Bina Otomasyonu - Cihaz Envanteri ve Yaşam Döngüsü (Faz 6.1)
-- ==============================================================================

-- 1. CİHAZ ENVANTERİ TABLOSU (DEVICE_INVENTORY)
CREATE TABLE IF NOT EXISTS device_inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_uuid VARCHAR(64) UNIQUE NOT NULL,             -- Kart donanım kimliği (Örn: AHBU-S3-PANEL-001)
    mac_address VARCHAR(32) UNIQUE NOT NULL,             -- Cihazın fiziksel MAC adresi (Örn: E8:F6:0A:DD:87:54)
    pin_hash VARCHAR(255) NOT NULL,                      -- 6 haneli Setup PIN'in SHA-256 özeti (Plaintext saklanmaz)
    model VARCHAR(64) DEFAULT 'ESP32-S3-POE-ETH-8DI-8RO',-- Donanım modeli
    batch_no VARCHAR(64) DEFAULT 'BATCH-2026-01',        -- Üretim parti numarası
    status VARCHAR(30) NOT NULL DEFAULT 'IN_STOCK' 
        CHECK (status IN ('IN_STOCK', 'INSTALLED', 'CLAIMED', 'REVOKED')),
    
    -- Brute-Force ve Kötüye Kullanım Koruması (Rate-Limiting & Lockout)
    failed_attempts INT DEFAULT 0,                       -- Hatalı PIN deneme sayısı
    locked_until TIMESTAMPTZ,                            -- 5 hatalı denemede geçici kilitlenme zamanı
    
    -- Sahiplenme (Claiming) Bağlantıları
    claimed_home_id UUID REFERENCES homes(id) ON DELETE SET NULL,
    claimed_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    claimed_at TIMESTAMPTZ,
    installed_at TIMESTAMPTZ,
    
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Hızlı Arama İndeksleri
CREATE INDEX IF NOT EXISTS idx_inventory_uuid ON device_inventory(device_uuid);
CREATE INDEX IF NOT EXISTS idx_inventory_mac ON device_inventory(mac_address);
CREATE INDEX IF NOT EXISTS idx_inventory_status ON device_inventory(status);

-- Otomatik Güncelleme Trigger'ı
DROP TRIGGER IF EXISTS trg_device_inventory_updated ON device_inventory;
CREATE TRIGGER trg_device_inventory_updated 
    BEFORE UPDATE ON device_inventory 
    FOR EACH ROW EXECUTE FUNCTION update_timestamp();

-- NOT (WP-C, denetim 2026-10-01): Bu dosyada daha once SAHADAKI TEST CIHAZININ ENVANTERE EKLENMESI
-- (bilinen, tahmin edilebilir bir PIN ozetiyle) ve `ON CONFLICT ... DO UPDATE` ile durumu IN_STOCK'a
-- GERI ALAN bir tohum (seed) komutu vardi. Dosya yeniden calistirilirsa sahiplenilmis cihaz stoga
-- donup bilinen PIN'le yeniden sahiplenilebiliyordu. Tohum veri migrations/dev_seeds/ altina
-- tasindi (yalnizca gelistirme; uretimde calismaz, PIN ortamdan gelir ve cakismada DOKUNMAZ).

