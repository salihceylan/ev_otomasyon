// Uctan uca "duman testi" (run.js smoke): calisan QA yiginini (sunucu + broker + simulator) GERCEK REST/MQTT
// uzerinden dener. Tohumlanmis hesaplari kullanir; yan etkileri geri alinir (servis PIN'i yenilenir, uye geri eklenir,
// uye cikarmanin dondurdugu yerel anahtar accounts.json'a yazilir).
// Amac: yiginin "tum sistem calisiyor" iddiasini somut denetimle desteklemek ve sunucu/firmware sozlesme
// sapmalarini erken yakalamak. Basarisiz denetimler gercek bulgudur (QA yigini degil, sunucu/sozlesme olabilir).
import mqtt from 'mqtt';
import { PORTS } from './config.js';
import { fetchJson, sleep, waitFor } from './util.js';
import { readAccounts, writeAccounts } from './accounts.js';
import { QaApi } from './seed.js';

const dataOf = (res) => (res.json && typeof res.json === 'object' && 'data' in res.json ? res.json.data : res.json);
const first = (o, ...ks) => { for (const k of ks) if (o && o[k] !== undefined && o[k] !== null) return o[k]; return undefined; };

/** MQTT istemcisi (kimlikle). Host eslemesi: emulator adresi -> 127.0.0.1. */
function mqttConnect({ host, port, username, password, clientId }) {
  const h = host === '10.0.2.2' || host === 'localhost' ? '127.0.0.1' : host;
  return new Promise((resolve, reject) => {
    const c = mqtt.connect({ protocol: 'mqtt', host: h, port, username, password, clientId, clean: true, reconnectPeriod: 0, connectTimeout: 5000, protocolVersion: 4 });
    c.once('connect', () => { c.on('error', () => {}); resolve(c); });
    c.once('error', (e) => { c.end(true); reject(e); });
  });
}

function subscribeOnce(c, topic) {
  return new Promise((resolve) => {
    c.subscribe(topic, { qos: 1 }, (err, granted) => resolve(!err && granted && granted[0] && granted[0].qos !== 128));
  });
}

/**
 * @returns {Promise<{ok:boolean, checks:{name:string, ok:boolean, detail?:string}[]}>}
 */
export async function runSmoke({ rt, apiBase = `http://127.0.0.1:${PORTS.api}/api/v1`, log = () => {} }) {
  const acc = readAccounts(rt);
  if (!acc || !acc.homes || !acc.homes.home1) throw new Error('tohumlanmis hesap yok (accounts.json): `up --stage2` / `seed` calistirin');
  const api = new QaApi(apiBase);
  const checks = [];
  const homeId = acc.homes.home1.id;
  const uid = acc.devices.home1.uid;
  const simBase = `http://127.0.0.1:${acc.devices.home1.http_port}`;
  const T = acc.homes.home1.mqtt_topic_id;
  const tokens = {};
  const open = [];

  async function check(name, fn) {
    try {
      const detail = await fn();
      checks.push({ name, ok: true, detail: typeof detail === 'string' ? detail : undefined });
    } catch (e) {
      checks.push({ name, ok: false, detail: e.message });
    }
    log('smoke_check', { name, ok: checks.at(-1).ok });
  }
  const expect = (cond, msg) => { if (!cond) throw new Error(msg); };
  const expectStatus = async (promise, statuses, label) => {
    let res;
    try { res = await promise; } catch (e) { res = { status: e.detail && e.detail.status, err: e }; }
    expect(statuses.includes(res.status), `${label}: HTTP ${res.status} (beklenen ${statuses.join('/')})${res.err ? ` ${res.err.message}` : ''}`);
    return res;
  };
  const raw = (method, path, o = {}) => api.request(method, path, { ok: [200, 201, 204, 400, 401, 403, 404, 409, 423, 429, 502], ...o });
  const sim = (method, path, o = {}) => fetchJson(`${simBase}${path}`, { method, headers: o.key ? { 'X-Device-Key': o.key } : {}, body: o.body, timeoutMs: 8000 });
  const simState = async () => (await sim('GET', '/__sim/state')).json;
  const cmd = (who, command, extra = {}) => raw('POST', `/devices/${uid}/command`, { token: tokens[who], body: { home_id: homeId, command, ...extra } });
  // pano-6: uye cikarma tek panolu evde yerel anahtari DONDURUR (bekleyen -> `set_local_key` -> pano lk_fp'siyle takas).
  // Pano eski anahtari birakinca sunucunun guncel anahtari panoda dogrulanir ve accounts.json'a yazilir (tohum durumu).
  async function syncRotatedLocalKey() {
    const info = acc.devices.home1;
    const old = info.local_key;
    expect(old, 'accounts.json home1 yerel anahtari yok');
    const status = async (key) => (await sim('GET', '/api/auth/check', { key })).status;
    await waitFor(async () => (await status(old)) === 401, { timeoutMs: 45000, intervalMs: 500, label: 'uye cikarma yerel anahtari dondurmedi (pano-6)' });
    let fresh = null;
    await waitFor(async () => {
      const k = first(dataOf(await api.request('GET', `/homes/${homeId}/devices/${encodeURIComponent(uid)}/local-key`, { token: tokens.owner1 })), 'local_key');
      if (!k || k === old || (await status(k)) !== 200) return false;
      fresh = k;
      return true;
    }, { timeoutMs: 20000, intervalMs: 700, label: 'sunucu panonun yeni yerel anahtarini kesinlestirmedi' });
    info.local_key = fresh;
    writeAccounts(rt, acc);
  }

  try {
    // ---------------------------------------------------------------- oturumlar
    for (const k of ['owner1', 'owner2', 'resident', 'guest_valid', 'guest_expired', 'staff']) {
      await check(`giris: ${k}`, async () => {
        const u = acc.users[k];
        const res = await api.request('POST', '/auth/login', { body: { identifier: u.email, password: u.password } });
        tokens[k] = first(dataOf(res), 'access_token', 'token');
        expect(tokens[k], 'access token yok');
      });
    }

    // ---------------------------------------------------------------- IDOR / ev listesi / uc noktalar
    await check('GET /homes: sahip 1 ev 1\'i rol=owner ile gorur', async () => {
      const d = dataOf(await api.request('GET', '/homes', { token: tokens.owner1 }));
      const h = (Array.isArray(d) ? d : first(d, 'homes') || []).find((x) => x.id === homeId);
      expect(h, 'ev 1 listede yok');
      expect(h.role === 'owner', `rol=${h.role}`);
      expect(typeof h.mqtt_topic_id === 'string' && h.mqtt_topic_id.startsWith('h_'), `mqtt_topic_id=${h.mqtt_topic_id}`);
    });
    await check('IDOR: sahip 2 ev 1\'in cihaz/uc nokta/kural uclarina ERISEMEZ', async () => {
      for (const p of [`/homes/${homeId}/devices`, `/homes/${homeId}/endpoints`, `/homes/${homeId}/scheduled-rules`, `/homes/${homeId}/devices/${uid}/local-key`]) {
        const r = await raw('GET', p, { token: tokens.owner2 });
        expect([403, 404].includes(r.status), `${p}: HTTP ${r.status}`);
      }
      const c = await cmd('owner2', { relay: 5, state: true });
      expect([403, 404].includes(c.status), `komut: HTTP ${c.status}`);
    });
    await check('uc noktalar: ev 1 icin 8 kanal listelenir', async () => {
      const d = dataOf(await api.request('GET', `/homes/${homeId}/endpoints`, { token: tokens.owner1 }));
      const arr = Array.isArray(d) ? d : first(d, 'endpoints') || [];
      expect(arr.length === 8, `kanal sayisi ${arr.length}`);
    });
    await check('zamanli kurallar: sahip 4 kural gorur, misafir goremez', async () => {
      const d = dataOf(await api.request('GET', `/homes/${homeId}/scheduled-rules`, { token: tokens.owner1 }));
      const arr = Array.isArray(d) ? d : first(d, 'rules') || [];
      expect(arr.length === 4, `kural sayisi ${arr.length}`);
      const g = await raw('GET', `/homes/${homeId}/scheduled-rules`, { token: tokens.guest_valid });
      expect(g.status === 403, `misafir HTTP ${g.status}`);
    });

    // ---------------------------------------------------------------- bulut: cihaz cevrimici, state, MQTT kimligi
    await check('cihaz bulutta cevrimici (sunucu kopru -> DB)', async () => {
      const d = dataOf(await api.request('GET', `/homes/${homeId}/devices`, { token: tokens.owner1 }));
      const arr = Array.isArray(d) ? d : first(d, 'devices') || [];
      const dev = arr.find((x) => first(x, 'device_uuid') === uid);
      expect(dev, 'cihaz listede yok');
      expect(dev.online === true || dev.is_online === true, 'cihaz cevrimdisi gorunuyor');
    });

    let ownerMqtt = null;
    await check('MQTT kimligi: sahip salt-okunur kimlik alir; baglanir; state/status abone olur, cmd REDDEDILIR', async () => {
      const d = dataOf(await api.request('POST', `/homes/${homeId}/mqtt-credentials`, { token: tokens.owner1 }));
      for (const k of ['host', 'port', 'username', 'password', 'client_id', 'expires_at', 'topic_id']) expect(d[k] !== undefined, `yanitta ${k} yok`);
      expect(d.topic_id === T, 'topic_id ev konu kimligiyle uyusmuyor');
      expect(/^a_h_[0-9a-f]{16}_/.test(d.username), `kullanici adi bicimi: ${d.username}`);
      ownerMqtt = await mqttConnect({ host: d.host, port: d.port, username: d.username, password: d.password, clientId: `smoke-${Date.now()}` });
      open.push(ownerMqtt);
      const msgs = [];
      ownerMqtt.on('message', (t, p, pk) => msgs.push({ t, p: p.toString(), retain: pk.retain }));
      expect(await subscribeOnce(ownerMqtt, `ev/${T}/state`), 'state aboneligi reddedildi');
      expect(await subscribeOnce(ownerMqtt, `ev/${T}/status`), 'status aboneligi reddedildi');
      expect(!(await subscribeOnce(ownerMqtt, `ev/${T}/cmd`)), 'cmd aboneligi KABUL edildi (olmamali)');
      expect(!(await subscribeOnce(ownerMqtt, 'ev/#')), 'joker abonelik KABUL edildi (olmamali)');
      await waitFor(() => msgs.some((m) => m.t.endsWith('/state')), { timeoutMs: 8000, label: 'retained state gelmedi' });
      const st = JSON.parse(msgs.find((m) => m.t.endsWith('/state')).p);
      expect(st.v >= 2 && st.uid === uid, `state v=${st.v} uid=${st.uid}`);   // v1.2.0 state v:3 (v:2 ust kumesi; tuketiciler v >= 2 denetler [O8])
      expect(msgs.find((m) => m.t.endsWith('/state')).retain === true, 'state retained degil');
    });
    await check('uygulama kimligi MQTT\'ye YAYIN YAPAMAZ (cmd dusurulur, cihaz uygulamaz)', async () => {
      expect(ownerMqtt, 'MQTT baglantisi yok');
      ownerMqtt.publish(`ev/${T}/cmd`, JSON.stringify({ relay: 6, state: true }), { qos: 1 });
      await sleep(1500);
      expect((await simState()).relays[5].state === false, 'rol 6 AC OLDU: uygulama yayini cihaza ulasti');
    });

    // ---------------------------------------------------------------- komut hatti (REST -> MQTT -> cihaz)
    await check('komut: sahip role 5\'i acar; yanit {delivered, device_online, command_id}; cihaz uygular', async () => {
      const r = await expectStatus(cmd('owner1', { relay: 5, state: true }), [200], 'komut');
      const d = dataOf(r);
      expect(d.delivered === true && d.device_online === true && typeof d.command_id === 'string', `yanit: ${JSON.stringify(d)}`);
      await waitFor(async () => (await simState()).relays[4].state === true, { timeoutMs: 6000, label: 'cihaz rolesi acmadi' });
      expect((await simState()).last_id === d.command_id, 'last_id komut kimligini yankilamadi');
    });
    await check('komut: durum (state) cihazdan sunucuya yansir (uygulama MQTT state\'i)', async () => {
      const d = dataOf(await api.request('GET', `/homes/${homeId}/endpoints`, { token: tokens.owner1 }));
      const arr = Array.isArray(d) ? d : first(d, 'endpoints') || [];
      const ep = arr.find((e) => Number(first(e, 'channel_index', 'channel')) === 5);
      expect(ep, 'kanal 5 yok');
      await waitFor(async () => {
        const x = dataOf(await api.request('GET', `/homes/${homeId}/endpoints`, { token: tokens.owner1 }));
        const e5 = (Array.isArray(x) ? x : first(x, 'endpoints') || []).find((e) => Number(first(e, 'channel_index', 'channel')) === 5);
        return e5 && (e5.current_state === true || e5.state === true || e5.is_on === true);
      }, { timeoutMs: 8000, label: 'DB endpoint durumu guncellenmedi' });
    });
    await check('komut yetkileri: aile uyesi + gecerli misafir role komutu verir; misafir toplu/cocuk kilidi REDDEDILIR', async () => {
      await expectStatus(cmd('resident', { relay: 5, state: false }), [200], 'resident komut');
      await expectStatus(cmd('guest_valid', { relay: 5, state: true }), [200], 'misafir komut');
      await expectStatus(cmd('guest_valid', { cmd: 'all_lights_off' }), [403], 'misafir toplu');
      await expectStatus(cmd('guest_valid', { cmd: 'set_child_lock', enabled: true }), [403], 'misafir cocuk kilidi');
      await expectStatus(cmd('resident', { cmd: 'all_lights_off' }), [200], 'resident toplu');
      await waitFor(async () => (await simState()).relays[4].state === false, { timeoutMs: 6000, label: 'toplu komut uygulanmadi' });
    });
    await check('komut dogrulamasi: gecersiz yukler 400 VALIDATION (cihaza GITMEZ)', async () => {
      for (const bad of [{ relay: 99, state: true }, { relay: 5, state: 'ON' }, { shutter: 1, pos: 101 }, { cmd: 'reboot' }, { relay: 5, state: true, extra: 1 }]) {
        const r = await cmd('owner1', bad);
        expect(r.status === 400, `${JSON.stringify(bad)} -> HTTP ${r.status}`);
      }
      const before = (await simState()).counters.mqtt_cmd_rejected;
      await sleep(400);
      expect((await simState()).counters.mqtt_cmd_rejected === before, 'cihaz gecersiz komut aldi (sunucu elemeliydi)');
    });
    await check('panjur: pair 1 tabanli; yukari komutu cihazda pair 1\'i hareket ettirir', async () => {
      await expectStatus(cmd('owner1', { shutter: 1, cmd: 'up' }), [200], 'panjur up');
      await waitFor(async () => (await simState()).shutters.find((s) => s.pair === 1).dir === 1, { timeoutMs: 6000, label: 'panjur 1 hareket etmedi' });
      await expectStatus(cmd('owner1', { shutter: 1, cmd: 'stop' }), [200], 'panjur stop');
      await waitFor(async () => (await simState()).shutters.find((s) => s.pair === 1).dir === 0, { timeoutMs: 6000 });
      expect((await simState()).violation_count === 0, 'INTERLOCK ihlali kaydedildi');
    });

    // ---------------------------------------------------------------- misafir suresi dolmus
    await check('suresi dolmus misafir: 403 GUEST_EXPIRED (MQTT kimligi ve komut)', async () => {
      const a = await raw('POST', `/homes/${homeId}/mqtt-credentials`, { token: tokens.guest_expired });
      expect(a.status === 403 && a.json && a.json.code === 'GUEST_EXPIRED', `mqtt-credentials: HTTP ${a.status} code=${a.json && a.json.code}`);
      const b = await cmd('guest_expired', { relay: 5, state: true });
      expect(b.status === 403 && b.json && b.json.code === 'GUEST_EXPIRED', `komut: HTTP ${b.status} code=${b.json && b.json.code}`);
    });

    // ---------------------------------------------------------------- yerel anahtar (LAN modu)
    await check('yerel anahtar: sahip/aile alir (cihazda gecerli), misafir ALAMAZ', async () => {
      const k1 = first(dataOf(await api.request('GET', `/homes/${homeId}/devices/${encodeURIComponent(uid)}/local-key`, { token: tokens.owner1 })), 'local_key');
      expect(k1, 'local_key yok');
      expect((await sim('GET', '/api/auth/check', { key: k1 })).status === 200, 'sunucunun anahtari cihazda gecersiz');
      expect((await sim('GET', '/api/auth/check', { key: 'yanlis-anahtar-1' })).status === 401, 'yanlis anahtar kabul edildi');
      const g = await raw('GET', `/homes/${homeId}/devices/${encodeURIComponent(uid)}/local-key`, { token: tokens.guest_valid });
      expect(g.status === 403, `misafir HTTP ${g.status}`);
    });

    // ---------------------------------------------------------------- cevrimdisi / geri gelme
    await check('cevrimdisi: LWT -> sunucu is_online=false -> komut 409 DEVICE_OFFLINE; cihaz donunce komut calisir', async () => {
      await sim('POST', '/__sim/offline');
      await waitFor(async () => {
        const r = await cmd('owner1', { relay: 6, state: true });
        return r.status === 409 && r.json && r.json.code === 'DEVICE_OFFLINE';
      }, { timeoutMs: 15000, intervalMs: 700, label: 'sunucu cihazi cevrimdisi saymadi' });
      expect((await simState()).relays[5].state === false, 'cevrimdisi cihaz komutu uyguladi');
      await sim('POST', '/__sim/online');
      // sozlesme (CONTRACTS §2.2): cihaz cmd'ye abone olduktan sonraki ILK 1500 ms icindeki komutlari yok sayar;
      // sunucu bu surede 'delivered:true' dondurebilir -> istemci geri alma zamanlayicisi bunu yakalar.
      await waitFor(async () => {
        const m = (await simState()).mqtt;
        return m.connected && m.cmd_subscribed && m.in_startup_window === false;
      }, { timeoutMs: 20000, intervalMs: 500, label: 'cihaz geri baglanmadi / baslangic penceresi bitmedi' });
      await waitFor(async () => (await cmd('owner1', { relay: 6, state: true })).status === 200, { timeoutMs: 20000, intervalMs: 1000, label: 'sunucu cihazi geri cevrimici gormedi' });
      await waitFor(async () => (await simState()).relays[5].state === true, { timeoutMs: 8000, label: 'cihaz geri geldikten sonra komutu uygulamadi' });
      await cmd('owner1', { cmd: 'all_lights_off' });
    });

    // ---------------------------------------------------------------- uye cikarma -> MQTT kick
    await check('uye cikarma: aile uyesinin MQTT baglantisi KICK ile dusurulur, kimligi silinir; sonra geri eklenir', async () => {
      const d = dataOf(await api.request('POST', `/homes/${homeId}/mqtt-credentials`, { token: tokens.resident }));
      const c = await mqttConnect({ host: d.host, port: d.port, username: d.username, password: d.password, clientId: `smoke-res-${Date.now()}` });
      open.push(c);
      let closed = false;
      c.on('close', () => { closed = true; });
      const members = dataOf(await api.request('GET', `/homes/${homeId}/members`, { token: tokens.owner1 }));
      const arr = Array.isArray(members) ? members : first(members, 'members') || [];
      const m = arr.find((x) => (first(x, 'email') || '').toLowerCase() === acc.users.resident.email.toLowerCase());
      expect(m, 'uye listede yok');
      const memberId = first(m, 'user_id', 'id');
      await api.request('DELETE', `/homes/${homeId}/members/${memberId}`, { token: tokens.owner1 });
      await waitFor(() => closed, { timeoutMs: 8000, label: 'uyenin MQTT baglantisi dusurulmedi (EMQX_API_URL kick calismadi?)' });
      let reconnect = 'kabul edildi';
      try {
        const c2 = await mqttConnect({ host: d.host, port: d.port, username: d.username, password: d.password, clientId: `smoke-res2-${Date.now()}` });
        c2.end(true);
      } catch (e) { reconnect = 'reddedildi'; }
      expect(reconnect === 'reddedildi', 'kimlik silinmedi: ayni kimlikle yeniden baglanildi');
      const g = await raw('GET', `/homes/${homeId}/endpoints`, { token: tokens.resident });
      expect([403, 404].includes(g.status), `cikarilan uye ev erisimi: HTTP ${g.status}`);
      // geri ekle (tohum durumunu koru)
      const inv = dataOf(await api.request('POST', `/homes/${homeId}/invitations`, { token: tokens.owner1, body: { role: 'resident' } }));
      await api.request('POST', '/homes/join', { token: tokens.resident, body: { code: first(inv, 'code', 'invite_code') } });
      await syncRotatedLocalKey();
    });

    // ---------------------------------------------------------------- servis PIN
    await check('servis PIN: 6 haneli, tek kullanimlik, TEK ev kapsami (staff olmaz, baska eve girmez); PIN yenilenir', async () => {
      const pin = acc.service_pin && acc.service_pin.pin;
      expect(pin, 'tohumlanmis servis PIN yok');
      const login = dataOf(await api.request('POST', '/auth/service-login', { body: { service_pin: pin, technician_name: 'QA Teknisyen' } }));
      const tk = first(login, 'access_token', 'token');
      expect(tk, 'servis token yok');
      expect(login.scope === 'home_service' && !login.refresh_token, `scope=${login.scope} refresh=${!!login.refresh_token}`);
      const homes = dataOf(await api.request('GET', '/homes', { token: tk }));
      const arr = Array.isArray(homes) ? homes : first(homes, 'homes') || [];
      expect(arr.length === 1 && arr[0].id === homeId, `servis oturumu ev sayisi ${arr.length}`);
      const other = await raw('GET', `/homes/${acc.homes.home2.id}/endpoints`, { token: tk });
      expect([403, 404].includes(other.status), `baska eve erisim: HTTP ${other.status}`);
      const again = await raw('POST', '/auth/service-login', { body: { service_pin: pin, technician_name: 'QA Teknisyen' } });
      expect([400, 401, 403].includes(again.status), `PIN ikinci kullanimda HTTP ${again.status} (tek kullanimlik olmali)`);
      // tohum durumunu geri kur: yeni PIN uret ve accounts.json'a yaz
      const fresh = dataOf(await api.request('POST', `/homes/${homeId}/service-token`, { token: tokens.owner1 }));
      acc.service_pin = { home: 'home1', pin: first(fresh, 'service_pin', 'pin'), expires_at: first(fresh, 'expires_at'), note: '2 saat gecerli, tek kullanimlik (servis girisinde tuketilir)' };
      writeAccounts(rt, acc);
    });
  } finally {
    for (const c of open) { try { c.end(true); } catch (_) { /* yok say */ } }
  }
  return { ok: checks.every((c) => c.ok), checks };
}
