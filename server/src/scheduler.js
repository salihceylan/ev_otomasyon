'use strict';

// ==============================================================================
// AHBU Akilli Ev - Zamanli kural motoru (scheduler)            [CONTRACTS §1.5, §2.3]
// ==============================================================================
//
// Kullanim (server.js):
//   const scheduler = require('./scheduler');
//   scheduler.start({ mqttBridge, db });   // dakika sinirinda hizalanir
//   await scheduler.stop();                // zarif kapanis
//
// Tasarim
//   - Her kural EVIN saat diliminde (`homes.timezone`, IANA; Intl ile) degerlendirilir.
//     DST: bahar atlamasinda var olmayan yerel saat o gun calismaz; sonbahar tekrarinda
//     (ayni yerel saat iki kez) kural YALNIZCA BIR KEZ calisir (yerel gun denetimi).
//   - ATOMIK tekrar engeli: `last_run_at` = calisan YUVANIN (dakika) zamani. Talep
//     `UPDATE ... WHERE last_run_at IS NULL OR last_run_at < yuva RETURNING id` ile
//     alinir; birden cok sunucu/instance ve ust uste binen turlar guvenlidir.
//   - 2 dakikalik TELAFI penceresi: gecikmeli/atlanan turlar son 2 dakikanin yuvalarini
//     yakalar. Kural olusturulmadan/duzenlenmeden ONCE baslayan yuvalar telafi edilmez
//     (`schedule_changed_at`): yeni kural gecmis bir dakika icin aninda tetiklenmez.
//   - Gecici hatalar (cihaz cevrimdisi, broker yok) talebi GERI BIRAKIR; ayni pencerede
//     sonraki dakikada yeniden denenir. Kalici durumlar (yetki, cihaz, gecersiz kural)
//     yuvayi tuketir. Komutlar mutlak (on/off/up/down) oldugu icin tekrar zararsizdir ve
//     cihaz ayni `id`'yi (`sr<kural>-<yuva>`) tekilleştirir.
//   - Calistirma aninda: kuralin sahibi (created_by) hala yetkili mi (owner/resident/
//     staff/super), kural cihazi hala o evde mi, cihaz cevrimici mi -> degilse atlanir ve
//     `scheduled_rule_runs` tablosuna yazilir.
//   - Ayrica kanalin GUNCEL uc nokta tipi denetlenir (WP-L D4): role kurali panjur kanalinda,
//     panjur kurali panjur olmayan ciftte calismaz ('skipped_invalid', yuva tuketilir).
//   - Evde acik GAZ alarmi varsa (alarms kind='gas', status latched|fault|silenced) role/panjur kurali
//     yayinlanmaz ('skipped_hazard', detail 'gas_alarm', yuva tuketilir; Faz 2 F2.A.4). Denetim cihaz
//     sorgusunun icindedir (ek sorgu yok).
//   - Kurallar `Promise.allSettled` ile sinirli es zamanlilikta ve kural basina zaman
//     asimiyla calistirilir; bir kural digerini bloklamaz.
//
// Komut ceviri (CONTRACTS §2.3; kanal 1 tabanli):
//   relay   on/off    -> { relay: N, state: true|false, id }
//   shutter open      -> { shutter: N, cmd: "up",   id }     (N = panjur cifti)
//   shutter close     -> { shutter: N, cmd: "down", id }

const DEFAULT_TZ = 'Europe/Istanbul';
const WINDOW_MINUTES = 2; // telafi penceresi (gecen dakikalar)
const TICK_OFFSET_MS = 1000; // dakika basindan sonra 1 sn (saat sapmasi payi)
const MAX_CANDIDATES = 5000;
const RULE_TIMEOUT_MS = 10 * 1000;
const CONCURRENCY = 10;
const HOUSEKEEPING_EVERY_MS = 24 * 60 * 60 * 1000;
const RUN_LOG_RETENTION_DAYS = 30;
// Guvenlik olay gunlugu (device_events; migration 033) saklama suresi. Tekillestirme eid'si acilis nonce'u tasidigindan
// eski satirin silinmesi yinelenen olayi yeniden islemez (yeni acilis = yeni bn). Alarm kayitlari (alarms) SILINMEZ.
const DEVICE_EVENT_RETENTION_DAYS = 90;
const WARN_INTERVAL_MS = 10 * 60 * 1000;

const AUTHORIZED_HOME_ROLES = new Set(['owner', 'resident', 'service_user']);
// Hesap durumu sutunu (users.account_status) opsiyoneldir; bilinen engelli degerler:
const BLOCKED_ACCOUNT_STATUSES = new Set([
  'suspended',
  'frozen',
  'disabled',
  'deleted',
  'locked',
  'banned',
  'inactive',
  'blocked',
]);

// ------------------------------------------------------------------------------
// Saf zaman yardimcilari
// ------------------------------------------------------------------------------
const formatterCache = new Map();
const tzValidityCache = new Map();
const WEEKDAYS = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

function isValidTimeZone(tz) {
  if (typeof tz !== 'string' || tz.length === 0 || tz.length > 64) return false;
  if (tzValidityCache.has(tz)) return tzValidityCache.get(tz);
  let ok = true;
  try {
    // eslint-disable-next-line no-new
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
  } catch (_) {
    ok = false;
  }
  tzValidityCache.set(tz, ok);
  return ok;
}

/** Gecersiz/bos saat dilimi -> varsayilan (Europe/Istanbul). */
function resolveTimeZone(tz) {
  return isValidTimeZone(tz) ? tz : DEFAULT_TZ;
}

function getFormatter(tz) {
  let f = formatterCache.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: tz,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      weekday: 'short',
    });
    formatterCache.set(tz, f);
  }
  return f;
}

/**
 * Bir UTC anin (ms) verilen saat dilimindeki yerel bilesenleri.
 * @returns {{year:number,month:number,day:number,hour:number,minute:number,dow:number,dateKey:string}}
 *          dow: 0=Pazar..6=Cumartesi; dateKey: "YYYY-MM-DD" (yerel tarih)
 */
function localParts(ms, tz) {
  const parts = getFormatter(tz).formatToParts(new Date(ms));
  const o = {};
  for (const p of parts) {
    if (p.type !== 'literal') o[p.type] = p.value;
  }
  let hour = parseInt(o.hour, 10);
  if (hour === 24) hour = 0; // bazi ICU surumleri gece yarisini 24 verir
  return {
    year: parseInt(o.year, 10),
    month: parseInt(o.month, 10),
    day: parseInt(o.day, 10),
    hour,
    minute: parseInt(o.minute, 10),
    dow: WEEKDAYS[o.weekday],
    dateKey: `${o.year}-${o.month}-${o.day}`,
  };
}

function floorMinute(ms) {
  return Math.floor(ms / 60000) * 60000;
}

/** Su anki dakika ve onceki `windowMinutes` dakika icin yuvalar (en yeni basta). */
function windowSlots(nowMs, tz, windowMinutes = WINDOW_MINUTES) {
  const t0 = floorMinute(nowMs);
  const slots = [];
  for (let k = 0; k <= windowMinutes; k++) {
    const ms = t0 - k * 60000;
    slots.push({ ms, parts: localParts(ms, tz) });
  }
  return slots;
}

function toMs(v) {
  if (v === null || v === undefined) return null;
  if (v instanceof Date) {
    const t = v.getTime();
    return Number.isFinite(t) ? t : null;
  }
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  const t = Date.parse(String(v));
  return Number.isFinite(t) ? t : null;
}

function toInt(v) {
  if (typeof v === 'number' && Number.isInteger(v)) return v;
  if (typeof v === 'string' && /^-?\d{1,6}$/.test(v)) return parseInt(v, 10);
  return null;
}

function normalizeDays(raw) {
  let v = raw;
  if (typeof v === 'string') {
    try {
      v = JSON.parse(v);
    } catch (_) {
      return [];
    }
  }
  if (!Array.isArray(v)) return [];
  return v.filter((d) => Number.isInteger(d) && d >= 0 && d <= 6);
}

/**
 * Bir kural icin pencerede calismasi gereken yuvayi bulur (yoksa null).
 *
 * @param {object} rule  { hour, minute, days_of_week, last_run_at, schedule_changed_at }
 * @param {{tz:string, slots:Array}} info  windowSlots sonucu + saat dilimi
 */
function dueSlotForRule(rule, info) {
  const hour = toInt(rule.hour);
  const minute = toInt(rule.minute);
  if (hour === null || minute === null) return null;
  const days = normalizeDays(rule.days_of_week);
  if (days.length === 0) return null;

  const lastRun = toMs(rule.last_run_at);
  const changedAt = toMs(rule.schedule_changed_at);
  const lastRunDate = lastRun === null ? null : localParts(lastRun, info.tz).dateKey;

  for (const s of info.slots) {
    if (s.parts.hour !== hour || s.parts.minute !== minute) continue;
    if (!days.includes(s.parts.dow)) continue;
    if (lastRun !== null && lastRun >= s.ms) continue; // bu yuva (veya daha yenisi) zaten calisti
    if (lastRunDate !== null && lastRunDate === s.parts.dateKey) continue; // ayni yerel gun (DST tekrari)
    if (changedAt !== null && s.ms < changedAt) continue; // kural bu yuvadan SONRA olusturuldu/duzenlendi
    return s;
  }
  return null;
}

/** Kurali firmware komutuna cevirir (CONTRACTS §2.3). Gecersizse null. */
function ruleToCommand(rule, slotMs) {
  const channel = toInt(rule.channel);
  if (channel === null || channel < 1 || channel > 64) return null;
  const id = `sr${rule.id}-${Math.floor(slotMs / 60000).toString(36)}`.slice(0, 24);
  const type = rule.channel_type || 'relay';
  if (type === 'relay') {
    if (rule.action === 'on') return { relay: channel, state: true, id };
    if (rule.action === 'off') return { relay: channel, state: false, id };
    return null;
  }
  if (type === 'shutter') {
    if (rule.action === 'open') return { shutter: channel, cmd: 'up', id };
    if (rule.action === 'close') return { shutter: channel, cmd: 'down', id };
    return null;
  }
  return null;
}

/** Kural sahibi calistirma aninda hala kural yonetmeye yetkili mi? */
function isCreatorAuthorized(row, nowMs = Date.now()) {
  if (!row) return false; // kullanici silinmis
  if (row.is_active === false) return false;
  const status = row.account_status ? String(row.account_status).toLowerCase() : null;
  if (status && BLOCKED_ACCOUNT_STATUSES.has(status)) return false;
  if (row.global_role === 'super_user') return true;
  if (!AUTHORIZED_HOME_ROLES.has(row.home_role)) return false;
  if (row.home_role === 'service_user' && row.installer_expires_at) {
    const exp = toMs(row.installer_expires_at);
    if (exp !== null && exp < nowMs) return false; // suresi dolmus gecici servis erisimi
  }
  return true;
}

class TimeoutError extends Error {
  constructor(label) {
    super(`${label} zaman asimina ugradi`);
    this.name = 'TimeoutError';
  }
}

function withTimeout(promise, ms, label, timers) {
  return new Promise((resolve, reject) => {
    const t = timers.setTimeout(() => reject(new TimeoutError(label)), ms);
    if (t && typeof t.unref === 'function') t.unref();
    Promise.resolve(promise).then(
      (v) => {
        timers.clearTimeout(t);
        resolve(v);
      },
      (e) => {
        timers.clearTimeout(t);
        reject(e);
      }
    );
  });
}

function safeMessage(err) {
  const m = err && err.message ? String(err.message) : 'bilinmeyen hata';
  return m.replace(/\s+/g, ' ').slice(0, 180);
}

// ------------------------------------------------------------------------------
// SQL
// ------------------------------------------------------------------------------
const SQL = Object.freeze({
  timezones:
    "SELECT DISTINCT COALESCE(h.timezone, '" +
    DEFAULT_TZ +
    "') AS tz FROM homes h " +
    'WHERE EXISTS (SELECT 1 FROM scheduled_rules sr WHERE sr.home_id = h.id AND sr.enabled = TRUE)',
  candidates:
    'SELECT sr.id, sr.home_id, sr.device_id, sr.channel, sr.channel_type, sr.action, sr.hour, sr.minute, ' +
    'sr.days_of_week, sr.created_by, sr.last_run_at, sr.schedule_changed_at, ' +
    "h.mqtt_username, COALESCE(h.timezone, '" +
    DEFAULT_TZ +
    "') AS timezone " +
    'FROM scheduled_rules sr JOIN homes h ON h.id = sr.home_id ' +
    'WHERE sr.enabled = TRUE ' +
    'AND (sr.hour, sr.minute) IN (SELECT t.h, t.m FROM unnest($1::int[], $2::int[]) AS t(h, m)) ' +
    `ORDER BY sr.id LIMIT ${MAX_CANDIDATES}`,
  claim:
    'UPDATE scheduled_rules SET last_run_at = $2::timestamptz ' +
    'WHERE id = $1 AND enabled = TRUE AND (last_run_at IS NULL OR last_run_at < $2::timestamptz) ' +
    'RETURNING id',
  release:
    'UPDATE scheduled_rules SET last_run_at = $3::timestamptz WHERE id = $1 AND last_run_at = $2::timestamptz',
  creator:
    "SELECT u.is_active, to_jsonb(u) ->> 'account_status' AS account_status, u.role AS global_role, " +
    'hu.role AS home_role, hu.installer_expires_at ' +
    'FROM users u LEFT JOIN home_users hu ON hu.user_id = u.id AND hu.home_id = $1 ' +
    'WHERE u.id = $2',
  // Faz 2 F2.A.4: evde acik gaz alarmi (gas_alarm) AYNI sorguda okunur (ek sorgu yok; alarms_home_open_idx).
  devices:
    'SELECT id, home_id, is_online, ' +
    "EXISTS (SELECT 1 FROM alarms a WHERE a.home_id = devices.home_id AND a.kind = 'gas' AND a.status IN ('latched', 'fault', 'silenced')) AS gas_alarm " +
    'FROM devices ' +
    'WHERE home_id = $1 AND ($2::uuid IS NULL OR id = $2::uuid)',
  // WP-L D4: atesleme aninda kuralin kanal(lar)inin guncel uc nokta tipi (cozulen cihaz).
  target: 'SELECT channel_index, type, actuator_type FROM endpoints WHERE device_id = $1::uuid AND channel_index = ANY($2::int[])',
  logRun:
    'INSERT INTO scheduled_rule_runs (rule_id, home_id, device_id, slot_at, status, detail, command_id) ' +
    'VALUES ($1, $2, $3, $4::timestamptz, $5, $6, $7) ' +
    'ON CONFLICT (rule_id, slot_at) DO UPDATE SET status = EXCLUDED.status, detail = EXCLUDED.detail, ' +
    'command_id = EXCLUDED.command_id, attempts = scheduled_rule_runs.attempts + 1, updated_at = CURRENT_TIMESTAMP',
  housekeeping: `DELETE FROM scheduled_rule_runs WHERE created_at < CURRENT_TIMESTAMP - INTERVAL '${RUN_LOG_RETENTION_DAYS} days'`,
  eventRetention: `DELETE FROM device_events WHERE received_at < CURRENT_TIMESTAMP - INTERVAL '${DEVICE_EVENT_RETENTION_DAYS} days'`,
});

// ------------------------------------------------------------------------------
// Motor
// ------------------------------------------------------------------------------
class Scheduler {
  /** @param {object} [opts] { now, timers, logger, windowMinutes, tickOffsetMs, ruleTimeoutMs, concurrency } */
  constructor(opts = {}) {
    this.now = opts.now || Date.now;
    this.timers = opts.timers || {
      setTimeout: (...a) => setTimeout(...a),
      clearTimeout: (...a) => clearTimeout(...a),
    };
    this.logger = opts.logger || console;
    this.windowMinutes = opts.windowMinutes !== undefined ? opts.windowMinutes : WINDOW_MINUTES;
    this.tickOffsetMs = opts.tickOffsetMs !== undefined ? opts.tickOffsetMs : TICK_OFFSET_MS;
    this.ruleTimeoutMs = opts.ruleTimeoutMs || RULE_TIMEOUT_MS;
    this.concurrency = opts.concurrency || CONCURRENCY;

    this.db = null;
    this.mqttBridge = null;
    this._started = false;
    this._timer = null;
    this._running = null;
    this._lastHousekeeping = 0;
    this._warned = new Map();
  }

  /**
   * @param {{mqttBridge:object, db:object}} deps
   *   mqttBridge: { publishCommand(topicId, obj), isConnected() }   db: { query(text, params) }
   */
  start({ mqttBridge, db } = {}) {
    if (!mqttBridge || typeof mqttBridge.publishCommand !== 'function') {
      throw new TypeError('scheduler.start: mqttBridge (publishCommand) zorunludur');
    }
    if (!db || typeof db.query !== 'function') {
      throw new TypeError('scheduler.start: db (query) zorunludur');
    }
    if (this._started) return this; // idempotent
    this.mqttBridge = mqttBridge;
    this.db = db;
    this._started = true;
    this._scheduleNext();
    this.logger.log(
      `[SCHEDULER] Zamanli kural motoru baslatildi (dakika hizali, telafi penceresi ${this.windowMinutes} dk)`
    );
    return this;
  }

  /** Zarif durdurma: yeni tur planlanmaz, calisan tur (en fazla 5 sn) beklenir. */
  async stop() {
    this._started = false;
    if (this._timer) {
      this.timers.clearTimeout(this._timer);
      this._timer = null;
    }
    const running = this._running;
    if (running) {
      let t;
      const limit = new Promise((resolve) => {
        t = this.timers.setTimeout(resolve, 5000);
        if (t && typeof t.unref === 'function') t.unref();
      });
      try {
        await Promise.race([running.catch(() => {}), limit]);
      } finally {
        this.timers.clearTimeout(t);
      }
    }
  }

  isRunning() {
    return this._started;
  }

  _scheduleNext() {
    if (!this._started) return;
    const now = this.now();
    const delay = 60000 - (now % 60000) + this.tickOffsetMs;
    this._timer = this.timers.setTimeout(() => this._onTimer(), delay);
    if (this._timer && typeof this._timer.unref === 'function') this._timer.unref();
  }

  async _onTimer() {
    this._timer = null;
    if (!this._started) return;
    const p = this.runTick(this.now()).catch((err) => {
      this._warnOnce('tick', `Tur hatasi: ${safeMessage(err)}`);
    });
    this._running = p;
    await p;
    this._running = null;
    this._scheduleNext();
  }

  _warnOnce(key, message) {
    const t = this.now();
    const last = this._warned.get(key);
    if (last !== undefined && t - last < WARN_INTERVAL_MS) return;
    this._warned.set(key, t);
    this.logger.warn(`[SCHEDULER] ${message}`);
  }

  /**
   * Tek bir dakika turu. Test ve elle tetikleme icin disa aciktir.
   * @param {number} [nowMs]
   */
  async runTick(nowMs = this.now()) {
    const summary = { due: 0, sent: 0, skipped: 0, failed: 0, lost: 0, outcomes: [] };
    try {
      await this._maybeHousekeeping(nowMs);

      const tzRes = await this.db.query(SQL.timezones, []);
      const rawZones = ((tzRes && tzRes.rows) || []).map((r) => r.tz).filter(Boolean);
      if (rawZones.length === 0) return summary;

      const infoByRaw = new Map();
      const hours = [];
      const minutes = [];
      const seen = new Set();
      for (const raw of rawZones) {
        const tz = resolveTimeZone(raw);
        if (tz !== raw) this._warnOnce(`tz:${raw}`, `Gecersiz saat dilimi "${String(raw).slice(0, 64)}", ${DEFAULT_TZ} kullaniliyor`);
        const slots = windowSlots(nowMs, tz, this.windowMinutes);
        infoByRaw.set(raw, { tz, slots });
        for (const s of slots) {
          const key = s.parts.hour * 60 + s.parts.minute;
          if (!seen.has(key)) {
            seen.add(key);
            hours.push(s.parts.hour);
            minutes.push(s.parts.minute);
          }
        }
      }

      const res = await this.db.query(SQL.candidates, [hours, minutes]);
      const rows = (res && res.rows) || [];
      const due = [];
      for (const rule of rows) {
        const info = infoByRaw.get(rule.timezone);
        if (!info) continue;
        const slot = dueSlotForRule(rule, info);
        if (slot) due.push({ rule, slot });
      }
      summary.due = due.length;
      if (due.length === 0) return summary;

      this.logger.log(`[SCHEDULER] ${due.length} zamanli kural tetikleniyor...`);
      for (let i = 0; i < due.length; i += this.concurrency) {
        const chunk = due.slice(i, i + this.concurrency);
        const settled = await Promise.allSettled(
          chunk.map(({ rule, slot }) =>
            withTimeout(this._executeRule(rule, slot, nowMs), this.ruleTimeoutMs, `Kural #${rule.id}`, this.timers)
          )
        );
        settled.forEach((r, idx) => {
          const rule = chunk[idx].rule;
          let outcome;
          if (r.status === 'fulfilled') {
            outcome = { ruleId: rule.id, ...r.value };
          } else {
            outcome = { ruleId: rule.id, status: 'failed', detail: safeMessage(r.reason) };
            this.logger.error(`[SCHEDULER] Kural #${rule.id} hatasi: ${safeMessage(r.reason)}`);
          }
          summary.outcomes.push(outcome);
          if (outcome.status === 'sent') summary.sent++;
          else if (outcome.status === 'lost_claim') summary.lost++;
          else if (outcome.status.startsWith('skipped')) summary.skipped++;
          else summary.failed++;
        });
      }
    } catch (err) {
      if (err && (err.code === '42703' || err.code === '42P01')) {
        this._warnOnce(
          'schema',
          'Zamanli kural tablolari/kolonlari eksik: 022_scheduled_rules_fix.sql uygulanmamis olabilir (scripts/migrate.js)'
        );
      } else {
        this._warnOnce('tick', `Zamanli kural turu hatasi: ${safeMessage(err)}`);
      }
      summary.error = safeMessage(err);
    }
    return summary;
  }

  async _maybeHousekeeping(nowMs) {
    if (nowMs - this._lastHousekeeping < HOUSEKEEPING_EVERY_MS) return;
    this._lastHousekeeping = nowMs;
    try {
      await this.db.query(SQL.housekeeping, []);
    } catch (err) {
      this._warnOnce('housekeeping', `Calisma gunlugu temizligi hatasi: ${safeMessage(err)}`);
    }
    try {
      // Guvenlik olay gunlugu 90 gun (device_events_received_idx); hata kural turunu etkilemez.
      await this.db.query(SQL.eventRetention, []);
    } catch (err) {
      this._warnOnce('event-retention', `Olay gunlugu temizligi hatasi: ${safeMessage(err)}`);
    }
  }

  async _executeRule(rule, slot, nowMs) {
    const slotIso = new Date(slot.ms).toISOString();
    const prevLastRun = toMs(rule.last_run_at);
    const prevIso = prevLastRun === null ? null : new Date(prevLastRun).toISOString();

    // 1) ATOMIK talep: yalnizca bir instance kazanir.
    const claim = await this.db.query(SQL.claim, [rule.id, slotIso]);
    if (!claim || claim.rowCount === 0) return { status: 'lost_claim' };

    // 2) Karar + yayin
    let outcome;
    try {
      outcome = await this._dispatch(rule, slot, nowMs);
    } catch (err) {
      outcome = { status: 'failed', detail: safeMessage(err) };
    }

    // 3) Gunluk (hata kuralin calismasini etkilemez)
    await this._logRun(rule, slot, outcome);

    // 4) Gecici nedenlerde talebi geri birak: ayni pencerede sonraki dakikada yeniden denenir.
    if (outcome.release) {
      try {
        await this.db.query(SQL.release, [rule.id, slotIso, prevIso]);
      } catch (err) {
        this._warnOnce('release', `Talep geri birakilamadi (kural #${rule.id}): ${safeMessage(err)}`);
      }
    }
    return { status: outcome.status, detail: outcome.detail, commandId: outcome.commandId, released: !!outcome.release };
  }

  async _dispatch(rule, slot, nowMs) {
    if (!rule.mqtt_username) {
      return { status: 'skipped_invalid', detail: 'ev konu kimligi yok' };
    }
    const command = ruleToCommand(rule, slot.ms);
    if (!command) {
      return { status: 'skipped_invalid', detail: 'kural komuta cevrilemedi (kanal/tip/eylem)' };
    }

    // Kural sahibi hala yetkili mi?
    const who = await this.db.query(SQL.creator, [rule.home_id, rule.created_by]);
    if (!isCreatorAuthorized((who && who.rows && who.rows[0]) || null, nowMs)) {
      return { status: 'skipped_creator', detail: 'kural sahibi artik yetkili degil' };
    }

    // Kural cihazi hala bu evde mi?
    const devRes = await this.db.query(SQL.devices, [rule.home_id, rule.device_id || null]);
    const devices = (devRes && devRes.rows) || [];
    let device = null;
    if (rule.device_id) {
      device = devices.find((d) => String(d.id) === String(rule.device_id)) || null;
      if (!device) return { status: 'skipped_device', detail: 'kural cihazi artik bu eve ait degil' };
    } else if (devices.length === 1) {
      device = devices[0];
    } else {
      return {
        status: 'skipped_device',
        detail: devices.length === 0 ? 'evde cihaz yok' : 'evde birden fazla cihaz var, kural cihaz belirtmiyor',
      };
    }

    // Hedef hala kuralla uyumlu mu? (pano yerlesimi degismis olabilir; kalici durum)
    const mismatch = await this._checkTarget(device, command);
    if (mismatch) return { status: 'skipped_invalid', detail: mismatch };

    // Faz 2 F2.A.4: gaz kacaginda OTOMATIK anahtarlama tutusma kaynagidir; kural yayinlanmaz, yuva tuketilir
    // (alarm pencere icinde kapansa bile gecikmis anahtarlama yapilmaz). Kullanicinin bilincli komutu engellenmez.
    if (device.gas_alarm === true || device.gas_alarm === 't') {
      return { status: 'skipped_hazard', detail: 'gas_alarm' };
    }

    if (!device.is_online) {
      return { status: 'skipped_offline', detail: 'cihaz cevrimdisi', release: true };
    }
    if (typeof this.mqttBridge.isConnected === 'function' && !this.mqttBridge.isConnected()) {
      return { status: 'failed_broker', detail: 'MQTT broker baglantisi yok', release: true, commandId: command.id };
    }

    try {
      await this.mqttBridge.publishCommand(rule.mqtt_username, command);
    } catch (err) {
      return { status: 'failed_broker', detail: safeMessage(err), release: true, commandId: command.id };
    }
    this.logger.log(
      `[SCHEDULER] Kural #${rule.id} gonderildi -> ev/${rule.mqtt_username}/cmd | ${rule.channel_type} ${rule.channel} ${rule.action}`
    );
    return { status: 'sent', commandId: command.id };
  }

  /**
   * WP-L D4 (savunma derinligi): esitleme kurali kapatmayi kacirsa bile role kurali panjur
   * motorunu surmesin. Tek sorgu. Uc nokta satiri yoksa (cihaz henuz yapilandirilmamis)
   * eski davranis surer. Panjur kuralinda cift eksik ya da panjur degilse yayin yapilmaz.
   * @returns {Promise<string|null>} uyumsuzluk aciklamasi ya da null
   */
  async _checkTarget(device, command) {
    const isShutter = command.shutter !== undefined;
    const n = isShutter ? command.shutter : command.relay;
    const channels = isShutter ? [n * 2 - 1, n * 2] : [n];
    const res = await this.db.query(SQL.target, [device.id, channels]);
    const rows = (res && res.rows) || [];
    if (rows.length === 0) return null;
    const typeOf = new Map(rows.map((r) => [Number(r.channel_index), r.type]));
    if (!isShutter) {
      // WP-S2 [O6]: eylemci (vana/siren/fan) kanalina zamanli role komutu GONDERILMEZ (esitleme kurali kapatmayi
      // kacirsa bile). Kolon gelmezse (eski satir/sorgu) eski davranis.
      const row = rows.find((r) => Number(r.channel_index) === n);
      if (row && row.actuator_type !== undefined && row.actuator_type !== null) {
        return 'kanal artik bir guvenlik eylemcisi; role kurali calistirilmadi';
      }
      return typeOf.get(n) === 'shutter' ? 'kanal artik panjur; role kurali calistirilmadi' : null;
    }
    const ok = channels.every((ch) => typeOf.get(ch) === 'shutter');
    return ok ? null : 'kanal cifti artik panjur degil';
  }

  async _logRun(rule, slot, outcome) {
    try {
      await this.db.query(SQL.logRun, [
        rule.id,
        rule.home_id,
        rule.device_id || null,
        new Date(slot.ms).toISOString(),
        outcome.status,
        outcome.detail ? String(outcome.detail).slice(0, 200) : null,
        outcome.commandId || null,
      ]);
    } catch (err) {
      this._warnOnce('logrun', `Calisma gunlugu yazilamadi: ${safeMessage(err)}`);
    }
  }
}

const scheduler = new Scheduler();

module.exports = {
  start: (deps) => scheduler.start(deps),
  stop: () => scheduler.stop(),
  isRunning: () => scheduler.isRunning(),
  runTick: (nowMs) => scheduler.runTick(nowMs),
  Scheduler,
  helpers: {
    DEFAULT_TZ,
    isValidTimeZone,
    resolveTimeZone,
    localParts,
    floorMinute,
    windowSlots,
    normalizeDays,
    dueSlotForRule,
    ruleToCommand,
    isCreatorAuthorized,
    withTimeout,
    TimeoutError,
  },
  SQL,
};
