-- ==============================================================================
-- Migration 033: Guvenlik modulu (su baskini + vana) - alarmlar, olay gunlugu, yapilandirma kopyasi (WP-S1)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 033_safety_alarms.sql
-- Tasarim: docs/superpowers/specs/2026-10-06-guvenlik-iklim-senaryo-mimarisi-design.md bolum 5.2.1 (revizyon 2).
--
-- Kapsam
--   1. alarms: bolge alarminin yasam dongusu (bir aid = bir satir). aid = firmware olay kimligi `<bn>-<n>`
--      (bn = acilis nonce'u; fabrika sifirlamasi / pano degisimi sonrasi da cakismaz). origin: event (ev/{t}/event),
--      state (olay kayboldu, state uzlastirmasi acti), tomb (sirasiz teslim: once alarm_cleared geldi; push YOK).
--      push_status 030 deseni (pending -> claimed -> sending -> sent | failed | skipped): "en cok bir push".
--      fault_push_status: valve_fault icin ikinci push (NULL = gerekmedi).
--   2. devices.caps / devices.safety_state: son CANLI state'teki yetenekler ve guvenlik ozeti (kopru yazar).
--      caps yoksa pano "guvenlik desteklemiyor" sayilir (yeni komutlar 409 FIRMWARE_UNSUPPORTED).
--   3. device_events: ham olay gunlugu + (device_id, eid) tekillestirme. Saklama 90 gun (bakim isi; received_at indeksi).
--   4. device_configs: panonun modul yapilandirma kopyasi (K5: asil kaynak panodaki NVS; bulut yalniz kopya).
--   5. endpoints.actuator_type (valve|siren|fan|generic; NULL = eylemci degil), dimmable, dimmer_source (K1/K4).
--      endpoints.type CHECK'ine DOKUNULMAZ: eylemci rolesi bugunku tipiyle (light/impulse) kalir.
--   6. mqtt_acl: MEVCUT cihaz kimliklerine `ev/{t}/event` yayin izni. mqtt_acl'de benzersiz kisit YOKTUR
--      (020): ON CONFLICT ise yaramaz, NOT EXISTS kullanilir. Konu kimligi mevcut `ev/{t}/state` yayin satirindan
--      turetilir (020 ve mqtt_credential_service ile ayni kaynak); kimlik turu kind = 'device' ile secilir.
--      Yeni uretilen cihaz kimlikleri bu satiri mqtt_credential_service.issueDeviceCredential ile alir.
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001 (homes, devices, endpoints, users; kimlikler UUID), 020 (mqtt_credentials,
--   mqtt_acl), 021 (device_audit_logs; olaylar `safety_<tur>` adiyla oraya da yazilir).
--
-- Rolling deploy: yeni tablolar bostur; yeni kolonlar NULL ya da sabit varsayilanlidir (dimmable FALSE: PG 11+
-- tabloyu yeniden yazmaz). Eski kod yeni kolonlari gormezden gelir (INSERT/UPDATE'ler kolon adlarini acikca sayar).
-- CHECK'ler NOT VALID + VALIDATE deseniyle eklenir (030): mevcut satirlarda yeni kolonlar NULL/FALSE oldugundan
-- dogrulama kisa surer. ACL satiri eklenmeden eski firmware zaten event yayini yapmaz; yeni firmware'in olaylari
-- 033 + yeni kopru gelene kadar panoda bekler ve state uzlastirmasi devreye girer (tasarim bolum 7.3 dagitim sirasi).
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. ALARMS
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS alarms (
  id                BIGSERIAL PRIMARY KEY,
  home_id           UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  device_id         UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  aid               VARCHAR(16) NOT NULL,                      -- firmware eid (<bn>-<n>)
  zone              SMALLINT NOT NULL CHECK (zone BETWEEN 1 AND 4),
  kind              VARCHAR(12) NOT NULL,                      -- water|gas|smoke|...
  status            VARCHAR(12) NOT NULL,                      -- latched|fault|silenced|cleared|lost
  origin            VARCHAR(8)  NOT NULL DEFAULT 'event',      -- event|state|tomb
  sources           JSONB NOT NULL DEFAULT '[]',
  raised_at         TIMESTAMPTZ NOT NULL,
  device_epoch      BIGINT,                                    -- time_ok ise panonun saati
  acked_by          UUID REFERENCES users(id) ON DELETE SET NULL,
  acked_at          TIMESTAMPTZ,
  ack_requested_at  TIMESTAMPTZ,                               -- cevrimdisi panoya onay istegi
  ack_requested_by  UUID REFERENCES users(id) ON DELETE SET NULL,
  cleared_at        TIMESTAMPTZ,
  cleared_by        VARCHAR(16),                               -- device_event|device_state|lost
  push_status       VARCHAR(12) NOT NULL DEFAULT 'pending',    -- pending|claimed|sending|sent|failed|skipped
  push_attempts     SMALLINT NOT NULL DEFAULT 0,
  fault_push_status VARCHAR(12),                               -- valve_fault icin ikinci push (NULL = gerekmedi)
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT alarms_status_check CHECK (status IN ('latched', 'fault', 'silenced', 'cleared', 'lost')),
  CONSTRAINT alarms_origin_check CHECK (origin IN ('event', 'state', 'tomb')),
  CONSTRAINT alarms_push_status_check CHECK (push_status IN ('pending', 'claimed', 'sending', 'sent', 'failed', 'skipped')),
  CONSTRAINT alarms_fault_push_status_check
    CHECK (fault_push_status IS NULL OR fault_push_status IN ('pending', 'claimed', 'sending', 'sent', 'failed', 'skipped')),
  CONSTRAINT alarms_device_aid_uniq UNIQUE (device_id, aid)
);

-- Acik alarmlar (liste + state uzlastirmasi): kucuk kismi indeks.
CREATE INDEX IF NOT EXISTS alarms_home_open_idx ON alarms (home_id) WHERE status NOT IN ('cleared', 'lost');
-- Ev gecmisi (GET /homes/:id/alarms?state=all&before=): yeniden eskiye.
CREATE INDEX IF NOT EXISTS alarms_home_raised_idx ON alarms (home_id, raised_at DESC, id DESC);

COMMENT ON TABLE alarms IS 'WP-S1: bolge alarmi yasam dongusu (bir aid = bir satir); origin event|state|tomb; push en cok bir kez (push_status 030 deseni)';

-- ------------------------------------------------------------------------------
-- 2. DEVICES: son canli state'ten yetenekler ve guvenlik ozeti [O1]
-- ------------------------------------------------------------------------------
ALTER TABLE devices ADD COLUMN IF NOT EXISTS caps JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS safety_state JSONB;

COMMENT ON COLUMN devices.caps IS 'WP-S1: son CANLI state.caps (["safety","actuator","event","cfg"]); NULL = eski firmware (guvenlik desteklemiyor)';
COMMENT ON COLUMN devices.safety_state IS 'WP-S1: son CANLI state guvenlik ozeti (mode, policy, zones, actuators, sensors, cfg rev, boot, bn, last_rej); kopru yazar';

-- ------------------------------------------------------------------------------
-- 3. DEVICE_EVENTS: ham olay gunlugu + eid tekillestirme (saklama 90 gun, bakim isi)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS device_events (
  device_id   UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  eid         VARCHAR(16) NOT NULL,
  type        VARCHAR(24) NOT NULL,
  body        JSONB NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (device_id, eid)
);

CREATE INDEX IF NOT EXISTS device_events_received_idx ON device_events (received_at);

-- ------------------------------------------------------------------------------
-- 4. DEVICE_CONFIGS: panonun modul yapilandirma kopyasi (K5)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS device_configs (
  device_id  UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  module     VARCHAR(16) NOT NULL,
  rev        BIGINT NOT NULL,
  crc        VARCHAR(8) NOT NULL,
  body       JSONB NOT NULL,
  pending    JSONB,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (device_id, module)
);

-- ------------------------------------------------------------------------------
-- 5. ENDPOINTS: eylemci ve dimmer (K1/K4). type CHECK'ine DOKUNULMAZ.
-- ------------------------------------------------------------------------------
ALTER TABLE endpoints ADD COLUMN IF NOT EXISTS actuator_type VARCHAR(10);
ALTER TABLE endpoints ADD COLUMN IF NOT EXISTS dimmable BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE endpoints ADD COLUMN IF NOT EXISTS dimmer_source VARCHAR(8);

ALTER TABLE endpoints DROP CONSTRAINT IF EXISTS endpoints_actuator_type_check;
ALTER TABLE endpoints ADD CONSTRAINT endpoints_actuator_type_check
  CHECK (actuator_type IS NULL OR actuator_type IN ('valve', 'siren', 'fan', 'generic')) NOT VALID;
ALTER TABLE endpoints VALIDATE CONSTRAINT endpoints_actuator_type_check;

ALTER TABLE endpoints DROP CONSTRAINT IF EXISTS endpoints_dimmer_source_check;
ALTER TABLE endpoints ADD CONSTRAINT endpoints_dimmer_source_check
  CHECK (dimmer_source IS NULL OR dimmer_source IN ('modbus', 'bridge')) NOT VALID;
ALTER TABLE endpoints VALIDATE CONSTRAINT endpoints_dimmer_source_check;

COMMENT ON COLUMN endpoints.actuator_type IS 'WP-S1/K1: panonun state.relays[].act degeri (yerlesim esitleme yazar); NULL = eylemci degil (lamba/priz/darbe). Dolu kanal lamba sayilmaz, duz relay komutu ve zamanli kural almaz';
COMMENT ON COLUMN endpoints.dimmable IS 'K4: kanal parlaklik ayari istiyor (dimmer donanimi gerekir)';
COMMENT ON COLUMN endpoints.dimmer_source IS 'K4: NULL | modbus | bridge';

-- ------------------------------------------------------------------------------
-- 6. MQTT_ACL: mevcut cihaz kimliklerine ev/{t}/event yayini [O9]
-- ------------------------------------------------------------------------------
INSERT INTO mqtt_acl (credential_id, username, permission, action, topic)
SELECT a.credential_id, a.username, 'allow', 'publish',
       left(a.topic, length(a.topic) - length('/state')) || '/event'
  FROM mqtt_acl a
  JOIN mqtt_credentials c ON c.id = a.credential_id
 WHERE c.kind = 'device'
   AND a.permission = 'allow'
   AND a.action = 'publish'
   AND a.topic LIKE 'ev/%/state'
   AND NOT EXISTS (SELECT 1 FROM mqtt_acl e
                    WHERE e.credential_id = a.credential_id
                      AND e.action = 'publish'
                      AND e.topic = left(a.topic, length(a.topic) - length('/state')) || '/event');
