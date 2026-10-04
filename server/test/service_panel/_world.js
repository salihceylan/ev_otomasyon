'use strict';

// ==============================================================================
// WP-B2 test altyapisi: bellek ici "dunya" (tablolar) + servis/middleware SQL'lerini taklit eden isleyiciler.
//
// GERCEK PostgreSQL YOK: FakeDb (test/devices/_fake_db.js) transaction/ROLLBACK (geri alma gunlugu) ve satir kilidi
// (FOR UPDATE / advisory) davranisini saglar. Uretim SQL'i degisirse eslesen isleyici bulunamaz ve test gurultuyle
// kirilir (sessiz gecmez). SQL'in GERCEK anlami `pg_live.test.js` ile gercek PostgreSQL'de dogrulanir.
//
// `createEnv()`:
//   - ortam degiskenleri (rastgele sirlar), `src/db.js` modulunu SAHTE db ile degistirir (require.cache),
//   - mailer'i yakalayici tasiyiciya baglar (OTP e-postadan okunur),
//   - GERCEK `createApp` + gercek auth_middleware / servisler (yalnizca db ve broker sahte),
//   - `h` yardimcilari: kullanici/ev/uye/cihaz olusturma, JWT, e-posta yakalama.
// Her test dosyasi AYRI surecte calisir; require.cache degisikligi sizmaz.

const crypto = require('crypto');
const path = require('path');
const { FakeDb } = require('../devices/_fake_db');
const { injectModule } = require('../devices/_routes_env');

const uid = () => crypto.randomUUID();
const copy = (o) => (o ? { ...o } : o);
const copies = (arr) => arr.map((o) => ({ ...o }));
const ms = (d) => (d ? new Date(d).getTime() : null);

function createClock(startMs = Date.now()) {
  return {
    t: startMs,
    now() {
      return new Date(this.t);
    },
    advance(delta) {
      this.t += delta;
    },
  };
}

/** LIKE/ILIKE kalibi (\ ile kacirilmis % _ dahil) -> RegExp (buyuk/kucuk harf duyarsiz). */
function likeToRegExp(pattern) {
  let out = '';
  for (let i = 0; i < pattern.length; i++) {
    const ch = pattern[i];
    if (ch === '\\' && i + 1 < pattern.length) {
      out += pattern[++i].replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    } else if (ch === '%') out += '.*';
    else if (ch === '_') out += '.';
    else out += ch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${out}$`, 'i');
}

function createWorld({ clock = createClock() } = {}) {
  const s = {
    users: [],
    homes: [],
    home_users: [],
    devices: [],
    device_inventory: [],
    home_admin_assign_otps: [],
    home_admin_assignment_logs: [],
    device_audit_logs: [],
    service_tokens: [],
    service_sessions: [],
    home_invitations: [],
    home_transfers: [],
    scheduled_rules: [],
    mqtt_credentials: [],
    push_tokens: [],
    refresh_tokens: [],
    password_resets: [],
    phone_otp_codes: [],
    device_claim_otps: [],
  };
  const flags = { pushTokensTable: true };
  const db = new FakeDb();
  const now = () => clock.now();
  let seq = 0;

  const remove = (arr, item) => {
    const i = arr.indexOf(item);
    if (i >= 0) arr.splice(i, 1);
  };
  const insert = (ctx, arr, row) => {
    arr.push(row);
    ctx.undo(() => remove(arr, row));
    return row;
  };
  const patch = (ctx, row, changes) => {
    const before = {};
    for (const k of Object.keys(changes)) before[k] = row[k];
    ctx.undo(() => Object.assign(row, before));
    Object.assign(row, changes);
    return row;
  };
  const removeRows = (ctx, arr, pred) => {
    const removed = arr.filter(pred);
    for (const r of removed) remove(arr, r);
    ctx.undo(() => arr.push(...removed));
    return removed;
  };
  const dupError = (constraint) => Object.assign(new Error(`duplicate key value violates unique constraint "${constraint}"`), { code: '23505' });
  const userById = (id) => s.users.find((u) => u.id === id);
  const homeById = (id) => s.homes.find((h) => h.id === id);
  const membersOf = (homeId) => s.home_users.filter((m) => m.home_id === homeId);
  const staffMemberValid = (homeId, userId) =>
    s.home_users.some(
      (m) =>
        m.home_id === homeId && m.user_id === userId && m.role === 'service_user' &&
        (!m.installer_expires_at || ms(m.installer_expires_at) > now().getTime())
    );
  const ownerOf = (homeId) => {
    const owners = membersOf(homeId).filter((m) => m.role === 'owner').sort((a, b) => ms(a.created_at) - ms(b.created_at) || a.seq - b.seq);
    return owners.length ? userById(owners[0].user_id) : null;
  };

  // ================================================================== auth_middleware
  db.on('SELECT id, email, full_name, role, is_active, account_status, token_version FROM users WHERE id = $1', ({ params }) =>
    copies(s.users.filter((u) => u.id === params[0]))
  );
  db.on('FROM service_sessions WHERE id = $1', ({ params }) => copies(s.service_sessions.filter((x) => x.id === params[0])));
  db.on((sql) => sql === 'SELECT id FROM homes WHERE id = $1', ({ params }) => (homeById(params[0]) ? [{ id: params[0] }] : []));
  db.on('SELECT role, valid_from, valid_until, installer_expires_at FROM home_users WHERE home_id = $1 AND user_id = $2', ({ params }) =>
    copies(s.home_users.filter((m) => m.home_id === params[0] && m.user_id === params[1]))
  );

  // ================================================================== abone listesi
  const subscriberFilter = (sql, params) => {
    let i = 0;
    const staffId = sql.includes("sm.role = 'service_user'") ? params[i++] : null;
    const term = sql.includes('ILIKE') ? params[i++] : null;
    const re = term ? likeToRegExp(term) : null;
    const homes = s.homes.filter((h) => {
      if (staffId && !staffMemberValid(h.id, staffId)) return false;
      if (re) {
        const owner = ownerOf(h.id);
        const fields = [h.name, h.address || '', owner ? owner.full_name : null, owner ? owner.email : null, owner ? owner.phone || '' : null];
        const deviceHit = s.devices.some((d) => d.home_id === h.id && re.test(d.device_uuid));
        if (!fields.some((f) => f !== null && re.test(String(f))) && !deviceHit) return false;
      }
      return true;
    });
    return { homes, rest: params.slice(i) };
  };
  db.on((sql) => sql.startsWith('SELECT COUNT(*)::int AS total FROM homes h'), ({ sql, params }) => [
    { total: subscriberFilter(sql, params).homes.length },
  ]);
  db.on((sql) => sql.startsWith('SELECT h.id AS home_id, h.name AS home_name'), ({ sql, params }) => {
    const { homes, rest } = subscriberFilter(sql, params);
    const [limit, offset] = rest;
    homes.sort((a, b) => ms(b.created_at) - ms(a.created_at) || (a.id < b.id ? -1 : 1));
    return homes.slice(offset, offset + limit).map((h) => {
      const o = ownerOf(h.id);
      return {
        home_id: h.id, home_name: h.name, home_address: h.address || null, home_created_at: h.created_at,
        owner_id: o ? o.id : null, owner_full_name: o ? o.full_name : null, owner_email: o ? o.email : null,
        owner_phone: o ? o.phone || null : null, owner_account_status: o ? o.account_status : null,
      };
    });
  });
  db.on('FROM devices d WHERE d.home_id = ANY($1::uuid[]) GROUP BY d.home_id', ({ params }) => {
    const out = [];
    for (const homeId of params[0]) {
      const devs = s.devices.filter((d) => d.home_id === homeId).sort((a, b) => ms(a.created_at) - ms(b.created_at));
      if (devs.length === 0) continue;
      const commissioned = devs.filter((d) => d.is_commissioned === true);
      out.push({
        home_id: homeId,
        device_count: devs.length,
        online_count: devs.filter((d) => d.is_online === true).length,
        commissioned_count: commissioned.length,
        commissioned_at: commissioned.length ? new Date(Math.max(...commissioned.map((d) => ms(d.commissioned_at)))) : null,
        last_seen_at: devs.some((d) => d.last_seen_at) ? new Date(Math.max(...devs.filter((d) => d.last_seen_at).map((d) => ms(d.last_seen_at)))) : null,
        device_uuids: devs.map((d) => d.device_uuid).slice(0, 10),
      });
    }
    return out;
  });

  // ================================================================== Home Admin atama
  db.on('SELECT id, name FROM homes WHERE id = $1', ({ params }) => copies(s.homes.filter((h) => h.id === params[0])));
  db.on('SELECT id, name, mqtt_username FROM homes WHERE id = $1 FOR UPDATE', async (ctx) => {
    const home = homeById(ctx.params[0]);
    if (!home) return [];
    await ctx.lock(`home:${home.id}`);
    return [copy(home)];
  });
  db.on('SELECT id, role, is_active, account_status FROM users WHERE id = $1', ({ params }) => copies(s.users.filter((u) => u.id === params[0])));
  db.on(
    "SELECT 1 FROM home_users WHERE home_id = $1 AND user_id = $2 AND role = 'service_user' AND (installer_expires_at IS NULL OR installer_expires_at > NOW())",
    ({ params }) => (staffMemberValid(params[0], params[1]) ? [{ '?column?': 1 }] : [])
  );
  db.on("FROM home_users hu JOIN users u ON u.id = hu.user_id WHERE hu.home_id = $1 AND hu.role = 'owner'", ({ params }) =>
    membersOf(params[0])
      .filter((m) => m.role === 'owner')
      .sort((a, b) => ms(a.created_at) - ms(b.created_at) || a.seq - b.seq)
      .map((m) => {
        const u = userById(m.user_id);
        return { id: u.id, email: u.email, full_name: u.full_name, phone: u.phone || null, account_status: u.account_status };
      })
  );
  const targetColumns = (u) => ({ id: u.id, email: u.email, full_name: u.full_name, phone: u.phone || null, role: u.role, is_active: u.is_active, account_status: u.account_status });
  db.on('SELECT id, email, full_name, phone, role, is_active, account_status FROM users WHERE LOWER(email) = $1', ({ params }) =>
    s.users.filter((u) => String(u.email).toLowerCase() === params[0]).map(targetColumns)
  );
  db.on('SELECT id, email, full_name, phone, role, is_active, account_status FROM users WHERE phone = $1', ({ params }) =>
    s.users.filter((u) => u.phone && u.phone === params[0]).map(targetColumns)
  );
  db.on('SELECT 1 FROM users WHERE phone = $1', ({ params }) => (s.users.some((u) => u.phone === params[0]) ? [{ '?column?': 1 }] : []));

  db.on("DELETE FROM home_admin_assign_otps WHERE expires_at < NOW() - INTERVAL '1 day'", (ctx) => ({
    rows: [],
    rowCount: removeRows(ctx, s.home_admin_assign_otps, (o) => ms(o.expires_at) < now().getTime() - 86400000).length,
  }));
  db.on((sql) => sql.startsWith('INSERT INTO home_admin_assign_otps'), (ctx) => {
    const [homeId, ownerId, target, targetName, otpHash, expiresAt, requestedBy, windowMinutes, cooldownSeconds] = ctx.params;
    const t = now().getTime();
    const existing = s.home_admin_assign_otps.find((o) => o.home_id === homeId);
    if (!existing) {
      const row = insert(ctx, s.home_admin_assign_otps, {
        id: uid(), home_id: homeId, owner_user_id: ownerId, target_identifier: target, target_name: targetName, otp_hash: otpHash,
        expires_at: expiresAt, attempts: 0, window_started_at: now(), requested_by: requestedBy, created_at: now(),
      });
      return [{ attempts: row.attempts, window_started_at: row.window_started_at }];
    }
    if (!(ms(existing.created_at) < t - cooldownSeconds * 1000)) return []; // WHERE created_at < NOW() - cooldown
    const windowExpired = ms(existing.window_started_at) < t - windowMinutes * 60000;
    patch(ctx, existing, {
      owner_user_id: ownerId, target_identifier: target, target_name: targetName, otp_hash: otpHash, expires_at: expiresAt,
      requested_by: requestedBy, created_at: now(),
      attempts: windowExpired ? 0 : existing.attempts,
      window_started_at: windowExpired ? now() : existing.window_started_at,
    });
    return [{ attempts: existing.attempts, window_started_at: existing.window_started_at }];
  });
  db.on('AS wait_seconds FROM home_admin_assign_otps', ({ params }) => {
    const row = s.home_admin_assign_otps.find((o) => o.home_id === params[0]);
    if (!row) return [];
    const elapsed = (now().getTime() - ms(row.created_at)) / 1000;
    return [{ wait_seconds: Math.max(1, Math.ceil(params[1] - elapsed)) }];
  });
  db.on('UPDATE home_admin_assign_otps SET expires_at = NOW(), created_at = NOW() - INTERVAL', (ctx) => {
    const row = s.home_admin_assign_otps.find((o) => o.home_id === ctx.params[0] && o.otp_hash === ctx.params[1]);
    if (row) patch(ctx, row, { expires_at: now(), created_at: new Date(now().getTime() - 86400000) });
    return { rows: [], rowCount: row ? 1 : 0 };
  });
  db.on('FROM home_admin_assign_otps WHERE home_id = $1 FOR UPDATE', async (ctx) => {
    const row = s.home_admin_assign_otps.find((o) => o.home_id === ctx.params[0]);
    if (!row) return [];
    await ctx.lock(`otp:${row.id}`);
    return [copy(row)];
  });
  db.on('UPDATE home_admin_assign_otps SET attempts = attempts + 1', (ctx) => {
    const row = s.home_admin_assign_otps.find((o) => o.id === ctx.params[0]);
    patch(ctx, row, { attempts: row.attempts + 1 });
    return [{ attempts: row.attempts }];
  });
  db.on('DELETE FROM home_admin_assign_otps WHERE id = $1', (ctx) => ({
    rows: [], rowCount: removeRows(ctx, s.home_admin_assign_otps, (o) => o.id === ctx.params[0]).length,
  }));
  db.on('DELETE FROM home_admin_assign_otps WHERE home_id = $1', (ctx) => ({
    rows: [], rowCount: removeRows(ctx, s.home_admin_assign_otps, (o) => o.home_id === ctx.params[0]).length,
  }));
  db.on('DELETE FROM home_admin_assign_otps WHERE owner_user_id = $1 OR requested_by = $1 OR target_identifier = ANY($2::text[])', (ctx) => ({
    rows: [],
    rowCount: removeRows(
      ctx, s.home_admin_assign_otps,
      (o) => o.owner_user_id === ctx.params[0] || o.requested_by === ctx.params[0] || ctx.params[1].includes(o.target_identifier)
    ).length,
  }));

  db.on((sql) => sql.startsWith('INSERT INTO users (full_name, email, password_hash, phone, role, is_active, account_status, created_by_user_id)'), (ctx) => {
    const [fullName, email, hash, phone, createdBy] = ctx.params;
    if (s.users.some((u) => u.email === email)) return []; // ON CONFLICT (email) DO NOTHING
    if (phone && s.users.some((u) => u.phone === phone)) throw dupError('uq_users_phone');
    const row = insert(ctx, s.users, {
      id: uid(), full_name: fullName, email, password_hash: hash, phone, role: 'user', is_active: true, account_status: 'pending_invite',
      created_by_user_id: createdBy, token_version: 1, must_change_password: false, email_verified: false,
      password_changed_at: null, google_id: null, apple_id: null, deleted_at: null,
    });
    return [targetColumns(row)];
  });
  db.on(
    (sql) => sql.startsWith('DELETE FROM home_users WHERE home_id = $1 AND ($2::uuid IS NULL OR NOT (user_id = $2::uuid AND role = \'service_user\'))'),
    (ctx) => {
      const [homeId, keepStaff] = ctx.params;
      const removed = removeRows(ctx, s.home_users, (m) => m.home_id === homeId && !(keepStaff && m.user_id === keepStaff && m.role === 'service_user'));
      return removed.map((m) => ({ user_id: m.user_id }));
    }
  );
  db.on("INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner') ON CONFLICT (home_id, user_id) DO UPDATE", (ctx) => {
    const [homeId, userId] = ctx.params;
    const existing = s.home_users.find((m) => m.home_id === homeId && m.user_id === userId);
    if (existing) {
      patch(ctx, existing, { role: 'owner', valid_from: null, valid_until: null, installer_expires_at: null });
    } else {
      insert(ctx, s.home_users, { id: uid(), seq: ++seq, home_id: homeId, user_id: userId, role: 'owner', valid_from: null, valid_until: null, installer_expires_at: null, created_at: now() });
    }
    return { rows: [], rowCount: 1 };
  });
  db.on('UPDATE device_inventory SET claimed_by_user_id = $1 WHERE claimed_home_id = $2', (ctx) => {
    const rows = s.device_inventory.filter((i) => i.claimed_home_id === ctx.params[1]);
    for (const r of rows) patch(ctx, r, { claimed_by_user_id: ctx.params[0] });
    return { rows: [], rowCount: rows.length };
  });
  db.on('UPDATE devices SET claimed_by = $1 WHERE home_id = $2', (ctx) => {
    const rows = s.devices.filter((d) => d.home_id === ctx.params[1]);
    for (const r of rows) patch(ctx, r, { claimed_by: ctx.params[0] });
    return { rows: [], rowCount: rows.length };
  });
  // service_token_service.revokeHomeServiceAccess (GERCEK modul SQL'i)
  db.on('UPDATE service_tokens SET revoked_at = NOW() WHERE home_id = $1 AND revoked_at IS NULL AND used_at IS NULL RETURNING id', (ctx) => {
    const rows = s.service_tokens.filter((t) => t.home_id === ctx.params[0] && !t.revoked_at && !t.used_at);
    for (const r of rows) patch(ctx, r, { revoked_at: now() });
    return rows.map((r) => ({ id: r.id }));
  });
  db.on('UPDATE service_sessions SET revoked_at = NOW(), revoked_reason = $2 WHERE home_id = $1 AND revoked_at IS NULL RETURNING id', (ctx) => {
    const rows = s.service_sessions.filter((x) => x.home_id === ctx.params[0] && !x.revoked_at);
    for (const r of rows) patch(ctx, r, { revoked_at: now(), revoked_reason: ctx.params[1] });
    return rows.map((r) => ({ id: r.id }));
  });
  // mqtt_credential_service.revokeHomeAccess / hesap silme
  const deleteCreds = (ctx, pred) => removeRows(ctx, s.mqtt_credentials, pred).map((c) => ({ username: c.username }));
  db.on("DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind = 'app' RETURNING username", (ctx) =>
    deleteCreds(ctx, (c) => c.home_id === ctx.params[0] && c.kind === 'app')
  );
  db.on("DELETE FROM mqtt_credentials WHERE user_id = $1 AND kind = 'app' RETURNING username", (ctx) =>
    deleteCreds(ctx, (c) => c.user_id === ctx.params[0] && c.kind === 'app')
  );
  // revokeHomeAccess({ includeDevice: true }) - bos daire silinirken (UYELIK-03)
  db.on("DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind IN ('app', 'device') RETURNING username", (ctx) =>
    deleteCreds(ctx, (c) => c.home_id === ctx.params[0] && (c.kind === 'app' || c.kind === 'device'))
  );
  // DELETE FROM homes: ON DELETE CASCADE tablolari birlikte gider (migration 001-028), SET NULL olanlar bosaltilir
  db.on('DELETE FROM homes WHERE id = $1', (ctx) => {
    const homeId = ctx.params[0];
    const removed = removeRows(ctx, s.homes, (x) => x.id === homeId);
    if (removed.length === 0) return { rows: [], rowCount: 0 };
    for (const table of ['home_users', 'mqtt_credentials', 'service_tokens', 'service_sessions', 'home_invitations', 'home_transfers', 'scheduled_rules', 'home_admin_assign_otps']) {
      removeRows(ctx, s[table], (r) => r.home_id === homeId);
    }
    for (const d of s.devices.filter((x) => x.home_id === homeId)) patch(ctx, d, { home_id: null });
    for (const a of s.device_audit_logs.filter((x) => x.home_id === homeId)) patch(ctx, a, { home_id: null });
    return { rows: [], rowCount: removed.length };
  });
  db.on((sql) => sql.startsWith('INSERT INTO home_admin_assignment_logs'), (ctx) => {
    const [homeId, homeName, actorId, actorRole, ip, mode, previous, newOwner, created, reason] = ctx.params;
    insert(ctx, s.home_admin_assignment_logs, {
      home_id: homeId, home_name: homeName, actor_user_id: actorId, actor_role: actorRole, ip_address: ip, mode,
      previous_owner_ids: JSON.parse(previous), new_owner_id: newOwner, account_created: created, reason, created_at: now(),
    });
    return { rows: [], rowCount: 1 };
  });
  db.on((sql) => sql.startsWith('INSERT INTO device_audit_logs'), (ctx) => {
    const [event, deviceUuid, homeId, actorUserId, actorRole, ip, details] = ctx.params;
    insert(ctx, s.device_audit_logs, {
      event, device_uuid: deviceUuid, home_id: homeId, actor_user_id: actorUserId, actor_role: actorRole, ip_address: ip,
      details: details ? JSON.parse(details) : null, created_at: now(),
    });
    return { rows: [], rowCount: 1 };
  });

  // ev temizligi (home_cleanup.cleanupHome'un SQL'i yerine testte kullanilan SAHTE temizlik bunlari calistirir)
  db.on('DELETE FROM home_invitations WHERE home_id = $1', (ctx) => ({
    rows: [], rowCount: removeRows(ctx, s.home_invitations, (i) => i.home_id === ctx.params[0]).length,
  }));
  db.on('DELETE FROM scheduled_rules WHERE home_id = $1', (ctx) => ({
    rows: [], rowCount: removeRows(ctx, s.scheduled_rules, (r) => r.home_id === ctx.params[0]).length,
  }));
  db.on("UPDATE home_transfers SET status = 'CANCELLED' WHERE home_id = $1 AND status = 'PENDING'", (ctx) => {
    const rows = s.home_transfers.filter((t) => t.home_id === ctx.params[0] && t.status === 'PENDING');
    for (const r of rows) patch(ctx, r, { status: 'CANCELLED' });
    return { rows: [], rowCount: rows.length };
  });

  // ================================================================== hesap silme
  db.on((sql) => sql.startsWith('SELECT id, email, phone, role, is_active, account_status, password_hash'), ({ params }) =>
    copies(s.users.filter((u) => u.id === params[0]))
  );
  db.on('SELECT id, email, phone, role, account_status FROM users WHERE id = $1 FOR UPDATE', async (ctx) => {
    const u = userById(ctx.params[0]);
    if (!u) return [];
    await ctx.lock(`user:${u.id}`);
    return [copy(u)];
  });
  db.on("AND NOT EXISTS (SELECT 1 FROM home_users o WHERE o.home_id = hu.home_id AND o.role = 'owner' AND o.user_id <> $1)", ({ params }) => {
    const userId = params[0];
    return s.home_users
      .filter((m) => m.user_id === userId && m.role === 'owner' && !s.home_users.some((o) => o.home_id === m.home_id && o.role === 'owner' && o.user_id !== userId))
      .map((m) => ({
        id: m.home_id,
        name: homeById(m.home_id).name,
        other_member_count: s.home_users.filter((x) => x.home_id === m.home_id && x.user_id !== userId).length,
        device_count: s.devices.filter((d) => d.home_id === m.home_id).length,
      }))
      .sort((a, b) => (a.name < b.name ? -1 : 1));
  });
  db.on('DELETE FROM home_users WHERE user_id = $1 RETURNING home_id', (ctx) =>
    removeRows(ctx, s.home_users, (m) => m.user_id === ctx.params[0]).map((m) => ({ home_id: m.home_id }))
  );
  db.on('SELECT to_regclass($1) AS t', ({ params }) => [{ t: params[0] === 'public.push_tokens' && flags.pushTokensTable ? 'public.push_tokens' : null }]);
  db.on('DELETE FROM push_tokens WHERE user_id = $1', (ctx) => ({ rows: [], rowCount: removeRows(ctx, s.push_tokens, (t) => t.user_id === ctx.params[0]).length }));
  db.on('DELETE FROM home_invitations WHERE created_by = $1 AND is_used = FALSE', (ctx) => ({
    rows: [], rowCount: removeRows(ctx, s.home_invitations, (i) => i.created_by === ctx.params[0] && !i.is_used).length,
  }));
  db.on("UPDATE home_transfers SET status = 'CANCELLED' WHERE status = 'PENDING' AND (from_user_id = $1 OR target_identifier = ANY($2::text[]))", (ctx) => {
    const rows = s.home_transfers.filter((t) => t.status === 'PENDING' && (t.from_user_id === ctx.params[0] || ctx.params[1].includes(t.target_identifier)));
    for (const r of rows) patch(ctx, r, { status: 'CANCELLED' });
    return { rows: [], rowCount: rows.length };
  });
  db.on("UPDATE service_sessions SET revoked_at = NOW(), revoked_reason = 'account_deleted'", (ctx) => {
    const tokenIds = s.service_tokens.filter((t) => t.created_by === ctx.params[0]).map((t) => t.id);
    const rows = s.service_sessions.filter((x) => !x.revoked_at && tokenIds.includes(x.service_token_id));
    for (const r of rows) patch(ctx, r, { revoked_at: now(), revoked_reason: 'account_deleted' });
    return { rows: [], rowCount: rows.length };
  });
  db.on('UPDATE service_tokens SET revoked_at = NOW() WHERE created_by = $1 AND revoked_at IS NULL AND used_at IS NULL', (ctx) => {
    const rows = s.service_tokens.filter((t) => t.created_by === ctx.params[0] && !t.revoked_at && !t.used_at);
    for (const r of rows) patch(ctx, r, { revoked_at: now() });
    return { rows: [], rowCount: rows.length };
  });
  db.on('DELETE FROM scheduled_rules WHERE created_by = $1', (ctx) => ({ rows: [], rowCount: removeRows(ctx, s.scheduled_rules, (r) => r.created_by === ctx.params[0]).length }));
  db.on('DELETE FROM password_resets WHERE user_id = $1 OR identifier = ANY($2::text[])', (ctx) => ({
    rows: [], rowCount: removeRows(ctx, s.password_resets, (r) => r.user_id === ctx.params[0] || ctx.params[1].includes(r.identifier)).length,
  }));
  db.on('DELETE FROM phone_otp_codes WHERE phone = ANY($1::text[])', (ctx) => ({
    rows: [], rowCount: removeRows(ctx, s.phone_otp_codes, (r) => ctx.params[0].includes(r.phone)).length,
  }));
  db.on('DELETE FROM device_claim_otps WHERE requested_by = $1 OR target_identifier = ANY($2::text[])', (ctx) => ({
    rows: [], rowCount: removeRows(ctx, s.device_claim_otps, (r) => r.requested_by === ctx.params[0] || ctx.params[1].includes(r.target_identifier)).length,
  }));
  db.on('DELETE FROM refresh_tokens WHERE user_id = $1', (ctx) => ({ rows: [], rowCount: removeRows(ctx, s.refresh_tokens, (r) => r.user_id === ctx.params[0]).length }));
  db.on((sql) => sql.startsWith('UPDATE users SET email = $2, full_name = $3, phone = NULL'), (ctx) => {
    const [id, email, fullName, hash] = ctx.params;
    const u = userById(id);
    if (!u || u.account_status === 'deleted') return [];
    patch(ctx, u, {
      email, full_name: fullName, phone: null, google_id: null, apple_id: null, password_hash: hash, is_active: false, account_status: 'deleted',
      deleted_at: now(), email_verified: false, must_change_password: false, admin_notes: null, token_version: u.token_version + 1,
    });
    return [{ deleted_at: u.deleted_at }];
  });

  // ================================================================== hesap kurulum daveti (auth_service.issueUserCode)
  db.on(
    'SELECT id, email, full_name, phone, role, is_active, account_status, token_version, must_change_password, email_verified, google_id, apple_id FROM users WHERE id = $1',
    ({ params }) => copies(s.users.filter((u) => u.id === params[0]))
  );
  db.on('UPDATE password_resets SET used_at = NOW() WHERE identifier = $1 AND used_at IS NULL', (ctx) => {
    const rows = s.password_resets.filter((r) => r.identifier === ctx.params[0] && !r.used_at);
    for (const r of rows) patch(ctx, r, { used_at: now() });
    return { rows: [], rowCount: rows.length };
  });
  db.on((sql) => sql.startsWith('INSERT INTO password_resets (user_id, identifier, code_hash, token_hash, expires_at, attempts, purpose)'), (ctx) => {
    const [userId, identifier, codeHash, tokenHash, ttlSec, purpose] = ctx.params;
    const row = insert(ctx, s.password_resets, {
      id: ++seq, user_id: userId, identifier, code_hash: codeHash, token_hash: tokenHash, expires_at: new Date(now().getTime() + ttlSec * 1000),
      attempts: 0, purpose, used_at: null, created_at: now(),
    });
    return [{ id: row.id, expires_at: row.expires_at }];
  });

  // ================================================================== kayit / giris (A'nin gercek auth_service SQL'i)
  db.on((sql) => sql === 'SELECT id FROM users WHERE LOWER(email) = $1', ({ params }) =>
    s.users.filter((u) => String(u.email).toLowerCase() === params[0]).map((u) => ({ id: u.id }))
  );
  db.on((sql) => sql === 'SELECT id FROM users WHERE phone = $1', ({ params }) => s.users.filter((u) => u.phone === params[0]).map((u) => ({ id: u.id })));
  db.on((sql) => sql.startsWith('INSERT INTO users (full_name, email, password_hash, phone, role, is_active, account_status, password_changed_at)'), (ctx) => {
    const [fullName, email, hash, phone] = ctx.params;
    if (s.users.some((u) => String(u.email).toLowerCase() === String(email).toLowerCase())) throw dupError('uq_users_email_lower');
    if (phone && s.users.some((u) => u.phone === phone)) throw dupError('uq_users_phone');
    const row = insert(ctx, s.users, {
      id: uid(), full_name: fullName, email, password_hash: hash, phone, role: 'user', is_active: true, account_status: 'active',
      token_version: 1, must_change_password: false, email_verified: false, password_changed_at: now(), google_id: null, apple_id: null,
      created_by_user_id: null, deleted_at: null,
    });
    return [{ ...row }];
  });
  db.on((sql) => sql.startsWith('INSERT INTO refresh_tokens'), (ctx) => {
    const [userId, tokenHash, familyId, expiresAt, ip] = ctx.params;
    const row = insert(ctx, s.refresh_tokens, { id: uid(), user_id: userId, token_hash: tokenHash, family_id: familyId, expires_at: expiresAt, created_ip: ip, revoked_at: null, used_at: null });
    return [{ id: row.id }];
  });
  db.on('FROM home_users hu JOIN homes h ON h.id = hu.home_id WHERE hu.user_id = $1', ({ params }) =>
    s.home_users.filter((m) => m.user_id === params[0]).map((m) => {
      const h = homeById(m.home_id);
      return { id: h.id, name: h.name, address: h.address || null, mqtt_username: h.mqtt_username, timezone: 'Europe/Istanbul', role: m.role, valid_from: m.valid_from, valid_until: m.valid_until, installer_expires_at: m.installer_expires_at };
    })
  );
  db.on(', password_hash FROM users WHERE LOWER(email) = $1', ({ params }) => copies(s.users.filter((u) => String(u.email).toLowerCase() === params[0])));

  // ================================================================== envanter etiketi yeniden uretimi
  db.on('FROM device_inventory di WHERE di.device_uuid = $1 FOR UPDATE OF di', async (ctx) => {
    const inv = s.device_inventory.find((i) => i.device_uuid === ctx.params[0]);
    if (!inv) return [];
    await ctx.lock(`inv:${inv.id}`);
    const attached = s.devices.some((d) => d.device_uuid === inv.device_uuid && (d.home_id || d.is_claimed === true || d.is_commissioned === true));
    return [{ id: inv.id, status: inv.status, claimed_home_id: inv.claimed_home_id || null, attached }];
  });
  db.on((sql) => sql.startsWith('UPDATE device_inventory SET pin_hash = $1, local_key_enc = $2'), (ctx) => {
    const [pinHash, enc, id] = ctx.params;
    const inv = s.device_inventory.find((i) => i.id === id && i.status === 'IN_STOCK');
    if (!inv) return [];
    patch(ctx, inv, {
      pin_hash: pinHash, local_key_enc: enc, failed_attempts: 0, locked_until: null, label_reissued_at: now(),
      label_reissue_count: (inv.label_reissue_count || 0) + 1,
    });
    return [{
      id: inv.id, serial_no: inv.serial_no, device_uuid: inv.device_uuid, mac_address: inv.mac_address, model: inv.model,
      batch_no: inv.batch_no, status: inv.status, label_reissued_at: inv.label_reissued_at, label_reissue_count: inv.label_reissue_count,
    }];
  });
  db.on('UPDATE devices SET local_key_enc = $1, updated_at = CURRENT_TIMESTAMP WHERE device_uuid = $2 AND home_id IS NULL', (ctx) => {
    const rows = s.devices.filter((d) => d.device_uuid === ctx.params[1] && !d.home_id);
    for (const r of rows) patch(ctx, r, { local_key_enc: ctx.params[0] });
    return { rows: [], rowCount: rows.length };
  });

  // ================================================================== davet / devir kodu onizleme
  db.on('FROM home_invitations i JOIN homes h ON h.id = i.home_id WHERE i.code_hash = $1', ({ params }) =>
    s.home_invitations.filter((i) => i.code_hash === params[0]).map((i) => ({
      ...i, home_name: homeById(i.home_id).name,
      resident_count: s.home_users.filter((m) => m.home_id === i.home_id && ['owner', 'resident'].includes(m.role)).length,
      already_member: s.home_users.some((m) => m.home_id === i.home_id && m.user_id === params[1]),
    }))
  );
  db.on('FROM home_transfers t JOIN homes h ON h.id = t.home_id WHERE t.code_hash = $1', ({ params }) =>
    s.home_transfers.filter((t) => t.code_hash === params[0]).map((t) => ({
      ...t, home_name: homeById(t.home_id).name,
      resident_count: s.home_users.filter((m) => m.home_id === t.home_id && ['owner', 'resident'].includes(m.role)).length,
    }))
  );
  db.on('SELECT id, email, phone FROM users WHERE id = $1', ({ params }) => copies(s.users.filter((u) => u.id === params[0])));

  // ================================================================== olusturucular
  const h = {
    user({ email, role = 'user', phone = null, full_name = 'Test Kisi', status = 'active', password_hash = 'x', google_id = null, apple_id = null, password_changed_at = null, must_change_password = false } = {}) {
      const row = {
        id: uid(), email: email || `u${++seq}-${uid().slice(0, 6)}@example.test`, role, phone, full_name, is_active: status !== 'suspended',
        account_status: status, password_hash, token_version: 1, must_change_password, email_verified: true, password_changed_at,
        google_id, apple_id, created_by_user_id: null, deleted_at: null,
      };
      s.users.push(row);
      return row;
    },
    home({ name, owner = null, address = null, created_at } = {}) {
      const row = { id: uid(), name: name || `Ev ${++seq}`, address, mqtt_username: `h_${crypto.randomBytes(8).toString('hex')}`, created_at: created_at || new Date(now().getTime() + ++seq) };
      s.homes.push(row);
      if (owner) h.member(row, owner, 'owner');
      return row;
    },
    member(home, user, role, extra = {}) {
      const row = { id: uid(), seq: ++seq, home_id: home.id, user_id: user.id, role, valid_from: null, valid_until: null, installer_expires_at: null, created_at: new Date(now().getTime() + seq), ...extra };
      s.home_users.push(row);
      return row;
    },
    device(home, { online = false, commissioned = false, uuid, last_seen_at = null } = {}) {
      const row = {
        id: uid(), home_id: home ? home.id : null, device_uuid: uuid || `AHBU-T${++seq}-${uid().slice(0, 4).toUpperCase()}`, is_online: online,
        is_commissioned: commissioned, commissioned_at: commissioned ? now() : null, last_seen_at: last_seen_at || (online ? now() : null),
        created_at: new Date(now().getTime() + seq), is_claimed: Boolean(home), claimed_by: null, local_key_enc: null,
      };
      s.devices.push(row);
      return row;
    },
    inventory({ uuid, status = 'IN_STOCK', pin_hash = 'old-pin-hash', local_key_enc = 'old-key-enc', claimed_home_id = null } = {}) {
      const row = {
        id: uid(), device_uuid: uuid || `AHBU-S3-${String(++seq).padStart(4, '0')}`, mac_address: 'E8:F6:0A:00:00:01', model: 'ESP32-S3-POE-ETH-8DI-8RO',
        batch_no: 'B1', serial_no: s.device_inventory.length + 1, status, pin_hash, local_key_enc, failed_attempts: 3, locked_until: new Date(now().getTime() + 600000),
        claimed_home_id, claimed_by_user_id: null, label_reissue_count: 0, label_reissued_at: null,
      };
      s.device_inventory.push(row);
      return row;
    },
    appCredential(home, user) {
      const row = { id: uid(), username: `a_${home.mqtt_username}_${crypto.randomBytes(5).toString('hex')}`, kind: 'app', home_id: home.id, user_id: user ? user.id : null, expires_at: null };
      s.mqtt_credentials.push(row);
      return row;
    },
    serviceSession(home, { ownerId } = {}) {
      const token = { id: uid(), home_id: home.id, created_by: ownerId || null, used_at: null, revoked_at: null };
      s.service_tokens.push(token);
      const session = { id: uid(), home_id: home.id, service_token_id: token.id, technician_name: 'Usta', expires_at: new Date(now().getTime() + 7200000), revoked_at: null };
      s.service_sessions.push(session);
      return { token, session };
    },
  };

  return { state: s, db, clock, helpers: h, flags, now };
}

// ------------------------------------------------------------------------------
// Tam ortam: ortam degiskenleri + sahte db.js + yakalayici e-posta + gercek app
// ------------------------------------------------------------------------------
function createEnv({ clock = createClock() } = {}) {
  process.env.NODE_ENV = 'test';
  process.env.BCRYPT_TEST_COST = '4';
  process.env.AUTH_CACHE_TTL_MS = '0';
  process.env.JWT_SECRET = crypto.randomBytes(32).toString('hex');
  process.env.PIN_PEPPER = crypto.randomBytes(32).toString('hex');
  process.env.LOCAL_KEY_SECRET = crypto.randomBytes(32).toString('hex');
  process.env.DATABASE_URL = 'postgres://test-only-not-used/none';
  process.env.MQTT_PUBLIC_HOST = 'broker.test.invalid';
  process.env.MQTT_PUBLIC_PORT = '8884';
  // dotenv yalniz TANIMSIZ degiskenleri yukler: canli olabilecek yerel .env degerleri BOS dizgeyle sabitlenir
  for (const k of ['EMQX_API_URL', 'EMQX_API_KEY', 'EMQX_API_SECRET', 'ALLOW_DEBUG_OTP', 'ADMIN_API_KEY', 'SMTP_HOST', 'SMTP_USER', 'SMTP_PASSWORD', 'GOOGLE_CLIENT_IDS', 'APPLE_CLIENT_IDS', 'MQTT_BACKEND_USER', 'MQTT_BACKEND_PASS']) {
    process.env[k] = '';
  }
  console.warn = () => {};

  const world = createWorld({ clock });
  const dbProxy = {
    query: (t, p) => world.db.query(t, p),
    withTransaction: (fn) => world.db.withTransaction(fn),
    pool: { end: async () => {} },
  };
  injectModule('db.js', dbProxy);

  const request = require('supertest');
  const SRC = (rel) => require(path.join(__dirname, '..', '..', 'src', rel));
  const mailer = SRC('utils/mailer');
  const jwtConfig = SRC('middlewares/jwt_config');

  const mails = [];
  const mailControl = { fail: false };
  mailer.setTransportFactory(() => ({
    sendMail: async (msg) => {
      if (mailControl.fail) throw new Error('smtp down');
      mails.push({ to: String(msg.to), subject: String(msg.subject), text: String(msg.text) });
    },
  }));

  const { createApp } = SRC('server');
  const bridge = { isConnected: () => true, init() {}, end: async () => {}, publishCommand: async () => ({}), publishSys: async () => ({}), clearRetained: async () => {} };
  const app = createApp({ db: dbProxy, mqttBridge: bridge, pushService: { upsertToken: async () => {}, disableToken: async () => {} } });

  const api = (method, url, token, body) => {
    let r = request(app)[method](url);
    if (token) r = r.set('Authorization', `Bearer ${token}`);
    if (body !== undefined && method !== 'get') r = r.send(body);
    return r;
  };
  const tokenOf = (user) => jwtConfig.signAccessToken({ id: user.id, role: user.role, token_version: user.token_version });

  const env = {
    world, state: world.state, h: world.helpers, clock, app, api, request, mails, mailControl, mailer, jwtConfig, SRC, tokenOf,
    lastOtp(toEmail) {
      for (let i = mails.length - 1; i >= 0; i--) {
        if (mails[i].to === toEmail) {
          const m = /iletin: (\d{6})/.exec(mails[i].text);
          if (m) return m[1];
        }
      }
      return null;
    },
    mailsTo: (to) => mails.filter((m) => m.to === to),
    sessionToken(home, session) {
      return jwtConfig.signServiceSessionToken({ sid: session.id, home_id: home.id, expiresInSec: 3600 });
    },
  };
  return env;
}

module.exports = { createWorld, createEnv, createClock, likeToRegExp, uid };
