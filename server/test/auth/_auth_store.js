'use strict';

// Kimlik tablolari icin bellek ici sahte veri deposu (users, refresh_tokens, password_resets,
// phone_otp_codes, push_tokens). auth_service'in kullandigi SQL ifadelerini (sirali regex eslemesi ile)
// davranissal olarak taklit eder; boylece rotation / deneme sayaci / tek kullanim gibi
// ozellikler gercek akisla sinanir. `now` enjekte edilebilir (DB NOW()).

const crypto = require('crypto');

function pgUnique() {
  const e = new Error('duplicate key value violates unique constraint');
  e.code = '23505';
  return e;
}

function createAuthStore({ now = () => Date.now() } = {}) {
  const s = {
    now,
    users: new Map(),
    refresh: [],
    resets: [],
    otps: [],
    pushTokens: [], // { id, user_id, token, disabled_at }  (plan §5d-1: oturumlar iptal edilince belirtec kapanir)
    // { id, username, kind:'app'|'device', home_id, user_id }  (UYELIK-02: toplu oturum iptali uygulama kimliklerini siler)
    mqttCreds: [],
    homes: [], // { home_id, user_id, role, name, mqtt_username, valid_from, valid_until }
    seq: 1,
  };

  const NOW = () => new Date(s.now());

  s.addUser = (fields = {}) => {
    const u = {
      id: crypto.randomUUID(),
      email: `u${s.seq++}@test.invalid`,
      full_name: 'Test Kullanici',
      phone: null,
      role: 'user',
      is_active: true,
      account_status: 'active',
      token_version: 1,
      must_change_password: false,
      email_verified: false,
      google_id: null,
      apple_id: null,
      password_hash: null,
      created_by_user_id: null,
      ...fields,
    };
    s.users.set(u.id, u);
    return u;
  };

  s.addPushToken = (userId, fields = {}) => {
    const t = { id: crypto.randomUUID(), user_id: userId, token: `tok-${s.seq++}-${crypto.randomBytes(12).toString('hex')}`, disabled_at: null, ...fields };
    s.pushTokens.push(t);
    return t;
  };
  s.activePushTokens = (userId) => s.pushTokens.filter((t) => t.user_id === userId && !t.disabled_at);

  /** Uygulama (varsayilan) veya cihaz MQTT kimligi; `home_id` verilmezse rastgele ev. */
  s.addMqttCred = (userId, fields = {}) => {
    const homeId = fields.home_id || crypto.randomUUID();
    const kind = fields.kind || 'app';
    const c = {
      id: crypto.randomUUID(),
      username: kind === 'device' ? `d_h_${s.seq++}` : `a_h_${s.seq++}_${crypto.randomBytes(5).toString('hex')}`,
      kind,
      home_id: homeId,
      user_id: kind === 'device' ? null : userId,
      ...fields,
    };
    s.mqttCreds.push(c);
    return c;
  };
  s.appCredsOf = (userId) => s.mqttCreds.filter((c) => c.user_id === userId && c.kind === 'app');

  const byEmail = (email) => [...s.users.values()].filter((u) => String(u.email).toLowerCase() === email);
  const byPhone = (phone) => [...s.users.values()].filter((u) => u.phone === phone);

  function checkUnique(candidate, ignoreId = null) {
    for (const u of s.users.values()) {
      if (u.id === ignoreId) continue;
      if (candidate.email && String(u.email).toLowerCase() === String(candidate.email).toLowerCase()) throw pgUnique();
      if (candidate.phone && u.phone === candidate.phone) throw pgUnique();
      if (candidate.google_id && u.google_id === candidate.google_id) throw pgUnique();
      if (candidate.apple_id && u.apple_id === candidate.apple_id) throw pgUnique();
    }
  }

  const latestActive = (list, keyField, key, consumedField) =>
    list
      .filter((r) => r[keyField] === key && !r[consumedField] && r.expires_at.getTime() > s.now())
      .sort((a, b) => b.created_at - a.created_at || b.id - a.id)[0];

  const rules = [
    [/pg_advisory_xact_lock/, () => [{}]],
    [/SELECT COUNT\(\*\)::int AS sends/, (p, t) => {
      const list = t.includes('password_resets') ? s.resets : s.otps;
      const keyField = t.includes('password_resets') ? 'identifier' : 'phone';
      const rows = list.filter((r) => r[keyField] === p[0] && r.created_at.getTime() > s.now() - 3600 * 1000);
      if (rows.length === 0) return [{ sends: 0, first_at: null, last_at: null, max_attempts: 0, db_now: NOW() }];
      return [{
        sends: rows.length,
        first_at: new Date(Math.min(...rows.map((r) => r.created_at.getTime()))),
        last_at: new Date(Math.max(...rows.map((r) => r.created_at.getTime()))),
        max_attempts: Math.max(...rows.map((r) => r.attempts)),
        db_now: NOW(),
      }];
    }],

    // ---------------- refresh_tokens ----------------
    [/UPDATE refresh_tokens\s+SET used_at = NOW\(\)/, (p) => {
      const r = s.refresh.find((x) => x.token_hash === p[0] && !x.used_at && !x.revoked_at && x.expires_at.getTime() > s.now());
      if (!r) return [];
      r.used_at = NOW();
      return [{ id: r.id, user_id: r.user_id, family_id: r.family_id }];
    }],
    [/SELECT id, user_id, family_id, used_at, revoked_at FROM refresh_tokens WHERE token_hash = \$1/, (p) =>
      s.refresh.filter((x) => x.token_hash === p[0])],
    [/revoked_reason = 'reuse_detected'/, (p) => {
      s.refresh.filter((x) => x.family_id === p[0] && !x.revoked_at).forEach((x) => { x.revoked_at = NOW(); x.revoked_reason = 'reuse_detected'; });
      return [];
    }],
    [/revoked_reason = 'inactive'/, (p) => {
      s.refresh.filter((x) => x.family_id === p[0] && !x.revoked_at).forEach((x) => { x.revoked_at = NOW(); x.revoked_reason = 'inactive'; });
      return [];
    }],
    [/INSERT INTO refresh_tokens/, (p) => {
      const row = { id: crypto.randomUUID(), user_id: p[0], token_hash: p[1], family_id: p[2], expires_at: new Date(p[3]), created_ip: p[4], used_at: null, revoked_at: null, revoked_reason: null, replaced_by: null };
      s.refresh.push(row);
      return [{ id: row.id }];
    }],
    [/UPDATE refresh_tokens SET replaced_by = \$1 WHERE id = \$2/, (p) => {
      const r = s.refresh.find((x) => x.id === p[1]);
      if (r) r.replaced_by = p[0];
      return [];
    }],
    [/revoked_reason = 'logout'/, (p) => {
      const fam = s.refresh.filter((x) => x.token_hash === p[0]).map((x) => x.family_id);
      s.refresh.filter((x) => fam.includes(x.family_id) && !x.revoked_at).forEach((x) => { x.revoked_at = NOW(); x.revoked_reason = 'logout'; });
      return [];
    }],
    [/UPDATE refresh_tokens SET revoked_at = NOW\(\), revoked_reason = \$2\s+WHERE user_id = \$1/, (p) => {
      s.refresh.filter((x) => x.user_id === p[0] && !x.revoked_at).forEach((x) => { x.revoked_at = NOW(); x.revoked_reason = p[1]; });
      return [];
    }],
    [/revoked_reason = 'social_link'/, (p) => {
      s.refresh.filter((x) => x.user_id === p[0] && !x.revoked_at).forEach((x) => { x.revoked_at = NOW(); x.revoked_reason = 'social_link'; });
      return [];
    }],

    // ---------------- mqtt_credentials (mqtt_credential_service.revokeAllUserAccess) ----------------
    [/DELETE FROM mqtt_credentials WHERE user_id = \$1 AND kind = 'app' RETURNING username/, (p) => {
      const hit = s.mqttCreds.filter((c) => c.user_id === p[0] && c.kind === 'app');
      s.mqttCreds = s.mqttCreds.filter((c) => !hit.includes(c));
      return hit.map((c) => ({ username: c.username }));
    }],

    // ---------------- push_tokens (push_service.disableAllTokensForUser) ----------------
    [/UPDATE push_tokens SET disabled_at = now\(\) WHERE user_id = \$1 AND disabled_at IS NULL/, (p) => {
      const hit = s.pushTokens.filter((t) => t.user_id === p[0] && !t.disabled_at);
      hit.forEach((t) => { t.disabled_at = NOW(); });
      return { rows: [], rowCount: hit.length };
    }],

    // ---------------- users ----------------
    [/UPDATE users SET token_version = token_version \+ 1 WHERE id = \$1/, (p) => {
      const u = s.users.get(p[0]);
      if (u) u.token_version += 1;
      return [];
    }],
    [/UPDATE users\s+SET password_hash = \$1,\s+must_change_password = \$2/, (p) => {
      const u = s.users.get(p[4]);
      if (!u) return [];
      u.password_hash = p[0];
      u.must_change_password = Boolean(p[1]);
      u.password_changed_at = NOW();
      u.token_version += 1;
      if (p[2]) u.email_verified = true;
      if (p[3] && u.account_status === 'pending_invite') u.account_status = 'active';
      return [{ ...u }];
    }],
    [/UPDATE users SET email_verified = TRUE, last_login_at = NOW\(\) WHERE id = \$1/, (p) => {
      const u = s.users.get(p[0]);
      if (u) { u.email_verified = true; u.last_login_at = NOW(); }
      return [];
    }],
    [/UPDATE users SET last_login_at = NOW\(\) WHERE id = \$1/, (p) => {
      const u = s.users.get(p[0]);
      if (u) u.last_login_at = NOW();
      return [];
    }],
    [/UPDATE users\s+SET (google_id|apple_id) = \$1, email_verified = TRUE, password_hash = \$2/, (p, t) => {
      const col = t.match(/SET (google_id|apple_id) = \$1/)[1];
      const u = s.users.get(p[2]);
      if (!u) return [];
      checkUnique({ [col]: p[0] }, u.id);
      u[col] = p[0];
      u.email_verified = true;
      u.password_hash = p[1];
      u.token_version += 1;
      if (u.account_status === 'pending_invite') u.account_status = 'active';
      return [{ ...u }];
    }],
    [/UPDATE users SET (google_id|apple_id) = \$1,/, (p, t) => {
      const col = t.match(/UPDATE users SET (google_id|apple_id) = \$1/)[1];
      const u = s.users.get(p[1]);
      if (!u) return [];
      checkUnique({ [col]: p[0] }, u.id);
      u[col] = p[0];
      if (u.account_status === 'pending_invite') u.account_status = 'active';
      return [{ ...u }];
    }],
    [/INSERT INTO users \(full_name, email, password_hash, phone, role, is_active, account_status, password_changed_at\)/, (p) => {
      const cand = { full_name: p[0], email: p[1], password_hash: p[2], phone: p[3] };
      checkUnique(cand);
      return [{ ...s.addUser({ ...cand, role: 'user', account_status: 'active' }) }];
    }],
    [/INSERT INTO users \(full_name, phone, email, password_hash, role, is_active, account_status\)/, (p) => {
      const cand = { full_name: p[0], phone: p[1], email: p[2], password_hash: p[3] };
      checkUnique(cand);
      return [{ ...s.addUser({ ...cand }) }];
    }],
    [/INSERT INTO users \(full_name, email, password_hash, (google_id|apple_id), role, is_active, account_status, email_verified\)/, (p, t) => {
      const col = t.match(/password_hash, (google_id|apple_id), role/)[1];
      const cand = { full_name: p[0], email: p[1], password_hash: p[2], [col]: p[3], email_verified: Boolean(p[4]) };
      checkUnique(cand);
      return [{ ...s.addUser(cand) }];
    }],
    [/INSERT INTO users \(full_name, email, password_hash, phone, role, is_active, account_status,\s+must_change_password, created_by_user_id, admin_notes\)/, (p) => {
      const cand = {
        full_name: p[0], email: p[1], password_hash: p[2], phone: p[3], role: p[4], account_status: p[5],
        must_change_password: Boolean(p[6]), created_by_user_id: p[7], admin_notes: p[8],
      };
      checkUnique(cand);
      return [{ ...s.addUser(cand) }];
    }],
    [/FROM users WHERE (google_id|apple_id) = \$1/, (p, t) => {
      const col = t.match(/FROM users WHERE (google_id|apple_id) = \$1/)[1];
      return [...s.users.values()].filter((u) => u[col] === p[0]).map((u) => ({ ...u }));
    }],
    [/FROM users\s+WHERE LOWER\(email\) = \$1 AND is_active = TRUE AND account_status IN/, (p) =>
      byEmail(p[0]).filter((u) => u.is_active && ['active', 'pending_invite'].includes(u.account_status)).map((u) => ({ ...u }))],
    [/FROM users\s+WHERE phone = \$1 AND is_active = TRUE AND account_status IN/, (p) =>
      byPhone(p[0]).filter((u) => u.is_active && ['active', 'pending_invite'].includes(u.account_status)).map((u) => ({ ...u }))],
    [/FROM users WHERE LOWER\(email\) = \$1/, (p) => byEmail(p[0]).map((u) => ({ ...u }))],
    [/FROM users WHERE phone = \$1/, (p) => byPhone(p[0]).map((u) => ({ ...u }))],
    [/FROM users\s+WHERE id = \$1/, (p) => (s.users.has(p[0]) ? [{ ...s.users.get(p[0]) }] : [])],

    // ---------------- password_resets ----------------
    // UYELIK-K1: yeni kod TESLIM EDILDIKTEN sonra onceki talepler kapatilir (yeni satir haric). Genel kuraldan ONCE.
    [/UPDATE password_resets SET used_at = NOW\(\)\s+WHERE identifier = \$1 AND used_at IS NULL AND id <> \$2/, (p) => {
      s.resets.filter((r) => r.identifier === p[0] && !r.used_at && r.id !== p[1]).forEach((r) => { r.used_at = NOW(); });
      return [];
    }],
    [/UPDATE password_resets SET used_at = NOW\(\)\s+WHERE identifier = \$1 AND used_at IS NULL/, (p) => {
      s.resets.filter((r) => r.identifier === p[0] && !r.used_at).forEach((r) => { r.used_at = NOW(); });
      return [];
    }],
    [/INSERT INTO password_resets[\s\S]*'reset'\)/, (p) => {
      const row = { id: s.seq++, user_id: p[0], identifier: p[1], code_hash: p[2], token_hash: p[3], expires_at: new Date(s.now() + Number(p[4]) * 1000), attempts: Number(p[5]), purpose: 'reset', used_at: null, created_at: NOW() };
      s.resets.push(row);
      return [{ id: row.id }];
    }],
    [/INSERT INTO password_resets[\s\S]*0, \$6\)/, (p) => {
      const row = { id: s.seq++, user_id: p[0], identifier: p[1], code_hash: p[2], token_hash: p[3], expires_at: new Date(s.now() + Number(p[4]) * 1000), attempts: 0, purpose: p[5], used_at: null, created_at: NOW() };
      s.resets.push(row);
      return [{ id: row.id, expires_at: row.expires_at }];
    }],
    [/UPDATE password_resets\s+SET used_at = NOW\(\)\s+WHERE token_hash = \$1/, (p) => {
      const r = s.resets.find((x) => x.token_hash === p[0] && !x.used_at && x.expires_at.getTime() > s.now() && p[1].includes(x.purpose));
      if (!r) return [];
      r.used_at = NOW();
      return [{ id: r.id, user_id: r.user_id, identifier: r.identifier, purpose: r.purpose }];
    }],
    [/UPDATE password_resets\s+SET attempts = attempts \+ 1/, (p) => {
      const r = latestActive(s.resets, 'identifier', p[0], 'used_at');
      if (!r || r.attempts >= p[1] || !p[2].includes(r.purpose)) return [];
      r.attempts += 1;
      return [{ id: r.id, user_id: r.user_id, code_hash: r.code_hash, attempts: r.attempts, purpose: r.purpose }];
    }],
    [/SELECT attempts FROM password_resets/, (p) => {
      const r = latestActive(s.resets, 'identifier', p[0], 'used_at');
      return r ? [{ attempts: r.attempts }] : [];
    }],
    [/UPDATE password_resets SET used_at = NOW\(\)\s+WHERE id = \$1 AND used_at IS NULL/, (p) => {
      const r = s.resets.find((x) => x.id === p[0] && !x.used_at);
      if (!r) return [];
      r.used_at = NOW();
      return [{ id: r.id, user_id: r.user_id, identifier: r.identifier, purpose: r.purpose }];
    }],
    [/UPDATE password_resets SET used_at = NOW\(\) WHERE id = \$1/, (p) => {
      const r = s.resets.find((x) => x.id === p[0]);
      if (r) r.used_at = NOW();
      return [];
    }],
    [/UPDATE password_resets SET used_at = NOW\(\) WHERE user_id = \$1 AND used_at IS NULL/, (p) => {
      s.resets.filter((r) => r.user_id === p[0] && !r.used_at).forEach((r) => { r.used_at = NOW(); });
      return [];
    }],

    // ---------------- phone_otp_codes ----------------
    // UYELIK-K1: yeni SMS TESLIM EDILDIKTEN sonra onceki kodlar kapatilir (yeni satir haric). Genel kuraldan ONCE.
    [/UPDATE phone_otp_codes SET consumed_at = NOW\(\)\s+WHERE phone = \$1 AND consumed_at IS NULL AND id <> \$2/, (p) => {
      s.otps.filter((r) => r.phone === p[0] && !r.consumed_at && r.id !== p[1]).forEach((r) => { r.consumed_at = NOW(); });
      return [];
    }],
    [/UPDATE phone_otp_codes SET consumed_at = NOW\(\) WHERE phone = \$1/, (p) => {
      s.otps.filter((r) => r.phone === p[0] && !r.consumed_at).forEach((r) => { r.consumed_at = NOW(); });
      return [];
    }],
    [/INSERT INTO phone_otp_codes/, (p) => {
      const row = { id: s.seq++, phone: p[0], otp_hash: p[1], expires_at: new Date(s.now() + Number(p[2]) * 1000), attempts: Number(p[3]), consumed_at: null, created_at: NOW() };
      s.otps.push(row);
      return [{ id: row.id }];
    }],
    [/UPDATE phone_otp_codes SET consumed_at = NOW\(\) WHERE id = \$1 AND consumed_at IS NULL/, (p) => {
      const r = s.otps.find((x) => x.id === p[0] && !x.consumed_at);
      if (!r) return [];
      r.consumed_at = NOW();
      return [{ id: r.id }];
    }],
    [/UPDATE phone_otp_codes SET consumed_at = NOW\(\) WHERE id = \$1/, (p) => {
      const r = s.otps.find((x) => x.id === p[0]);
      if (r) r.consumed_at = NOW();
      return [];
    }],
    [/UPDATE phone_otp_codes\s+SET attempts = attempts \+ 1/, (p) => {
      const r = latestActive(s.otps, 'phone', p[0], 'consumed_at');
      if (!r || r.attempts >= p[1]) return [];
      r.attempts += 1;
      return [{ id: r.id, otp_hash: r.otp_hash, attempts: r.attempts }];
    }],
    [/SELECT attempts FROM phone_otp_codes/, (p) => {
      const r = latestActive(s.otps, 'phone', p[0], 'consumed_at');
      return r ? [{ attempts: r.attempts }] : [];
    }],

    // ---------------- evler ----------------
    [/FROM home_users hu\s+JOIN homes h/, (p) => s.homes
      .filter((h) => h.user_id === p[0])
      .filter((h) => !(h.role === 'service_user' && h.installer_expires_at && new Date(h.installer_expires_at).getTime() <= s.now()))
      .map((h) => ({
        id: h.home_id, name: h.name, address: null, mqtt_username: h.mqtt_username, timezone: 'Europe/Istanbul',
        role: h.role, valid_from: h.valid_from || null, valid_until: h.valid_until || null,
        installer_expires_at: h.installer_expires_at || null,
      }))],
  ];

  s.unmatched = [];
  s.handle = async (params, text) => {
    for (const [re, fn] of rules) {
      if (re.test(text)) {
        const out = await fn(params || [], text);
        return out;
      }
    }
    s.unmatched.push(text);
    return [];
  };

  s.install = (fakeDb) => {
    fakeDb.on(/[\s\S]*/, (params, text) => s.handle(params, text));
    return s;
  };

  return s;
}

module.exports = { createAuthStore };
