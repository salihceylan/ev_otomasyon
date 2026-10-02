-- ==============================================================================
-- Migration 020: MQTT kimlikleri ve ACL (WP-B, denetim 2026-10-01)  -- CONTRACTS §2.2
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -f 020_mqtt_credentials.sql
--
-- Amac: paylasilan (tum evler icin ayni) sabit MQTT parolasini kaldirmak.
--   * Cihaz kimligi : d_{t}              (t = homes.mqtt_username = 'h_' + 16 hex; cihaz basina rastgele parola)
--   * Uygulama kimligi: a_{t}_{rastgele}  (kullanici oturumu basina, SURELI, YALNIZCA abonelik)
-- Parolalar yalnizca bcrypt ozeti olarak tutulur. Duz metin parola veritabaninda YOKTUR.
--
-- EMQX (WP-C) ile sozlesme - onerilen sorgular (sutun adlari EMQX varsayilanlariyla ayni):
--   authn (password_based / postgresql, algoritma bcrypt):
--     SELECT password_hash, is_superuser FROM mqtt_credentials
--      WHERE username = ${username} AND (expires_at IS NULL OR expires_at > NOW()) LIMIT 1
--   authz (postgresql):
--     SELECT permission, action, topic FROM mqtt_acl WHERE username = ${username}
--   (authz no_match = deny olmalidir; uygulama kimliklerine hic 'publish' satiri YAZILMAZ.)
--   EMQX icin en az yetkili DB rolu: SELECT yalnizca mqtt_credentials, mqtt_acl (ve gecis doneminde mqtt_users).
--
-- 'backend' turu: yonetim betigi (scripts/create_backend_mqtt_user.js) isterse backend_service
-- superuser kaydini bu tabloya yazabilsin diye izinlidir (home_id bos olabilir).
-- ==============================================================================

CREATE TABLE IF NOT EXISTS mqtt_credentials (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username       VARCHAR(100) NOT NULL,
  password_hash  VARCHAR(100) NOT NULL,                       -- bcrypt ($2a$/$2b$), parola DEGIL
  is_superuser   BOOLEAN NOT NULL DEFAULT FALSE,
  kind           VARCHAR(10) NOT NULL CHECK (kind IN ('device', 'app', 'backend')),
  home_id        UUID REFERENCES homes(id) ON DELETE CASCADE,
  device_id      UUID REFERENCES devices(id) ON DELETE CASCADE,
  user_id        UUID REFERENCES users(id) ON DELETE CASCADE, -- servis (PIN) oturumunda bos
  client_id      VARCHAR(100),
  expires_at     TIMESTAMPTZ,                                 -- cihaz kimliginde bos; uygulama kimliginde dolu
  created_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT uq_mqtt_credentials_username UNIQUE (username),
  CONSTRAINT chk_mqtt_credentials_home CHECK (kind = 'backend' OR home_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_mqtt_credentials_home ON mqtt_credentials (home_id);
CREATE INDEX IF NOT EXISTS idx_mqtt_credentials_user_home ON mqtt_credentials (user_id, home_id) WHERE kind = 'app';
CREATE INDEX IF NOT EXISTS idx_mqtt_credentials_expires ON mqtt_credentials (expires_at) WHERE expires_at IS NOT NULL;
-- Bir evin (konu kimliginin) tek cihaz kimligi olur; yeni kimlik eskisini degistirir.
CREATE UNIQUE INDEX IF NOT EXISTS uq_mqtt_credentials_home_device ON mqtt_credentials (home_id) WHERE kind = 'device';

CREATE TABLE IF NOT EXISTS mqtt_acl (
  id             BIGSERIAL PRIMARY KEY,
  credential_id  UUID REFERENCES mqtt_credentials(id) ON DELETE CASCADE,
  username       VARCHAR(100) NOT NULL,
  permission     VARCHAR(5) NOT NULL CHECK (permission IN ('allow', 'deny')),
  action         VARCHAR(10) NOT NULL CHECK (action IN ('publish', 'subscribe', 'all')),
  topic          VARCHAR(255) NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_mqtt_acl_username ON mqtt_acl (username);
CREATE INDEX IF NOT EXISTS idx_mqtt_acl_credential ON mqtt_acl (credential_id);
