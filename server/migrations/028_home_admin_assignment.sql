-- ==============================================================================
-- Migration 028: Home Admin atama - mevcut sahip onay kodu (OTP) + atama gunlugu (WP-B2)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 028_home_admin_assignment.sql
--
-- Servis personeli / super yonetici bir eve YENI "Home Admin" (owner) atarken (POST
-- /service/subscribers/:homeId/assign-admin) mevcut sahibin RIZASI zorunludur:
--   * home_admin_assign_otps : mevcut sahibe e-postayla giden 6 haneli onay kodunun OZETI (pin.js HMAC).
--     Kod HEDEF KISIYE baglidir (target_identifier): sahip "X kisisine devredilecek" onayini verir;
--     personel kodu baska birine atamak icin kullanamaz. Ev basina tek satir (yeni istek eskisini
--     degistirir); deneme sayaci 15 dk'lik pencerede tutulur ve yeniden istekle SIFIRLANMAZ
--     (device_claim_otps ile ayni kural).
--   * home_admin_assignment_logs : atamanin kalici DENETIM kaydi (kim, hangi IP, hangi mod, onceki
--     sahipler, yeni sahip, zorlama gerekcesi). Sir ICERMEZ (kod, parola yok).
--     mode: no_owner (sahip yoktu), owner_consent (sahip OTP ile onayladi),
--           forced (sahibe ulasilamadi; YALNIZ super_user, gerekce >= 15 karakter).

CREATE TABLE IF NOT EXISTS home_admin_assign_otps (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id            UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  owner_user_id      UUID REFERENCES users(id) ON DELETE CASCADE,
  target_identifier  VARCHAR(255) NOT NULL,
  target_name        VARCHAR(100),
  otp_hash           VARCHAR(255) NOT NULL,
  expires_at         TIMESTAMPTZ NOT NULL,
  attempts           SMALLINT NOT NULL DEFAULT 0,
  window_started_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  requested_by       UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_home_admin_assign_otps_home UNIQUE (home_id)
);

CREATE INDEX IF NOT EXISTS idx_home_admin_assign_otps_expires ON home_admin_assign_otps (expires_at);
CREATE INDEX IF NOT EXISTS idx_home_admin_assign_otps_owner ON home_admin_assign_otps (owner_user_id);

CREATE TABLE IF NOT EXISTS home_admin_assignment_logs (
  id                  BIGSERIAL PRIMARY KEY,
  home_id             UUID REFERENCES homes(id) ON DELETE SET NULL,
  home_name           VARCHAR(100),
  actor_user_id       UUID REFERENCES users(id) ON DELETE SET NULL,
  actor_role          VARCHAR(30),
  ip_address          VARCHAR(64),
  mode                VARCHAR(20) NOT NULL CHECK (mode IN ('no_owner', 'owner_consent', 'forced')),
  previous_owner_ids  JSONB NOT NULL DEFAULT '[]'::jsonb,
  new_owner_id        UUID REFERENCES users(id) ON DELETE SET NULL,
  account_created     BOOLEAN NOT NULL DEFAULT FALSE,
  reason              TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_home_admin_assignment_logs_home ON home_admin_assignment_logs (home_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_home_admin_assignment_logs_new_owner ON home_admin_assignment_logs (new_owner_id);
