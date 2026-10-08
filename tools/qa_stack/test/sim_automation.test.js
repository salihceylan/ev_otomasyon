// Firmware SmartAutomation portu (sim/fw/automation.js) entegrasyon testleri: sanal saat, gercek ShutterFsm/DiGate/InterlockGuard portlari,
// bagimsiz fiziksel gozlemci (ihlal = iki yon ayni anda / dogrudan yon degisimi / <500 ms olu zaman).
import test from 'node:test';
import assert from 'node:assert/strict';
import { Rig, CmdType, CmdSource, makeCommand, NvsImage, makeExt } from './_rig.js';
import { DIMode, RelayType } from '../sim/fw/sysconfig.js';
import { buildWriteCoil, hexString, COIL_ON, COIL_OFF, COIL_TOGGLE } from '../sim/fw/modbus.js';

const T = CmdType;

test('automation: acilista roleler KAPALI; ilk 500 ms komutlar islenmez (kuyrukta bekler), sonra uygulanir', () => {
  const r = new Rig({ skipBootHold: false });
  assert.deepEqual(r.snap.relays.slice(0, 8), new Array(8).fill(false));
  r.cmd(T.RELAY_SET, 5, 1);
  r.run(400);
  assert.equal(r.relay(5), false, 'acilis bekleme penceresi (500 ms)');
  r.run(150);
  assert.equal(r.relay(5), true);
  assert.deepEqual(r.violations, []);
});

test('automation: lamba set/toggle; last_id yalniz BASARILI komutta yankilanir', () => {
  const r = new Rig();
  r.cmd(T.RELAY_SET, 5, 1, 'ok-1');
  r.run(30);
  assert.equal(r.relay(5), true);
  assert.equal(r.snap.lastId, 'ok-1');
  r.cmd(T.RELAY_TOGGLE, 5, 0, 'ok-2');
  r.run(30);
  assert.equal(r.relay(5), false);
  assert.equal(r.snap.lastId, 'ok-2');
  r.cmd(T.RELAY_SET, 99, 1, 'bad-1');           // aralik disi -> reddedilir
  r.run(30);
  assert.equal(r.snap.lastId, 'ok-2', 'reddedilen komut last_id yankilamaz');
  assert.ok(r.events.some((e) => e.type === 'cmd_rejected' && e.reason === 'invalid_relay'));
});

test('automation: ALL_LIGHTS_OFF yalniz LIGHT tipli roleleri kapatir; darbe rolesi suresi bitince kendi kapanir', () => {
  const r = new Rig({ configure: (cm) => { cm.config.relays[7].type = RelayType.IMPULSE; cm.config.relays[7].runtime_sec = 1000; } });
  for (const n of [5, 6, 7, 8]) r.cmd(T.RELAY_SET, n, 1);
  r.run(100);
  assert.deepEqual([5, 6, 7, 8].map((n) => r.relay(n)), [true, true, true, true]);
  r.cmd(T.ALL_LIGHTS_OFF);
  r.run(100);
  assert.deepEqual([5, 6, 7].map((n) => r.relay(n)), [false, false, false]);
  assert.equal(r.relay(8), true, 'darbe rolesi toplu kapatmadan etkilenmez');
  r.run(1000);
  assert.equal(r.relay(8), false, 'darbe suresi (1000 ms) doldu');
});

test('automation: tam yukari = 20 sn + 2 sn overrun; konum yuzde olarak ilerler; sonunda %100 ve roleler kapali; ihlal yok', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 1);
  r.run(30);
  assert.equal(r.relay(1), true);
  assert.equal(r.relay(2), false);
  assert.equal(r.shutter(1).moving, true);
  assert.equal(r.shutter(1).dir, 1);
  assert.equal(r.shutter(1).target, 100);
  const start = r.a.fsm[0].startMs();
  r.runUntil(() => r.t - start >= 10000, 20000);   // hareketin 10. sn'si
  assert.equal(r.shutter(1).pos, 50);
  r.runUntil(() => r.t - start >= 20000, 20000);   // 20. sn: konum 100 ama role limit oturmasi icin hala enerjili
  assert.equal(r.shutter(1).pos, 100);
  assert.equal(r.relay(1), true);
  r.run(2100);
  assert.equal(r.relay(1), false);
  assert.equal(r.shutter(1).moving, false);
  assert.equal(r.shutter(1).pos, 100);
  assert.deepEqual(r.violations, []);
  assert.ok(r.events.some((e) => e.type === 'shutter_completed'));
});

test('automation: ters yon komutu once keser, 500 ms olu zaman sonra kalkar; konum sureklidir; ihlal yok', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 1);
  r.run(30);
  const start = r.a.fsm[0].startMs();
  r.runUntil(() => r.t - start >= 5000, 20000);
  assert.equal(r.shutter(1).pos, 25);
  r.cmd(T.SHUTTER_DOWN, 1);
  r.run(20);
  assert.equal(r.relay(1), false, 'yukari hemen kesildi');
  assert.equal(r.relay(2), false, 'olu zaman: asagi henuz yok');
  assert.equal(r.shutter(1).waiting, true);
  r.run(400);
  assert.equal(r.relay(2), false);
  r.run(120);
  assert.equal(r.relay(2), true, '500 ms sonra asagi');
  assert.equal(r.shutter(1).waiting, false);
  assert.ok(r.shutter(1).pos <= 25 && r.shutter(1).pos >= 24, `konum surekli: ${r.shutter(1).pos}`);
  assert.deepEqual(r.violations, []);
});

test('automation: konum komutu (%50) orantili sure, hedefte durur (overrun yok); step yonu konuma gore secer', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_POS, 1, 50);
  r.run(30);
  assert.equal(r.shutter(1).target, 50);
  assert.equal(r.relay(1), true);
  r.run(9900);
  assert.equal(r.shutter(1).moving, true);
  r.run(200);
  assert.equal(r.shutter(1).moving, false);
  assert.equal(r.shutter(1).pos, 50);
  r.run(600);
  r.cmd(T.SHUTTER_STEP, 1);                       // arada, son yon YUKARI -> simdi ASAGI
  r.run(30);
  assert.equal(r.relay(2), true);
  assert.deepEqual(r.violations, []);
});

test('automation: yetim panjur rolesi (eslesmeyen UP/DOWN) panjur sayilmaz: komut reddedilir, role HER ZAMAN kapali', () => {
  const r = new Rig({ configure: (cm) => { cm.config.relays[1].type = RelayType.LIGHT; cm.config.relays[1].runtime_sec = 0; } });
  assert.equal(r.shutter(1).configured, false);
  r.cmd(T.SHUTTER_UP, 1, 0, 'x-1');
  r.cmd(T.RELAY_SET, 1, 1, 'x-2');
  r.run(200);
  assert.equal(r.relay(1), false);
  assert.equal(r.snap.lastId, '');
  assert.ok(r.events.some((e) => e.type === 'cmd_rejected' && e.reason === 'not_a_shutter_pair'));
  assert.ok(r.events.some((e) => e.type === 'cmd_rejected' && e.reason === 'orphan_shutter_relay'));
});

test('automation: cocuk kilidi YALNIZ duvar butonlarini engeller; uygulama komutlari serbest; kilitliyken duvar HAREKETLI panjuru durdurabilir', () => {
  const r = new Rig();
  r.cmd(T.SET_CHILD_LOCK, 0, 1);
  r.run(30);
  assert.equal(r.snap.childLock, true);
  assert.equal(r.nvs.get('auto').child_lock, true, 'kilit NVS\'e yazildi');
  r.press(5);                                     // DI5 toggle -> role 5: engelli
  assert.equal(r.relay(5), false);
  assert.ok(r.beeps.some((b) => b.reason === 'child_lock_blocked'));
  r.press(1);                                     // DI1 panjur STEP, panjur duragan: BASLATMAZ
  assert.equal(r.shutter(1).moving, false);
  r.cmd(T.SHUTTER_UP, 1);                         // uygulamadan serbest
  r.run(500);
  assert.equal(r.shutter(1).moving, true);
  r.press(1);                                     // kilitli ama panjur hareketli: duvardan DURDURULUR
  assert.equal(r.shutter(1).moving, false);
  assert.deepEqual(r.violations, []);
});

test('automation: momentary -- kilit basili tutarken devreye girse de birakma roleyi KAPATIR; kilitle dusen basista kilit kalkarsa bayat KAPAT uretilmez', () => {
  const r = new Rig({ configure: (cm) => { cm.config.dis[5].mode = DIMode.MOMENTARY; cm.config.dis[5].target_relay = 6; } });
  r.a.setRawDi(5, true);
  r.run(120);
  assert.equal(r.relay(6), true, 'basili iken role acik');
  r.cmd(T.SET_CHILD_LOCK, 0, 1);
  r.run(30);
  r.a.setRawDi(5, false);
  r.run(120);
  assert.equal(r.relay(6), false, 'birakma kilitliyken de roleyi kapatir');

  r.cmd(T.SET_CHILD_LOCK, 0, 0);
  r.cmd(T.RELAY_SET, 6, 1);                       // uygulamadan acilmis lamba
  r.run(60);
  r.cmd(T.SET_CHILD_LOCK, 0, 1);
  r.run(30);
  r.a.setRawDi(5, true);                          // kilitli: engellenen basis
  r.run(120);
  r.cmd(T.SET_CHILD_LOCK, 0, 0);
  r.run(30);
  r.a.setRawDi(5, false);
  r.run(120);
  assert.equal(r.relay(6), true, 'bayat KAPAT uretilmedi: uygulamadan acilan lamba soenmedi');
});

test('automation: varsayilan DI davranisi -- DI5 toggle role 5; DI1 panjur 1 STEP (basinca hareket, tekrar basinca DUR)', () => {
  const r = new Rig();
  r.press(5);
  assert.equal(r.relay(5), true);
  r.press(5);
  assert.equal(r.relay(5), false);
  r.press(1);
  assert.equal(r.shutter(1).moving, true);
  assert.equal(r.shutter(1).dir, 1, 'konum 0 -> yukari');
  r.run(2000);
  r.press(1);
  assert.equal(r.shutter(1).moving, false);
  assert.ok(r.shutter(1).pos > 0 && r.shutter(1).pos < 100);
  assert.equal(r.di(1), false, 'birakildi: durum kararli olarak kapali');
  assert.deepEqual(r.violations, []);
});

test('automation: DI durumu 60 ms suzgecinden sonra kararli (state.dis); 60 ms altindaki parazit kenar uretmez', () => {
  const r = new Rig();
  r.a.setRawDi(4, true);
  r.run(40);
  r.a.setRawDi(4, false);                         // 40 ms: parazit
  r.run(200);
  assert.equal(r.di(5), false);
  assert.equal(r.relay(5), false, 'parazit role tetiklemedi');
  r.a.setRawDi(4, true);
  r.run(100);
  assert.equal(r.di(5), true);
});

test('automation: panjur konumu NVS\'e hareket bittikten ~8 sn sonra yazilir; yeniden acilista geri yuklenir', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_POS, 1, 50);
  r.run(10200);
  assert.equal(r.shutter(1).pos, 50);
  assert.equal(r.nvs.get('pos'), null, 'henuz yazilmadi (8 sn gecikme)');
  r.run(8100);
  assert.equal(r.nvs.get('pos')[0], 50);
  r.coldBoot();
  assert.equal(r.shutter(1).pos, 50, 'konum geri yuklendi');
  assert.equal(r.relay(1), false);
  assert.deepEqual(r.snap.relays.slice(0, 8), new Array(8).fill(false), 'elektrik gelince tum roleler KAPALI');
});

test('automation: guc kesintisi hareket bittikten hemen sonra olursa son konum KAYBOLUR (NVS gecikmeli yazim); planli yeniden baslatma konumu zorla yazar', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_POS, 1, 40);
  r.run(8300);
  assert.equal(r.shutter(1).pos, 40);
  r.run(2000);                                    // durdu, ama 8 sn dolmadi
  r.coldBoot();                                   // ani elektrik kesintisi
  assert.equal(r.shutter(1).pos, 0, 'yazilmamis konum kayip');

  const r2 = new Rig();
  r2.cmd(T.SHUTTER_POS, 1, 40);
  r2.run(8300);
  r2.run(500);
  r2.a.requestRestart(600, r2.t);
  r2.run(800);
  assert.equal(r2.restarts, 1);
  assert.equal(r2.preRestarts, 1);
  assert.equal(r2.nvs.get('pos')[0], 40, 'planli yeniden baslatma konumu zorla yazar');
});

test('automation: planli yeniden baslatma -- hareket eden panjur HEMEN durur; bekleme suresince yeni komut islenmez; sure dolunca restart kancasi', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 1);
  r.run(3000);
  assert.equal(r.shutter(1).moving, true);
  r.a.requestRestart(600, r.t);
  r.cmd(T.RELAY_SET, 5, 1);                       // bekleme suresince komut islenmez
  r.run(30);
  assert.equal(r.shutter(1).moving, false, 'panjur cagri aninda durdu');
  assert.equal(r.relay(1), false);
  r.run(500);
  assert.equal(r.relay(5), false);
  assert.equal(r.restarts, 0);
  r.run(100);
  assert.equal(r.restarts, 1);
  assert.equal(r.preRestarts, 1);
  assert.deepEqual(r.violations, []);
});

test('automation: komut kuyrugu 24 ile sinirli (taşan komut false); DURDURMA kuyruk dolu olsa bile KAYBOLMAZ (acil durdurma bayragi)', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 1);
  r.run(1000);
  assert.equal(r.shutter(1).moving, true);
  // kuyrugu loop() bosaltmadan doldur
  let accepted = 0;
  for (let i = 0; i < 40; i++) if (r.cmd(T.RELAY_TOGGLE, 6)) accepted++;
  assert.equal(accepted, 24);
  assert.equal(r.cmd(T.SHUTTER_STOP, 1), false, 'kuyruk dolu: false ama acil bayrak kuruldu');
  r.run(30);
  assert.equal(r.shutter(1).moving, false, 'durdurma kaybolmadi');
});

test('automation: komut kuyrugu FIFO -- DURDURMA one gecmez; ayni turdaki "YUKARI, sonra DURDUR" cifti DURDURMA ile biter', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 1);
  r.cmd(T.RELAY_SET, 5, 1);
  r.cmd(T.ALL_SHUTTERS_STOP);
  assert.deepEqual(r.a.queue.map((c) => c.type), [T.SHUTTER_UP, T.RELAY_SET, T.ALL_SHUTTERS_STOP], 'gelis sirasi korunur');
  r.run(40);
  assert.equal(r.shutter(1).moving, false, 'kullanicinin SON niyeti DURDURMA');
  assert.equal(r.relay(1), false, 'YUKARI rolesi hic enerjilenmedi');
  assert.equal(r.relay(5), true, 'aradaki lamba komutu uygulandi');
  assert.deepEqual(r.violations, []);
});

test('automation: kuyruk doluyken DURDURMA once hemen, kuyruk bosalinca bir kez daha uygulanir (onceden kuyruktaki YUKARI sonucu ezemez)', () => {
  const r = new Rig();
  for (let i = 0; i < 23; i++) assert.equal(r.cmd(T.RELAY_TOGGLE, 6), true);
  assert.equal(r.cmd(T.SHUTTER_UP, 1), true, '24. komut kuyrugu doldurur');
  assert.equal(r.cmd(T.SHUTTER_STOP, 1), false, 'kuyruk dolu: yazilamadi');
  assert.equal(r.a.emergencyStopAll, true, 'acil durdurma bayragi kuruldu');
  assert.equal(r.a.cmdDropped, 1);
  r.run(10);                                      // 1. tur: hemen durdur + 12 komut + (bosalmadi) bayrak korunur + tekrar durdur
  assert.equal(r.a.queue.length, 12);
  assert.equal(r.a.emergencyStopAll, true);
  r.run(10);                                      // 2. tur: kalan 12 (YUKARI dahil) yurutulur; tur 12 komutla bittigi icin "bosaldi" kesinlesmez (firmware ayni)
  assert.equal(r.a.queue.length, 0);
  assert.equal(r.a.emergencyStopAll, true, 'tam 12 komut kaldiysa bir tur daha');
  r.run(10);                                      // 3. tur: kuyruk bos -> bayrak temizlenir, son DURDURMA
  assert.equal(r.a.emergencyStopAll, false);
  r.run(100);
  assert.equal(r.shutter(1).moving, false, 'YUKARI komutu yurutulse de son DURDURMA kazandi');
  assert.equal(r.relay(1), false);
  assert.equal(r.eventsOf('queue_full_stop').length, 3);
  assert.deepEqual(r.violations, []);
});

test('automation: emniyet gorevi suresi ENERJILENDIGI andan sayilir; ayni yonde yeniden hedefleme emniyet suresini uzatmaz (ust sinir: tam yol + oturma payi)', () => {
  const r = new Rig({ timeScale: 10 });             // 20 sn yol -> 2 sn, oturma payi 2 sn -> 0,2 sn
  r.cmd(T.SHUTTER_POS, 1, 60);
  r.run(30);
  const f = r.a.fsm[0];
  const g0 = { ...r.a.guards[0] };
  assert.equal(g0.armed, true);
  assert.equal(g0.start, f.runStartMs(), 'sayim enerjilenme anindan');
  r.run(500);
  r.cmd(T.SHUTTER_POS, 1, 100);                     // ayni yon, yeni hedef: FSM start_ms_ yeniden damgalar
  r.run(30);
  const g1 = r.a.guards[0];
  assert.equal(f.isMoving(), true);
  assert.ok(f.startMs() !== f.runStartMs(), 'start_ms_ ilerledi ama run_start_ ayni');
  assert.equal(g1.start, g0.start, 'yeniden hedefleme baslangic damgasini ilerletmez');
  assert.ok(g1.maxRun <= f.runCapMs() + 1500, `emniyet suresi tam yol + oturma payi + marji asmaz (${g1.maxRun} > ${f.runCapMs() + 1500})`);
  r.runUntil(() => !f.isMoving(), 10000);
  assert.equal(r.shutter(1).pos, 100);
  assert.equal(r.a.guards[0].armed, false, 'durunca emniyet bozuldu');
  assert.equal(r.eventsOf('safety_guard_trip').length, 0);
  assert.deepEqual(r.violations, []);
});

test('automation: SET_RUNTIME hareket sirasinda reddedilir; duragansa iki role kaydedilir ve sonraki tam hareket yeni sureyle calisir', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 1);
  r.run(500);
  r.cmd(T.SET_RUNTIME, 1, 10, 'rt-busy');
  r.run(30);
  assert.ok(r.events.some((e) => e.type === 'cmd_rejected' && e.reason === 'shutter_busy'));
  r.cmd(T.SHUTTER_STOP, 1);
  r.run(700);
  r.cmd(T.SET_RUNTIME, 1, 10, 'rt-ok');
  r.run(30);
  assert.equal(r.snap.lastId, 'rt-ok');
  assert.equal(r.cm.config.relays[0].runtime_sec, 10);
  assert.equal(r.cm.config.relays[1].runtime_sec, 10);
  assert.equal(r.nvs.get('cfg').r_rt_0, 10);
  assert.equal(r.nvs.get('cfg').r_rt_1, 10);
  r.cmd(T.SHUTTER_DOWN, 1);                       // konum ~2: asagi tam hareket 10 sn + 2 sn overrun
  r.run(30);
  assert.equal(r.a.fsm[0].durationMs(), 12000);
});

test('automation: time-scale yalniz panjur yol/overrun suresini olcekler; 500 ms olu zaman sabit kalir', () => {
  const r = new Rig({ timeScale: 10 });
  r.cmd(T.SHUTTER_UP, 1);
  r.run(30);
  const start = r.a.fsm[0].startMs();
  r.runUntil(() => r.t - start >= 2000, 5000);
  assert.equal(r.shutter(1).pos, 100);
  assert.equal(r.relay(1), true);
  r.run(300);
  assert.equal(r.relay(1), false, '2 sn + 0,2 sn overrun');
  r.cmd(T.SHUTTER_DOWN, 1);
  r.run(20);
  assert.equal(r.relay(2), false);
  r.run(520);
  assert.equal(r.relay(2), true, 'olu zaman 500 ms (olceklenmedi)');
  assert.deepEqual(r.violations, []);
});

test('automation: yapilandirma degisip cift gecersizlesirse hareket DURDURULUR, roleler kapanir', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 1);
  r.run(2000);
  assert.equal(r.relay(1), true);
  r.cm.config.relays[1].type = RelayType.LIGHT;   // eslesme bozuldu
  r.run(50);
  assert.equal(r.shutter(1).configured, false);
  assert.equal(r.shutter(1).moving, false);
  assert.equal(r.relay(1), false);
  assert.ok(r.events.some((e) => e.type === 'shutter_pair_invalidated'));
  assert.deepEqual(r.violations, []);
});

test('automation: I2C yazim arizasi -- role degismez, panjur baslamaz (konum korunur); ariza gidince islemler surer', () => {
  const r = new Rig();
  r.a.tca.i2cFail = true;
  r.cmd(T.RELAY_SET, 5, 1);
  r.cmd(T.SHUTTER_UP, 1);
  r.run(600);
  assert.equal(r.relay(5), false);
  assert.equal(r.relay(1), false);
  assert.equal(r.shutter(1).moving, false, 'enerjileme basarisiz: hareket iptal');
  assert.ok(r.events.some((e) => e.type === 'shutter_start_failed'));
  assert.equal(r.shutter(1).pos, 0);
  r.a.tca.i2cFail = false;
  r.run(1000);                                    // olu zaman + yeniden deneme
  r.cmd(T.SHUTTER_UP, 1);
  r.run(700);
  assert.equal(r.relay(5), true, 'lamba istegi hala gecerli: ariza gidince uygulandi');
  assert.equal(r.relay(1), true);
  assert.deepEqual(r.violations, []);
});

// ------------------------------------------------------------------ ek modul (RS485)
test('automation: ek modul -- yanit veriyor, ek roleler (9..16) calisir; panjur cifti ek modulde de interlock\'lu', () => {
  const ext = makeExt(8);
  const r = new Rig({
    ext,
    configure: (cm) => {
      cm.config.ext_module_enabled = true;
      cm.config.ext_module_channels = 8;
      cm.config.relays[8].type = RelayType.SHUTTER_UP; cm.config.relays[8].runtime_sec = 20;
      cm.config.relays[9].type = RelayType.SHUTTER_DOWN; cm.config.relays[9].runtime_sec = 20;
    },
  });
  r.run(400);
  assert.equal(r.snap.totalRelays, 16);
  assert.equal(r.snap.extModuleResponding, true);
  assert.equal(r.shutter(5).configured, true);
  r.cmd(T.RELAY_SET, 11, 1);
  r.run(300);
  assert.equal(r.relay(11), true);
  assert.equal(ext.coils[2], true, 'ek modul coil\'i fiziksel olarak acildi');
  r.cmd(T.SHUTTER_UP, 5);
  r.run(300);
  assert.equal(r.relay(9), true);
  r.cmd(T.SHUTTER_DOWN, 5);
  r.run(100);
  assert.equal(r.relay(9), false);
  assert.equal(r.relay(10), false, 'olu zaman');
  r.run(700);
  assert.equal(r.relay(10), true);
  assert.deepEqual(r.violations, []);
});

test('automation: ek modul yapilandirmada acik ama bagli degil -- yanit vermiyor, ek roleler enerjilenmez, panjur baslatma iptal', () => {
  const ext = makeExt(0);
  const r = new Rig({
    ext,
    configure: (cm) => {
      cm.config.ext_module_enabled = true;
      cm.config.ext_module_channels = 8;
      cm.config.relays[8].type = RelayType.SHUTTER_UP; cm.config.relays[8].runtime_sec = 20;
      cm.config.relays[9].type = RelayType.SHUTTER_DOWN; cm.config.relays[9].runtime_sec = 20;
    },
  });
  r.run(3000);
  assert.equal(r.snap.extModuleResponding, false);
  r.cmd(T.RELAY_SET, 11, 1);
  r.cmd(T.SHUTTER_UP, 5);
  r.run(1500);
  assert.equal(ext.coils.some(Boolean), false, 'hicbir ek modul rolesi fiziksel olarak enerjilenmedi');
  assert.equal(r.a.hwKnown[10], false, 'ek role durumu DOGRULANAMADI');
  // firmware: dogrulanamayan ek roleler "acik olabilir" varsayilir ve state'te ACIK raporlanir (guvenli taraf), KAPAT yeniden gonderilir
  assert.equal(r.relay(11), true);
  assert.equal(r.shutter(5).moving, false, 'panjur baslamadi (esin KAPALI oldugu dogrulanamadi)');
  assert.equal(r.shutter(5).waiting, true, 'istek kuyrukta bekliyor');
  assert.deepEqual(r.violations, []);
});

test('automation: ek modul girisleri (DI 9..16) ayni DiGate kapisindan gecer; cocuk kilidi ek modul butonunu da engeller', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: (cm) => { cm.config.ext_module_enabled = true; cm.config.ext_module_channels = 8; cm.config.dis[8].target_relay = 12; cm.config.dis[8].mode = DIMode.TOGGLE; } });
  r.run(600);
  ext.rawDi[0] = true;                            // DI 9 kapali
  r.run(400);
  ext.rawDi[0] = false;
  r.run(400);
  assert.equal(r.relay(12), true, 'DI9 toggle role 12');
  r.cmd(T.SET_CHILD_LOCK, 0, 1);
  r.run(50);
  ext.rawDi[0] = true;
  r.run(400);
  ext.rawDi[0] = false;
  r.run(400);
  assert.equal(r.relay(12), true, 'kilitli: ek modul butonu role degistirmedi');
  assert.ok(r.beeps.some((b) => b.reason === 'child_lock_blocked'));
});

// ------------------------------------------------------------------ ek modul: panjur oncesi geri okuma, ham komutlar, tarama
const extShutter = (cm) => {
  cm.config.ext_module_enabled = true;
  cm.config.ext_module_channels = 8;
  cm.config.relays[8].type = RelayType.SHUTTER_UP; cm.config.relays[8].runtime_sec = 20;
  cm.config.relays[9].type = RelayType.SHUTTER_DOWN; cm.config.relays[9].runtime_sec = 20;
};

test('automation: ek modul panjur -- AC\'MADAN once modulun GERCEK coil durumu okunur; es baska bir master tarafindan acilmissa hareket iptal, es kapatilir', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  assert.equal(r.snap.extModuleResponding, true);
  ext.coils[1] = true;                              // baska bir Modbus master DOWN kanalini acti; firmware henuz yoklamadi (inanc: kapali)
  assert.equal(r.a.hw[9], false, 'inanc: KAPALI');
  r.cmd(T.SHUTTER_UP, 5);
  r.run(40);
  assert.equal(ext.coils[0], false, 'YUKARI rolesi ASLA enerjilenmedi (es acikken)');
  assert.equal(r.eventsOf('shutter_start_failed').length, 1, 'hareket iptal edildi');
  assert.equal(r.eventsOf('ext_interlock_peer_on').length, 1);
  r.run(300);
  assert.equal(ext.coils[1], false, 'es sonraki turda KAPATILDI');
  assert.equal(r.shutter(5).moving, false);
  assert.deepEqual(r.violations, []);
});

test('automation: ek modul panjur -- hedef role modulde zaten ACIKSA ("kapali" saniliyordu) hareket iptal edilir ve role kapatilir (calisiyor sayilmaz)', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  ext.coils[0] = true;                              // YUKARI kanali modulde zaten acik (inanc: kapali): onceki KAPAT uygulanmamis olabilir
  r.cmd(T.SHUTTER_UP, 5);
  r.run(40);
  assert.equal(r.eventsOf('ext_interlock_self_on').length, 1);
  assert.equal(r.eventsOf('shutter_start_failed').length, 1, 'hareket iptal edildi');
  r.run(300);
  assert.equal(ext.coils[0], false, 'beklenmedik ACIK role sonraki turda KAPATILDI');
  assert.equal(r.shutter(5).moving, false);
  assert.deepEqual(r.violations, []);
});

test('automation: ek modul panjur -- geri okuma BASARISIZSA yazma basarisizligi gibi islenir (hareket iptal, geri cekilme)', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  ext.failWrites = true;                            // modul susar; firmware henuz fark etmedi
  r.cmd(T.SHUTTER_UP, 5);
  r.run(40);
  assert.equal(r.eventsOf('shutter_start_failed').length, 1);
  assert.equal(ext.coils[0], false);
  assert.ok(r.a.extWriteFails >= 1);
  assert.deepEqual(r.violations, []);
});

test('automation: ham ek modul komutu -- panjur kanalina/toplu ACMAYA ret; panjur disi kanal acilir ve inanc guncellenir', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  const noShutter = r.a.rs485ControlExtRelay(1, 1, 1, r.t);
  assert.equal(noShutter.ok, false, 'kanal 1 = panjur YUKARI');
  assert.equal(r.a.rs485ControlExtRelay(1, 0, 1, r.t).ok, false, 'toplu ACMA yasak');
  assert.equal(r.a.rs485ControlExtRelay(1, 3, 3, r.t).ok, false, 'gecersiz eylem');
  assert.equal(r.a.rs485ControlExtRelay(1, 33, 1, r.t).ok, false, 'gecersiz kanal');
  const logs = r.a.rs485GetLogs();
  assert.match(logs, /\[RED\] Panjur kanalina ham ACMA\/TOGGLE yasak/);
  assert.match(logs, /\[RED\] Toplu ACMA/);
  const ok = r.a.rs485ControlExtRelay(1, 3, 1, r.t);
  assert.equal(ok.ok, true);
  assert.equal(ok.responseHex, hexString(buildWriteCoil(1, 2, COIL_ON)), 'yanki cercevesi (CRC dahil)');
  assert.equal(ext.coils[2], true);
  assert.equal(r.a.want[10], true);
  assert.equal(r.a.hw[10], true);
  r.run(100);
  assert.equal(r.relay(11), true);
  assert.match(r.a.rs485GetLogs(), /\[EXT ROLE\] Slave 1 CH3 Eylem:1 -> OK/);
  // KAPAT serbest; baska slave'e ham yazim uygulama durumunu etkilemez
  assert.equal(r.a.rs485ControlExtRelay(1, 3, 0, r.t).ok, true);
  assert.equal(ext.coils[2], false);
  assert.equal(r.a.rs485ControlExtRelay(7, 3, 1, r.t).ok, false, 'baska slave yanit vermez');
  assert.equal(r.a.rs485ControlExtRelay(7, 3, 1, r.t).responseHex, '');
  assert.deepEqual(r.violations, []);
});

test('automation: ham TOGGLE -- sonuc bilinmez (inanc "bilinmiyor" + benimse bayragi); TOGGLE ile acilan role GERI KAPANMAZ, coil okumasinda benimsenir; ikinci TOGGLE kapatir', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  assert.equal(r.a.rs485ControlExtRelay(1, 4, 2, r.t).ok, true);
  assert.equal(ext.coils[3], true, 'toggle modulde uygulandi');
  assert.equal(r.a.hwKnown[11], false);
  assert.equal(r.a.adoptNextPoll[11], true);
  // F12 duzeltmesi: stepExtOutputs 1. gecis benimse-bekleyen ("bilinmeyen + istenmeyen") roleyi KAPATMAZ (eskiden ~1 turda geri kapanirdi)
  r.run(30);
  assert.equal(ext.coils[3], true, 'TOGGLE ile acilan role geri kapanmadi');
  r.run(600);
  assert.equal(r.a.want[11], true, 'durum benimsendi: istenen = ACIK');
  assert.equal(r.a.adoptNextPoll[11], false);
  assert.equal(r.relay(12), true);
  r.run(3000);
  assert.equal(ext.coils[3], true, 'kalici ACIK');
  // ikinci TOGGLE ACIK rolyi kapatir ve benimsenir
  assert.equal(r.a.rs485ControlExtRelay(1, 4, 2, r.t).ok, true);
  assert.equal(ext.coils[3], false, 'toggle ACIK rolyi kapatti');
  r.run(30);
  assert.equal(ext.coils[3], false);
  r.run(1800);
  assert.equal(r.a.want[11], false, 'benimsendi');
  assert.equal(r.relay(12), false);
  assert.equal(ext.coils[3], false);
  // kalici ACMA/KAPATMA icin action=1/0 (want'i dogrudan gunceller) hala calisir
  assert.equal(r.a.rs485ControlExtRelay(1, 4, 1, r.t).ok, true);
  r.run(2000);
  assert.equal(ext.coils[3], true);
  assert.equal(r.a.rs485ControlExtRelay(1, 4, 0, r.t).ok, true);
  r.run(2000);
  assert.equal(ext.coils[3], false);
  assert.deepEqual(r.violations, []);
});

test('automation: ham TOGGLE benimse-yoklamasi modul susmusken tamamlanamaz: role ACIK kalir (yalnizca o rolenin KAPAT yazimi atlanir), modul donunce benimsenir', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  assert.equal(r.a.rs485ControlExtRelay(1, 4, 2, r.t).ok, true);
  ext.failWrites = true;                            // modul susar (kablo kopar): benimse-yoklamasi yapilamaz
  r.run(3000);
  ext.failWrites = false;                           // modul geri gelir
  assert.equal(ext.coils[3], true, 'sessizlik boyunca role kapatilmadi (KAPAT zaten gonderilemezdi)');
  r.run(8000);
  assert.equal(ext.coils[3], true, 'donunce durum benimsendi, role acik kaldi');
  assert.equal(r.a.want[11], true);
  assert.equal(r.relay(12), true);
});

test('automation: [F12] ham TOGGLE sonrasi (benimse bekliyor) gelen acik komut bekleyen benimsemeyi GECERSIZ kilar: modul sustuktan sonra donunce kullanicinin son istegi (KAPALI) kazanir', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  assert.equal(r.a.rs485ControlExtRelay(1, 4, 2, r.t).ok, true);   // kanal 4 TOGGLE: modulde ACIK, benimse bekliyor
  assert.equal(r.a.adoptNextPoll[11], true);
  ext.failWrites = true;                                           // modul susar: coil yoklamasi basarisiz, benimseme gerceklesemez
  r.cmd(T.RELAY_SET, 12, 0);                                       // kullanici: KAPAT
  r.run(1500);
  assert.equal(ext.coils[3], true, 'modul sessiz: KAPAT uygulanamadi');
  assert.equal(r.a.adoptNextPoll[11], false, 'acik komut bekleyen benimsemeyi gecersiz kildi');
  ext.failWrites = false;                                          // modul geri geldi
  r.run(5000);
  assert.equal(ext.coils[3], false, 'son istek (KAPAT) uygulandi; eskiden coil yoklamasi fiziksel ACIK durumu benimser, KAPAT kaybolurdu');
  assert.equal(r.relay(12), false);
  // ayni durum ALL_LIGHTS_OFF ile
  assert.equal(r.a.rs485ControlExtRelay(1, 5, 2, r.t).ok, true);
  ext.failWrites = true;
  r.cmd(T.ALL_LIGHTS_OFF);
  r.run(1500);
  ext.failWrites = false;
  r.run(5000);
  assert.equal(ext.coils[4], false);
  assert.equal(r.relay(13), false);
  assert.deepEqual(r.violations, []);
});

test('automation: ham KAPAT hareket eden ek panjuru durdurur ve olu zaman o andan sayilir (rele yeniden ACILMAZ)', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  r.cmd(T.SHUTTER_UP, 5);
  r.run(600);
  assert.equal(ext.coils[0], true);
  assert.equal(r.a.rs485ControlExtRelay(1, 1, 0, r.t).ok, true);
  assert.equal(r.a.fsm[4].isMoving(), false, 'FSM de durduruldu (aksi halde cikis katmani roleyi yeniden acardi)');
  r.cmd(T.SHUTTER_DOWN, 5);
  r.run(100);
  assert.equal(ext.coils[1], false, 'olu zaman: ham KAPAT anindan 500 ms dolmadi');
  assert.equal(ext.coils[0], false);
  r.run(900);
  assert.equal(ext.coils[1], true);
  assert.equal(ext.coils[0], false);
  assert.deepEqual(r.violations, []);
});

test('automation: ham gonderim (rs485Send) -- dogrulama kurallari, panjur kanalina ham ACMA yasak, gunluk cizgesi', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  r.a.rs485ClearLogs();
  assert.equal(r.a.rs485Send('01 03 0', true, r.t), false, 'tek sayida hex hanesi');
  assert.equal(r.a.rs485Send('01 03', true, r.t), false, 'cok kisa');
  assert.equal(r.a.rs485Send('01 10 00 00 00 01', true, r.t), false, 'yasak islev (0x10)');
  assert.equal(r.a.rs485Send('01 05 00 00 FF 00 8C 3A', true, r.t), false, 'panjur kanalina (kanal 1) ham ACMA');
  assert.equal(r.a.rs485Send('01 05 00 FF FF 00 00 00', true, r.t), false, 'toplu ACMA');
  assert.equal(r.a.rs485Send('abc\u0001', false, r.t), false, 'ASCII kontrol karakteri');
  let l = r.a.rs485GetLogs();
  assert.match(l, /\[Hata\] Gecersiz HEX verisi/);
  assert.match(l, /\[RED\] Cerceve cok kisa/);
  assert.match(l, /\[RED\] Bu Modbus islevi ham gonderimde yasak/);
  assert.match(l, /\[RED\] Panjur kanalina ham ACMA yasak/);
  assert.match(l, /\[RED\] Toplu ACMA \(adres 0x00FF\)/);
  assert.match(l, /\[RED\] ASCII gonderimde/);
  assert.ok(l.split('\n').every((x) => x === '' || /^\[\d\d:\d\d:\d\d\] /.test(x)), 'her satir [SA:DD:SN] onekli');
  r.a.rs485ClearLogs();
  // gecerli okuma: modul yanit verir -> TX + RX satirlari
  assert.equal(r.a.rs485Send('01 01 00 00 00 08 3D CC', true, r.t), true);
  l = r.a.rs485GetLogs();
  assert.match(l, /\[TX HEX\] 01 01 00 00 00 08 3D CC/);
  assert.match(l, /\[RX\] HEX: 01 01 01 00 /);
  // CRC hatali cerceve: gonderim basarili sayilir (firmware yanit beklemez) ama modul susar -> RX satiri yok
  r.a.rs485ClearLogs();
  assert.equal(r.a.rs485Send('01 01 00 00 00 08 00 00', true, r.t), true);
  assert.doesNotMatch(r.a.rs485GetLogs(), /\[RX\]/);
  // F12: panjur disi kanalda ham 0x05 ACMA gecerlidir, MODULDE uygulanir VE uygulama durumuna yansir (RELAY_SET kuyruga yazilir):
  // eskiden "istenen" durum (want) degismedigi icin coil yoklamasinda (<= ~1,5 sn) role geri KAPATILIRDI
  assert.equal(r.a.rs485Send(hexString(buildWriteCoil(1, 2, COIL_ON)), true, r.t), true);
  assert.equal(ext.coils[2], true, 'ham yazim modulde uygulandi');
  r.run(2500);
  assert.equal(ext.coils[2], true, 'ham ACMA artik geri kapatilmaz (istenen durum = ACIK)');
  assert.equal(r.relay(11), true);
  assert.equal(r.a.want[10], true);
  // ham KAPAT ve ham TOGGLE de yansir
  assert.equal(r.a.rs485Send(hexString(buildWriteCoil(1, 2, COIL_OFF)), true, r.t), true);
  r.run(2500);
  assert.equal(ext.coils[2], false);
  assert.equal(r.relay(11), false);
  assert.equal(r.a.rs485Send(hexString(buildWriteCoil(1, 5, COIL_TOGGLE)), true, r.t), true);
  r.run(2500);
  assert.equal(ext.coils[5], true, 'ham TOGGLE: kalici ACIK');
  assert.equal(r.a.want[13], true);
  r.cmd(T.ALL_LIGHTS_OFF);
  r.run(1500);
  assert.equal(ext.coils[5], false, 'uygulama komutu hala etkili');
  assert.deepEqual(r.violations, []);
  // modul yok: dogrulamayi gecen cerceve yine true (yanit yok)
  const none = new Rig({ ext: makeExt(0), configure: extShutter });
  none.run(1000);
  none.a.rs485ClearLogs();
  assert.equal(none.a.rs485Send('01 01 00 00 00 08 3D CC', true, none.t), true);
  assert.doesNotMatch(none.a.rs485GetLogs(), /\[RX\]/);
});

test('automation: [F12] ham KAPAT (0x05) hareket eden ek panjuru DURDURUR; role geri ACILMAZ (eskiden FSM yeniden acardi)', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  r.cmd(T.SHUTTER_UP, 5);
  r.run(1500);
  assert.equal(ext.coils[0], true);
  assert.equal(r.a.rs485Send(hexString(buildWriteCoil(1, 0, COIL_OFF)), true, r.t), true);   // ham KAPAT, panjur kanali 1
  r.run(3000);
  assert.equal(ext.coils[0], false, 'role geri acilmadi');
  assert.equal(r.shutter(5).moving, false, 'panjur FSM de durduruldu');
  assert.deepEqual(r.violations, []);
});

test('automation: [F12] ham toplu KAPAT (0x00FF) ek modul rolelerini istenmeyen olarak isaretler; istenen lambalar geri ACILMAZ; toplu ACMA reddedilir', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  r.cmd(T.RELAY_SET, 13, 1);
  r.cmd(T.RELAY_SET, 14, 1);
  r.cmd(T.SHUTTER_UP, 5);
  r.run(1500);
  assert.equal(ext.coils[4] && ext.coils[5] && ext.coils[0], true);
  assert.equal(r.a.rs485Send(hexString(buildWriteCoil(1, 0x00FF, COIL_ON)), true, r.t), false, 'toplu ACMA ham gonderimde yasak');
  assert.equal(r.a.rs485Send(hexString(buildWriteCoil(1, 0x00FF, COIL_OFF)), true, r.t), true);
  r.run(4000);
  assert.equal(ext.coils.slice(0, 8).some(Boolean), false, 'hicbir ek role geri acilmadi');
  assert.equal(r.a.want[12] || r.a.want[13], false);
  assert.equal(r.shutter(5).moving, false);
  assert.equal(r.snap.relays[12] || r.snap.relays[13], false);
  assert.deepEqual(r.violations, []);
});

test('automation: [F12] baska slave\'e / modul KAPALIYKEN yapilan ham yazim uygulama durumunu ETKILEMEZ; yankisiz (susmus modul) ham yazim yansitilmaz', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  assert.equal(r.a.rs485Send(hexString(buildWriteCoil(7, 2, COIL_ON)), true, r.t), true);   // slave 7: modul yanit vermez
  r.run(500);
  assert.equal(r.a.want[10], false, 'baska slave: durum degismedi');
  ext.failWrites = true;                                                                    // modul susar
  assert.equal(r.a.rs485Send(hexString(buildWriteCoil(1, 2, COIL_ON)), true, r.t), true);
  ext.failWrites = false;
  r.run(500);
  assert.equal(r.a.want[10], false, 'yanki yok: yansitilmadi');
  const off = new Rig({ ext: makeExt(8) });                                                 // ek modul KAPALI yapilandirma
  off.run(1000);
  assert.equal(off.a.rs485Send(hexString(buildWriteCoil(1, 2, COIL_ON)), true, off.t), true);
  off.run(500);
  assert.equal(off.snap.totalRelays, 8);
  assert.equal(off.a.queue.length, 0);
});

test('automation: [F12] komut kuyrugu doluyken ham yazim uygulama durumuna yansitilamaz: modulde uygulanir, UYARI gunlukte gorunur (sessiz kayip yok)', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  r.a.rs485ClearLogs();
  for (let i = 0; i < 24; i++) assert.equal(r.cmd(T.ALL_LIGHTS_OFF), true);   // kuyruk dolu (loop calismadan)
  assert.equal(r.cmd(T.ALL_LIGHTS_OFF), false);
  assert.equal(r.a.rs485Send(hexString(buildWriteCoil(1, 4, COIL_ON)), true, r.t), true);
  assert.equal(ext.coils[4], true, 'modulde uygulandi');
  assert.match(r.a.rs485GetLogs(), /\[UYARI\] Ham yazim modulde uygulandi ama uygulama durumuna yansitilamadi/);
});

test('automation: RS485 gunlugu 25 satirlik halka tampon; temizlenebilir', () => {
  const r = new Rig({ ext: makeExt(8), configure: extShutter });
  r.run(100);
  r.a.rs485ClearLogs();
  for (let i = 0; i < 40; i++) r.a.addRs485Log(`satir-${i}`, r.t);
  const lines = r.a.rs485GetLogs().split('\n').filter(Boolean);
  assert.equal(lines.length, 25);
  assert.match(lines[0], /satir-15$/);
  assert.match(lines[24], /satir-39$/);
  r.a.rs485ClearLogs();
  assert.equal(r.a.rs485GetLogs(), '');
});

test('automation: baud uyusmazligi -- modul yanit vermez ("yanit vermiyor"); tarama dogru baud\'u bulup yapilandirmayi duzeltir', () => {
  const ext = makeExt(8);
  ext.baud = 19200;                                  // modul 19200'e ayarli, yapilandirma 9600
  const r = new Rig({ ext, configure: extShutter });
  r.run(8000);
  assert.equal(r.snap.extModuleResponding, false);
  assert.equal(r.a.rs485Baud, 9600);
  assert.equal(r.cm.config.rs485_baud, 9600);
  assert.equal(r.a.rs485StartScan(r.t), true);
  assert.equal(r.a.rs485ScanState(), 'running');
  r.run(20);
  assert.equal(r.a.rs485StartScan(r.t), false, 'zaten calisiyor');
  // tarama 9600 (8 yoklama x 230 ms), 38400, 115200 siralamasindan sonra 19200'de bulur
  r.runUntil(() => r.a.rs485ScanState() === 'done', 20000);
  const res = r.a.rs485ScanResult();
  assert.equal(res.found, true);
  assert.equal(res.slaveId, 1);
  assert.equal(res.baud, 19200);
  assert.equal(res.info, 'Modbus RTU Standard Yanit (CRC Dogru)');
  assert.match(res.rawHex, /^01 01 01 00 [0-9A-F]{2} [0-9A-F]{2} $/);
  assert.equal(r.cm.config.rs485_baud, 19200, 'yapilandirma bulunan baud\'a esitlendi');
  assert.equal(r.a.rs485Baud, 19200);
  assert.match(r.a.rs485GetLogs(), /\[BULUNDU\] Slave ID: 1 \(19200 baud\) \| Role Durumu: 0x0/);
  r.run(1500);
  assert.equal(r.snap.extModuleResponding, true, 'tarama sonrasi modul yeniden yanit veriyor');
});

test('automation: tarama suresince ek modul hatti tutulur -- ek modul panjur komutlari reddedilir, ek roleler yazilmaz, DURDURMA serbest', () => {
  const ext = makeExt(8);
  ext.baud = 115200;                                 // bulmasi uzun surer
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  assert.equal(r.a.rs485StartScan(r.t), true);
  r.run(100);
  r.cmd(T.SHUTTER_UP, 5);
  r.cmd(T.RELAY_SET, 13, 1);
  r.cmd(T.ALL_SHUTTERS_UP);
  r.run(100);
  assert.ok(r.events.some((e) => e.type === 'cmd_rejected' && e.reason === 'rs485_scan_running'), 'ek modul panjuru reddedildi');
  assert.equal(r.shutter(5).moving, false);
  assert.equal(r.shutter(1).moving, true, 'yerel panjurlar etkilenmez (ALL_SHUTTERS_UP yerel cifti hareket ettirdi)');
  assert.equal(ext.coils[4], false, 'tarama suresince ek role yazilmadi');
  assert.equal(r.a.rs485ControlExtRelay(1, 3, 1, r.t).ok, false);
  assert.match(r.a.rs485GetLogs(), /\[RED\] RS485 taramasi suruyor/);
  r.cmd(T.ALL_SHUTTERS_STOP);
  r.run(100);
  assert.equal(r.shutter(1).moving, false);
  r.runUntil(() => r.a.rs485ScanState() === 'done', 30000);
  assert.equal(r.a.rs485ScanResult().baud, 115200);
  r.run(1500);
  assert.equal(ext.coils[4], true, 'tarama bitince bekleyen ek role istegi uygulandi');
});

test('automation: ek modul panjuru hareket ederken tarama BASLATILMAZ (hareket eden panjura KAPAT gonderilemezdi)', () => {
  const ext = makeExt(8);
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  r.cmd(T.SHUTTER_UP, 5);
  r.run(400);
  assert.equal(r.shutter(5).moving, true);
  r.a.rs485ClearLogs();
  assert.equal(r.a.rs485StartScan(r.t), false);
  assert.equal(r.a.rs485ScanState(), 'idle');
  assert.match(r.a.rs485GetLogs(), /\[RED\] Tarama baslatilamadi: ek modul panjuru hareket halinde/);
  assert.equal(r.a.rs485StartScan(r.t, 1234), false, 'izinli olmayan baud');
});

test('automation: modul yokken tarama tum baud/slave araligini gezer (~9,3 sn) ve hicbir sey bulamaz; baud eski degerine doner', () => {
  const r = new Rig({ ext: makeExt(0) });
  r.run(100);
  const t0 = r.t;
  assert.equal(r.a.rs485StartScan(r.t), true);
  r.runUntil(() => r.a.rs485ScanState() === 'done', 30000);
  const took = r.t - t0;
  assert.ok(took > 9100 && took < 9700, `5 baud (9600,38400,115200,19200,4800) x 8 slave x 230 ms + 5 x 20 ms baud gecisi (${took} ms)`);
  const res = r.a.rs485ScanResult();
  assert.equal(res.found, false);
  assert.equal(res.info, 'Hicbir RS485 yaniti alinamadi.');
  assert.equal(r.a.rs485Baud, 9600);
  assert.match(r.a.rs485GetLogs(), /Harici modulden yanit alinamadi/);
});

test('automation: 4 kanalli modul 0x01 (8 coil) isteginde exception verir; tarama 0x03 yoklamasiyla bulur', () => {
  const ext = makeExt(4);
  const r = new Rig({ ext });
  r.run(100);
  assert.equal(r.a.rs485StartScan(r.t), true);
  r.runUntil(() => r.a.rs485ScanState() === 'done', 10000);
  const res = r.a.rs485ScanResult();
  assert.equal(res.found, true);
  assert.equal(res.info, 'Modbus 0x03 Register Yaniti (CRC Dogru)');
  assert.equal(res.relayStatus, 0);
});

// ------------------------------------------------------------------ yerel cikis dogrulamasi (TCA_Verify)
test('automation: TCA cip sifirlanmasi (brown-out) -- 2 sn icinde fark edilir, yerel panjurlar DURDURULUR, gercek duruma esitlenir', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 1);
  r.cmd(T.RELAY_SET, 5, 1);
  r.run(600);
  assert.equal(r.relay(1), true);
  assert.equal(r.relay(5), true);
  r.a.tca.qaChipReset();                              // cikis latch'i dustu, yon yazmaci varsayilana dondu
  assert.equal(r.a.tca.latch, 0);
  r.runUntil(() => r.eventsOf('tca_latch_changed').length > 0, 3000);
  assert.equal(r.eventsOf('tca_latch_changed').length, 1);
  r.run(100);
  assert.equal(r.shutter(1).moving, false, 'yerel panjur durduruldu');
  assert.equal(r.relay(1), false);
  assert.equal(r.a.want[4], true, 'lamba istegi bellekte kalir');
  assert.equal(r.relay(5), true, 'lamba normal akisla (want) yeniden yazildi; yalniz PANJURLAR durdurulur');
  r.run(3000);
  assert.equal(r.a.tca.shadow, r.a.tca.latch, 'golge ve donanim tutarli');
  assert.deepEqual(r.violations, []);
});

test('automation: [F12] TCA cip sifirlanmasi ile verify (<= 2 sn) arasindaki yazim dusen panjur rolesini YENIDEN CEKMEZ (yazim on denetimi); ihlal yok', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 2);                             // cift 2 (role 3/4) YUKARI
  r.run(600);
  assert.equal(r.a.tca.latch & 0x04, 0x04);
  r.a.tca.qaChipReset();                              // role 3 fiziksel olarak DUSTU; firmware golgesi hala "acik" (verify <= 2 sn sonra)
  r.run(10);
  r.cmd(T.SHUTTER_UP, 1);                             // baska cifte yeni hareket: 8 bitlik yazim eskiden role 3'u de olu zamansiz yeniden cekerdi
  r.run(100);
  assert.deepEqual(r.violations, [], 'on denetim: donanim okundu, dusen bit yazimdan cikarildi, kapanma ani InterlockGuard\'a bildirildi');
  assert.equal(r.a.tca.latch, 0, 'cip sifirlanmasi tespit edildi: TUM panjur ciftleri icin olu zaman o andan baslar (yeni hareket <= 500 ms bekler); role 3 yeniden cekilmedi');
  assert.equal(r.a.tca.cfgHw, r.a.tca.cfgShadow, 'yon yazmaci guvenli sirayla geri yuklendi');
  assert.equal(r.shutter(2).moving, false, 'dusen panjur durduruldu');
  assert.equal(r.shutter(1).moving, true, 'yeni komut kaybolmadi (olu zaman dolunca enerjilenir)');
  r.run(600);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x01, 'yalniz cift 1 enerjilendi; role 3 yeniden cekilmedi');
  assert.equal(r.eventsOf('tca_relay_dropped').length, 1);
  assert.deepEqual(r.eventsOf('tca_relay_dropped')[0].stopped_pairs, [2]);
  r.cmd(T.SHUTTER_UP, 2);                             // dusen cift yeniden istenir: ancak 500 ms olu zamandan sonra enerjilenir
  r.run(2000);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x05);
});

test('automation: [F12] role dusmesi (cikis yazmacindan bit silindi, yon yazmaci saglam) -- ilgisiz lamba yazimi dusen panjur rolesini yeniden CEKMEZ', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 2);
  r.run(600);
  assert.equal(r.a.tca.latch & 0x04, 0x04);
  r.a.tca.qaDropLatch(0x04);                          // role 3 dustu
  r.run(10);
  r.cmd(T.RELAY_SET, 5, 1);                           // lamba AC: yazim role 3 bitini de tasirdi
  r.run(100);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x10, 'yalniz lamba; role 3 yeniden cekilmedi');
  assert.equal(r.shutter(2).moving, false);
  assert.equal(r.relay(5), true);
  assert.equal(r.relay(3), false);
});

test('automation: [F12] dusen + beklenmeyen ACIK bit birlikte -- ikisi de dogru ele alinir (dusen YENIDEN cekilmez, fazla kapatilir)', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 2);
  r.run(600);
  r.a.tca.qaDropLatch(0x04);                          // role 3 dustu
  r.a.tca.qaForceLatchOn(0x40);                       // role 7 kendiliginden cekti
  r.run(10);
  r.cmd(T.RELAY_SET, 5, 1);
  r.run(100);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x10, 'role 7 kapatildi, role 3 yeniden cekilmedi, lamba acildi');
  assert.equal(r.shutter(2).moving, false);
});

test('automation: [F12] bagimsiz emniyet gorevi baska bir rolenin dusmesiyle yarisirken yine hedef cifti keser ve dusen biti geri cekmez', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 1);
  r.cmd(T.SHUTTER_UP, 2);
  r.run(600);
  assert.equal(r.a.tca.latch, 0x05);
  r.a.tca.qaDropLatch(0x04);                          // cift 2'nin rolesi dustu (firmware golgesi hala 0x05)
  // ana dongu takildi: bagimsiz emniyet gorevi cift 1'i keser -> guardTask'in yaptigi cagri: TCA_ClearBits(0x03 << 2p)
  r.a.tca.clearBits(0x03, r.t);
  assert.equal(r.a.tca.latch, 0x00, 'cift 1 kesildi, dusen rolenin biti geri cekilmedi (eskiden 0x04: yazim golgedeki diger biti de yeniden cekerdi)');
  r.run(100);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x00);
});

// ---- [F12] yazim on denetiminin sertlestirilmesi (firmware WS_TCA9554PWR.cpp: okuma yeniden denemesi, okunamayan donanim, iki asamali esitleme, KAPATMA oncesi esitleme)
test('automation: [F12] TCA on denetimi -- gecici okuma hatalari (en cok 2) yeniden denemeyle atlatilir: calisan panjur durdurulmaz, dusen role yeniden cekilmez', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 2);
  r.run(600);
  assert.equal(r.a.tca.latch, 0x04);
  r.a.tca.failReads = 2;                              // iki gecici okuma hatasi: ilk yazmac 3. denemede okunur
  r.cmd(T.RELAY_SET, 5, 1);
  r.run(100);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x14, 'lamba acildi; panjur KESINTISIZ suruyor (yeniden denemesiz: dogrulanamadi sanilip durdurulurdu)');
  assert.equal(r.shutter(2).moving, true);
  r.a.tca.qaDropLatch(0x04);                          // ayni gecici hatalar + role dusmesi: dusen role yine de tespit edilir
  r.run(10);
  r.a.tca.failReads = 2;
  r.cmd(T.RELAY_SET, 6, 1);
  r.run(100);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x30, 'iki lamba; dusen role yeniden CEKILMEDI');
  assert.equal(r.shutter(2).moving, false);
});

test('automation: [F12] TCA donanimi OKUNAMIYORSA (3 denemede de hata) golgede ACIK panjur rolesi yazimdan cikarilir ve panjur durdurulur (dogrulanamayan enerji yok)', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 2);
  r.run(600);
  r.a.tca.qaDropLatch(0x04);                          // role 3 dustu (firmware bilmiyor)
  r.run(10);
  r.a.tca.failReads = 3;                              // ilk yazmac 3 denemede de okunamaz: durum bilinmiyor
  r.cmd(T.RELAY_SET, 5, 1);
  r.run(100);
  assert.deepEqual(r.violations, [], 'eskiden: 8 bitlik yazim role 3\'u olu zamansiz yeniden cekerdi');
  assert.equal(r.a.tca.latch, 0x10);
  assert.equal(r.shutter(2).moving, false, 'dogrulanamayan panjur durduruldu');
  assert.equal(r.relay(5), true);
  assert.deepEqual(r.eventsOf('tca_unverified_stripped').map((e) => e.mask), [0x04]);
});

test('automation: [F12] okunamayan donanimda role GERCEKTEN acik kalmissa da guvenli yon: panjur kapatilir; lamba bitleri ve yeni enerjilenecek panjur biti etkilenmez', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 2);
  r.cmd(T.RELAY_SET, 5, 1);
  r.run(600);
  assert.equal(r.a.tca.latch, 0x14);
  const t0 = r.observer.transitions;
  r.a.tca.failReads = 3;
  r.cmd(T.RELAY_SET, 6, 1);                           // ikinci lamba: yazim lamba 5 (korunan) ve panjur 2 (korunan) bitlerini de tasir
  r.run(100);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x30, 'panjur rolesi kapandi (dogrulanamayan enerji yok), lambalar acik');
  assert.equal(r.shutter(2).moving, false);
  assert.equal(r.observer.transitions - t0, 2, 'lamba 5 titremedi: yalniz panjur kapandi ve lamba 6 acildi');
  // SINIR (karakterizasyon): okunamayan donanimda YENI enerjilenecek panjur biti (golgede kapali) etkilenmez
  r.cmd(T.SHUTTER_UP, 2);
  r.run(700);                                         // cift 2 yeniden calisiyor
  assert.equal(r.a.tca.latch, 0x34);
  r.a.tca.failReads = 3;
  r.cmd(T.SHUTTER_UP, 1);
  r.run(100);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x31, 'cift 1 (yeni) enerjili; cift 2 (dogrulanamayan) kapatildi');
  assert.equal(r.shutter(1).moving, true);
  assert.equal(r.shutter(2).moving, false);
});

test('automation: [F12] okuma basarisizken YAZIM da basarisizsa (hat olu) hicbir sey degismez: calisan panjur durdurulmaz, ariza gidince lamba acilir', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 2);
  r.run(600);
  assert.equal(r.a.tca.latch, 0x04);
  r.a.tca.i2cFail = true;
  r.cmd(T.RELAY_SET, 5, 1);
  r.run(50);
  assert.equal(r.a.tca.latch, 0x04, 'fiziksel durum degismedi');
  assert.equal(r.shutter(2).moving, true, 'panjur suruyor (yazim yapilamadi: "dustu" sayilmadi)');
  r.a.tca.i2cFail = false;
  r.run(400);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x14, 'hat toparlaninca lamba acildi; panjur kesintisiz suruyor');
  assert.equal(r.shutter(2).moving, true);
});

test('automation: [F12] duzeltme yazimi basarisiz olsa bile okunan "dusen" bilgisi kaybolmaz: ana yazim dusen panjur rolesini yeniden cekmez', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 2);
  r.run(600);
  assert.equal(r.a.tca.latch, 0x04);
  r.a.tca.qaDropLatch(0x04);                          // role 3 dustu
  r.a.tca.qaForceLatchOn(0x40);                       // role 7 kendiliginden cekti (duzeltme yazimi gerekir)
  r.run(10);
  r.a.tca.failWrites = 3;                             // duzeltme yazimi (3 deneme) basarisiz
  r.cmd(T.RELAY_SET, 5, 1);
  r.run(100);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch & 0x04, 0, 'dusen role YENIDEN CEKILMEDI');
  assert.equal(r.shutter(2).moving, false);
  assert.equal(r.relay(5), true);
  assert.equal(r.a.tca.latch, 0x10, 'role 7 de ana yazimla kapandi');
  assert.equal(r.eventsOf('tca_resync_fix_failed').length, 1);
});

test('automation: [F12] fiziksel olarak fazla ACIK bulunan panjur rolesi kapatilinca olu zaman O kapanmadan baslar (eskiden damga yoktu: hemen yeniden enerjilenirdi)', () => {
  const r = new Rig();
  r.a.tca.qaForceLatchOn(0x02);                       // role 2 (cift 1 ASAGI) kendiliginden cekti; firmware bilmiyor
  r.cmd(T.SHUTTER_DOWN, 1);                           // FSM ayni role icin yeni hareket ister
  r.run(300);
  assert.equal(r.a.tca.latch, 0, 'fazla acik role kapatildi; yeni hareket olu zamani (500 ms) bekliyor');
  r.run(800);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x02, 'olu zaman dolunca hareket basladi');
  assert.equal(r.shutter(1).moving, true);
});

test('automation: [F12] duzeltme yazimi basarisiz olursa fazla acik panjur rolesi "enerjili" bilinmeye DEVAM eder: ters yon ayni yazimda enerjilenemez', () => {
  const r = new Rig();
  r.a.tca.qaForceLatchOn(0x01);                       // role 1 (cift 1 YUKARI) kendiliginden cekti
  r.a.tca.failWrites = 3;                             // duzeltme yazimi basarisiz
  r.cmd(T.SHUTTER_DOWN, 1);                           // ters yon istenir
  r.run(60);
  assert.deepEqual(r.violations, [], 'eskiden: ana yazim 0x02 -> UP\'tan DOWN\'a dogrudan yon degisimi');
  assert.notEqual(r.a.tca.latch & 3, 3);
  r.run(3000);
  assert.deepEqual(r.violations, []);
  assert.notEqual(r.a.tca.latch & 3, 3);
});

test('automation: [F12] KAPATMA yazimi (mask == 0) firmware\'in bilmedigi ACIK panjur rolesini de kapatir: kapanma ani damgalanir, ters yon hemen enerjilenmez', () => {
  const r = new Rig();
  r.cmd(T.SHUTTER_UP, 2);
  r.run(600);
  assert.equal(r.a.tca.latch, 0x04);
  r.a.tca.qaForceLatchOn(0x01);                       // role 1 (cift 1 YUKARI) kendiliginden cekti; firmware bilmiyor
  r.run(10);
  r.cmd(T.SHUTTER_STOP, 2);                           // cift 2 durdurulur: yazim 0x00 (KAPATMA) role 1'i de kapatir
  r.run(40);
  assert.equal(r.a.tca.latch, 0);
  r.cmd(T.SHUTTER_DOWN, 1);                           // cift 1 ters yon, hemen
  r.run(300);
  assert.equal(r.a.tca.latch, 0, 'eskiden: olu zaman damgasi yok -> ters yon ~50 ms sonra enerjilenirdi');
  r.run(800);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x02);
});

test('automation: [F12] cip sifirlanmasi firmware\'in bilmedigi ACIK panjur rolesini de dusurur: tum panjur ciftleri icin olu zaman tespit anindan baslar', () => {
  const r = new Rig();
  r.a.tca.qaForceLatchOn(0x02);                       // role 2 (cift 1 ASAGI) kendiliginden cekti; firmware bilmiyor
  r.run(10);                                          // gozlemci role 2'nin ACIK oldugunu gorur
  r.a.tca.qaChipReset();                              // cip sifirlandi: bilinmeyen role de DUSTU (firmware golgesi hic acik demedi)
  r.run(5);
  r.cmd(T.SHUTTER_UP, 1);                             // ayni cifte ters yon: hemen
  r.run(300);
  assert.equal(r.a.tca.latch, 0, '500 ms olu zaman (tespit anindan) bekliyor; eskiden damga yoktu -> hemen enerjilenirdi');
  r.run(900);
  assert.deepEqual(r.violations, []);
  assert.equal(r.a.tca.latch, 0x01);
});

test('automation: TCA\'da beklenmeyen ACIK role (golge kapali, latch acik) -- verify kapatir', () => {
  const r = new Rig();
  r.run(100);
  r.a.tca.qaForceLatchOn(0x10);                       // role 5 kendiliginden cekti
  assert.equal(r.a.tca.latch, 0x10);
  r.runUntil(() => r.eventsOf('tca_verify').length > 0, 3000);
  assert.equal(r.eventsOf('tca_verify')[0].result, 'fixed');
  assert.equal(r.a.tca.latch, 0, 'donanim golgeye (kapali) cekildi');
  assert.equal(r.relay(5), false);
});

test('automation: TCA\'da dusen role (golge acik, latch kapali) -- golge donanima cekilir, role yeniden ACILMAZ', () => {
  const r = new Rig();
  r.cmd(T.RELAY_SET, 5, 1);
  r.run(100);
  assert.equal(r.relay(5), true);
  r.a.tca.qaDropLatch(0x10);
  r.runUntil(() => r.eventsOf('tca_verify').length > 0, 3000);
  assert.equal(r.eventsOf('tca_verify')[0].result, 'reset');
  r.run(100);
  assert.equal(r.relay(5), true, 'istek (want) hala gecerli: lamba normal akisla (verify disinda) yeniden yazildi');
  assert.equal(r.a.tca.latch & 0x10, 0x10);
});

// ------------------------------------------------------------------ gurultu / tasma
test('automation: millis() tasmasi (49,7 gun) hareket ve olu zaman sirasinda sorunsuz; ihlal yok', () => {
  const r = new Rig({ t0: 0xFFFFFFFF - 3000 });
  r.cmd(T.SHUTTER_UP, 1);
  r.run(30);
  const start = r.a.fsm[0].startMs();
  r.runUntil(() => ((r.t - start) >>> 0) >= 4000, 10000);
  assert.ok(r.t < 4000, 'sayac sarmis');
  assert.equal(r.shutter(1).pos, 20);
  r.cmd(T.SHUTTER_DOWN, 1);
  r.run(600);
  assert.equal(r.relay(2), true);
  r.run(1000);
  r.cmd(T.SHUTTER_STOP, 1);
  r.run(200);
  assert.deepEqual(r.violations, []);
});

let rng = 0x1234567;
const rnd = () => { rng = (Math.imul(rng, 1664525) + 1013904223) >>> 0; return rng >>> 8; };

test('automation: rastgele komut/DI/yapilandirma firtinasi (4 sanal dakika x 3 baslangic saati) -- fiziksel degismez ihlali YOK, istisna YOK', () => {
  for (const t0 of [0, 0xFFFFF000, 0x7FFFF000]) {
    const r = new Rig({ t0, timeScale: 20 });
    let noReadFailUntil = 0;
    let extraInjected = 0;
    const types = [T.RELAY_SET, T.RELAY_TOGGLE, T.SHUTTER_UP, T.SHUTTER_DOWN, T.SHUTTER_STOP, T.SHUTTER_STEP, T.SHUTTER_POS, T.ALL_LIGHTS_OFF,
      T.ALL_SHUTTERS_UP, T.ALL_SHUTTERS_DOWN, T.ALL_SHUTTERS_STOP, T.SET_CHILD_LOCK, T.SET_RUNTIME];
    for (let i = 0; i < 24000; i++) {
      r.step(10);
      const k = rnd() % 40;
      if (k < 6) {
        const type = types[rnd() % types.length];
        const idx = type === T.RELAY_SET || type === T.RELAY_TOGGLE ? 1 + (rnd() % 9) : 1 + (rnd() % 5);
        r.a.post({ ...makeCommand(type, CmdSource.MQTT, idx, type === T.SHUTTER_POS ? rnd() % 101 : type === T.SET_RUNTIME ? 1 + (rnd() % 30) : rnd() % 2), id: '' });
      } else if (k < 10) {
        r.a.setRawDi(rnd() % 8, (rnd() & 1) === 1);
      } else if (k === 10 && (rnd() % 50) === 0) {
        // yapilandirma karisikligi: bir roleyi rastgele tipe cevir (cift gecerli/gecersiz olur)
        r.cm.config.relays[rnd() % 8].type = rnd() % 4;
        r.cm.config.relays[0].runtime_sec = 1 + (rnd() % 30);
        r.cm.config.relays[1].runtime_sec = 1 + (rnd() % 30);
      } else if (k === 11 && (rnd() % 8) === 0) {
        // F12: TCA donanim arizasi: role dusmesi (tum bitler, panjur dahil) / cip sifirlanmasi / lamba rolesinin kendiliginden cekmesi /
        // panjur rolesinin kendiliginden cekmesi (firmware bilmiyor) / gecici I2C okuma ve yazma hatalari (3 okuma hatasi = on denetim okunamaz)
        const q = rnd() % 6;
        if (q === 0) r.a.tca.qaDropLatch(1 << (rnd() % 8));
        else if (q === 1) r.a.tca.qaChipReset();
        else if (q === 2) r.a.tca.qaForceLatchOn(0x10 << (rnd() % 4));
        else if (q === 3) {
          // Panjur rolesi KENDILIGINDEN cekti: yalniz cifte enerji verilmemisken ve son kapanmadan >= 500 ms sonra enjekte edilir (enjeksiyonun kendisi
          // fiziksel ihlal sayilmasin). Firmware bunu on denetim / KAPATMA oncesi esitleme / verify ile fark eder ve olu zamani O andan sayar.
          // Tespit edilene kadar (3 sn) yeni okuma hatasi enjekte edilmez: "bilinmeyen role + okunamayan donanim + ters yon" birlesimi sinir disi.
          const pr = rnd() % 2, dr = rnd() % 2;
          const free = ((r.a.tca.latch >> (2 * pr)) & 3) === 0;
          const aged = !r.observer.haveOff[pr] || (((r.t - r.observer.offAt[pr]) >>> 0) >= 500);
          if (free && aged && r.a.tca.failReads === 0) { r.a.tca.qaForceLatchOn(1 << (2 * pr + dr)); noReadFailUntil = (r.t + 3000) >>> 0; extraInjected++; }
        } else if (q === 4) {
          if (((r.t - noReadFailUntil) | 0) >= 0) r.a.tca.failReads = 1 + (rnd() % 3);
        } else {
          r.a.tca.failWrites = 1 + (rnd() % 5);
        }
      }
    }
    assert.deepEqual(r.violations, [], `t0=${t0.toString(16)}: ihlal`);
    for (let p = 1; p <= 4; p++) assert.ok(r.shutter(p).pos >= 0 && r.shutter(p).pos <= 100);
    assert.ok(r.observer.transitions > 50, `yeterli fiziksel gecis olustu (${r.observer.transitions})`);
    // firtina F12 nadir yollarini gercekten calistirdi mi? (aksi halde "yesil" bir sey kanitlamaz)
    const seenF12 = { extra: extraInjected, dropped: r.eventsOf('tca_relay_dropped').length, fixFailed: r.eventsOf('tca_resync_fix_failed').length,
      stripped: r.eventsOf('tca_unverified_stripped').length, verify: r.eventsOf('tca_verify').length };
    assert.ok(seenF12.extra >= 1 && seenF12.dropped >= 1 && seenF12.verify >= 1, `t0=${t0.toString(16)}: F12 yollari: ${JSON.stringify(seenF12)}`);
    r.f12Seen = seenF12;
  }
});

test('automation: ek modul + RS485 ham komut/tarama + donanim arizasi firtinasi (3 sanal dakika x 2 baslangic saati) -- fiziksel degismez ihlali YOK, sonunda inanc donanimla UYUSUR', () => {
  let rs = 0xC0FFEE;                                    // bu test KENDI rastgele akisini kullanir (calisma sirasindan/filtreden bagimsiz, tekrarlanabilir)
  const rnd = () => { rs = (Math.imul(rs, 1664525) + 1013904223) >>> 0; return rs >>> 8; };
  for (const t0 of [0, 0xFFFFF000]) {
    const ext = makeExt(8);
    const r = new Rig({
      t0, timeScale: 20, ext,
      configure: (cm) => {
        const c = cm.config;
        c.ext_module_enabled = true; c.ext_module_channels = 8;
        for (const [a, b] of [[8, 9], [10, 11]]) {
          c.relays[a].type = RelayType.SHUTTER_UP; c.relays[a].runtime_sec = 20;
          c.relays[b].type = RelayType.SHUTTER_DOWN; c.relays[b].runtime_sec = 20;
        }
      },
    });
    const types = [T.RELAY_SET, T.RELAY_TOGGLE, T.SHUTTER_UP, T.SHUTTER_DOWN, T.SHUTTER_STOP, T.SHUTTER_STEP, T.SHUTTER_POS, T.ALL_LIGHTS_OFF,
      T.ALL_SHUTTERS_UP, T.ALL_SHUTTERS_DOWN, T.ALL_SHUTTERS_STOP];
    const raw = (a, b, c) => r.a.rs485ControlExtRelay(a, b, c, r.t);
    for (let i = 0; i < 18000; i++) {
      r.step(10);
      const k = rnd() % 200;
      if (k < 30) {
        const type = types[rnd() % types.length];
        const idx = type === T.RELAY_SET || type === T.RELAY_TOGGLE ? 1 + (rnd() % 16) : 1 + (rnd() % 6);
        r.a.post({ ...makeCommand(type, CmdSource.MQTT, idx, type === T.SHUTTER_POS ? rnd() % 101 : rnd() % 2), id: '' });
      } else if (k < 45) {
        r.a.setRawDi(rnd() % 8, (rnd() & 1) === 1);
        if ((rnd() & 3) === 0) ext.rawDi[rnd() % 8] = (rnd() & 1) === 1;
      } else if (k === 45) {
        raw(rnd() % 8 === 0 ? 7 : 1, rnd() % 9, rnd() % 3);                         // ham role komutu (panjur kanali/toplu ACMA reddedilir)
      } else if (k === 46) {
        // ham cerceve: rastgele kanal/deger (panjur kanalina ACMA reddedilir; KAPAT ve panjur disi ACMA gecer)
        const addr = rnd() % 9 === 0 ? 0x00FF : rnd() % 8;
        const val = [COIL_ON, 0x0000, 0x5500][rnd() % 3];
        r.a.rs485Send(hexString(buildWriteCoil(1, addr, val)), true, r.t);
      } else if (k === 47 && (rnd() % 3) === 0) {
        r.a.rs485StartScan(r.t);                                                     // (ek panjur hareketliyse reddedilir)
      } else if (k === 48 && (rnd() % 6) === 0) {
        ext.failWrites = !ext.failWrites;                                            // modul susar / geri gelir
      } else if (k === 49 && (rnd() % 10) === 0) {
        ext.baud = ext.baud === 9600 ? 19200 : 9600;                                 // baud uyusmazligi
      } else if (k === 50 && (rnd() % 8) === 0) {
        // BASKA master: yalniz panjur DISI kanallari (coil 4..7) ve KAPATMA (her coil) -- panjur coil'ine disaridan ACMA fiziksel ihlal olurdu
        const ch = rnd() % 8;
        if (ch >= 4) ext.coils[ch] = (rnd() & 1) === 1; else ext.coils[ch] = false;
      } else if (k === 51 && (rnd() % 15) === 0) {
        // F12: yazim on denetimiyle role dusmesi / cip sifirlanmasi artik KAPALI bir pencere: TUM bitler (panjur dahil) dusurulur, cip sifirlanir.
        // Beklenmeyen ACIK role (kendiliginden cekme) yalniz lamba bitlerinde (panjur rolesinin disaridan ACILMASI enjekte edilen fiziksel ihlal olurdu)
        const q = rnd() % 4;
        if (q === 0) r.a.tca.qaForceLatchOn(0x10 << (rnd() % 4));
        else if (q === 1) r.a.tca.qaDropLatch(1 << (rnd() % 8));
        else if (q === 2) r.a.tca.qaChipReset();
        else r.a.tca.qaDropLatch(0x10 << (rnd() % 4));
      } else if (k === 52 && (rnd() % 40) === 0) {
        r.cm.config.relays[rnd() % 8].type = rnd() % 4;                              // yerel yapilandirma karisikligi (ek panjur ciftleri sabit)
      }
    }
    assert.deepEqual(r.violations, [], `t0=${t0.toString(16)}: ihlal`);
    assert.ok(r.observer.transitions > 40, `yeterli fiziksel gecis olustu (${r.observer.transitions})`);
    // firtina nadir yollari gercekten calistirdi mi? (aksi halde "yesil" bir sey kanitlamaz)
    const seen = (t) => r.eventsOf(t).length;
    assert.ok(seen('rs485_scan_done') >= 1 && seen('ext_module_not_responding') >= 1 && seen('shutter_started') >= 20,
      `nadir yollar: tarama=${seen('rs485_scan_done')} modul_sustu=${seen('ext_module_not_responding')} panjur=${seen('shutter_started')}`);

    // ---- yakinsama: ariza/uyusmazlik giderilir, her sey durdurulur; firmware durumu donanimla UYUSMALI
    r.runUntil(() => r.a.rs485ScanState() !== 'running', 15000);                     // suren tarama bitsin (sonucu baslangictaki modul durumuna gore)
    ext.failWrites = false; ext.baud = 9600;
    r.cm.config.rs485_baud = 9600;
    r.a.rs485Begin(9600, r.t);
    r.cmd(T.ALL_SHUTTERS_STOP);
    r.cmd(T.ALL_LIGHTS_OFF);
    r.run(8000);
    assert.deepEqual(r.violations, [], `t0=${t0.toString(16)}: yakinsama sirasinda ihlal`);
    assert.equal(r.snap.extModuleResponding, true, 'modul yeniden yanit veriyor');
    for (let i = 0; i < 8; i++) assert.equal(r.snap.relays[i], ((r.a.tca.latch >> i) & 1) === 1, `yerel role ${i + 1}: inanc donanimla ayni`);
    for (let k = 0; k < 8; k++) assert.equal(r.snap.relays[8 + k], ext.coils[k], `ek role ${9 + k}: inanc modul coil'iyle ayni (t0=${t0.toString(16)})`);
    for (let p = 1; p <= 6; p++) assert.ok(r.shutter(p).pos >= 0 && r.shutter(p).pos <= 100);
  }
});

test('automation: DI kenarlari / komutlar yeniden baslatmada korunan kilit (NVS) ve konfigurasyon ile tutarli: kilit kalicidir, fabrika sifirlama RAM kilidini de siler', () => {
  const r = new Rig();
  r.cmd(T.SET_CHILD_LOCK, 0, 1);
  r.run(40);
  r.coldBoot();
  r.run(600);
  assert.equal(r.snap.childLock, true, 'kilit elektrik gidip gelince korunur');
  r.cm.resetToDefaults();
  r.run(50);
  assert.equal(r.snap.childLock, false, 'fabrika sifirlama kilidi kaldirir');
  assert.equal(r.nvs.get('auto'), null);
});

test('automation: bos NVS ile ilk acilis firmware varsayilanlari yazar; resetToDefaults kimlik/MQTT/yerel anahtari KORUR, Wi-Fi ve uygulama ayarini siler', () => {
  const nvs = new NvsImage(null);
  const r = new Rig({ nvs, configure: (cm) => { cm.setLocalKey('abcdefgh12345678'); cm.setApPass('ap-pass-1234'); cm.setMqttCredentials('10.0.2.2', 1883, 'd_h_abc', 'pw12345'); cm.config.wifi_ssid = 'Ev'; cm.config.wifi_pass = '12345678'; cm.config.wifi_sta_enabled = true; cm.config.device_name = 'Benim Evim'; cm.save(); } });
  assert.equal(r.cm.config.device_name, 'Benim Evim');
  r.cm.resetToDefaults();
  const c = r.cm.config;
  assert.equal(c.device_name, 'AHBU Akilli Ev Kontrol');
  assert.equal(c.wifi_sta_enabled, false);
  assert.equal(c.wifi_ssid, '');
  assert.equal(c.local_key, 'abcdefgh12345678');
  assert.equal(c.ap_pass, 'ap-pass-1234');
  assert.equal(c.mqtt_user, 'd_h_abc');
  assert.equal(c.mqtt_pass, 'pw12345');
  assert.equal(c.mqtt_server, '10.0.2.2');
  assert.equal(c.mqtt_port, 1883);
  const stored = nvs.get('cfg');
  assert.equal(stored.lk, 'abcdefgh12345678');
  assert.equal(stored.sta_en, false);
  assert.equal(stored.cfg_init, true);
});

// pano-8: kuyruga alinip cekirdekte reddedilen KIMLIKLI genel komutlar state.last_rej {id, code} yazar (bulut 'yanit yok' zaman asimina
// dusmez). Yalniz mevcut kodlar: bad_cmd (gecersiz role/cift, panjur olmayan cift, eslesmeyen panjur rolesi, gecersiz sure/konum) ve busy
// (yeniden baslatma bekliyor, RS485 taramasi suruyor, panjur hareketteyken SET_RUNTIME). Kimliksiz red last_rej'i degistirmez.
test('automation: reddedilen kimlikli genel komutlar last_rej uretir: bad_cmd / busy; kimliksiz red yazmaz (pano-8)', () => {
  const rej = (r) => r.a.safety.lastReject();
  const r = new Rig();
  r.cmd(T.RELAY_SET, 99, 1, 'g-role');
  r.run(30);
  assert.deepEqual(rej(r), { id: 'g-role', code: 'bad_cmd' });
  r.cmd(T.SHUTTER_UP, 3, 0, 'g-cift');               // cift 3 = role 5-6 (lamba): panjur degil
  r.run(30);
  assert.deepEqual(rej(r), { id: 'g-cift', code: 'bad_cmd' });
  r.cmd(T.SHUTTER_POS, 1, 150, 'g-konum');
  r.run(30);
  assert.deepEqual(rej(r), { id: 'g-konum', code: 'bad_cmd' });
  r.cmd(T.SET_RUNTIME, 1, 999, 'g-sure');
  r.run(30);
  assert.deepEqual(rej(r), { id: 'g-sure', code: 'bad_cmd' });
  r.cmd(T.SHUTTER_UP, 1);
  r.run(300);
  r.cmd(T.SET_RUNTIME, 1, 10, 'g-hareket');
  r.run(30);
  assert.deepEqual(rej(r), { id: 'g-hareket', code: 'busy' });
  r.cmd(T.SHUTTER_STOP, 1);
  r.run(700);
  r.cmd(T.RELAY_SET, 99, 1);                          // kimliksiz red: last_rej degismez
  r.run(30);
  assert.deepEqual(rej(r), { id: 'g-hareket', code: 'busy' });
  // yeniden baslatma beklenirken yurutulen komut (baska gorevin istegiyle ayni turda bosaltilan kuyruk / satir ici submit): busy
  r.a.requestRestart(600, r.t);
  const c = makeCommand(T.RELAY_SET, CmdSource.MQTT, 5, 1);
  c.id = 'g-restart';
  assert.equal(r.a.executeCommand(c, r.t), false);
  assert.deepEqual(rej(r), { id: 'g-restart', code: 'busy' });
  const o = new Rig({ configure: (cm) => { cm.config.relays[1].type = RelayType.LIGHT; cm.config.relays[1].runtime_sec = 0; } });
  o.cmd(T.RELAY_SET, 1, 1, 'g-yetim');                // eslesmeyen panjur rolesi
  o.run(30);
  assert.deepEqual(rej(o), { id: 'g-yetim', code: 'bad_cmd' });
});

test('automation: RS485 taramasi surerken reddedilen ek modul panjur komutu last_rej busy uretir (pano-8)', () => {
  const ext = makeExt(8);
  ext.baud = 115200;
  const r = new Rig({ ext, configure: extShutter });
  r.run(1000);
  assert.equal(r.a.rs485StartScan(r.t), true);
  r.run(100);
  r.cmd(T.SHUTTER_UP, 5, 0, 'g-tarama1');
  r.run(50);
  assert.deepEqual(r.a.safety.lastReject(), { id: 'g-tarama1', code: 'busy' });
  r.cmd(T.RELAY_SET, 9, 1, 'g-tarama2');               // ek modul panjur rolesi (ham)
  r.run(50);
  assert.deepEqual(r.a.safety.lastReject(), { id: 'g-tarama2', code: 'busy' });
});

// pano-4: ek modul ETKINKEN kanal sayisi arttiginda (CLI EXTMOD / POST /api/config / sablon) yeni kanallarin DI kapisi hic baslatilmamisti
// (kararli = "kontak acik"): ilk okumada surekli kapali kontak sahte "basis" kenari uretip roleyi degistiriyordu. Duzeltme: yeni kanallar ilk
// taze okumayla kenarsiz baslatilir; gercek basislar sonra olagan yoldan islenir.
test('automation: ek modul kanal sayisi artinca yeni kanal DI kapisi ilk okumada kenarsiz baslar; sahte basis yok (pano-4)', () => {
  const ext = makeExt(16);
  ext.rawDi[8] = true;                                   // DI 17: kontak surekli kapali
  const r = new Rig({ ext, configure: (cm) => { cm.config.ext_module_enabled = true; cm.config.ext_module_channels = 8; } });
  r.run(2000);
  assert.equal(r.relay(5), false);
  r.cm.config.ext_module_channels = 16;                  // 8 -> 16 kanal; DI 17 -> role 5 TOGGLE
  r.cm.config.dis[16].target_relay = 5;
  r.cm.config.dis[16].mode = DIMode.TOGGLE;
  r.run(2000);
  assert.equal(r.relay(5), false, 'ilk okuma basis sayilmadi (role degismedi)');
  assert.equal(r.eventsOf('di_press').filter((e) => e.di === 17).length, 0);
  ext.rawDi[8] = false;                                  // gercek birakma + basis olagan yoldan islenir
  r.run(300);
  ext.rawDi[8] = true;
  r.run(300);
  assert.equal(r.relay(5), true, 'gercek basis TOGGLE yapar');
});
