-- ==============================================================================
-- Migration 041: Telefon dogrulama bayragi (telefon-OTP girisi yalniz dogrulanmis telefona), 2026-10-09
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 041_users_phone_verified.sql
--
-- Kapsam (hesap-uyelik-3, sozlesme C9)
--   users.phone_verified: hesaptaki telefonun sahibinin SMS koduyla (telefon-OTP) dogrulandigi. Kayit, yonetici
--   ekrani ve Home Admin atamasinin yazdigi telefon DOGRULANMAMISTIR (FALSE). Telefon-OTP girisi (verifyPhoneOtp)
--   yalniz dogrulanmis telefona ya da OTP ile acilmis yer tutucu hesaba (phone_<no>@ahbu.local) baglanir; aksi
--   halde 409 PHONE_NOT_VERIFIED (baskasinin numarasiyla kaydolup OTP girisini ele gecirme kapanir).
--   Doldurma: OTP ile acilmis yer tutucu hesaplarin telefonu SMS ile dogrulanmistir -> TRUE.
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001 (users), 018 (uq_users_phone).
-- Rolling deploy: ADD COLUMN ... NOT NULL DEFAULT FALSE tabloyu yeniden yazmaz (PG 11+). Eski kod kolonu gormezden
--   gelir. Yeni kod kolonu okurken to_jsonb kullanir (041'siz veritabaninda giris yollari kopmaz) ama telefon-OTP ile
--   yeni hesap / yonetici telefon degisikligi 42703 alir. Sira: once migration, sonra sunucu.
-- ==============================================================================

-- users ALTER'i canli trafikte (giris UPDATE'leri) uzun kilit beklemesin: 5 sn'de vazgec, yeniden denenir.
SET LOCAL lock_timeout = '5s';

ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_verified BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN users.phone_verified IS 'Telefon SMS koduyla (telefon-OTP) dogrulandi; kayit/yonetici yazdigi telefon FALSE';

-- OTP ile acilmis yer tutucu hesaplar (telefon SMS ile dogrulanmis)
UPDATE users
   SET phone_verified = TRUE
 WHERE phone_verified = FALSE
   AND phone IS NOT NULL
   AND phone <> ''
   AND email ~* '^phone_[0-9]+@ahbu[.]local$';
