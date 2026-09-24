-- 007_guest_and_invitations.sql
-- FAZ 6 / ADIM 12: Aile İçi Katılım & Dinamik QR / Misafir Yönetimi

-- 1. home_invitations tablosundaki role kısıtlamasını genişlet (guest desteği)
ALTER TABLE home_invitations DROP CONSTRAINT IF EXISTS home_invitations_role_check;
ALTER TABLE home_invitations ADD CONSTRAINT home_invitations_role_check CHECK (role IN ('member', 'owner', 'guest'));

-- 2. home_invitations tablosuna misafir geçerlilik saat aralığı kolonları ekle
ALTER TABLE home_invitations ADD COLUMN IF NOT EXISTS guest_valid_from TIMESTAMPTZ;
ALTER TABLE home_invitations ADD COLUMN IF NOT EXISTS guest_valid_until TIMESTAMPTZ;
ALTER TABLE home_invitations ADD COLUMN IF NOT EXISTS guest_name VARCHAR(100);

-- 3. home_users tablosuna misafir geçerlilik kolonları ekle
ALTER TABLE home_users ADD COLUMN IF NOT EXISTS valid_from TIMESTAMPTZ;
ALTER TABLE home_users ADD COLUMN IF NOT EXISTS valid_until TIMESTAMPTZ;

-- 4. İndeksler
CREATE INDEX IF NOT EXISTS idx_home_users_valid_until ON home_users(valid_until);
CREATE INDEX IF NOT EXISTS idx_home_invitations_valid_until ON home_invitations(guest_valid_until);

