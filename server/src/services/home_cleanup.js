'use strict';

// ==============================================================================
// Ev temizligi: daire DEVRINDE ve ACIL SIFIRLAMADA eski sakinlerin biraktigi eve ait
// verileri temizler (denetim bulgusu: "devirde-veri-temizlenmiyor").
//
// Ortak kullanim:
//   - WP-A transfer_service (devir kabulu):   await cleanupHome(tx, homeId, { keepEndpoints: true })
//   - WP-B device_service.emergencyReset:     await cleanupHome(tx, homeId, { keepEndpoints: false })
//
// Ne temizlenir (tablo yoksa HATA FIRLATILMAZ; to_regclass + sutun denetimi ile korunur,
// cunku PostgreSQL'de basarisiz tek sorgu butun transaction'i iptal eder):
//   - scheduled_rules (+ scheduled_rule_runs)  eski ailenin zamanli kurallari
//   - home_invitations                          bekleyen/kullanilmis davetler
//   - service_tokens                            ev sahibinin urettigi servis PIN'leri (iptal)
//   - service_sessions                          acik servis (PIN) oturumlari (iptal)
//   - peace_notification_logs                   eski ailenin aliskanlik gunlugu
//   - home_transfers                            BEKLEYEN devirler iptal edilir (cancelPendingTransfers)
//   - endpoints                                 keepEndpoints=false ise (cihaz kanallari)
//
// Ne YAPMAZ: home_users (uyelik) ve MQTT kimlikleri. Uyelikleri cagiran degistirir;
// MQTT kimlikleri mqttCredentialService.revokeHomeAccess() ile iptal edilir (tx icinde
// DB satirlari silinir, ag cagrisi olan "kick" commit SONRASI yapilir).
//
// `tx`: db.withTransaction callback'indeki { query } nesnesi. (db.query('BEGIN') KULLANMAYIN.)
// ==============================================================================

async function tableExists(tx, table) {
  const r = await tx.query('SELECT to_regclass($1) AS t', [`public.${table}`]);
  return Boolean(r.rows && r.rows[0] && r.rows[0].t);
}

async function columnExists(tx, table, column) {
  const r = await tx.query(
    `SELECT 1
       FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
      LIMIT 1`,
    [table, column]
  );
  return Boolean(r.rows && r.rows.length > 0);
}

/** Tablo var ve home_id sutunu var mi? (Degilse bu adim sessizce atlanir.) */
async function isHomeScoped(tx, table) {
  return (await tableExists(tx, table)) && (await columnExists(tx, table, 'home_id'));
}

// NOT: `table` yalnizca bu dosyadaki SABIT listeden gelir (kullanici girdisi degildir).

/** home_id'ye bagli satirlari siler. */
async function deleteByHome(tx, table, homeId) {
  if (!(await isHomeScoped(tx, table))) return { skipped: true, count: 0 };
  const r = await tx.query(`DELETE FROM ${table} WHERE home_id = $1`, [homeId]);
  return { skipped: false, count: r.rowCount || 0 };
}

/**
 * Iptal edilebilir kayitlar (revoked_at sutunu varsa) iptal edilir, yoksa silinir.
 * Iptal, denetim izini korur ve kimlik dogrulama katmaninin (revoked_at kontrolu) hemen reddetmesini saglar.
 */
async function revokeOrDeleteByHome(tx, table, homeId, reason) {
  if (!(await isHomeScoped(tx, table))) return { skipped: true, count: 0 };

  if (await columnExists(tx, table, 'revoked_at')) {
    const sets = ['revoked_at = NOW()'];
    if (await columnExists(tx, table, 'revoked_reason')) {
      sets.push(`revoked_reason = '${reason}'`); // reason: bu dosyadaki sabit
    }
    const r = await tx.query(
      `UPDATE ${table} SET ${sets.join(', ')} WHERE home_id = $1 AND revoked_at IS NULL`,
      [homeId]
    );
    return { skipped: false, count: r.rowCount || 0 };
  }

  const r = await tx.query(`DELETE FROM ${table} WHERE home_id = $1`, [homeId]);
  return { skipped: false, count: r.rowCount || 0 };
}

/**
 * Evin zamanli kurallarini siler (calisma gunlugu tablosu varsa once onu).
 * scheduled_rule_runs FK'si CASCADE degilse bile silme basarisiz olmaz.
 */
async function deleteScheduledRules(tx, homeId) {
  if (!(await isHomeScoped(tx, 'scheduled_rules'))) return { skipped: true, count: 0 };

  if ((await tableExists(tx, 'scheduled_rule_runs')) && (await columnExists(tx, 'scheduled_rule_runs', 'rule_id'))) {
    await tx.query(
      `DELETE FROM scheduled_rule_runs
        WHERE rule_id IN (SELECT id FROM scheduled_rules WHERE home_id = $1)`,
      [homeId]
    );
  }
  const r = await tx.query('DELETE FROM scheduled_rules WHERE home_id = $1', [homeId]);
  return { skipped: false, count: r.rowCount || 0 };
}

async function cancelPendingTransfers(tx, homeId) {
  if (!(await isHomeScoped(tx, 'home_transfers'))) return { skipped: true, count: 0 };
  const r = await tx.query(
    `UPDATE home_transfers SET status = 'CANCELLED' WHERE home_id = $1 AND status = 'PENDING'`,
    [homeId]
  );
  return { skipped: false, count: r.rowCount || 0 };
}

/**
 * @param {{query:Function}} tx        db.withTransaction icindeki islem nesnesi
 * @param {string}           homeId    ev UUID'si
 * @param {object}           [options]
 * @param {boolean}          [options.keepEndpoints=false]       true: cihaz kanallari (endpoints) korunur
 * @param {boolean}          [options.cancelPendingTransfers=true] false: bekleyen devir kayitlarina dokunulmaz
 *                                                                (devir kabulunde kabul edilen kaydi cagiran kapatir)
 * @returns {Promise<{cleaned: Object<string, number>, skipped: string[]}>}
 */
async function cleanupHome(tx, homeId, options = {}) {
  if (!tx || typeof tx.query !== 'function') {
    throw new TypeError('cleanupHome: tx (db.withTransaction islem nesnesi) zorunludur.');
  }
  if (!homeId) {
    throw new TypeError('cleanupHome: homeId zorunludur.');
  }
  const keepEndpoints = options.keepEndpoints === true;
  const cancelTransfers = options.cancelPendingTransfers !== false;

  const cleaned = {};
  const skipped = [];
  const record = (name, result) => {
    if (result.skipped) skipped.push(name);
    else cleaned[name] = result.count;
  };

  record('scheduled_rules', await deleteScheduledRules(tx, homeId));
  record('home_invitations', await deleteByHome(tx, 'home_invitations', homeId));
  record('service_tokens', await revokeOrDeleteByHome(tx, 'service_tokens', homeId, 'home_reset'));
  record('service_sessions', await revokeOrDeleteByHome(tx, 'service_sessions', homeId, 'home_reset'));
  record('peace_notification_logs', await deleteByHome(tx, 'peace_notification_logs', homeId));
  if (cancelTransfers) {
    record('home_transfers', await cancelPendingTransfers(tx, homeId));
  }
  if (!keepEndpoints) {
    record('endpoints', await deleteByHome(tx, 'endpoints', homeId));
  }

  return { cleaned, skipped };
}

module.exports = { cleanupHome };
