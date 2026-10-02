// GERCEK yigin uzerinde tohumlama IDEMPOTENCY testi: gomulu PostgreSQL 18 + broker + simulator + GERCEK server/ + gercek REST tohumlamasi.
// `node run.js` CLI'si alt surec olarak calistirilir (kullanicinin yaptigiyla ayni yol); her sey YALITILMIS bir QA_RUNTIME_DIR
// (gecici dizin) ve rastgele bos portlarla kurulur: kullanicinin tools/qa_stack/.runtime klasorune ve 5000/1883/... portlarina
// DOKUNMAZ. server/ kaynagi ya da node_modules yoksa ATLANIR.
//
// Kanitlananlar (docs/QA_STACK.md §4 "Tohumlama davranisi"):
//   1. ikinci/ucuncu `seed` ve `up --stage2` (yeniden baslatma) DB kayit sayilarini, satir kimliklerini, uyelik/kural/PIN/kimlik
//      durumunu ve accounts.json'u (icerik + mtime) DEGISTIRMEZ; cikti "0 yapildi, N atlandi (zaten var)" der
//   2. servis personeli (qa.servis) zorunlu parola degisimi istemez (must_change_password=false) ve accounts.json parolasi gecerlidir
//   3. bozulmus durum onarilir: yinelenen zamanli kurallar, uygulamada degistirilmis parola, bayrak, silinmis aile uyesi, suresi dolmus
//      24 sa misafir, kullanilmis/suresi dolmus servis PIN'i, kopmus simulator bulut kimligi
//   4. `--keep-secrets` oturumlari korur; her `up` JWT sirrini yeniler (eski access token 401, refresh token calisir)
//   5. `smoke` 23/23 ve zamanli kural sayisi 4
import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import pg from 'pg';
import { readAccounts } from '../lib/accounts.js';
import { ROOT, SERVER_DIR, runtimePaths } from '../lib/paths.js';
import { QaApi, SCHEDULED_RULES } from '../lib/seed.js';
import { fetchJson, readJson, sleep } from '../lib/util.js';

const RUN_JS = path.join(ROOT, 'run.js');
const SKIP = (!fs.existsSync(path.join(SERVER_DIR, 'src', 'server.js')) || !fs.existsSync(path.join(SERVER_DIR, 'node_modules', 'express')))
  ? 'server/ (kaynak ya da node_modules) yok: gercek yigin kurulamaz' : false;

const PORT_ENV = ['QA_PG_PORT', 'QA_MQTT_PORT', 'QA_MQTT_WS_PORT', 'QA_BROKER_CONTROL_PORT', 'QA_SUPERVISOR_PORT', 'QA_API_PORT', 'QA_SMTP_PORT',
  'QA_SIM_PORT_1', 'QA_SIM_PORT_2', 'QA_SIM_PORT_3'];

/** n adet AYNI ANDA bos TCP portu (cakismasin diye hepsi tutulup sonra birakilir). */
async function freePorts(n) {
  const servers = [];
  try {
    for (let i = 0; i < n; i++) {
      const s = net.createServer();
      await new Promise((resolve, reject) => { s.once('error', reject); s.listen(0, '127.0.0.1', resolve); });
      servers.push(s);
    }
    return servers.map((s) => s.address().port);
  } finally {
    await Promise.all(servers.map((s) => new Promise((resolve) => s.close(resolve))));
  }
}

const dataOf = (res) => (res.json && typeof res.json === 'object' && 'data' in res.json ? res.json.data : res.json);
const sha = (text) => crypto.createHash('sha256').update(text).digest('hex');

test('tohumlama IDEMPOTENT: gercek yigin (gomulu PG + broker + simulator + gercek sunucu); onarim; --keep-secrets; smoke 23/23',
  { skip: SKIP, timeout: 900000 }, async (t) => {
    const rtDir = fs.mkdtempSync(path.join(os.tmpdir(), 'qa_runtime_seedtest_'));
    const rt = runtimePaths(rtDir);
    const ports = await freePorts(PORT_ENV.length);
    const env = { ...process.env, QA_RUNTIME_DIR: rtDir };
    delete env.NODE_TEST_CONTEXT;
    PORT_ENV.forEach((name, i) => { env[name] = String(ports[i]); });
    const apiPort = ports[PORT_ENV.indexOf('QA_API_PORT')];
    const pgPort = ports[PORT_ENV.indexOf('QA_PG_PORT')];
    const api = new QaApi(`http://127.0.0.1:${apiPort}/api/v1`);

    const cliOnce = (args, { timeoutMs = 300000 } = {}) => new Promise((resolve) => {
      const child = spawn(process.execPath, [RUN_JS, ...args], { env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
      let out = '';
      child.stdout.on('data', (d) => { out += d; });
      child.stderr.on('data', (d) => { out += d; });
      const timer = setTimeout(() => { child.kill(); }, timeoutMs);
      child.on('close', (code) => { clearTimeout(timer); resolve({ code, out }); });
    });
    /**
     * `node run.js ...` (cikti = stdout+stderr; parola icermez). Windows/Node'da bilinen aralikli YEREL cokme (cikis kodu 0xC0000409,
     * 'UV_HANDLE_CLOSING'; bkz. docs/QA_STACK.md §11) tohumlamayla ilgisizdir ve komutlarin hepsi tekrar calistirilmaya guvenlidir
     * (`up` zaten calisiyorsa "zaten calisiyor" der): bir kez yeniden denenir ve gorunur sekilde bildirilir.
     */
    const cli = async (args, o) => {
      let r = await cliOnce(args, o);
      if (typeof r.code === 'number' && r.code >= 0xC0000000) {
        console.log(`  [uyari] 'node run.js ${args[0]}' yerel olarak coktu (kod ${r.code}; bilinen Windows/libuv sorunu): bir kez yeniden deneniyor`);
        r = await cliOnce(args, o);
      }
      return r;
    };

    /** Basarisizlikta mesaja eklenir: gunluklerin son satirlari (parola/anahtar icermez: gunlukleyici maskeler). */
    const diag = () => ['daemon', 'migrate', 'api'].map((n) => {
      try {
        const tail = fs.readFileSync(rt.logs[n], 'utf8').split(/\r?\n/).slice(-30).join('\n').slice(-3500);
        return `--- ${n}.log (son satirlar)\n${tail}`;
      } catch (_) {
        return `--- ${n}.log yok`;
      }
    }).join('\n');

    let started = false;
    const emergency = () => {
      if (!started) return;
      try { spawnSync(process.execPath, [RUN_JS, 'down'], { env, timeout: 90000, windowsHide: true, stdio: 'ignore' }); } catch (_) { /* yok say */ }
    };
    process.on('exit', emergency);

    const withDb = async (fn) => {
      const secrets = readJson(rt.secretsFile);
      const c = new pg.Client({ connectionString: `postgresql://ev_qa:${encodeURIComponent(secrets.db_password)}@127.0.0.1:${pgPort}/ev_qa` });
      c.on('error', () => {});
      await c.connect();
      try { return await fn(c); } finally { await c.end().catch(() => {}); }
    };
    const sql = (text, params) => withDb((c) => c.query(text, params));
    const accounts = () => readAccounts(rt);

    // tohum varliklarinin durumu: kayit sayilari + satir kimlikleri + uyelik/kural/PIN/kimlik durumu + accounts.json ozeti (parola YAZILMAZ)
    const ENTITY_TABLES = ['users', 'homes', 'home_users', 'devices', 'device_inventory', 'endpoints', 'home_invitations', 'scheduled_rules',
      'service_tokens', 'mqtt_credentials', 'mqtt_acl', 'device_audit_logs'];
    async function snapshot() {
      return withDb(async (c) => {
        const counts = {};
        for (const name of ENTITY_TABLES) counts[name] = (await c.query(`SELECT count(*)::int AS n FROM ${name}`)).rows[0].n;
        const rows = async (text) => (await c.query(text)).rows;
        return {
          counts,
          users: await rows('SELECT email, role, is_active, account_status, must_change_password FROM users ORDER BY email'),
          members: await rows('SELECT home_id, user_id, role, valid_from, valid_until FROM home_users ORDER BY home_id, user_id'),
          rules: await rows('SELECT id, home_id, label, enabled, hour, minute FROM scheduled_rules ORDER BY id'),
          credentials: await rows('SELECT id, username, kind FROM mqtt_credentials ORDER BY username'),
          tokens: await rows("SELECT id, CASE WHEN revoked_at IS NOT NULL THEN 'revoked' WHEN used_at IS NOT NULL THEN 'used' ELSE 'open' END AS st FROM service_tokens ORDER BY id"),
          invitations: await rows('SELECT id, role, is_used FROM home_invitations ORDER BY id'),
          accountsSha: sha(fs.readFileSync(rt.accountsFile, 'utf8')),
          accountsMtime: fs.statSync(rt.accountsFile).mtimeMs,
        };
      });
    }

    const login = async (key, password) => {
      const u = accounts().users[key];
      return api.request('POST', '/auth/login', { body: { identifier: u.email, password: password ?? u.password }, ok: [200, 401] });
    };
    const bearer = async (key) => dataOf(await login(key)).access_token;
    const summaryOf = () => readJson(rt.stackFile).components.seed.summary;
    const SUMMARY_NOOP = /Tohumlama\s+tamam\s+\(\d+\/\d+ adim: 0 yapildi, \d+ atlandi \(zaten var\), 3 dogrulandi\)/;

    try {
      // ------------------------------------------------------------------ 1) temiz kurulum
      let first;
      await t.test('temiz `up --stage2`: tohum tamam; servis personeli zorunlu parola istemez; 4 zamanli kural', async () => {
        started = true;
        const up = await cli(['up', '--stage2', '--timeout', '300'], { timeoutMs: 330000 });
        assert.equal(up.code, 0, `${up.out.slice(-1500)}\n${diag()}`);
        const s = summaryOf();
        assert.equal(s.ok, true);
        assert.equal(s.failed + s.blocked, 0);
        assert.equal(s.unchanged, 0, 'temiz veritabaninda atlanacak (zaten var) adim olmamali');
        assert.ok(s.applied >= 15, `yapilan adim sayisi ${s.applied}`);
        assert.equal(s.verified, 3);
        assert.match(up.out, /Tohumlama\s+tamam\s+\(20\/20 adim: \d+ yapildi, 0 atlandi \(zaten var\), 3 dogrulandi\)/);

        const acc = accounts();
        const staff = (await sql('SELECT role, must_change_password, account_status FROM users WHERE email = $1', [acc.users.staff.email])).rows[0];
        assert.equal(staff.role, 'service_user');
        assert.equal(staff.account_status, 'active');
        assert.equal(staff.must_change_password, false, 'servis personeli ilk giriste zorunlu parola ekranina TAKILMAMALI');
        const res = await login('staff');
        assert.equal(res.status, 200, 'accounts.json parolasiyla giris');
        assert.equal(dataOf(res).user.must_change_password, false);
        assert.equal(dataOf(res).user.role, 'service_user');

        const rules = (await sql('SELECT label FROM scheduled_rules')).rows.map((r) => r.label);
        assert.equal(rules.length, 4);
        assert.deepEqual([...new Set(rules)].sort(), SCHEDULED_RULES.map((r) => r.label).sort());
        assert.equal(acc.homes.home1.scheduled_rule_ids.length, 4);
        first = await snapshot();
      });

      // ------------------------------------------------------------------ 2) ikinci ve ucuncu seed: hicbir sey degismez
      await t.test('ikinci ve ucuncu `seed`: kayit sayilari, satir kimlikleri ve accounts.json (icerik + mtime) AYNI; "0 yapildi"', async () => {
        for (const n of [2, 3]) {
          const r = await cli(['seed']);
          assert.equal(r.code, 0, r.out.slice(-1500));
          assert.match(r.out, SUMMARY_NOOP, `${n}. seed: hicbir sey yapilmamali\n${r.out.slice(-1200)}`);
          assert.doesNotMatch(r.out, /^YAPILDI/m);
          assert.deepStrictEqual(await snapshot(), first, `${n}. seed tohum varliklarini degistirdi`);
        }
      });

      // ------------------------------------------------------------------ 3) bozulmus durumu onar
      let healed;
      await t.test('bozulmus durum onarilir: yinelenen kural, degistirilen parola, bayrak, silinen uye, suresi dolan misafir/PIN, kopan cihaz kimligi', async () => {
        const acc0 = accounts();
        const homeId = acc0.homes.home1.id;
        const originalRuleIds = first.rules.map((r) => r.id);
        const oldPin = acc0.service_pin.pin;
        const owner = await bearer('owner1');

        // (a) eski tohum calistirmalarinin biraktigi yinelenen zamanli kurallar (4 -> 8)
        for (const r of SCHEDULED_RULES) await api.request('POST', `/homes/${homeId}/scheduled-rules`, { token: owner, body: r });
        assert.equal((await sql('SELECT count(*)::int AS n FROM scheduled_rules')).rows[0].n, 8);
        // (b) servis personeli parolayi uygulamada degistirdi (accounts.json eski parolada kalir)
        const staffTok = await bearer('staff');
        await api.request('POST', '/auth/change-password', { token: staffTok, body: { current_password: acc0.users.staff.password, new_password: `${acc0.users.staff.password}Xz9` } });
        assert.equal((await login('staff')).status, 401, 'eski parola artik gecersiz');
        // (b2) baska hesaplarin parolasi da uygulamada degistirildi: sahip 2 (gercek REST girisi yolu) ve misafir (SQL dogrulama yolu)
        for (const key of ['owner2', 'guest_valid']) {
          const pw = acc0.users[key].password;
          await api.request('POST', '/auth/change-password', { token: await bearer(key), body: { current_password: pw, new_password: `${pw}Qw7` } });
        }
        // (c) zorunlu parola bayragi geri acik (eski tohumun biraktigi durum)
        await sql('UPDATE users SET must_change_password = TRUE WHERE email = $1', [acc0.users.staff.email]);
        // (d) aile uyesi evden cikarildi + servis personelinin uyeligi silindi
        await api.request('DELETE', `/homes/${homeId}/members/${acc0.users.resident.id}`, { token: owner });
        await sql("DELETE FROM home_users WHERE home_id = $1 AND role = 'service_user'", [homeId]);
        // (e) 24 saatlik gecerli misafirin suresi doldu; suresi dolmus misafir yenilendi (gecerli oldu)
        await sql(`UPDATE home_users SET valid_from = now() - interval '25 hours', valid_until = now() - interval '1 hour'
                    WHERE home_id = $1 AND user_id = $2`, [homeId, acc0.users.guest_valid.id]);
        await sql(`UPDATE home_users SET valid_from = now() - interval '1 hour', valid_until = now() + interval '5 hours'
                    WHERE home_id = $1 AND user_id = $2`, [homeId, acc0.users.guest_expired.id]);
        // (f) servis PIN'inin suresi doldu
        await sql("UPDATE service_tokens SET expires_at = now() - interval '1 minute' WHERE revoked_at IS NULL AND used_at IS NULL");
        // (g) cihazin bulut kimligi yeniden uretildi: simulator eski parolayla baglanamaz (kopar)
        await api.request('POST', `/homes/${homeId}/devices/${encodeURIComponent(acc0.devices.home1.uid)}/mqtt-credential`, { token: owner });

        const r = await cli(['seed'], { timeoutMs: 240000 });
        assert.equal(r.code, 0, r.out.slice(-2000));
        assert.match(r.out, /Tohumlama\s+tamam\s+\(20\/20 adim: [1-9]\d* yapildi, /, r.out.slice(-1200));
        const stepsDone = r.out.split('\n').filter((l) => l.startsWith('YAPILDI')).map((l) => l.split(/\s+/)[1]);
        for (const name of ['servis_personeli', 'kullanici_owner2', 'kullanici_guest_valid', 'aile_uyesi', 'misafir_gecerli', 'misafir_suresi_dolmus',
          'servis_personeli_uyeligi', 'zamanli_kurallar', 'servis_pin', 'home1_simulator']) {
          assert.ok(stepsDone.includes(name), `${name} onarmaliydi (yapilanlar: ${stepsDone.join(', ')})`);
        }
        for (const [key, email] of [['staff', 'qa.servis@example.com'], ['owner2', 'qa.sahip2@example.com'], ['guest_valid', 'qa.misafir@example.com']]) {
          assert.match(r.out, new RegExp(`^NOT {2}${key} \\(${email.replace(/\./g, '\\.')}\\): accounts\\.json parolasi gecersizdi`, 'm'), `${key}: parolanin geri alinmasi NOT olarak bildirilir`);
        }

        const acc = accounts();
        // kurallar: yinelenenler silindi, ilk (en kucuk id'li) 4 kural KORUNDU, accounts.json ayni idleri tutar
        const ruleIds = (await sql('SELECT id FROM scheduled_rules ORDER BY id')).rows.map((x) => x.id);
        assert.deepEqual(ruleIds, originalRuleIds);
        assert.deepEqual(acc.homes.home1.scheduled_rule_ids.slice().sort((a, b) => a - b), originalRuleIds);
        // servis personeli: accounts.json parolasi yine gecerli, bayrak kapali, ev uyeligi geri geldi
        const res = await login('staff');
        assert.equal(res.status, 200, 'accounts.json parolasi geri alindi');
        assert.equal(dataOf(res).user.must_change_password, false);
        for (const key of ['owner2', 'guest_valid']) assert.equal((await login(key)).status, 200, `${key}: accounts.json parolasi geri alindi`);
        assert.equal((await sql('SELECT role FROM home_users WHERE home_id = $1 AND user_id = $2', [homeId, acc.users.staff.id])).rows[0].role, 'service_user');
        // uyeler
        const members = dataOf(await api.request('GET', `/homes/${homeId}/members`, { token: await bearer('owner1') })).members;
        const by = (email) => members.find((m) => m.email === email);
        assert.equal(by(acc.users.resident.email).role, 'resident', 'aile uyesi geri eklendi');
        assert.equal(by(acc.users.guest_valid.email).is_expired, false, '24 saatlik misafir yenilendi');
        assert.equal(by(acc.users.guest_expired.email).is_expired, true, 'suresi dolmus misafir yeniden gecmise cekildi');
        // PIN
        assert.notEqual(acc.service_pin.pin, oldPin, 'suresi dolan PIN yenilendi');
        assert.equal((await sql("SELECT count(*)::int AS n FROM service_tokens WHERE revoked_at IS NULL AND used_at IS NULL AND expires_at > now()")).rows[0].n, 1);
        // cihaz kimligi: simulator yeniden bulutta
        const sim = await fetchJson(`http://127.0.0.1:${acc.devices.home1.http_port}/__sim/state`);
        assert.equal(sim.json.mqtt.connected, true, 'simulator bulut kimligi onarildi');
        healed = await snapshot();
      });

      await t.test('onarimdan sonra `seed` yine tam bir bos islemdir (0 yapildi) ve hicbir sey degismez', async () => {
        const r = await cli(['seed']);
        assert.equal(r.code, 0, r.out.slice(-1500));
        assert.match(r.out, SUMMARY_NOOP, r.out.slice(-1200));
        assert.deepStrictEqual(await snapshot(), healed);
      });

      // ------------------------------------------------------------------ 4) yeniden baslatma: --keep-secrets oturumlari korur
      let sessionBefore;
      await t.test('`down` + `up --stage2 --keep-secrets`: tohum "0 yapildi"; kayitlar ayni; JWT sirri korundu -> eski access token GECERLI', async () => {
        const u = accounts().users.owner1;
        const lg = dataOf(await api.request('POST', '/auth/login', { body: { identifier: u.email, password: u.password } }));
        sessionBefore = { access: lg.access_token, refresh: lg.refresh_token };
        const secretsBefore = readJson(rt.secretsFile);
        const downRes = await cli(['down'], { timeoutMs: 120000 });
        assert.equal(downRes.code, 0, downRes.out);
        const up = await cli(['up', '--stage2', '--keep-secrets', '--timeout', '300'], { timeoutMs: 330000 });
        assert.equal(up.code, 0, `${up.out.slice(-1500)}\n${diag()}`);
        assert.match(up.out, SUMMARY_NOOP, `yeniden baslatma: hicbir sey yapilmamali\n${up.out.slice(-1500)}`);
        assert.equal(readJson(rt.secretsFile).jwt_secret, secretsBefore.jwt_secret, '--keep-secrets JWT sirrini korur');
        assert.deepStrictEqual(await snapshot(), healed, 'yeniden baslatma tohum varliklarini degistirdi');
        const r = await api.request('GET', '/homes', { token: sessionBefore.access, ok: [200, 401] });
        assert.equal(r.status, 200, 'eski access token --keep-secrets ile gecerli kalmali');
      });

      await t.test('`down` + `up --stage2` (sirlar yenilenir): tohum yine "0 yapildi"; eski access token 401, refresh token oturumu surdurur', async () => {
        const secretsBefore = readJson(rt.secretsFile);
        await cli(['down'], { timeoutMs: 120000 });
        const up = await cli(['up', '--stage2', '--timeout', '300'], { timeoutMs: 330000 });
        assert.equal(up.code, 0, `${up.out.slice(-1500)}\n${diag()}`);
        assert.match(up.out, SUMMARY_NOOP, `yeniden baslatma: hicbir sey yapilmamali\n${up.out.slice(-1500)}`);
        const secretsAfter = readJson(rt.secretsFile);
        assert.notEqual(secretsAfter.jwt_secret, secretsBefore.jwt_secret, 'her up yeni JWT sirri uretir');
        assert.equal(secretsAfter.pin_pepper, secretsBefore.pin_pepper, 'veriye bagli sirlar degismez');
        assert.deepStrictEqual(await snapshot(), healed, 'yeniden baslatma tohum varliklarini degistirdi');
        const stale = await api.request('GET', '/homes', { token: sessionBefore.access, ok: [200, 401] });
        assert.equal(stale.status, 401, 'yeni JWT sirriyla eski access token gecersiz');
        const refreshed = await api.request('POST', '/auth/refresh', { body: { refresh_token: sessionBefore.refresh }, ok: [200, 401] });
        assert.equal(refreshed.status, 200, 'refresh token DB\'de saklidir (sirdan bagimsiz): kullanici oturumu surer');
        const again = await api.request('GET', '/homes', { token: dataOf(refreshed).access_token, ok: [200, 401] });
        assert.equal(again.status, 200);
      });

      // ------------------------------------------------------------------ 5) uctan uca duman testi
      await t.test('`smoke` 23/23 ve zamanli kural sayisi 4', async () => {
        const r = await cli(['smoke'], { timeoutMs: 240000 });
        assert.equal(r.code, 0, r.out.slice(-2500));
        assert.match(r.out, /23\/23 denetim gecti\./);
        assert.match(r.out, /OK {4}zamanli kurallar: sahip 4 kural gorur/);
        assert.equal((await sql('SELECT count(*)::int AS n FROM scheduled_rules')).rows[0].n, 4);
        // smoke servis PIN'ini tuketip yenisini yazdi: sonraki seed bunu "zaten var" sayar
        const seed = await cli(['seed']);
        assert.equal(seed.code, 0, seed.out.slice(-1500));
        assert.match(seed.out, SUMMARY_NOOP, seed.out.slice(-1200));
      });
    } finally {
      process.off('exit', emergency);
      if (started) {
        const down = await cli(['down'], { timeoutMs: 120000 }).catch(() => null);
        if (!down || down.code !== 0) emergency();
      }
      await sleep(300);
      fs.rmSync(rtDir, { recursive: true, force: true, maxRetries: 30, retryDelay: 300 });
    }
  });
