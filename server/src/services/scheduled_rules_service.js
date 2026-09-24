const db = require('../db');

/**
 * Bir ev için tüm zamanlı kuralları listele
 */
async function listRules(homeId) {
  const res = await db.query(
    `SELECT sr.*, COALESCE(u.full_name, u.email) AS created_by_name
     FROM scheduled_rules sr
     LEFT JOIN users u ON u.id = sr.created_by
     WHERE sr.home_id = $1
     ORDER BY sr.hour ASC, sr.minute ASC`,
    [homeId]
  );
  return res.rows;
}

/**
 * Yeni kural oluştur
 */
async function createRule(homeId, userId, { deviceId, channel, channelType, action, hour, minute, daysOfWeek, label }) {
  // Doğrulama
  const validActions = ['on', 'off', 'open', 'close'];
  if (!validActions.includes(action)) throw new Error('Geçersiz eylem: ' + action);
  if (channel < 0 || channel > 15) throw new Error('Geçersiz kanal numarası');
  if (hour < 0 || hour > 23) throw new Error('Geçersiz saat');
  if (minute < 0 || minute > 59) throw new Error('Geçersiz dakika');

  const days = daysOfWeek || [0, 1, 2, 3, 4, 5, 6];
  if (!Array.isArray(days) || days.some(d => d < 0 || d > 6)) {
    throw new Error('Geçersiz gün listesi');
  }

  const res = await db.query(
    `INSERT INTO scheduled_rules
       (home_id, device_id, channel, channel_type, action, hour, minute, days_of_week, label, created_by)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
     RETURNING *`,
    [homeId, deviceId || null, channel, channelType || 'relay', action, hour, minute, JSON.stringify(days), label || null, userId]
  );
  return res.rows[0];
}

/**
 * Kural güncelle
 */
async function updateRule(ruleId, homeId, updates) {
  const fields = [];
  const values = [];
  let idx = 1;

  if (updates.action !== undefined) { fields.push(`action = $${idx++}`); values.push(updates.action); }
  if (updates.hour !== undefined)   { fields.push(`hour = $${idx++}`);   values.push(updates.hour); }
  if (updates.minute !== undefined) { fields.push(`minute = $${idx++}`); values.push(updates.minute); }
  if (updates.daysOfWeek !== undefined) { fields.push(`days_of_week = $${idx++}`); values.push(JSON.stringify(updates.daysOfWeek)); }
  if (updates.label !== undefined)  { fields.push(`label = $${idx++}`);  values.push(updates.label); }
  if (updates.enabled !== undefined){ fields.push(`enabled = $${idx++}`);values.push(updates.enabled); }

  if (fields.length === 0) throw new Error('Güncellenecek alan yok');

  values.push(ruleId, homeId);
  const res = await db.query(
    `UPDATE scheduled_rules SET ${fields.join(', ')}
     WHERE id = $${idx++} AND home_id = $${idx++}
     RETURNING *`,
    values
  );
  if (res.rows.length === 0) throw new Error('Kural bulunamadı');
  return res.rows[0];
}

/**
 * Kural sil
 */
async function deleteRule(ruleId, homeId) {
  const res = await db.query(
    `DELETE FROM scheduled_rules WHERE id = $1 AND home_id = $2 RETURNING id`,
    [ruleId, homeId]
  );
  if (res.rows.length === 0) throw new Error('Kural bulunamadı');
  return res.rows[0];
}

/**
 * Şu an tetiklenmesi gereken kuralları getir (cron job için)
 * Her dakika çalıştırılır, o dakikaya denk gelen aktif kuralları döner
 */
async function getRulesDueNow() {
  const now = new Date();
  const hour = now.getHours();
  const minute = now.getMinutes();
  const dayOfWeek = now.getDay(); // 0=Pazar, 6=Cumartesi

  const res = await db.query(
    `SELECT sr.*, h.mqtt_username AS home_mqtt_username
     FROM scheduled_rules sr
     LEFT JOIN homes h ON h.id = sr.home_id
     WHERE sr.enabled = TRUE
       AND sr.hour = $1
       AND sr.minute = $2
       AND sr.days_of_week @> $3::jsonb`,
    [hour, minute, JSON.stringify([dayOfWeek])]
  );
  return res.rows;
}

module.exports = { listRules, createRule, updateRule, deleteRule, getRulesDueNow };
