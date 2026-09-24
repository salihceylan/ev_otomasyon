-- 008_transfer_and_emergency_reset.sql
-- FAZ 6 / ADIM 13: Daire Devri, Eski Ailenin Azli & Acil Sıfırlama

-- 1. DAİRE DEVİR İŞLEMLERİ TABLOSU (HOME_TRANSFERS)
CREATE TABLE IF NOT EXISTS home_transfers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    home_id UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    from_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target_identifier VARCHAR(255),
    transfer_code VARCHAR(32) UNIQUE NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING' 
        CHECK (status IN ('PENDING', 'COMPLETED', 'CANCELLED', 'EXPIRED')),
    expires_at TIMESTAMPTZ NOT NULL,
    accepted_by UUID REFERENCES users(id),
    accepted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_home_transfers_code ON home_transfers(transfer_code);
CREATE INDEX IF NOT EXISTS idx_home_transfers_home ON home_transfers(home_id);
CREATE INDEX IF NOT EXISTS idx_home_transfers_status ON home_transfers(status);

-- 2. ACİL SERVİS SIFIRLAMA GÜNLÜĞÜ (EMERGENCY_RESET_LOGS)
CREATE TABLE IF NOT EXISTS emergency_reset_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_uuid VARCHAR(64) NOT NULL,
    home_id UUID REFERENCES homes(id) ON DELETE SET NULL,
    installer_user_id UUID NOT NULL REFERENCES users(id),
    reason TEXT NOT NULL,
    new_owner_identifier VARCHAR(255),
    previous_owner_ids JSONB,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_emergency_reset_device ON emergency_reset_logs(device_uuid);
CREATE INDEX IF NOT EXISTS idx_emergency_reset_installer ON emergency_reset_logs(installer_user_id);

