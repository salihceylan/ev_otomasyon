-- ==============================================================================
-- AHBU Akıllı Ev & Bina Otomasyonu - ADIM 11: RBAC & Devreye Alma (Commissioning)
-- ==============================================================================

-- 1. Cihaz Tablosuna Devreye Alma (Commissioning) Alanları
ALTER TABLE devices 
ADD COLUMN IF NOT EXISTS is_commissioned BOOLEAN DEFAULT FALSE,
ADD COLUMN IF NOT EXISTS commissioned_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS commissioned_by UUID REFERENCES users(id),
ADD COLUMN IF NOT EXISTS commissioning_status VARCHAR(50) DEFAULT 'PENDING_INSTALLATION',
ADD COLUMN IF NOT EXISTS commissioning_notes TEXT;

-- 2. Servis Devreye Alma ve Onay Günlüğü (Commissioning Logs)
CREATE TABLE IF NOT EXISTS commissioning_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    home_id UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    device_id UUID REFERENCES devices(id) ON DELETE SET NULL,
    technician_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tests_passed BOOLEAN DEFAULT TRUE,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_commissioning_logs_home ON commissioning_logs(home_id);

