// SmartAutomation.cpp / SmartAutomation_Rs485.cpp (firmware) JavaScript portu: role / panjur / DI / ek modul yoneticisi.
//
// MIMARI (firmware ile ayni):
//  * Role ve panjur durumunu YALNIZCA loop() degistirir. MQTT/Web/CLI komutu post() ile kuyruga yazar; kuyrugu loop() bosaltir.
//    DI (duvar butonu) olaylari ayni yurutucuya (executeCommand) satir ici girer ve kuyruk dolulugu yuzunden kaybolmaz.
//  * Panjur durum makinesi ShutterFsm portudur (fw/shutter_fsm.js, firmware'in kendi Unity testleriyle dogrulanir);
//    burada yalniz ince sarmalayici: FSM'e komut verir, FSM ciktisini (outMask) role surucusune uygular,
//    surucu geri bildirimini (role KAPALI teyidi) FSM'e verir.
//  * Fiziksel cikis katmani: yerel 8 role TCA9554 golge kayit + InterlockGuard; ek modul (RS485) rolelerinin ayri InterlockGuard'i.
//  * Saat DISARIDAN verilir (loop(now), uint32 ms); hicbir gercek zamanlayici yoktur: testler sanal saatle surulebilir.
//
// QA'ya ozgu (firmware'de OLMAYAN) kisimlar acikca "QA:" ile isaretlidir: ham DI seviyeleri, ek modul donanim modeli,
// I2C hata enjeksiyonu. Time-scale: yalniz panjur yol/overrun sureleri olceklenir (olu zaman 500 ms sabit kalir).
import { ShutterFsm, Ev } from './shutter_fsm.js';
import { InterlockGuard, Result, ResyncKind, planTcaResync, extNeedsOffWrite, unverifiedRetainedShutterBits } from './interlock_guard.js';
import { DiGate, Mode, Action, Edge } from './di_gate.js';
import {
  MAX_TOTAL_RELAYS, MAX_TOTAL_DIS, RelayType, SHUTTER_RUNTIME_MIN_SEC, SHUTTER_RUNTIME_MAX_SEC, IMPULSE_MS_DEFAULT,
} from './sysconfig.js';
import { CmdType } from '../command_schema.js';
import {
  FC_READ_COILS, FC_READ_DISCRETE_INPUTS, FC_READ_HOLDING, FC_WRITE_SINGLE_COIL, COIL_ON, COIL_OFF, COIL_TOGGLE, Status,
  buildReadBits, buildWriteCoil, checkReadBits, checkWriteCoilEcho, frameCrcOk, getBit, hexString, moduleRespond, statusText,
} from './modbus.js';

export const CMD_QUEUE_LEN = 24;
export const GUARD_MARGIN_MS = 1500;
export const POS_SAVE_DELAY_MS = 8000;
export const POS_SAVE_MIN_DELTA = 2;
export const BOOT_HOLD_MS = 500;
export const TCA_VERIFY_PERIOD_MS = 2000;
export const SHUTTER_DEAD_TIME_MS = ShutterFsm.MIN_DEAD_TIME_MS;
export const SHUTTER_OVERRUN_MS = 2000;
export const MAX_PAIRS = MAX_TOTAL_RELAYS / 2;
/** SmartAutomation_Rs485.cpp isAllowedBaud() */
export const RS485_BAUDS = Object.freeze([4800, 9600, 19200, 38400, 57600, 115200]);
export const RS485_LOG_MAX = 25;
/** Tarama zamanlamasi (runScanBody): baud degisimi 20 ms, her slave once 10 ms bekleme, yanitsiz 0x01 yoklamasi 120 ms, 0x03 yoklamasi 100 ms */
const SCAN_BAUD_SWITCH_MS = 20;
const SCAN_SLAVE_GAP_MS = 10;
const SCAN_COIL_TIMEOUT_MS = 120;
const SCAN_HOLD_TIMEOUT_MS = 100;
const SCAN_REPLY_MS = 15;

const u32 = (x) => x >>> 0;
const M64 = (1n << 64n) - 1n;
const p2 = (n) => String(n).padStart(2, '0');

/** SmartAutomation::ExtReadback */
const Readback = Object.freeze({ PEER_OFF: 0, PEER_ON: 1, ALREADY_ON: 2, READ_FAILED: 3 });

export const CmdSource = Object.freeze({ MQTT: 'mqtt', WEB: 'web', CLI: 'cli', DI: 'di', RULE: 'rule', QA: 'qa' });

export function makeCommand(type, source, index = 0, value = 0) {
  return { type, source, index, value, id: '' };
}

// =============================================================================================
// Yerel cikis surucusu: TCA9554 (WS_TCA9554PWR.cpp) = golge kayit + InterlockGuard
// =============================================================================================
export class TcaDriver {
  constructor({ event = () => {} } = {}) {
    this.event = event;
    /** firmware s_outShadow: son BASARILI yazim (firmware'in "inanci") */
    this.shadow = 0;
    /** QA: cikis latch'inin GERCEK (fiziksel) degeri; normalde golgeyle ayni. brown-out/cip sifirlanmasinda golgeden ayrilir. */
    this.latch = 0;
    this.cfgShadow = 0;     // yon yazmaci golgesi (0 = hepsi cikis)
    this.cfgHw = 0;         // QA: yon yazmacinin gercek degeri (cip sifirlanirsa 0xFF = hepsi giris)
    this.guard = new InterlockGuard();
    this.writeFailures = 0;
    /** firmware s_droppedMask: esitlemede "golgede ACIK sanilip fiziksel olarak KAPALI bulunan" bitler (takeDroppedMask ile alinir) */
    this.droppedMask = 0;
    /** QA: true iken TUM I2C islemleri (okuma + yazma) basarisiz olur (hat olu / role surucusu arizasi). */
    this.i2cFail = false;
    /** QA: sonraki N yazmac OKUMA denemesi basarisiz olur (gecici NACK; her deneme 1 sayar). */
    this.failReads = 0;
    /** QA: sonraki N yazmac YAZMA denemesi basarisiz olur (gecici NACK; her deneme 1 sayar). */
    this.failWrites = 0;
  }

  /** TCA9554PWR_Init: acilista hepsi KAPALI; onceki durum "her cift enerjiliydi" sayilir (ilk enerjileme olu zamana tabi). */
  init(now) {
    if (this.i2cFail) return;               // 3 yazim denemesi basarisiz: guard/golge guncellenmez
    this.latch = 0;
    this.cfgHw = 0;
    this.cfgShadow = 0;
    this.guard.forceHw(~0n & M64);
    this.guard.commit(0, now);
    this.shadow = 0;
  }

  setShutterPairs(pairMask) { this.guard.setShutterPairs(pairMask & 0x0F); }

  outputShadow() { return this.shadow; }

  // QA: tek yazmac erisimi (TCA_ReadReg / TCA_WriteReg): hat olu (i2cFail) ya da enjekte edilen gecici hata (failReads/failWrites) ise basarisiz.
  #readOk() {
    if (this.i2cFail) return false;
    if (this.failReads > 0) { this.failReads--; return false; }
    return true;
  }

  #writeRegOk() {
    if (this.i2cFail) return false;
    if (this.failWrites > 0) { this.failWrites--; return false; }
    return true;
  }

  /** tcaReadRegRetry() / tcaWriteRegRetry(): en cok `attempts` (3) deneme (firmware aralarinda 2 ms bekler; QA sanal saatte bekleme modellenmez). */
  #readRetry(attempts = 3) {
    for (let attempt = 0; attempt < attempts; attempt++) if (this.#readOk()) return true;
    return false;
  }

  #writeRetry() {
    for (let attempt = 0; attempt < 3; attempt++) if (this.#writeRegOk()) return true;
    return false;
  }

  /**
   * tcaResyncLocked(): donanimi (cikis + yon yazmaci) okuyup golgeyi + InterlockGuard'i ona esitler. Karar SAF mantiktir
   * (planTcaResync, firmware relayrules::planTcaResync). Dusen bitler droppedMask'e eklenir ve YENIDEN CEKILMEZ. IKI ASAMA:
   * (1) okunan FIZIKSEL durum hemen golgeye ve InterlockGuard'a islenir (dusenlerin kapanma ani simdi damgalanir: 500 ms olu zaman o
   * andan baslar; fazla acik bir role "enerjili" bilinir: duzeltme yazimi basarisiz olsa bile ters yon / olu zaman korumasi gercege gore
   * calisir), (2) fazla acik roleler kapatilir / yon yazmaci geri yuklenir; fazla acik PANJUR rolesinin ACIK->KAPALI gecisi bu ikinci
   * asamada damgalanir. readFailed: donanim 3 denemede de OKUNAMADI (durum bilinmiyor): cagiran dogrulanamayan panjur bitlerini yazimdan cikarir.
   * adoptOnly (KAPATMA yazimi mask == 0 oncesi): yalniz 1. asama (tek okuma denemesi, duzeltme yazimi YOK). Hemen ardindan gelen KAPATMA yazimi zaten
   * her cikisi kapatir; 1. asama, o yazimin fiziksel olarak ACIK bulunan (firmware'in bilmedigi) panjur rolelerini de kapattigini InterlockGuard'a
   * bildirir (kapanma damgasi: olu zaman o andan baslar). Hicbir sey engellenmez/bekletilmez.
   * @returns {{result:'ok'|'fixed'|'reset'|'error', dropped:number, readFailed:boolean}}
   */
  #resync(now, adoptOnly = false) {
    const readAttempts = adoptOnly ? 1 : 3;
    if (!this.#readRetry(readAttempts) || !this.#readRetry(readAttempts)) return { result: 'error', dropped: 0, readFailed: true };   // okunamadi (OUT, sonra CFG)
    const outHw = this.latch;
    const plan = planTcaResync(outHw, this.cfgHw, this.shadow, this.cfgShadow);
    if (plan.kind === ResyncKind.IN_SYNC) return { result: 'ok', dropped: 0, readFailed: false };

    // Asama 1: fiziksel gercegi HEMEN isle (asagidaki duzeltme yazimlari basarisiz olsa bile bilgi kaybolmaz)
    if (plan.dropped !== 0) this.droppedMask = (this.droppedMask | plan.dropped) & 0xFF;
    if (plan.kind === ResyncKind.CHIP_RESET) {
      // Cip sifirlaninca HER role (firmware'in ACIK oldugunu bilmedigi, kendiliginden cekmis olanlar dahil) bilinmeyen bir anda (<= simdi) dustu:
      // koruma yalniz "ACIK sanilan" ciftleri damgalayabilir; kalan ciftlerin olu zamani en kotu ihtimalle (simdi) kabul edilir.
      for (let relay = 0; relay < 8; relay += 2) this.guard.noteOff(relay, now);
    }
    this.guard.commit(plan.physical, now);                          // dusen bitlerin ACIK->KAPALI gecisi SIMDI damgalanir (olu zaman yeniden baslar)
    this.shadow = plan.physical;
    if (adoptOnly) return { result: plan.kind === ResyncKind.FIX_EXTRA ? 'fixed' : 'reset', dropped: plan.dropped, readFailed: false };

    // Asama 2: duzeltme yazimlari
    const failed = () => {
      this.event('tca_resync_fix_failed', { physical: plan.physical, dropped: plan.dropped });
      return { result: 'error', dropped: plan.dropped, readFailed: false };
    };
    if (plan.restoreConfig) {
      // Cip sifirlanmis: once GUVENLI (hepsi KAPALI) cikis, sonra yon
      if (!this.#writeRetry()) return failed();
      this.latch = 0;
      if (!this.#writeRetry()) return failed();
      this.cfgHw = this.cfgShadow;
    } else if (plan.writeOut) {
      if (!this.#writeRetry()) return failed();
      this.latch = plan.newShadow;                                  // beklenmeyen ACIK bitler kapatilir (dusenler yeniden cekilmez)
    }
    this.guard.commit(plan.newShadow, now);                         // fazla acik rolenin ACIK->KAPALI gecisi SIMDI damgalanir (olu zaman o andan baslar)
    this.shadow = plan.newShadow;
    const result = plan.kind === ResyncKind.FIX_EXTRA ? 'fixed' : 'reset';
    this.event('tca_verify', { result, out_hw: outHw, shadow: this.shadow });
    return { result, dropped: plan.dropped, readFailed: false };
  }

  /** TCA_TakeDroppedMask(): esitlemede dusen bitlerin birikmis maskesini alir ve sifirlar. */
  takeDroppedMask() {
    const d = this.droppedMask;
    this.droppedMask = 0;
    return d;
  }

  /** @returns {'ok'|'dead_time'|'both_on'|'reversal'|'i2c_fail'} */
  writeEx(mask, now) {
    mask &= 0xFF;
    // ON DENETIM: bir roleyi ACIK birakacak/acacak her yazimdan once donanim okunur. Cip sifirlanmasi / role dusmesi ile periyodik verify
    // arasinda golge "ACIK", donanim "KAPALI" der; 8 bitlik yazim dusen rolenin bitini (panjur dahil) olu zamansiz yeniden cekerdi.
    // Donanim 3 denemede de OKUNAMAZSA (durum bilinmiyor): golgede zaten ACIK olan PANJUR roleleri dogrulanamaz; yeniden cekmek olu zamani
    // ciynebilir. DOGRULANAMAYAN ENERJI YOK: bu bitler yazimdan cikarilir (role kapanir) ve YAZIM BASARILI olursa "dusmus" sayilir (ust
    // katman panjuru durdurur). Yazim basarisizsa hicbir sey degismez. Yeni enerjilenecek bitler ve lambalar etkilenmez.
    // KAPATMA yazimlari (mask == 0) HICBIR kosulda engellenmez/bekletilmez; yalniz oncesinde fiziksel durum (tek okuma denemesi) InterlockGuard'a
    // islenir: yazim, firmware'in bilmedigi ACIK bir panjur rolesini de kapatir ve o kapanmanin olu zamani damgalanmalidir.
    let unverified = 0;
    if (mask !== 0) {
      const rs = this.#resync(now);
      mask &= ~rs.dropped & 0xFF;
      if (rs.readFailed) {
        unverified = unverifiedRetainedShutterBits(mask, this.shadow, this.guard.shutterPairs());
        mask &= ~unverified & 0xFF;
      }
    } else {
      this.#resync(now, true);
    }
    const r = this.guard.check(mask, now);
    if (r !== Result.OK) {
      if (r === Result.DEAD_TIME) return 'dead_time';
      this.writeFailures++;
      this.event('tca_interlock_refused', { mask, reason: InterlockGuard.resultText(r) });
      return r === Result.BOTH_ON ? 'both_on' : 'reversal';
    }
    if (!this.#writeRetry()) {
      this.writeFailures++;
      this.event('tca_i2c_write_failed', { mask });
      return 'i2c_fail';
    }
    this.guard.commit(mask, now);
    this.shadow = mask & 0xFF;
    this.latch = mask & 0xFF;
    if (unverified !== 0) {
      this.droppedMask = (this.droppedMask | unverified) & 0xFF;
      this.event('tca_unverified_stripped', { mask: unverified });
    }
    return 'ok';
  }

  writeOutputs(mask, now) { return this.writeEx(mask, now) === 'ok'; }

  /** Acil kapatma: golgeden clearMask'i dusur (yalniz KAPATMA: interlock'a takilmaz). */
  clearBits(clearMask, now) { return this.writeOutputs(this.shadow & ~clearMask & 0xFF, now); }

  /**
   * TCA_Verify(): cikis/yon yazmaclarini okuyup golgeyle karsilastirir (firmware 2 sn'de bir).
   * @returns {'ok'|'fixed'|'reset'|'error'}  fixed = beklenmeyen ACIK role kapatildi; reset = cip sifirlanmis/role dusmus (golge donanima cekildi)
   */
  verify(now) { return this.#resync(now).result; }   // yazim on denetimiyle AYNI esitleme (tcaResyncLocked)

  // ---- QA: donanim arizasi enjeksiyonu (firmware bunlari yalniz verify() ile fark eder)
  /** Cip sifirlanmasi (brown-out): cikis latch'i duser, yon yazmaci varsayilana (hepsi giris) doner. */
  qaChipReset() { this.latch = 0; this.cfgHw = 0xFF; }

  /** Beklenmeyen ACIK role (latch'te acik ama firmware kapali sanir): `mask` bitleri acilir. */
  qaForceLatchOn(mask) { this.latch = (this.latch | mask) & 0xFF; }

  /** Rolenin kendiliginden dusmesi: `mask` bitleri latch'ten silinir. */
  qaDropLatch(mask) { this.latch = this.latch & ~mask & 0xFF; }
}

// =============================================================================================
// SmartAutomation
// =============================================================================================
export class Automation {
  /**
   * @param {object} o
   * @param {import('./config_manager.js').ConfigManager} o.config
   * @param {import('./config_manager.js').NvsImage} o.nvs
   * @param {object} o.ext  QA ek modul donanim modeli {present, address, channels, coils[], rawDi[], failWrites}
   * @param {number} [o.timeScale]
   * @param {number} [o.bootHoldMs]  acilis sonrasi komut/DI islenmeyen pencere (firmware: 500 ms)
   * @param {{event?:Function, beep?:Function, changed?:Function, preRestart?:Function, restart?:Function}} [o.hooks]
   */
  constructor({ config, nvs, ext, timeScale = 1, hooks = {}, bootHoldMs = BOOT_HOLD_MS }) {
    this.cm = config;
    this.bootHoldMs = bootHoldMs;
    this.nvs = nvs;
    this.ext = ext;
    this.timeScale = Number(timeScale) > 0 ? Number(timeScale) : 1;
    this.hooks = hooks;
    this.event = (type, fields) => this.hooks.event?.(type, fields);

    this.tca = new TcaDriver({ event: (t, f) => this.event(t, f) });
    this.extGuard = new InterlockGuard();
    this.fsm = Array.from({ length: MAX_PAIRS }, () => new ShutterFsm());
    this.pairValid = new Array(MAX_PAIRS).fill(false);
    this.posSaved = new Array(MAX_PAIRS).fill(0);
    this.posDirty = false;
    this.lastMotionMs = 0;

    this.want = new Array(MAX_TOTAL_RELAYS).fill(false);
    this.hw = new Array(MAX_TOTAL_RELAYS).fill(false);
    this.hwKnown = Array.from({ length: MAX_TOTAL_RELAYS }, (_, i) => i < 8);
    this.impulseActive = new Array(MAX_TOTAL_RELAYS).fill(false);
    this.impulseStart = new Array(MAX_TOTAL_RELAYS).fill(0);
    this.impulseDur = new Array(MAX_TOTAL_RELAYS).fill(0);
    this.adoptNextPoll = new Array(MAX_TOTAL_RELAYS).fill(false);

    this.diGate = new DiGate();
    this.diActTarget = new Array(MAX_TOTAL_DIS).fill(0);
    /** QA: yerel/ek modul giris pinlerinin HAM seviyeleri (true = kontak kapali / DGND ile birlesti). */
    this.rawDi = new Array(MAX_TOTAL_DIS).fill(false);
    this.extDiInit = false;
    this.extEnabledPrev = false;
    this.lastLocalPairMask = 0xFF;
    this.childLockEnabled = false;
    this.seenResetCount = 0;

    this.localRetryLast = 0;
    this.localRetryGap = 0;
    this.localFails = 0;
    this.extRetryLast = 0;
    this.extRetryGap = 0;
    this.extWriteFails = 0;

    this.stateChanged = false;
    this.lastMovePublish = 0;
    this.bootAt = 0;
    this.bootHoldActive = false;
    this.lastId = '';
    this.restartPending = false;
    this.restartAt = 0;
    this.started = false;

    this.extPollLast = 0;
    this.extPollGap = 0;
    this.extFails = 0;
    this.extModuleResponding = false;
    this.lastExtCoilPoll = 0;
    /** ham toplu KAPAT (0x00FF) yansitma istegi (firmware: volatile _rawExtAllOff; rs485Send yazar, loop() tuketir) */
    this.rawExtAllOff = false;

    this.queue = [];
    this.emergencyStopAll = false;
    this.cmdDropped = 0;
    this.guards = Array.from({ length: MAX_PAIRS }, () => ({ start: 0, maxRun: 0, armed: false, tripped: false }));
    this.lastTcaVerify = 0;
    this.nowMs = 0;

    // ---- RS485 hatti (SmartAutomation_Rs485.cpp): UART baud'u, gunluk halka tampon, bloklamayan tarama
    this.rs485Baud = 9600;
    this.rs485Logs = [];
    this.lastExtRx = Buffer.alloc(0);
    this.scan = { state: 'idle', doneAt: 0, finish: null, result: null };
    this.snap = this.#emptySnapshot();
  }

  // --------------------------------------------------------------------------- yardimcilar
  #cfg() { return this.cm.config; }

  #emptySnapshot() {
    return {
      seq: 0, childLock: false, lastId: '', totalRelays: 8, totalPairs: 4, totalDIs: 8, extModuleResponding: false,
      relays: new Array(MAX_TOTAL_RELAYS).fill(false), dis: new Array(MAX_TOTAL_DIS).fill(false),
      shutters: Array.from({ length: MAX_PAIRS }, () => ({ pos: 0, moving: false, dir: 0, target: 255, waiting: false, pendingDir: 0, lastDir: 0, configured: false })),
    };
  }

  markChanged() { this.stateChanged = true; }

  beep(ms, reason = '') { this.hooks.beep?.(ms, reason); }

  /** Relay_SignalFailure(): surucu/emniyet hatasi sinyali. */
  signalFailure(reason) { this.event('failure_signal', { reason }); this.beep(400, 'failure'); }

  pairConfigured(p) {
    const cfg = this.#cfg();
    if (p < 0 || p >= Math.floor(cfg.totalRelays() / 2) || p >= MAX_PAIRS) return false;
    return cfg.relays[2 * p].type === RelayType.SHUTTER_UP && cfg.relays[2 * p + 1].type === RelayType.SHUTTER_DOWN;
  }

  pairHwOff(p) { return !this.hw[2 * p] && !this.hw[2 * p + 1] && this.hwKnown[2 * p] && this.hwKnown[2 * p + 1]; }

  // --------------------------------------------------------------------------- komut kuyrugu (postDeviceCommand)
  /**
   * Her gorevden cagrilabilir. Kuyruk doluysa false (cagiran bunu hata olarak ele alir).
   * SIRA (FIFO): komutlar GELIS SIRASIYLA yurutulur; DURDURMA one gecmez (kullanicinin son niyeti DURDURMA ise ondan SONRA gelir).
   * Kuyruk DOLU iken gelen DURDURMA yine de ASLA kaybolmaz: acil durdurma bayragi kurulur (bkz. #drainCommands).
   */
  post(cmd) {
    const c = { ...cmd, id: String(cmd.id || '').slice(0, 24) };
    const isStop = c.type === CmdType.SHUTTER_STOP || c.type === CmdType.ALL_SHUTTERS_STOP;
    if (this.queue.length < CMD_QUEUE_LEN) {
      this.queue.push(c);
      return true;
    }
    this.cmdDropped++;
    if (isStop) this.emergencyStopAll = true;   // durdurma ASLA kaybolmaz
    return false;
  }

  // --------------------------------------------------------------------------- konum kaliciligi
  #loadShutterPositions() {
    const blob = this.nvs.get('pos');
    const buf = new Array(MAX_PAIRS).fill(0);
    let haveBlob = false;
    if (Array.isArray(blob) && blob.length === MAX_PAIRS) {
      for (let i = 0; i < MAX_PAIRS; i++) buf[i] = Number.isInteger(blob[i]) ? blob[i] : 0;
      haveBlob = true;
    }
    for (let i = 0; i < MAX_PAIRS; i++) {
      if (buf[i] > 100 || buf[i] < 0) buf[i] = 0;
      this.fsm[i].setPosition(buf[i]);
      this.posSaved[i] = haveBlob ? buf[i] : 0xFF;
    }
  }

  /** Tum ciftler TEK yazimda; hareket bittikten POS_SAVE_DELAY_MS sonra ve |delta| >= %2 ise (veya zorla). */
  persistPositions(now, force) {
    if (!this.posDirty && !force) return;
    for (let p = 0; p < MAX_PAIRS; p++) {
      if (this.fsm[p].isMoving() || this.fsm[p].isWaiting()) {
        this.lastMotionMs = now;
        if (!force) return;
      }
    }
    if (!force && u32(now - this.lastMotionMs) < POS_SAVE_DELAY_MS) return;
    const cur = new Array(MAX_PAIRS);
    let need = false;
    for (let p = 0; p < MAX_PAIRS; p++) {
      cur[p] = this.fsm[p].position(now);
      const d = cur[p] - this.posSaved[p];
      if (this.posSaved[p] === 0xFF) need = true;
      else if (d >= POS_SAVE_MIN_DELTA || d <= -POS_SAVE_MIN_DELTA) need = true;
      else if ((cur[p] === 0 || cur[p] === 100) && cur[p] !== this.posSaved[p]) need = true;
    }
    if (!need) { this.posDirty = false; return; }
    this.nvs.put('pos', cur);
    this.posSaved = cur.slice();
    this.posDirty = false;
  }

  applyChildLock(enabled) {
    if (this.childLockEnabled === enabled) return;
    this.childLockEnabled = enabled;
    this.nvs.put('auto', { child_lock: enabled });
    this.event('child_lock', { enabled });
    this.beep(enabled ? 200 : 100, 'child_lock');
    this.markChanged();
  }

  // --------------------------------------------------------------------------- baslatma
  begin(now) {
    if (this.started) return;
    this.started = true;
    const cfg = this.#cfg();

    // Acilista mevcut DI seviyesi "kararli" kabul edilir (kenar uretmez); QA ham seviyeleri bos baslar
    for (let i = 0; i < 8; i++) this.diGate.init(i, this.rawDi[i], now);

    const auto = this.nvs.get('auto');
    this.childLockEnabled = !!(auto && auto.child_lock === true);
    this.#loadShutterPositions();

    this.extEnabledPrev = cfg.ext_module_enabled;
    // Acilis bekleme penceresi (500 ms) surucu olu zamanini da karsilar; pencere kisaltilmissa (QA/test) eksik kismi baslangic damgasindan dusulur
    const initAt = u32(now + this.bootHoldMs - BOOT_HOLD_MS);
    this.nowMs = now;
    this.tca.init(initAt);
    this.syncConfig(now);
    this.rs485Begin(cfg.rs485_baud, now);

    // POWER-ON STATE: lambalar KESINLIKLE KAPALI; panjurlar hareket etmez
    const totalR = cfg.totalRelays();
    this.want.fill(false);
    if (this.tca.writeOutputs(0x00, now)) this.syncLocalHw(0x00);
    if (cfg.ext_module_enabled && totalR > 8) {
      for (let i = 8; i < totalR; i++) { this.hw[i] = true; this.hwKnown[i] = false; }
      this.extGuard.forceHw((~0n & M64) << 8n & M64);
      if (this.extAllOff()) {
        for (let i = 8; i < totalR; i++) { this.hw[i] = false; this.hwKnown[i] = true; }
        this.extGuard.commit(0n, initAt);
      }
    }
    this.lastTcaVerify = now;
    this.bootAt = now;
    this.bootHoldActive = true;
    this.markChanged();
  }

  // --------------------------------------------------------------------------- yapilandirma esitleme
  syncConfig(now) {
    const cfg = this.#cfg();

    // Fabrika sifirlama: RAM'deki cocuk kilidi da sifirlanir
    const rc = this.cm.resetCount;
    if (rc !== this.seenResetCount) {
      this.seenResetCount = rc;
      if (this.childLockEnabled) {
        this.childLockEnabled = false;
        this.event('child_lock', { enabled: false, reason: 'factory_reset' });
        this.markChanged();
      }
    }

    // Ek modul acildi/kapandi: ek roleler "bilinmiyor"a doner ve KAPALI olmasi dogrulanana dek yeniden yazilir
    if (cfg.ext_module_enabled !== this.extEnabledPrev) {
      const wasEnabled = this.extEnabledPrev;
      this.extEnabledPrev = cfg.ext_module_enabled;
      if (wasEnabled && !cfg.ext_module_enabled) {
        for (let p = 4; p < MAX_PAIRS; p++) {
          if (this.fsm[p].isMoving() || this.fsm[p].isWaiting()) this.fsm[p].forceStop(now);
          this.#disarmGuard(p);
        }
        this.extAllOff();
      }
      for (let i = 8; i < MAX_TOTAL_RELAYS; i++) {
        this.want[i] = false;
        this.hw[i] = cfg.ext_module_enabled;
        this.hwKnown[i] = false;
        this.impulseActive[i] = false;
        this.adoptNextPoll[i] = false;
      }
      this.extGuard.forceHw(cfg.ext_module_enabled ? ((~0n & M64) << 8n) & M64 : 0n);
      this.extFails = 0;
      this.extPollLast = now;
      this.extPollGap = 0;
      this.extRetryGap = 0;
      this.extDiInit = false;
      this.extModuleResponding = false;
    }

    let pairMaskExt = 0;
    let pairMaskLocal = 0;
    for (let p = 0; p < MAX_PAIRS; p++) {
      const valid = this.pairConfigured(p);
      if (valid !== this.pairValid[p]) {
        if (!valid && (this.fsm[p].isMoving() || this.fsm[p].isWaiting())) {
          this.event('shutter_pair_invalidated', { pair: p + 1 });
          this.fsm[p].forceStop(now);
        }
        this.pairValid[p] = valid;
      }
      if (valid) {
        if (p < 4) pairMaskLocal |= (1 << p);
        else pairMaskExt |= (1 << p);
        if (!this.fsm[p].isMoving() && !this.fsm[p].isWaiting()) {
          const sc = (ms) => Math.max(1, Math.round(ms / this.timeScale));
          const upMs = cfg.relays[2 * p].runtime_sec * 1000;
          const downMs = cfg.relays[2 * p + 1].runtime_sec * 1000;
          this.fsm[p].setTiming(sc(upMs), sc(downMs), SHUTTER_DEAD_TIME_MS, sc(SHUTTER_OVERRUN_MS));
        }
      }
    }
    if (pairMaskLocal !== this.lastLocalPairMask) {
      this.lastLocalPairMask = pairMaskLocal;
      this.tca.setShutterPairs(pairMaskLocal);
    }
    this.extGuard.setShutterPairs(pairMaskExt >>> 0);
  }

  // --------------------------------------------------------------------------- komut yurutme
  /**
   * Kuyruk doluyken gelen (yazilamayan) DURDURMA: once HEMEN durdur, kuyruktakiler (DURDURMA'dan ONCE gelmis olanlar) yurutulduktan
   * sonra bir kez daha durdur. Kuyruk bu turda tumuyle bosalmadiysa bayrak korunur. Turda en cok 12 komut.
   */
  #drainCommands(now) {
    let stopAfter = false;
    if (this.emergencyStopAll) {
      this.emergencyStopAll = false;
      stopAfter = true;
      this.event('queue_full_stop', {});
      this.executeCommand(makeCommand(CmdType.ALL_SHUTTERS_STOP, CmdSource.MQTT), now);
    }
    let emptied = false;
    for (let n = 0; n < 12; n++) {
      if (this.queue.length === 0) { emptied = true; break; }
      this.executeCommand(this.queue.shift(), now);
    }
    if (stopAfter) {
      if (!emptied) this.emergencyStopAll = true;       // kalan eski komutlar sonraki turda; durdurma yinelenir
      this.executeCommand(makeCommand(CmdType.ALL_SHUTTERS_STOP, CmdSource.MQTT), now);
    }
  }

  /** TEK mutasyon noktasi. @returns {boolean} basarili mi (basarisiz komut last_id'yi YANKILAMAZ) */
  executeCommand(cmd, now) {
    const cfg = this.#cfg();
    const totalR = cfg.totalRelays();
    const totalPairs = Math.floor(totalR / 2);

    const isStop = cmd.type === CmdType.SHUTTER_STOP || cmd.type === CmdType.ALL_SHUTTERS_STOP;
    if (this.restartPending && !isStop) {
      this.event('cmd_rejected', { source: cmd.source, cmd: cmd.type, reason: 'restart_pending' });
      return false;
    }

    const idx = cmd.index > 0 ? cmd.index - 1 : 0xFF;
    let ok = true;
    let reason = '';

    switch (cmd.type) {
      case CmdType.RELAY_SET:
      case CmdType.RELAY_TOGGLE: {
        if (idx >= totalR) { ok = false; reason = 'invalid_relay'; break; }
        const rtype = cfg.relays[idx].type;
        // Acik komut, ham TOGGLE sonrasi bekleyen "fiziksel durumu benimse" istegini GECERSIZ kilar: kullanicinin son istegi kazanir
        // (aksi halde modul susup geri geldiginde coil yoklamasi fiziksel ACIK durumu istenen durum diye benimser, KAPAT komutu kaybolurdu).
        this.adoptNextPoll[idx] = false;
        if (rtype === RelayType.SHUTTER_UP || rtype === RelayType.SHUTTER_DOWN) {
          const p = Math.floor(idx / 2);
          if (!this.pairConfigured(p)) { ok = false; reason = 'orphan_shutter_relay'; break; }
          const isUp = rtype === RelayType.SHUTTER_UP;
          let on;
          if (cmd.type === CmdType.RELAY_SET) on = cmd.value !== 0;
          else on = !(this.fsm[p].isMoving() || this.fsm[p].isWaiting());
          if (on && p >= 4 && this.scan.state === 'running') { ok = false; reason = 'rs485_scan_running'; break; }   // tarama hatti tutarken ek modul panjuru baslatilmaz
          if (on) { if (isUp) this.fsm[p].cmdUp(now); else this.fsm[p].cmdDown(now); } else this.fsm[p].cmdStop(now);
        } else if (rtype === RelayType.IMPULSE) {
          const on = cmd.type === CmdType.RELAY_SET ? cmd.value !== 0 : !this.impulseActive[idx];
          if (on) { this.#startImpulse(idx, now); this.beep(100, 'impulse'); } else { this.impulseActive[idx] = false; this.want[idx] = false; }
        } else {
          const on = cmd.type === CmdType.RELAY_SET ? cmd.value !== 0 : !this.want[idx];
          this.want[idx] = on;
          this.beep(80, 'relay');
        }
        break;
      }
      case CmdType.SHUTTER_UP:
      case CmdType.SHUTTER_DOWN:
      case CmdType.SHUTTER_STOP:
      case CmdType.SHUTTER_STEP:
      case CmdType.SHUTTER_POS: {
        if (idx >= totalPairs || !this.pairConfigured(idx)) { ok = false; reason = 'not_a_shutter_pair'; break; }
        // Tarama hatti (RS485 mutex'i) tutarken ek module KAPAT gonderilemez: hareket baslatilmaz (DURDURMA serbest)
        if (idx >= 4 && cmd.type !== CmdType.SHUTTER_STOP && this.scan.state === 'running') { ok = false; reason = 'rs485_scan_running'; break; }
        if (cmd.type === CmdType.SHUTTER_UP) this.fsm[idx].cmdUp(now);
        else if (cmd.type === CmdType.SHUTTER_DOWN) this.fsm[idx].cmdDown(now);
        else if (cmd.type === CmdType.SHUTTER_STOP) this.fsm[idx].cmdStop(now);
        else if (cmd.type === CmdType.SHUTTER_STEP) this.fsm[idx].cmdStep(now);
        else {
          if (cmd.value < 0 || cmd.value > 100) { ok = false; reason = 'bad_position'; break; }
          this.fsm[idx].cmdPosition(now, cmd.value);
        }
        break;
      }
      case CmdType.ALL_LIGHTS_OFF: {
        for (let i = 0; i < totalR; i++) if (cfg.relays[i].type === RelayType.LIGHT) { this.want[i] = false; this.adoptNextPoll[i] = false; }   // acik komut bekleyen benimsemeyi gecersiz kilar
        this.beep(300, 'all_lights_off');
        break;
      }
      case CmdType.ALL_SHUTTERS_UP:
      case CmdType.ALL_SHUTTERS_DOWN:
      case CmdType.ALL_SHUTTERS_STOP: {
        for (let p = 0; p < totalPairs; p++) {
          if (!this.pairValid[p]) continue;
          if (p >= 4 && cmd.type !== CmdType.ALL_SHUTTERS_STOP && this.scan.state === 'running') continue;   // tarama suruyor
          if (cmd.type === CmdType.ALL_SHUTTERS_UP) this.fsm[p].cmdUp(now);
          else if (cmd.type === CmdType.ALL_SHUTTERS_DOWN) this.fsm[p].cmdDown(now);
          else this.fsm[p].cmdStop(now);
        }
        break;
      }
      case CmdType.SET_CHILD_LOCK:
        this.applyChildLock(cmd.value !== 0);
        break;
      case CmdType.SET_RUNTIME: {
        if (idx >= totalPairs || !this.pairConfigured(idx) || cmd.value < SHUTTER_RUNTIME_MIN_SEC || cmd.value > SHUTTER_RUNTIME_MAX_SEC) {
          ok = false; reason = 'invalid_set_runtime'; break;
        }
        if (this.fsm[idx].isMoving() || this.fsm[idx].isWaiting()) { ok = false; reason = 'shutter_busy'; break; }
        const rUp = idx * 2;
        const rDown = rUp + 1;
        cfg.relays[rUp].runtime_sec = cmd.value;
        cfg.relays[rDown].runtime_sec = cmd.value;
        this.cm.saveRelayRuntime(rUp);
        this.cm.saveRelayRuntime(rDown);
        const sc = (ms) => Math.max(1, Math.round(ms / this.timeScale));
        this.fsm[idx].setTiming(sc(cmd.value * 1000), sc(cmd.value * 1000), SHUTTER_DEAD_TIME_MS, sc(SHUTTER_OVERRUN_MS));
        break;
      }
      default:
        ok = false; reason = 'unknown_type';
        break;
    }

    if (ok) {
      if (cmd.id) this.lastId = String(cmd.id).slice(0, 24);
      this.markChanged();
      this.event('cmd_applied', { source: cmd.source, cmd: cmd.type, index: cmd.index, value: cmd.value, id: cmd.id || undefined });
    } else {
      this.event('cmd_rejected', { source: cmd.source, cmd: cmd.type, index: cmd.index, reason });
    }
    return ok;
  }

  // --------------------------------------------------------------------------- panjur sarmalayici
  #tickShutters(now) {
    const totalPairs = Math.floor(this.#cfg().totalRelays() / 2);
    for (let p = 0; p < totalPairs && p < MAX_PAIRS; p++) {
      if (!this.pairValid[p]) continue;
      this.fsm[p].tick(now, this.pairHwOff(p));
    }
  }

  #processShutterEvents(now) {
    for (let p = 0; p < MAX_PAIRS; p++) {
      const ev = this.fsm[p].takeEvents();
      if (ev === 0) continue;
      const f = this.fsm[p];
      if ((ev & Ev.STARTED) && f.isMoving()) {
        this.event('shutter_started', { pair: p + 1, dir: f.dir() === 1 ? 'up' : 'down', duration_ms: f.durationMs(), target: f.target() });
        this.beep(150, 'shutter_start');
      }
      if (ev & Ev.RETARGET) this.event('shutter_retarget', { pair: p + 1, target: f.target(), duration_ms: f.durationMs() });
      if ((ev & Ev.DEAD_BEGIN) && f.isWaiting()) this.event('shutter_interlock_wait', { pair: p + 1, pending: f.pendingDir() === 1 ? 'up' : 'down' });
      if (ev & Ev.COMPLETED) this.event('shutter_completed', { pair: p + 1, pos: f.position(now) });
      if (ev & Ev.START_FAILED) { this.event('shutter_start_failed', { pair: p + 1 }); this.signalFailure('shutter_start_failed'); }
      if ((ev & Ev.STOPPED) && !(ev & Ev.COMPLETED)) { this.event('shutter_stopped', { pair: p + 1, pos: f.position(now) }); this.beep(80, 'shutter_stop'); }
      if (ev & Ev.STOPPED) { this.posDirty = true; this.lastMotionMs = now; }

      // Bagimsiz emniyet gorevi icin sure kurma/bozma: durum tabanli (olay sirasindan bagimsiz). Sure, bu yonde ENERJILENDIGI
      // andan sayilir: yeniden hedefleme (start_ms_ yeniden damgasi) emniyet suresini UZATMAZ; ust sinir "tam yol + oturma payi" (runCapMs).
      if (f.isMoving()) {
        let planned = u32(f.startMs() - f.runStartMs()) + f.durationMs();
        if (planned > f.runCapMs()) planned = f.runCapMs();
        this.#armGuard(p, f.runStartMs(), planned + GUARD_MARGIN_MS);
      } else {
        this.#disarmGuard(p);
      }
      this.markChanged();
    }
  }

  #armGuard(p, startMs, maxRunMs) { if (p < MAX_PAIRS) this.guards[p] = { start: startMs, maxRun: maxRunMs, armed: true, tripped: this.guards[p].tripped }; }

  #disarmGuard(p) { if (p < MAX_PAIRS) this.guards[p].armed = false; }

  /** Bagimsiz motor sure asimi emniyeti (guardTask): ana dongu kilitlense bile panjur rolesini keser. */
  #guardTask(now) {
    for (let p = 0; p < MAX_PAIRS; p++) {
      const g = this.guards[p];
      if (!g.armed) continue;
      if (u32(now - g.start) <= g.maxRun) continue;
      this.event('safety_guard_trip', { pair: p + 1, elapsed_ms: u32(now - g.start), max_ms: g.maxRun });
      if (p < 4) {
        this.tca.clearBits(0x03 << (2 * p), now);
      } else {
        const slave = this.#cfg().ext_module_address;
        const ch = (p - 4) * 2 + 1;
        const a = this.extWriteCoil(slave, ch, false);
        const b = this.extWriteCoil(slave, ch + 1, false);
        if (!(a && b)) continue;   // armed kalir: yeniden dene
      }
      g.armed = false;
      g.tripped = true;
    }
  }

  #serviceGuardTrips(now) {
    for (let p = 0; p < MAX_PAIRS; p++) {
      const g = this.guards[p];
      if (!g.tripped) continue;
      g.tripped = false;
      this.fsm[p].forceStop(now);
      this.want[2 * p] = false;
      this.want[2 * p + 1] = false;
      if (p < 4) this.syncLocalHw(this.tca.outputShadow());
      else { this.hwKnown[2 * p] = false; this.hwKnown[2 * p + 1] = false; }
      this.signalFailure('guard_trip');
      this.markChanged();
    }
  }

  // --------------------------------------------------------------------------- darbe roleleri
  #startImpulse(i, now) {
    let dur = this.#cfg().relays[i].runtime_sec;   // ms
    if (dur === 0) dur = IMPULSE_MS_DEFAULT;
    this.want[i] = true;
    this.impulseActive[i] = true;
    this.impulseStart[i] = now;
    this.impulseDur[i] = dur;
  }

  #tickImpulses(now) {
    const totalR = this.#cfg().totalRelays();
    for (let i = 0; i < totalR; i++) {
      if (this.impulseActive[i] && u32(now - this.impulseStart[i]) >= this.impulseDur[i]) {
        this.impulseActive[i] = false;
        this.want[i] = false;
      }
    }
  }

  // --------------------------------------------------------------------------- girisler (DI)
  #checkDigitalInputs(now) {
    for (let i = 0; i < 8; i++) this.#handleDiEdge(i, this.rawDi[i], now);
  }

  /** TEK KAPI: yerel ve ek modul girisleri HAM ornek olarak gelir; DiGate suzgec + cocuk kilidi + acted kararini verir. */
  #handleDiEdge(idx, closed, now) {
    if (idx >= MAX_TOTAL_DIS) return;
    const e = this.diGate.sample(idx, closed, now);
    if (e === Edge.NONE) return;
    const cfg = this.#cfg();
    const d = cfg.dis[idx];
    this.markChanged();
    let shutterActive = false;
    if (d.target_relay >= 1 && d.target_relay <= cfg.totalRelays()) {
      const p = Math.floor((d.target_relay - 1) / 2);
      shutterActive = p < MAX_PAIRS && (this.fsm[p].isMoving() || this.fsm[p].isWaiting());
    }
    const dec = this.diGate.decide(idx, e, d.mode, this.childLockEnabled, shutterActive);
    this.#runDiDecision(idx, dec, now);
  }

  #runDiDecision(idx, dec, now) {
    const cfg = this.#cfg();
    const d = cfg.dis[idx];
    const pressed = dec.edge === Edge.PRESS;
    if (pressed && dec.dropped) {
      this.event('di_blocked_child_lock', { di: idx + 1 });
      this.beep(60, 'child_lock_blocked');
      return;
    }
    let target = d.target_relay;
    if (pressed) this.diActTarget[idx] = target; else target = this.diActTarget[idx];
    if (target < 1 || target > cfg.totalRelays()) {
      this.event(pressed ? 'di_press' : 'di_release', { di: idx + 1, target_relay: target, action: 'no_target' });
      return;
    }
    const pair1 = Math.floor((target - 1) / 2) + 1;
    const src = CmdSource.DI;
    switch (dec.action) {
      case Action.RELAY_TOGGLE: this.executeCommand(makeCommand(CmdType.RELAY_TOGGLE, src, target), now); break;
      case Action.RELAY_ON: this.executeCommand(makeCommand(CmdType.RELAY_SET, src, target, 1), now); break;
      case Action.RELAY_OFF: this.executeCommand(makeCommand(CmdType.RELAY_SET, src, target, 0), now); break;
      case Action.SHUTTER_STEP: this.executeCommand(makeCommand(CmdType.SHUTTER_STEP, src, pair1), now); break;
      case Action.SHUTTER_UP: this.executeCommand(makeCommand(CmdType.SHUTTER_UP, src, pair1), now); break;
      case Action.SHUTTER_DOWN: this.executeCommand(makeCommand(CmdType.SHUTTER_DOWN, src, pair1), now); break;
      case Action.SHUTTER_STOP: this.executeCommand(makeCommand(CmdType.SHUTTER_STOP, src, pair1), now); break;
      default: return;
    }
    this.event(pressed ? 'di_press' : 'di_release', { di: idx + 1, target_relay: target, mode: d.mode, action: dec.action });
  }

  // --------------------------------------------------------------------------- fiziksel cikis katmani
  syncLocalHw(mask) {
    let changed = false;
    for (let i = 0; i < 8; i++) {
      const v = ((mask >> i) & 1) === 1;
      if (this.hw[i] !== v) changed = true;
      this.hw[i] = v;
      this.hwKnown[i] = true;
    }
    if (changed) this.markChanged();
  }

  #stepOutputs(now) {
    const cfg = this.#cfg();
    const totalR = cfg.totalRelays();
    // 1) istenen durum: gecerli panjur ciftlerinde FSM ciktisi; yetim panjur roleleri HER ZAMAN kapali
    for (let i = 0; i < totalR; i++) {
      const t = cfg.relays[i].type;
      if (t === RelayType.SHUTTER_UP || t === RelayType.SHUTTER_DOWN) {
        const p = Math.floor(i / 2);
        if (this.pairValid[p]) {
          const m = this.fsm[p].outMask();
          this.want[i] = i % 2 === 0 ? (m & 1) !== 0 : (m & 2) !== 0;
        } else {
          this.want[i] = false;
        }
      }
    }
    this.#stepLocalOutputs(now);
    this.#stepExtOutputs(now);
  }

  /**
   * Surucu esitlemede (cip sifirlanmasi / dusen role; periyodik verify ya da yazim on denetimi) "golgede ACIK sanilip fiziksel olarak
   * KAPALI bulunan" roleler bildirdiyse: bu bitlere ait HAREKET EDEN panjurlar durdurulur (konum takibi gecersiz) ve bilinen durum
   * donanimla esitlenir. Dusen roleler surucude YENIDEN CEKILMEZ; lamba gibi istenen roleler normal akisla (want) yeniden yazilir.
   */
  #handleLocalDrops(now) {
    const dropped = this.tca.takeDroppedMask();
    if (dropped === 0) return;
    const pairs = [];
    for (let p = 0; p < 4; p++) {
      if (((dropped >> (2 * p)) & 3) === 0) continue;
      if (this.pairValid[p] && (this.fsm[p].isMoving() || this.fsm[p].isWaiting())) { this.fsm[p].forceStop(now); pairs.push(p + 1); }
    }
    this.event('tca_relay_dropped', { mask: dropped, stopped_pairs: pairs });
    this.syncLocalHw(this.tca.outputShadow());
    this.markChanged();
  }

  #stepLocalOutputs(now) {
    let wantLocal = 0;
    for (let i = 0; i < 8; i++) if (this.want[i]) wantLocal |= (1 << i);
    const shadow = this.tca.outputShadow();
    if (wantLocal === shadow) { this.localFails = 0; this.localRetryGap = 0; return; }
    if (u32(now - this.localRetryLast) < this.localRetryGap) return;

    const wr = this.tca.writeEx(wantLocal, now);
    this.#handleLocalDrops(now);                    // yazim on denetimi golgeyi donanima esitlediyse etkilenen panjurlar durdurulur
    if (wr === 'ok') {
      this.localFails = 0;
      this.localRetryGap = 0;
      this.syncLocalHw(this.tca.outputShadow());    // gercekte yazilan (dusen bitler cikarilmis olabilir; onlar sonraki turda normal akisla yazilir)
      return;
    }
    if (wr === 'dead_time') { this.localRetryLast = now; this.localRetryGap = 20; return; }

    // YAZIM BASARISIZ (I2C hatasi ya da surucu interlock'u reddetti)
    this.localFails++;
    this.localRetryLast = now;
    this.localRetryGap = 100;
    this.signalFailure('local_write_failed');
    const shadowNow = this.tca.outputShadow();      // on denetim golgeyi degistirmis olabilir: taze oku
    const safe = shadowNow & wantLocal;             // GUVENLI DURUM: yalniz KAPATMA bitleri
    if (safe !== shadowNow) this.tca.writeOutputs(safe, now);
    this.#handleLocalDrops(now);
    const after = this.tca.outputShadow();
    for (let p = 0; p < 4; p++) {
      const wantBits = (wantLocal >> (2 * p)) & 3;
      const hwBits = (after >> (2 * p)) & 3;
      if (this.pairValid[p] && this.fsm[p].isMoving() && wantBits !== 0 && hwBits === 0) this.fsm[p].onEnergizeFailed(now);
    }
    this.syncLocalHw(after);
  }

  // ---- ek modul (RS485): firmware GERCEK Modbus RTU cerceveleri uretir, QA modul modeli (fw/modbus.js) yanitlar
  /**
   * QA: istek cercevesi -> modul yanit cercevesi. null = yanit yok (modul yok/arizali, UART baud'u modulunkiyle uyusmuyor, hat taramada).
   * @param {Buffer} frame
   */
  #exchange(frame) {
    const x = this.ext;
    if (this.scan.state === 'running') return null;              // tarama hatti (mutex) tutuyor
    if (!x || !x.present || x.failWrites) return null;
    if ((x.baud ?? 9600) !== this.rs485Baud) return null;       // baud uyusmazligi: modul cevap vermez
    return moduleRespond(x, frame);
  }

  /** extWriteCoil(): 0x05 tek coil, yanit istekle BIREBIR yanki olmali; basarida `extModuleResponding` = true. @param {boolean|'toggle'} value */
  extWriteCoil(slave, channel1, value) {
    const addr = channel1 === 0 ? 0x00FF : channel1 - 1;
    const code = value === 'toggle' ? COIL_TOGGLE : (value ? COIL_ON : COIL_OFF);
    const req = buildWriteCoil(slave, addr, code);
    const rx = this.#exchange(req);
    this.lastExtRx = rx ? Buffer.from(rx) : Buffer.alloc(0);
    const chk = checkWriteCoilEcho(req, rx);
    if (chk.status === Status.OK) {
      this.extModuleResponding = true;
      return true;
    }
    this.addRs485Log(`[EXT ROLE HATA] Slave ${slave} CH${channel1} -> ${statusText(chk.status)}${rx && rx.length ? ` (${hexString(rx)})` : ''}`);
    return false;
  }

  extAllOff() { return this.extWriteCoil(this.#cfg().ext_module_address, 0, false); }

  /** extReadBits(): 0x01 / 0x02, count <= 32. @param {'coils'|'inputs'} func @returns {boolean[]|null} */
  extReadBits(slave, func, count) {
    if (count === 0 || count > 32) return null;
    const fc = func === 'coils' ? FC_READ_COILS : FC_READ_DISCRETE_INPUTS;
    const req = buildReadBits(slave, fc, 0, count);
    const rx = this.#exchange(req);
    const chk = checkReadBits(slave, fc, count, rx);
    if (chk.status !== Status.OK) return null;
    return Array.from({ length: count }, (_, i) => getBit(chk.data, chk.byteCount, i));
  }

  /**
   * Panjur rolesi ACILMADAN hemen once (stepExtOutputs): "es KAPALI" bilgisi yalniz onceki KAPAT yazimunun YANKISINA dayaniyorsa
   * yanlis olabilir (modul yankiyi verip komutu uygulamamis ya da baska bir Modbus master coil'i acmis olabilir); gercek coil durumu okunur.
   */
  #extReadbackBeforeEnergize(slave, relayIdx, now) {
    const peer = relayIdx ^ 1;
    const ch = relayIdx - 8 + 1;
    const peerCh = peer - 8 + 1;
    const bits = this.extReadBits(slave, 'coils', Math.max(ch, peerCh));
    if (!bits) return Readback.READ_FAILED;
    const peerOn = bits[peerCh - 1] === true;
    const selfOn = bits[ch - 1] === true;
    if (peerOn) {
      this.event('ext_interlock_peer_on', { relay: relayIdx + 1, peer: peer + 1 });
      this.hw[peer] = true;
      this.hwKnown[peer] = true;
      this.extGuard.commit(InterlockGuard.withRelay(this.extGuard.hw(), peer, true) & M64, now);
      this.markChanged();
      return Readback.PEER_ON;
    }
    if (selfOn) {
      // Kendi rolesi zaten ACIK, oysa "KAPALI" saniliyordu: onceki KAPAT uygulanmamis, motor sure planimizin DISINDA calisiyor olabilir.
      // "Calisiyor say ve devam et" YAPILMAZ: hareket iptal edilir, role kapatilir.
      this.event('ext_interlock_self_on', { relay: relayIdx + 1 });
      this.hw[relayIdx] = true;
      this.hwKnown[relayIdx] = true;
      this.extGuard.commit(InterlockGuard.withRelay(this.extGuard.hw(), relayIdx, true) & M64, now);
      this.markChanged();
      return Readback.ALREADY_ON;
    }
    return Readback.PEER_OFF;
  }

  static #extBackoffMs(fails) { return fails > 5 ? 1600 : 50 * (2 ** fails); }

  #stepExtOutputs(now) {
    const cfg = this.#cfg();
    const totalR = cfg.totalRelays();
    if (!cfg.ext_module_enabled || totalR <= 8) return;
    if (this.scan.state === 'running') return;                       // tarama hatti tutuyor
    if (u32(now - this.extRetryLast) < this.extRetryGap) return;     // geri cekilme (basarisiz yazimdan sonra)
    let budget = 2;                                                  // tur basina en cok 2 RS485 islemi
    const slave = cfg.ext_module_address;

    // 1. gecis: KAPATMALAR (guvenli yon: hicbir kural engellemez)
    for (let i = 8; i < totalR && budget > 0; i++) {
      // KAPAT gerekir mi? (saf kural: extNeedsOffWrite). Ham TOGGLE sonrasi benimse-bekleyen role KAPATILMAZ: aksi halde TOGGLE ile
      // acilan role benimsenmeden ~10-20 ms icinde geri kapatilirdi.
      if (!extNeedsOffWrite(this.want[i], this.hw[i], this.hwKnown[i], this.adoptNextPoll[i])) continue;
      budget--;
      const ch = i - 8 + 1;
      if (this.extWriteCoil(slave, ch, false)) {
        this.extWriteFails = 0;
        this.extRetryGap = 0;
        this.hw[i] = false;
        this.hwKnown[i] = true;
        this.extGuard.commit(InterlockGuard.withRelay(this.extGuard.hw(), i, false) & M64, now);
        this.extGuard.noteOff(i, now);   // onayli KAPAT: olu zaman GERCEK kapanmadan sayilir (inanc yanlis olsa bile)
        this.markChanged();
      } else {
        this.hwKnown[i] = false;
        this.extWriteFails++;
        this.extRetryLast = now;
        this.extRetryGap = Automation.#extBackoffMs(this.extWriteFails);
        return;
      }
    }

    // 2. gecis: ACMALAR
    for (let i = 8; i < totalR && budget > 0; i++) {
      if (!this.want[i] || this.hw[i]) continue;
      const p = Math.floor(i / 2);
      const isShutterRelay = cfg.relays[i].type === RelayType.SHUTTER_UP || cfg.relays[i].type === RelayType.SHUTTER_DOWN;
      if (isShutterRelay && this.pairValid[p] && !this.pairHwOff(p)) continue;   // "esi KAPALI DOGRULANMADAN panjur rolesi ACILMAZ"
      const peer = i ^ 1;
      if (isShutterRelay && !this.hw[peer] && this.hwKnown[peer] && ((this.extGuard.hw() >> BigInt(peer)) & 1n)) {
        this.extGuard.commit(InterlockGuard.withRelay(this.extGuard.hw(), peer, false) & M64, now);
      }
      const newMask = InterlockGuard.withRelay(this.extGuard.hw(), i, true) & M64;
      const r = this.extGuard.check(newMask, now);
      if (r === Result.DEAD_TIME) continue;
      if (r !== Result.OK) {
        this.event('ext_interlock_refused', { relay: i + 1, reason: InterlockGuard.resultText(r) });
        if (isShutterRelay && this.pairValid[p] && this.fsm[p].isMoving()) this.fsm[p].onEnergizeFailed(now);
        this.want[i] = false;
        continue;
      }

      // Panjur: "es KAPALI" bilgisi yazma yankisina dayaniyor; ACMADAN hemen once modulun GERCEK coil durumu okunur.
      // Okuma + yazma birlikte 2 islem butcesi alir.
      if (isShutterRelay && this.pairValid[p]) {
        if (budget < 2) break;                                      // bu turda sigmiyor: sonraki turda
        budget--;
        const rb = this.#extReadbackBeforeEnergize(slave, i, now);
        if (rb === Readback.PEER_ON || rb === Readback.ALREADY_ON) {  // es (ya da kendisi) gercekte ACIK: hareket iptal, bir sonraki turda KAPATILIR
          if (this.fsm[p].isMoving()) this.fsm[p].onEnergizeFailed(now);
          this.want[i] = false;
          continue;
        }
        if (rb === Readback.READ_FAILED) {                          // modul okunamadi: yazma basarisizligiyla ayni islem
          this.extWriteFails++;
          this.extRetryLast = now;
          this.extRetryGap = Automation.#extBackoffMs(this.extWriteFails);
          if (this.fsm[p].isMoving()) this.fsm[p].onEnergizeFailed(now);
          this.want[i] = false;
          return;
        }
      }

      budget--;
      const ch = i - 8 + 1;
      if (this.extWriteCoil(slave, ch, true)) {
        this.extWriteFails = 0;
        this.extRetryGap = 0;
        this.hw[i] = true;
        this.hwKnown[i] = true;
        this.extGuard.commit(newMask, now);
        this.markChanged();
      } else {
        this.extWriteFails++;
        this.extRetryLast = now;
        this.extRetryGap = Automation.#extBackoffMs(this.extWriteFails);
        if (isShutterRelay && this.pairValid[p]) {
          if (this.fsm[p].isMoving()) this.fsm[p].onEnergizeFailed(now);
          this.want[i] = false;
        }
        return;
      }
    }
  }

  /** Ek modul yoklamasi: ~120 ms'de bir girisler, 1,5 sn'de bir coil durumlari; yanitsiz modulde ustel geri cekilme. */
  #pollExtModule(now) {
    const cfg = this.#cfg();
    if (!cfg.ext_module_enabled) return;
    if (this.scan.state === 'running') return;                  // tarama hatti tutuyor
    if (u32(now - this.extPollLast) < this.extPollGap) return;
    const slave = cfg.ext_module_address;
    let extCh = cfg.ext_module_channels;
    if (extCh === 0) extCh = 8;
    if (extCh > 32) extCh = 32;
    const doCoils = u32(now - this.lastExtCoilPoll) >= 1500 || this.lastExtCoilPoll === 0;
    const bits = this.extReadBits(slave, doCoils ? 'coils' : 'inputs', extCh);

    if (!bits) {
      this.extFails = this.extFails < 250 ? this.extFails + 1 : this.extFails;
      if (this.extFails >= 3 && this.extModuleResponding) {
        this.extModuleResponding = false;
        this.event('ext_module_not_responding', { fails: this.extFails });
        for (let i = 8; i < MAX_TOTAL_RELAYS; i++) this.hwKnown[i] = false;
        this.markChanged();
      }
      const sh = this.extFails > 6 ? 6 : this.extFails;
      this.extPollLast = now;
      this.extPollGap = Math.min(5000, 120 * (2 ** sh));
      return;
    }
    if (!this.extModuleResponding) {
      this.extModuleResponding = true;
      this.event('ext_module_responding', {});
      this.markChanged();
    }
    this.extFails = 0;
    this.extPollLast = now;
    this.extPollGap = 120;

    if (doCoils) {
      this.lastExtCoilPoll = now || 1;
      let actual = 0n;
      let changed = false;
      for (let k = 0; k < extCh; k++) {
        const rIdx = 8 + k;
        if (rIdx >= MAX_TOTAL_RELAYS) break;
        const state = bits[k];
        if (state) actual |= (1n << BigInt(rIdx));
        if (this.hw[rIdx] !== state || !this.hwKnown[rIdx]) changed = true;
        this.hw[rIdx] = state;
        this.hwKnown[rIdx] = true;
        if (this.adoptNextPoll[rIdx]) { this.want[rIdx] = state; this.adoptNextPoll[rIdx] = false; }
      }
      if (actual !== this.extGuard.hw()) this.extGuard.commit(actual, now);
      if (changed) this.markChanged();
      return;
    }
    if (!this.extDiInit) {
      this.extDiInit = true;
      for (let k = 0; k < extCh; k++) {
        const dIdx = 8 + k;
        if (dIdx >= MAX_TOTAL_DIS) break;
        this.diGate.init(dIdx, bits[k], now);
      }
      return;
    }
    for (let k = 0; k < extCh; k++) {
      const dIdx = 8 + k;
      if (dIdx >= MAX_TOTAL_DIS) break;
      this.#handleDiEdge(dIdx, bits[k], now);
    }
  }

  #emergencyAllOff(now) {
    for (let p = 0; p < MAX_PAIRS; p++) {
      if (this.fsm[p].isMoving() || this.fsm[p].isWaiting()) this.fsm[p].forceStop(now);
      this.#disarmGuard(p);
    }
    for (let i = 0; i < MAX_TOTAL_RELAYS; i++) { this.want[i] = false; this.impulseActive[i] = false; }
    if (this.tca.writeOutputs(0x00, now)) this.syncLocalHw(0x00);
    const cfg = this.#cfg();
    if (cfg.ext_module_enabled && cfg.totalRelays() > 8) this.extAllOff();
  }

  // --------------------------------------------------------------------------- RS485 servis katmani (SmartAutomation_Rs485.cpp)
  /** addRs485Log(): "[SA:DD:SN] " (cihaz uptime saat:dakika:saniye) onekli, 25 satirlik halka tampon. */
  addRs485Log(line, now = this.nowMs) {
    const sec = Math.floor(u32(now) / 1000);
    this.rs485Logs.push(`[${p2(Math.floor(sec / 3600) % 24)}:${p2(Math.floor(sec / 60) % 60)}:${p2(sec % 60)}] ${line}`);
    if (this.rs485Logs.length > RS485_LOG_MAX) this.rs485Logs.shift();
  }

  rs485GetLogs() { return this.rs485Logs.map((l) => `${l}\n`).join(''); }

  rs485ClearLogs() { this.rs485Logs = []; }

  /** rs485Begin(): UART'i verilen baud ile (yeniden) kurar. Gecersiz baud reddedilir. */
  rs485Begin(baud, now = this.nowMs) {
    if (!RS485_BAUDS.includes(baud)) { this.event('rs485_bad_baud', { baud }); return false; }
    this.rs485Baud = baud;
    this.addRs485Log(`[Sistem] RS485 baslatildi (${baud} baud, 8N1)`, now);
    return true;
  }

  #extChannelIsShutter(channel1) {
    const rIdx = 8 + channel1 - 1;
    if (channel1 === 0 || rIdx >= MAX_TOTAL_RELAYS) return false;
    const t = this.#cfg().relays[rIdx].type;
    return t === RelayType.SHUTTER_UP || t === RelayType.SHUTTER_DOWN;
  }

  /**
   * rs485Send(): ham gonderim (servis terminali). GUVENLIK: ham cerceve interlock'u atlayamaz; yalniz OKUMA islevleri ve panjur olmayan
   * kanala 0x05. Dogrulamayi gecen her cerceve (modul yanit vermese de) true doner; yanit varsa gunluge yazilir.
   * @returns {boolean}
   */
  rs485Send(data, isHex, now = this.nowMs) {
    const text = String(data ?? '');
    if (text.length === 0) return false;
    let frame;
    if (isHex) {
      const clean = text.replace(/[^0-9a-fA-F]/g, '');
      if (clean.length === 0 || clean.length % 2 !== 0) { this.addRs485Log('[Hata] Gecersiz HEX verisi: Uzunluk cift olmalidir!', now); return false; }
      const len = clean.length / 2;
      if (len > 64) { this.addRs485Log('[Hata] HEX verisi cok uzun (en cok 64 bayt).', now); return false; }
      frame = Buffer.from(clean, 'hex');
      if (len < 4) { this.addRs485Log('[RED] Cerceve cok kisa.', now); return false; }
      const fn = frame[1];
      if (fn === FC_READ_COILS || fn === FC_READ_DISCRETE_INPUTS || fn === FC_READ_HOLDING || fn === 0x04) {
        // serbest (salt okuma)
      } else if (fn === FC_WRITE_SINGLE_COIL && len === 8) {
        const addr = (frame[2] << 8) | frame[3];
        const val = (frame[4] << 8) | frame[5];
        const energize = val !== COIL_OFF;
        if (addr === 0x00FF && energize) { this.addRs485Log("[RED] Toplu ACMA (adres 0x00FF) ham gonderimde yasak: panjur interlock'u atlanir.", now); return false; }
        if (addr !== 0x00FF && energize && addr < 32 && this.#extChannelIsShutter(addr + 1)) {
          this.addRs485Log("[RED] Panjur kanalina ham ACMA yasak (interlock/olu zaman ShutterFsm'dedir).", now);
          return false;
        }
      } else {
        this.addRs485Log('[RED] Bu Modbus islevi ham gonderimde yasak (yalniz 0x01-0x04 okuma ve tek coil 0x05).', now);
        return false;
      }
    } else {
      // ASCII: yalnizca yazdirilabilir karakter + CR/LF (gecerli bir Modbus yazma cercevesi 0x00/0xFF bayt gerektirir)
      const bytes = Buffer.from(text, 'utf8');
      const len = Math.min(bytes.length, 64);
      for (let i = 0; i < len; i++) {
        const c = bytes[i];
        if (!((c >= 0x20 && c <= 0x7E) || c === 0x0D || c === 0x0A)) { this.addRs485Log('[RED] ASCII gonderimde kontrol/ASCII-disi karakter yasak.', now); return false; }
      }
      frame = bytes.subarray(0, len);
    }
    const rx = this.#exchange(frame);
    this.addRs485Log(isHex ? `[TX HEX] ${hexString(frame)}` : `[TX ASCII] ${text}`, now);
    if (rx && rx.length > 0) this.addRs485Log(`[RX] HEX: ${hexString(rx)}`, now);
    // Ham tek-coil yazimi (0x05) yapilandirilmis ek module gittiyse UYGULAMA durumuna da yansitilir
    if (isHex && rx && rx.length > 0 && frame.length === 8 && frame[1] === FC_WRITE_SINGLE_COIL) this.#mirrorRawCoilWrite(frame, rx);
    return true;
  }

  /**
   * mirrorRawCoilWrite(): ham tek-coil yazimi (0x05, rs485Send) UYGULAMA durumuna yansitilir. Eskiden ham yazim "istenen durum" (want) ile
   * ilgisizdi: coil yoklamasi (<= ~1,5 sn) rolenin istenen durumuna geri dondururdu (ham AC geri kapanir, ham KAPAT'i panjur FSM'i geri acardi).
   * Artik yapilandirilmis ek module yapilan, YANKISI DOGRULANMIS ham yazim "CH n" komutuyla ayni sonucu verir: ON/OFF -> RELAY_SET,
   * TOGGLE (0x5500) -> RELAY_TOGGLE. Panjur kanalina AC/TOGGLE zaten reddedilmistir; panjur kanalina KAPAT -> RELAY_SET 0 = panjuru DURDURUR.
   * Durum DOGRUDAN degistirilmez (firmware'de rs485Send baska gorevden cagrilabilir): komut kuyruguna yazilir. Toplu KAPAT (0x00FF)
   * rawExtAllOff bayragiyla loop()'ta islenir. Baska slave'e / modul kapaliyken yapilan ham yazim uygulama durumunu ETKILEMEZ.
   */
  #mirrorRawCoilWrite(req, rx) {
    const cfg = this.#cfg();
    if (!cfg.ext_module_enabled || req[0] !== cfg.ext_module_address) return;
    if (checkWriteCoilEcho(req, rx).status !== Status.OK) return;       // yanki dogrulanmadan yansitilmaz
    const addr = (req[2] << 8) | req[3];
    const val = (req[4] << 8) | req[5];
    if (addr === 0x00FF) { if (val === COIL_OFF) this.rawExtAllOff = true; return; }   // (toplu AC zaten reddedilmistir)
    if (addr >= 32) return;
    const relayIdx = 8 + addr;
    if (relayIdx >= cfg.totalRelays()) return;
    const cmdIndex = relayIdx + 1;                                      // komutlarda 1 tabanli
    let posted = true;
    if (val === COIL_ON) posted = this.post(makeCommand(CmdType.RELAY_SET, CmdSource.WEB, cmdIndex, 1));
    else if (val === COIL_OFF) posted = this.post(makeCommand(CmdType.RELAY_SET, CmdSource.WEB, cmdIndex, 0));
    else if (val === COIL_TOGGLE) posted = this.post(makeCommand(CmdType.RELAY_TOGGLE, CmdSource.WEB, cmdIndex));
    if (!posted) this.addRs485Log('[UYARI] Ham yazim modulde uygulandi ama uygulama durumuna yansitilamadi (komut kuyrugu dolu): coil yoklamasi geri dondurebilir.');
  }

  /**
   * applyRawExtAllOff(): ham toplu KAPAT (0x00FF) modulde uygulandi: ek panjurlar durdurulur, ek roleler istenmeyen olarak isaretlenir,
   * durumlari yeniden dogrulanir (KAPAT yeniden gonderilir / coil okunur). Aksi halde coil yoklamasi istenen (ACIK) lambalari geri acardi.
   */
  #applyRawExtAllOff(now) {
    if (!this.rawExtAllOff) return;
    this.rawExtAllOff = false;
    const cfg = this.#cfg();
    if (!cfg.ext_module_enabled) return;
    const totalR = cfg.totalRelays();
    for (let p = 4; p < MAX_PAIRS; p++) {
      if (this.fsm[p].isMoving() || this.fsm[p].isWaiting()) this.fsm[p].forceStop(now);
    }
    for (let i = 8; i < totalR; i++) {
      this.want[i] = false;
      this.impulseActive[i] = false;
      this.adoptNextPoll[i] = false;
      this.hwKnown[i] = false;
    }
    this.markChanged();
  }

  /**
   * rs485ControlExtRelay(): ham ek modul role komutu (servis/web). action: 1 AC, 0 KAPAT, 2 TOGGLE (Waveshare 0x5500).
   * Panjur kanallarini ve channel=0 toplu ACMAYI reddeder (kapatma serbest).
   * @returns {{ok:boolean, responseHex:string}}
   */
  rs485ControlExtRelay(slaveId, channel, action, now = this.nowMs) {
    const out = { ok: false, responseHex: '' };
    if (action > 2) { this.addRs485Log('[RED] Gecersiz eylem (0=KAPAT, 1=AC, 2=TOGGLE).', now); return out; }
    if (channel > 32) { this.addRs485Log('[RED] Gecersiz kanal (0=hepsi, 1..32).', now); return out; }
    const energizes = action !== 0;
    if (channel === 0 && energizes) { this.addRs485Log("[RED] Toplu ACMA (channel=0) yasak: panjur interlock'u atlanir.", now); return out; }
    if (energizes && this.#extChannelIsShutter(channel)) { this.addRs485Log('[RED] Panjur kanalina ham ACMA/TOGGLE yasak (ShutterFsm uzerinden kullanin).', now); return out; }
    if (this.scan.state === 'running') { this.addRs485Log('[RED] RS485 taramasi suruyor.', now); return out; }

    const ok = this.extWriteCoil(slaveId, channel, action === 1 ? true : (action === 0 ? false : 'toggle'));
    out.responseHex = hexString(this.lastExtRx);
    out.ok = ok;
    if (!ok) return out;
    this.addRs485Log(`[EXT ROLE] Slave ${slaveId} CH${channel} Eylem:${action} -> OK`, now);
    // Yapilandirilmis modulun durumunu istenen duruma esitle (baska slave'e ham yazim uygulama durumunu etkilemez)
    const cfg = this.#cfg();
    if (slaveId === cfg.ext_module_address && cfg.ext_module_enabled) {
      const touch = (rIdx) => {
        if (rIdx >= MAX_TOTAL_RELAYS || rIdx >= cfg.totalRelays()) return;
        if (action === 2) {                                  // toggle: sonuc bilinmez -> bir sonraki coil okumasinda benimse
          this.hwKnown[rIdx] = false;
          this.adoptNextPoll[rIdx] = true;
          this.lastExtCoilPoll = 0;                          // coil okumasini one cek
        } else {
          this.want[rIdx] = action === 1;
          this.hw[rIdx] = action === 1;
          this.hwKnown[rIdx] = true;
          this.extGuard.commit(InterlockGuard.withRelay(this.extGuard.hw(), rIdx, action === 1) & M64, now);
          if (action === 0) {
            this.extGuard.noteOff(rIdx, now);                // onayli KAPAT: olu zaman bu andan sayilir (inanc yanlis olsa bile)
            // Ham KAPAT bir panjur kanalini sondurdu ise durum makinesi de durdurulur; aksi halde cikis katmani FSM "hareket ediyor"
            // diye rolenin YENIDEN ACILMASINI isterdi (operatorun durdurma niyeti ciglenirdi).
            const p = rIdx >> 1;
            if (p < MAX_PAIRS && this.pairValid[p] && (this.fsm[p].isMoving() || this.fsm[p].isWaiting())) this.fsm[p].forceStop(now);
          }
        }
      };
      if (channel === 0) { for (let i = 8; i < cfg.totalRelays(); i++) touch(i); } else touch(8 + channel - 1);
      this.markChanged();
    }
    return out;
  }

  // ---- bloklamayan tarama: hat (mutex) tarama suresince tutulur; ek modul yazimlari/yoklamasi bekler
  /** Ek modul panjur ciftlerinden biri hareket ediyor/bekliyor mu? (tarama bu durumda baslatilmaz: hareket eden panjura KAPAT gonderilemezdi) */
  extShutterBusy() {
    for (let p = 4; p < MAX_PAIRS; p++) if (this.fsm[p].isMoving() || this.fsm[p].isWaiting()) return true;
    return false;
  }

  /** @returns {'idle'|'running'|'done'} */
  rs485ScanState() { return this.scan.state; }

  rs485ScanResult() {
    return this.scan.result ? { ...this.scan.result } : { found: false, slaveId: 0, baud: 0, relayStatus: 0, rawHex: '', info: '' };
  }

  /** @returns {boolean} false: zaten calisiyor / gecersiz baud / ek modul panjuru hareket halinde */
  rs485StartScan(now = this.nowMs, specificBaud = 0) {
    if (specificBaud !== 0 && !RS485_BAUDS.includes(specificBaud)) return false;
    if (this.scan.state === 'running') return false;
    if (this.extShutterBusy()) {
      this.addRs485Log('[RED] Tarama baslatilamadi: ek modul panjuru hareket halinde (once durdurun).', now);
      return false;
    }
    const plan = this.#planScan(specificBaud);
    this.scan = { state: 'running', doneAt: u32(now + plan.durationMs), finish: plan, result: this.scan.result };
    this.addRs485Log('[Tarama] Harici role modulu araniyor...', now);
    this.event('rs485_scan_started', { baud: specificBaud || undefined, expected_ms: plan.durationMs });
    return true;
  }

  /** runScanBody() zamanlamasi + sonucu QA modul modeli uzerinden onceden hesaplar (hat tutuldugu icin sonuc taramayla degismez). */
  #planScan(specificBaud) {
    const original = this.rs485Baud || 9600;
    const bauds = specificBaud > 0 ? [specificBaud] : [original, ...[9600, 38400, 115200, 19200, 4800].filter((b) => b !== original)];
    const x = this.ext;
    const alive = !!(x && x.present && !x.failWrites);
    const modBaud = x ? (x.baud ?? 9600) : 9600;
    const res = { found: false, slaveId: 0, baud: 0, relayStatus: 0, rawHex: '', info: 'Hicbir RS485 yaniti alinamadi.' };
    const logs = [];
    let t = 0;
    outer:
    for (const baud of bauds) {
      t += SCAN_BAUD_SWITCH_MS;
      for (let sid = 1; sid <= 8; sid++) {
        t += SCAN_SLAVE_GAP_MS;
        const answers = alive && baud === modBaud && sid === x.address;
        // 1) 0x01 Read Coils (8): yanit CRC/adres/islev/uzunluk dogrulamasindan gecmeli
        if (!answers) {
          t += SCAN_COIL_TIMEOUT_MS + SCAN_HOLD_TIMEOUT_MS;
          continue;
        }
        const rx1 = moduleRespond(x, buildReadBits(sid, FC_READ_COILS, 0, 8));
        t += SCAN_REPLY_MS;
        const c1 = checkReadBits(sid, FC_READ_COILS, 8, rx1);
        if (c1.status === Status.OK) {
          res.found = true; res.slaveId = sid; res.baud = baud;
          res.relayStatus = c1.byteCount >= 1 ? c1.data[0] : 0;
          res.rawHex = hexString(rx1);
          res.info = 'Modbus RTU Standard Yanit (CRC Dogru)';
          logs.push(`[BULUNDU] Slave ID: ${sid} (${baud} baud) | Role Durumu: 0x${res.relayStatus.toString(16)}`);
          break outer;
        }
        // 2) 0x03 Read Holding Registers (2): CRC + adres + islev dogrula
        const rx2 = moduleRespond(x, buildReadBits(sid, FC_READ_HOLDING, 0, 2));
        t += SCAN_REPLY_MS;
        if (rx2 && rx2.length >= 5 && frameCrcOk(rx2) && rx2[0] === sid && rx2[1] === FC_READ_HOLDING) {
          res.found = true; res.slaveId = sid; res.baud = baud;
          res.rawHex = hexString(rx2);
          res.info = 'Modbus 0x03 Register Yaniti (CRC Dogru)';
          logs.push(`[BULUNDU] Slave ID: ${sid} (${baud} baud, 0x03)`);
          break outer;
        }
        t += SCAN_HOLD_TIMEOUT_MS;
      }
    }
    if (!res.found) logs.push('[Tarama] Harici modulden yanit alinamadi. A/B klemenslerini ve 12V/24V beslemeyi kontrol edin.');
    return { durationMs: t, result: res, logs, original };
  }

  #serviceScan(now) {
    if (this.scan.state !== 'running' || ((now - this.scan.doneAt) | 0) < 0) return;
    const plan = this.scan.finish;
    const res = plan.result;
    if (res.found) {
      this.#cfg().rs485_baud = res.baud;                 // kalici kayit cagiranin karari (yapilandirma kaydedilince yazilir)
      this.rs485Baud = res.baud;
    } else {
      this.rs485Baud = plan.original;
    }
    for (const l of plan.logs) this.addRs485Log(l, now);
    this.scan = { state: 'done', doneAt: now, finish: null, result: res };
    this.event('rs485_scan_done', { found: res.found, slave: res.slaveId, baud: res.baud });
    this.markChanged();
  }

  // --------------------------------------------------------------------------- sistem: planli yeniden baslatma
  /** Hareket eden panjurlar HEMEN durdurulur; bekleme suresince yeni hareket komutlari reddedilir. */
  requestRestart(delayMs, now) {
    if (this.restartPending) return;
    this.restartAt = u32(now + delayMs);
    this.restartPending = true;
    this.emergencyStopAll = true;
    this.event('restart_requested', { delay_ms: delayMs });
  }

  #performRestart(now) {
    this.#emergencyAllOff(now);
    this.persistPositions(now, true);
    this.hooks.preRestart?.();
    this.hooks.restart?.();
  }

  // --------------------------------------------------------------------------- ana dongu (Core 1 / loopTask)
  loop(now) {
    this.nowMs = now;
    this.#serviceScan(now);       // tarama gorevi (firmware: ayri gorev; ana donguden bagimsiz ilerler)
    this.#guardTask(now);         // bagimsiz emniyet gorevi (firmware: Core 0 gorevi) bekleme/yeniden baslatma sirasinda da calisir

    if (this.bootHoldActive) {
      if (u32(now - this.bootAt) < this.bootHoldMs) { this.#publishSnapshot(now); return; }
      this.bootHoldActive = false;
    }

    if (this.restartPending) {
      if (this.emergencyStopAll) {
        this.emergencyStopAll = false;
        for (let p = 0; p < MAX_PAIRS; p++) if (this.pairValid[p]) this.fsm[p].cmdStop(now);
      }
      this.#stepOutputs(now);
      this.#processShutterEvents(now);
      if (((now - this.restartAt) | 0) >= 0) { this.#performRestart(now); return; }
      this.#publishSnapshot(now);
      return;
    }

    this.#serviceGuardTrips(now);
    this.syncConfig(now);
    this.#tickShutters(now);
    this.#drainCommands(now);
    this.#applyRawExtAllOff(now);   // ham toplu KAPAT (0x00FF) yansitma istegi
    this.#tickImpulses(now);
    this.#checkDigitalInputs(now);
    this.#stepOutputs(now);
    this.#processShutterEvents(now);
    this.#pollExtModule(now);

    // Yerel cikis yazmaci dogrulamasi (cip sifirlanmasi / dusen role / beklenmeyen bit): 2 sn'de bir. Role acik birakacak her yazim ayrica
    // on denetimle ayni esitlemeyi yapar (TcaDriver.writeEx); burada bekleyen yazim olmasa da hata en gec 2 sn'de gorulur.
    if (u32(now - this.lastTcaVerify) >= TCA_VERIFY_PERIOD_MS) {
      this.lastTcaVerify = now;
      const v = this.tca.verify(now);
      if (v === 'reset') this.event('tca_latch_changed', { action: 'local_shutters_stopped' });
      this.#handleLocalDrops(now);
      if (v === 'reset' || v === 'fixed') this.syncLocalHw(this.tca.outputShadow());
    }

    this.persistPositions(now, false);

    // Hareket surerken konum ~1 sn'de bir yayinlanir (uygulamada ilerleme cubugu); duragan iken yayin yok
    let anyMoving = false;
    for (let p = 0; p < MAX_PAIRS; p++) if (this.fsm[p].isMoving()) { anyMoving = true; break; }
    if (anyMoving && u32(now - this.lastMovePublish) >= 1000) {
      this.lastMovePublish = now;
      this.markChanged();
    }

    this.#publishSnapshot(now);
    if (this.stateChanged) {
      this.stateChanged = false;
      this.hooks.changed?.();
    }
  }

  // --------------------------------------------------------------------------- anlik goruntu
  #publishSnapshot(now) {
    const cfg = this.#cfg();
    const next = this.#emptySnapshot();
    next.totalRelays = cfg.totalRelays();
    next.totalPairs = Math.floor(next.totalRelays / 2);
    next.totalDIs = cfg.totalDIs();
    next.childLock = this.childLockEnabled;
    next.extModuleResponding = cfg.ext_module_enabled && this.extModuleResponding;
    next.lastId = this.lastId;
    for (let i = 0; i < MAX_TOTAL_RELAYS; i++) next.relays[i] = this.hw[i];
    for (let i = 0; i < MAX_TOTAL_DIS; i++) next.dis[i] = this.diGate.stable(i);
    for (let p = 0; p < MAX_PAIRS; p++) {
      const f = this.fsm[p];
      next.shutters[p] = {
        pos: f.position(now), moving: f.isMoving(), dir: f.dir(), target: f.target(), waiting: f.isWaiting(),
        pendingDir: f.pendingDir(), lastDir: f.lastDir(), configured: this.pairValid[p],
      };
    }
    const sig = (s) => JSON.stringify([s.relays, s.dis, s.shutters, s.childLock, s.lastId, s.totalRelays, s.totalDIs, s.extModuleResponding]);
    next.seq = this.snap.seq;
    if (sig(next) !== this.snapSig) { next.seq = this.snap.seq + 1; this.snapSig = sig(next); }
    this.snap = next;
  }

  getSnapshot() { return this.snap; }

  isChildLockEnabled() { return this.childLockEnabled; }

  // --------------------------------------------------------------------------- QA
  /** QA: bir duvar butonunun HAM kontak seviyesi (true = kapali). Isleme loop() icinde, suzgec ile olur. */
  setRawDi(idx, closed) { this.rawDi[idx] = !!closed; }

  /** QA: panjurun ic durumu (FSM). */
  internalShutter(p, now) {
    const f = this.fsm[p];
    return {
      pair: p + 1, configured: this.pairValid[p], pos: f.position(now), moving: f.isMoving(), waiting: f.isWaiting(), dir: f.dir(),
      pending_dir: f.pendingDir(), last_dir: f.lastDir(), target: f.target(), dead_time_active: f.deadTimeActive(),
      duration_ms: f.durationMs(), up_ms: f.upMs(), down_ms: f.downMs(),
    };
  }
}
