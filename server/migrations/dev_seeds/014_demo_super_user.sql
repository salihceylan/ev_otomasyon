-- ==============================================================================
-- DEV SEED 014: Gelistirme super kullanicisi   (YALNIZCA GELISTIRME)
-- ==============================================================================
-- Eski migrations/014_super_user_and_service_management.sql icindeki "ilk super kullanici" tohumu
-- buraya tasindi (WP-C, denetim 2026-10-01). Eski tohum sabit bir parola ozetiyle GERCEK bir
-- hesabi super kullanici yapiyor ve yeniden calistirmada parolayi geri yaziyordu; temiz bir uretim
-- veritabaninda bilinen parolali yonetici olusturuyordu.
-- Uretimde ilk super kullanici: `node scripts/create_super_user.js` (parola ortamdan).
--
-- Kullanilan yer tutucular: DEV_PASSWORD_HASH (bcrypt), DEV_SUPER_EMAIL

INSERT INTO users (full_name, email, password_hash, phone, role, is_active)
VALUES (
    'Dev Super Kullanici',
    '{{DEV_SUPER_EMAIL}}',
    '{{DEV_PASSWORD_HASH}}',
    NULL,
    'super_user',
    TRUE
)
ON CONFLICT DO NOTHING;
