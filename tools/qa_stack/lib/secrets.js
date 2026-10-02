// Calisma zamani sirlari. HICBIRI repoya yazilmaz: yalnizca .runtime/secrets.json (gitignore'lu, 0600).
//
// Politika:
//  - Veriye BAGLI sirlar (db_password, pin_pepper, local_key_secret) pgdata ile birlikte yasar: bunlar
//    degisirse veritabanindaki PIN ozetleri / sifreli yerel anahtarlar / parola gecersiz olur.
//    Yalnizca ilk up'ta (veya reset sonrasi) uretilir.
//  - Digerleri (jwt_secret, admin_api_key, MQTT backend parolasi, EMQX API anahtari/sirri, SMTP parolasi) HER up'ta
//    yeniden uretilir (`up --keep-secrets` ile korunur). JWT_SECRET degisince emulatordeki oturumlar gecersiz olur.
import { randomB64Url, randomHex, readJson, writeJsonAtomic } from './util.js';
import { BACKEND_MQTT_USER } from './config.js';

export const DATA_BOUND = ['db_password', 'pin_pepper', 'local_key_secret'];
export const ROTATING = ['jwt_secret', 'admin_api_key', 'mqtt_backend_pass', 'emqx_api_key', 'emqx_api_secret', 'smtp_pass'];

function generate(name) {
  switch (name) {
    case 'db_password': return randomB64Url(24);
    case 'pin_pepper': return randomB64Url(36);            // 48 karakter (>= 32)
    case 'local_key_secret': return randomHex(32);         // 32 bayt = 64 hex
    case 'jwt_secret': return randomB64Url(48);            // 64 karakter (>= 32)
    case 'admin_api_key': return randomB64Url(36);         // 48 karakter (>= 32)
    case 'mqtt_backend_pass': return randomB64Url(24);
    case 'emqx_api_key': return `qa_${randomHex(8)}`;
    case 'emqx_api_secret': return randomB64Url(24);
    case 'smtp_pass': return randomB64Url(12);
    default: throw new Error(`bilinmeyen sir: ${name}`);
  }
}

/**
 * @param {{secretsFile:string}} rt
 * @param {{keepSecrets?:boolean}} [opts]
 * @returns {{secrets:object, created:boolean, rotated:string[]}}
 */
export function loadOrCreateSecrets(rt, { keepSecrets = false } = {}) {
  const existing = readJson(rt.secretsFile, null);
  const now = new Date().toISOString();
  const rotated = [];
  let secrets;
  let created = false;
  if (!existing || typeof existing !== 'object') {
    created = true;
    secrets = { created_at: now, rotated_at: now, mqtt_backend_user: BACKEND_MQTT_USER };
    for (const k of [...DATA_BOUND, ...ROTATING]) secrets[k] = generate(k);
  } else {
    secrets = { ...existing, mqtt_backend_user: BACKEND_MQTT_USER };
    for (const k of DATA_BOUND) if (!secrets[k]) secrets[k] = generate(k);
    for (const k of ROTATING) {
      if (!secrets[k] || !keepSecrets) {
        secrets[k] = generate(k);
        rotated.push(k);
      }
    }
    if (rotated.length) secrets.rotated_at = now;
  }
  writeJsonAtomic(rt.secretsFile, secrets, { mode: 0o600 });
  return { secrets, created, rotated };
}

/** Yalnizca ad listesi (degerler DEGIL) - durum/log ciktisi icin. */
export const secretNames = () => [...DATA_BOUND, ...ROTATING, 'mqtt_backend_user'];
