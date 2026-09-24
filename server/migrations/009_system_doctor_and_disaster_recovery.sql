-- 009_system_doctor_and_disaster_recovery.sql
-- FAZ 6 / ADIM 16: Sistem Doktoru & Buluttan Tek Tıkla Pano Değişimi

-- 1. CİHAZ TABLOSUNA SNAPSHOT VE DURUM SÜTUNLARI
ALTER TABLE devices ADD COLUMN IF NOT EXISTS config_snapshot JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS device_status VARCHAR(30) DEFAULT 'ACTIVE';

-- 2. PANO DEĞİŞİMİ VE FELAKET KURTARMA GÜNLÜĞÜ (DEVICE_REPLACEMENT_LOGS)
CREATE TABLE IF NOT EXISTS device_replacement_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    home_id UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    old_device_uuid VARCHAR(64) NOT NULL,
    new_device_uuid VARCHAR(64) NOT NULL,
    replaced_by_user_id UUID NOT NULL REFERENCES users(id),
    endpoints_migrated_count INT DEFAULT 0,
    config_snapshot JSONB,
    reason TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_device_replacement_home ON device_replacement_logs(home_id);
CREATE INDEX IF NOT EXISTS idx_device_replacement_new ON device_replacement_logs(new_device_uuid);
CREATE INDEX IF NOT EXISTS idx_device_replacement_old ON device_replacement_logs(old_device_uuid);

