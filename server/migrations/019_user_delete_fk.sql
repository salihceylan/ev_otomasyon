-- ==============================================================================
-- Migration 019: Kullanici silme icin eksik ON DELETE kurallari (WP-A, A7)
-- ==============================================================================
-- IDEMPOTENT. Icinde BEGIN/COMMIT yoktur (calistirici dosyayi tek transaction'da calistirir).
--
-- Kullanici kalici silinirken (admin "hard delete") ON DELETE kurali olmayan (NO ACTION)
-- referanslar silmeyi engelliyordu ve hata istemciye constraint adiyla sizabiliyordu.
-- Karar (021'deki WP-B karari ile ayni): gunluk/gecmis kayitlari SILINMEZ, kullanici
-- referansi NULL'a doner (ON DELETE SET NULL).
--   home_invitations.used_by     -> SET NULL (davet gecmisi korunur)
--   home_transfers.accepted_by   -> SET NULL (devir gecmisi korunur)
-- (devices/commissioning/emergency/replacement referanslari 021'de ele alinir.)

DO $$
DECLARE
  spec TEXT[][] := ARRAY[
    ['home_invitations', 'used_by'],
    ['home_transfers', 'accepted_by']
  ];
  i INT;
  r RECORD;
BEGIN
  FOR i IN 1 .. array_length(spec, 1) LOOP
    IF to_regclass(spec[i][1]) IS NULL THEN
      CONTINUE;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
       WHERE table_schema = current_schema() AND table_name = spec[i][1] AND column_name = spec[i][2]
    ) THEN
      CONTINUE;
    END IF;
    FOR r IN
      SELECT con.conname
        FROM pg_constraint con
        JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY (con.conkey)
       WHERE con.contype = 'f'
         AND con.conrelid = to_regclass(spec[i][1])
         AND att.attname = spec[i][2]
    LOOP
      EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I', spec[i][1], r.conname);
    END LOOP;
    EXECUTE format(
      'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES users(id) ON DELETE SET NULL',
      spec[i][1], spec[i][1] || '_' || spec[i][2] || '_fkey', spec[i][2]
    );
  END LOOP;
END $$;

CREATE INDEX IF NOT EXISTS idx_home_invitations_used_by ON home_invitations (used_by);
CREATE INDEX IF NOT EXISTS idx_home_transfers_accepted_by ON home_transfers (accepted_by);
CREATE INDEX IF NOT EXISTS idx_users_created_by ON users (created_by_user_id);
