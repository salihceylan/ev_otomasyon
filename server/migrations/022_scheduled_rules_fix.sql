-- ==============================================================================
-- Migration 022: Zamanli kurallar duzeltmesi (WP-C, denetim 2026-10-01)  -- CONTRACTS §1.5
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR; migration
-- calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -f 022_scheduled_rules_fix.sql
--
-- Kapsam
--   1. homes.timezone (IANA, varsayilan Europe/Istanbul): kurallar EVIN saat diliminde yorumlanir.
--   2. scheduled_rules: eski 011 / run_011.js'in biraktigi HER olasi durumdan (UUID kolonlu,
--      INTEGER kolonlu, tablo yok) ayni hedef semaya yaklasir:
--        - home_id / device_id / created_by UUID tipinde ve kanonik FK'lerle (INTEGER ise eski
--          satirlar gecersiz kimlik tasidigi icin SILINIR; donusturulemezler)
--        - last_run_at (atomik tekrar engeli), schedule_changed_at (telafi siniri)
--        - KANAL 1 TABANLI: eski (0 tabanli) satirlar +1 kaydirilir (YALNIZCA ilk uygulamada)
--        - kisitlar (NOT VALID: mevcut satirlar taranmaz, yeni/guncellenen satirlar denetlenir)
--        - (hour, minute) WHERE enabled indeksi (scheduler her dakika bunu kullanir)
--   3. scheduled_rule_runs: calistirma gunlugu (sent / skipped_* / failed_*), 30 gun saklanir.
--
-- Bagimlilik: 001 (homes, devices, users), 010b/011 (scheduled_rules, varsa).

-- ------------------------------------------------------------------------------
-- 1. HOMES.TIMEZONE
-- ------------------------------------------------------------------------------
ALTER TABLE homes ADD COLUMN IF NOT EXISTS timezone VARCHAR(64) NOT NULL DEFAULT 'Europe/Istanbul';
ALTER TABLE homes DROP CONSTRAINT IF EXISTS homes_timezone_format_check;
ALTER TABLE homes ADD CONSTRAINT homes_timezone_format_check CHECK (timezone ~ '^[A-Za-z0-9_+/-]{1,64}$');

-- ------------------------------------------------------------------------------
-- 2. SCHEDULED_RULES
-- ------------------------------------------------------------------------------
DO $$
DECLARE
  existed      BOOLEAN := (to_regclass('public.scheduled_rules') IS NOT NULL);
  had_last_run BOOLEAN := FALSE;
  col          RECORD;
  fk           RECORD;
BEGIN
  IF NOT existed THEN
    CREATE TABLE scheduled_rules (
      id                  SERIAL PRIMARY KEY,
      home_id             UUID NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
      device_id           UUID REFERENCES devices(id) ON DELETE CASCADE,
      channel             INTEGER NOT NULL,
      channel_type        VARCHAR(20) NOT NULL DEFAULT 'relay',
      action              VARCHAR(20) NOT NULL,
      hour                SMALLINT NOT NULL CHECK (hour >= 0 AND hour <= 23),
      minute              SMALLINT NOT NULL CHECK (minute >= 0 AND minute <= 59),
      days_of_week        JSONB NOT NULL DEFAULT '[0,1,2,3,4,5,6]',
      label               VARCHAR(100),
      enabled             BOOLEAN NOT NULL DEFAULT TRUE,
      created_by          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      last_run_at         TIMESTAMPTZ,
      schedule_changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  ELSE
    had_last_run := EXISTS (
      SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'scheduled_rules' AND column_name = 'last_run_at'
    );

    -- (a) INTEGER kimlik kolonlari -> UUID. Tamsayi kimlikler UUID'e donusturulemez ve zaten
    --     hicbir eve/kullaniciya baglanamaz; bu satirlar calisamazdi, bu yuzden silinirler.
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'scheduled_rules'
         AND column_name IN ('home_id', 'device_id', 'created_by') AND data_type <> 'uuid'
    ) THEN
      RAISE NOTICE '[022] scheduled_rules: INTEGER kimlik kolonlari UUID''e cevriliyor; eski (gecersiz kimlikli) satirlar siliniyor';
      DELETE FROM scheduled_rules;
      FOR fk IN
        SELECT conname FROM pg_constraint
         WHERE conrelid = 'public.scheduled_rules'::regclass AND contype = 'f'
      LOOP
        EXECUTE format('ALTER TABLE public.scheduled_rules DROP CONSTRAINT %I', fk.conname);
      END LOOP;
      FOR col IN
        SELECT column_name FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'scheduled_rules'
           AND column_name IN ('home_id', 'device_id', 'created_by') AND data_type <> 'uuid'
      LOOP
        EXECUTE format('ALTER TABLE public.scheduled_rules ALTER COLUMN %I TYPE UUID USING NULL', col.column_name);
      END LOOP;
    END IF;

    -- (b) yeni kolonlar
    ALTER TABLE scheduled_rules ADD COLUMN IF NOT EXISTS last_run_at TIMESTAMPTZ;
    -- Mevcut kurallar icin "degisiklik zamani" = migration zamani: gecmis yuvalar telafi edilmez.
    ALTER TABLE scheduled_rules ADD COLUMN IF NOT EXISTS schedule_changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

    -- (c) KANAL 1 TABANLI (sozlesme §0). Eski uygulama 0 tabanli yaziyordu. Yalnizca bu migration'in
    --     ILK uygulamasinda (last_run_at henuz yokken) bir kez kaydirilir; tekrar calistirmada kaymaz.
    IF NOT had_last_run THEN
      UPDATE scheduled_rules SET channel = channel + 1;
    END IF;

    -- (d) yetim satirlari temizle, kanonik FK'leri kur (eski adlar: fk_sr_home / fk_sr_device ...)
    DELETE FROM scheduled_rules
     WHERE home_id NOT IN (SELECT id FROM homes)
        OR created_by NOT IN (SELECT id FROM users)
        OR (device_id IS NOT NULL AND device_id NOT IN (SELECT id FROM devices));

    FOR fk IN
      SELECT conname FROM pg_constraint
       WHERE conrelid = 'public.scheduled_rules'::regclass AND contype = 'f'
    LOOP
      EXECUTE format('ALTER TABLE public.scheduled_rules DROP CONSTRAINT %I', fk.conname);
    END LOOP;
    ALTER TABLE scheduled_rules ADD CONSTRAINT scheduled_rules_home_id_fkey
      FOREIGN KEY (home_id) REFERENCES homes(id) ON DELETE CASCADE;
    ALTER TABLE scheduled_rules ADD CONSTRAINT scheduled_rules_device_id_fkey
      FOREIGN KEY (device_id) REFERENCES devices(id) ON DELETE CASCADE;
    ALTER TABLE scheduled_rules ADD CONSTRAINT scheduled_rules_created_by_fkey
      FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE CASCADE;
  END IF;
END $$;

-- Kisitlar: NOT VALID = mevcut satirlar taranmaz (eski bozuk kayit migration'i dusurmesin),
-- yeni ve guncellenen satirlar denetlenir.
ALTER TABLE scheduled_rules DROP CONSTRAINT IF EXISTS scheduled_rules_channel_range_check;
ALTER TABLE scheduled_rules ADD CONSTRAINT scheduled_rules_channel_range_check
  CHECK (channel BETWEEN 1 AND 64) NOT VALID;

ALTER TABLE scheduled_rules DROP CONSTRAINT IF EXISTS scheduled_rules_type_action_check;
ALTER TABLE scheduled_rules ADD CONSTRAINT scheduled_rules_type_action_check
  CHECK (
    (channel_type = 'relay' AND action IN ('on', 'off'))
    OR (channel_type = 'shutter' AND action IN ('open', 'close'))
  ) NOT VALID;

ALTER TABLE scheduled_rules DROP CONSTRAINT IF EXISTS scheduled_rules_days_check;
ALTER TABLE scheduled_rules ADD CONSTRAINT scheduled_rules_days_check
  CHECK (jsonb_typeof(days_of_week) = 'array') NOT VALID;

COMMENT ON COLUMN scheduled_rules.channel IS '1 tabanli: role numarasi (relay) veya panjur cifti (shutter; cift N = role 2N-1 ve 2N)';
COMMENT ON COLUMN scheduled_rules.last_run_at IS 'Son calisan YUVANIN (dakika) zamani; scheduler atomik talep icin kullanir';
COMMENT ON COLUMN scheduled_rules.schedule_changed_at IS 'Olusturma / zamanlama degisikligi zamani; bundan onceki yuvalar telafi edilmez';

-- Indeksler
CREATE INDEX IF NOT EXISTS idx_scheduled_rules_home_id ON scheduled_rules (home_id);
-- scheduler her dakika (hour, minute) kumesiyle yalnizca etkin kurallari sorgular
CREATE INDEX IF NOT EXISTS idx_scheduled_rules_due ON scheduled_rules (hour, minute) WHERE enabled = TRUE;
-- 011'in dusuk secicilikli indeksi gereksiz
DROP INDEX IF EXISTS idx_scheduled_rules_enabled;

-- updated_at tetikleyicisi (011 ile ayni; temiz kurulumda tablo bu dosyada olusmus olabilir)
CREATE OR REPLACE FUNCTION update_scheduled_rules_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_scheduled_rules_updated_at ON scheduled_rules;
CREATE TRIGGER trg_scheduled_rules_updated_at
  BEFORE UPDATE ON scheduled_rules
  FOR EACH ROW EXECUTE FUNCTION update_scheduled_rules_updated_at();

-- ------------------------------------------------------------------------------
-- 3. SCHEDULED_RULE_RUNS (calistirma gunlugu)
-- ------------------------------------------------------------------------------
-- rule_id tipi scheduled_rules.id ile ayni olmali (SERIAL beklenir; surukleme olursa uyumlu kalir).
DO $$
DECLARE
  id_type TEXT;
BEGIN
  SELECT format_type(a.atttypid, a.atttypmod) INTO id_type
    FROM pg_attribute a
   WHERE a.attrelid = 'public.scheduled_rules'::regclass
     AND a.attname = 'id'
     AND NOT a.attisdropped;
  IF id_type IS NULL THEN
    id_type := 'integer';
  END IF;
  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS scheduled_rule_runs (
       id         BIGSERIAL PRIMARY KEY,
       rule_id    %s REFERENCES scheduled_rules(id) ON DELETE SET NULL,
       home_id    UUID REFERENCES homes(id) ON DELETE CASCADE,
       device_id  UUID REFERENCES devices(id) ON DELETE SET NULL,
       slot_at    TIMESTAMPTZ NOT NULL,
       status     VARCHAR(24) NOT NULL,
       detail     VARCHAR(200),
       command_id VARCHAR(32),
       attempts   INTEGER NOT NULL DEFAULT 1,
       created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
       updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
     )',
    id_type
  );
END $$;

-- Ayni (kural, yuva) icin tek satir: yeniden denemeler ON CONFLICT ile guncellenir.
CREATE UNIQUE INDEX IF NOT EXISTS ux_scheduled_rule_runs_rule_slot ON scheduled_rule_runs (rule_id, slot_at);
CREATE INDEX IF NOT EXISTS idx_scheduled_rule_runs_home ON scheduled_rule_runs (home_id, slot_at DESC);
CREATE INDEX IF NOT EXISTS idx_scheduled_rule_runs_created ON scheduled_rule_runs (created_at);
