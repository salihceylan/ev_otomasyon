// Varsayilan portlar ve adlar. Hepsi 127.0.0.1 uzerindedir (QA yigini LAN'a/internete acilmaz).
// Emulatorden bakis: 10.0.2.2 = makinenin 127.0.0.1'i.

function intEnv(name, def) {
  const v = process.env[name];
  if (v === undefined || v === '') return def;
  const n = Number.parseInt(v, 10);
  return Number.isInteger(n) && n >= 0 && n <= 65535 ? n : def;
}

export const HOST = '127.0.0.1';

export const PORTS = {
  pg: intEnv('QA_PG_PORT', 54329),
  mqtt: intEnv('QA_MQTT_PORT', 1883),
  mqttWs: intEnv('QA_MQTT_WS_PORT', 9001),
  brokerControl: intEnv('QA_BROKER_CONTROL_PORT', 18083),
  supervisor: intEnv('QA_SUPERVISOR_PORT', 18090),
  api: intEnv('QA_API_PORT', 5000),
  smtp: intEnv('QA_SMTP_PORT', 2525),
  // simulatorler: 8081 = provizyonsuz (cihaz AP simulasyonu), 8082 = hazir cihaz, 8083 = ikinci provizyonsuz (16 role)
  sims: [intEnv('QA_SIM_PORT_1', 8081), intEnv('QA_SIM_PORT_2', 8082), intEnv('QA_SIM_PORT_3', 8083)],
};

export const DB = {
  name: 'ev_qa',
  user: 'ev_qa',
};

export const EMULATOR_HOST = '10.0.2.2';

// Emulatordeki uygulamanin gordugu MQTT sunucu adi (sunucunun MQTT_PUBLIC_HOST degeri).
export const DEFAULT_PUBLIC_MQTT_HOST = EMULATOR_HOST;

export const BACKEND_MQTT_USER = 'backend_service';

// Flutter web (Chrome) icin onerilen sabit port: `flutter run -d chrome --web-port=7357`
export const DEFAULT_CORS_ORIGINS = [
  'http://localhost:7357',
  'http://127.0.0.1:7357',
  'http://localhost:8090',
  'http://127.0.0.1:8090',
];

// Simulatorlerin tanidigi (sahte) ev Wi-Fi agi
export const HOME_WIFI_SSID = 'QA-Ev-WiFi';
