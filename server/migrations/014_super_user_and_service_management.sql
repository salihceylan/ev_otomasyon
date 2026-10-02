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

-- NOT (WP-C, denetim 2026-10-01): Bu dosyada daha once (3) "ilk super kullanici" TOHUMU (sabit
-- parola ozetiyle, yeniden calistirmada parolayi GERI YAZAN `ON CONFLICT DO UPDATE`) ve (4) demo
-- kullanicilarin rol senkronizasyonu vardi. Temiz bir uretim veritabaninda bilinen parolali
-- bir super kullanici olusturdugu icin migrations/dev_seeds/ altina tasindi (yalnizca gelistirme).
-- Uretimde ilk super kullanici `node scripts/create_super_user.js` ile (parola ortamdan) olusturulur.
