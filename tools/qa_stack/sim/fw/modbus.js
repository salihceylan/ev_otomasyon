// ModbusRtu.h (firmware) JavaScript portu: CRC16 + cerceve olusturma/dogrulama (saf mantik) ve QA'ya ozgu EK MODUL DONANIM MODELI
// (Waveshare tipi Modbus RTU role modulu). Firmware tarafi (SmartAutomation_Rs485.cpp portu) gercek baytlarla konusur:
// istek cercevesi olusturur, modul modeli CRC/adres/islev dogrulayip yanit cercevesi uretir, firmware portu yaniti ayristirir.
export const FC_READ_COILS = 0x01;
export const FC_READ_DISCRETE_INPUTS = 0x02;
export const FC_READ_HOLDING = 0x03;
export const FC_READ_INPUT_REGS = 0x04;
export const FC_WRITE_SINGLE_COIL = 0x05;

export const COIL_ON = 0xFF00;
export const COIL_OFF = 0x0000;
export const COIL_TOGGLE = 0x5500;

export const Status = Object.freeze({
  OK: 0, ERR_NO_DATA: 1, ERR_SHORT: 2, ERR_CRC: 3, ERR_SLAVE: 4, ERR_FUNC: 5, ERR_EXCEPTION: 6, ERR_LENGTH: 7, ERR_ECHO: 8,
});

/** SmartAutomation_Rs485.cpp statusText() */
export function statusText(s) {
  switch (s) {
    case Status.OK: return 'OK';
    case Status.ERR_NO_DATA: return 'yanit yok';
    case Status.ERR_SHORT: return 'yanit cok kisa';
    case Status.ERR_CRC: return 'CRC hatasi';
    case Status.ERR_SLAVE: return 'baska slave';
    case Status.ERR_FUNC: return 'beklenmeyen islev';
    case Status.ERR_EXCEPTION: return 'slave exception';
    case Status.ERR_LENGTH: return 'uzunluk uyusmuyor';
    case Status.ERR_ECHO: return 'yanki uyusmuyor';
    default: return '?';
  }
}

/** CRC-16/MODBUS (poly 0xA001 yansitilmis, baslangic 0xFFFF). */
export function crc16(buf, len = buf.length) {
  let crc = 0xFFFF;
  for (let pos = 0; pos < len; pos++) {
    crc ^= buf[pos];
    for (let i = 8; i !== 0; i--) {
      if (crc & 0x0001) { crc >>= 1; crc ^= 0xA001; } else { crc >>= 1; }
    }
  }
  return crc & 0xFFFF;
}

/** @param {number[]|Uint8Array} body @returns {Buffer} body + CRC (dusuk bayt once) */
export function withCrc(body) {
  const b = Buffer.from(body);
  const c = crc16(b, b.length);
  return Buffer.concat([b, Buffer.from([c & 0xFF, (c >> 8) & 0xFF])]);
}

export function buildReadBits(slave, func, start, count) {
  return withCrc([slave, func, (start >> 8) & 0xFF, start & 0xFF, (count >> 8) & 0xFF, count & 0xFF]);
}

export function buildWriteCoil(slave, coilAddr, value) {
  return withCrc([slave, FC_WRITE_SINGLE_COIL, (coilAddr >> 8) & 0xFF, coilAddr & 0xFF, (value >> 8) & 0xFF, value & 0xFF]);
}

export function expectedResponseLen(func, count) {
  if (func === FC_WRITE_SINGLE_COIL) return 8;
  if (func === FC_READ_COILS || func === FC_READ_DISCRETE_INPUTS) return 5 + Math.floor((count + 7) / 8);
  return 0;
}

export function frameCrcOk(rx, len = rx.length) {
  if (len < 4) return false;
  const calc = crc16(rx, len - 2);
  const got = rx[len - 2] | (rx[len - 1] << 8);
  return calc === got;
}

/** 0x05 yaniti: istekle BIREBIR ayni olmali. @returns {{status:number, exception?:number}} */
export function checkWriteCoilEcho(req, rx) {
  const rxLen = rx ? rx.length : 0;
  if (rxLen === 0) return { status: Status.ERR_NO_DATA };
  if (rxLen < 5) return { status: Status.ERR_SHORT };
  if (!frameCrcOk(rx, rxLen)) return { status: Status.ERR_CRC };
  if (req.length < 2) return { status: Status.ERR_FUNC };
  if (rx[0] !== req[0]) return { status: Status.ERR_SLAVE };
  if (rx[1] === ((req[1] | 0x80) & 0xFF)) return { status: Status.ERR_EXCEPTION, exception: rxLen >= 3 ? rx[2] : undefined };
  if (rx[1] !== req[1]) return { status: Status.ERR_FUNC };
  if (rxLen !== req.length) return { status: Status.ERR_LENGTH };
  for (let i = 0; i < req.length; i++) if (rx[i] !== req[i]) return { status: Status.ERR_ECHO };
  return { status: Status.OK };
}

/** 0x01/0x02 yaniti: [slave, func, bayt_sayisi, veri..., crcLo, crcHi]. @returns {{status:number, data?:Buffer, byteCount?:number, exception?:number}} */
export function checkReadBits(slave, func, count, rx) {
  const rxLen = rx ? rx.length : 0;
  if (rxLen === 0) return { status: Status.ERR_NO_DATA };
  if (rxLen < 5) return { status: Status.ERR_SHORT };
  if (!frameCrcOk(rx, rxLen)) return { status: Status.ERR_CRC };
  if (rx[0] !== slave) return { status: Status.ERR_SLAVE };
  if (rx[1] === ((func | 0x80) & 0xFF)) return { status: Status.ERR_EXCEPTION, exception: rx[2] };
  if (rx[1] !== func) return { status: Status.ERR_FUNC };
  const bc = rx[2];
  if (bc !== Math.floor((count + 7) / 8)) return { status: Status.ERR_LENGTH };
  if (rxLen !== 5 + bc) return { status: Status.ERR_LENGTH };
  return { status: Status.OK, data: rx.subarray(3, 3 + bc), byteCount: bc };
}

/** veri icinde bit numarasi (0 tabanli, LSB-first). Aralik disi => false. */
export function getBit(data, byteCount, bit) {
  const idx = Math.floor(bit / 8);
  if (idx >= byteCount) return false;
  return ((data[idx] >> (bit % 8)) & 1) !== 0;
}

/** SmartAutomation_Rs485.cpp hexString(): her bayt "%02X " (sondaki bosluk dahil). */
export function hexString(bytes) {
  let s = '';
  for (const b of bytes) s += `${b.toString(16).padStart(2, '0').toUpperCase()} `;
  return s;
}

const exception = (slave, func, code) => withCrc([slave, (func | 0x80) & 0xFF, code]);

/**
 * QA: Modbus RTU role modulu modeli. `ext` = {present, address, channels, coils[], rawDi[], failWrites, baud?}.
 * Hat/baud/adres uygunlugu cagiranda denetlenir; burada yalniz cerceve semantigi: CRC hatali cerceve YANITSIZ kalir, adres
 * uyusmazsa yanitsiz, 0x01/0x02 okuma, 0x03/0x04 (sifir yazmaclar), 0x05 tek coil (ON/OFF/TOGGLE, 0x00FF = hepsi).
 * @returns {Buffer|null} yanit cercevesi (null = yanit yok)
 */
export function moduleRespond(ext, frame) {
  if (!ext || !ext.present || !frame || frame.length < 8) return null;
  if (!frameCrcOk(frame, frame.length)) return null;
  const slave = frame[0];
  if (slave !== ext.address) return null;
  const fn = frame[1];
  const addr = (frame[2] << 8) | frame[3];
  const val = (frame[4] << 8) | frame[5];
  const channels = Math.min(32, ext.channels);
  if (fn === FC_READ_COILS || fn === FC_READ_DISCRETE_INPUTS) {
    if (frame.length !== 8) return null;
    if (val < 1 || val > 2000) return exception(slave, fn, 0x03);
    if (addr + val > channels) return exception(slave, fn, 0x02);
    const src = fn === FC_READ_COILS ? ext.coils : ext.rawDi;
    const bc = Math.floor((val + 7) / 8);
    const data = Buffer.alloc(bc);
    for (let k = 0; k < val; k++) if (src[addr + k]) data[k >> 3] |= (1 << (k & 7));
    return withCrc([slave, fn, bc, ...data]);
  }
  if (fn === FC_READ_HOLDING || fn === FC_READ_INPUT_REGS) {
    if (frame.length !== 8) return null;
    if (val < 1 || val > 125) return exception(slave, fn, 0x03);
    return withCrc([slave, fn, val * 2, ...new Array(val * 2).fill(0)]);
  }
  if (fn === FC_WRITE_SINGLE_COIL) {
    if (frame.length !== 8) return null;
    if (val !== COIL_ON && val !== COIL_OFF && val !== COIL_TOGGLE) return exception(slave, fn, 0x03);
    if (addr === 0x00FF) {
      for (let k = 0; k < channels; k++) ext.coils[k] = val === COIL_TOGGLE ? !ext.coils[k] : val === COIL_ON;
      return Buffer.from(frame);
    }
    if (addr >= channels) return exception(slave, fn, 0x02);
    ext.coils[addr] = val === COIL_TOGGLE ? !ext.coils[addr] : val === COIL_ON;
    return Buffer.from(frame);
  }
  return exception(slave, fn, 0x01);
}
