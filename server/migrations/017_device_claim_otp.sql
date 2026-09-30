-- Migration 017: Servis Sorumlusu Cihaz Eşleme Müşteri OTP Doğrulama Tablosu
BEGIN;

CREATE TABLE IF NOT EXISTS device_claim_otps (
  id                SERIAL PRIMARY KEY,
  device_uuid       VARCHAR(100) NOT NULL,
  target_identifier VARCHAR(255) NOT NULL,
  otp_hash          VARCHAR(255) NOT NULL,
  expires_at        TIMESTAMPTZ NOT NULL,
  attempts          SMALLINT NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_device_claim_otps_uuid ON device_claim_otps(device_uuid);
CREATE INDEX IF NOT EXISTS idx_device_claim_otps_target ON device_claim_otps(target_identifier);
CREATE INDEX IF NOT EXISTS idx_device_claim_otps_expires ON device_claim_otps(expires_at);

COMMIT;
