// Firmware SystemConfig (src/SystemConfig.h) JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_system_config/test_main.cpp) 19 testinin BIREBIR portu.
// C'deki ham bayt dizisi hileleri (NUL'suz memset) JS'te "N-1 bayta kesme" olarak karsilanir.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  SystemConfig, RelayType, DIMode, MAX_TOTAL_RELAYS, MAX_TOTAL_DIS, DEFAULT_MQTT_PORT,
  SHUTTER_RUNTIME_DEFAULT_SEC, IMPULSE_MS_DEFAULT, IMPULSE_MS_MAX, isValidExtChannelCount,
} from '../sim/fw/sysconfig.js';

/** Gecerli bir temel yapilandirma (varsayilan degerlere esdeger): validate() hicbir sey degistirmemeli. */
function makeValid() {
  const c = new SystemConfig();
  c.device_name = 'AHBU Test';
  c.rs485_baud = 9600;
  c.ext_module_address = 1;
  c.mqtt_enabled = true;
  c.mqtt_server = 'broker.example';
  c.mqtt_port = 8884;
  for (let i = 0; i < MAX_TOTAL_RELAYS; i++) {
    c.relays[i].name = 'Role';
    c.relays[i].type = RelayType.LIGHT;
    c.relays[i].runtime_sec = 0;
  }
  c.relays[0].type = RelayType.SHUTTER_UP; c.relays[0].runtime_sec = 20;
  c.relays[1].type = RelayType.SHUTTER_DOWN; c.relays[1].runtime_sec = 20;
  for (let i = 0; i < MAX_TOTAL_DIS; i++) {
    c.dis[i].name = 'DI';
    c.dis[i].target_relay = (i % 8) + 1;
    c.dis[i].mode = DIMode.TOGGLE;
  }
  return c;
}

test('fw_system_config: toplam role sayisi ve uint8 tasmasi yok', () => {
  const c = makeValid();
  assert.equal(c.totalRelays(), 8);
  assert.equal(c.totalDIs(), 8);
  c.ext_module_enabled = true;
  c.ext_module_channels = 8;
  assert.equal(c.totalRelays(), 16);
  c.ext_module_channels = 32;
  assert.equal(c.totalRelays(), 40);
  c.ext_module_channels = 250;       // eski kod: uint8_t t = 8 + 250 = 2
  assert.equal(c.totalRelays(), 40);
  assert.equal(c.totalDIs(), 40);
  c.ext_module_channels = 255;
  assert.equal(c.totalRelays(), 40);
});

test('fw_system_config: gecerli varsayilan benzeri yapilandirmaya dokunulmaz', () => {
  const c = makeValid();
  assert.equal(c.validate(), true);
  assert.equal(c.relays[0].type, RelayType.SHUTTER_UP);
  assert.equal(c.relays[0].runtime_sec, 20);
  assert.equal(c.dis[2].target_relay, 3);
});

test('fw_system_config: ek modul kanal beyaz listesi', () => {
  for (const v of [0, 2, 4, 8, 12, 16, 24, 32]) assert.equal(isValidExtChannelCount(v), true, String(v));
  for (const v of [1, 3, 5, 6, 7, 9, 10, 11, 13, 20, 31, 33, 40, 64, 100, 250, 255]) assert.equal(isValidExtChannelCount(v), false, String(v));
});

test('fw_system_config: gecersiz ek modul kanallari onarilir', () => {
  let c = makeValid();
  c.ext_module_enabled = true;
  c.ext_module_channels = 250;
  assert.equal(c.validate(), false);
  assert.equal(c.ext_module_channels, 8);

  c = makeValid();
  c.ext_module_enabled = false;
  c.ext_module_channels = 7;
  assert.equal(c.validate(), false);
  assert.equal(c.ext_module_channels, 0);
});

test('fw_system_config: etkin ama 0 kanal varsayilan 8 olur', () => {
  const c = makeValid();
  c.ext_module_enabled = true;
  c.ext_module_channels = 0;
  assert.equal(c.validate(), false);
  assert.equal(c.ext_module_channels, 8);
  assert.equal(c.totalRelays(), 16);
});

test('fw_system_config: ek modul adres araligi', () => {
  for (const bad of [0, 248, 255]) {
    const c = makeValid();
    c.ext_module_address = bad;
    assert.equal(c.validate(), false);
    assert.equal(c.ext_module_address, 1);
  }
  for (const good of [1, 2, 100, 247]) {
    const c = makeValid();
    c.ext_module_address = good;
    assert.equal(c.validate(), true);
    assert.equal(c.ext_module_address, good);
  }
});

test('fw_system_config: role tipi araligi', () => {
  const c = makeValid();
  c.relays[4].type = 4;
  c.relays[5].type = 200;
  assert.equal(c.validate(), false);
  assert.equal(c.relays[4].type, RelayType.LIGHT);
  assert.equal(c.relays[5].type, RelayType.LIGHT);
});

test('fw_system_config: panjur calisma suresi 1..300', () => {
  for (const bad of [0, 301, 1000, 65535]) {
    const c = makeValid();
    c.relays[0].runtime_sec = bad;
    assert.equal(c.validate(), false);
    assert.equal(c.relays[0].runtime_sec, SHUTTER_RUNTIME_DEFAULT_SEC);
  }
  for (const good of [1, 20, 300]) {
    const c = makeValid();
    c.relays[1].runtime_sec = good;
    assert.equal(c.validate(), true);
    assert.equal(c.relays[1].runtime_sec, good);
  }
});

test('fw_system_config: darbe suresi araligi', () => {
  let c = makeValid();
  c.relays[6].type = RelayType.IMPULSE;
  c.relays[6].runtime_sec = 0;
  assert.equal(c.validate(), false);
  assert.equal(c.relays[6].runtime_sec, IMPULSE_MS_DEFAULT);

  c = makeValid();
  c.relays[6].type = RelayType.IMPULSE;
  c.relays[6].runtime_sec = 65535;
  assert.equal(c.validate(), false);
  assert.equal(c.relays[6].runtime_sec, IMPULSE_MS_MAX);

  c = makeValid();
  c.relays[6].type = RelayType.IMPULSE;
  c.relays[6].runtime_sec = 500;
  assert.equal(c.validate(), true);
  assert.equal(c.relays[6].runtime_sec, 500);
});

test('fw_system_config: lamba rolesinin runtime degerine dokunulmaz', () => {
  const c = makeValid();
  c.relays[4].runtime_sec = 12345;
  assert.equal(c.validate(), true);
  assert.equal(c.relays[4].runtime_sec, 12345);
});

test('fw_system_config: DI modu ve hedef rolesi araligi', () => {
  let c = makeValid();
  c.dis[3].mode = 5;
  c.dis[4].target_relay = 9;             // ek modul kapali: en cok 8
  assert.equal(c.validate(), false);
  assert.equal(c.dis[3].mode, DIMode.TOGGLE);
  assert.equal(c.dis[4].target_relay, 0);

  c = makeValid();
  c.dis[0].target_relay = 8;
  assert.equal(c.validate(), true);
  assert.equal(c.dis[0].target_relay, 8);

  c = makeValid();
  c.ext_module_enabled = true;
  c.ext_module_channels = 8;             // toplam 16 role
  c.dis[0].target_relay = 16;
  c.dis[1].target_relay = 17;
  assert.equal(c.validate(), false);
  assert.equal(c.dis[0].target_relay, 16);
  assert.equal(c.dis[1].target_relay, 0);
});

test('fw_system_config: Wi-Fi kimlik bilgisi kurallari', () => {
  let c = makeValid();
  c.wifi_ssid = 'EvAgim';
  c.wifi_pass = '12345678';
  c.wifi_sta_enabled = true;
  assert.equal(c.validate(), true);

  c = makeValid();                                 // 7 karakterlik parola WPA icin gecersiz
  c.wifi_ssid = 'EvAgim';
  c.wifi_pass = '1234567';
  c.wifi_sta_enabled = true;
  assert.equal(c.validate(), false);
  assert.equal(c.wifi_ssid, '');
  assert.equal(c.wifi_sta_enabled, false);

  c = makeValid();                                 // acik ag: bos parola gecerli
  c.wifi_ssid = 'Misafir';
  c.wifi_sta_enabled = true;
  assert.equal(c.validate(), true);

  c = makeValid();                                 // 33 bayt SSID gecersiz
  c.wifi_ssid = 'A'.repeat(33);
  c.wifi_sta_enabled = true;
  assert.equal(c.validate(), false);
  assert.equal(c.wifi_ssid, '');

  c = makeValid();                                 // etkin ama SSID bos
  c.wifi_sta_enabled = true;
  assert.equal(c.validate(), false);
  assert.equal(c.wifi_sta_enabled, false);
});

test('fw_system_config: baud beyaz listesi', () => {
  let c = makeValid();
  c.rs485_baud = 12345;
  assert.equal(c.validate(), false);
  assert.equal(c.rs485_baud, 9600);
  for (const good of [4800, 9600, 19200, 38400, 57600, 115200]) {
    c = makeValid();
    c.rs485_baud = good;
    assert.equal(c.validate(), true);
    assert.equal(c.rs485_baud, good);
  }
});

test('fw_system_config: MQTT varsayilaninda kimlik YOK', () => {
  const c = new SystemConfig();                    // sifirlanmis (ConfigManager::applyDefaults ile ayni baslangic)
  c.device_name = 'x';
  c.rs485_baud = 9600;
  c.ext_module_address = 1;
  assert.equal(c.validate(), false);               // bos sunucu/port onarilir
  assert.equal(c.mqtt_port, DEFAULT_MQTT_PORT);
  assert.ok(c.mqtt_server.length > 0);
  assert.equal(c.mqtt_user, '');
  assert.equal(c.mqtt_pass, '');
  assert.equal(c.hasMqttCredentials(), false);
  assert.equal(c.hasLocalKey(), false);
});

test('fw_system_config: hasMqttCredentials uc alan da gerektirir', () => {
  const c = makeValid();
  assert.equal(c.hasMqttCredentials(), false);
  c.mqtt_user = 'd_h_0123456789abcdef';
  assert.equal(c.hasMqttCredentials(), false);
  c.mqtt_pass = 'x';
  assert.equal(c.hasMqttCredentials(), true);
  c.mqtt_server = '';
  assert.equal(c.hasMqttCredentials(), false);
});

test('fw_system_config: yerel anahtar uzunluk ve karakter kumesi', () => {
  const c = makeValid();
  assert.equal(c.setLocalKey(null), false);
  assert.equal(c.setLocalKey(''), false);
  assert.equal(c.setLocalKey('1234567'), false);
  assert.equal(c.setLocalKey('12345678'), true);
  assert.equal(c.hasLocalKey(), true);
  assert.equal(c.local_key, '12345678');
  assert.equal(c.setLocalKey('abcdefghijklmnopqrstuvwxyz012345'), true);              // 32
  assert.equal(c.setLocalKey('abcdefghijklmnopqrstuvwxyz0123456'), false);            // 33
  assert.equal(c.local_key, 'abcdefghijklmnopqrstuvwxyz012345');                      // reddedilen cagri ESKIYI bozmaz
  assert.equal(c.setLocalKey('abcd efgh'), false);
  assert.equal(c.setLocalKey('abcd\tefgh'), false);
  assert.equal(c.setLocalKey('abcd\x01efgh'), false);
  assert.equal(c.setLocalKey('abcdefgü'), false);                                 // ASCII disi (UTF-8: C3 BC)
  assert.equal(c.local_key, 'abcdefghijklmnopqrstuvwxyz012345');
});

test('fw_system_config: AP parolasi kurallari', () => {
  const c = makeValid();
  assert.equal(c.setApPass(null), false);
  assert.equal(c.setApPass('short'), false);
  assert.equal(c.setApPass('Ev Agi 2026'), true);                 // bosluk AP parolasinda serbest
  assert.equal(c.ap_pass, 'Ev Agi 2026');
  assert.equal(c.setApPass('0123456789012345678901234567890123'), false);   // 34
  assert.equal(c.setApPass('abcdefg\x07h'), false);
  assert.equal(c.ap_pass, 'Ev Agi 2026');
});

test('fw_system_config: validate bozuk gizli degerleri temizler', () => {
  let c = makeValid();
  c.local_key = 'abc';                                            // 3 karakter: bozuk
  c.ap_pass = 'kisa';
  assert.equal(c.validate(), false);
  assert.equal(c.hasLocalKey(), false);                           // kismi/bozuk kimlik KALMAZ
  assert.equal(c.ap_pass, '');

  c = makeValid();
  assert.equal(c.setLocalKey('GecerliAnahtar123'), true);
  assert.equal(c.validate(), true);
  assert.equal(c.hasLocalKey(), true);                            // gecerli anahtar korunur
});

test('fw_system_config: NUL sonlandirilmamis metinler sonlandirilir (N-1 bayta kesilir)', () => {
  const c = makeValid();
  c.device_name = 'A'.repeat(32);
  c.relays[3].name = 'B'.repeat(32);
  c.dis[3].name = 'C'.repeat(32);
  c.validate();
  assert.equal(Buffer.byteLength(c.device_name), 31);
  assert.equal(Buffer.byteLength(c.relays[3].name), 31);
  assert.equal(Buffer.byteLength(c.dis[3].name), 31);
});
