-- Migration 013: Sürtünmesiz Şifre Yenileme & Sıfır-Stres Hesap Kurtarma
BEGIN;

-- users tablosuna token_version ekleme (şifre değiştiğinde tüm eski aktif oturumları anında düşürmek için)
ALTER TABLE users ADD COLUMN IF NOT EXISTS token_version INT NOT NULL DEFAULT 1;

-- Şifre sıfırlama talepleri ve OTP / Magic Link tablosu
CREATE TABLE IF NOT EXISTS password_resets (
  id          SERIAL PRIMARY KEY,
  user_id     UUID REFERENCES users(id) ON DELETE CASCADE,
  identifier  VARCHAR(255) NOT NULL,
  code_hash   VARCHAR(255) NOT NULL,
  token       VARCHAR(255) UNIQUE NOT NULL,
  expires_at  TIMESTAMPTZ NOT NULL,
  used_at     TIMESTAMPTZ,
  attempts    SMALLINT NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_password_resets_identifier ON password_resets(identifier);
CREATE INDEX IF NOT EXISTS idx_password_resets_token ON password_resets(token);
CREATE INDEX IF NOT EXISTS idx_password_resets_expires ON password_resets(expires_at);

COMMIT;
