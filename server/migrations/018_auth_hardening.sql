-- ==============================================================================
-- Migration 018: Kimlik / oturum sertlestirmesi (WP-A, denetim 2026-10-01)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -f 018_auth_hardening.sql
--
-- Kapsam:
--   1. users: token_version, must_change_password, account_status, email_verified,
--      password_changed_at, last_login_at; e-posta/telefon/google_id/apple_id kismi UNIQUE
--   2. refresh_tokens: aile (family_id), kullanildi (used_at), rotation zinciri, 30 gun ust siniri
--   3. service_tokens: PIN ozeti (pin_hash), tek kullanim (used_at), iptal (revoked_at);
--      duz metin PIN'ler iptal edilir
--   4. service_sessions: tek-ev kapsamli servis oturumlari (kullanici satiri YOK)
--   5. Eski gecici (PIN ile olusan) servis uyelikleri ve "NO_DIRECT_LOGIN" teknisyen hesaplari kapatilir
--   6. OTP / sifre sifirlama tablolari: ozet, deneme, tek kullanim, amac (purpose)
--   7. home_users.role CHECK ('member' -> 'resident'), misafir zaman penceresi CHECK
--   8. home_invitations: rol beyaz listesi (resident/guest), kod ozeti (code_hash)
--   9. home_transfers: kod ozeti (code_hash), duz metin kodlar iptal
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. USERS
-- ------------------------------------------------------------------------------
ALTER TABLE users ADD COLUMN IF NOT EXISTS token_version INT NOT NULL DEFAULT 1;
ALTER TABLE users ADD COLUMN IF NOT EXISTS must_change_password BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS account_status VARCHAR(20) NOT NULL DEFAULT 'active';
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_changed_at TIMESTAMPTZ;
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_login_at TIMESTAMPTZ;

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_account_status_check;
ALTER TABLE users ADD CONSTRAINT users_account_status_check
  CHECK (account_status IN ('active', 'pending_invite', 'suspended'));

-- E-posta: kucuk harf normalizasyonu ve buyuk/kucuk harf duyarsiz UNIQUE.
-- Cakisan kayit varsa index OLUSTURULMAZ, uyari verilir (veri elle temizlenmeli).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'uq_users_email_lower') THEN
    IF EXISTS (SELECT LOWER(TRIM(email)) FROM users GROUP BY LOWER(TRIM(email)) HAVING COUNT(*) > 1) THEN
      RAISE WARNING '[018] users.email buyuk/kucuk harf cakismasi var; uq_users_email_lower OLUSTURULMADI. Cakismalari giderip migration''i yeniden calistirin.';
    ELSE
      UPDATE users SET email = LOWER(TRIM(email)) WHERE email <> LOWER(TRIM(email));
      CREATE UNIQUE INDEX uq_users_email_lower ON users (LOWER(email));
    END IF;
  END IF;
END $$;

-- Telefon: kismi UNIQUE (bos olmayanlar). Ayni telefona bagli iki hesap, telefon OTP
-- girisinde rastgele hesaba oturum acilmasina yol acar.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'uq_users_phone') THEN
    IF EXISTS (SELECT phone FROM users WHERE phone IS NOT NULL AND phone <> '' GROUP BY phone HAVING COUNT(*) > 1) THEN
      RAISE WARNING '[018] users.phone cakismasi var; uq_users_phone OLUSTURULMADI (uygulama ayni telefonlu hesaplarda telefonla girisi reddeder).';
    ELSE
      CREATE UNIQUE INDEX uq_users_phone ON users (phone) WHERE phone IS NOT NULL AND phone <> '';
    END IF;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'uq_users_google_id') THEN
    IF EXISTS (SELECT google_id FROM users WHERE google_id IS NOT NULL GROUP BY google_id HAVING COUNT(*) > 1) THEN
      RAISE WARNING '[018] users.google_id cakismasi var; uq_users_google_id OLUSTURULMADI.';
    ELSE
      CREATE UNIQUE INDEX uq_users_google_id ON users (google_id) WHERE google_id IS NOT NULL;
    END IF;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'uq_users_apple_id') THEN
    IF EXISTS (SELECT apple_id FROM users WHERE apple_id IS NOT NULL GROUP BY apple_id HAVING COUNT(*) > 1) THEN
      RAISE WARNING '[018] users.apple_id cakismasi var; uq_users_apple_id OLUSTURULMADI.';
    ELSE
      CREATE UNIQUE INDEX uq_users_apple_id ON users (apple_id) WHERE apple_id IS NOT NULL;
    END IF;
  END IF;
END $$;

-- ------------------------------------------------------------------------------
-- 2. REFRESH TOKENS (opak, yalnizca SHA-256 ozeti; rotation + yeniden kullanim tespiti)
-- ------------------------------------------------------------------------------
ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS family_id UUID;
ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS used_at TIMESTAMPTZ;
ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS replaced_by UUID;
ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS revoked_reason VARCHAR(40);
ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS created_ip VARCHAR(64);

UPDATE refresh_tokens SET family_id = id WHERE family_id IS NULL;
ALTER TABLE refresh_tokens ALTER COLUMN family_id SET NOT NULL;

-- Eski 365 gunluk oturumlar en fazla 30 gune kirpilir.
UPDATE refresh_tokens
   SET expires_at = NOW() + INTERVAL '30 days'
 WHERE revoked_at IS NULL
   AND expires_at > NOW() + INTERVAL '30 days';

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_family ON refresh_tokens (family_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user_active ON refresh_tokens (user_id) WHERE revoked_at IS NULL;

-- ------------------------------------------------------------------------------
-- 3. SERVICE TOKENS (ev sahibinin urettigi servis PIN'i)
-- ------------------------------------------------------------------------------
ALTER TABLE service_tokens ADD COLUMN IF NOT EXISTS pin_hash VARCHAR(80);
ALTER TABLE service_tokens ADD COLUMN IF NOT EXISTS used_at TIMESTAMPTZ;
ALTER TABLE service_tokens ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;
ALTER TABLE service_tokens ALTER COLUMN service_pin DROP NOT NULL;
ALTER TABLE service_tokens ALTER COLUMN token DROP NOT NULL;

-- Duz metin PIN'ler gecersiz kilinir ve silinir.
UPDATE service_tokens
   SET revoked_at = COALESCE(revoked_at, NOW()),
       service_pin = NULL,
       token = NULL
 WHERE service_pin IS NOT NULL OR token IS NOT NULL;

DROP INDEX IF EXISTS idx_service_tokens_pin;
-- Ayni anda ayni PIN ozetine sahip yalnizca bir aktif kayit olabilir.
CREATE UNIQUE INDEX IF NOT EXISTS uq_service_tokens_active_pin
  ON service_tokens (pin_hash)
  WHERE pin_hash IS NOT NULL AND used_at IS NULL AND revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_service_tokens_home ON service_tokens (home_id);

-- ------------------------------------------------------------------------------
-- 4. SERVICE SESSIONS (PIN ile acilan 2 saatlik, TEK EV kapsamli oturum)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS service_sessions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id          UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  service_token_id UUID REFERENCES service_tokens(id) ON DELETE SET NULL,
  technician_name  VARCHAR(100),
  created_ip       VARCHAR(64),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at       TIMESTAMPTZ NOT NULL,
  revoked_at       TIMESTAMPTZ,
  revoked_reason   VARCHAR(40)
);
CREATE INDEX IF NOT EXISTS idx_service_sessions_home_active ON service_sessions (home_id) WHERE revoked_at IS NULL;

-- ------------------------------------------------------------------------------
-- 5. Eski PIN akisinin biraktigi global yetki kalintilari
-- ------------------------------------------------------------------------------
-- Eski servis-login her PIN girisinde home_users'a 2 saatlik 'service_user' kaydi ekliyordu.
-- Suresi dolmus sureli servis uyelikleri ve eski PIN akisinin hesaplarina ait kayitlar silinir.
-- (WP-B'nin yeni, SURESI DOLMAMIS teknisyen uyelikleri korunur; migration tekrar calissa da guvenli.)
DELETE FROM home_users
 WHERE role = 'service_user'
   AND installer_expires_at IS NOT NULL
   AND (installer_expires_at <= NOW()
        OR user_id IN (SELECT id FROM users WHERE password_hash = 'NO_DIRECT_LOGIN'));
-- Eski akisin olusturdugu, parolayla girilemeyen global 'service_user' hesaplari kapatilir.
UPDATE users
   SET is_active = FALSE,
       account_status = 'suspended',
       token_version = token_version + 1
 WHERE password_hash = 'NO_DIRECT_LOGIN'
   AND (is_active = TRUE OR account_status <> 'suspended');

-- ------------------------------------------------------------------------------
-- 6. OTP / SIFRE SIFIRLAMA
-- ------------------------------------------------------------------------------
-- Telefon OTP: tek kullanim + eski (pepper'siz) ozetli kayitlarin temizligi
ALTER TABLE phone_otp_codes ADD COLUMN IF NOT EXISTS consumed_at TIMESTAMPTZ;
DELETE FROM phone_otp_codes WHERE otp_hash NOT LIKE 'h1$%';
CREATE INDEX IF NOT EXISTS idx_phone_otp_phone_created ON phone_otp_codes (phone, created_at DESC);

-- Sifre sifirlama: sihirli baglanti token'i artik yalnizca SHA-256 ozetiyle tutulur.
ALTER TABLE password_resets ADD COLUMN IF NOT EXISTS token_hash VARCHAR(64);
ALTER TABLE password_resets ADD COLUMN IF NOT EXISTS purpose VARCHAR(20) NOT NULL DEFAULT 'reset';
ALTER TABLE password_resets ALTER COLUMN token DROP NOT NULL;
ALTER TABLE password_resets DROP CONSTRAINT IF EXISTS password_resets_purpose_check;
ALTER TABLE password_resets ADD CONSTRAINT password_resets_purpose_check
  CHECK (purpose IN ('reset', 'account_setup'));
-- Duz metin token'li / pepper'siz kodlu eski talepler gecersiz kilinir.
UPDATE password_resets
   SET used_at = COALESCE(used_at, NOW()),
       token = NULL
 WHERE token IS NOT NULL
    OR (used_at IS NULL AND code_hash NOT LIKE 'h1$%');
CREATE UNIQUE INDEX IF NOT EXISTS uq_password_resets_token_hash ON password_resets (token_hash) WHERE token_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_password_resets_identifier_created ON password_resets (identifier, created_at DESC);

-- Eski (olu kod) OTP tablosu duz metin kod tutuyordu: icerigi silinir.
DO $$
BEGIN
  IF to_regclass('public.password_reset_tokens') IS NOT NULL THEN
    DELETE FROM password_reset_tokens;
  END IF;
END $$;

-- ------------------------------------------------------------------------------
-- 7. HOME_USERS rol ve misafir zaman penceresi
-- ------------------------------------------------------------------------------
UPDATE home_users SET role = 'resident' WHERE role = 'member';
ALTER TABLE home_users DROP CONSTRAINT IF EXISTS home_users_role_check;
ALTER TABLE home_users ADD CONSTRAINT home_users_role_check
  CHECK (role IN ('owner', 'resident', 'guest', 'service_user'));

ALTER TABLE home_users DROP CONSTRAINT IF EXISTS home_users_guest_window_check;
ALTER TABLE home_users ADD CONSTRAINT home_users_guest_window_check
  CHECK (role <> 'guest' OR (valid_until IS NOT NULL AND (valid_from IS NULL OR valid_from < valid_until)))
  NOT VALID;

-- ------------------------------------------------------------------------------
-- 8. HOME_INVITATIONS
-- ------------------------------------------------------------------------------
ALTER TABLE home_invitations ADD COLUMN IF NOT EXISTS code_hash VARCHAR(64);
ALTER TABLE home_invitations ALTER COLUMN invite_code DROP NOT NULL;
ALTER TABLE home_invitations ALTER COLUMN invite_code TYPE VARCHAR(40);

-- Duz metin (6 haneli, tahmin edilebilir) kullanilmamis davetler gecersiz kilinir.
UPDATE home_invitations
   SET expires_at = LEAST(expires_at, NOW()),
       invite_code = NULL
 WHERE code_hash IS NULL AND is_used = FALSE AND invite_code IS NOT NULL;
-- 'owner' daveti artik yok (sahiplik yalnizca devirle); kullanilmamislar kapatilir.
UPDATE home_invitations
   SET expires_at = LEAST(expires_at, NOW())
 WHERE role = 'owner' AND is_used = FALSE AND expires_at > NOW();

-- Eski CHECK ('member','owner','guest') 'resident'e izin vermez: once kaldirilir.
ALTER TABLE home_invitations DROP CONSTRAINT IF EXISTS home_invitations_role_check;
UPDATE home_invitations SET role = 'resident' WHERE role = 'member';
ALTER TABLE home_invitations ADD CONSTRAINT home_invitations_role_check
  CHECK (role IN ('resident', 'guest'))
  NOT VALID;
ALTER TABLE home_invitations ALTER COLUMN role SET DEFAULT 'resident';
CREATE UNIQUE INDEX IF NOT EXISTS uq_home_invitations_code_hash ON home_invitations (code_hash) WHERE code_hash IS NOT NULL;

-- ------------------------------------------------------------------------------
-- 9. HOME_TRANSFERS
-- ------------------------------------------------------------------------------
ALTER TABLE home_transfers ADD COLUMN IF NOT EXISTS code_hash VARCHAR(64);
ALTER TABLE home_transfers ALTER COLUMN transfer_code DROP NOT NULL;

-- Duz metin (6 haneli) bekleyen devirler iptal edilir; eski kodlar silinir.
UPDATE home_transfers
   SET status = 'CANCELLED'
 WHERE status = 'PENDING' AND code_hash IS NULL;
UPDATE home_transfers SET transfer_code = NULL WHERE code_hash IS NULL AND transfer_code IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_home_transfers_code_hash ON home_transfers (code_hash) WHERE code_hash IS NOT NULL;
-- Bir evde ayni anda yalnizca bir bekleyen devir.
CREATE UNIQUE INDEX IF NOT EXISTS uq_home_transfers_pending_home ON home_transfers (home_id) WHERE status = 'PENDING';
