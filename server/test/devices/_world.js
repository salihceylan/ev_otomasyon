'use strict';

// ==============================================================================
// Test altyapisi: "dunya" = bellek ici tablolar + device_service / mqtt_credential_service SQL'lerini
// taklit eden isleyiciler + sahte bagimliliklar (pin, mailer, bridge, fetch...).
//
// Isleyiciler uretim SQL'inin ANLAMINI yansitir (kilit, atomik sayac, upsert, RETURNING, ON CONFLICT).
// Uretim SQL'i degisirse eslesen isleyici bulunamaz ve test gurultuyle kirilir.
// ==============================================================================

const crypto = require('crypto');
const { FakeDb, tick } = require('./_fake_db');

const uid = () => crypto.randomUUID();
const copy = (o) => (o ? { ...o } : o);
const copies = (arr) => arr.map((o) => ({ ...o }));
const normPhone = (p) => String(p || '').replace(/[^0-9+]/g, '');

// --- Sahte saat -------------------------------------------------------------------
function createClock(startIso = '2026-10-01T12:00:00.000Z') {
  const clock = {
    t: Date.parse(startIso),
    now() {
      return new Date(this.t);
    },
    advance(ms) {
      this.t += ms;
    },
  };
  return clock;
}

// --- Ortam ----------------------------------------------------------------------
function setTestEnv(extra = {}) {
  process.env.LOCAL_KEY_SECRET = crypto.randomBytes(32).toString('hex');
  process.env.PIN_PEPPER = crypto.randomBytes(32).toString('hex');
  process.env.MQTT_PUBLIC_HOST = 'broker.test.invalid';
  process.env.MQTT_PUBLIC_PORT = '8884';
  process.env.NODE_ENV = 'test';
  for (const k of ['EMQX_API_URL', 'EMQX_API_KEY', 'EMQX_API_SECRET', 'ALLOW_DEBUG_OTP']) delete process.env[k];
  Object.assign(process.env, extra);
}

// --- Sahte PIN ozeti (A'nin pin.js'inin arayuzunu taklit eder: hashPin / verifyPin) ---
// Ozet duz metni ICERMEZ (testlerde "duz metin PIN saklanmadi" iddiasi anlamli olsun diye).
const fakePin = {
  hashPin: (pin) =>
    `h1$${crypto.createHash('sha256').update(`fake-pepper:${String(pin).trim()}`).digest('hex')}`,
  verifyPin: (pin, stored) => typeof stored === 'string' && stored === fakePin.hashPin(pin),
};

function createFakeMailer() {
  const mailer = {
    sent: [],
    failWith: null, // { sent:false, reason } veya Error
    async sendClaimOtpEmail(args) {
      if (this.failWith instanceof Error) throw this.failWith;
      if (this.failWith) return this.failWith;
      this.sent.push({ to: args.to, deviceUuid: args.deviceUuid, code: args.code });
      return { sent: true };
    },
    lastCode() {
      return this.sent.length ? this.sent[this.sent.length - 1].code : null;
    },
  };
  return mailer;
}

function createFakeBridge(timeline = []) {
  return {
    connected: true,
    failPublish: false,
    failSys: false,
    failClear: false,
    commands: [],
    topics: [],
    cleared: [],
    isConnected() {
      return this.connected;
    },
    async publishCommand(topicId, obj) {
      if (this.failPublish) throw new Error('broker down');
      this.commands.push({ topicId, obj: JSON.parse(JSON.stringify(obj)) });
      timeline.push('publishCommand');
      return {};
    },
    async publishToTopic(topic, obj) {
      if (this.failSys) throw new Error('broker down');
      this.topics.push({ topic, obj: JSON.parse(JSON.stringify(obj)) });
      timeline.push('publishSys');
      return {};
    },
    // C paketinin bridge.publishSys(topicId, obj) imzasi (yuk loglanmaz); kayit publishToTopic ile ayni listeye
    async publishSys(topicId, obj) {
      if (this.failSys) throw new Error('broker down');
      this.topics.push({ topic: `ev/${topicId}/sys`, obj: JSON.parse(JSON.stringify(obj)), via: 'publishSys' });
      timeline.push('publishSys');
      return {};
    },
    async clearRetained(topicId) {
      if (this.failClear) throw new Error('clear failed');
      this.cleared.push(topicId);
      timeline.push('clearRetained');
    },
  };
}

/** EMQX REST sahtesi: GET /clients?username=U -> [{clientid:U}], DELETE /clients/:id -> 204 */
function createFakeFetch(timeline = []) {
  const fetchFn = async (url, init = {}) => {
    fetchFn.calls.push({ url: String(url), method: init.method || 'GET', headers: init.headers || {} });
    if (fetchFn.failAll) throw new Error('network');
    const u = new URL(url);
    if ((init.method || 'GET') === 'GET' && u.pathname.endsWith('/clients')) {
      const username = u.searchParams.get('username');
      return { ok: true, status: 200, json: async () => ({ data: [{ clientid: username, username }] }) };
    }
    if (init.method === 'DELETE') {
      timeline.push(`kick:${decodeURIComponent(u.pathname.split('/').pop())}`);
      return { ok: !fetchFn.deleteStatus || fetchFn.deleteStatus < 400, status: fetchFn.deleteStatus || 204, json: async () => ({}) };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  fetchFn.calls = [];
  fetchFn.failAll = false;
  fetchFn.deleteStatus = 0;
  return fetchFn;
}

const silentLogger = { warn() {}, error() {}, log() {} };

// --- Varsayilan kanal yerlesimi (uretim SEED_ENDPOINTS_SQL'inin aynisi) ---------------------
function defaultEndpointRows(homeId, deviceId, count) {
  const names = {
    1: 'Salon Panjur Yukarı', 2: 'Salon Panjur Aşağı', 3: 'Oda Panjur Yukarı', 4: 'Oda Panjur Aşağı',
    5: 'Salon Aydınlatma', 6: 'Mutfak Aydınlatma', 7: 'Koridor Aydınlatma', 8: 'Balkon Aydınlatma',
  };
  const rooms = { 1: 'Salon', 2: 'Salon', 3: 'Oda', 4: 'Oda', 5: 'Salon', 6: 'Mutfak', 7: 'Koridor', 8: 'Balkon' };
  const rows = [];
  for (let n = 1; n <= count; n++) {
    rows.push({
      id: uid(),
      home_id: homeId,
      device_id: deviceId,
      channel_index: n,
      name: names[n] || `Ek Modül Röle ${n - 8}`,
      type: n <= 4 ? 'shutter' : 'light',
      room: rooms[n] || 'Genel',
      shutter_pair_index: n <= 4 ? Math.floor((n + 1) / 2) : null,
      shutter_duration_sec: n <= 4 ? 20 : null,
      current_state: false,
      current_position: 0,
    });
  }
  return rows;
}

// ==============================================================================
function createWorld({ clock = createClock() } = {}) {
  const state = {
    users: [],
    homes: [],
    home_users: [],
    devices: [],
    device_inventory: [],
    endpoints: [],
    device_claim_otps: [],
    mqtt_credentials: [],
    mqtt_acl: [],
    device_audit_logs: [],
    emergency_reset_logs: [],
    device_replacement_logs: [],
    commissioning_logs: [],
    commissioning_checks: [],
    peace_notification_logs: [],
  };
  const db = new FakeDb();
  const now = () => clock.now();
  let homeSeq = 0;

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

  // ------------------------------------------------------------------ users
  db.on('FROM users WHERE id = $1', ({ params }) => copies(state.users.filter((u) => u.id === params[0])));
  db.on("regexp_replace(COALESCE(phone, ''), '[^0-9+]', '', 'g') = $1", ({ params }) =>
    copies(state.users.filter((u) => normPhone(u.phone) === params[0]))
  );
  db.on('FROM users WHERE LOWER(email) = $1', ({ params }) =>
    copies(state.users.filter((u) => String(u.email).toLowerCase() === params[0]))
  );
  db.on('FROM users WHERE email = $1', ({ params }) => copies(state.users.filter((u) => u.email === params[0])));
  db.on('INSERT INTO users (full_name, email, password_hash', (ctx) => {
    const [fullName, email, passwordHash, createdBy] = ctx.params;
    if (state.users.some((u) => u.email === email)) return []; // ON CONFLICT (email) DO NOTHING
    const row = insert(ctx, state.users, {
      id: uid(), full_name: fullName, email, password_hash: passwordHash, phone: null, role: 'user',
      is_active: true, account_status: 'pending_invite', created_by_user_id: createdBy,
    });
    return [copy(row)];
  });

  // ------------------------------------------------------------------ kilitler
  db.on('pg_advisory_xact_lock', async (ctx) => {
    await ctx.lock(`adv:${ctx.params[0]}`);
    await tick();
    return [{ pg_advisory_xact_lock: '' }];
  });

  // ------------------------------------------------------------------ device_inventory
  db.on('FROM device_inventory WHERE device_uuid = $1 FOR UPDATE', async (ctx) => {
    const inv = state.device_inventory.find((i) => i.device_uuid === ctx.params[0]);
    if (!inv) return [];
    await ctx.lock(`inv:${inv.id}`);
    await tick();
    return [copy(inv)]; // kilit alindiktan SONRA guncel hali okunur
  });
  db.on('FROM device_inventory WHERE device_uuid = $1', ({ params }) =>
    copies(state.device_inventory.filter((i) => i.device_uuid === params[0]))
  );
  db.on('UPDATE device_inventory SET failed_attempts = COALESCE(failed_attempts, 0) + 1', (ctx) => {
    const [id, max, minutes] = ctx.params;
    const inv = state.device_inventory.find((i) => i.id === id);
    const next = (inv.failed_attempts || 0) + 1;
    const changes = { failed_attempts: next };
    if (next >= max) changes.locked_until = new Date(now().getTime() + minutes * 60000);
    patch(ctx, inv, changes);
    return [{ failed_attempts: inv.failed_attempts, locked_until: inv.locked_until }];
  });
  db.on("UPDATE device_inventory SET status = 'CLAIMED'", (ctx) => {
    // claim / pano degisimi (yeni): [home, owner, burned, enc, id] - COALESCE(local_key_enc, $4)
    // acil sifirlama (yeni sahip): [home, owner, burned, enc, id] - local_key_enc = $4
    const [homeId, ownerId, burned, enc, id] = ctx.params;
    const inv = state.device_inventory.find((i) => i.id === id);
    const keepExisting = ctx.sql.includes('COALESCE(local_key_enc, $4)');
    patch(ctx, inv, {
      status: 'CLAIMED', claimed_home_id: homeId, claimed_by_user_id: ownerId, claimed_at: now(),
      failed_attempts: 0, locked_until: null, pin_hash: burned,
      local_key_enc: keepExisting ? inv.local_key_enc || enc : enc,
    });
    return { rows: [], rowCount: 1 };
  });
  db.on("UPDATE device_inventory SET status = 'IN_STOCK'", (ctx) => {
    const [pinHash, enc, id] = ctx.params;
    const inv = state.device_inventory.find((i) => i.id === id);
    patch(ctx, inv, {
      status: 'IN_STOCK', claimed_home_id: null, claimed_by_user_id: null, claimed_at: null,
      failed_attempts: 0, locked_until: null, pin_hash: pinHash, local_key_enc: enc,
    });
    return { rows: [], rowCount: 1 };
  });
  db.on("UPDATE device_inventory SET status = 'REVOKED'", (ctx) => {
    const inv = state.device_inventory.find((i) => i.device_uuid === ctx.params[0]);
    if (inv) patch(ctx, inv, { status: 'REVOKED', claimed_home_id: null });
    return { rows: [], rowCount: inv ? 1 : 0 };
  });

  // ------------------------------------------------------------------ device_claim_otps
  db.on('FROM device_claim_otps WHERE device_uuid = $1 AND target_identifier = $2 FOR UPDATE', async (ctx) => {
    const row = state.device_claim_otps.find((o) => o.device_uuid === ctx.params[0] && o.target_identifier === ctx.params[1]);
    if (!row) return [];
    await ctx.lock(`otp:${row.id}`);
    await tick();
    return [copy(row)];
  });
  db.on('INSERT INTO device_claim_otps', (ctx) => {
    const [uuid, identifier, otpHash, expiresAt, requestedBy, windowMinutes, cooldownSeconds] = ctx.params;
    const t = now().getTime();
    const existing = state.device_claim_otps.find((o) => o.device_uuid === uuid && o.target_identifier === identifier);
    if (!existing) {
      const row = insert(ctx, state.device_claim_otps, {
        id: state.device_claim_otps.length + 1 + Math.floor(Math.random() * 1e6), device_uuid: uuid,
        target_identifier: identifier, otp_hash: otpHash, expires_at: expiresAt, attempts: 0,
        window_started_at: now(), created_at: now(), requested_by: requestedBy,
      });
      return [{ attempts: row.attempts, window_started_at: row.window_started_at }];
    }
    // ON CONFLICT ... DO UPDATE ... WHERE created_at < NOW() - cooldown
    if (!(new Date(existing.created_at).getTime() < t - cooldownSeconds * 1000)) return [];
    const windowExpired = new Date(existing.window_started_at).getTime() < t - windowMinutes * 60000;
    patch(ctx, existing, {
      otp_hash: otpHash, expires_at: expiresAt, requested_by: requestedBy, created_at: now(),
      attempts: windowExpired ? 0 : existing.attempts,
      window_started_at: windowExpired ? now() : existing.window_started_at,
    });
    return [{ attempts: existing.attempts, window_started_at: existing.window_started_at }];
  });
  db.on('AS wait_seconds FROM device_claim_otps', ({ params }) => {
    const row = state.device_claim_otps.find((o) => o.device_uuid === params[0] && o.target_identifier === params[1]);
    if (!row) return [];
    const elapsed = (now().getTime() - new Date(row.created_at).getTime()) / 1000;
    return [{ wait_seconds: Math.max(1, Math.ceil(params[2] - elapsed)) }];
  });
  db.on("UPDATE device_claim_otps SET expires_at = NOW(), created_at = NOW() - INTERVAL '1 day'", (ctx) => {
    const [uuid, identifier, otpHash] = ctx.params;
    const row = state.device_claim_otps.find(
      (o) => o.device_uuid === uuid && o.target_identifier === identifier && o.otp_hash === otpHash
    );
    if (row) patch(ctx, row, { expires_at: now(), created_at: new Date(now().getTime() - 86400000) });
    return { rows: [], rowCount: row ? 1 : 0 };
  });
  db.on('UPDATE device_claim_otps SET attempts = attempts + 1', (ctx) => {
    const row = state.device_claim_otps.find((o) => o.id === ctx.params[0]);
    patch(ctx, row, { attempts: row.attempts + 1 });
    return [{ attempts: row.attempts }];
  });
  db.on('DELETE FROM device_claim_otps WHERE id = $1', (ctx) => {
    const removed = removeRows(ctx, state.device_claim_otps, (o) => o.id === ctx.params[0]);
    return { rows: [], rowCount: removed.length };
  });

  // ------------------------------------------------------------------ homes / home_users
  db.on('FOR UPDATE OF h', async (ctx) => {
    const ownerId = ctx.params[0];
    const candidates = state.homes.filter(
      (h) =>
        state.home_users.some((m) => m.home_id === h.id && m.user_id === ownerId && m.role === 'owner') &&
        !state.devices.some((d) => d.home_id === h.id)
    );
    candidates.sort((a, b) => a.seq - b.seq);
    if (!candidates.length) return [];
    await ctx.lock(`home:${candidates[0].id}`);
    return [copy(candidates[0])];
  });
  db.on('INSERT INTO homes (name, mqtt_username)', (ctx) => {
    const [name, topic] = ctx.params;
    if (state.homes.some((h) => h.mqtt_username === topic)) return []; // ON CONFLICT DO NOTHING
    const row = insert(ctx, state.homes, {
      id: uid(), name, mqtt_username: topic, seq: ++homeSeq, child_lock_enabled: false,
      peace_notification_enabled: true, peace_notification_time: '23:30',
    });
    return [{ id: row.id, name: row.name, mqtt_username: row.mqtt_username }];
  });
  db.on('FROM homes WHERE id = $1 FOR UPDATE', async (ctx) => {
    const home = state.homes.find((h) => h.id === ctx.params[0]);
    if (!home) return [];
    await ctx.lock(`home:${home.id}`);
    return [copy(home)];
  });
  db.on('SELECT mqtt_username FROM homes WHERE id = $1', ({ params }) =>
    copies(state.homes.filter((h) => h.id === params[0]))
  );
  db.on('UPDATE homes SET child_lock_enabled = FALSE', (ctx) => {
    const home = state.homes.find((h) => h.id === ctx.params[0]);
    if (home) {
      patch(ctx, home, {
        child_lock_enabled: false, child_lock_requested: null, child_lock_requested_at: null, child_lock_requested_by: null,
        peace_notification_enabled: true, peace_notification_time: '23:30',
      });
    }
    return { rows: [], rowCount: home ? 1 : 0 };
  });
  db.on('UPDATE devices SET child_lock_enabled = FALSE WHERE home_id = $1', (ctx) => {
    const devs = state.devices.filter((d) => d.home_id === ctx.params[0]);
    for (const d of devs) patch(ctx, d, { child_lock_enabled: false });
    return { rows: [], rowCount: devs.length };
  });
  db.on("INSERT INTO home_users (home_id, user_id, role) VALUES ($1, $2, 'owner')", (ctx) => {
    const [homeId, userId] = ctx.params;
    if (state.home_users.some((m) => m.home_id === homeId && m.user_id === userId)) {
      throw Object.assign(new Error('duplicate key'), { code: '23505' });
    }
    insert(ctx, state.home_users, { home_id: homeId, user_id: userId, role: 'owner', installer_expires_at: null });
    return { rows: [], rowCount: 1 };
  });
  db.on('INSERT INTO home_users (home_id, user_id, role, installer_expires_at)', (ctx) => {
    const [homeId, userId, hours] = ctx.params;
    const expires = new Date(now().getTime() + hours * 3600000);
    const existing = state.home_users.find((m) => m.home_id === homeId && m.user_id === userId);
    if (existing) {
      if (existing.role !== 'service_user') return [];
      patch(ctx, existing, { installer_expires_at: expires });
      return [{ installer_expires_at: expires }];
    }
    insert(ctx, state.home_users, { home_id: homeId, user_id: userId, role: 'service_user', installer_expires_at: expires });
    return [{ installer_expires_at: expires }];
  });
  db.on('FROM home_users WHERE home_id = $1 AND user_id = $2', ({ params, sql }) => {
    const m = state.home_users.find((x) => x.home_id === params[0] && x.user_id === params[1]);
    if (!m) return [];
    // acil sifirlama sorgusu suresi dolmus servis uyeligini SQL'de eler; auth_middleware (A) JS'te kontrol eder
    const filtersExpiry = sql.includes('installer_expires_at IS NULL OR installer_expires_at > NOW()');
    if (filtersExpiry && m.installer_expires_at && new Date(m.installer_expires_at).getTime() <= now().getTime()) return [];
    return [{
      role: m.role, valid_from: m.valid_from || null, valid_until: m.valid_until || null,
      installer_expires_at: m.installer_expires_at || null,
    }];
  });
  db.on('SELECT user_id FROM home_users WHERE home_id = $1 AND role', ({ params }) => {
    const owners = state.home_users.filter((m) => m.home_id === params[0] && m.role === 'owner');
    return owners.map((m) => ({ user_id: m.user_id }));
  });
  db.on('SELECT user_id FROM home_users WHERE home_id = $1', ({ params }) =>
    state.home_users.filter((m) => m.home_id === params[0]).map((m) => ({ user_id: m.user_id }))
  );
  db.on('DELETE FROM home_users WHERE home_id = $1', (ctx) => {
    const removed = removeRows(ctx, state.home_users, (m) => m.home_id === ctx.params[0]);
    return { rows: [], rowCount: removed.length };
  });

  // ------------------------------------------------------------------ devices
  db.on('FROM devices WHERE device_uuid = $1 FOR UPDATE', async (ctx) => {
    const dev = state.devices.find((d) => d.device_uuid === ctx.params[0]);
    if (!dev) return [];
    await ctx.lock(`dev:${dev.id}`);
    return [copy(dev)];
  });
  db.on('FROM devices WHERE mac_address = $1 AND device_uuid <> $2 FOR UPDATE', ({ params }) =>
    copies(state.devices.filter((d) => d.mac_address === params[0] && d.device_uuid !== params[1]))
  );
  db.on("UPDATE devices SET mac_address = left(mac_address, 17)", (ctx) => {
    const dev = state.devices.find((d) => d.id === ctx.params[0]);
    patch(ctx, dev, { mac_address: `${dev.mac_address.slice(0, 17)}-DUP-${dev.id.slice(0, 8)}` });
    return { rows: [], rowCount: 1 };
  });
  db.on('INSERT INTO devices (home_id, device_uuid, mac_address, is_claimed', (ctx) => {
    // claim: [home, uuid, mac, owner, model, enc]   |   pano degisimi: [home, uuid, mac, owner, model, snapshot, enc]
    const hasSnapshot = ctx.sql.includes('config_snapshot');
    const [homeId, uuid, mac, owner, model] = ctx.params;
    const snapshot = hasSnapshot ? ctx.params[5] : undefined;
    const enc = hasSnapshot ? ctx.params[6] : ctx.params[5];
    let dev = state.devices.find((d) => d.device_uuid === uuid);
    const fields = {
      home_id: homeId, mac_address: mac, is_claimed: true, claimed_at: now(), claimed_by: owner, model,
      is_online: false, is_commissioned: false, commissioned_at: null, commissioned_by: null,
      commissioning_status: 'PENDING_INSTALLATION', commissioning_notes: null, device_status: 'ACTIVE',
      local_key_enc: enc, setup_pin: null,
    };
    if (hasSnapshot) fields.config_snapshot = snapshot;
    if (dev) {
      patch(ctx, dev, fields);
    } else {
      dev = insert(ctx, state.devices, { id: uid(), device_uuid: uuid, created_at: now(), ...fields });
    }
    return [{ id: dev.id, home_id: dev.home_id, device_uuid: dev.device_uuid, model: dev.model }];
  });
  db.on('FROM devices WHERE device_uuid = $1 AND home_id = $2 FOR UPDATE', async (ctx) => {
    const dev = state.devices.find((d) => d.device_uuid === ctx.params[0] && d.home_id === ctx.params[1]);
    if (!dev) return [];
    await ctx.lock(`dev:${dev.id}`);
    return [copy(dev)];
  });
  db.on('FROM devices WHERE home_id = $1 ORDER BY created_at ASC FOR UPDATE', async (ctx) => {
    const devs = state.devices.filter((d) => d.home_id === ctx.params[0]).sort((a, b) => a.created_at - b.created_at);
    for (const d of devs) await ctx.lock(`dev:${d.id}`);
    return copies(devs);
  });
  db.on('UPDATE devices SET home_id = $1, is_claimed = TRUE, claimed_by = $2', (ctx) => {
    // acil sifirlama (yeni sahip): [home, newOwner, enc, devId]
    const [homeId, owner, enc, id] = ctx.params;
    const dev = state.devices.find((d) => d.id === id);
    patch(ctx, dev, {
      home_id: homeId, is_claimed: true, claimed_by: owner, claimed_at: now(), is_online: false, is_commissioned: false,
      commissioning_status: 'PENDING_INSTALLATION', device_status: 'ACTIVE', local_key_enc: enc, setup_pin: null,
      child_lock_enabled: false,
    });
    return { rows: [], rowCount: 1 };
  });
  db.on('UPDATE devices SET home_id = NULL, is_claimed = FALSE, claimed_by = NULL, claimed_at = NULL', (ctx) => {
    // acil sifirlama (stoga don): [enc, devId]
    const [enc, id] = ctx.params;
    const dev = state.devices.find((d) => d.id === id);
    patch(ctx, dev, {
      home_id: null, is_claimed: false, claimed_by: null, claimed_at: null, is_online: false, is_commissioned: false,
      commissioning_status: 'PENDING_INSTALLATION', device_status: 'ACTIVE', local_key_enc: enc, setup_pin: null,
      child_lock_enabled: false,
    });
    return { rows: [], rowCount: 1 };
  });
  db.on("UPDATE devices SET home_id = NULL, is_claimed = FALSE, claimed_by = NULL, is_online = FALSE, device_status = 'REPLACED_DAMAGED'", (ctx) => {
    const dev = state.devices.find((d) => d.id === ctx.params[0]);
    patch(ctx, dev, { home_id: null, is_claimed: false, claimed_by: null, is_online: false, device_status: 'REPLACED_DAMAGED' });
    return { rows: [], rowCount: 1 };
  });

  // ------------------------------------------------------------------ endpoints
  db.on('DELETE FROM endpoints WHERE device_id = $1 AND home_id <> $2', (ctx) => {
    const removed = removeRows(ctx, state.endpoints, (e) => e.device_id === ctx.params[0] && e.home_id !== ctx.params[1]);
    return { rows: [], rowCount: removed.length };
  });
  db.on('DELETE FROM endpoints WHERE device_id = $1', (ctx) => {
    const removed = removeRows(ctx, state.endpoints, (e) => e.device_id === ctx.params[0]);
    return { rows: [], rowCount: removed.length };
  });
  db.on('INSERT INTO endpoints (home_id, device_id, channel_index', (ctx) => {
    const [homeId, deviceId, count] = ctx.params;
    let n = 0;
    for (const row of defaultEndpointRows(homeId, deviceId, count)) {
      // ON CONFLICT (device_id, channel_index) DO NOTHING
      if (state.endpoints.some((e) => e.device_id === deviceId && e.channel_index === row.channel_index)) continue;
      insert(ctx, state.endpoints, row);
      n += 1;
    }
    return { rows: [], rowCount: n };
  });
  db.on('FROM endpoints WHERE home_id = $1 AND device_id = $2 ORDER BY channel_index ASC', ({ params }) =>
    copies(state.endpoints.filter((e) => e.home_id === params[0] && e.device_id === params[1]).sort((a, b) => a.channel_index - b.channel_index))
  );
  db.on('UPDATE endpoints SET device_id = $1', (ctx) => {
    const [newId, oldId, homeId] = ctx.params;
    const rows = state.endpoints.filter((e) => e.device_id === oldId && e.home_id === homeId);
    // UNIQUE(device_id, channel_index) ihlali: gercek PostgreSQL'de hata verir
    for (const r of rows) {
      if (state.endpoints.some((e) => e.device_id === newId && e.channel_index === r.channel_index)) {
        throw Object.assign(new Error('duplicate key value violates unique constraint "endpoints_device_id_channel_index_key"'), { code: '23505' });
      }
    }
    for (const r of rows) patch(ctx, r, { device_id: newId });
    return { rows: [], rowCount: rows.length };
  });

  // ------------------------------------------------------------------ mqtt_credentials / mqtt_acl (gercek servis SQL'i)
  const deleteCreds = (ctx, pred) => {
    const removed = removeRows(ctx, state.mqtt_credentials, pred);
    for (const c of removed) removeRows(ctx, state.mqtt_acl, (a) => a.credential_id === c.id);
    return removed.map((c) => ({ username: c.username }));
  };
  db.on("DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind IN ('app', 'device')", (ctx) =>
    deleteCreds(ctx, (c) => c.home_id === ctx.params[0])
  );
  db.on("DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device' AND device_id = $2", (ctx) =>
    deleteCreds(ctx, (c) => c.home_id === ctx.params[0] && c.kind === 'device' && c.device_id === ctx.params[1])
  );
  db.on("DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind = 'device'", (ctx) =>
    deleteCreds(ctx, (c) => c.home_id === ctx.params[0] && c.kind === 'device')
  );
  db.on("DELETE FROM mqtt_credentials WHERE home_id = $1 AND user_id = $2 AND kind = 'app'", (ctx) =>
    deleteCreds(ctx, (c) => c.home_id === ctx.params[0] && c.user_id === ctx.params[1] && c.kind === 'app')
  );
  db.on("DELETE FROM mqtt_credentials WHERE home_id = $1 AND kind = 'app'", (ctx) =>
    deleteCreds(ctx, (c) => c.home_id === ctx.params[0] && c.kind === 'app')
  );
  db.on('DELETE FROM mqtt_credentials WHERE id IN (', (ctx) => {
    // en yeni (offset) tanesini koru, fazlasini sil: [homeId, userId, offset]
    const [homeId, userId, offset] = ctx.params;
    const mine = state.mqtt_credentials
      .filter((c) => c.home_id === homeId && c.kind === 'app' && (c.user_id || null) === (userId || null))
      .sort((a, b) => b.created_at - a.created_at);
    const excess = mine.slice(offset);
    return deleteCreds(ctx, (c) => excess.includes(c));
  });
  db.on('expires_at <= NOW()', (ctx) =>
    deleteCreds(ctx, (c) => c.kind === 'app' && c.expires_at && new Date(c.expires_at).getTime() <= now().getTime())
  );
  db.on('INSERT INTO mqtt_credentials', (ctx) => {
    const isDevice = ctx.sql.includes("'device'");
    const row = isDevice
      ? { username: ctx.params[0], password_hash: ctx.params[1], kind: 'device', home_id: ctx.params[2], device_id: ctx.params[3], user_id: null, client_id: ctx.params[4], expires_at: null }
      : { username: ctx.params[0], password_hash: ctx.params[1], kind: 'app', home_id: ctx.params[2], device_id: null, user_id: ctx.params[3], client_id: ctx.params[4], expires_at: ctx.params[5] };
    if (state.mqtt_credentials.some((c) => c.username === row.username)) {
      throw Object.assign(new Error('duplicate username'), { code: '23505' });
    }
    insert(ctx, state.mqtt_credentials, { id: uid(), is_superuser: false, created_at: new Date(now().getTime() + state.mqtt_credentials.length), ...row });
    return [{ id: state.mqtt_credentials[state.mqtt_credentials.length - 1].id }];
  });
  db.on('INSERT INTO mqtt_acl', (ctx) => {
    const [credentialId, username, ...topics] = ctx.params;
    const actions = topics.length === 4 ? ['publish', 'publish', 'subscribe', 'subscribe'] : ['subscribe', 'subscribe'];
    topics.forEach((topic, i) => {
      insert(ctx, state.mqtt_acl, { credential_id: credentialId, username, permission: 'allow', action: actions[i], topic });
    });
    return { rows: [], rowCount: topics.length };
  });

  // ------------------------------------------------------------------ gunlukler
  db.on('INSERT INTO device_audit_logs', (ctx) => {
    const [event, deviceUuid, homeId, actorUserId, actorRole, ip, details] = ctx.params;
    insert(ctx, state.device_audit_logs, {
      event, device_uuid: deviceUuid, home_id: homeId, actor_user_id: actorUserId, actor_role: actorRole,
      ip_address: ip, details: details ? JSON.parse(details) : null,
    });
    return { rows: [], rowCount: 1 };
  });
  db.on('INSERT INTO emergency_reset_logs', (ctx) => {
    const [deviceUuid, homeId, userId, reason, newOwner, prev, ip, role, action] = ctx.params;
    insert(ctx, state.emergency_reset_logs, {
      device_uuid: deviceUuid, home_id: homeId, installer_user_id: userId, reason, new_owner_identifier: newOwner,
      previous_owner_ids: JSON.parse(prev), ip_address: ip, actor_role: role, action,
    });
    return { rows: [], rowCount: 1 };
  });
  db.on('INSERT INTO device_replacement_logs', (ctx) => {
    const [homeId, oldUuid, newUuid, userId, label, sessionId, ip, migrated, snapshot, reason] = ctx.params;
    insert(ctx, state.device_replacement_logs, {
      home_id: homeId, old_device_uuid: oldUuid, new_device_uuid: newUuid, replaced_by_user_id: userId,
      replaced_by_label: label, service_session_id: sessionId, ip_address: ip, endpoints_migrated_count: migrated,
      config_snapshot: JSON.parse(snapshot), reason,
    });
    return { rows: [], rowCount: 1 };
  });

  // ------------------------------------------------------------------ komut hatti / ev / cihaz listesi / endpoint
  const homeOf = (id) => state.homes.find((h) => h.id === id);
  db.on('FROM devices d JOIN homes h ON h.id = d.home_id WHERE d.home_id = $1 AND ((d.id::text = $2)', ({ params }) => {
    const [homeId, id, uuid] = params;
    const dev = state.devices.find((d) => d.home_id === homeId && ((id && d.id === id) || (uuid && d.device_uuid === uuid)));
    if (!dev) return [];
    return [{ id: dev.id, device_uuid: dev.device_uuid, is_online: dev.is_online === true, topic_id: homeOf(dev.home_id).mqtt_username }];
  });
  db.on('SELECT type FROM endpoints WHERE device_id = $1 AND channel_index = $2', ({ params }) =>
    state.endpoints.filter((e) => e.device_id === params[0] && e.channel_index === params[1]).map((e) => ({ type: e.type }))
  );
  db.on('SELECT d.id, COALESCE(d.is_online, FALSE) AS is_online FROM devices d WHERE d.home_id = $1', ({ params }) =>
    state.devices.filter((d) => d.home_id === params[0]).map((d) => ({ id: d.id, is_online: d.is_online === true }))
  );
  // Cocuk kilidi (B12): REST DURUM yazmaz; yalnizca NIYET (homes.child_lock_requested*) yazilir.
  db.on('UPDATE homes SET child_lock_requested', (ctx) => {
    // kilit rotasi: [homeId, enabled, userId]  |  pano degisimi (tasima): [homeId, userId] ('child_lock_requested = TRUE')
    const carried = ctx.sql.includes('child_lock_requested = TRUE');
    const homeId = ctx.params[0];
    const home = homeOf(homeId);
    if (!home) return { rows: [], rowCount: 0 };
    patch(ctx, home, {
      child_lock_requested: carried ? true : ctx.params[1],
      child_lock_requested_at: now(),
      child_lock_requested_by: carried ? ctx.params[1] : ctx.params[2],
    });
    return { rows: [], rowCount: 1 };
  });
  db.on('d.child_lock_enabled FROM devices d WHERE d.home_id = $1 ORDER BY d.created_at ASC', ({ params }) =>
    copies(state.devices.filter((d) => d.home_id === params[0]).sort((a, b) => a.created_at - b.created_at)).map((d) => ({
      id: d.id, device_uuid: d.device_uuid, is_online: d.is_online === true,
      online: d.is_online === true, child_lock_enabled: d.child_lock_enabled === undefined ? null : d.child_lock_enabled,
    }))
  );
  db.on("FROM endpoints e WHERE e.home_id = $1 AND e.type = 'light' AND e.current_state = TRUE", ({ params }) =>
    copies(state.endpoints.filter((e) => e.home_id === params[0] && e.type === 'light' && e.current_state === true).sort((a, b) => a.channel_index - b.channel_index))
  );
  db.on("FROM endpoints e WHERE e.home_id = $1 AND e.type = 'shutter' AND e.shutter_pair_index IS NOT NULL", ({ params }) =>
    copies(
      state.endpoints.filter(
        (e) => e.home_id === params[0] && e.type === 'shutter' && e.shutter_pair_index !== null && e.channel_index % 2 === 1 && e.current_position > 0
      )
    )
  );
  // --- Gece huzur v2 (WP-H): DeviceService peace_service.js'e devreder; canli anlik goruntu peace_snapshot.js'tedir.
  //     Gercek SQL metinleri GERCEK PostgreSQL'e karsi test/peace/peace_service_pg.test.js'te calisir; burada JS ile taklit edilir.
  db.on('SELECT id, name, peace_notification_enabled, peace_notification_time, timezone FROM homes WHERE id = $1', ({ params }) =>
    copies(state.homes.filter((h) => h.id === params[0]))
  );
  db.on('SELECT d.id AS device_id, COALESCE(d.is_online IS TRUE AND d.last_seen_at', ({ params }) => {
    const [homeId, liveSec, minPos] = params;
    const rows = [];
    for (const d of state.devices.filter((x) => x.home_id === homeId)) {
      // sahte dunyada last_seen_at izlenmeyebilir: yoksa cevrimici cihaz canli sayilir
      const seenMs = d.last_seen_at ? new Date(d.last_seen_at).getTime() : null;
      const fresh = seenMs === null ? true : now().getTime() - seenMs <= liveSec * 1000;
      const base = { device_id: d.id, live: d.is_online === true && fresh };
      const open = state.endpoints.filter(
        (e) => e.device_id === d.id && ((e.type === 'light' && e.current_state === true) || (e.type === 'shutter' && e.current_position >= minPos))
      );
      if (open.length === 0) {
        rows.push({ ...base, endpoint_id: null, type: null, channel_index: null, pair: null, name: null, room: null, current_state: null, current_position: null });
      }
      for (const e of open) {
        rows.push({
          ...base,
          endpoint_id: e.id,
          type: e.type,
          channel_index: e.channel_index,
          pair: e.shutter_pair_index === null || e.shutter_pair_index === undefined ? Math.floor((e.channel_index + 1) / 2) : e.shutter_pair_index,
          name: e.name,
          room: e.room || 'Genel',
          current_state: e.current_state,
          current_position: e.current_position,
        });
      }
    }
    return rows;
  });
  db.on("SELECT EXISTS (SELECT 1 FROM endpoints WHERE home_id = $1 AND type = 'plug') AS has_plug", ({ params }) => [
    { has_plug: state.endpoints.some((e) => e.home_id === params[0] && e.type === 'plug') },
  ]);
  db.on('SELECT device_id, type, channel_index, shutter_pair_index, current_position FROM endpoints WHERE home_id = $1', ({ params }) =>
    copies(state.endpoints.filter((e) => e.home_id === params[0]))
  );
  db.on("SELECT id, to_char(local_date, 'YYYY-MM-DD') AS local_date, status, summary_text", ({ params }) =>
    copies(
      state.peace_notification_logs
        .filter((r) => r.home_id === params[0] && r.local_date && ['sent', 'no_recipients', 'resolved'].includes(r.status))
        .sort((a, b) => (a.local_date < b.local_date ? 1 : -1))
        .slice(0, 1)
    )
  );
  db.on("UPDATE peace_notification_logs SET status = 'resolved'", (ctx) => {
    const [actorId, commandId, noticeId, homeId] = ctx.params;
    const resolvable = (r) => r.home_id === homeId && !r.resolved_at && ['sent', 'no_recipients', 'sending'].includes(r.status);
    const row =
      noticeId !== null && noticeId !== undefined
        ? state.peace_notification_logs.find((r) => r.id === noticeId && resolvable(r))
        : state.peace_notification_logs.filter((r) => r.local_date && resolvable(r)).sort((a, b) => (a.local_date < b.local_date ? 1 : -1))[0];
    if (!row) return { rows: [], rowCount: 0 };
    patch(ctx, row, { status: 'resolved', resolved_by_user: true, resolved_at: now(), resolved_by_user_id: actorId, resolved_via: 'close_all', command_id: commandId });
    return { rows: [{ id: row.id }], rowCount: 1 };
  });
  db.on('INSERT INTO peace_notification_logs', (ctx) => {
    const [homeId, lights, shutters, summary, actorId, commandId] = ctx.params;
    insert(ctx, state.peace_notification_logs, {
      id: state.peace_notification_logs.length + 1,
      home_id: homeId,
      local_date: null,
      status: 'manual',
      open_lights_count: lights,
      open_shutters_count: shutters,
      summary_text: summary,
      resolved_by_user: true,
      resolved_by_user_id: actorId,
      resolved_via: 'close_all',
      command_id: commandId,
      resolved_at: now(),
    });
    return { rows: [], rowCount: 1 };
  });
  db.on('UPDATE homes SET peace_notification_enabled = COALESCE($1, peace_notification_enabled)', (ctx) => {
    const [enabled, time, id] = ctx.params;
    const home = homeOf(id);
    if (!home) return [];
    patch(ctx, home, {
      peace_notification_enabled: enabled === null ? home.peace_notification_enabled : enabled,
      peace_notification_time: time === null ? home.peace_notification_time : time,
    });
    return [{ id: home.id, peace_notification_enabled: home.peace_notification_enabled, peace_notification_time: home.peace_notification_time }];
  });
  db.on('FROM homes WHERE id = $1', ({ params }) => copies(state.homes.filter((h) => h.id === params[0])));
  db.on('SELECT 1', () => [{ '?column?': 1 }]);
  db.on('SELECT count(*) AS count FROM endpoints WHERE home_id = $1', ({ params }) => [
    { count: String(state.endpoints.filter((e) => e.home_id === params[0]).length) },
  ]);
  db.on('FROM devices d WHERE d.home_id = $1 ORDER BY d.last_seen_at DESC NULLS LAST', ({ params }) =>
    copies(
      state.devices
        .filter((d) => d.home_id === params[0])
        .sort((a, b) => (b.last_seen_at ? new Date(b.last_seen_at).getTime() : -1) - (a.last_seen_at ? new Date(a.last_seen_at).getTime() : -1))
    )
  );
  db.on("COALESCE(NULLIF(d.name, ''), d.model, d.device_uuid) AS name", ({ params }) =>
    copies(state.devices.filter((d) => d.home_id === params[0]).sort((a, b) => a.created_at - b.created_at)).map((d) => ({
      id: d.id, device_uuid: d.device_uuid, name: d.name || d.model || d.device_uuid, model: d.model, online: d.is_online === true,
      last_seen_at: d.last_seen_at || null, firmware: d.firmware_version || null, ip_address: d.ip_address || null,
    }))
  );
  db.on('SELECT device_uuid, local_key_enc FROM devices WHERE home_id = $1 AND device_uuid = $2', ({ params }) =>
    copies(state.devices.filter((d) => d.home_id === params[0] && d.device_uuid === params[1]))
  );
  db.on('SELECT id FROM devices WHERE home_id = $1 AND device_uuid = $2 FOR UPDATE', async (ctx) => {
    const dev = state.devices.find((d) => d.home_id === ctx.params[0] && d.device_uuid === ctx.params[1]);
    if (!dev) return [];
    await ctx.lock(`dev:${dev.id}`);
    return [{ id: dev.id }];
  });

  // endpoint servisi
  db.on('FROM endpoints e JOIN devices d ON d.id = e.device_id JOIN homes h ON h.id = e.home_id WHERE e.id = $1 AND e.home_id = $2', ({ params }) => {
    const ep = state.endpoints.find((e) => e.id === params[0] && e.home_id === params[1]);
    if (!ep) return [];
    const dev = state.devices.find((d) => d.id === ep.device_id);
    return [{ id: ep.id, device_id: ep.device_id, type: ep.type, shutter_pair_index: ep.shutter_pair_index, is_online: dev.is_online === true, topic_id: homeOf(ep.home_id).mqtt_username }];
  });
  db.on('SELECT id, device_id, type, channel_index, shutter_pair_index FROM endpoints WHERE id = $1 AND home_id = $2', ({ params }) =>
    copies(state.endpoints.filter((e) => e.id === params[0] && e.home_id === params[1]))
  );
  db.on('UPDATE endpoints SET name = COALESCE($1, name)', (ctx) => {
    const [name, room, type, id, homeId] = ctx.params;
    const ep = state.endpoints.find((e) => e.id === id && e.home_id === homeId);
    if (!ep) return [];
    patch(ctx, ep, { name: name === null ? ep.name : name, room: room === null ? ep.room : room, type: type === null ? ep.type : type });
    return [{ id: ep.id }];
  });
  db.on('UPDATE endpoints SET shutter_duration_sec = $1', (ctx) => {
    const [sec, homeId, deviceId, pair] = ctx.params;
    const rows = state.endpoints.filter((e) => e.home_id === homeId && e.device_id === deviceId && e.shutter_pair_index === pair);
    for (const r of rows) patch(ctx, r, { shutter_duration_sec: sec });
    return { rows: [], rowCount: rows.length };
  });
  db.on('FROM endpoints e LEFT JOIN devices d ON d.id = e.device_id WHERE e.id = $1', ({ params }) =>
    state.endpoints.filter((e) => e.id === params[0]).map((e) => {
      const dev = state.devices.find((d) => d.id === e.device_id);
      return { ...e, device_uuid: dev ? dev.device_uuid : null, device_online: dev ? dev.is_online === true : false };
    })
  );
  db.on('FROM endpoints e LEFT JOIN devices d ON d.id = e.device_id WHERE e.home_id = $1', ({ params }) =>
    state.endpoints
      .filter((e) => e.home_id === params[0])
      .map((e) => {
        const dev = state.devices.find((d) => d.id === e.device_id);
        return { ...e, device_uuid: dev ? dev.device_uuid : null, device_online: dev ? dev.is_online === true : false };
      })
  );

  // devreye alma
  db.on('SELECT id, device_uuid FROM devices WHERE home_id = $1 AND device_uuid = $2 FOR UPDATE', async (ctx) => {
    const dev = state.devices.find((d) => d.home_id === ctx.params[0] && d.device_uuid === ctx.params[1]);
    if (!dev) return [];
    await ctx.lock(`dev:${dev.id}`);
    return [{ id: dev.id, device_uuid: dev.device_uuid }];
  });
  db.on('INSERT INTO commissioning_logs', (ctx) => {
    const [homeId, deviceId, deviceUuid, techId, label, sessionId, passed, notes] = ctx.params;
    const row = insert(ctx, state.commissioning_logs, {
      id: uid(), home_id: homeId, device_id: deviceId, device_uuid: deviceUuid, technician_id: techId, technician_label: label,
      service_session_id: sessionId, tests_passed: passed, notes, created_at: now(),
    });
    return [{ id: row.id, created_at: row.created_at }];
  });
  db.on('INSERT INTO commissioning_checks', (ctx) => {
    const [logId, names, oks, details] = ctx.params;
    names.forEach((n, i) => insert(ctx, state.commissioning_checks, { commissioning_log_id: logId, check_name: n, ok: oks[i], detail: details[i] }));
    return { rows: [], rowCount: names.length };
  });
  db.on('UPDATE devices SET is_commissioned = TRUE', (ctx) => {
    const [by, notes, id] = ctx.params;
    const dev = state.devices.find((d) => d.id === id);
    patch(ctx, dev, { is_commissioned: true, commissioned_at: now(), commissioned_by: by, commissioning_status: 'APPROVED_WORKING', commissioning_notes: notes });
    return [{ commissioned_at: dev.commissioned_at }];
  });
  db.on('UPDATE devices SET is_commissioned = FALSE, commissioned_at = NULL, commissioned_by = NULL, commissioning_status = \'TESTS_FAILED\'', (ctx) => {
    const [notes, id] = ctx.params;
    const dev = state.devices.find((d) => d.id === id);
    patch(ctx, dev, { is_commissioned: false, commissioned_at: null, commissioned_by: null, commissioning_status: 'TESTS_FAILED', commissioning_notes: notes });
    return [{ commissioned_at: null }];
  });
  db.on('FROM devices d LEFT JOIN users u ON u.id = d.commissioned_by WHERE d.home_id = $1', ({ params }) =>
    state.devices
      .filter((d) => d.home_id === params[0])
      .sort((a, b) => a.created_at - b.created_at)
      .map((d) => {
        const u = state.users.find((x) => x.id === d.commissioned_by);
        return {
          device_uuid: d.device_uuid, is_commissioned: d.is_commissioned === true, commissioned_at: d.commissioned_at || null,
          commissioning_status: d.commissioning_status || 'PENDING_INSTALLATION', commissioning_notes: d.commissioning_notes || null,
          technician_name: u ? u.full_name : null,
        };
      })
  );

  // ------------------------------------------------------------------ olusturucular (fixture)
  const helpers = {
    addUser({ email, role = 'user', phone = null, full_name = 'Test Kullanici', is_active = true } = {}) {
      const row = { id: uid(), email: email || `${uid()}@example.test`, phone, role, full_name, is_active, account_status: 'active', password_hash: 'x' };
      state.users.push(row);
      return row;
    },
    addInventory({ uuid = 'AHBU-S3-0001', pin = '123456', model = 'ESP32-S3-POE-ETH-8DI-8RO', status = 'IN_STOCK', mac, local_key_enc = null } = {}) {
      const row = {
        id: uid(), device_uuid: uuid, mac_address: mac || `E8:F6:0A:${String(Math.floor(Math.random() * 90) + 10)}:${String(Math.floor(Math.random() * 90) + 10)}:${String(Math.floor(Math.random() * 90) + 10)}`,
        pin_hash: fakePin.hashPin(pin), model, status, failed_attempts: 0, locked_until: null, claimed_home_id: null,
        claimed_by_user_id: null, local_key_enc,
      };
      state.device_inventory.push(row);
      return row;
    },
    addHome({ name = 'Ev', owner = null, topic } = {}) {
      const row = {
        id: uid(), name, mqtt_username: topic || `h_${crypto.randomBytes(8).toString('hex')}`, seq: ++homeSeq,
        child_lock_enabled: false, peace_notification_enabled: true, peace_notification_time: '23:30',
      };
      state.homes.push(row);
      if (owner) state.home_users.push({ home_id: row.id, user_id: owner.id, role: 'owner', installer_expires_at: null });
      return row;
    },
    addMember(home, user, role, extra = {}) {
      const row = { home_id: home.id, user_id: user.id, role, installer_expires_at: null, ...extra };
      state.home_users.push(row);
      return row;
    },
    addDevice({ home = null, uuid = 'AHBU-S3-0001', mac = 'E8:F6:0A:00:00:01', claimedBy = null, online = false, model = 'ESP32-S3-POE-ETH-8DI-8RO', local_key_enc = null } = {}) {
      const row = {
        id: uid(), device_uuid: uuid, home_id: home ? home.id : null, mac_address: mac, is_claimed: Boolean(home),
        claimed_by: claimedBy ? claimedBy.id : null, is_online: online, model, local_key_enc, setup_pin: null,
        created_at: new Date(now().getTime() + state.devices.length),
      };
      state.devices.push(row);
      return row;
    },
    addEndpoints(home, device, count = 8) {
      const rows = defaultEndpointRows(home.id, device.id, count);
      state.endpoints.push(...rows);
      return rows;
    },
  };

  return { state, db, clock, helpers };
}

/** Standart test dugumu: gercek servisler + sahte bagimliliklar birlestirilir. */
function createServices(world, overrides = {}) {
  const { MqttCredentialService } = require('../../src/services/mqtt_credential_service');
  const { DeviceService } = require('../../src/services/device_service');
  const secretBox = require('../../src/utils/secret_box');

  const timeline = [];
  const bridge = createFakeBridge(timeline);
  const mailer = createFakeMailer();
  const fetchFn = createFakeFetch(timeline);
  const cleanupCalls = [];

  const credentials = new MqttCredentialService({
    db: world.db,
    env: process.env,
    fetch: fetchFn,
    logger: silentLogger,
    now: () => world.clock.now(),
  });

  const deviceService = new DeviceService({
    db: world.db,
    mqttBridge: bridge,
    mqttCredentials: credentials,
    pin: fakePin,
    secretBox,
    mailer,
    now: () => world.clock.now(),
    env: process.env,
    inviteCustomer: async (args) => {
      deviceService.invites.push(args);
      return { sent: true };
    },
    cleanupHome: async (tx, homeId, options) => {
      cleanupCalls.push({ homeId, options, inTx: Boolean(tx && tx.query) });
      return { cleaned: {}, skipped: [] };
    },
    ...overrides,
  });
  deviceService.invites = [];

  return { deviceService, credentials, bridge, mailer, fetchFn, timeline, cleanupCalls, secretBox };
}

/** Servis hatasi beklentisi: HttpError durum + kod (+ ek alanlar) dogrulanir, hata nesnesi doner. */
async function expectHttp(promise, status, code, extra = null) {
  let caught = null;
  try {
    await promise;
  } catch (err) {
    caught = err;
  }
  const assert = require('node:assert');
  assert.ok(caught, `HTTP ${status} ${code} hatasi bekleniyordu ama islem basarili oldu`);
  assert.strictEqual(caught.status, status, `durum: ${caught.status} (${caught.message})`);
  if (code) assert.strictEqual(caught.code, code, `kod: ${caught.code} (${caught.message})`);
  if (extra) {
    for (const [k, v] of Object.entries(extra)) assert.strictEqual(caught.extra && caught.extra[k], v, `extra.${k}`);
  }
  return caught;
}

module.exports = {
  expectHttp,
  createWorld,
  createServices,
  createClock,
  setTestEnv,
  fakePin,
  createFakeMailer,
  createFakeBridge,
  createFakeFetch,
  silentLogger,
  defaultEndpointRows,
  uid,
};
