-- ==============================================================================
-- Migration 035: Site, daire, kurulum sablonu (surumlu) ve karta yazim kaydi (Faz 1 / IP-1.1)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 035_sites_templates.sql
-- Plan: docs/superpowers/plans/2026-10-08-site-sablon-kurulum.md (K-S2, K-S6, K-S7, K-S8).
-- Sozlesme: docs/CONTRACTS.md bolum 3e, docs/contracts/template/README.md (ahbu-template/1).
--
-- Kapsam
--   1. sites: toplu kurulum yapilan site (ad, adres, il/ilce, sorumlu, blok/daire sayisi, not). Silme YUMUSAK
--      (deleted_at); dairesine kart bagli site silinemez (servis katmani, 409 SITE_HAS_DEVICES).
--   2. install_templates: kurulum sablonu (site_id NULL = genel/standart). current_version = son surum no.
--      Silme YUMUSAK; surumler ve yazim kayitlari KALIR.
--   3. install_template_versions: DEGISMEZ surum satirlari (govde JSONB + govde SHA-256). UPDATE / DELETE
--      tetikleyiciyle REDDEDILIR (trg_install_template_versions_immutable; SQLSTATE 55000).
--   4. site_flats: daire (blok + no), daire tipi, atanan sablon, bagli kart (device_uuid; envanter kaydi, en cok
--      bir daireye), durum planned | written | installed | handed_over.
--   5. template_writes: karta yazim kaydi (kart, sablon, surum, daire, yol usb | eth | lan, yazan, zaman, sonuc,
--      hata kodu). Claim tohumu (K-S8) kartin son BASARILI yazimini okur.
--   6. devices.template_id / template_version / template_reported_at: panonun MQTT state'te bildirdigi
--      `tpl {id, ver}` (kopru yazar; FK YOK: pano sunucuda olmayan bir sablon bildirebilir).
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001 (users, devices; kimlikler UUID, pgcrypto), 003 (device_inventory.device_uuid
--   UNIQUE), 021 (device_audit_logs; yerel anahtar okumasi oraya yazilir).
--
-- Rolling deploy: yeni tablolar bostur; devices'a eklenen kolonlar NULL'dur (tablo yeniden yazilmaz). Eski kod yeni
-- kolonlari gormezden gelir. Kullanici silinince (027) referanslar NULL'a doner (ON DELETE SET NULL).
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. SITES
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sites (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name           VARCHAR(100) NOT NULL,
  address        VARCHAR(300),
  city           VARCHAR(60),
  district       VARCHAR(60),
  contact_name   VARCHAR(100),
  contact_phone  VARCHAR(32),
  contact_email  VARCHAR(254),
  block_count    INT,
  flat_count     INT,
  notes          VARCHAR(2000),
  created_by     UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  deleted_at     TIMESTAMPTZ,
  CONSTRAINT sites_counts_check CHECK ((block_count IS NULL OR block_count BETWEEN 0 AND 1000)
                                       AND (flat_count IS NULL OR flat_count BETWEEN 0 AND 100000))
);
CREATE INDEX IF NOT EXISTS idx_sites_active_name ON sites (name) WHERE deleted_at IS NULL;

-- ------------------------------------------------------------------------------
-- 2. INSTALL_TEMPLATES
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS install_templates (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id          UUID REFERENCES sites(id) ON DELETE RESTRICT,
  name             VARCHAR(48) NOT NULL,
  flat_type        VARCHAR(16) NOT NULL,
  current_version  INT NOT NULL DEFAULT 0,
  created_by       UUID REFERENCES users(id) ON DELETE SET NULL,
  updated_by       UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  deleted_at       TIMESTAMPTZ,
  CONSTRAINT install_templates_version_check CHECK (current_version >= 0)
);
CREATE INDEX IF NOT EXISTS idx_install_templates_site ON install_templates (site_id) WHERE deleted_at IS NULL;

-- ------------------------------------------------------------------------------
-- 3. INSTALL_TEMPLATE_VERSIONS (degismez)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS install_template_versions (
  template_id  UUID NOT NULL REFERENCES install_templates(id) ON DELETE RESTRICT,
  version      INT NOT NULL,
  body         JSONB NOT NULL,
  sha256       CHAR(64) NOT NULL,
  created_by   UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (template_id, version),
  CONSTRAINT install_template_versions_version_check CHECK (version >= 1),
  CONSTRAINT install_template_versions_sha_check CHECK (sha256 ~ '^[0-9a-f]{64}$')
);

-- Surum satirlari DEGISMEZ (K-S6). Tek istisna: kullanici silinince created_by -> NULL (ON DELETE SET NULL, 027);
-- bu guncelleme yalniz created_by'i NULL'a cekiyorsa izin verilir, baska her UPDATE ve her DELETE reddedilir.
CREATE OR REPLACE FUNCTION install_template_versions_immutable() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.created_by IS NULL
     AND NEW.template_id = OLD.template_id
     AND NEW.version = OLD.version
     AND NEW.body = OLD.body
     AND NEW.sha256 = OLD.sha256
     AND NEW.created_at = OLD.created_at THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'install_template_versions satirlari degistirilemez (%)', TG_OP USING ERRCODE = '55000';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_install_template_versions_immutable ON install_template_versions;
CREATE TRIGGER trg_install_template_versions_immutable
  BEFORE UPDATE OR DELETE ON install_template_versions
  FOR EACH ROW EXECUTE FUNCTION install_template_versions_immutable();

-- ------------------------------------------------------------------------------
-- 4. SITE_FLATS
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS site_flats (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id      UUID NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  block        VARCHAR(16) NOT NULL,
  number       VARCHAR(16) NOT NULL,
  flat_type    VARCHAR(16),
  template_id  UUID REFERENCES install_templates(id) ON DELETE SET NULL,
  device_uuid  VARCHAR(64) REFERENCES device_inventory(device_uuid) ON DELETE SET NULL,
  status       VARCHAR(12) NOT NULL DEFAULT 'planned',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT site_flats_status_check CHECK (status IN ('planned', 'written', 'installed', 'handed_over')),
  CONSTRAINT site_flats_block_number_key UNIQUE (site_id, block, number)
);
-- Bir kart en cok bir daireye bagli olabilir.
CREATE UNIQUE INDEX IF NOT EXISTS uq_site_flats_device ON site_flats (device_uuid) WHERE device_uuid IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_site_flats_template ON site_flats (template_id) WHERE template_id IS NOT NULL;

-- ------------------------------------------------------------------------------
-- 5. TEMPLATE_WRITES
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS template_writes (
  id           BIGSERIAL PRIMARY KEY,
  device_uuid  VARCHAR(64) NOT NULL,
  template_id  UUID NOT NULL,
  version      INT NOT NULL,
  flat_id      UUID REFERENCES site_flats(id) ON DELETE SET NULL,
  via          VARCHAR(4) NOT NULL,
  result       VARCHAR(8) NOT NULL,
  error_code   VARCHAR(48),
  written_by   UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT template_writes_version_fk FOREIGN KEY (template_id, version)
    REFERENCES install_template_versions (template_id, version) ON DELETE RESTRICT,
  CONSTRAINT template_writes_via_check CHECK (via IN ('usb', 'eth', 'lan')),
  CONSTRAINT template_writes_result_check CHECK (result IN ('ok', 'error'))
);
CREATE INDEX IF NOT EXISTS idx_template_writes_device ON template_writes (device_uuid, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_template_writes_flat ON template_writes (flat_id, created_at DESC, id DESC) WHERE flat_id IS NOT NULL;

-- ------------------------------------------------------------------------------
-- 6. DEVICES: panonun bildirdigi yuklu sablon (state `tpl`)
-- ------------------------------------------------------------------------------
ALTER TABLE devices ADD COLUMN IF NOT EXISTS template_id UUID;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS template_version INT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS template_reported_at TIMESTAMPTZ;

ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_template_version_check;
ALTER TABLE devices ADD CONSTRAINT devices_template_version_check
  CHECK (template_version IS NULL OR template_version >= 1) NOT VALID;
ALTER TABLE devices VALIDATE CONSTRAINT devices_template_version_check;

COMMENT ON TABLE install_template_versions IS 'K-S6: degismez sablon surumleri (UPDATE/DELETE tetikleyiciyle reddedilir)';
COMMENT ON COLUMN template_writes.via IS 'usb (seri TPL) | eth (Ethernet, servis yazilimi) | lan (uygulama sihirbazi, Wi-Fi LAN)';
COMMENT ON COLUMN devices.template_id IS 'Panonun MQTT state tpl.id degeri (kopru yazar; FK yok)';
COMMENT ON COLUMN devices.template_version IS 'Panonun MQTT state tpl.ver degeri';
