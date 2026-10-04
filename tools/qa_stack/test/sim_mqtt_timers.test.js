// MqttManager zamanlayicilari (SANAL SAAT, gercek broker/soket yok) = firmware MqttManager.cpp + NetTime.h portu: durum yayini tetikleme/birlestirme/kalp atisi
// (PublishPacer), yayin hatasi sonrasi ustel bekleme (1-2-4-8-16-30 sn), yeniden baglanma sabitleri (ReconnectBackoff) ve abonelik sonrasi 1500 ms
// "yok say" penceresi (sessizlikte bayat kalmaz). Gercek broker ile entegrasyon: test/sim_mqtt.test.js.
import test from 'node:test';
import assert from 'node:assert/strict';
import { MqttManager, QA_TIMING, FIRMWARE_TIMING } from '../sim/fw/mqtt_manager.js';
import { Rig } from './_rig.js';

const T = 'h_0123456789abcdef';

/** Baglanmis gibi davranan bir yonetici: sahte mqtt istemcisi (yayinlari toplar; connected=false -> yayin hatasi). */
function makeManager({ timing = {}, t0 = 5000 } = {}) {
  const rig = new Rig();
  rig.cm.setMqttCredentials('127.0.0.1', 1883, `d_${T}`, 'sifre-12345');
  rig.cm.save();
  const events = [];
  const clock = { t: t0, now: () => clock.t };
  const wifi = { getDeviceUid: () => 'AHBU-S3-0A0001', isConnected: () => true, isTimeSynced: () => true, getLocalIP: () => '192.168.1.40', applyApConfigChange() {} };
  const posted = [];
  const m = new MqttManager({
    config: rig.cm, wifi, automation: rig.a, clock, uptimeSec: () => 1, mac: '02:A5:00:0A:00:01', fw: '1.1.1',
    post: (c) => { posted.push(c); return true; }, hooks: { event: (type, f) => events.push({ type, ...f }) }, timing,
  });
  m.begin();
  const published = [];
  const client = {
    connected: true,
    publish(topic, payload, opts, cb) { published.push({ topic, payload: String(payload), opts }); cb?.(); },
    subscribe() {}, end() {}, on() {},
  };
  m.client = client;
  m.connected = true;
  m.pace.connected();
  return { m, rig, clock, events, published, client, posted, states: () => published.filter((p) => p.topic === `ev/${T}/state`) };
}

const at = (h, ms) => { h.clock.t = (h.clock.t + ms) >>> 0; h.m.step(h.clock.t); };

test('yayin zamanlamasi: baglanir baglanmaz ilk tam durum GECIKMESIZ; sonra kalp atisi tam 30 sn', () => {
  const h = makeManager();
  h.m.step(h.clock.t);
  assert.equal(h.states().length, 1, 'ilk tam durum hemen');
  const first = JSON.parse(h.states()[0].payload);
  assert.deepEqual([first.v, first.uid, first.seq], [2, 'AHBU-S3-0A0001', 1]);
  assert.deepEqual([h.states()[0].opts.qos, h.states()[0].opts.retain], [0, true], 'state QoS 0 + retained');
  const sentAt = h.clock.t;
  for (let ms = 50; ms < 30000; ms += 50) {
    h.clock.t = (sentAt + ms) >>> 0;
    h.m.step(h.clock.t);
    assert.equal(h.states().length, 1, `kalp atisi 30 sn dolmadan yayin yok (${ms} ms)`);
  }
  h.clock.t = (sentAt + 30000) >>> 0;
  h.m.step(h.clock.t);
  assert.equal(h.states().length, 2, '30 sn: kalp atisi');
  assert.equal(JSON.parse(h.states()[1].payload).seq, 2);
});

test('yayin tetikleme zaman damgasi TASIMAZ: birlestirme penceresi bayragi ilk GOZLEDIGI turda baslar (250 ms); ikinci tetik pencereyi uzatmaz', () => {
  const h = makeManager();
  h.m.step(h.clock.t);
  assert.equal(h.states().length, 1);
  h.clock.t += 5000;                                   // sessizlik: gorev dongusu donmedi (her turda yoklanir)
  h.m.step(h.clock.t);
  h.m.triggerPublish();                                // baska gorev bayrak kurar; MQTT gorevi henuz gozlemedi
  h.clock.t += 40;                                     // gozlemden ONCE gecen sure pencereye sayilmaz
  h.m.step(h.clock.t);                                 // gozlem: pencere burada baslar
  assert.equal(h.states().length, 1);
  const observedAt = h.clock.t;
  h.m.triggerPublish();                                // ikinci tetik
  for (const dt of [50, 100, 200, 249]) { h.clock.t = (observedAt + dt) >>> 0; h.m.step(h.clock.t); assert.equal(h.states().length, 1, `+${dt}`); }
  h.clock.t = (observedAt + 250) >>> 0;
  h.m.step(h.clock.t);
  assert.equal(h.states().length, 2, '250 ms birlestirme sonrasi TEK yayin');
  h.clock.t += 100;
  h.m.step(h.clock.t);
  assert.equal(h.states().length, 2, 'bayrak tuketildi: ikinci yayin yok');
  assert.equal(h.m.pace.isPending(), false);
});

test('yayin hatasi: istek KORUNUR, 1-2-4-8-16-30-30 sn ustel bekleme (retry); basarida sayac sifirlanir', () => {
  const h = makeManager();
  h.m.step(h.clock.t);
  assert.equal(h.states().length, 1);
  h.client.connected = false;                          // yayin basarisiz (firmware: _mqttClient.publish false)
  h.m.triggerPublish();
  const waits = [];
  for (let i = 0; i < 7; i++) {
    // sonraki deneme zamanina kadar ilerle (50 ms adimlarla) ve yeni hata olayini yakala
    const before = h.events.filter((e) => e.type === 'mqtt_publish_deferred').length;
    for (let k = 0; k < 2000 && h.events.filter((e) => e.type === 'mqtt_publish_deferred').length === before; k++) at(h, 50);
    waits.push(h.events.filter((e) => e.type === 'mqtt_publish_deferred').at(-1).retry_in_ms);
    assert.equal(h.m.pace.isPending(), true, 'istek korunur');
  }
  assert.deepEqual(waits, [1000, 2000, 4000, 8000, 16000, 30000, 30000]);
  assert.equal(h.states().length, 1, 'hicbir yayin gitmedi');
  h.client.connected = true;                           // baglanti duzeldi
  for (let k = 0; k < 800 && h.states().length === 1; k++) at(h, 50);
  assert.equal(h.states().length, 2, 'bekleme bitince KORUNAN istek yayinlandi');
  assert.equal(h.m.pace.failCount, 0, 'basari: hata sayaci sifirlandi');
  h.client.connected = false;
  h.m.triggerPublish();
  const before = h.events.filter((e) => e.type === 'mqtt_publish_deferred').length;
  for (let k = 0; k < 40 && h.events.filter((e) => e.type === 'mqtt_publish_deferred').length === before; k++) at(h, 50);
  assert.equal(h.events.filter((e) => e.type === 'mqtt_publish_deferred').at(-1).retry_in_ms, 1000, 'sayac 1 sn\'den yeniden baslar');
});

test('yeniden baglanma sabitleri: QA hizli (2..10 sn, jitter yok) / firmware (5 -> 300 sn +-%20 jitter, CONNACK 4/5 300 sn, TLS hatasi >= 60 sn)', () => {
  const q = makeManager({ timing: QA_TIMING }).m.reconnect;
  assert.deepEqual([q.minMs, q.maxMs, q.authRejectMs, q.longMinMs, q.jitter], [2000, 10000, 10000, 10000, false]);
  q.schedule(0, false, 0); assert.deepEqual([q.wait.span, q.backoffMs], [2000, 4000]);
  q.schedule(0, false, 0); q.schedule(0, false, 0); q.schedule(0, false, 0);
  assert.equal(q.backoffMs, 10000, 'tavan 10 sn');

  const f = makeManager({ timing: FIRMWARE_TIMING }).m.reconnect;
  assert.deepEqual([f.minMs, f.maxMs, f.authRejectMs, f.longMinMs, f.jitter], [5000, 300000, 300000, 60000, true]);
  for (let i = 0; i < 40; i++) {
    f.reset();
    f.schedule(0, false, (Math.random() * 0x100000000) >>> 0);
    assert.ok(f.wait.span >= 4000 && f.wait.span <= 6000, `jitter +-%20: ${f.wait.span}`);
  }
  f.reset(); f.scheduleAuthRejected(0, 0);
  assert.ok(f.wait.span >= 240000 && f.wait.span <= 360000, `CONNACK 4/5: ~300 sn (${f.wait.span})`);
  assert.equal(f.backoffMs, 300000);
  f.reset(); f.schedule(0, true, 0);
  assert.ok(f.wait.span >= 48000, `sertifika dogrulama hatasi: >= 60 sn tabanli (${f.wait.span})`);
});

test('abonelik sonrasi ilk 1500 ms cmd/sys YOK SAYILIR; sonrasi islenir; haftalarca sessizlikte pencere BAYAT kalmaz (N6)', () => {
  for (const t0 of [5000, 0xFFFF0000, 0x7FFFF000]) {
    const h = makeManager({ t0 });
    h.m.ignore.arm(h.clock.t, 1500);
    h.m.connected = true;
    const cmd = Buffer.from(JSON.stringify({ relay: 5, state: true }));
    h.clock.t = (t0 + 1499) >>> 0;
    assert.equal(h.m.onMessage(`ev/${T}/cmd`, cmd).kind, 'ignored_window', 'pencere icinde');
    assert.equal(h.posted.length, 0);
    h.clock.t = (t0 + 1500) >>> 0;
    assert.equal(h.m.onMessage(`ev/${T}/cmd`, cmd).kind, 'queued', '1500 ms: islenir');
    assert.equal(h.posted.length, 1);

    // sessizlik: pencere kuruldu, mesaj YOK, gorev dongusu 40 gun yoklar (24,86 gunu ve 49,7 gun yakinini asar)
    const g = makeManager({ t0 });
    g.m.ignore.arm(g.clock.t, 1500);
    g.m.qaHold = true;                                  // adim yalniz zamanlayicilari yoklar (yayin/baglanti yok)
    for (let t = 0; t < 40 * 86400000; t += 60000) { g.clock.t = (t0 + t) >>> 0; g.m.step(g.clock.t); }
    assert.equal(g.m.onMessage(`ev/${T}/cmd`, cmd).kind, 'queued', `taban ${t0.toString(16)}: 40 gun sonra ilk komut ISLENIR (eski hedef-zaman karsilastirmasi hepsini yok sayardi)`);
  }
});

test('qaState: next_attempt_in_ms / backoff_ms / in_startup_window zamanlayicilardan okunur', () => {
  const h = makeManager({ timing: QA_TIMING });
  h.m.ignore.arm(h.clock.t, 1500);
  h.clock.t += 500;
  const s = h.m.qaState(h.clock.t);
  assert.equal(s.in_startup_window, true);
  assert.equal(s.next_attempt_in_ms, 0);
  assert.equal(s.backoff_ms, 2000);
  h.m.reconnect.schedule(h.clock.t, false, 0);
  assert.deepEqual([h.m.qaState(h.clock.t).next_attempt_in_ms, h.m.qaState(h.clock.t).backoff_ms], [2000, 4000]);
  h.clock.t += 1100;
  assert.equal(h.m.qaState(h.clock.t).in_startup_window, false, '1500 ms doldu');
});
