-- ==============================================================================
-- Migration 042: Telefon numaralarinin kanonik bicimi (TR cep: E.164 "+905XXXXXXXXX"), 2026-10-09
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 042_phone_canonical.sql
--
-- Kapsam (karar 11)
--   Sunucu (src/utils/phone.js) TR cep numaralarini 05XXXXXXXXX, 905XXXXXXXXX, +905XXXXXXXXX, 5XXXXXXXXX ve
--   00905XXXXXXXXX yazimlarindan "+905XXXXXXXXX" bicimine cevirir; TR disi "+..." numara oldugu gibi kalir. Bu dosya
--   mevcut kimlik telefonlarini ayni kurala gore cevirir:
--     users.phone                          kanonik bicime. CAKISMA: kanonik deger baska bir hesapta zaten varsa ya da
--                                          baska bir hesabin telefonu da ayni kanonik degere donusuyorsa satir
--                                          DEGISTIRILMEZ (uq_users_phone ihlali olmaz; bu hesaplar telefonla girisi
--                                          eskisi gibi yapamaz, yonetici ekranindan duzeltilir).
--     phone_otp_codes.phone                kullanilmamis kodlar (benzersizlik yok)
--     home_transfers.target_identifier     yalniz bekleyen (PENDING) ve telefon bicimindeki hedefler
--     home_admin_assign_otps.target_identifier  telefon bicimindeki hedefler
--   E-posta degerlerine ve yer tutucu e-postalara (phone_<no>@ahbu.local) dokunulmaz.
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001 (users), 012 (phone_otp_codes), 008 (home_transfers), 028
--   (home_admin_assign_otps), 018 (uq_users_phone).
-- Rolling deploy: yalniz veri; eski kod kanonik degeri de gecerli telefon sayar (10-15 hane, basta +).
-- ==============================================================================

-- users UPDATE'i canli trafikte (giris UPDATE'leri) uzun kilit beklemesin: 5 sn'de vazgec, yeniden denenir.
SET LOCAL lock_timeout = '5s';

WITH norm AS (
  SELECT id,
         phone,
         CASE WHEN regexp_replace(phone, '[[:space:]().-]', '', 'g') ~ '^(\+90|0090|90|0)?5[0-9]{9}$'
              THEN '+90' || right(regexp_replace(phone, '[[:space:]().-]', '', 'g'), 10)
         END AS canon
    FROM users
   WHERE phone IS NOT NULL AND phone <> ''
), targets AS (
  -- Cakisan satirlar atlanir: kanonik deger baska hesapta var ya da baska hesap da ayni degere donusuyor.
  SELECT n.id, n.canon
    FROM norm n
   WHERE n.canon IS NOT NULL
     AND n.canon <> n.phone
     AND NOT EXISTS (SELECT 1 FROM norm o WHERE o.id <> n.id AND (o.phone = n.canon OR o.canon = n.canon))
)
UPDATE users u
   SET phone = t.canon
  FROM targets t
 WHERE u.id = t.id;

UPDATE phone_otp_codes
   SET phone = '+90' || right(regexp_replace(phone, '[[:space:]().-]', '', 'g'), 10)
 WHERE consumed_at IS NULL
   AND regexp_replace(phone, '[[:space:]().-]', '', 'g') ~ '^(\+90|0090|90|0)?5[0-9]{9}$'
   AND phone <> '+90' || right(regexp_replace(phone, '[[:space:]().-]', '', 'g'), 10);

UPDATE home_transfers
   SET target_identifier = '+90' || right(regexp_replace(target_identifier, '[[:space:]().-]', '', 'g'), 10)
 WHERE status = 'PENDING'
   AND target_identifier IS NOT NULL
   AND regexp_replace(target_identifier, '[[:space:]().-]', '', 'g') ~ '^(\+90|0090|90|0)?5[0-9]{9}$'
   AND target_identifier <> '+90' || right(regexp_replace(target_identifier, '[[:space:]().-]', '', 'g'), 10);

UPDATE home_admin_assign_otps
   SET target_identifier = '+90' || right(regexp_replace(target_identifier, '[[:space:]().-]', '', 'g'), 10)
 WHERE target_identifier IS NOT NULL
   AND regexp_replace(target_identifier, '[[:space:]().-]', '', 'g') ~ '^(\+90|0090|90|0)?5[0-9]{9}$'
   AND target_identifier <> '+90' || right(regexp_replace(target_identifier, '[[:space:]().-]', '', 'g'), 10);
