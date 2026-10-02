-- ==============================================================================
-- Migration 027: Hesap silme - yumusak silme + anonimlestirme (WP-B2, denetim 2026-10-01)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 027_account_deletion.sql
--
-- Amac: DELETE /api/v1/auth/account (magaza gereksinimi: uygulama icinden hesap silme).
-- Silme FIZIKSEL DEGILDIR: kullanici satiri korunur (denetim/gunluk satirlari ona isaret eder) ama
-- tum kisisel veri anonimlestirilir:
--   email      -> 'deleted+<kullanici-id>@deleted.invalid'  (benzersiz; ESKI E-POSTA SERBEST KALIR,
--                 ayni adresle yeniden kayit olunabilir)
--   phone, google_id, apple_id -> NULL (kismi UNIQUE indeksler serbest kalir)
--   full_name  -> 'Silinmiş Kullanıcı'
--   is_active  -> FALSE, account_status -> 'deleted', deleted_at -> silme zamani
--
-- 1. users.deleted_at
-- 2. users.account_status CHECK: 'deleted' degeri eklenir (018'deki kume + 'deleted').
--    'deleted' ayri bir durumdur: yonetici "aktiflestir" islemi silinmis hesabi canlandiramaz
--    (admin_user_service durumu 'suspended'dan baska bir degere cevirmez).
-- 3. Tutarlilik: account_status = 'deleted'  <=>  deleted_at dolu.

ALTER TABLE users ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_account_status_check;
ALTER TABLE users ADD CONSTRAINT users_account_status_check
  CHECK (account_status IN ('active', 'pending_invite', 'suspended', 'deleted'));

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_deleted_consistency_check;
ALTER TABLE users ADD CONSTRAINT users_deleted_consistency_check
  CHECK ((account_status = 'deleted') = (deleted_at IS NOT NULL));

-- Saklama suresi sonunda kalici silme / raporlama sorgulari icin
CREATE INDEX IF NOT EXISTS idx_users_deleted_at ON users (deleted_at) WHERE deleted_at IS NOT NULL;

COMMENT ON COLUMN users.deleted_at IS 'Hesap silme (anonimlestirme) zamani; NULL = silinmemis. Satir korunur, kisisel veri anonimlestirilir.';
