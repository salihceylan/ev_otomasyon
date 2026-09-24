-- ==============================================================================
-- AHBU Akıllı Ev & Bina Otomasyonu - ADIM 10: Refresh & Password Reset Şeması
-- ==============================================================================

-- 1. REFRESH TOKENS (1 Yıllık Uzun Ömürlü Oturum ve Güvenli İptal Mimarisi)
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    revoked_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_hash ON refresh_tokens(token_hash);

-- 2. PASSWORD RESET TOKENS (OTP & Güvenli Şifre Sıfırlama)
CREATE TABLE IF NOT EXISTS password_reset_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    otp_code VARCHAR(10) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    used BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_password_reset_user ON password_reset_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_users_phone ON users(phone);

