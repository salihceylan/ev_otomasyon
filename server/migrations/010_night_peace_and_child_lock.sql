-- Migration 010: Gece Huzur Bildirimi & Yazılımsal Çocuk Kilidi (ADIM 17)

-- 1. Homes tablosuna çocuk kilidi ve gece huzur bildirimi alanları
ALTER TABLE homes 
ADD COLUMN IF NOT EXISTS child_lock_enabled BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS peace_notification_enabled BOOLEAN DEFAULT TRUE,
ADD COLUMN IF NOT EXISTS peace_notification_time VARCHAR(10) DEFAULT '23:30';

-- 2. Devices tablosuna çocuk kilidi durumu
ALTER TABLE devices
ADD COLUMN IF NOT EXISTS child_lock_enabled BOOLEAN DEFAULT FALSE;

-- 3. Gece Huzur Bildirimi ve Toplu Kapatma Logları (homes.id UUID tipiyle uyumlu)
CREATE TABLE IF NOT EXISTS peace_notification_logs (
    id SERIAL PRIMARY KEY,
    home_id UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    triggered_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    open_lights_count INTEGER DEFAULT 0,
    open_shutters_count INTEGER DEFAULT 0,
    summary_text TEXT,
    resolved_by_user BOOLEAN DEFAULT FALSE,
    resolved_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX IF NOT EXISTS idx_peace_notif_home ON peace_notification_logs(home_id);

