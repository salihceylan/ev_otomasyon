-- ==============================================================================
-- AHBU Akıllı Ev - Başlangıç Tohum Verileri (Seed Data)
-- ==============================================================================

-- 1. Demo Kullanıcı (Ev Sahibi)
INSERT INTO users (id, email, password_hash, full_name, phone)
VALUES (
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
    'salih@gudeteknoloji.com.tr',
    crypt('GudeAdmin2026!', gen_salt('bf', 10)),
    'Salih Ceylan',
    '+905551234567'
) ON CONFLICT (email) DO NOTHING;

-- 2. Demo Ev / Daire (home_101)
INSERT INTO homes (id, name, address, mqtt_username)
VALUES (
    'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22',
    'Güde Teknoloji Akıllı Demo Dairesi',
    'Ankara / Çankaya',
    'home_101'
) ON CONFLICT (mqtt_username) DO NOTHING;

-- 3. Ev Sahibi Yetkilendirmesi
INSERT INTO home_users (home_id, user_id, role)
VALUES (
    'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22',
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
    'owner'
) ON CONFLICT (home_id, user_id) DO NOTHING;

-- 4. Aktif Sahadaki ESP32-S3 Cihazı
INSERT INTO devices (id, home_id, device_uuid, mac_address, setup_pin, is_claimed, claimed_at, claimed_by, model, firmware_version, ip_address, is_online)
VALUES (
    'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33',
    'b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22',
    'DEV-S3-8754-AHBU',
    'E8:F6:0A:DD:87:54',
    '889900',
    TRUE,
    CURRENT_TIMESTAMP,
    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
    'ESP32-S3-POE-ETH-8DI-8RO',
    'v1.0.0',
    '192.168.1.30',
    TRUE
) ON CONFLICT (device_uuid) DO NOTHING;

-- 5. Başlangıç Kontrol Noktaları (Endpoints 1..16)
-- Dahili Röle 1-2: Salon Panjuru
INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, shutter_duration_sec, current_position)
VALUES 
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 1, 'Salon Panjur Yukarı', 'shutter', 'Salon', 1, 20, 30),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 2, 'Salon Panjur Aşağı', 'shutter', 'Salon', 1, 20, 30),
-- Dahili Röle 3..8: Lambalar
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 3, 'Salon Avize', 'light', 'Salon', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 4, 'Salon Gizli Led', 'light', 'Salon', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 5, 'Mutfak Ana Aydınlatma', 'light', 'Mutfak', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 6, 'Mutfak Tezgah Üstü', 'light', 'Mutfak', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 7, 'Koridor Spot', 'light', 'Koridor', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 8, 'Giriş Vestiyer Işığı', 'light', 'Antre', NULL, NULL, 0),
-- Harici RS485 Modbus Modülü Röle 9..16
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 9, 'Yatak Odası Ana Lamba', 'light', 'Yatak Odası', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 10, 'Yatak Odası Aplikler', 'light', 'Yatak Odası', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 11, 'Çocuk Odası Işık', 'light', 'Çocuk Odası', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 12, 'Banyo Tavan', 'light', 'Banyo', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 13, 'Balkon Aydınlatma', 'light', 'Balkon', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 14, 'Kombi / Termostat Rölesi', 'impulse', 'Teknik', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 15, 'Akıllı Priz - Kahve Makinesi', 'plug', 'Mutfak', NULL, NULL, 0),
('b0eebc99-9c0b-4ef8-bb6d-6bb9bd380b22', 'c0eebc99-9c0b-4ef8-bb6d-6bb9bd380c33', 16, 'Akıllı Priz - TV Ünitesi', 'plug', 'Salon', NULL, NULL, 0)
ON CONFLICT (device_id, channel_index) DO NOTHING;

