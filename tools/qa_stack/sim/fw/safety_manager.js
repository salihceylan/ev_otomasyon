// safety/SafetyManager.{h,cpp} + safety/SafetyStore.{h,cpp} + events/EventOutboxRtos.h (firmware) JavaScript portu: guvenlik
// katmaninin BAGLAYICISI. Karar SafetyCore'dadir (safety_fsm.js); burada yalniz NVS, maskeler ve cagri sirasi vardir.
//
// NVS modeli (NvsImage, config_manager.js):
//  * 'safety' (NVS_NS_SAFETY "ahbu_safety"): { ver, cfg, crc } -- cfg = SafetyConfig nesnesi, crc = configCrc(cfg) (firmware'de her
//    blob'un CRC32'si). crc tutmazsa ya da ver farkliysa "bozuk" sayilir (cfg_corrupt). Fabrika sifirlamasi bu alani SILER.
//  * 'latch' (NVS_NS_LATCH "ahbu_latch"): { latch, act_pos: {open, known}, safe_msk: {assert, level} (BigInt; inceleme turu EM-1/EM-5),
//    bootc, crash, siren_s, arm: ArmRecord (Faz 2: hirsiz kipi + alarm bellegi) } -- fabrika sifirlamasi SILMEZ.
//  * Faz 2 (F2.B): IntrusionCore SafetyCore'dan SONRA ayni turda; siren istegi setIntrusionSiren (VEYA, ayri butce); buzzer deseni
//    buzzerPattern() (firmware Buzzer_SetPattern); kapi/pencere kenarlari ContactBus'a.
//  * saveConfig yarida kalirsa (QA: nvs.failKeys 'safety_mid', tek seferlik) "ver" gecersiz kalir: acilis cfg_corrupt (RV-4); yonetici eskiyi
//    geri yazar.
// Yapilandirilmamis panoda active() false: Automation kancalarinin hepsi tutmaz, maskeler 0'dir (spec 2.9).
//
// QA'ya ozgu: bootNonce (bn) ve resetReason disaridan verilebilir (deterministik testler). intrusion=false hirsiz katmanini HIC kurmaz
// (v1.2.0 davranisi; esdegerlik testi: hirsiz sensoru olmayan panoda katman varken iz bit bit ayni).
import { DiSensor, BridgeSensor, SensorHub } from './sensor_hub.js';
import { ActKind, ActuatorCore, applyLatchMask, bootLevelMask, bootSafeMasks, rawCommand, RawDecision, relayBit, isValve } from './actuator_map.js';
import {
  SAFETY_SCHEMA_VER, defaultSafetyConfig, validate, CfgErr, cfgErrText, configCrc, decideBootMode, SafeReason, safeReasonText,
  latchClear, latchValid, latchAny, latchAssert64, latchLevel64, latchZoneMask, crashClear, crashOnBoot, crashStableTick, cloneLatch,
  bootMaskForSystem,
} from './safety_config.js';
import { SafetyCore, Rej, Origin, rejText, SirenKick } from './safety_fsm.js';
import { EventOutbox, EvType, makeEvent, NVSK_LATCH, NVSK_ACT_POS, NVSK_SIREN, NVSK_CRASH, NVSK_ARM, VIA_CLI, VIA_DI } from './event_outbox.js';
import { IntrusionCore, ArmMode, ARM_REC_VER, makeArmRecord } from './intrusion_fsm.js';
import { ContactBus, feedContacts } from './contact_bus.js';
import { safeHoldMasks } from './valve_guard.js';
import { buildView, viewSignature } from './safety_view.js';
import { applyEdit, isLoosening, isGasRelease, isIntrusionLoosening, remapActPos, actuatorIdentityMap, diUseMask } from './safety_cfg_edit.js';
import { touchesLockedZones } from './safety_config.js';
import { VIA_LAN, VIA_LOCAL_WEB, VIA_CLOUD, NVSK_CFG } from './event_outbox.js';
import { isValve as isValveCfg } from './actuator_map.js';

/** ACTUATOR_SET value kodlamasi (firmware SafetyManager.h): 0 guvenli / 1 acma (yerel); MQTT/LAN "to": vana 0x10/0x11, anahtar 0x20/0x21. */
export const ACT_TO = Object.freeze({ closed: 0x10, open: 0x11, off: 0x20, on: 0x21 });
// GAS_LOCAL / ARMED: yalniz VIA_CLOUD (Faz 2 incelemesi G-1; firmware SafetyManager.h)
export const CfgResult = Object.freeze({
  OK: 'ok', CONFLICT: 'conflict', INVALID: 'invalid', LATCHED: 'latched', LOOSEN: 'loosen', STORAGE: 'storage', BUSY: 'busy', GAS_LOCAL: 'gas_local', ARMED: 'armed',
});

const u32 = (x) => x >>> 0;
const clone = (o) => JSON.parse(JSON.stringify(o));

/** firmware CmdType (DeviceCommand.h) guvenlik eki; sim komut sozlesmesi (command_schema.js) WP-F4/Q1'de genisler. */
export const SafetyCmdType = Object.freeze({
  ACTUATOR_SET: 'ACTUATOR_SET', ALARM_ACK: 'ALARM_ACK', ALARM_TEST: 'ALARM_TEST', SAFETY_ARM: 'SAFETY_ARM',
  CLIMATE_TARGET: 'CLIMATE_TARGET', SCENE_RUN: 'SCENE_RUN',
});
export const SAFETY_CMD_TYPES = new Set(Object.values(SafetyCmdType));

/** esp_reset_reason(): beklenmeyen sifirlamalar (cokme dongusu sayaci) */
export const UNEXPECTED_RESETS = new Set(['panic', 'int_wdt', 'task_wdt', 'wdt', 'brownout']);

// ------------------------------------------------------------------------------------------------ SafetyStore (NVS)
function latchNs(nvs) { return nvs.get('latch') || {}; }
function putLatchNs(nvs, patch) { nvs.put('latch', { ...latchNs(nvs), ...patch }); }

export const SafetyStore = {
  /** Relay_Init oncesi: kilit kaydi + acilis guvenli maskesinin yerel seviyesi [EM-1]. @returns {number} yerel guvenli seviye */
  readBootLatchLocal(nvs) {
    const r = latchNs(nvs).latch;
    let v = r && latchValid(r) && latchAny(r) ? (r.m.localLevel & r.m.localAssert) : 0;
    const m = latchNs(nvs).safe_msk;
    if (m) v |= Number(BigInt(m.level) & BigInt(m.assert) & 0xFFn);
    return v;
  },
  /** @returns {{assert: bigint, level: bigint}|null} */
  loadSafeMask(nvs) { const m = latchNs(nvs).safe_msk; return m ? { assert: BigInt(m.assert), level: BigInt(m.level) & BigInt(m.assert) } : null; },
  /** Kalici DI kullanim gecmisi (FW2-2). @returns {bigint|null} */
  loadDiHist(nvs) { const v = latchNs(nvs).di_hist; return v === undefined ? null : BigInt(v); },
  saveDiHist(nvs, m) { if (nvs.failKeys?.has('di_hist')) return false; putLatchNs(nvs, { di_hist: String(m) }); return true; },
  saveSafeMask(nvs, a, l) { if (nvs.failKeys?.has('safe_msk')) return false; putLatchNs(nvs, { safe_msk: { assert: String(a), level: String(l & a) } }); return true; },   // NVS imaji JSON: BigInt metin
  /** @returns {{cfg:object, present:boolean, crcOk:boolean}} */
  loadConfig(nvs) {
    const s = nvs.get('safety');
    if (!s || s.ver === undefined) return { cfg: defaultSafetyConfig(), present: false, crcOk: true };
    if (s.ver !== SAFETY_SCHEMA_VER || !s.cfg || configCrc(s.cfg) !== s.crc) return { cfg: defaultSafetyConfig(), present: true, crcOk: false };
    return { cfg: clone(s.cfg), present: true, crcOk: true };
  },
  /** @returns {boolean} (touched: false donuste NVS'e yazildi mi -- res.touched) */
  saveConfig(nvs, cfg, res = {}) {
    res.touched = false;
    if (nvs.failKeys?.has('safety')) return false;
    res.touched = true;
    if (nvs.failKeys?.has('safety_mid')) {   // RV-4 (QA, tek seferlik): yazim yarida kaldi, ver gecersiz kalir
      nvs.failKeys.delete('safety_mid');
      nvs.put('safety', { ...(nvs.get('safety') || {}), ver: 0 });
      return false;
    }
    nvs.put('safety', { ver: SAFETY_SCHEMA_VER, cfg: clone(cfg), crc: configCrc(cfg) });
    return true;
  },
  loadLatch(nvs) {
    const r = latchNs(nvs).latch;
    return r && latchValid(r) ? cloneLatch(r) : null;
  },
  saveLatch(nvs, r) { if (nvs.failKeys?.has('latch')) return false; putLatchNs(nvs, { latch: cloneLatch(r) }); return true; },
  reserveLatch(nvs) { if (!latchNs(nvs).latch) putLatchNs(nvs, { latch: latchClear() }); },
  /** Hirsiz kipi + alarm bellegi (NVS "ahbu_latch/arm"). @returns {object|null} */
  loadArm(nvs) { const r = latchNs(nvs).arm; return r && r.ver === ARM_REC_VER ? { ...r } : null; },
  saveArm(nvs, r) { if (nvs.failKeys?.has('arm')) return false; putLatchNs(nvs, { arm: { ...r } }); return true; },
  reserveArm(nvs) { if (!latchNs(nvs).arm) putLatchNs(nvs, { arm: makeArmRecord() }); },
  loadActPos(nvs) { const p = latchNs(nvs).act_pos; return { open: p?.open ?? 0, known: p?.known ?? 0 }; },
  saveActPos(nvs, open, known) { if (nvs.failKeys?.has('act_pos')) return false; putLatchNs(nvs, { act_pos: { open, known } }); return true; },
  bumpBootCount(nvs) { const v = u32((latchNs(nvs).bootc || 0) + 1); putLatchNs(nvs, { bootc: v }); return v; },
  loadCrash(nvs) { const c = latchNs(nvs).crash; return c ? { count: c.count, stableWritten: 0 } : crashClear(); },
  saveCrash(nvs, c) { putLatchNs(nvs, { crash: { count: c.count, stableWritten: 0 } }); return true; },
  loadSirenS(nvs) { return latchNs(nvs).siren_s || 0; },
  saveSirenS(nvs, s) { putLatchNs(nvs, { siren_s: s }); return true; },
};

// ------------------------------------------------------------------------------------------------ SafetyManager
/** Hirsiz olaylarinin "via" alani. */
function viaOf(src) {
  if (src === 'web') return VIA_LAN;
  if (src === 'cli') return VIA_CLI;
  if (src === 'di') return VIA_DI;
  return VIA_CLOUD;
}

function originOf(src) {
  if (src === 'di' || src === 'cli') return Origin.LOCAL_DI;
  if (src === 'safety') return Origin.SAFETY;
  return Origin.REMOTE;
}

export class SafetyManager {
  /** @param {{nvs: object, bootNonce?: number, intrusion?: boolean}} o */
  constructor({ nvs, bootNonce, intrusion = true } = {}) {
    this.nvs = nvs;
    this.intrusionOn = intrusion !== false;
    this.fixedNonce = bootNonce;
    this.cfg = defaultSafetyConfig();
    this.hub = new SensorHub();
    this.act = new ActuatorCore();
    this.core = new SafetyCore();
    this.intr = new IntrusionCore();
    this.contacts = new ContactBus();
    this.buzzerPattern_ = 0;
    this.outbox = new EventOutbox();
    this.bridge = new BridgeSensor();
    this.di = new DiSensor(null);
    this.crash = crashClear();
    this.sensorQ = [];
    this.actuatorMask_ = 0n;
    this.sensorDiMask_ = 0n;
    this.bootLevel_ = 0n;
    this.bootAt = 0;
    this.bootCount = 0;
    this.bn = 0;
    this.lastSirenSave = 0;
    this.sirenSaved = 0;
    this.active_ = false;
    this.localReady = false;
    this.extOk = false;
    this.extActuator = false;
    this.scanBlocked_ = false;
    this.keepLocal = 0;
    this.keepExt = 0;
    this.safeMask = { assert: 0n, level: 0n };
    this.relayGuard_ = 0n;   // safe_msk | kilit maskesi: ana yapilandirma dogrulamasi (FW2-1)
    this.diHist = 0n;        // kalici DI kullanim gecmisi (FW2-2)
    this.diHistDirty = false;
    this.cfgUsable = false;
    this.lastRej = { id: '', code: Rej.OK };
    this.rejSeq = 0;
    this.masksGen = 0;
    this.latchedMask = 0;
    this.posSaveForced = false;
    this.view = null;
    this.viewSig_ = '';
    this.lastViewAt = 0;
    this.pending = null;   // loopTask'a postalanan yapilandirma isi (simulator: ayni is parcacigi; isteyen serviceConfig'i bekler)
  }

  /** @param {object} gate DiGate  @param {number} nowMs  @param {object} sys SystemConfig  @param {string} [resetReason] */
  begin(gate, nowMs, sys, resetReason = 'poweron') {
    nowMs = u32(nowMs);
    this.di = new DiSensor(gate);
    this.bootAt = nowMs;
    const { cfg, present, crcOk } = SafetyStore.loadConfig(this.nvs);
    this.cfg = cfg;
    const latch = SafetyStore.loadLatch(this.nvs);
    SafetyStore.reserveLatch(this.nvs);
    const armRec = this.intrusionOn ? SafetyStore.loadArm(this.nvs) : null;
    if (this.intrusionOn) SafetyStore.reserveArm(this.nvs);
    const pos = SafetyStore.loadActPos(this.nvs);
    this.safeMask = SafetyStore.loadSafeMask(this.nvs) || { assert: 0n, level: 0n };
    this.diHist = SafetyStore.loadDiHist(this.nvs) ?? 0n;
    this.bootCount = SafetyStore.bumpBootCount(this.nvs);
    this.crash = SafetyStore.loadCrash(this.nvs);
    const unexpected = UNEXPECTED_RESETS.has(resetReason);
    crashOnBoot(this.crash, unexpected);
    if (unexpected) SafetyStore.saveCrash(this.nvs, this.crash);
    this.bn = this.fixedNonce !== undefined ? u32(this.fixedNonce) : u32(Math.floor(Math.random() * 0x100000000));

    const ve = validate(sys, this.cfg);
    const usable = crcOk && ve === CfgErr.OK;
    const mode = decideBootMode(present, usable, latch, this.cfg, this.crash);
    if (!usable) {
      this.cfg.nSens = 0; this.cfg.sens = [];
      this.cfg.nAct = 0; this.cfg.act = [];
    }
    this.hub.configure(this.cfg.sens, this.cfg.nSens, nowMs);
    this.act.configure(this.cfg.act, this.cfg.nAct, pos.open, pos.known, nowMs);
    this.outbox.begin(this.bn);
    this.core.begin(this.cfg, this.hub, this.act, this.outbox, latch, mode, nowMs);
    if (this.intrusionOn) {
      this.intr.begin(this.cfg, this.hub, this.outbox, armRec, nowMs);   // F2-4: kip geri yuklenir; bellekteki alarm sirensiz
      this.intr.setUsable(this.#intrusionUsable());
      this.core.setIntrusionSiren(this.intr.sirenReq(), this.intr.takeSirenKick(), nowMs);
    }
    this.contacts = new ContactBus();
    if (present && crcOk && ve !== CfgErr.OK) this.outbox.push(makeEvent({ type: EvType.ACTUATOR_FAULT }));
    if (!usable) {   // EM-5: son gecerli yapilandirmanin acilis guvenli maskesi guvenli kipte dayatilir
      const a = bootMaskForSystem(sys, this.safeMask.assert);
      this.core.imposeBootMask(a, this.safeMask.level & a);
      // FW2-1: ana yapilandirmada panjur/darbe ya da olmayan role olan bitler kalici maskeden de dusulur (yalniz bit siler)
      if (a !== this.safeMask.assert && SafetyStore.saveSafeMask(this.nvs, a, this.safeMask.level & a)) {
        this.safeMask = { assert: a, level: this.safeMask.level & a };
      }
    }
    this.cfgUsable = usable;
    if (usable) this.#mergeDiHist(diUseMask(this.cfg));
    if (latch && latchAny(latch)) {
      const s = SafetyStore.loadSirenS(this.nvs);
      this.sirenSaved = s;
      for (let i = 0; i < this.act.count(); i++) if (this.act.config(i).kind === ActKind.SIREN) this.act.setSirenRunMs(i, s * 1000);
    }
    let la = latch ? latchAssert64(latch) : 0n;
    let ll = latch ? latchLevel64(latch) : 0n;
    if (this.core.safeMode()) { const l = this.core.latchMasks(); la = l.assert; ll = l.level; }
    this.#recomputeMasks();
    this.bootLevel_ = applyLatchMask(bootLevelMask(this.cfg.act, this.cfg.nAct, latch ? latchZoneMask(latch) : 0, pos.open, pos.known), la, ll);
    this.#refreshKeep();
    this.#persistSafeMask(nowMs);
    this.validateError = ve === CfgErr.OK ? '' : cfgErrText(ve);
    this.mode = mode === SafeReason.NONE ? 'normal' : safeReasonText(mode);
    this.#refreshView(nowMs, true);
  }

  /** Guvenli kipte sensor tablosu kullanilamiyorsa (cfg_corrupt / latch_orphan) hirsiz katmani etkisiz. */
  #intrusionUsable() {
    const r = this.core.safeReason();
    return r !== SafeReason.CFG_CORRUPT && r !== SafeReason.LATCH_ORPHAN;
  }

  #recomputeMasks() {
    const l = this.core.latchMasks();
    this.actuatorMask_ = this.act.relayMask() | l.assert;
    this.relayGuard_ = this.safeMask.assert | l.assert;
    this.sensorDiMask_ = DiSensor.diMaskOf(this.cfg.sens, this.cfg.nSens) | this.act.fbDiMask();
    this.extActuator = (this.actuatorMask_ >> 8n) !== 0n || (this.sensorDiMask_ >> 8n) !== 0n;
    this.active_ = this.core.active();
    this.latchedMask = this.core.latchedZoneMask();
    this.scanBlocked_ = this.extActuator || this.latchedMask !== 0;
    this.masksGen = (this.masksGen + 1) >>> 0;
  }

  /** Kapanis/yeniden baslatmada korunan bitler: KAPALI komutlu E2C vanalar + guvenli kipte kilit/acilis maskesi [EM-1]. */
  #refreshKeep() {
    const h = this.holdMasks();
    const keep = h.level & h.assert;
    this.keepLocal = Number(keep & 0xFFn);
    this.keepExt = u32(Number((keep >> 8n) & 0xFFFFFFFFn));
  }

  #persistSafeMask(nowMs) {
    if (!this.cfgUsable) return;   // cfg_corrupt: son gecerli maske korunur [EM-5]
    let closed = 0;
    for (let i = 0; i < this.act.count(); i++) if (this.act.closedCmd(i)) closed |= 1 << i;
    const m = bootSafeMasks(this.cfg.act, this.act.count(), closed);
    if (m.assert === this.safeMask.assert && m.level === this.safeMask.level) return;
    if (SafetyStore.saveSafeMask(this.nvs, m.assert, m.level)) {
      this.safeMask = m;
      this.relayGuard_ = m.assert | this.core.latchMasks().assert;
    } else this.#nvsFail(NVSK_ACT_POS, nowMs);
  }

  /** FW2-2: DI kullanim gecmisi yalniz buyur; yazilamazsa RAM'de buyur ve sonraki uygulamada yeniden denenir. */
  #mergeDiHist(used) {
    const n = this.diHist | used;
    if (n !== this.diHist) { this.diHist = n; this.diHistDirty = true; }
    if (this.diHistDirty && SafetyStore.saveDiHist(this.nvs, n)) this.diHistDirty = false;
  }

  /** Ana yapilandirma dogrulamasinin koruma maskesi (validateSystemChange; FW2-1). @returns {bigint} */
  relayGuard() { return this.relayGuard_; }

  /** Durum gorunumu (firmware refreshView): icerik degistiyse ya da 1 sn gectiyse yayinlanir. */
  #refreshView(nowMs, force) {
    const v = buildView(this.cfg, this.hub, this.act, this.core, nowMs, this.intrusionOn ? this.intr : null);
    const sig = viewSignature(v);
    if (!force && sig === this.viewSig_ && u32(nowMs - this.lastViewAt) < 1000) return;
    this.view = v;
    this.viewSig_ = sig;
    this.lastViewAt = u32(nowMs);
  }

  copyView() { return this.view; }
  viewSig() { return this.viewSig_; }
  /** @returns {{boot:number, bn:number, rejId:string, rej:number}} */
  stateMeta() { return { boot: this.bootCount, bn: this.bn, rejId: this.lastRej.id, rej: this.lastRej.code }; }
  safeModeActive() { return this.core.safeMode(); }

  active() { return this.active_; }
  actuatorMask() { return this.actuatorMask_; }
  sensorDiMask() { return this.sensorDiMask_; }
  bootLevelMask() { return this.bootLevel_; }
  setDiHealth(localReady, extOk) { this.localReady = !!localReady; this.extOk = !!extOk; }

  tick(nowMs, epoch = 0) {
    if (!this.active_) return;
    while (this.sensorQ.length) this.bridge.report(this.sensorQ.shift());
    this.di.setLocalReady(this.localReady);
    this.di.setExtOk(this.extOk);
    this.core.tick(nowMs, epoch >>> 0, this.di, this.bridge);
    if (this.intrusionOn) {
      this.intr.setUsable(this.#intrusionUsable());
      this.intr.tick(nowMs, epoch >>> 0);
      this.core.setIntrusionSiren(this.intr.sirenReq(), this.intr.takeSirenKick(), nowMs);
      feedContacts(this.hub, this.contacts, nowMs);
      this.buzzerPattern_ = this.intr.buzzer();               // firmware Buzzer_SetPattern
      if (this.intr.takeKeyError()) this.keyErrorBeeps = (this.keyErrorBeeps || 0) + 1;   // firmware Buzzer_Open_Time(450, 100)
    }
    this.active_ = this.core.active();
    this.latchedMask = this.core.latchedZoneMask();
    this.scanBlocked_ = this.extActuator || this.latchedMask !== 0;
    this.#refreshView(nowMs, false);
  }

  outputs() { return this.core.outputMasks(); }
  /** ValveGuard: KAPALI komutlu vanalarin guvenli seviyeleri + guvenli kipte kilit maskesi. @returns {{assert:bigint, level:bigint}} */
  holdMasks() {
    let closed = 0;
    for (let i = 0; i < this.act.count(); i++) if (this.act.closedCmd(i)) closed |= 1 << i;
    const l = this.core.latchMasks();
    return safeHoldMasks(this.cfg.act, this.act.count(), closed, l.assert, l.level);
  }
  buzzer() { return this.core.buzzer(); }
  /** Hirsiz buzzer deseni (0 kapali, 1 cikis, 2 giris, 3 alarm; tehlike alarmi oncelikli -- firmware WS_GPIO). */
  buzzerPattern() { return this.buzzerPattern_; }

  #nvsFail(key, nowMs) {
    this.outbox.push(makeEvent({ type: EvType.NVS_FAIL, sub: key, atUp: Math.floor(u32(u32(nowMs) - this.bootAt) / 1000) }));
  }

  persist(nowMs) {
    if (!this.active_) return;
    nowMs = u32(nowMs);
    if (this.intrusionOn && this.intr.takeDirty() && !SafetyStore.saveArm(this.nvs, this.intr.record())) this.#nvsFail(NVSK_ARM, nowMs);
    if (this.core.takeLatchDirty()) {
      const rec = this.core.buildLatch();
      if (!SafetyStore.saveLatch(this.nvs, rec)) this.#nvsFail(NVSK_LATCH, nowMs);
      if (!latchAny(rec) && this.sirenSaved !== 0 && SafetyStore.saveSirenS(this.nvs, 0)) this.sirenSaved = 0;
    }
    this.#refreshKeep();
    const posDirty = this.act.takePosDirty() || this.posSaveForced;
    this.posSaveForced = false;
    if (posDirty && !SafetyStore.saveActPos(this.nvs, this.act.posOpenBits(), this.act.posKnownBits())) this.#nvsFail(NVSK_ACT_POS, nowMs);
    if (posDirty) this.#persistSafeMask(nowMs);
    if (this.core.latchedZoneMask() !== 0 && u32(nowMs - this.lastSirenSave) >= 30000) {
      this.lastSirenSave = nowMs;
      let maxMs = 0;
      for (let i = 0; i < this.act.count(); i++) maxMs = Math.max(maxMs, this.act.sirenRunMs(i));
      const s = Math.min(0xFFFF, Math.floor(maxMs / 1000));
      if (s !== this.sirenSaved) { if (SafetyStore.saveSirenS(this.nvs, s)) this.sirenSaved = s; else this.#nvsFail(NVSK_SIREN, nowMs); }
    }
    if (crashStableTick(this.crash, u32(nowMs - this.bootAt)) && !SafetyStore.saveCrash(this.nvs, this.crash)) this.#nvsFail(NVSK_CRASH, nowMs);
  }

  rawRelay(relay1, level, src, nowMs) {
    let d = this.core.rawRelay(relay1, level, originOf(src), nowMs);
    if (d === RawDecision.NOT_ACTUATOR && (this.actuatorMask_ & relayBit(relay1))) {
      const { level: l } = this.core.outputMasks();
      d = (!!level === ((l & relayBit(relay1)) !== 0n)) ? RawDecision.NOOP : RawDecision.REJECT;
    }
    this.active_ = this.core.active();
    return d;
  }

  rawRelayCheck(relay1, level) {
    let d = rawCommand(this.cfg.act, this.cfg.nAct, relay1, level).d;
    if (d === RawDecision.NOT_ACTUATOR && (this.actuatorMask_ & relayBit(relay1))) d = RawDecision.REJECT;
    return d;
  }

  actuatorOfRelay(relay1) { return rawCommand(this.cfg.act, this.cfg.nAct, relay1, false).act; }
  /** MqttTask: uid'siz duz role komutu bu panonun eylemci rolesine mi (RV-2)? */
  isActuatorRelay(relay1) {
    const b = relayBit(relay1);
    if (!b) return false;
    return rawCommand(this.cfg.act, this.cfg.nAct, relay1, false).act >= 0 || (this.actuatorMask_ & b) !== 0n;
  }
  actuatorEngaged(a) {
    if (a >= this.act.count()) return false;
    return isValve(this.act.config(a)) ? !this.act.closedCmd(a) : this.act.on(a);
  }

  handleCommand(cmd, nowMs) {
    const o = originOf(cmd.source);
    let r;
    switch (cmd.type) {
      case SafetyCmdType.ACTUATOR_SET: {
        if (cmd.index < 1 || cmd.index > this.act.count()) { r = Rej.UNKNOWN_ACTUATOR; break; }
        const i = cmd.index - 1;
        let safe;
        if (cmd.value & 0x30) {
          if (((cmd.value & 0x30) === 0x10) !== isValveCfg(this.act.config(i))) { r = Rej.BAD_STATE; break; }
          safe = (cmd.value & 0x01) === 0;
        } else safe = cmd.value === 0;
        r = this.core.actuatorSet(i, safe, o, nowMs);
        break;
      }
      case SafetyCmdType.ALARM_ACK: r = this.core.ack(cmd.index, cmd.aid ? cmd.aid : null, o, cmd.value !== 0, nowMs); break;
      case SafetyCmdType.ALARM_TEST: r = this.core.test(cmd.index, nowMs); break;
      case SafetyCmdType.SAFETY_ARM:   // value: 0 off, 1 away, 2 home
        if (!this.intrusionOn) { r = Rej.UNSUPPORTED; break; }
        if (!(cmd.value >= ArmMode.OFF && cmd.value <= ArmMode.HOME)) { r = Rej.BAD_CMD; break; }
        this.intr.setUsable(this.#intrusionUsable());
        r = this.intr.command(cmd.value, viaOf(cmd.source), nowMs);
        this.core.setIntrusionSiren(this.intr.sirenReq(), this.intr.takeSirenKick(), nowMs);
        break;
      default: r = Rej.UNSUPPORTED;
    }
    this.active_ = this.core.active();
    this.latchedMask = this.core.latchedZoneMask();
    if (r !== Rej.OK) this.noteReject(cmd.id, r);
    return r;
  }

  noteReject(id, code) { this.lastRej = { id: String(id || '').slice(0, 24), code }; this.rejSeq = (this.rejSeq + 1) >>> 0; }
  lastReject() { return { id: this.lastRej.id, code: rejText(this.lastRej.code) }; }
  latched() { return this.core.latchedZoneMask() !== 0; }
  hasExtActuator() { return this.extActuator; }
  scanBlocked() { return this.scanBlocked_; }
  shutdownKeepLocal() { return this.keepLocal; }
  shutdownKeepExt() { return this.keepExt; }
  postBridgeReport(r) { if (this.sensorQ.length >= 16) return false; this.sensorQ.push({ ...r }); return true; }
  copyConfig() { return clone(this.cfg); }

  // ------------------------------------------------------------------------------------------------ yapilandirma yazimi (WP-F4/F5)
  /**
   * Tek ogeli yama: validate(system, safety) -> kilitli bolge -> (LAN) gevsetme yasagi -> rev++ -> NVS -> loopTask uygulamasi.
   * Simulator tek is parcaciklidir: inLoop=false ise is postalanir ve `drainPending` (loop) uygulayana kadar beklenmez -- cagiran sonucu
   * `await` ile alir (Automation her turda serviceConfig cagirir). inLoop=true (CLI) satir ici uygular.
   * @returns {{r:string, err:number, rev:number, crc:number}|Promise<{r:string, err:number, rev:number, crc:number}>}
   */
  submitEdit(e, hasBase, baseRev, via, sys, { inLoop = false, curLevels = 0n, nowMs = 0 } = {}) {
    const cur = clone(this.cfg);
    const o = { r: CfgResult.BUSY, err: CfgErr.OK, rev: cur.rev >>> 0, crc: configCrc(cur) };
    if (hasBase && (baseRev >>> 0) !== (cur.rev >>> 0)) {
      o.r = CfgResult.CONFLICT;
      if (via === VIA_CLOUD) this.outbox.push(makeEvent({ type: EvType.CFG_CONFLICT, rev: cur.rev >>> 0, crc: o.crc }));
      return o;
    }
    const ed = applyEdit(cur, e);
    let err = ed.err;
    if (err === CfgErr.OK) err = validate(sys, ed.out);
    if (err !== CfgErr.OK) { o.r = CfgResult.INVALID; o.err = err; return o; }
    if (touchesLockedZones(cur, ed.out, this.latchedMask)) { o.r = CfgResult.LATCHED; return o; }
    if ((via === VIA_LAN || via === VIA_LOCAL_WEB) && isLoosening(cur, ed.out, this.diHist)) { o.r = CfgResult.LOOSEN; return o; }   // FW2-2
    // Bulut gevsetebilir (D.4) ama gaz vanasini uzaktan acilabilir kilamaz (7.2b-8) ve kurulu kipte hirsiz alarmini zayiflatamaz (F2-3) [G-1]
    if (via === VIA_CLOUD && isGasRelease(cur, ed.out, this.diHist)) { o.r = CfgResult.GAS_LOCAL; return o; }
    if (via === VIA_CLOUD && this.intrusionOn && this.intr.mode() !== ArmMode.OFF && isIntrusionLoosening(cur, ed.out, this.diHist)) { o.r = CfgResult.ARMED; return o; }
    const next = ed.out;
    next.rev = (cur.rev + 1) >>> 0;
    const sr = {};
    if (!SafetyStore.saveConfig(this.nvs, next, sr)) {
      this.#nvsFail(NVSK_CFG, nowMs);
      if (sr.touched) SafetyStore.saveConfig(this.nvs, cur);   // RV-4: yarim yazim -> eski yapilandirma geri yazilir
      o.r = CfgResult.STORAGE;
      return o;
    }
    const finish = (applied) => {
      if (!applied) { SafetyStore.saveConfig(this.nvs, cur); o.r = this.latchedMask ? CfgResult.LATCHED : CfgResult.BUSY; return o; }
      o.r = CfgResult.OK; o.rev = next.rev; o.crc = configCrc(next); return o;
    };
    if (inLoop) return finish(this.#applyConfigOnLoop(next, via, curLevels, nowMs));
    return new Promise((resolve) => { this.pending = { next, via, resolve: (ok) => resolve(finish(ok)) }; });
  }

  configPending() { return this.pending !== null; }

  /** loopTask: bekleyen yapilandirma isini uygular. */
  serviceConfig(nowMs, curLevels) {
    const p = this.pending;
    if (!p) return;
    this.pending = null;
    p.resolve(this.#applyConfigOnLoop(p.next, p.via, curLevels, nowMs));
  }

  #applyConfigOnLoop(next, via, curLevels, nowMs) {
    if (touchesLockedZones(this.cfg, next, this.core.latchedZoneMask())) return false;
    const pos = remapActPos(this.cfg, this.act.posOpenBits(), this.act.posKnownBits(), next, curLevels);
    const fromOld = actuatorIdentityMap(this.cfg, next);
    for (const k of Object.keys(next)) this.cfg[k] = clone(next[k]);   // ayni nesne (cekirdek isaretcisi gecerli kalir)
    this.hub.configure(this.cfg.sens, this.cfg.nSens, nowMs);
    this.act.reconfigure(this.cfg.act, this.cfg.nAct, pos.open, pos.known, fromOld, nowMs);
    this.core.reconfigured(via, nowMs, fromOld);
    if (this.intrusionOn) {
      this.intr.reconfigured(nowMs);
      this.contacts.reset();
      this.core.setIntrusionSiren(this.intr.sirenReq(), SirenKick.NONE, nowMs);
    }
    if (this.core.safeMode()) {
      this.core.setConfigUsable(this.cfg.nAct > 0 && (this.core.latchRecordAssert() & ~this.act.relayMask()) === 0n);
    }
    this.cfgUsable = true;
    this.#mergeDiHist(diUseMask(this.cfg));   // FW2-2
    this.posSaveForced = true;
    this.#recomputeMasks();
    this.#refreshKeep();
    this.#persistSafeMask(nowMs);
    this.#refreshView(nowMs, true);
    if (!this.active_) this.buzzerPattern_ = 0;
    return true;
  }
}

