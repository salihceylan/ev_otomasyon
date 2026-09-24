-- Migration 012: Sosyal & Şifresiz Giriş (Google, Apple, Telefon OTP)
BEGIN;

-- users tablosuna google_id ve apple_id ekleme
ALTER TABLE users ADD COLUMN IF NOT EXISTS google_id VARCHAR(255);
ALTER TABLE users ADD COLUMN IF NOT EXISTS apple_id VARCHAR(255);

CREATE INDEX IF NOT EXISTS idx_users_google_id ON users(google_id) WHERE google_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_users_apple_id ON users(apple_id) WHERE apple_id IS NOT NULL;

-- Telefon OTP doğrulama tablosu
CREATE TABLE IF NOT EXISTS phone_otp_codes (
  id          SERIAL PRIMARY KEY,
  phone       VARCHAR(50) NOT NULL,
  otp_hash    VARCHAR(255) NOT NULL,
  expires_at  TIMESTAMPTZ NOT NULL,
  attempts    SMALLINT NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_phone_otp_phone ON phone_otp_codes(phone);
CREATE INDEX IF NOT EXISTS idx_phone_otp_expires ON phone_otp_codes(expires_at);

COMMIT;

