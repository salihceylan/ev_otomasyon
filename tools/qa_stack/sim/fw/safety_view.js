// safety/SafetyView.h (firmware) JavaScript portu: guvenlik katmaninin durum gorunumu ve state v:3 eki (spec 3.1-3.2, CONTRACTS 2.6). SAF MANTIK.
//  * Gorunum ADSIZDIR (sensor/eylemci/bolge adlari state'e yazilmaz [B12]).
//  * writeStateExtras(): v:2 nesnesinin SONUNA eklenen, her anahtari virgulle baslayan JSON parcasi. Yapilandirilmamis panoda yalniz
//    caps, boot, bn, time_ok, epoch (+ varsa last_rej) [B14]; cfg/sensors/actuators/safety yalniz katman etkinse.
//  * viewSignature(): yayin tetigi; since_up imzaya girmez. (Firmware CRC32 alir; burada esdeger icerigin metin ozeti.)
//  * Faz 2 (F2.B.7): caps "intrusion"; safety.arm {mode, st, ok, until_up?, aid?, srcs?} yalniz hirsiz sensoru varsa (ya da kip kuruluysa).
import { SensorKind, isControlRole, sensorIdCode, sensorIdText, HZ_GAS, HZ_SMOKE, HZ_WATER, MAX_ZONES } from './sensor_hub.js';
import { ActKind, Medium, isValve, isPulseValve, actKindText, valvePosText } from './actuator_map.js';
import { ZoneSt, zoneStText, rejText, Rej } from './safety_fsm.js';
import { configCrc, safeReasonText, SafeReason } from './safety_config.js';
import { ArmSt, armModeText, armStText } from './intrusion_fsm.js';

const KIND_TEXT = {
  [SensorKind.WATER]: 'water', [SensorKind.GAS]: 'gas', [SensorKind.SMOKE]: 'smoke', [SensorKind.DOOR]: 'door', [SensorKind.WINDOW]: 'window',
  [SensorKind.MOTION]: 'motion', [SensorKind.GENERIC]: 'generic', [SensorKind.ALARM_ACK]: 'alarm_ack', [SensorKind.VALVE_CLOSE]: 'valve_close',
  [SensorKind.GAS_RESET]: 'gas_reset', [SensorKind.ARM_KEY]: 'arm_key',
};
export const sensorKindText = (k) => KIND_TEXT[k] ?? 'unknown';
export const mediumText = (m) => (m === Medium.WATER ? 'water' : m === Medium.GAS ? 'gas' : 'none');
const hazardKindText = (k) => ((k & HZ_GAS) ? 'gas' : (k & HZ_SMOKE) ? 'smoke' : (k & HZ_WATER) ? 'water' : null);
const hex8 = (v) => (v >>> 0).toString(16).padStart(8, '0');

/** loop: cekirdeklerden gorunum. intr: hirsiz cekirdegi (yoksa null: arm yazilmaz). */
export function buildView(cfg, hub, act, core, nowMs, intr = null) {
  const v = {
    configured: core.active() ? 1 : 0, policyOn: core.policyOn() ? 1 : 0, mode: core.safeReason(), rev: cfg.rev >>> 0, crc: configCrc(cfg),
    sens: [], act: [], zones: [], arm: null,
  };
  for (let i = 0; i < hub.count(); i++) {
    const c = hub.config(i);
    v.sens.push({
      code: sensorIdCode(c), kind: c.kind, zone: c.zone, ok: hub.ok(i) ? 1 : 0,
      active: (isControlRole(c.kind) ? hub.rawActive(i) : hub.active(i)) ? 1 : 0,
    });
  }
  for (let i = 0; i < act.count(); i++) {
    const c = act.config(i);
    const a = { relay: c.relay, relay2: isPulseValve(c) ? c.relay2 : 0, kind: c.kind, medium: c.medium, zoneMask: c.zone_mask, pos: 0, on: 0, fb: 0, fault: 0 };
    if (isValve(c)) {
      a.pos = act.pos(i);
      a.fb = act.hasFb(i) && act.fbSeen(i) ? (act.fbClosed(i) ? 2 : 1) : 0;
      a.fault = act.fbFault(i) ? 1 : 0;
    } else {
      a.on = act.output(i) ? 1 : 0;
    }
    v.act.push(a);
  }
  for (let z = 1; z <= MAX_ZONES; z++) {
    if (core.zoneState(z) === ZoneSt.NORMAL) continue;
    const r = core.zone(z);
    v.zones.push({
      id: z, st: r.st, kinds: r.kinds, silenced: r.silenced ? 1 : 0, srcs: (r.srcs || []).slice(0, 8), aid: r.aid || '',
      sinceEpoch: r.sinceEpoch >>> 0, sinceUp: core.sinceUpS(z, nowMs),
    });
  }
  if (intr && intr.present()) {
    const alarm = intr.st() === ArmSt.ALARM;
    v.arm = {
      mode: intr.mode(), st: intr.st(), ok: intr.usable() ? 1 : 0, untilUp: intr.untilUp() >>> 0,
      aid: alarm ? intr.aid() : '', srcs: alarm ? intr.srcs().slice(0, 8) : [],
    };
  }
  return v;
}

export function viewSignature(v) {
  return JSON.stringify({ ...v, zones: v.zones.map(({ sinceUp, ...rest }) => rest) });
}

export function relayActText(v, relay1) {
  for (const a of v.act) if (a.relay === relay1 || (a.relay2 !== 0 && a.relay2 === relay1)) return actKindText(a.kind);
  return null;
}

const zonesArray = (mask) => {
  const z = [];
  for (let i = 0; i < MAX_ZONES; i++) if (mask & (1 << i)) z.push(i + 1);
  return `,"zones":[${z.join(',')}]`;
};

/** @param {{boot:number,bn:number,timeOk:boolean,epoch:number,rejId:string,rej:number}} m */
export function writeStateExtras(v, m) {
  let s = `,"caps":["safety","actuator","event","cfg","intrusion"],"boot":${m.boot >>> 0},"bn":"${hex8(m.bn)}","time_ok":${m.timeOk ? 'true' : 'false'},"epoch":${m.timeOk ? (m.epoch >>> 0) : 0}`;
  if (m.rej !== Rej.OK) s += `,"last_rej":{${m.rejId ? `"id":"${m.rejId}",` : ''}"code":"${rejText(m.rej)}"}`;
  // cfg.safety yapilandirilmamis panoda da yazilir (guvenlik-3): bulut ilk yamayi base_rev ile gonderebilir
  s += `,"cfg":{"safety":{"rev":${v.rev >>> 0},"crc":"${hex8(v.crc)}"}}`;
  if (!v.configured) return s;
  s += `,"sensors":[${v.sens.map((x) => `{"id":"${sensorIdText(x.code)}","src":"${x.code & 0x80 ? 'bridge' : 'di'}","kind":"${sensorKindText(x.kind)}","zone":${x.zone},"active":${x.active ? 'true' : 'false'},"ok":${x.ok ? 'true' : 'false'}}`).join(',')}]`;
  s += `,"actuators":[${v.act.map((a, i) => {
    let t = `{"id":"a${i + 1}","relay":${a.relay}`;
    if (a.relay2) t += `,"relay2":${a.relay2}`;
    t += `,"kind":"${actKindText(a.kind)}"`;
    if (a.kind === ActKind.VALVE) {
      t += `,"medium":"${mediumText(a.medium)}"${zonesArray(a.zoneMask)},"pos":"${valvePosText(a.pos)}","fb":${a.fb === 0 ? 'null' : a.fb === 2 ? 'true' : 'false'}`;
    } else {
      t += `${zonesArray(a.zoneMask)},"on":${a.on ? 'true' : 'false'}`;
    }
    return `${t},"fault":${a.fault ? 'true' : 'false'}}`;
  }).join(',')}]`;
  const mode = v.mode !== SafeReason.NONE ? `safe","reason":"${safeReasonText(v.mode)}` : 'normal';
  s += `,"safety":{"policy":"${v.policyOn ? 'on' : 'off'}","mode":"${mode}","zones":[${v.zones.map((z) => {
    let t = `{"id":${z.id},"st":"${zoneStText(z.st)}"`;
    const k = hazardKindText(z.kinds);
    if (k) t += `,"kind":"${k}"`;
    if (z.aid) t += `,"aid":"${z.aid}"`;
    if (z.sinceEpoch) t += `,"since":${z.sinceEpoch}`;
    t += `,"since_up":${z.sinceUp},"silenced":${z.silenced ? 'true' : 'false'},"srcs":[${z.srcs.map((c) => `"${sensorIdText(c)}"`).join(',')}]}`;
    return t;
  }).join(',')}]`;
  if (v.arm) {
    const a = v.arm;
    s += `,"arm":{"mode":"${armModeText(a.mode)}","st":"${armStText(a.st)}","ok":${a.ok ? 'true' : 'false'}`;
    if (a.st === ArmSt.EXIT || a.st === ArmSt.ENTRY) s += `,"until_up":${a.untilUp >>> 0}`;
    if (a.st === ArmSt.ALARM) {
      if (a.aid) s += `,"aid":"${a.aid}"`;
      s += `,"srcs":[${a.srcs.map((c) => `"${sensorIdText(c)}"`).join(',')}]`;
    }
    s += '}';
  }
  s += '}';
  return s;
}
