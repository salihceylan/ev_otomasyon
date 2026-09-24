-- ==============================================================================
-- AHBU Akıllı Ev & Bina Otomasyonu - ADIM 19: Süper Yönetici & Servis Yönetim Sistemi
-- ==============================================================================

-- 1. users tablosuna sistem seviyesi rol (role) alanı ekleme
ALTER TABLE users 
ADD COLUMN IF NOT EXISTS role VARCHAR(50) NOT NULL DEFAULT 'user';

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check CHECK (
  role IN ('super_user', 'service_user', 'installer', 'user')
);

CREATE INDEX IF NOT EXISTS idx_users_role ON users(role);

-- 2. Servis yöneticisi ve kullanıcı ilişkileri için yardımcı alanlar
ALTER TABLE users
ADD COLUMN IF NOT EXISTS created_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS admin_notes TEXT;

-- 3. İlk Super User (salihceylan@gmail.com / Fingon08.) oluştur veya güncelle
INSERT INTO users (
  full_name,
  email,
  password_hash,
  phone,
  role,
  is_active
)
VALUES (
  'Salih Ceylan',
  'salihceylan@gmail.com',
  '$2a$10$J30D1aJus/VF08a7EtzSD..aiFEyvm/fxY0HBwwYTnmgrwnLDGzAS',
  '+905551234567',
  'super_user',
  TRUE
)
ON CONFLICT (email) DO UPDATE SET
  role = 'super_user',
  password_hash = '$2a$10$J30D1aJus/VF08a7EtzSD..aiFEyvm/fxY0HBwwYTnmgrwnLDGzAS',
  full_name = 'Salih Ceylan',
  is_active = TRUE;

-- 4. Mevcut demo kullanıcıların rollerini senkronize et
UPDATE users SET role = 'super_user' WHERE email = 'salih@gudeteknoloji.com.tr';
UPDATE users SET role = 'installer' WHERE email IN ('ali.montaj@gudeteknoloji.com.tr', 'teknisyen@gudeteknoloji.com.tr', 'teknisyen@ahbu.com');
