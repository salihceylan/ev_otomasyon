// QA kurulum duzeni (test donanimi; firmware'in parcasi DEGIL).
//
// Sahip karari (2026-10-09): firmware fabrika varsayilaninda HICBIR rolenin sabit rolu yok (roleler "Röle N" genel ac-kapa, DI n -> role n
// TOGGLE); panjur davranisi yalniz servisin yazdigi sablon/yapilandirmadan gelir. Panjur senaryolari sinayan QA donanimi (DeviceSimulator,
// test/_rig.js) bu nedenle ilk acilista (bos NVS) "servis sablonu yazmis" gibi panjur ciftlerini ACIKCA kurar:
//   cift p -> role 2p-1 YUKARI / 2p ASAGI (20 sn), DI 2p-1 -> P<p> STEP butonu, DI 2p bosta.
// Varsayilan [1, 2] eski QA beklentilerini (Salon/Oda panjuru) korur; [] = saf fabrika varsayilani.
import { MAX_TOTAL_RELAYS, RelayType, DIMode, SHUTTER_RUNTIME_DEFAULT_SEC } from './fw/sysconfig.js';

export const QA_SHUTTER_PAIRS = Object.freeze([1, 2]);
const QA_PAIR_NAMES = { 1: 'Salon', 2: 'Oda' };

/** @param {object} c SystemConfig  @param {number[]} pairs 1 tabanli cift numaralari */
export function applyQaShutterLayout(c, pairs = QA_SHUTTER_PAIRS) {
  for (const p of pairs || []) {
    const up = 2 * p - 2;
    if (!Number.isInteger(p) || p < 1 || up + 1 >= MAX_TOTAL_RELAYS) throw new Error(`shutterPairs: gecersiz cift ${p}`);
    const label = QA_PAIR_NAMES[p] || `Panjur ${p}`;
    Object.assign(c.relays[up], { name: `${label} Panjur (Yukari)`, type: RelayType.SHUTTER_UP, runtime_sec: SHUTTER_RUNTIME_DEFAULT_SEC });
    Object.assign(c.relays[up + 1], { name: `${label} Panjur (Asagi)`, type: RelayType.SHUTTER_DOWN, runtime_sec: SHUTTER_RUNTIME_DEFAULT_SEC });
    Object.assign(c.dis[up], { name: `${label} Panjur Butonu`, target_relay: up + 1, mode: DIMode.SHUTTER_STEP });
    Object.assign(c.dis[up + 1], { name: `Giriş ${up + 2} (Boşta / Serbest)`, target_relay: 0, mode: DIMode.TOGGLE });
  }
}
