// MqttHostPolicy.h (firmware) JavaScript portu: bulut (MQTT) sunucu adi kilidi. SAF MANTIK.
//
// Sahip karari (2026-10-09): POST /api/mqtt/config (ve firmware'de bootstrap yaniti) panoyu yalniz derlemeye gomulu izin listesindeki bir
// sunucuya yonlendirebilir: DEFAULT_MQTT_SERVER + -DAHBU_MQTT_HOST_ALLOW="h1,h2" (virgulle ayrilir, bosluklar kirpilir, bos ogeler yok
// sayilir; buyuk/kucuk harf duyarsiz TAM eslesme). Listede olmayan ad -> 400 host_not_allowed. Bos/verilmemis "server" mevcut sunucuyu korur.
// Simulatorde derleme bayraginin karsiligi DeviceSimulator `mqttHostAllow` secenegidir (QA test sunuculari).
import { DEFAULT_MQTT_SERVER } from './sysconfig.js';

/** Ana makine adi: harf/rakam/'.'/'-', 1..63, '.' veya '-' ile baslamaz/bitmez */
export function validSyntax(s) {
  if (typeof s !== 'string') return false;
  const n = Buffer.byteLength(s);
  if (n < 1 || n > 63) return false;
  if (s[0] === '.' || s[0] === '-' || s[s.length - 1] === '.' || s[s.length - 1] === '-') return false;
  return /^[A-Za-z0-9.-]+$/.test(s);
}

/** host, def ya da extra (virgullu liste) icindeki bir ada TAM esit mi? Sozdizimi bozuk ad hic kabul edilmez. */
export function allowedIn(host, def, extra) {
  if (!validSyntax(host)) return false;
  const h = host.toLowerCase();
  if (typeof def === 'string' && def !== '' && def.toLowerCase() === h) return true;
  if (typeof extra !== 'string') return false;
  return extra.split(',').map((x) => x.replace(/^[ \t]+|[ \t]+$/g, '')).some((x) => x !== '' && x.toLowerCase() === h);
}

export const Check = Object.freeze({ KEEP: 'keep', SET: 'set', INVALID: 'invalid', NOT_ALLOWED: 'not_allowed' });

/** POST /api/mqtt/config "server" alani. extra = derleme bayragi AHBU_MQTT_HOST_ALLOW karsiligi. */
export function checkRequested(host, extra = '') {
  if (host === undefined || host === null || host === '') return Check.KEEP;
  if (!validSyntax(host)) return Check.INVALID;
  return allowedIn(host, DEFAULT_MQTT_SERVER, extra) ? Check.SET : Check.NOT_ALLOWED;
}
