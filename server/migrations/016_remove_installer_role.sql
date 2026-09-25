-- ==============================================================================
-- AHBU Akıllı Ev & Bina Otomasyonu - ADIM 20: Teknisyen Rolünü Kaldırma & Servis Sorumlusuna Devretme
-- ==============================================================================

BEGIN;

-- 1. Bağımlı tablolardaki teknisyen (installer) kayıtlarını temizle
DELETE FROM emergency_reset_logs WHERE installer_user_id IN (SELECT id FROM users WHERE role = 'installer');
DELETE FROM device_replacement_logs WHERE replaced_by_user_id IN (SELECT id FROM users WHERE role = 'installer');
DELETE FROM commissioning_logs WHERE technician_id IN (SELECT id FROM users WHERE role = 'installer');
DELETE FROM service_tokens WHERE created_by IN (SELECT id FROM users WHERE role = 'installer');
DELETE FROM refresh_tokens WHERE user_id IN (SELECT id FROM users WHERE role = 'installer');
DELETE FROM password_resets WHERE user_id IN (SELECT id FROM users WHERE role = 'installer');
DELETE FROM password_reset_tokens WHERE user_id IN (SELECT id FROM users WHERE role = 'installer');
DELETE FROM home_transfers WHERE from_user_id IN (SELECT id FROM users WHERE role = 'installer') OR accepted_by IN (SELECT id FROM users WHERE role = 'installer');

-- 2. Cihaz ve ev ilişkilerinde teknisyeni boşa çıkar veya sil
UPDATE devices SET commissioned_by = NULL WHERE commissioned_by IN (SELECT id FROM users WHERE role = 'installer');
UPDATE devices SET claimed_by = NULL WHERE claimed_by IN (SELECT id FROM users WHERE role = 'installer');
UPDATE device_inventory SET claimed_by_user_id = NULL WHERE claimed_by_user_id IN (SELECT id FROM users WHERE role = 'installer');
UPDATE users SET created_by_user_id = NULL WHERE created_by_user_id IN (SELECT id FROM users WHERE role = 'installer');

DELETE FROM home_users WHERE role = 'installer' OR user_id IN (SELECT id FROM users WHERE role = 'installer');

-- 3. Veritabanındaki tüm teknisyen kullanıcıları sil
DELETE FROM users WHERE role = 'installer';

-- 4. Rol kısıtlamasını güncelle (super_user, service_user, user)
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check CHECK (
  role IN ('super_user', 'service_user', 'user')
);

-- home_users tablosundaki rol kısıtlamasını güncelle
ALTER TABLE home_users DROP CONSTRAINT IF EXISTS home_users_role_check;
ALTER TABLE home_users ADD CONSTRAINT home_users_role_check CHECK (
  role IN ('owner', 'resident', 'guest', 'service_user')
);

COMMIT;
