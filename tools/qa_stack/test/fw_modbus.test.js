// Firmware ModbusRtu.h JS portunun UYUMLULUK testi: firmware'in kendi Unity testlerinin
// (ev_otomasyon_servis_yazilimi/waveshare_s3_demo/test/test_modbus_rtu/test_main.cpp) 17 testinin portu + QA modul modeli testleri.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  crc16, withCrc, buildReadBits, buildWriteCoil, expectedResponseLen, frameCrcOk, checkWriteCoilEcho, checkReadBits, getBit, hexString,
  moduleRespond, Status, COIL_ON, COIL_OFF, COIL_TOGGLE, FC_READ_COILS, FC_READ_DISCRETE_INPUTS, FC_WRITE_SINGLE_COIL,
} from '../sim/fw/modbus.js';

const B = (...a) => Buffer.from(a);

test('fw_modbus: CRC16 bilinen vektorler', () => {
  assert.equal(crc16(B(0x01, 0x05, 0x00, 0x00, 0xFF, 0x00)), 0x3A8C);
  assert.equal(crc16(B(0x01, 0x05, 0x00, 0x00, 0x00, 0x00)), 0xCACD);
  assert.equal(crc16(B(0x01, 0x05, 0x00, 0x00, 0x55, 0x00)), 0x9AF2);
  assert.equal(crc16(B(0x01, 0x01, 0x00, 0x00, 0x00, 0x08)), 0xCC3D);
  assert.equal(crc16(B(0x01, 0x02, 0x00, 0x00, 0x00, 0x08)), 0xCC79);
  assert.equal(crc16(B(0x01, 0x03, 0x00, 0x00, 0x00, 0x02)), 0x0BC4);
});

test('fw_modbus: buildWriteCoil belgelenmis cerceveleri uretir', () => {
  assert.deepEqual([...buildWriteCoil(1, 0, COIL_ON)], [0x01, 0x05, 0x00, 0x00, 0xFF, 0x00, 0x8C, 0x3A]);
  assert.deepEqual([...buildWriteCoil(1, 0, COIL_OFF)], [0x01, 0x05, 0x00, 0x00, 0x00, 0x00, 0xCD, 0xCA]);
  assert.deepEqual([...buildWriteCoil(1, 0, COIL_TOGGLE)], [0x01, 0x05, 0x00, 0x00, 0x55, 0x00, 0xF2, 0x9A]);
});

test('fw_modbus: buildReadBits', () => {
  assert.deepEqual([...buildReadBits(1, FC_READ_COILS, 0, 8)], [0x01, 0x01, 0x00, 0x00, 0x00, 0x08, 0x3D, 0xCC]);
  assert.deepEqual([...buildReadBits(1, FC_READ_DISCRETE_INPUTS, 0, 8)], [0x01, 0x02, 0x00, 0x00, 0x00, 0x08, 0x79, 0xCC]);
});

test('fw_modbus: cerceve CRC denetimi', () => {
  const good = B(0x01, 0x05, 0x00, 0x00, 0xFF, 0x00, 0x8C, 0x3A);
  assert.equal(frameCrcOk(good), true);
  assert.equal(frameCrcOk(B(0x01, 0x05, 0x00, 0x00, 0xFF, 0x00, 0x8C, 0x3B)), false);
  assert.equal(frameCrcOk(good, 3), false);
  assert.equal(frameCrcOk(good, 0), false);
});

test('fw_modbus: 0x05 yanki dogrulamasi (tamam / veri yok / kisa)', () => {
  const req = buildWriteCoil(1, 3, COIL_ON);
  assert.equal(checkWriteCoilEcho(req, req).status, Status.OK);
  assert.equal(checkWriteCoilEcho(req, req.subarray(0, 0)).status, Status.ERR_NO_DATA);
  assert.equal(checkWriteCoilEcho(req, null).status, Status.ERR_NO_DATA);
  assert.equal(checkWriteCoilEcho(req, req.subarray(0, 3)).status, Status.ERR_SHORT);
  assert.equal(checkWriteCoilEcho(req, req.subarray(0, 4)).status, Status.ERR_SHORT);
});

test('fw_modbus: 0x05 bozuk CRC / baska slave / yanki uyusmazligi reddedilir', () => {
  const req = buildWriteCoil(1, 3, COIL_ON);
  const bad = Buffer.from(req);
  bad[7] ^= 0x01;
  assert.equal(checkWriteCoilEcho(req, bad).status, Status.ERR_CRC);
  assert.equal(checkWriteCoilEcho(req, buildWriteCoil(2, 3, COIL_ON)).status, Status.ERR_SLAVE);
  assert.equal(checkWriteCoilEcho(req, buildWriteCoil(1, 3, COIL_OFF)).status, Status.ERR_ECHO);
  assert.equal(checkWriteCoilEcho(req, buildWriteCoil(1, 4, COIL_ON)).status, Status.ERR_ECHO);
});

test('fw_modbus: 0x05 exception / yanlis islev / uzunluk', () => {
  const req = buildWriteCoil(1, 3, COIL_ON);
  const exc = checkWriteCoilEcho(req, withCrc([0x01, 0x85, 0x02]));
  assert.equal(exc.status, Status.ERR_EXCEPTION);
  assert.equal(exc.exception, 2);
  assert.equal(checkWriteCoilEcho(req, withCrc([0x01, 0x06, 0x00, 0x03, 0xFF, 0x00])).status, Status.ERR_FUNC);
  assert.equal(checkWriteCoilEcho(req, withCrc([0x01, 0x05, 0x00, 0x03, 0xFF, 0x00, 0x00])).status, Status.ERR_LENGTH);
});

test('fw_modbus: 0x01 okuma yaniti ve bit cikarma', () => {
  const rx = withCrc([0x01, 0x01, 0x01, 0x05]);
  const r = checkReadBits(1, FC_READ_COILS, 8, rx);
  assert.equal(r.status, Status.OK);
  assert.equal(r.byteCount, 1);
  assert.equal(getBit(r.data, r.byteCount, 0), true);
  assert.equal(getBit(r.data, r.byteCount, 1), false);
  assert.equal(getBit(r.data, r.byteCount, 2), true);
  assert.equal(getBit(r.data, r.byteCount, 7), false);
  assert.equal(getBit(r.data, r.byteCount, 8), false);
});

test('fw_modbus: 16 kanalli okuma', () => {
  const rx = withCrc([0x01, 0x02, 0x02, 0x01, 0x80]);
  const r = checkReadBits(1, FC_READ_DISCRETE_INPUTS, 16, rx);
  assert.equal(r.status, Status.OK);
  assert.equal(getBit(r.data, r.byteCount, 0), true);
  assert.equal(getBit(r.data, r.byteCount, 15), true);
  assert.equal(getBit(r.data, r.byteCount, 8), false);
});

test('fw_modbus: bozuk okuma yanitlari reddedilir', () => {
  const rx = withCrc([0x01, 0x01, 0x01, 0x05]);
  const badCrc = Buffer.from(rx);
  badCrc[badCrc.length - 1] ^= 0xFF;
  assert.equal(checkReadBits(1, FC_READ_COILS, 8, badCrc).status, Status.ERR_CRC);
  assert.equal(checkReadBits(2, FC_READ_COILS, 8, rx).status, Status.ERR_SLAVE);
  assert.equal(checkReadBits(1, FC_READ_DISCRETE_INPUTS, 8, rx).status, Status.ERR_FUNC);
  assert.equal(checkReadBits(1, FC_READ_COILS, 16, rx).status, Status.ERR_LENGTH);
  assert.equal(checkReadBits(1, FC_READ_COILS, 8, withCrc([0x01, 0x01, 0x01, 0x05, 0x00])).status, Status.ERR_LENGTH);
  assert.equal(checkReadBits(1, FC_READ_COILS, 8, rx.subarray(0, 0)).status, Status.ERR_NO_DATA);
  assert.equal(checkReadBits(1, FC_READ_COILS, 8, rx.subarray(0, 3)).status, Status.ERR_SHORT);
});

test('fw_modbus: okuma exception yaniti', () => {
  const r = checkReadBits(1, FC_READ_COILS, 8, withCrc([0x01, 0x81, 0x02]));
  assert.equal(r.status, Status.ERR_EXCEPTION);
  assert.equal(r.exception, 2);
});

test('fw_modbus: beklenen yanit uzunlugu', () => {
  assert.equal(expectedResponseLen(FC_WRITE_SINGLE_COIL, 0), 8);
  assert.equal(expectedResponseLen(FC_READ_COILS, 8), 6);
  assert.equal(expectedResponseLen(FC_READ_DISCRETE_INPUTS, 16), 7);
  assert.equal(expectedResponseLen(FC_READ_COILS, 32), 9);
  assert.equal(expectedResponseLen(FC_READ_COILS, 1), 6);
  assert.equal(expectedResponseLen(0x7F, 8), 0);
});

test('fw_modbus: hexString firmware bicimi (her bayt %02X + bosluk)', () => {
  assert.equal(hexString(B(0x01, 0x05, 0xFF, 0x0A)), '01 05 FF 0A ');
  assert.equal(hexString(B()), '');
});

// ---------------------------------------------------------------- QA modul modeli
const mkExt = (over = {}) => ({ present: true, address: 1, channels: 8, coils: new Array(32).fill(false), rawDi: new Array(32).fill(false), failWrites: false, ...over });

test('fw_modbus: modul modeli tek coil yazar (ON/OFF/TOGGLE) ve yanki doner', () => {
  const x = mkExt();
  const on = buildWriteCoil(1, 2, COIL_ON);
  assert.deepEqual([...moduleRespond(x, on)], [...on]);
  assert.equal(x.coils[2], true);
  moduleRespond(x, buildWriteCoil(1, 2, COIL_TOGGLE));
  assert.equal(x.coils[2], false);
  moduleRespond(x, buildWriteCoil(1, 2, COIL_TOGGLE));
  assert.equal(x.coils[2], true);
  moduleRespond(x, buildWriteCoil(1, 2, COIL_OFF));
  assert.equal(x.coils[2], false);
});

test('fw_modbus: modul modeli 0x00FF ile hepsini yazar, aralik disi kanal exception verir', () => {
  const x = mkExt();
  x.coils.fill(true);
  moduleRespond(x, buildWriteCoil(1, 0x00FF, COIL_OFF));
  assert.equal(x.coils.slice(0, 8).some(Boolean), false);
  x.coils[8] = false;
  const r = moduleRespond(x, buildWriteCoil(1, 8, COIL_ON));
  assert.equal(checkWriteCoilEcho(buildWriteCoil(1, 8, COIL_ON), r).status, Status.ERR_EXCEPTION);
  assert.equal(x.coils[8], false, 'kanal sinirinin disindaki coil degismez');
});

test('fw_modbus: modul modeli okuma yanitlari bayt sirasi (LSB-first)', () => {
  const x = mkExt({ channels: 16 });
  x.coils[0] = true; x.coils[9] = true; x.rawDi[15] = true;
  const rc = moduleRespond(x, buildReadBits(1, FC_READ_COILS, 0, 16));
  assert.deepEqual([...rc.subarray(0, 5)], [1, 1, 2, 0x01, 0x02]);
  const rd = checkReadBits(1, FC_READ_DISCRETE_INPUTS, 16, moduleRespond(x, buildReadBits(1, FC_READ_DISCRETE_INPUTS, 0, 16)));
  assert.equal(rd.status, Status.OK);
  assert.equal(getBit(rd.data, rd.byteCount, 15), true);
  assert.equal(getBit(rd.data, rd.byteCount, 0), false);
});

test('fw_modbus: modul modeli yanitsiz kalir (CRC hatali, baska adres, yok, kisa cerceve)', () => {
  const x = mkExt();
  const good = buildWriteCoil(1, 0, COIL_ON);
  const bad = Buffer.from(good);
  bad[7] ^= 0xFF;
  assert.equal(moduleRespond(x, bad), null);
  assert.equal(moduleRespond(x, buildWriteCoil(2, 0, COIL_ON)), null);
  assert.equal(moduleRespond(mkExt({ present: false }), good), null);
  assert.equal(moduleRespond(x, good.subarray(0, 5)), null);
  assert.equal(x.coils[0], false, 'yanitsiz isteklerde coil degismedi');
});

test('fw_modbus: modul modeli desteklenmeyen islev icin exception 0x01 verir', () => {
  const x = mkExt();
  const rx = moduleRespond(x, withCrc([1, 0x10, 0, 0, 0, 1]));
  assert.equal(rx[1], 0x90);
  assert.equal(rx[2], 0x01);
  assert.equal(frameCrcOk(rx), true);
});
