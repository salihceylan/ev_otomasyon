-- ==============================================================================
-- DEV SEED 002: Demo ev, ev sahibi, cihaz ve kanallar   (YALNIZCA GELISTIRME)
-- ==============================================================================
-- Eski migrations/002_seed_initial_data.sql buraya tasindi (WP-C, denetim 2026-10-01).
-- Calistirma: `ALLOW_DEV_SEEDS=true DEV_SEED_PASSWORD=... DEV_SEED_PIN=... MIGRATE_CONFIRM=<db> \
--              node scripts/seed_dev.js`   (uretimde calismaz; bkz. scripts/seed_dev.js)
--
-- SIR YOK: parola ozeti ve PIN ortamdan uretilir ve calistirici tarafindan asagidaki
-- DEV_* yer tutucularina (cift suslu parantezli adlar) yazilir. Eski dosyadaki sabit demo parolasi/PIN'i ve gercek e-posta adresi
-- kaldirildi. Cakismada MEVCUT SATIRA DOKUNULMAZ (DO NOTHING). Cakisma HEDEFI bilerek belirtilmez:
-- sabit kimlikli satirlar (users/homes/devices) daha once ESKI 002 tohumuyla olusmus bir gelistirme
-- veritabaninda e-posta/uuid yerine birincil anahtardan da cakisabilir; hangi benzersiz kisit olursa olsun
-- satir atlanir ve betik hata vermez.
--
-- Kullanilan yer tutucular: DEV_PASSWORD_HASH (bcrypt), DEV_OWNER_EMAIL

-- 1. Demo ev sahibi
INSERT INTO users (id, email, password_hash, full_name, phone)
VALUES (
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
    '{{DEV_OWNER_EMAIL}}',
    '{{DEV_PASSWORD_HASH}}',
    'Dev Ev Sahibi',
    NULL
) ON CONFLICT DO NOTHING;

-- 2. Demo ev (konu kimligi: h_ + 16 hex)
INSERT INTO homes (id, name, address, mqtt_username)
VALUES (
    'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22',
    'Gelistirme Demo Dairesi',
    'Demo Mah. / Ankara',
    'h_0000000000000101'
) ON CONFLICT DO NOTHING;

-- 3. Ev sahibi yetkilendirmesi
INSERT INTO home_users (home_id, user_id, role)
SELECT 'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', u.id, 'owner'
  FROM users u
 WHERE u.email = '{{DEV_OWNER_EMAIL}}'
ON CONFLICT DO NOTHING;

-- 4. Demo cihaz (duz metin kurulum PIN'i YOK: devices.setup_pin migration 021 ile bosaltildi)
INSERT INTO devices (id, home_id, device_uuid, mac_address, is_claimed, claimed_at, claimed_by, model, firmware_version, ip_address, is_online)
SELECT
    'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33',
    'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22',
    'AHBU-S3-DEV-0001',
    'E8:F6:0A:DD:00:01',
    TRUE,
    CURRENT_TIMESTAMP,
    u.id,
    'ESP32-S3-POE-ETH-8DI-8RO',
    '1.1.0',
    '192.168.1.30',
    FALSE
  FROM users u
 WHERE u.email = '{{DEV_OWNER_EMAIL}}'
ON CONFLICT DO NOTHING;

-- 5. Kontrol noktalari (1 tabanli kanal): 1-2 panjur cifti, 3-8 isik, 9-16 cesitli
INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec, current_position)
VALUES
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 1, 'Salon Panjur Yukari', 'shutter', 'Salon', 1, 20, 30),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 2, 'Salon Panjur Asagi', 'shutter', 'Salon', 1, 20, 30),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 3, 'Salon Avize', 'light', 'Salon', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 4, 'Salon Gizli Led', 'light', 'Salon', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 5, 'Mutfak Ana Aydinlatma', 'light', 'Mutfak', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 6, 'Mutfak Tezgah Ustu', 'light', 'Mutfak', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 7, 'Koridor Spot', 'light', 'Koridor', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 8, 'Giris Vestiyer Isigi', 'light', 'Antre', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 9, 'Yatak Odasi Ana Lamba', 'light', 'Yatak Odasi', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 10, 'Yatak Odasi Aplikler', 'light', 'Yatak Odasi', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 11, 'Cocuk Odasi Isik', 'light', 'Cocuk Odasi', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 12, 'Banyo Tavan', 'light', 'Banyo', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 13, 'Balkon Aydinlatma', 'light', 'Balkon', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 14, 'Kombi / Termostat Rolesi', 'impulse', 'Teknik', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 15, 'Akilli Priz - Kahve Makinesi', 'plug', 'Mutfak', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 16, 'Akilli Priz - TV Unitesi', 'plug', 'Salon', NULL, NULL, 0)
ON CONFLICT DO NOTHING;
