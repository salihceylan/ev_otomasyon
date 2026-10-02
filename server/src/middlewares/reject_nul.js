'use strict';

const { HttpError } = require('../utils/helpers');

// Gövde/sorgu yapisinda taranacak en cok dugum sayisi (asiri buyuk/derin yapi taramasini sinirlar).
// Govde zaten BODY_LIMIT (256 KB) ile sinirli; bu sinir hesap maliyetini ayrica kisitlar.
const MAX_NODES = 20000;

/**
 * NUL (\u0000) bayti iceren herhangi bir metin (anahtar dahil) veya asiri buyuk yapi icin true.
 * Iteratif (yigin) tarama: derin ic ice yapilarda cagri yigini tasmaz.
 */
function containsNul(root) {
  const stack = [root];
  let visited = 0;
  while (stack.length > 0) {
    const v = stack.pop();
    if (typeof v === 'string') {
      if (v.indexOf('\u0000') !== -1) return true;
      continue;
    }
    if (v === null || typeof v !== 'object') continue;
    if (++visited > MAX_NODES) return true; // guvenli taraf: reddet
    if (Array.isArray(v)) {
      for (let i = 0; i < v.length; i += 1) stack.push(v[i]);
    } else {
      for (const key of Object.keys(v)) {
        if (key.indexOf('\u0000') !== -1) return true;
        stack.push(v[key]);
      }
    }
  }
  return false;
}

/**
 * NEDEN: PostgreSQL UTF8 kodlamasi NUL baytini kabul etmez (22021); bu deger sorgu/gövde/yol
 * parametresi olarak herhangi bir servise ulasirsa 500 doner. Tek noktadan 400 VALIDATION'a cevrilir.
 * Yol parcalarindaki %00 de ham URL uzerinden yakalanir.
 */
function rejectNulBytes(req, res, next) {
  const url = String(req.originalUrl || req.url || '');
  if (/%00/i.test(url) || url.indexOf('\u0000') !== -1) {
    return next(new HttpError(400, 'İstekte geçersiz (NUL) karakter bulundu.', 'VALIDATION'));
  }
  if (containsNul(req.query) || containsNul(req.body)) {
    return next(new HttpError(400, 'İstekte geçersiz (NUL) karakter bulundu.', 'VALIDATION'));
  }
  return next();
}

module.exports = { rejectNulBytes, containsNul, MAX_NODES };
