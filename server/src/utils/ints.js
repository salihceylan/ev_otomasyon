'use strict';

// Sayfalama sinirlari: asiri buyuk 'offset' PostgreSQL'e ulasmadan kirpilir.
const MAX_OFFSET = 1000000;

/**
 * Tamsayiya cevirir ve [min, max] araligina kirpar; sayi degilse (veya zeroIsFallback ve 0 ise) `fallback`.
 *
 * NEDEN: `Number.parseInt('9'.repeat(40))` = 1e+39 uretir; ust sinir olmadan SQL `OFFSET`'e
 * "1e+39" olarak gider ve PostgreSQL 22P02 (invalid input syntax for bigint) ile 500 dondurur.
 * Dizgi yalnizca duz (isaretli) ondalik tamsayi ise cevrilir; "1e5", "0x10", "12abc" gibi degerler `fallback` olur.
 */
function toBoundedInt(value, { min, max, fallback, zeroIsFallback = false } = {}) {
  let n;
  if (typeof value === 'number') {
    n = Number.isFinite(value) ? Math.trunc(value) : NaN;
  } else if (typeof value === 'string' && /^\s*[+-]?\d{1,18}\s*$/.test(value)) {
    n = Number.parseInt(value, 10);
  } else {
    n = NaN;
  }
  if (!Number.isFinite(n) || (zeroIsFallback && n === 0)) return fallback;
  return Math.min(max, Math.max(min, n));
}

module.exports = { toBoundedInt, MAX_OFFSET };
