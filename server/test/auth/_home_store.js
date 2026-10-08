'use strict';

// Ev tarafi tablolar icin bellek ici sahte depo: users, homes, home_users, service_tokens,
// service_sessions, home_invitations, home_transfers (+ devices/device_inventory guncelleme kaydi).
// service_token_service, invitation_service, transfer_service ve auth_middleware SQL'lerini
// sirali regex eslemesiyle davranissal olarak taklit eder.

const crypto = require('crypto');

function createHomeStore({ now = () => Date.now() } = {}) {
  const s = {
    now,
    users: new Map(),
    homes: new Map(),
    members: [], // { home_id, user_id, role, valid_from, valid_until, installer_expires_at, created_at }
    tokens: [], // service_tokens
    sessions: [], // service_sessions
    invitations: [],
    transfers: [],
    deviceUpdates: [],
    mqttCreds: [], // { username, kind, home_id, user_id } (uyelik-6: servis oturumu kimlikleri user_id bos)
    audits: [], // device_audit_logs (ev_uyelik-6: invitation_revoked)
    devices: [], // pano-6: { id, home_id, device_uuid, local_key_pending_enc } (yerel anahtar rotasyonu)
    unmatched: [],
  };
  const NOW = () => new Date(s.now());
  const alive = (d) => d && new Date(d).getTime() > s.now();
  // pano-6: anahtari okumus ve bitmis (iptal / suresi dolmus), rotasyonu yapilmamis servis oturumu
  const endedRead = (x) => x.local_key_read_at && !x.key_rotated_at && (x.revoked_at || !alive(x.expires_at));

  s.addUser = (fields = {}) => {
    const u = {
      id: crypto.randomUUID(), email: `k${s.users.size + 1}@test.invalid`, full_name: 'Kisi', phone: null,
      role: 'user', is_active: true, account_status: 'active', token_version: 1, ...fields,
    };
    s.users.set(u.id, u);
    return u;
  };
  s.addHome = (fields = {}) => {
    const h = { id: crypto.randomUUID(), name: 'Ev', address: null, mqtt_username: `h_${crypto.randomBytes(8).toString('hex')}`, ...fields };
    s.homes.set(h.id, h);
    return h;
  };
  s.addMember = (home, user, role, extra = {}) => {
    s.members.push({ home_id: home.id || home, user_id: user.id || user, role, valid_from: null, valid_until: null, installer_expires_at: null, created_at: NOW(), ...extra });
  };
  s.member = (homeId, userId) => s.members.find((m) => m.home_id === homeId && m.user_id === userId);
  s.addDevice = (home, fields = {}) => {
    const d = {
      id: crypto.randomUUID(), home_id: home.id || home, device_uuid: `AHBU-S3-${crypto.randomBytes(3).toString('hex').toUpperCase()}`,
      local_key_pending_enc: null, local_key_pending_at: null, ...fields,
    };
    s.devices.push(d);
    return d;
  };
  s.addMqttCred = (fields = {}) => {
    const c = { username: `a_t_${crypto.randomBytes(6).toString('hex')}`, kind: 'app', home_id: null, user_id: null, ...fields };
    s.mqttCreds.push(c);
    return c;
  };

  const rules = [
    // ---------------- auth_middleware ----------------
    [/FROM service_sessions\s+WHERE id = \$1/, (p) => s.sessions.filter((x) => x.id === p[0]).map((x) => ({ ...x }))],
    [/SELECT id, email, full_name, role, is_active, account_status, token_version\s+FROM users\s+WHERE id = \$1/, (p) =>
      (s.users.has(p[0]) ? [{ ...s.users.get(p[0]) }] : [])],
    [/SELECT role, valid_from, valid_until, installer_expires_at\s+FROM home_users\s+WHERE home_id = \$1 AND user_id = \$2/, (p) =>
      s.members.filter((m) => m.home_id === p[0] && m.user_id === p[1]).map((m) => ({ ...m }))],
    [/SELECT id FROM homes WHERE id = \$1/, (p) => (s.homes.has(p[0]) ? [{ id: p[0] }] : [])],

    // ---------------- service_tokens ----------------
    [/UPDATE service_tokens SET revoked_at = NOW\(\)\s+WHERE revoked_at IS NULL AND used_at IS NULL AND expires_at <= NOW\(\)/, () => {
      s.tokens.filter((t) => !t.revoked_at && !t.used_at && !alive(t.expires_at)).forEach((t) => { t.revoked_at = NOW(); });
      return [];
    }],
    [/UPDATE service_tokens SET revoked_at = NOW\(\)\s+WHERE home_id = \$1 AND revoked_at IS NULL AND used_at IS NULL/, (p) => {
      const hit = s.tokens.filter((t) => t.home_id === p[0] && !t.revoked_at && !t.used_at);
      hit.forEach((t) => { t.revoked_at = NOW(); });
      return hit.map((t) => ({ id: t.id }));
    }],
    [/SELECT 1 FROM service_tokens\s+WHERE pin_hash = \$1/, (p) =>
      s.tokens.filter((t) => t.pin_hash === p[0] && !t.used_at && !t.revoked_at && alive(t.expires_at)).map(() => ({ '?column?': 1 }))],
    [/INSERT INTO service_tokens/, (p) => {
      const t = { id: crypto.randomUUID(), home_id: p[0], created_by: p[1], pin_hash: p[2], expires_at: new Date(s.now() + Number(p[3]) * 1000), used_at: null, revoked_at: null, is_used: false, created_at: NOW() };
      s.tokens.push(t);
      return [{ id: t.id, expires_at: t.expires_at }];
    }],
    [/UPDATE service_tokens\s+SET used_at = NOW\(\), is_used = TRUE/, (p) => {
      const t = s.tokens.find((x) => x.pin_hash === p[0] && !x.used_at && !x.revoked_at && alive(x.expires_at));
      if (!t) return [];
      t.used_at = NOW();
      t.is_used = true;
      return [{ id: t.id, home_id: t.home_id }];
    }],
    [/FROM service_tokens st/, (p) => s.tokens.filter((t) => t.home_id === p[0]).map((t) => ({ ...t, created_by_name: 'Sahip' }))],

    // ---------------- service_sessions ----------------
    [/INSERT INTO service_sessions/, (p) => {
      const x = { id: crypto.randomUUID(), home_id: p[0], service_token_id: p[1], technician_name: p[2], created_ip: p[3], created_at: NOW(), expires_at: new Date(s.now() + Number(p[4]) * 1000), revoked_at: null, revoked_reason: null };
      s.sessions.push(x);
      return [{ id: x.id, home_id: x.home_id, expires_at: x.expires_at }];
    }],
    [/UPDATE service_sessions SET revoked_at = NOW\(\), revoked_reason = \$2\s+WHERE home_id = \$1/, (p) => {
      const hit = s.sessions.filter((x) => x.home_id === p[0] && !x.revoked_at);
      hit.forEach((x) => { x.revoked_at = NOW(); x.revoked_reason = p[1]; });
      return hit.map((x) => ({ id: x.id }));
    }],
    [/FROM service_sessions\s+WHERE home_id = \$1 AND revoked_at IS NULL AND expires_at > NOW\(\)/, (p) =>
      s.sessions.filter((x) => x.home_id === p[0] && !x.revoked_at && alive(x.expires_at))],
    // uyelik-12: servis oturumunun kendi cikisi
    [/UPDATE service_sessions SET revoked_at = NOW\(\), revoked_reason = 'self_logout'\s+WHERE id = \$1 AND revoked_at IS NULL\s+RETURNING home_id/, (p) => {
      const x = s.sessions.find((r) => r.id === p[0] && !r.revoked_at);
      if (!x) return [];
      x.revoked_at = NOW();
      x.revoked_reason = 'self_logout';
      return [{ home_id: x.home_id }];
    }],

    // ---------------- pano-6: yerel anahtar rotasyonu + biten servis oturumu supurmesi ----------------
    [/SELECT id, device_uuid, local_key_pending_enc FROM devices WHERE home_id = \$1 ORDER BY id FOR UPDATE/, (p) =>
      s.devices
        .filter((d) => d.home_id === p[0])
        .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
        .map((d) => ({ id: d.id, device_uuid: d.device_uuid, local_key_pending_enc: d.local_key_pending_enc || null }))],
    [/UPDATE devices SET local_key_pending_enc = \$2, local_key_pending_at = NOW\(\) WHERE id = \$1 AND local_key_pending_enc IS NULL/, (p) => {
      const d = s.devices.find((x) => x.id === p[0] && !x.local_key_pending_enc);
      if (!d) return { rows: [], rowCount: 0 };
      d.local_key_pending_enc = p[1];
      d.local_key_pending_at = NOW();
      return { rows: [], rowCount: 1 };
    }],
    [/SELECT mqtt_username FROM homes WHERE id = \$1/, (p) => (s.homes.has(p[0]) ? [{ mqtt_username: s.homes.get(p[0]).mqtt_username }] : [])],
    [/SELECT DISTINCT home_id FROM service_sessions WHERE local_key_read_at IS NOT NULL AND key_rotated_at IS NULL AND \(revoked_at IS NOT NULL OR expires_at <= NOW\(\)\)/, (p, text) => {
      const scoped = /AND home_id = \$1\s*$/.test(text);
      const ids = [...new Set(s.sessions.filter((x) => endedRead(x) && (!scoped || x.home_id === p[0])).map((x) => x.home_id))];
      return ids.map((home_id) => ({ home_id }));
    }],
    [/UPDATE service_sessions SET key_rotated_at = NOW\(\) WHERE home_id = \$1 AND local_key_read_at IS NOT NULL/, (p) => {
      const hit = s.sessions.filter((x) => x.home_id === p[0] && endedRead(x));
      hit.forEach((x) => { x.key_rotated_at = NOW(); });
      return { rows: [], rowCount: hit.length };
    }],

    // ---------------- mqtt_credentials (uyelik-6: servis oturumu kimlikleri) ----------------
    [/DELETE FROM mqtt_credentials WHERE home_id = \$1 AND kind = 'app' AND user_id IS NULL RETURNING username/, (p) => {
      const hit = s.mqttCreds.filter((c) => c.home_id === p[0] && c.kind === 'app' && c.user_id === null);
      s.mqttCreds = s.mqttCreds.filter((c) => !hit.includes(c));
      return hit.map((c) => ({ username: c.username }));
    }],

    // ---------------- homes ----------------
    [/SELECT h\.id, h\.name, h\.mqtt_username,[\s\S]*FROM homes h\s+WHERE h\.id = \$1/, (p) => {
      const h = s.homes.get(p[0]);
      return h ? [{ ...h, timezone: 'Europe/Istanbul' }] : [];
    }],
    [/SELECT id, name FROM homes WHERE id = \$1/, (p) => {
      const h = s.homes.get(p[0]);
      return h ? [{ id: h.id, name: h.name }] : [];
    }],

    // ---------------- home_invitations ----------------
    [/SELECT COUNT\(\*\)::int AS n FROM home_invitations/, (p) =>
      [{ n: s.invitations.filter((i) => i.home_id === p[0] && !i.is_used && alive(i.expires_at)).length }]],
    [/INSERT INTO home_invitations/, (p) => {
      if (s.invitations.some((i) => i.code_hash === p[2])) { const e = new Error('dup'); e.code = '23505'; throw e; }
      const i = { id: crypto.randomUUID(), home_id: p[0], created_by: p[1], invite_code: null, code_hash: p[2], role: p[3], expires_at: new Date(p[4]), guest_valid_from: p[5], guest_valid_until: p[6], guest_name: p[7], is_used: false, used_by: null, used_at: null, created_at: NOW() };
      s.invitations.push(i);
      return [{ ...i }];
    }],
    [/FROM home_invitations i\s+JOIN homes h ON h\.id = i\.home_id\s+WHERE i\.code_hash = \$1/, (p) =>
      s.invitations.filter((i) => i.code_hash === p[0]).map((i) => {
        const h = s.homes.get(i.home_id) || {};
        return { ...i, home_name: h.name, home_address: h.address || null };
      })],
    // ev_uyelik-6: aktif davet listesi (kod DONMEZ) ve iptal
    [/SELECT id, role, expires_at, guest_valid_from, guest_valid_until, guest_name, created_at\s+FROM home_invitations\s+WHERE home_id = \$1 AND is_used = FALSE AND expires_at > NOW\(\)\s+ORDER BY created_at DESC/, (p) =>
      s.invitations
        .filter((i) => i.home_id === p[0] && !i.is_used && alive(i.expires_at))
        .sort((a, b) => b.created_at - a.created_at)
        .map((i) => ({
          id: i.id, role: i.role, expires_at: i.expires_at, guest_valid_from: i.guest_valid_from, guest_valid_until: i.guest_valid_until,
          guest_name: i.guest_name, created_at: i.created_at,
        }))],
    [/DELETE FROM home_invitations\s+WHERE id = \$1 AND home_id = \$2 AND is_used = FALSE\s+RETURNING id/, (p) => {
      const hit = s.invitations.filter((i) => i.id === p[0] && i.home_id === p[1] && !i.is_used);
      s.invitations = s.invitations.filter((i) => !hit.includes(i));
      return hit.map((i) => ({ id: i.id }));
    }],
    [/INSERT INTO device_audit_logs/, (p) => {
      s.audits.push({ event: p[0], device_uuid: p[1], home_id: p[2], actor_user_id: p[3], actor_role: p[4], ip_address: p[5], details: p[6] ? JSON.parse(p[6]) : null });
      return [];
    }],
    [/UPDATE home_invitations\s+SET is_used = TRUE, used_by = \$2, used_at = NOW\(\)/, (p) => {
      const i = s.invitations.find((x) => x.id === p[0] && !x.is_used && alive(x.expires_at));
      if (!i) return [];
      i.is_used = true; i.used_by = p[1]; i.used_at = NOW();
      return [{ id: i.id }];
    }],

    // ---------------- home_users ----------------
    [/SELECT role, valid_from, valid_until FROM home_users WHERE home_id = \$1 AND user_id = \$2 FOR UPDATE/, (p) =>
      s.members.filter((m) => m.home_id === p[0] && m.user_id === p[1]).map((m) => ({ ...m }))],
    [/SELECT role FROM home_users WHERE home_id = \$1 AND user_id = \$2 FOR UPDATE/, (p) =>
      s.members.filter((m) => m.home_id === p[0] && m.user_id === p[1]).map((m) => ({ role: m.role }))],
    [/UPDATE home_users SET valid_from = \$3, valid_until = \$4 WHERE home_id = \$1 AND user_id = \$2/, (p) => {
      const m = s.member(p[0], p[1]);
      if (m) { m.valid_from = p[2]; m.valid_until = p[3]; }
      return [];
    }],
    [/UPDATE home_users SET role = 'resident', valid_from = NULL, valid_until = NULL/, (p) => {
      const m = s.member(p[0], p[1]);
      if (m) { m.role = 'resident'; m.valid_from = null; m.valid_until = null; }
      return [];
    }],
    [/INSERT INTO home_users \(home_id, user_id, role, valid_from, valid_until\)/, (p) => {
      if (s.member(p[0], p[1])) { const e = new Error('dup'); e.code = '23505'; throw e; }
      s.members.push({ home_id: p[0], user_id: p[1], role: p[2], valid_from: p[3], valid_until: p[4], installer_expires_at: null, created_at: NOW() });
      return [];
    }],
    [/INSERT INTO home_users \(home_id, user_id, role\) VALUES \(\$1, \$2, 'owner'\)/, (p) => {
      s.members.push({ home_id: p[0], user_id: p[1], role: 'owner', valid_from: null, valid_until: null, installer_expires_at: null, created_at: NOW() });
      return [];
    }],
    [/FROM home_users hu\s+JOIN users u ON u\.id = hu\.user_id\s+WHERE hu\.home_id = \$1/, (p) =>
      s.members.filter((m) => m.home_id === p[0] && !(m.role === 'service_user' && m.installer_expires_at && !alive(m.installer_expires_at))).map((m) => {
        const u = s.users.get(m.user_id) || {};
        return { ...m, full_name: u.full_name, email: u.email, phone: u.phone };
      })],
    [/SELECT COUNT\(\*\)::int AS n FROM home_users WHERE home_id = \$1 AND role = 'owner'/, (p) =>
      [{ n: s.members.filter((m) => m.home_id === p[0] && m.role === 'owner').length }]],
    [/DELETE FROM home_users WHERE home_id = \$1 AND user_id = \$2/, (p) => {
      s.members = s.members.filter((m) => !(m.home_id === p[0] && m.user_id === p[1]));
      return [];
    }],
    [/DELETE FROM home_users WHERE home_id = \$1/, (p) => {
      s.members = s.members.filter((m) => m.home_id !== p[0]);
      return [];
    }],
    [/SELECT 1 FROM home_users WHERE home_id = \$1 AND user_id = \$2 AND role = 'owner'/, (p) =>
      s.members.filter((m) => m.home_id === p[0] && m.user_id === p[1] && m.role === 'owner').map(() => ({ x: 1 }))],

    // ---------------- home_transfers ----------------
    [/UPDATE home_transfers SET status = 'CANCELLED'\s+WHERE home_id = \$1 AND status = 'PENDING'/, (p) => {
      const hit = s.transfers.filter((t) => t.home_id === p[0] && t.status === 'PENDING');
      hit.forEach((t) => { t.status = 'CANCELLED'; });
      return hit.map((t) => ({ id: t.id }));
    }],
    [/INSERT INTO home_transfers/, (p) => {
      const t = { id: crypto.randomUUID(), home_id: p[0], from_user_id: p[1], target_identifier: p[2], transfer_code: null, code_hash: p[3], status: 'PENDING', expires_at: new Date(p[4]), accepted_by: null, accepted_at: null, created_at: NOW() };
      s.transfers.push(t);
      return [{ ...t }];
    }],
    [/FROM home_transfers t\s+JOIN homes h ON h\.id = t\.home_id\s+WHERE t\.code_hash = \$1/, (p) =>
      s.transfers.filter((t) => t.code_hash === p[0]).map((t) => {
        const h = s.homes.get(t.home_id) || {};
        return { ...t, home_name: h.name, home_address: h.address || null };
      })],
    [/UPDATE home_transfers\s+SET status = 'COMPLETED'/, (p) => {
      const t = s.transfers.find((x) => x.id === p[1] && x.status === 'PENDING' && alive(x.expires_at));
      if (!t) return [];
      t.status = 'COMPLETED'; t.accepted_by = p[0]; t.accepted_at = NOW();
      return [{ id: t.id }];
    }],
    [/FROM home_transfers\s+WHERE home_id = \$1 AND status = 'PENDING' AND expires_at > NOW\(\)/, (p) =>
      s.transfers.filter((t) => t.home_id === p[0] && t.status === 'PENDING' && alive(t.expires_at)).map((t) => ({ id: t.id, home_id: t.home_id, target_identifier: t.target_identifier, status: t.status, expires_at: t.expires_at, created_at: t.created_at }))],

    // ---------------- users (transfer) ----------------
    [/SELECT id, email, phone(?:, role)? FROM users WHERE id = \$1/, (p) => (s.users.has(p[0]) ? [{ ...s.users.get(p[0]) }] : [])],

    // ---------------- cihaz sahipligi (yalnizca kayit) ----------------
    [/UPDATE device_inventory SET claimed_by_user_id = \$1 WHERE claimed_home_id = \$2/, (p) => { s.deviceUpdates.push(['inventory', ...p]); return []; }],
    [/UPDATE devices SET claimed_by = \$1 WHERE home_id = \$2/, (p) => { s.deviceUpdates.push(['devices', ...p]); return []; }],
  ];

  s.handle = async (params, text) => {
    for (const [re, fn] of rules) {
      if (re.test(text)) return fn(params || [], text);
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

module.exports = { createHomeStore };
