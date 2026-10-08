// Firmware src/LocalKeyFp.h portu (pano-5, sozlesme 1 "lk_fp"): yerel anahtar parmak izi.
//   lk_fp = HMAC-SHA256(anahtar = local_key ASCII baytlari, ileti = "ahbu-lk-fp/1|" + buyuk harfli UID) ciktisinin kucuk harf hex
//   gosteriminin ilk 8 karakteri. Firmware'de HMAC mbedtls_md_hmac (ConfigManager::localKeyFp); burada node:crypto.
//   Yayin: provizyonluyken tam GET /api/status ve MQTT state "lk_fp"; provizyonsuzken alan YOK; kisitli durumda ASLA yok.
//   Test vektorleri: ("ABCDEFGH23456789", "AHBU-S3-DD8754") -> "c7076562"; ("k3yTEST-9999", "AHBU-S3-0A1B2C") -> "9814f286".
import crypto from 'node:crypto';

export const MSG_PREFIX = 'ahbu-lk-fp/1|';
export const FP_HEX = 8;
export const UID_MAX = 32;

/** "ahbu-lk-fp/1|" + buyuk harfli UID (onek kucuk harf kalir). UID yok/bos/UID_MAX'tan uzunsa null (firmware: 0). */
export function buildMessage(uid) {
  if (typeof uid !== 'string' || uid.length === 0 || uid.length > UID_MAX) return null;
  return MSG_PREFIX + uid.replace(/[a-z]/g, (c) => c.toUpperCase());
}

/** MAC'in ilk 4 bayti -> 8 kucuk harf hex. */
export const toHex8 = (mac) => Buffer.from(mac).subarray(0, 4).toString('hex');

/** Gecerli iz: tam 8 kucuk harf hex (sunucu kurali /^[0-9a-f]{8}$/). */
export const valid = (fp) => typeof fp === 'string' && /^[0-9a-f]{8}$/.test(fp);

/** Iz; anahtar yok/bos (provizyonsuz) ya da UID gecersizse null. */
export function compute(key, uid) {
  if (typeof key !== 'string' || key.length === 0) return null;
  const msg = buildMessage(uid);
  if (msg === null) return null;
  return toHex8(crypto.createHmac('sha256', Buffer.from(key, 'latin1')).update(msg, 'latin1').digest());
}
