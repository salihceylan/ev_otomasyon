'use strict';

// ==============================================================================
// Telefonun kanonik bicimi (karar 11, 2026-10-09)
// ==============================================================================
// TR cep numaralari E.164 "+905XXXXXXXXX" olarak saklanir ve karsilastirilir. Kabul edilen yazimlar (ayraclar
// temizlendikten sonra): 05XXXXXXXXX, 905XXXXXXXXX, +905XXXXXXXXX, 5XXXXXXXXX, 00905XXXXXXXXX. TR disi "+..." numara ve
// diger bicimler (sabit hat vb.) OLDUGU GIBI kalir. Kimlik eslestirmesi (giris, telefon-OTP, devir, sahiplenme, Home
// Admin atama) bu yardimciyi kullanir; migration 042 mevcut kayitlari ayni kurala gore cevirir.

const TR_MOBILE = /^(?:\+90|0090|90|0)?(5\d{9})$/;

/**
 * Ayraclari temizlenmis telefon metnini kanonik bicime cevirir (gecerlilik denetimi CAGIRANDADIR).
 * @param {string} cleaned yalniz rakam ve bastaki + (bosluk, tire, parantez, nokta temizlenmis)
 * @returns {string}
 */
function canonicalPhone(cleaned) {
  const s = String(cleaned);
  const m = TR_MOBILE.exec(s);
  return m ? `+90${m[1]}` : s;
}

module.exports = { canonicalPhone, TR_MOBILE };
