-- Migration 011: Zamanlı Otomasyon Kuralları
-- Her ev için kanal/relay bazlı zamanlı açma/kapama kuralları

BEGIN;

CREATE TABLE IF NOT EXISTS scheduled_rules (
  id            SERIAL PRIMARY KEY,
  home_id       INTEGER NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  device_id     INTEGER REFERENCES devices(id) ON DELETE CASCADE,
  channel       INTEGER NOT NULL,              -- 0-7 relay/shutter kanalı
  channel_type  VARCHAR(20) NOT NULL DEFAULT 'relay', -- 'relay' veya 'shutter'
  action        VARCHAR(20) NOT NULL,          -- 'on', 'off', 'open', 'close'
  hour          SMALLINT NOT NULL CHECK (hour >= 0 AND hour <= 23),
  minute        SMALLINT NOT NULL CHECK (minute >= 0 AND minute <= 59),
  days_of_week  JSONB NOT NULL DEFAULT '[0,1,2,3,4,5,6]', -- 0=Pazar..6=Cumartesi
  label         VARCHAR(100),                  -- Kullanıcı dostu isim (opsiyonel)
  enabled       BOOLEAN NOT NULL DEFAULT TRUE,
  created_by    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_scheduled_rules_home_id
  ON scheduled_rules(home_id);

CREATE INDEX IF NOT EXISTS idx_scheduled_rules_enabled
  ON scheduled_rules(enabled) WHERE enabled = TRUE;

-- Güncelleme zamanını otomatik tazele
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

COMMIT;

