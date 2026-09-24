-- 004_home_invitations_schema.sql
-- FAZ 9: Aile Bireyleri Paylaşımı ve Davet Sistemi

CREATE TABLE IF NOT EXISTS home_invitations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    home_id UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    invite_code VARCHAR(16) UNIQUE NOT NULL,
    role VARCHAR(20) DEFAULT 'member' CHECK (role IN ('member', 'owner')),
    expires_at TIMESTAMPTZ NOT NULL,
    is_used BOOLEAN DEFAULT FALSE,
    used_by UUID REFERENCES users(id),
    used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_home_invitations_code ON home_invitations(invite_code);
CREATE INDEX IF NOT EXISTS idx_home_invitations_home ON home_invitations(home_id);

