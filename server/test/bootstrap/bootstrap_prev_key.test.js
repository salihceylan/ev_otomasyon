'use strict';

// CONTRACTS 3f + inceleme (pano-6 / acil sifirlama atlatilamaz): bootstrap ONCEKI yerel anahtari KABUL ETMEZ.
// Adaylar yalniz: devices.local_key_enc, device_inventory.local_key_enc, devices.local_key_pending_enc.
//  - bekleyen terfisi (pano yeni anahtari imzasiyla kanitladi) eski anahtari SAKLAMAZ: eski anahtarla gelen istek
//    (cikarilan uye, biten servis oturumu, acil sifirlamadan onceki sahip) 401 AYNI govde; anahtarlar degismez,
//    kimlik uretilmez, uzlastirici istenmez, geri donus denetimi yazilmaz
//  - servis SQL'i local_key_prev_* okumaz / yazmaz (onceki anahtar hic saklanmaz)
// Sahte veritabani: SQL'i bilinen bicimlerle eslestirir ve YAZILDIGI GIBI uygular (bilinmeyen SQL -> hata).

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const { DeviceBootstrapService, DENIED_BODY, signBootstrap } = require('../../src/services/device_bootstrap_service');

const UUID = 'AHBU-S3-PR0001';
const NOW = Date.parse('2026-10-08T12:00:00Z');

// Sahte sifreleme: sifreli deger her seferinde FARKLI (gercek secret_box gibi rastgele IV).
const secretBox = {
  encrypt: (k) => `enc:${crypto.randomBytes(3).toString('hex')}:${k}`,
  decrypt: (e) => {
    const m = /^enc:[0-9a-f]{6}:(.*)$/.exec(String(e));
    if (!m) throw new Error('bozuk');
    return m[1];
  },
};

function makeWorld({ current, pending = null, homeId = 'h-1', topic = 't_topic1' } = {}) {
  const enc = (k) => (k === null ? null : secretBox.encrypt(k));
  const dev = {
    id: 'd-1',
    home_id: homeId,
    is_claimed: Boolean(homeId),
    local_key_enc: enc(current),
    local_key_pending_enc: enc(pending),
    local_key_pending_at: pending ? new Date(NOW - 1000) : null,
    local_key_prev_enc: null,
    local_key_prev_until: null,
  };
  const inv = { id: 'i-1', status: 'CLAIMED', local_key_enc: dev.local_key_enc };
  const audits = [];
  const sqls = [];
  const norm = (s) => String(s).replace(/\s+/g, ' ').trim();
  const query = async (sql, params = []) => {
    const s = norm(sql);
    sqls.push(s);
    if (s.startsWith('SELECT id, status, local_key_enc FROM device_inventory')) return { rows: [{ ...inv }], rowCount: 1 };
    if (s.includes('FROM devices WHERE device_uuid = $1 FOR UPDATE')) {
      const row = { id: dev.id, home_id: dev.home_id, is_claimed: dev.is_claimed, local_key_enc: dev.local_key_enc, local_key_pending_enc: dev.local_key_pending_enc };
      // eski kod onceki anahtari 4. aday olarak okuyordu: sahte db SQL'i yazildigi gibi uygular
      if (s.includes('local_key_prev_enc')) {
        row.local_key_prev_enc = dev.local_key_prev_until && dev.local_key_prev_until.getTime() > NOW ? dev.local_key_prev_enc : null;
      }
      if (s.includes('AS topic_id')) row.topic_id = dev.home_id ? topic : null;
      return { rows: [row], rowCount: 1 };
    }
    if (s.startsWith('DELETE FROM device_bootstrap_nonces')) return { rows: [], rowCount: 0 };
    if (s.startsWith('INSERT INTO device_bootstrap_nonces')) return { rows: [], rowCount: 1 };
    if (s.startsWith('UPDATE devices SET') && s.includes('local_key_enc = local_key_pending_enc')) {
      // bekleyen terfisi (CAS: bekleyen hala okunan deger)
      assert.match(s, /WHERE id = \$1 AND local_key_pending_enc = \$2$/);
      if (params[0] !== dev.id || dev.local_key_pending_enc !== params[1]) return { rows: [], rowCount: 0 };
      if (s.includes('local_key_prev_enc = CASE') && dev.local_key_enc !== dev.local_key_pending_enc) {
        dev.local_key_prev_enc = dev.local_key_enc;
        dev.local_key_prev_until = new Date(NOW + 30 * 86400000);
      }
      dev.local_key_enc = dev.local_key_pending_enc;
      dev.local_key_pending_enc = null;
      dev.local_key_pending_at = null;
      return { rows: [], rowCount: 1 };
    }
    if (s.startsWith('UPDATE devices SET local_key_enc = $2, local_key_pending_enc = COALESCE(local_key_pending_enc, $3)')) {
      // eski kodun geri donus (revert) yazimi
      if (params[0] !== dev.id || dev.local_key_enc !== params[2]) return { rows: [], rowCount: 0 };
      dev.local_key_enc = params[1];
      dev.local_key_pending_enc = dev.local_key_pending_enc || params[2];
      dev.local_key_prev_enc = null;
      dev.local_key_prev_until = null;
      return { rows: [], rowCount: 1 };
    }
    if (s.startsWith('UPDATE device_inventory SET local_key_enc = $2')) {
      inv.local_key_enc = params[1];
      return { rows: [], rowCount: 1 };
    }
    if (s.startsWith('INSERT INTO device_audit_logs')) {
      const m = /VALUES \('([a-z_]+)'/.exec(s);
      const event = m ? m[1] : params[0];
      const details = JSON.parse(params[params.length - 1]);
      audits.push({ event, details });
      return { rows: [], rowCount: 1 };
    }
    throw new Error(`sahte db: bilinmeyen SQL: ${s.slice(0, 120)}`);
  };
  let committed = false;
  const db = {
    async withTransaction(fn) {
      committed = false;
      const r = await fn({ query });
      committed = true;
      return r;
    },
    query,
  };
  const reconciles = [];
  const issued = [];
  const credentials = {
    async issueDeviceCredential(args) {
      assert.equal(committed, false, 'kimlik islem icinde uretilir');
      issued.push(args.deviceId);
      return { host: 'mqtt.test', port: 8883, username: 'd_user', password: 'p', previous_usernames: [] };
    },
    async kickUsernames() {},
  };
  const bridge = { requestReconcile: (topicId) => reconciles.push(topicId) };
  const logs = [];
  const logger = { log: (...a) => logs.push(a.join(' ')), warn: (...a) => logs.push(a.join(' ')), error: (...a) => logs.push(a.join(' ')) };
  const svc = new DeviceBootstrapService({ db, credentials, secretBox, logger, mqttBridge: bridge, now: () => NOW });
  const call = (key) => {
    const ts = Math.floor(NOW / 1000);
    const nonce = crypto.randomBytes(16).toString('hex');
    return svc.bootstrap({ body: { device_uuid: UUID, ts, nonce, fw: '1.3.0', sig: signBootstrap(key, UUID, ts, nonce) }, ip: '203.0.113.5' });
  };
  return { dev, inv, audits, sqls, reconciles, issued, logs, call };
}

test('rotasyon terfisinden sonra ESKI anahtar (cikarilan uye / biten servis oturumu) 401: geri donus yok, anahtarlar ve kimlik degismez', async () => {
  const w = makeWorld({ current: 'EskiAnahtar-0001', pending: 'YeniAnahtar-0001' });
  const pendEnc = w.dev.local_key_pending_enc;

  // pano yeni (bekleyen) anahtarla gelir: terfi
  const ok = await w.call('YeniAnahtar-0001');
  assert.equal(ok.http, 200);
  assert.equal(w.dev.local_key_enc, pendEnc);
  assert.equal(w.dev.local_key_pending_enc, null);
  assert.equal(w.inv.local_key_enc, pendEnc, 'envanter yeni anahtar');
  assert.equal(w.dev.local_key_prev_enc, null, 'onceki anahtar SAKLANMAZ');
  assert.deepEqual(w.audits.filter((a) => a.event === 'local_key_rotated').map((a) => a.details), [{ via: 'bootstrap' }]);
  assert.equal(w.issued.length, 1);

  // eski anahtari bilen kisi: AYNI 401 govdesi; hicbir sey degismez
  assert.deepEqual(await w.call('EskiAnahtar-0001'), { http: 401, body: DENIED_BODY });
  assert.equal(w.dev.local_key_enc, pendEnc, 'gecerli anahtar geri alinmadi');
  assert.equal(w.dev.local_key_pending_enc, null);
  assert.equal(w.inv.local_key_enc, pendEnc, 'envanter eski anahtara donmedi');
  assert.equal(w.issued.length, 1, 'eski anahtara cihaz MQTT kimligi uretilmez');
  assert.equal(w.audits.filter((a) => a.event === 'local_key_reverted').length, 0);
  assert.deepEqual(w.reconciles, []);

  // pano yeni anahtarla calismaya devam eder
  assert.equal((await w.call('YeniAnahtar-0001')).http, 200);
  const joined = JSON.stringify(w.audits) + w.logs.join('\n');
  assert.ok(!joined.includes('EskiAnahtar-0001') && !joined.includes('YeniAnahtar-0001'), 'anahtar denetim/gunlukte yok');
});

test('sahiplenilmemis kartta (stoga donus sonrasi) eski anahtar 401; yeni anahtar 202', async () => {
  const w = makeWorld({ current: 'StokEski-0002', pending: 'StokYeni-0002', homeId: null });
  assert.deepEqual(await w.call('StokYeni-0002'), { http: 202, body: { status: 'pending' } });
  assert.deepEqual(await w.call('StokEski-0002'), { http: 401, body: DENIED_BODY });
  assert.equal(w.issued.length, 0);
});

test('bootstrap SQL i onceki anahtari (local_key_prev_*) okumaz / yazmaz; geri donus yazimi yok', async () => {
  const w = makeWorld({ current: 'EskiAnahtar-0003', pending: 'YeniAnahtar-0003' });
  await w.call('YeniAnahtar-0003');
  await w.call('EskiAnahtar-0003');
  await w.call('YanlisAnahtar-0003');
  assert.ok(w.sqls.length > 0);
  for (const s of w.sqls) {
    assert.doesNotMatch(s, /local_key_prev/, `onceki anahtar kolonu: ${s.slice(0, 100)}`);
    assert.doesNotMatch(s, /local_key_reverted/);
  }
  const src = require('node:fs').readFileSync(require.resolve('../../src/services/device_bootstrap_service'), 'utf8');
  assert.doesNotMatch(src, /local_key_prev/);
});
