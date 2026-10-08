'use strict';

// ==============================================================================
// Yerel anahtar parmak izi (lk_fp) - pano-5, CONTRACTS (yerel anahtar parmak izi)
// ==============================================================================
//
//   lk_fp = HMAC-SHA256(anahtar = local_key ASCII baytlari, ileti = 'ahbu-lk-fp/1|' + BUYUK HARF UID)
//           ciktisinin kucuk harf hex gosteriminin ILK 8 karakteri.
//   UID = state'teki 'device' alani (or. AHBU-S3-DD8754) = devices.device_uuid.
//
// Firmware 1.3.1 provizyonluyken tam GET /api/status'ta ve her MQTT ev/{t}/state'te bildirir. Sunucu ayni formulle
// kendi anahtarlarinin (gecerli / bekleyen / onceki) izini hesaplar ve panonun hangi anahtari tasidigini anlar. Iz
// ANAHTAR DEGILDIR ama yine de gunluge yazilmaz.
//
// Sozlesme test vektorleri:
//   ('ABCDEFGH23456789', 'AHBU-S3-DD8754') -> 'c7076562'
//   ('k3yTEST-9999',     'AHBU-S3-0A1B2C') -> '9814f286'

const crypto = require('crypto');

const FP_PREFIX = 'ahbu-lk-fp/1|';
const FP_RE = /^[0-9a-f]{8}$/;

/**
 * @param {string} localKey   duz yerel anahtar (ASCII)
 * @param {string} deviceUuid pano kimligi (buyuk harfe cevrilir)
 * @returns {string|null} 8 karakter kucuk harf hex; girdi gecersizse null
 */
function localKeyFingerprint(localKey, deviceUuid) {
  if (typeof localKey !== 'string' || localKey.length === 0) return null;
  if (typeof deviceUuid !== 'string' || deviceUuid.trim().length === 0) return null;
  return crypto
    .createHmac('sha256', Buffer.from(localKey, 'utf8'))
    .update(FP_PREFIX + deviceUuid.trim().toUpperCase(), 'utf8')
    .digest('hex')
    .slice(0, 8);
}

/** Panonun bildirdigi iz gecerli bicimde mi (yalniz /^[0-9a-f]{8}$/). */
function isValidFingerprint(value) {
  return typeof value === 'string' && FP_RE.test(value);
}

module.exports = { localKeyFingerprint, isValidFingerprint, FP_PREFIX };
