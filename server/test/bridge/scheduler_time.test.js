'use strict';

// C8 - Zamanlayici: saat dilimi, DST, telafi penceresi, tekrar engeli, komut cevirme, yetki.

const test = require('node:test');
const assert = require('node:assert/strict');
const { helpers } = require('../../src/scheduler');

const {
  isValidTimeZone,
  resolveTimeZone,
  localParts,
  windowSlots,
  normalizeDays,
  dueSlotForRule,
  ruleToCommand,
  isCreatorAuthorized,
} = helpers;

const Z = (iso) => Date.parse(iso);
const ALL_DAYS = [0, 1, 2, 3, 4, 5, 6];
const MIN = 60 * 1000;

/** Bir tur icin bilgi nesnesi (pencere dahil). */
function infoAt(nowMs, tz, windowMinutes = 2) {
  return { tz, slots: windowSlots(nowMs, tz, windowMinutes) };
}

/**
 * Bir zaman araligini dakika dakika tarar; her turda kural "due" ise ATOMIK TALEBI taklit eder
 * (last_run_at = yuva) ve calisma zamanlarini toplar. Cok instance'li gercek davranisin
 * tek-instance karsiligi: ayni yuva ikinci kez kabul edilmez.
 */
function simulate(rule, tz, fromIso, toIso, windowMinutes = 2) {
  const r = { ...rule };
  const runs = [];
  for (let ms = Z(fromIso); ms < Z(toIso); ms += MIN) {
    const slot = dueSlotForRule(r, infoAt(ms + 5000, tz, windowMinutes)); // dakika basindan 5 sn sonra
    if (slot) {
      runs.push(new Date(slot.ms).toISOString());
      r.last_run_at = new Date(slot.ms);
    }
  }
  return runs;
}

test('isValidTimeZone / resolveTimeZone', () => {
  for (const ok of ['Europe/Istanbul', 'UTC', 'America/New_York', 'Asia/Tokyo']) assert.equal(isValidTimeZone(ok), true, ok);
  for (const bad of ['Mars/Phobos', '', null, undefined, 42, 'x'.repeat(65), 'Europe/Istanbul; DROP']) {
    assert.equal(isValidTimeZone(bad), false, String(bad));
  }
  assert.equal(resolveTimeZone('Mars/Phobos'), 'Europe/Istanbul');
  assert.equal(resolveTimeZone(null), 'Europe/Istanbul');
  assert.equal(resolveTimeZone('Asia/Tokyo'), 'Asia/Tokyo');
});

test('localParts: Istanbul (UTC+3, DST yok), gece yarisi 24 degil 0, gun adi dogru', () => {
  const p = localParts(Z('2026-10-01T05:30:00Z'), 'Europe/Istanbul');
  assert.deepEqual(
    { h: p.hour, m: p.minute, dow: p.dow, d: p.dateKey },
    { h: 8, m: 30, dow: 4, d: '2026-10-01' } // 1 Ekim 2026 Persembe
  );
  const mid = localParts(Z('2026-10-01T21:00:00Z'), 'Europe/Istanbul');
  assert.deepEqual({ h: mid.hour, m: mid.minute, dow: mid.dow, d: mid.dateKey }, { h: 0, m: 0, dow: 5, d: '2026-10-02' });
  // Yaz/kis fark etmez (Turkiye kalici +03)
  assert.equal(localParts(Z('2026-01-15T05:30:00Z'), 'Europe/Istanbul').hour, 8);
  assert.equal(localParts(Z('2026-07-15T05:30:00Z'), 'Europe/Istanbul').hour, 8);
});

test('localParts: DST gecisleri (New_York bahar ileri / sonbahar geri)', () => {
  const tz = 'America/New_York';
  // 2026-03-08 02:00 -> 03:00 (EST -> EDT)
  assert.deepEqual(((p) => [p.hour, p.minute])(localParts(Z('2026-03-08T06:59:00Z'), tz)), [1, 59]);
  assert.deepEqual(((p) => [p.hour, p.minute])(localParts(Z('2026-03-08T07:00:00Z'), tz)), [3, 0]);
  // 2026-11-01 02:00 EDT -> 01:00 EST: 01:30 iki kez yasanir
  assert.deepEqual(((p) => [p.hour, p.minute])(localParts(Z('2026-11-01T05:30:00Z'), tz)), [1, 30]);
  assert.deepEqual(((p) => [p.hour, p.minute])(localParts(Z('2026-11-01T06:30:00Z'), tz)), [1, 30]);
});

test('windowSlots: su anki dakika + onceki 2 dakika (en yeni basta), dakika sinirina yuvarlanir', () => {
  const slots = windowSlots(Z('2026-10-01T05:30:42Z'), 'Europe/Istanbul', 2);
  assert.deepEqual(
    slots.map((s) => new Date(s.ms).toISOString()),
    ['2026-10-01T05:30:00.000Z', '2026-10-01T05:29:00.000Z', '2026-10-01T05:28:00.000Z']
  );
  assert.deepEqual(slots.map((s) => [s.parts.hour, s.parts.minute]), [[8, 30], [8, 29], [8, 28]]);
});

test('normalizeDays: dizi, JSON metni, gecersiz ogeler elenir', () => {
  assert.deepEqual(normalizeDays([1, 3, 5]), [1, 3, 5]);
  assert.deepEqual(normalizeDays('[0,6]'), [0, 6]);
  assert.deepEqual(normalizeDays([1, 7, -1, '2', 3.5, null]), [1]);
  assert.deepEqual(normalizeDays(null), []);
  assert.deepEqual(normalizeDays('bozuk'), []);
  assert.deepEqual(normalizeDays({ a: 1 }), []);
});

test('dueSlotForRule: kural EVIN saat diliminde eslesir (Istanbul 08:30 = 05:30Z)', () => {
  const rule = { hour: 8, minute: 30, days_of_week: ALL_DAYS, last_run_at: null };
  const slot = dueSlotForRule(rule, infoAt(Z('2026-10-01T05:30:20Z'), 'Europe/Istanbul'));
  assert.equal(new Date(slot.ms).toISOString(), '2026-10-01T05:30:00.000Z');
  // ayni UTC anda UTC saat dilimli bir ev icin 08:30 kurali DEGIL, 05:30 kurali eslesir
  assert.equal(dueSlotForRule(rule, infoAt(Z('2026-10-01T05:30:20Z'), 'UTC')), null);
  const utcRule = { hour: 5, minute: 30, days_of_week: ALL_DAYS, last_run_at: null };
  assert.ok(dueSlotForRule(utcRule, infoAt(Z('2026-10-01T05:30:20Z'), 'UTC')));
});

test('dueSlotForRule: gun filtresi (0=Pazar..6=Cumartesi) yerel gune gore', () => {
  const info = infoAt(Z('2026-10-01T05:30:20Z'), 'Europe/Istanbul'); // Persembe = 4
  assert.ok(dueSlotForRule({ hour: 8, minute: 30, days_of_week: [4] }, info));
  assert.ok(dueSlotForRule({ hour: 8, minute: 30, days_of_week: [0, 4, 6] }, info));
  assert.equal(dueSlotForRule({ hour: 8, minute: 30, days_of_week: [0, 1, 2, 3, 5, 6] }, info), null);
  assert.equal(dueSlotForRule({ hour: 8, minute: 30, days_of_week: [] }, info), null);
  assert.equal(dueSlotForRule({ hour: 8, minute: 30, days_of_week: null }, info), null);
});

test('dueSlotForRule: gece yarisi sonrasi yerel gun (UTC gunu degil) esas alinir', () => {
  // 2026-10-01T21:30Z = Istanbul 2 Ekim 00:30 (Cuma = 5)
  const info = infoAt(Z('2026-10-01T21:30:10Z'), 'Europe/Istanbul');
  assert.ok(dueSlotForRule({ hour: 0, minute: 30, days_of_week: [5] }, info));
  assert.equal(dueSlotForRule({ hour: 0, minute: 30, days_of_week: [4] }, info), null);
});

test('telafi penceresi: 2 dakikaya kadar gecikmis tur yakalar, 3 dakika gecikmis yakalayamaz', () => {
  const rule = { hour: 8, minute: 30, days_of_week: ALL_DAYS, last_run_at: null };
  for (const delayMin of [0, 1, 2]) {
    const s = dueSlotForRule(rule, infoAt(Z('2026-10-01T05:30:05Z') + delayMin * MIN, 'Europe/Istanbul'));
    assert.ok(s, `${delayMin} dk gecikme yakalanmali`);
    assert.equal(new Date(s.ms).toISOString(), '2026-10-01T05:30:00.000Z');
  }
  assert.equal(dueSlotForRule(rule, infoAt(Z('2026-10-01T05:30:05Z') + 3 * MIN, 'Europe/Istanbul')), null);
});

test('telafi gece yarisini asar (23:59 kurali, 00:00:30 turunda yakalanir; gun yuvaya gore)', () => {
  // Pazartesi (1) 23:59 Istanbul = 20:59Z; tur Sali 00:00:30 yerel = 21:00:30Z
  const rule = { hour: 23, minute: 59, days_of_week: [1], last_run_at: null };
  const s = dueSlotForRule(rule, infoAt(Z('2026-10-05T21:00:30Z'), 'Europe/Istanbul')); // 5 Ekim 2026 Pazartesi
  assert.ok(s);
  assert.equal(new Date(s.ms).toISOString(), '2026-10-05T20:59:00.000Z');
});

test('tekrar engeli: last_run_at >= yuva ise tekrar calismaz; dunku calisma engellemez', () => {
  const info = infoAt(Z('2026-10-01T05:30:20Z'), 'Europe/Istanbul');
  const slotMs = Z('2026-10-01T05:30:00Z');
  assert.equal(dueSlotForRule({ hour: 8, minute: 30, days_of_week: ALL_DAYS, last_run_at: new Date(slotMs) }, info), null);
  assert.equal(dueSlotForRule({ hour: 8, minute: 30, days_of_week: ALL_DAYS, last_run_at: new Date(slotMs + 1000) }, info), null);
  assert.ok(dueSlotForRule({ hour: 8, minute: 30, days_of_week: ALL_DAYS, last_run_at: new Date(slotMs - 24 * 60 * MIN) }, info));
  // ISO metni olarak gelen zaman damgalari (pg Date doner, ama metin de tolere edilir)
  assert.equal(dueSlotForRule({ hour: 8, minute: 30, days_of_week: ALL_DAYS, last_run_at: '2026-10-01T05:30:00.000Z' }, info), null);
});

test('simulasyon: ardisik dakikalarda ayni yuva ASLA iki kez calismaz (telafi penceresi acikken bile)', () => {
  const rule = { hour: 8, minute: 30, days_of_week: ALL_DAYS, last_run_at: null };
  const runs = simulate(rule, 'Europe/Istanbul', '2026-10-01T05:00:00Z', '2026-10-01T06:30:00Z');
  assert.deepEqual(runs, ['2026-10-01T05:30:00.000Z']);
});

test('simulasyon: gunluk kural bir hafta boyunca gunde tam bir kez', () => {
  const rule = { hour: 22, minute: 0, days_of_week: ALL_DAYS, last_run_at: null };
  const runs = simulate(rule, 'Europe/Istanbul', '2026-10-01T00:00:00Z', '2026-10-08T00:00:00Z');
  assert.equal(runs.length, 7);
  assert.equal(new Set(runs).size, 7);
});

test('olusturma/duzenleme oncesi yuva TELAFI EDILMEZ (yeni kural gecmis dakika icin hemen tetiklenmez)', () => {
  const info = infoAt(Z('2026-10-01T05:31:10Z'), 'Europe/Istanbul'); // yuva 05:30:00Z pencerede
  const base = { hour: 8, minute: 30, days_of_week: ALL_DAYS, last_run_at: null };
  assert.equal(dueSlotForRule({ ...base, schedule_changed_at: new Date(Z('2026-10-01T05:30:20Z')) }, info), null);
  assert.ok(dueSlotForRule({ ...base, schedule_changed_at: new Date(Z('2026-10-01T05:29:59Z')) }, info));
  // eski kural (dakikalar once duzenlenmis) telafi edilir
  assert.ok(dueSlotForRule({ ...base, schedule_changed_at: new Date(Z('2026-09-01T00:00:00Z')) }, info));
});

test('DST bahar atlamasi: var olmayan yerel saat (02:30) o gun CALISMAZ, ertesi gun calisir', () => {
  const rule = { hour: 2, minute: 30, days_of_week: ALL_DAYS, last_run_at: null };
  const springDay = simulate(rule, 'America/New_York', '2026-03-08T00:00:00Z', '2026-03-09T00:00:00Z');
  assert.deepEqual(springDay, [], 'atlanan saat icin kural tetiklenmemeli');
  const nextDay = simulate({ ...rule, last_run_at: null }, 'America/New_York', '2026-03-09T00:00:00Z', '2026-03-10T00:00:00Z');
  assert.equal(nextDay.length, 1);
});

test('DST bahar atlamasi: 03:00 kurali atlama gunu dogru UTC aninda (07:00Z) calisir', () => {
  const rule = { hour: 3, minute: 0, days_of_week: ALL_DAYS, last_run_at: null };
  const runs = simulate(rule, 'America/New_York', '2026-03-08T00:00:00Z', '2026-03-09T00:00:00Z');
  assert.deepEqual(runs, ['2026-03-08T07:00:00.000Z']);
});

test('DST sonbahar geri alma: tekrar eden yerel saat (01:30) YALNIZCA BIR KEZ calisir', () => {
  const rule = { hour: 1, minute: 30, days_of_week: ALL_DAYS, last_run_at: null };
  const runs = simulate(rule, 'America/New_York', '2026-11-01T00:00:00Z', '2026-11-02T00:00:00Z');
  assert.equal(runs.length, 1, `beklenen 1 calisma, gelen: ${JSON.stringify(runs)}`);
  assert.equal(runs[0], '2026-11-01T05:30:00.000Z'); // ilk (EDT) yasanis
});

test('DST: Berlin sonbahar geri alma (02:30 iki kez) bir kez; bahar (02:30 yok) hic', () => {
  const rule = { hour: 2, minute: 30, days_of_week: ALL_DAYS, last_run_at: null };
  assert.equal(simulate(rule, 'Europe/Berlin', '2026-10-24T22:00:00Z', '2026-10-25T22:00:00Z').length, 1);
  assert.equal(simulate({ ...rule, last_run_at: null }, 'Europe/Berlin', '2026-03-28T22:00:00Z', '2026-03-29T22:00:00Z').length, 0);
});

test('Turkiye kalici +03: yaz/kis gecisi yok, kural her mevsim ayni UTC aninda', () => {
  const rule = { hour: 7, minute: 15, days_of_week: ALL_DAYS, last_run_at: null };
  const win = simulate(rule, 'Europe/Istanbul', '2026-01-15T00:00:00Z', '2026-01-16T00:00:00Z');
  const sum = simulate({ ...rule, last_run_at: null }, 'Europe/Istanbul', '2026-07-15T00:00:00Z', '2026-07-16T00:00:00Z');
  assert.deepEqual(win, ['2026-01-15T04:15:00.000Z']);
  assert.deepEqual(sum, ['2026-07-15T04:15:00.000Z']);
});

test('gecersiz kural alanlari: saat/dakika sayi degilse eslesme yok', () => {
  const info = infoAt(Z('2026-10-01T05:30:20Z'), 'Europe/Istanbul');
  assert.equal(dueSlotForRule({ hour: 'x', minute: 30, days_of_week: ALL_DAYS }, info), null);
  assert.equal(dueSlotForRule({ hour: 8, minute: null, days_of_week: ALL_DAYS }, info), null);
  assert.equal(dueSlotForRule({ hour: 8.5, minute: 30, days_of_week: ALL_DAYS }, info), null);
});

// -- Komut cevirme ---------------------------------------------------------------

test('ruleToCommand: role on/off -> { relay, state:boolean, id } (1 tabanli)', () => {
  const slotMs = Z('2026-10-01T05:30:00Z');
  assert.deepEqual(ruleToCommand({ id: 12, channel: 3, channel_type: 'relay', action: 'on' }, slotMs), {
    relay: 3,
    state: true,
    id: `sr12-${Math.floor(slotMs / MIN).toString(36)}`,
  });
  const off = ruleToCommand({ id: 12, channel: 1, channel_type: 'relay', action: 'off' }, slotMs);
  assert.equal(off.relay, 1);
  assert.equal(off.state, false);
  assert.equal(typeof off.state, 'boolean'); // "ON" string degil
  // channel_type bos -> role (eski kayit)
  assert.ok(ruleToCommand({ id: 1, channel: 2, action: 'on' }, slotMs));
});

test('ruleToCommand: panjur open/close -> { shutter, cmd: up|down, id }', () => {
  const slotMs = Z('2026-10-01T05:30:00Z');
  const open = ruleToCommand({ id: 5, channel: 2, channel_type: 'shutter', action: 'open' }, slotMs);
  assert.equal(open.shutter, 2);
  assert.equal(open.cmd, 'up');
  const close = ruleToCommand({ id: 5, channel: 2, channel_type: 'shutter', action: 'close' }, slotMs);
  assert.equal(close.cmd, 'down');
  assert.equal('relay' in open, false);
});

test('ruleToCommand: gecersiz kombinasyonlar null (firmware sessizce varsayilana dusmez)', () => {
  const slotMs = Z('2026-10-01T05:30:00Z');
  const bad = [
    { id: 1, channel: 0, channel_type: 'relay', action: 'on' }, // 0 tabanli kanal
    { id: 1, channel: 65, channel_type: 'relay', action: 'on' },
    { id: 1, channel: 1.5, channel_type: 'relay', action: 'on' },
    { id: 1, channel: 'a', channel_type: 'relay', action: 'on' },
    { id: 1, channel: 1, channel_type: 'relay', action: 'open' }, // tip/eylem uyumsuz
    { id: 1, channel: 1, channel_type: 'shutter', action: 'on' },
    { id: 1, channel: 1, channel_type: 'relay', action: 'toggle' },
    { id: 1, channel: 1, channel_type: 'plug', action: 'on' },
    { id: 1, channel: 1, channel_type: 'relay', action: undefined },
  ];
  for (const rule of bad) assert.equal(ruleToCommand(rule, slotMs), null, JSON.stringify(rule));
});

test('ruleToCommand: komut id\'si <= 24 karakter ve guvenli alfabe (cihaz tekilleştirme)', () => {
  const id = ruleToCommand({ id: 2147483647, channel: 1, channel_type: 'relay', action: 'on' }, Z('2026-10-01T05:30:00Z')).id;
  assert.ok(id.length <= 24, id);
  assert.match(id, /^[A-Za-z0-9_.:-]{1,24}$/);
  // ayni yuva -> ayni id (yeniden denemede cihaz tekrar uygulamaz); farkli yuva -> farkli id
  const a = ruleToCommand({ id: 7, channel: 1, channel_type: 'relay', action: 'on' }, Z('2026-10-01T05:30:00Z')).id;
  const b = ruleToCommand({ id: 7, channel: 1, channel_type: 'relay', action: 'on' }, Z('2026-10-01T05:30:00Z')).id;
  const c = ruleToCommand({ id: 7, channel: 1, channel_type: 'relay', action: 'on' }, Z('2026-10-02T05:30:00Z')).id;
  assert.equal(a, b);
  assert.notEqual(a, c);
});

// -- Yetki -------------------------------------------------------------------------

test('isCreatorAuthorized: owner/resident/staff/super evet; misafir/uye degil/silinmis/dondurulmus hayir', () => {
  const now = Z('2026-10-01T05:30:00Z');
  const active = { is_active: true, account_status: null, global_role: 'user' };
  assert.equal(isCreatorAuthorized({ ...active, home_role: 'owner' }, now), true);
  assert.equal(isCreatorAuthorized({ ...active, home_role: 'resident' }, now), true);
  assert.equal(isCreatorAuthorized({ ...active, home_role: 'service_user' }, now), true);
  assert.equal(isCreatorAuthorized({ ...active, global_role: 'super_user', home_role: null }, now), true);

  assert.equal(isCreatorAuthorized({ ...active, home_role: 'guest' }, now), false);
  assert.equal(isCreatorAuthorized({ ...active, home_role: null }, now), false, 'uyelik silinmis (evden cikarilmis)');
  assert.equal(isCreatorAuthorized(null, now), false, 'kullanici silinmis');
  assert.equal(isCreatorAuthorized({ ...active, is_active: false, home_role: 'owner' }, now), false);
  assert.equal(isCreatorAuthorized({ ...active, account_status: 'suspended', home_role: 'owner' }, now), false);
  assert.equal(isCreatorAuthorized({ ...active, account_status: 'FROZEN', home_role: 'owner' }, now), false);
  assert.equal(isCreatorAuthorized({ ...active, account_status: 'active', home_role: 'owner' }, now), true);
  assert.equal(isCreatorAuthorized({ ...active, account_status: 'pending_invite', home_role: 'owner' }, now), true);
  assert.equal(isCreatorAuthorized({ ...active, global_role: 'service_user', home_role: null }, now), false, 'uyeliksiz personel');
  assert.equal(isCreatorAuthorized({ ...active, global_role: 'installer', home_role: null }, now), false);
});

test('isCreatorAuthorized: suresi dolmus gecici servis erisimi (installer_expires_at) reddedilir', () => {
  const now = Z('2026-10-01T05:30:00Z');
  const row = { is_active: true, global_role: 'user', home_role: 'service_user' };
  assert.equal(isCreatorAuthorized({ ...row, installer_expires_at: new Date(now - MIN) }, now), false);
  assert.equal(isCreatorAuthorized({ ...row, installer_expires_at: new Date(now + MIN) }, now), true);
  assert.equal(isCreatorAuthorized({ ...row, installer_expires_at: null }, now), true);
});
