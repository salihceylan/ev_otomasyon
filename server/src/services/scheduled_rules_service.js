'use strict';

// ==============================================================================
// AHBU Akilli Ev - Zamanli kural servisi                            [CONTRACTS §1.5]
// ==============================================================================
//
// Sozlesme (snake_case govde; camelCase da kabul edilir, yanitlar hep snake_case):
//   { channel, channel_type: "relay"|"shutter", action, hour, minute, days_of_week,
//     device_id?, label?, enabled }
//   - channel 1 TABANLI (role numarasi veya panjur cifti); 0 tabanli kayitlar migration 022 ile +1 kaydirildi.
//   - action: relay -> on|off ; shutter -> open|close   (beyaz liste)
//   - days_of_week: benzersiz tamsayilar 0..6 (0=Pazar), bos olamaz
//   - hour 0..23, minute 0..59 (EVIN saat diliminde yorumlanir; bkz. scheduler.js)
//   - ev basina en cok 50 kural; device_id verilirse eve ait olmali
//
// `home_id` ve `created_by` ASLA govdeden alinmaz (URL + dogrulanmis uyelik / token).
// Hata mesajlari ic ayrinti (SQL/constraint) icermez; 5xx'te genel mesaj doner (route katmani).
//
// Disa acik arayuz: listRules, createRule, updateRule, deleteRule,
//   homeCleanupHook(tx, homeId)  -> devir/acil sifirlama/pano degisiminde kurallari temizler
//   (A: transfer_service, B: emergency reset cagirabilir; ayni transaction icinde).

const { HttpError, isUuid } = require('../utils/helpers');
const { isCreatorAuthorized } = require('../utils/rule_creator');

const MAX_RULES_PER_HOME = 50;
const MAX_RELAY_CHANNEL = 40; // endpoints.channel_index CHECK 1..40
const MAX_SHUTTER_PAIR = 20; // 40 role / 2
const MAX_LABEL_LENGTH = 100;

const ACTIONS_BY_TYPE = Object.freeze({
  relay: Object.freeze(['on', 'off']),
  shutter: Object.freeze(['open', 'close']),
});
const CHANNEL_TYPES = Object.freeze(Object.keys(ACTIONS_BY_TYPE));
const ALL_DAYS = Object.freeze([0, 1, 2, 3, 4, 5, 6]);

/** Girdi dogrulama hatasi (HTTP 400 VALIDATION). `errors`: [{ field, message }] */
class ValidationError extends HttpError {
  constructor(errors) {
    const list = Array.isArray(errors) ? errors : [errors];
    super(400, list[0] ? list[0].message : 'Gecersiz girdi', 'VALIDATION');
    this.name = 'ValidationError';
    this.errors = list;
  }
}

// ------------------------------------------------------------------------------
// Saf dogrulama (test edilebilir)
// ------------------------------------------------------------------------------

/** Tamsayi veya yalnizca rakamlardan olusan kisa metin -> sayi; aksi NaN. */
function strictInt(v) {
  if (typeof v === 'number') return Number.isInteger(v) ? v : NaN;
  if (typeof v === 'string' && /^\d{1,4}$/.test(v)) return parseInt(v, 10);
  return NaN;
}

function pick(body, snake, camel) {
  if (body[snake] !== undefined) return body[snake];
  return body[camel];
}

// Kontrol karakterleri (C0/C1) etiketten cikarilir.
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/g;

/**
 * Govdeyi okuyup alan alan dogrular. Yalnizca GONDERILEN alanlari dondurur.
 * @returns {{values: object, errors: Array<{field:string,message:string}>}}
 */
function parseRuleFields(body) {
  const errors = [];
  const values = {};
  const err = (field, message) => errors.push({ field, message });

  const channel = pick(body, 'channel', 'channel');
  if (channel !== undefined) {
    const n = strictInt(channel);
    if (!Number.isInteger(n) || n < 1 || n > MAX_RELAY_CHANNEL) {
      err('channel', `Geçersiz kanal numarası (1 tabanlı tamsayı, 1..${MAX_RELAY_CHANNEL})`);
    } else {
      values.channel = n;
    }
  }

  const channelType = pick(body, 'channel_type', 'channelType');
  if (channelType !== undefined) {
    if (typeof channelType !== 'string' || !CHANNEL_TYPES.includes(channelType)) {
      err('channel_type', `Geçersiz kanal tipi (${CHANNEL_TYPES.join(' | ')})`);
    } else {
      values.channel_type = channelType;
    }
  }

  const action = pick(body, 'action', 'action');
  if (action !== undefined) {
    const all = [...ACTIONS_BY_TYPE.relay, ...ACTIONS_BY_TYPE.shutter];
    if (typeof action !== 'string' || !all.includes(action)) {
      err('action', `Geçersiz eylem (${all.join(' | ')})`);
    } else {
      values.action = action;
    }
  }

  const hour = pick(body, 'hour', 'hour');
  if (hour !== undefined) {
    const n = strictInt(hour);
    if (!Number.isInteger(n) || n < 0 || n > 23) err('hour', 'Geçersiz saat (0..23)');
    else values.hour = n;
  }

  const minute = pick(body, 'minute', 'minute');
  if (minute !== undefined) {
    const n = strictInt(minute);
    if (!Number.isInteger(n) || n < 0 || n > 59) err('minute', 'Geçersiz dakika (0..59)');
    else values.minute = n;
  }

  const days = pick(body, 'days_of_week', 'daysOfWeek');
  if (days !== undefined) {
    if (!Array.isArray(days) || days.length === 0 || days.length > 7) {
      err('days_of_week', 'Gün listesi 1..7 öğeli bir dizi olmalı (0=Pazar..6=Cumartesi)');
    } else if (!days.every((d) => typeof d === 'number' && Number.isInteger(d) && d >= 0 && d <= 6)) {
      err('days_of_week', 'Gün listesi yalnızca 0..6 aralığında tamsayılar içermeli');
    } else if (new Set(days).size !== days.length) {
      err('days_of_week', 'Gün listesi tekrar eden gün içermemeli (benzersiz)');
    } else {
      values.days_of_week = [...days].sort((a, b) => a - b);
    }
  }

  const deviceId = pick(body, 'device_id', 'deviceId');
  if (deviceId !== undefined) {
    if (deviceId === null || deviceId === '') {
      values.device_id = null;
    } else if (typeof deviceId !== 'string' || !isUuid(deviceId)) {
      err('device_id', 'Geçersiz cihaz kimliği (UUID)');
    } else {
      values.device_id = deviceId.toLowerCase();
    }
  }

  const label = pick(body, 'label', 'label');
  if (label !== undefined) {
    if (label === null) {
      values.label = null;
    } else if (typeof label !== 'string') {
      err('label', 'Etiket metin olmalı');
    } else {
      const clean = label.replace(CONTROL_CHARS, '').trim();
      if (clean.length > MAX_LABEL_LENGTH) err('label', `Etiket en fazla ${MAX_LABEL_LENGTH} karakter olabilir`);
      else values.label = clean.length === 0 ? null : clean;
    }
  }

  const enabled = pick(body, 'enabled', 'enabled');
  if (enabled !== undefined) {
    if (typeof enabled !== 'boolean') err('enabled', 'enabled yalnızca true/false olabilir');
    else values.enabled = enabled;
  }

  return { values, errors };
}

/** channel_type / action uyumu (role: on|off, panjur: open|close). */
function checkTypeAction(channelType, action) {
  const allowed = ACTIONS_BY_TYPE[channelType];
  if (!allowed || !allowed.includes(action)) {
    return {
      field: 'action',
      message: `"${channelType}" kanal tipi için geçersiz eylem (izin verilen: ${(allowed || []).join(' | ')})`,
    };
  }
  return null;
}

/**
 * Kanal numarasini evin gercek uc noktalarina gore dogrular.
 * Uc nokta yoksa genel ust sinirlara dusulur (cihaz henuz yapilandirilmamis olabilir).
 * @param {Array<{channel_index:number,type:string}>} endpoints
 */
function checkChannelAgainstEndpoints(channelType, channel, endpoints) {
  const rows = Array.isArray(endpoints) ? endpoints : [];
  if (rows.length === 0) {
    const max = channelType === 'shutter' ? MAX_SHUTTER_PAIR : MAX_RELAY_CHANNEL;
    if (channel > max) return { field: 'channel', message: `Geçersiz kanal numarası (1..${max})` };
    return null;
  }
  const typeByChannel = new Map(rows.map((e) => [Number(e.channel_index), e.type]));
  const maxChannel = Math.max(...typeByChannel.keys());

  if (channelType === 'relay') {
    const t = typeByChannel.get(channel);
    if (t === undefined) {
      return { field: 'channel', message: `Geçersiz kanal numarası: evde ${maxChannel} kanal var (1..${maxChannel})` };
    }
    if (t === 'shutter') {
      return { field: 'channel', message: `Kanal ${channel} bir panjura ayrılmış; röle kuralı yerine panjur kuralı oluşturun` };
    }
    // WP-S2 [O6]: eylemci (vana/siren/fan) kanalina zamanli role kurali yazilmaz (lamba gibi acilamaz)
    const ep = rows.find((e) => Number(e.channel_index) === channel);
    if (ep && ep.actuator_type !== undefined && ep.actuator_type !== null) {
      return { field: 'channel', message: `Kanal ${channel} bir güvenlik cihazına (vana/siren/fan) bağlı; zamanlı kural kurulamaz` };
    }
    return null;
  }

  const up = typeByChannel.get(channel * 2 - 1);
  const down = typeByChannel.get(channel * 2);
  if (up === undefined || down === undefined) {
    return { field: 'channel', message: `Panjur ${channel} bu evde bulunamadı (evde ${Math.floor(maxChannel / 2)} panjur var)` };
  }
  if (up !== 'shutter' || down !== 'shutter') {
    return { field: 'channel', message: `Kanal ${channel * 2 - 1}/${channel * 2} bir panjur çifti değil` };
  }
  return null;
}

function toIso(v) {
  if (v === null || v === undefined) return null;
  const d = v instanceof Date ? v : new Date(v);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function normalizeDaysOut(v) {
  let arr = v;
  if (typeof arr === 'string') {
    try {
      arr = JSON.parse(arr);
    } catch (_) {
      arr = [];
    }
  }
  return Array.isArray(arr) ? arr.filter((d) => Number.isInteger(d)) : [];
}

/** kullanim-5: satirdaki kural sahibi yetki sutunlari (CREATOR_COLUMNS) -> isCreatorAuthorized girdisi. */
function creatorOf(row) {
  if (!row.created_by) return null;
  return {
    is_active: row.creator_is_active,
    account_status: row.creator_account_status,
    global_role: row.creator_global_role,
    home_role: row.creator_home_role,
    installer_expires_at: row.creator_installer_expires_at,
  };
}

/** Veritabani satiri -> API nesnesi (snake_case). `created_by_name` yalnizca ad (e-posta DEGIL). */
function mapRule(row) {
  return {
    id: Number(row.id),
    home_id: row.home_id,
    device_id: row.device_id || null,
    channel: Number(row.channel),
    channel_type: row.channel_type,
    action: row.action,
    hour: Number(row.hour),
    minute: Number(row.minute),
    days_of_week: normalizeDaysOut(row.days_of_week),
    label: row.label === undefined ? null : row.label,
    enabled: row.enabled === true,
    created_by: row.created_by || null,
    created_by_name: row.created_by_name === undefined ? null : row.created_by_name,
    // kullanim-5: kural sahibi hala yetkili mi (zamanlayici yetkisiz sahibin kuralini CALISTIRMAZ; listede gorunur olsun)
    creator_active: isCreatorAuthorized(creatorOf(row)),
    last_run_at: toIso(row.last_run_at),
    created_at: toIso(row.created_at),
    updated_at: toIso(row.updated_at),
  };
}

// ------------------------------------------------------------------------------
// Servis
// ------------------------------------------------------------------------------
// kullanim-5: kural sahibinin yetki sutunlari (zamanlayicinin SQL.creator denetimiyle ayni kaynak); e-posta SECILMEZ.
const CREATOR_COLUMNS =
  "u.full_name AS created_by_name, u.is_active AS creator_is_active, to_jsonb(u) ->> 'account_status' AS creator_account_status, " +
  'u.role AS creator_global_role, chu.role AS creator_home_role, chu.installer_expires_at AS creator_installer_expires_at';
const SELECT_WITH_CREATOR =
  `SELECT sr.*, ${CREATOR_COLUMNS} FROM scheduled_rules sr LEFT JOIN users u ON u.id = sr.created_by ` +
  'LEFT JOIN home_users chu ON chu.user_id = sr.created_by AND chu.home_id = sr.home_id';
// Kural sahibi tek satirda (ustlenme karari; zamanlayici SQL.creator ile ayni)
const CREATOR_SQL =
  "SELECT u.is_active, to_jsonb(u) ->> 'account_status' AS account_status, u.role AS global_role, " +
  'hu.role AS home_role, hu.installer_expires_at ' +
  'FROM users u LEFT JOIN home_users hu ON hu.user_id = u.id AND hu.home_id = $1 WHERE u.id = $2';
const RULE_AUDIT_SQL =
  'INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details) ' +
  'VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)';
// Ustlenebilecek (duzenleyen) ev rolleri: kural yonetimi yetkisi olanlar (servis personeli uyeligi gecerliyse rota gecirir)
const ADOPTER_ROLES = new Set(['owner', 'resident', 'service_user', 'super_user']);

function createService(deps = {}) {
  const getDb = () => deps.db || require('../db');

  async function listRules(homeId) {
    const res = await getDb().query(
      `${SELECT_WITH_CREATOR} WHERE sr.home_id = $1 ORDER BY sr.hour ASC, sr.minute ASC, sr.id ASC`,
      [homeId]
    );
    return res.rows.map(mapRule);
  }

  async function loadEndpoints(tx, homeId, deviceId) {
    const res = await tx.query(
      'SELECT channel_index, type, actuator_type FROM endpoints WHERE home_id = $1 AND ($2::uuid IS NULL OR device_id = $2::uuid)',
      [homeId, deviceId || null]
    );
    return res.rows;
  }

  async function assertDeviceInHome(tx, homeId, deviceId) {
    const res = await tx.query('SELECT id FROM devices WHERE id = $1 AND home_id = $2', [deviceId, homeId]);
    if (res.rows.length === 0) {
      throw new ValidationError({ field: 'device_id', message: 'Cihaz bu eve ait değil' });
    }
  }

  /**
   * @param {string} homeId
   * @param {string} userId  istegi yapan
   * @param {object} input
   * @param {{role?:string, ip?:string}} [actor]  kullanim-5: istegi yapanin ev rolu (servis personeli tek sahipli evde
   *                                            kurali sahip adina olusturur; denetimde gercek olusturan personel)
   */
  async function createRule(homeId, userId, input, actor = {}) {
    if (!input || typeof input !== 'object' || Array.isArray(input)) {
      throw new ValidationError({ field: 'body', message: 'İstek gövdesi bir nesne olmalı' });
    }
    const { values, errors } = parseRuleFields(input);
    const missing = ['channel', 'action', 'hour', 'minute'].filter((f) => input[f] === undefined && input[toCamel(f)] === undefined);
    for (const f of missing) errors.push({ field: f, message: `${f} zorunludur` });
    if (errors.length > 0) throw new ValidationError(errors);

    const rule = {
      channel: values.channel,
      channel_type: values.channel_type || 'relay',
      action: values.action,
      hour: values.hour,
      minute: values.minute,
      days_of_week: values.days_of_week || [...ALL_DAYS],
      device_id: values.device_id || null,
      label: values.label === undefined ? null : values.label,
      enabled: values.enabled === undefined ? true : values.enabled,
    };
    const pairErr = checkTypeAction(rule.channel_type, rule.action);
    if (pairErr) throw new ValidationError(pairErr);

    return getDb().withTransaction(async (tx) => {
      // Ayni ev icin es zamanli olusturmalari sirala (50 kural siniri yaris kosulu).
      await tx.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`scheduled_rules:${homeId}`]);

      const home = await tx.query('SELECT id FROM homes WHERE id = $1', [homeId]);
      if (home.rows.length === 0) throw new HttpError(404, 'Ev bulunamadı', 'NOT_FOUND');

      const count = await tx.query('SELECT COUNT(*)::int AS n FROM scheduled_rules WHERE home_id = $1', [homeId]);
      if (count.rows[0].n >= MAX_RULES_PER_HOME) {
        throw new HttpError(409, `Bir evde en fazla ${MAX_RULES_PER_HOME} zamanlı kural olabilir`, 'CONFLICT');
      }

      if (rule.device_id) await assertDeviceInHome(tx, homeId, rule.device_id);
      const endpoints = await loadEndpoints(tx, homeId, rule.device_id);
      const chErr = checkChannelAgainstEndpoints(rule.channel_type, rule.channel, endpoints);
      if (chErr) throw new ValidationError(chErr);

      // kullanim-5: servis personelinin (sureli uyelik) tek sahipli evde kurdugu kural sahibin adina kaydedilir: uyelik
      // bitince kural sessizce durmaz. Cok sahipli / sahipsiz evde eskisi gibi personel.
      let createdBy = userId;
      let onBehalfOf = null;
      if (actor && actor.role === 'service_user') {
        const owners = await tx.query("SELECT user_id FROM home_users WHERE home_id = $1 AND role = 'owner'", [homeId]);
        if (owners.rows.length === 1 && owners.rows[0].user_id && owners.rows[0].user_id !== userId) {
          onBehalfOf = owners.rows[0].user_id;
          createdBy = onBehalfOf;
        }
      }

      const ins = await tx.query(
        `WITH ins AS (
           INSERT INTO scheduled_rules
             (home_id, device_id, channel, channel_type, action, hour, minute, days_of_week, label, enabled, created_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10, $11)
           RETURNING *
         )
         SELECT ins.*, ${CREATOR_COLUMNS} FROM ins LEFT JOIN users u ON u.id = ins.created_by
           LEFT JOIN home_users chu ON chu.user_id = ins.created_by AND chu.home_id = ins.home_id`,
        [
          homeId,
          rule.device_id,
          rule.channel,
          rule.channel_type,
          rule.action,
          rule.hour,
          rule.minute,
          JSON.stringify(rule.days_of_week),
          rule.label,
          rule.enabled,
          createdBy,
        ]
      );
      if (onBehalfOf) {
        await tx.query(RULE_AUDIT_SQL, [
          'scheduled_rule_created_for_owner',
          null,
          homeId,
          userId,
          'service_user',
          (actor && actor.ip) || null,
          JSON.stringify({ rule_id: Number(ins.rows[0].id), owner_id: onBehalfOf }),
        ]);
      }
      return mapRule(ins.rows[0]);
    });
  }

  /**
   * @param {{userId?:string|null, role?:string, ip?:string}|null} [editor]  kullanim-5: duzenleyen. Kayitli sahip artik
   *   yetkili degilse ve duzenleyen kural yonetebiliyorsa kural ona gecer (ustlenme; denetim 'scheduled_rule_adopted').
   *   Servis personeli duzenlerse ve evin tek (yetkili) owner'i varsa kural owner adina ustlenilir (createRule gibi).
   */
  async function updateRule(homeId, ruleId, input, editor = null) {
    if (!input || typeof input !== 'object' || Array.isArray(input)) {
      throw new ValidationError({ field: 'body', message: 'İstek gövdesi bir nesne olmalı' });
    }
    const { values, errors } = parseRuleFields(input);
    if (errors.length > 0) throw new ValidationError(errors);
    if (Object.keys(values).length === 0) {
      throw new ValidationError({ field: 'body', message: 'Güncellenecek alan yok' });
    }

    return getDb().withTransaction(async (tx) => {
      const cur = await tx.query('SELECT * FROM scheduled_rules WHERE id = $1 AND home_id = $2 FOR UPDATE', [ruleId, homeId]);
      if (cur.rows.length === 0) throw new HttpError(404, 'Kural bulunamadı', 'NOT_FOUND');
      const before = cur.rows[0];

      const merged = {
        channel: Number(before.channel),
        channel_type: before.channel_type,
        action: before.action,
        device_id: before.device_id || null,
        ...values,
      };

      // Hedefi etkileyen alanlar degistiyse (kanal/tip/eylem/cihaz) ya da kapali kural yeniden
      // aciliyorsa (WP-L D3: esitlemenin kapattigi kural kanal artik uyumsuzken acilamasin)
      // birlesik degerlerle yeniden dogrula. Kapatma ve kapaliyken etiket/saat degisimi
      // dogrulamasizdir: eski (bozuk) bir kural her zaman kapatilabilsin.
      const targetChanged = ['channel', 'channel_type', 'action', 'device_id'].some((k) => k in values);
      const reEnabling = values.enabled === true && before.enabled !== true;
      if (targetChanged || reEnabling) {
        const pairErr = checkTypeAction(merged.channel_type, merged.action);
        if (pairErr) throw new ValidationError(pairErr);
        if (values.device_id) await assertDeviceInHome(tx, homeId, values.device_id);
        else if (reEnabling && !('device_id' in values) && merged.device_id) await assertDeviceInHome(tx, homeId, merged.device_id);
        const endpoints = await loadEndpoints(tx, homeId, merged.device_id);
        const chErr = checkChannelAgainstEndpoints(merged.channel_type, merged.channel, endpoints);
        if (chErr) throw new ValidationError(chErr);
      }

      // Zamanlamayi etkileyen degisiklik: son calisma sifirlanir ve gecmis yuva telafi edilmez.
      const beforeDays = JSON.stringify([...normalizeDaysOut(before.days_of_week)].sort((a, b) => a - b));
      const scheduleChanged =
        ('hour' in values && values.hour !== Number(before.hour)) ||
        ('minute' in values && values.minute !== Number(before.minute)) ||
        ('days_of_week' in values && JSON.stringify(values.days_of_week) !== beforeDays) ||
        ('enabled' in values && values.enabled === true && before.enabled !== true);

      const sets = [];
      const params = [];
      const add = (column, value, cast = '') => {
        params.push(value);
        sets.push(`${column} = $${params.length}${cast}`);
      };
      for (const col of ['channel', 'channel_type', 'action', 'hour', 'minute', 'device_id', 'label', 'enabled']) {
        if (col in values) add(col, values[col]);
      }
      if ('days_of_week' in values) add('days_of_week', JSON.stringify(values.days_of_week), '::jsonb');
      if (scheduleChanged) sets.push('schedule_changed_at = CURRENT_TIMESTAMP', 'last_run_at = NULL');

      // kullanim-5: ustlenme - kayitli sahip artik yetkili degil (uyelik / servis suresi bitti, hesap kapandi) ve duzenleyen
      // kural yonetebiliyor: kural duzenleyene gecer (zamanlayici yeniden calistirir). Duzenleyen bilinmiyorsa yapilmaz.
      // Duzenleyen SERVIS PERSONELIYSE (sureli uyelik) ve evin TEK owner'i yetkiliyse kural owner ADINA ustlenilir
      // (createRule ile ayni kural; inceleme): personelin penceresi bitince kural yine sessizce durmasin. Denetimde gercek
      // duzenleyen personel (actor) + owner_id / editor_id. Cok owner'li / owner'siz evde personel ustlenir.
      let adopted = null; // { newCreator, onBehalfOf }
      const editorId = editor && editor.userId ? String(editor.userId) : null;
      if (editorId && ADOPTER_ROLES.has(editor.role) && String(before.created_by || '') !== editorId) {
        const who = before.created_by ? await tx.query(CREATOR_SQL, [homeId, before.created_by]) : { rows: [] };
        if (!isCreatorAuthorized((who && who.rows && who.rows[0]) || null)) {
          let onBehalfOf = null;
          if (editor.role === 'service_user') {
            const owners = await tx.query("SELECT user_id FROM home_users WHERE home_id = $1 AND role = 'owner'", [homeId]);
            const soleOwner = owners.rows.length === 1 && owners.rows[0].user_id ? String(owners.rows[0].user_id) : null;
            if (soleOwner && soleOwner !== editorId && soleOwner !== String(before.created_by || '')) {
              const ow = await tx.query(CREATOR_SQL, [homeId, soleOwner]);
              if (isCreatorAuthorized((ow && ow.rows && ow.rows[0]) || null)) onBehalfOf = soleOwner;
            }
          }
          const newCreator = onBehalfOf || editorId;
          add('created_by', newCreator);
          adopted = { newCreator, onBehalfOf };
        }
      }

      params.push(ruleId, homeId);
      const upd = await tx.query(
        `WITH upd AS (
           UPDATE scheduled_rules SET ${sets.join(', ')}
           WHERE id = $${params.length - 1} AND home_id = $${params.length}
           RETURNING *
         )
         SELECT upd.*, ${CREATOR_COLUMNS} FROM upd LEFT JOIN users u ON u.id = upd.created_by
           LEFT JOIN home_users chu ON chu.user_id = upd.created_by AND chu.home_id = upd.home_id`,
        params
      );
      if (upd.rows.length === 0) throw new HttpError(404, 'Kural bulunamadı', 'NOT_FOUND');
      if (adopted) {
        const details = adopted.onBehalfOf
          ? { rule_id: Number(ruleId), owner_id: adopted.onBehalfOf, editor_id: editorId }
          : { rule_id: Number(ruleId) };
        await tx.query(RULE_AUDIT_SQL, [
          'scheduled_rule_adopted',
          null,
          homeId,
          editorId,
          String(editor.role).slice(0, 30),
          (editor && editor.ip) || null,
          JSON.stringify(details),
        ]);
      }
      return mapRule(upd.rows[0]);
    });
  }

  async function deleteRule(homeId, ruleId) {
    const res = await getDb().query('DELETE FROM scheduled_rules WHERE id = $1 AND home_id = $2 RETURNING id', [ruleId, homeId]);
    if (res.rows.length === 0) throw new HttpError(404, 'Kural bulunamadı', 'NOT_FOUND');
    return { id: Number(res.rows[0].id) };
  }

  /**
   * Bir evin tum zamanli kurallarini ve calisma gunlugunu siler. Daire devri, acil sifirlama
   * ve pano degisiminde ESKI sahibin kurallari yeni sahipte calismasin diye cagrilir.
   * Cagiranin transaction'i (`tx`) icinde calisir.
   * @returns {Promise<{rules:number, runs:number}>}
   */
  async function homeCleanupHook(tx, homeId) {
    const runner = tx && typeof tx.query === 'function' ? tx : getDb();
    const runs = await runner.query('DELETE FROM scheduled_rule_runs WHERE home_id = $1', [homeId]);
    const rules = await runner.query('DELETE FROM scheduled_rules WHERE home_id = $1', [homeId]);
    return { rules: rules.rowCount || 0, runs: runs.rowCount || 0 };
  }

  return { listRules, createRule, updateRule, deleteRule, homeCleanupHook };
}

function toCamel(snake) {
  return snake.replace(/_([a-z])/g, (_, c) => c.toUpperCase());
}

const defaultService = createService();

module.exports = {
  ...defaultService,
  deleteRulesForHome: defaultService.homeCleanupHook, // takma ad
  createService,
  ValidationError,
  MAX_RULES_PER_HOME,
  helpers: {
    strictInt,
    parseRuleFields,
    checkTypeAction,
    checkChannelAgainstEndpoints,
    mapRule,
    ACTIONS_BY_TYPE,
    MAX_RELAY_CHANNEL,
    MAX_SHUTTER_PAIR,
  },
};
