// DeviceSimulator kabugu (HTTP/MQTT olmadan, sahte saatle): UID/MAC turetme, ilk acilis fabrika secenekleri, NVS kaliciligi,
// guc kesintisi (yazilmamis konum kaybi), acilis bekleme penceresi, bagimsiz fiziksel gozlemci, komut satiri secenekleri.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { DeviceSimulator, macFromUid, optionsFromCli, UID_RE, S3_UID_RE } from '../sim/device_sim.js';
import { CmdType } from '../sim/command_schema.js';
import { makeCommand, CmdSource } from '../sim/fw/automation.js';
import { FW_VERSION_DEFAULT } from '../sim/fw/wifi_manager.js';
import { readFwVersion } from '../lib/fwcheck.js';
import { tmpDir } from './_helpers.js';

test('surum: simulatorun bildirdigi fw = firmware FW_VERSION (src/WiFiManager.h); firmware surumu yukselince simulator de yukselir', () => {
  const fw = readFwVersion();
  assert.match(String(fw), /^\d+\.\d+\.\d+$/, 'WiFiManager.h FW_VERSION okunamadi');
  assert.equal(FW_VERSION_DEFAULT, fw);
  assert.equal(new DeviceSimulator({ uid: 'AHBU-S3-0A0003' }).fw_version, fw, 'varsayilan cihaz surumu');
});

function makeClock(start = 100000) {
  return { t: start, now() { return this.t; }, advance(ms) { this.t += ms; } };
}

/** Elle tikletilen cihaz: gercek zamanlayici (tickMs) kapali, saat testte ilerler. */
async function make(opts = {}) {
  const clock = makeClock();
  const sim = new DeviceSimulator({
    uid: 'AHBU-S3-0A0002', relays: 8, localKey: 'test-key-abcdef12', strict: true, clock, tickMs: 1e9, bootMs: 5, bootHoldMs: 0, ...opts,
  });
  await sim.start();
  return { sim, clock };
}

/** Sanal saati 10 ms'lik adimlarla ilerletip tick() cagirir. */
function run(sim, clock, ms) {
  for (let done = 0; done < ms; done += 10) {
    clock.advance(10);
    sim.tick();
  }
}

const post = (sim, type, index = 0, value = 0, id = '') => sim.postCommand({ ...makeCommand(type, CmdSource.QA, index, value), id });
const relayOn = (sim, n) => sim.qaState().relays[n - 1].state;
const shutter = (sim, p) => sim.qaState().shutters.find((s) => s.pair === p);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('UID/MAC: AHBU-S3-<6 hex> UID\'si MAC\'ten turetilir; firmware getDeviceUid() ayni deger; baska UID bicimi override edilir', async () => {
  assert.equal(macFromUid('AHBU-S3-0A0001'), '02:A5:00:0A:00:01');
  assert.equal(S3_UID_RE.test('AHBU-S3-0A0001'), true);
  assert.equal(S3_UID_RE.test('AHBU-S3-0a0001'), false);
  const { sim } = await make({ uid: 'AHBU-S3-0A0001' });
  try {
    const st = sim.qaState();
    assert.equal(st.device_uid, 'AHBU-S3-0A0001');
    assert.equal(st.wifi.ap_ssid, 'AHBU-0A0001', 'AP SSID = AHBU-<MAC son 6>');
  } finally {
    await sim.stop();
  }
  const other = await make({ uid: 'AHBU-QA-HOME1' });
  try {
    assert.equal(other.sim.qaState().device_uid, 'AHBU-QA-HOME1', 'S3 bicimi disinda UID aynen bildirilir (QA sapmasi)');
    assert.match(other.sim.qaState().mac, /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/);
  } finally {
    await other.sim.stop();
  }
  assert.equal(UID_RE.test('AHBU-QA-HOME1'), true);
});

test('constructor dogrulamasi: gecersiz UID, role sayisi, yerel anahtar', () => {
  assert.throws(() => new DeviceSimulator({ uid: 'yanlis-uid' }), /gecersiz UID/);
  assert.throws(() => new DeviceSimulator({ uid: 'AHBU-OK-1', relays: 10 }), /8 veya 16/);
  assert.throws(() => new DeviceSimulator({ uid: 'AHBU-OK-1', localKey: 'kisa' }), /local-key/);
  assert.equal(CmdType.RELAY_SET, 'RELAY_SET');
});

test('optionsFromCli: bayraklar secenek nesnesine cevrilir; sayi olmayan deger hata', () => {
  const o = optionsFromCli({
    uid: 'AHBU-S3-0A0001', relays: '16', 'http-port': '8081', 'mqtt-host': '127.0.0.1', 'mqtt-port': '1883', 'mqtt-user': 'd_x', 'mqtt-pass': 'p',
    'local-key': 'abcdefgh12', 'time-scale': '10', 'firmware-timing': true, 'millis-offset': '4294960000', 'boot-hold-ms': '0', strict: true,
  });
  assert.deepEqual([o.relays, o.httpPort, o.timeScale, o.firmwareTiming, o.millisOffset, o.bootHoldMs, o.strict], [16, 8081, 10, true, 4294960000, 0, true]);
  assert.deepEqual(o.mqtt, { host: '127.0.0.1', port: 1883, user: 'd_x', pass: 'p' });
  assert.throws(() => optionsFromCli({ uid: 'AHBU-S3-0A0001', relays: 'x' }), /sayi olmali/);
});

test('ilk acilis (bos NVS) fabrika secenekleri: 16 role = ek modul etkin (8 kanal); provizyon, MQTT kimligi, Wi-Fi', async () => {
  const a = await make({ relays: 16, mqtt: { host: '10.0.2.2', port: 1883, user: 'd_h_abc', pass: 'sifre-1' }, deviceName: 'Test Evi', wifiConnected: true, homeWifi: { ssid: 'EvAgi', pass: 'ev-parola-1' } });
  try {
    const cfg = a.sim.fw.cm.config;
    assert.equal(cfg.ext_module_enabled, true);
    assert.equal(cfg.ext_module_channels, 8);
    assert.equal(cfg.totalRelays(), 16);
    assert.equal(cfg.device_name, 'Test Evi');
    assert.equal(cfg.mqtt_user, 'd_h_abc');
    assert.equal(cfg.mqtt_server, '10.0.2.2');
    assert.equal(cfg.wifi_ssid, 'EvAgi');
    assert.equal(cfg.wifi_sta_enabled, true);
    assert.equal(a.sim.isProvisioned(), true);
    assert.ok(cfg.ap_pass.length >= 8, 'AP parolasi uretildi');
  } finally {
    await a.sim.stop();
  }
  const b = await make({ relays: 8, localKey: '' });
  try {
    assert.equal(b.sim.fw.cm.config.ext_module_enabled, false);
    assert.equal(b.sim.isProvisioned(), false);
    assert.equal(b.sim.fw.cm.config.wifi_sta_enabled, false);
    assert.equal(b.sim.fw.cm.config.device_name, 'AHBU Akilli Ev Kontrol');
  } finally {
    await b.sim.stop();
  }
});

test('kalicilik (NVS): kimlik, ayarlar, cocuk kilidi ve panjur konumu yeniden baslatmada korunur; resetState siler; komut satiri degerleri yalniz ILK acilista etkili', async () => {
  const dir = tmpDir();
  const stateFile = path.join(dir, 'AHBU-S3-0A0003.json');
  try {
    const a = await make({ uid: 'AHBU-S3-0A0003', stateFile, localKey: 'persist-key-01', deviceName: 'Ilk Ad' });
    post(a.sim, CmdType.SET_CHILD_LOCK, 0, 1);
    post(a.sim, CmdType.SHUTTER_POS, 1, 60);
    run(a.sim, a.clock, 14000);
    assert.equal(shutter(a.sim, 1).pos, 60);
    a.sim.fw.cm.config.relays[4].name = 'Kalici Lamba';
    a.sim.fw.cm.save();
    await a.sim.stop();                                  // zarif kapanis: konumlar zorla yazilir

    const raw = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    assert.equal(raw.cfg.lk, 'persist-key-01');
    assert.equal(raw.cfg.cfg_init, true);
    assert.equal(raw.auto.child_lock, true);
    assert.equal(raw.pos[0], 60);

    const b = await make({ uid: 'AHBU-S3-0A0003', stateFile, localKey: 'baska-anahtar-99', deviceName: 'Yeni Ad' });
    try {
      assert.equal(b.sim.fw.cm.config.local_key, 'persist-key-01', 'komut satiri degeri ILK acilista etkili; NVS onceliklidir');
      assert.equal(b.sim.fw.cm.config.device_name, 'Ilk Ad');
      assert.equal(b.sim.fw.cm.config.relays[4].name, 'Kalici Lamba');
      run(b.sim, b.clock, 50);
      assert.equal(b.sim.childLock, true);
      assert.equal(shutter(b.sim, 1).pos, 60);
      assert.equal(relayOn(b.sim, 5), false, 'guc gelince lambalar KAPALI');
    } finally {
      await b.sim.stop();
    }
    const c = await make({ uid: 'AHBU-S3-0A0003', stateFile, resetState: true, localKey: '' });
    try {
      assert.equal(c.sim.isProvisioned(), false);
      assert.equal(c.sim.childLock, false);
      run(c.sim, c.clock, 50);
      assert.equal(shutter(c.sim, 1).pos, 0);
    } finally {
      await c.sim.stop();
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('guc kesintisi: hareket bittikten <8 sn sonra konum KAYBOLUR; 8 sn sonra NVS\'e yazilmis olur ve korunur', async () => {
  const dir = tmpDir();
  try {
    const a = await make({ stateFile: path.join(dir, 'a.json') });
    try {
      post(a.sim, CmdType.SHUTTER_POS, 1, 40);
      run(a.sim, a.clock, 8300);
      assert.equal(shutter(a.sim, 1).pos, 40);
      run(a.sim, a.clock, 2000);                         // durdu, 8 sn dolmadi
      a.sim.powerCycle();
      await sleep(40);
      assert.equal(a.sim.booting, false);
      run(a.sim, a.clock, 50);
      assert.equal(shutter(a.sim, 1).pos, 0, 'yazilmamis konum guc kesintisinde kayip');
      assert.equal(a.sim.qaState().relays.every((r) => !r.state), true);
    } finally {
      await a.sim.stop({ graceful: false });
    }

    const b = await make({ stateFile: path.join(dir, 'b.json') });
    try {
      post(b.sim, CmdType.SHUTTER_POS, 1, 40);
      run(b.sim, b.clock, 8300);
      run(b.sim, b.clock, 8500);                         // hareket bittikten sonra >8 sn: NVS'e yazildi
      b.sim.powerCycle();
      await sleep(40);
      run(b.sim, b.clock, 50);
      assert.equal(shutter(b.sim, 1).pos, 40, 'NVS\'e yazilmis konum korunur');
    } finally {
      await b.sim.stop({ graceful: false });
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('acilis bekleme penceresi (500 ms): bu surede komutlar kuyrukta bekler, sonra uygulanir; HTTP/QA durumu pencerede de okunur', async () => {
  const { sim, clock } = await make({ bootHoldMs: 500 });
  try {
    post(sim, CmdType.RELAY_SET, 5, 1);
    run(sim, clock, 400);
    assert.equal(relayOn(sim, 5), false);
    assert.equal(sim.qaState().command_queue, 1);
    run(sim, clock, 200);
    assert.equal(relayOn(sim, 5), true);
    assert.equal(sim.qaState().command_queue, 0);
  } finally {
    await sim.stop();
  }
});

test('fiziksel gozlemci: surucu seviyesi ihlali (iki yon ayni anda / olu zaman) KAYDEDILIR; strict modda fatal isaretlenir', async () => {
  const { sim, clock } = await make();
  try {
    run(sim, clock, 700);
    // Gozlemciyi sistemin kendi emniyetinden bagimsiz sinamak icin donanim, loop() sonrasinda (gozlemden once) bozulur (hata enjeksiyonu)
    const a = sim.fw.automation;
    const realLoop = a.loop.bind(a);
    let inject = null;
    a.loop = (now) => { realLoop(now); if (inject !== null) a.tca.latch = inject; };
    inject = 0b11;                                       // cift 1: YUKARI+ASAGI birden
    run(sim, clock, 20);
    assert.ok(sim.qaState().violations.some((v) => v.code === 'both_on' && v.pair === 1), JSON.stringify(sim.qaState().violations));
    assert.match(sim.qaState().fatal, /interlock ihlali/);
    inject = 0;
    run(sim, clock, 20);
    inject = 0b01;                                       // kapandiktan ~20 ms sonra yeniden enerjilendi: olu zaman
    run(sim, clock, 20);
    assert.ok(sim.qaState().violations.some((v) => v.code === 'dead_time'), JSON.stringify(sim.qaState().violations));
  } finally {
    await sim.stop();
  }
});

test('QA: setDi aralik/ek modul denetimi; slow(drop) komutu dusurur; dusuren komut sayaca islenir', async () => {
  const { sim, clock } = await make();
  try {
    run(sim, clock, 700);
    assert.throws(() => sim.setDi(0, true), RangeError);
    assert.throws(() => sim.setDi(9, true), RangeError, '8 role: DI 9 yok');
    sim.setSlow({ drop: true });
    assert.equal(post(sim, CmdType.RELAY_SET, 5, 1), true, 'dusurulen komut cagiriciya "kuyruga alindi" gorunur');
    run(sim, clock, 100);
    assert.equal(relayOn(sim, 5), false);
    sim.setSlow({});
    post(sim, CmdType.RELAY_SET, 5, 1);
    run(sim, clock, 100);
    assert.equal(relayOn(sim, 5), true);
    const ext = await make({ relays: 16 });
    try {
      run(ext.sim, ext.clock, 700);
      assert.doesNotThrow(() => ext.sim.setDi(9, false));
    } finally {
      await ext.sim.stop();
    }
  } finally {
    await sim.stop();
  }
});

test('/__sim/state: acilis sirasinda en az alanlarla doner (booting=true), sonra tam durum', async () => {
  const { sim, clock } = await make({ bootMs: 30 });
  try {
    run(sim, clock, 700);
    sim.powerCycle();
    assert.equal(sim.qaState().booting, true);
    assert.equal('relays' in sim.qaState(), false);
    await sleep(80);
    assert.equal(sim.qaState().booting, false);
    assert.equal(sim.qaState().relays.length, 8);
    assert.ok(sim.events.some((e) => e.type === 'booted' && e.kind === 'power'));
  } finally {
    await sim.stop();
  }
});
