'use strict';

// ==============================================================================
// Yonetim betikleri icin ortak "hedef veritabani" guvenligi (WP-C)
// ==============================================================================
//
// Neden: Ayni sunucuda uretimdeki kapi sistemi gibi BASKA veritabanlari var. Betigin yanlis
// veritabanina yazmasini onlemek icin hedef (sunucu:port/veritabani) ACIKCA yazdirilir ve
// islem, hedef veritabani adi `MIGRATE_CONFIRM` ortam degiskenine elle yazilmadikca YAPILMAZ.
// Sabit baglanti dizesi YOKTUR: yalnizca DATABASE_URL okunur.
//
// GUVENLIK: parola hicbir zaman yazdirilmaz/loglanmaz.

class TargetError extends Error {
  constructor(message, code = 'TARGET_ERROR') {
    super(message);
    this.name = 'TargetError';
    this.code = code;
  }
}

/**
 * DATABASE_URL -> { protocol, host, port, database, user }  (PAROLA DONMEZ)
 * @param {string} url
 */
function parseDatabaseUrl(url) {
  if (typeof url !== 'string' || url.trim() === '') {
    throw new TargetError('DATABASE_URL tanimli degil. Hedef veritabani belirsiz oldugu icin islem yapilmadi.', 'NO_URL');
  }
  let u;
  try {
    u = new URL(url.trim());
  } catch (_) {
    // Hata iletisine URL'yi KOYMA (parola icerebilir).
    throw new TargetError('DATABASE_URL ayristirilamadi (postgres://kullanici@sunucu:port/veritabani bekleniyor).', 'BAD_URL');
  }
  if (!/^postgres(ql)?:$/i.test(u.protocol)) {
    throw new TargetError('DATABASE_URL postgres:// veya postgresql:// ile baslamali.', 'BAD_URL');
  }
  const database = decodeURIComponent((u.pathname || '').replace(/^\//, ''));
  if (!database) {
    throw new TargetError('DATABASE_URL bir veritabani adi icermiyor.', 'BAD_URL');
  }
  return {
    protocol: u.protocol.replace(':', ''),
    host: u.hostname || 'localhost',
    port: u.port ? Number(u.port) : 5432,
    database,
    user: decodeURIComponent(u.username || ''),
  };
}

/** Insan okunur hedef metni (parolasiz). */
function describeTarget(target) {
  const who = target.user ? `${target.user}@` : '';
  return `${who}${target.host}:${target.port}/${target.database}`;
}

/**
 * Onay: MIGRATE_CONFIRM, hedef veritabani adina TAM esit olmali.
 * @throws {TargetError} onay yoksa/yanlissa
 */
function assertConfirmed(env, target) {
  const given = env.MIGRATE_CONFIRM;
  if (!given) {
    throw new TargetError(
      `Onay gerekli: hedef ${describeTarget(target)}. Dogruysa MIGRATE_CONFIRM=${target.database} ile yeniden calistirin.`,
      'NOT_CONFIRMED'
    );
  }
  if (given !== target.database) {
    throw new TargetError(
      `MIGRATE_CONFIRM ("${String(given).slice(0, 64)}") hedef veritabani adiyla ("${target.database}") eslesmiyor. Islem iptal.`,
      'CONFIRM_MISMATCH'
    );
  }
  return true;
}

/** URL'deki kimlik bilgisini maskeler (log/hata mesaji icin). */
function redactUrl(url) {
  return String(url).replace(/(\/\/[^:/@\s]*:)[^@\s]*@/, '$1***@');
}

/**
 * Rastgelelik/uzunluk gerektiren ortam sirlari icin ortak dogrulama.
 * Deger log'a YAZILMAZ; yalnizca hata nedeni.
 */
function requireSecretEnv(env, name, { minLength = 1, pattern = null, hint = '' } = {}) {
  const v = env[name];
  if (!v) throw new TargetError(`${name} ortam degiskeni tanimli degil.${hint ? ' ' + hint : ''}`, 'MISSING_ENV');
  if (String(v).length < minLength) {
    throw new TargetError(`${name} en az ${minLength} karakter olmali.`, 'WEAK_ENV');
  }
  if (pattern && !pattern.test(String(v))) {
    throw new TargetError(`${name} beklenen bicimde degil.${hint ? ' ' + hint : ''}`, 'BAD_ENV');
  }
  return String(v);
}

module.exports = {
  TargetError,
  parseDatabaseUrl,
  describeTarget,
  assertConfirmed,
  redactUrl,
  requireSecretEnv,
};
