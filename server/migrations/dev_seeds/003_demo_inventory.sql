-- ==============================================================================
-- DEV SEED 003: Stokta demo cihaz (sahiplenme akisini denemek icin)   (YALNIZCA GELISTIRME)
-- ==============================================================================
-- Eski migrations/003_device_inventory_schema.sql icindeki "sahadaki test cihazi" tohumu buraya
-- tasindi (WP-C, denetim 2026-10-01). Eski tohum:
--   - bilinen/tahmin edilebilir bir PIN ozeti iceriyordu,
--   - `ON CONFLICT DO UPDATE` ile yeniden calistirmada SAHIPLENILMIS cihazi IN_STOCK'a GERI aliyordu.
-- Burada: PIN ozeti ortamdan (DEV_SEED_PIN) uretilir ve cakismada HICBIR SEY DEGISMEZ.
--
-- Kullanilan yer tutucu: DEV_PIN_HASH (PIN_PEPPER varsa HMAC-SHA256 "h1$...", yoksa gelistirme icin eski SHA-256)

INSERT INTO device_inventory (device_uuid, mac_address, pin_hash, model, batch_no, status)
VALUES (
    'AHBU-S3-DEV-STOCK-01',
    'E8:F6:0A:DD:00:02',
    '{{DEV_PIN_HASH}}',
    'ESP32-S3-POE-ETH-8DI-8RO',
    'BATCH-DEV-01',
    'IN_STOCK'
)
ON CONFLICT DO NOTHING;
