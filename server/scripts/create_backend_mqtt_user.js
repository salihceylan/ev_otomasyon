#!/usr/bin/env node
'use strict';

// ==============================================================================
// AHBU Akilli Ev - Backend MQTT kimligi olusturma/dondurme (WP-C)
// ==============================================================================
//
// Backend koprusunun (src/mqtt_bridge.js) EMQX'e baglandigi `backend_service` kimligini
// `mqtt_credentials` tablosuna (bcrypt ozeti, superuser) yazar. Eski gomulu/paylasilan parola
// (init_mqtt_users.sql, add_users.sh, ...) SILINDI; parola YALNIZCA ortamdan okunur ve log'a /
// ekrana yazilmaz.
//
// KULLANIM (server/ dizininden; once `node scripts/migrate.js` ile 020 uygulanmis olmali):
//   MQTT_BACKEND_USER=backend_service MQTT_BACKEND_PASS='<en az 24 karakter, rastgele>' \
//   MIGRATE_CONFIRM=<veritabani_adi> node scripts/create_backend_mqtt_user.js
//
// Ayni degiskenler (MQTT_BACKEND_USER / MQTT_BACKEND_PASS) kopru tarafindan da okunur; boylece
// kimlik tek kaynaktan (.env) gelir. Parolayi dondurmek icin yeni degerle yeniden calistirin;
// ardindan backend'i yeniden baslatin (EMQX mevcut baglantiyi atmaz; yeniden baglanmada yeni parola gecer).
// Parola uretimi ornegi:  openssl rand -base64 36
//
// EMQX tarafi: emqx_config/emqx.conf birinci authenticator'i `is_superuser` sutununu bu satirdan alir.

const path = require('path');
const { parseDatabaseUrl, describeTarget, assertConfirmed, requireSecretEnv, TargetError } = require('./lib/target');

const USER_RE = /^[A-Za-z0-9_.-]{3,64}$/;

async function main(deps = {}) {
  const env = deps.env || process.env;
  const log = deps.log || ((...a) => console.log(...a));
  const errLog = deps.errLog || ((...a) => console.error(...a));

  let target;
  let username;
  let password;
  try {
    target = parseDatabaseUrl(env.DATABASE_URL);
    assertConfirmed(env, target);
    username = String(env.MQTT_BACKEND_USER || 'backend_service');
    if (!USER_RE.test(username)) {
      throw new TargetError('MQTT_BACKEND_USER yalnizca harf, rakam, "_", "-", "." icerebilir (3-64 karakter).', 'BAD_ENV');
    }
    password = requireSecretEnv(env, 'MQTT_BACKEND_PASS', {
      minLength: 24,
      hint: 'En az 24 karakterlik rastgele bir deger kullanin (ornek: openssl rand -base64 36).',
    });
  } catch (err) {
    errLog(`HATA: ${err.message}`);
    return 2;
  }
  log(`Hedef: ${describeTarget(target)}`);

  const bcrypt = deps.bcrypt || require('bcryptjs');
  const Client = deps.Client || require('pg').Client;
  const client = new Client({ connectionString: env.DATABASE_URL, application_name: 'ev_create_backend_mqtt_user', connectionTimeoutMillis: 10000 });
  try {
    await client.connect();
    const t = await client.query("SELECT to_regclass('public.mqtt_credentials') AS t");
    if (!t.rows[0] || !t.rows[0].t) {
      errLog('HATA: mqtt_credentials tablosu yok. Once `node scripts/migrate.js` ile 020 migration\'ini uygulayin.');
      return 1;
    }

    const hash = bcrypt.hashSync(password, 12);
    // Yalnizca ayni kullanici adli BACKEND kaydi guncellenir; baska turde (cihaz/uygulama) kimlige dokunulmaz.
    const res = await client.query(
      `INSERT INTO mqtt_credentials (username, password_hash, is_superuser, kind, expires_at)
       VALUES ($1, $2, TRUE, 'backend', NULL)
       ON CONFLICT (username) DO UPDATE
         SET password_hash = EXCLUDED.password_hash, is_superuser = TRUE
       WHERE mqtt_credentials.kind = 'backend'
       RETURNING username`,
      [username, hash]
    );
    if (res.rows.length === 0) {
      errLog(`HATA: "${username}" kullanici adi backend disi bir kimlige ait; degistirilmedi.`);
      return 1;
    }
    log(`Backend MQTT kimligi hazir: ${username} (superuser; parola ortamdan, bcrypt ozeti yazildi).`);
    return 0;
  } catch (err) {
    // kind CHECK'i 'backend' degerini reddederse (020 degismis olabilir) acik ipucu ver.
    if (err && err.code === '23514') {
      errLog('HATA: mqtt_credentials kisiti "backend" turunu reddetti; 020 migration\'ini kontrol edin.');
    } else {
      errLog(`HATA: ${err.message}`);
    }
    return 1;
  } finally {
    try {
      await client.end();
    } catch (_) {
      /* yut */
    }
  }
}

module.exports = { main, USER_RE };

if (require.main === module) {
  try {
    require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
  } catch (_) {
    /* yut */
  }
  main().then(
    (code) => process.exit(code),
    (err) => {
      console.error(`HATA: ${err && err.message ? err.message : err}`);
      process.exit(1);
    }
  );
}
