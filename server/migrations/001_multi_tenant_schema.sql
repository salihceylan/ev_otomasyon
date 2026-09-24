-- ==============================================================================
-- AHBU Akıllı Ev & Bina Otomasyonu - Multi-Tenant Veritabanı Şeması (Faz 4.1)
-- ==============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. KULLANICILAR (USERS)
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    phone VARCHAR(30),
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- 2. EVLER / DAİRELER (HOMES)
CREATE TABLE IF NOT EXISTS homes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(100) NOT NULL,
    address TEXT,
    mqtt_username VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_homes_mqtt_username ON homes(mqtt_username);

-- 3. EV - KULLANICI İLİŞKİSİ VE ROLLER (HOME_USERS)
CREATE TABLE IF NOT EXISTS home_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    home_id UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role VARCHAR(30) NOT NULL CHECK (role IN ('owner', 'resident', 'guest', 'installer')),
    installer_expires_at TIMESTAMPTZ, -- Teknisyen için geçici süre (Adım 4.3)
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(home_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_home_users_home ON home_users(home_id);
CREATE INDEX IF NOT EXISTS idx_home_users_user ON home_users(user_id);

-- 4. DONANIM CİHAZLARI (DEVICES - ESP32-S3 ANA KONTROL KARTLARI)
CREATE TABLE IF NOT EXISTS devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    home_id UUID REFERENCES homes(id) ON DELETE SET NULL,
    device_uuid VARCHAR(64) UNIQUE NOT NULL,
    mac_address VARCHAR(32) UNIQUE NOT NULL,
    setup_pin VARCHAR(32) NOT NULL,
    is_claimed BOOLEAN DEFAULT FALSE,
    claimed_at TIMESTAMPTZ,
    claimed_by UUID REFERENCES users(id),
    model VARCHAR(64) DEFAULT 'ESP32-S3-POE-ETH-8DI-8RO',
    firmware_version VARCHAR(32) DEFAULT 'v1.0.0',
    ip_address VARCHAR(45),
    last_seen_at TIMESTAMPTZ,
    is_online BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_devices_mac ON devices(mac_address);
CREATE INDEX IF NOT EXISTS idx_devices_uuid ON devices(device_uuid);
CREATE INDEX IF NOT EXISTS idx_devices_home ON devices(home_id);

-- 5. KONTROL NOKTALARI / RÖLE ÇIKIŞLARI (ENDPOINTS - LAMBA, PANJUR, PRİZ)
CREATE TABLE IF NOT EXISTS endpoints (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    home_id UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    channel_index INT NOT NULL CHECK (channel_index >= 1 AND channel_index <= 40),
    name VARCHAR(100) NOT NULL,
    type VARCHAR(30) NOT NULL CHECK (type IN ('light', 'shutter', 'impulse', 'plug')),
    room VARCHAR(50) DEFAULT 'Genel',
    shutter_pair_index INT,
    shutter_duration_sec INT DEFAULT 20,
    current_state BOOLEAN DEFAULT FALSE,
    current_position INT DEFAULT 0 CHECK (current_position >= 0 AND current_position <= 100),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(device_id, channel_index)
);

CREATE INDEX IF NOT EXISTS idx_endpoints_home ON endpoints(home_id);
CREATE INDEX IF NOT EXISTS idx_endpoints_device ON endpoints(device_id);

-- 6. GEÇİCİ TEKNİSYEN / SERVİS BELİRTEÇLERİ (SERVICE_TOKENS - Adım 4.3)
CREATE TABLE IF NOT EXISTS service_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    home_id UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token VARCHAR(64) UNIQUE NOT NULL,
    service_pin VARCHAR(10) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    is_used BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_service_tokens_token ON service_tokens(token);
CREATE INDEX IF NOT EXISTS idx_service_tokens_pin ON service_tokens(service_pin);

-- 7. OTOMATİK GÜNCELLEME TRİGGER'LARI
CREATE OR REPLACE FUNCTION update_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_users_updated ON users;
CREATE TRIGGER trg_users_updated BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_timestamp();

DROP TRIGGER IF EXISTS trg_homes_updated ON homes;
CREATE TRIGGER trg_homes_updated BEFORE UPDATE ON homes FOR EACH ROW EXECUTE FUNCTION update_timestamp();

DROP TRIGGER IF EXISTS trg_devices_updated ON devices;
CREATE TRIGGER trg_devices_updated BEFORE UPDATE ON devices FOR EACH ROW EXECUTE FUNCTION update_timestamp();

DROP TRIGGER IF EXISTS trg_endpoints_updated ON endpoints;
CREATE TRIGGER trg_endpoints_updated BEFORE UPDATE ON endpoints FOR EACH ROW EXECUTE FUNCTION update_timestamp();

