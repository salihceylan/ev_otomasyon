-- ==============================================================================
-- Migration 039: Yasal metin kabulleri (Kullanici Sozlesmesi), 2026-10-08
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 039_legal_acceptances.sql
--
-- Kapsam
--   1. users.terms_version / terms_accepted_at: kullanicinin EN SON kabul ettigi Kullanici Sozlesmesi surumu ve
--      zamani. NULL = hic kabul edilmedi. publicUser.legal (needs_acceptance) bunlardan hesaplanir.
--   2. legal_acceptances: her kabulun kaydi (kim, hangi belge, hangi surum, ne zaman, istemci IP'si ve User-Agent'i
--      en cok 255 karakter). Servis (services/legal_service.js) ayni kullanici + belgenin SON kabulu ayni surumse
--      yeni satir yazmaz (idempotent) ve satir ile users.terms_* alanlarini AYNI transaction'da yazar.
--      document kumesi 'privacy'yi de kapsar (ileriye uyum): KVKK aydinlatma metni bilgilendirmedir, rizaya
--      baglanmaz; sunucu bugun 'privacy' kabulu YAZMAZ (requires_acceptance false -> 400).
--   Belgelerin kendisi veritabaninda DEGILDIR: server/legal/<slug>.md.
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001 (users).
-- Hesap silme (027) yumusak silmedir: kabul kayitlari kalir. Kullanici satiri kalici silinirse (ON DELETE CASCADE)
--   kayitlari da silinir.
-- Rolling deploy: yeni kolonlar NULL ve varsayilansizdir (tablo yeniden yazilmaz); eski kod gormezden gelir. Yeni kod
--   039'suz veritabaninda giris / kayit / profil yanitlarini BOZMAZ (users.terms_version to_jsonb ile okunur, yoksa
--   NULL) ama kabul (POST /legal/accept) ve accept_terms_version'li kayit 500 doner (kayit geri alinir).
--   Sira: once migration, sonra sunucu.
-- ==============================================================================

-- users ALTER'i canli trafikte (giris / kopru UPDATE'leri) uzun kilit beklemesin: 5 sn'de vazgec, yeniden denenir.
SET LOCAL lock_timeout = '5s';

ALTER TABLE users ADD COLUMN IF NOT EXISTS terms_version INTEGER;
ALTER TABLE users ADD COLUMN IF NOT EXISTS terms_accepted_at TIMESTAMPTZ;

COMMENT ON COLUMN users.terms_version IS 'Yasal metinler: en son kabul edilen Kullanici Sozlesmesi surumu; NULL = kabul yok';
COMMENT ON COLUMN users.terms_accepted_at IS 'Yasal metinler: terms_version kabul zamani (legal_acceptances.accepted_at ile ayni)';

CREATE TABLE IF NOT EXISTS legal_acceptances (
  id           BIGSERIAL PRIMARY KEY,
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  document     TEXT NOT NULL CHECK (document IN ('terms', 'privacy')),
  version      INTEGER NOT NULL CHECK (version > 0),
  accepted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  ip_address   TEXT NULL,
  user_agent   TEXT NULL
);
CREATE INDEX IF NOT EXISTS idx_legal_acceptances_user_doc
  ON legal_acceptances (user_id, document, accepted_at DESC);

COMMENT ON TABLE legal_acceptances IS 'Yasal metin kabul kayitlari (kullanici, belge, surum, zaman, IP, User-Agent <= 255); son kabul ayni surumse yeni satir yazilmaz';
