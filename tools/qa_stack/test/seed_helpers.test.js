// Tohumlama (seed) saf yardimcilari: adim durumu/ozet metni, zamanli kural plani (ev + kural adi), servis PIN gecerliligi.
// Gercek yigin uzerindeki davranis: test/seed_idempotency.test.js.
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  SCHEDULED_RULES, SERVICE_PIN_REFRESH_MARGIN_MS, STEP_STATUS, formatSeedSummary, formatStepLine, isServicePinUsable, planScheduledRules,
  summarizeSteps,
} from '../lib/seed.js';
import { hasStatuses, normalizeStepResult, stepStatusOf } from '../lib/seed_report.js';

const step = (name, status, detail) => ({ name, ok: status !== 'failed' && status !== 'blocked', status, ...(detail ? { detail } : {}) });
const many = (n, status, prefix) => Array.from({ length: n }, (_, i) => step(`${prefix}${i}`, status));

// ------------------------------------------------------------------------------------------------ adim sonucu / ozet
test('normalizeStepResult: string/undefined = applied; {status, detail} aynen; bilinmeyen durum = applied', () => {
  assert.deepEqual(normalizeStepResult('olusturuldu'), { status: 'applied', detail: 'olusturuldu' });
  assert.deepEqual(normalizeStepResult(undefined), { status: 'applied', detail: undefined });
  assert.deepEqual(normalizeStepResult({ status: 'unchanged', detail: 'zaten var' }), { status: 'unchanged', detail: 'zaten var' });
  assert.deepEqual(normalizeStepResult({ status: 'verified' }), { status: 'verified', detail: undefined });
  assert.equal(normalizeStepResult({ status: 'uydurma', detail: 'x' }).status, 'applied');
});

test('formatSeedSummary: ilk calistirma -> "17 yapildi, 0 atlandi"; tekrar -> "0 yapildi, 17 atlandi (zaten var)"', () => {
  const first = [...many(17, 'applied', 'a'), ...many(3, 'verified', 'v')];
  assert.equal(formatSeedSummary(first), 'tamam  (20/20 adim: 17 yapildi, 0 atlandi (zaten var), 3 dogrulandi)');
  const again = [...many(17, 'unchanged', 'a'), ...many(3, 'verified', 'v')];
  assert.equal(formatSeedSummary(again), 'tamam  (20/20 adim: 0 yapildi, 17 atlandi (zaten var), 3 dogrulandi)');
  const s = summarizeSteps(again);
  assert.deepEqual({ applied: s.applied, unchanged: s.unchanged, verified: s.verified, done: s.done, total: s.total, ok: s.ok }, { applied: 0, unchanged: 17, verified: 3, done: 20, total: 20, ok: true });
});

test('formatSeedSummary: basarisiz ve engellenen adimlar "N/N" icinde SAYILMAZ ve ayri yazilir', () => {
  const steps = [...many(2, 'applied', 'a'), ...many(9, 'unchanged', 'u'), ...many(3, 'verified', 'v'), ...many(3, 'failed', 'f'), ...many(3, 'blocked', 'b')];
  assert.equal(
    formatSeedSummary(steps),
    'KISMEN BASARISIZ  (14/20 adim: 2 yapildi, 9 atlandi (zaten var), 3 dogrulandi; 3 basarisiz, 3 engellendi)',
  );
  const s = summarizeSteps(steps);
  assert.equal(s.ok, false);
  assert.equal(s.done, 14);
});

test('formatSeedSummary: durum alani olmayan ESKI stack.json kayitlarinda ayrim uydurulmaz', () => {
  const legacy = [{ name: 'a', ok: true }, { name: 'b', ok: true }, { name: 'c', ok: false, detail: 'x' }];
  assert.equal(hasStatuses(legacy), false);
  assert.equal(formatSeedSummary(legacy), 'KISMEN BASARISIZ  (2/3 adim)');
  assert.equal(formatSeedSummary([{ name: 'a', ok: true }]), 'tamam  (1/1 adim)');
  assert.equal(stepStatusOf({ ok: true }), 'applied');
  assert.equal(stepStatusOf({ ok: false }), 'failed');
});

test('formatStepLine: her durum ayri etiketle yazilir', () => {
  // etiketler 10 karakter genisliginde hizalanir (+ 1 bosluk)
  assert.equal(formatStepLine(step('x', STEP_STATUS.APPLIED, 'd')), 'YAPILDI    x  - d');
  assert.equal(formatStepLine(step('x', STEP_STATUS.UNCHANGED)), 'ATLANDI    x');
  assert.equal(formatStepLine(step('x', STEP_STATUS.VERIFIED)), 'DOGRULANDI x');
  assert.equal(formatStepLine(step('x', STEP_STATUS.FAILED, 'hata')), 'HATA       x  - hata');
  assert.equal(formatStepLine(step('x', STEP_STATUS.BLOCKED)), 'ENGELLENDI x');
});

// ------------------------------------------------------------------------------------------------ zamanli kurallar
const labels = SCHEDULED_RULES.map((r) => r.label);
const rule = (id, label) => ({ id, label });

test('SCHEDULED_RULES: 4 kural, adlar benzersiz (benzersizlik anahtari = ev + kural adi)', () => {
  assert.equal(SCHEDULED_RULES.length, 4);
  assert.equal(new Set(labels).size, 4);
  for (const r of SCHEDULED_RULES) assert.ok(r.label && r.label.trim() === r.label, `etiket: ${r.label}`);
});

test('planScheduledRules: bos ev -> 4 kural olusturulur', () => {
  const p = planScheduledRules([], SCHEDULED_RULES);
  assert.equal(p.create.length, 4);
  assert.deepEqual(p.keep, []);
  assert.deepEqual(p.remove, []);
});

test('planScheduledRules: kurallar zaten varsa HICBIR SEY yapilmaz (idempotent)', () => {
  const existing = labels.map((l, i) => rule(10 + i, l));
  const p = planScheduledRules(existing, SCHEDULED_RULES);
  assert.deepEqual(p.create, []);
  assert.deepEqual(p.remove, []);
  assert.deepEqual(p.keep, labels.map((l, i) => ({ label: l, id: 10 + i })));
});

test('planScheduledRules: yinelenenler (eski tohum calistirmalari) silinir, EN KUCUK id korunur', () => {
  const existing = [
    ...labels.map((l, i) => rule(50 + i, l)),     // ikinci tohum
    ...labels.map((l, i) => rule(10 + i, l)),     // ilk tohum (daha kucuk id)
    ...labels.map((l, i) => rule(90 + i, l)),     // ucuncu tohum
  ];
  const p = planScheduledRules(existing, SCHEDULED_RULES);
  assert.deepEqual(p.create, []);
  assert.deepEqual(p.keep, labels.map((l, i) => ({ label: l, id: 10 + i })));
  assert.equal(p.remove.length, 8);
  assert.deepEqual(p.remove.map((r) => r.id).sort((a, b) => a - b), [50, 51, 52, 53, 90, 91, 92, 93]);
});

test('planScheduledRules: eksik olan eklenir; kullanicinin kendi kurali ve etiketsiz kayit dokunulmaz', () => {
  const existing = [rule(1, labels[0]), rule(2, labels[1]), rule(3, 'Benim kuralim'), { id: 4, label: null }, { id: 5 }];
  const p = planScheduledRules(existing, SCHEDULED_RULES);
  assert.deepEqual(p.create.map((r) => r.label), [labels[2], labels[3]]);
  assert.deepEqual(p.keep, [{ label: labels[0], id: 1 }, { label: labels[1], id: 2 }]);
  assert.deepEqual(p.remove, []);
  assert.deepEqual(planScheduledRules(undefined, SCHEDULED_RULES).create.length, 4);
});

// ------------------------------------------------------------------------------------------------ servis PIN'i
test('isServicePinUsable: sunucuda ayni bitis zamanli "active" kayit + yeterli sure varsa true', () => {
  const now = Date.parse('2026-10-02T10:00:00.000Z');
  const exp = '2026-10-02T11:30:00.000Z';
  const pin = { pin: '123456', expires_at: exp };
  const tokens = [{ status: 'revoked', expires_at: '2026-10-02T09:00:00.000Z' }, { status: 'active', expires_at: exp }];
  assert.equal(isServicePinUsable(pin, tokens, now), true);
  // ms duzeyindeki gosterim farki tolere edilir
  assert.equal(isServicePinUsable(pin, [{ status: 'active', expires_at: '2026-10-02T11:30:00.500Z' }], now), true);
});

test('isServicePinUsable: kullanilmis / iptal / baska PIN / eksik kayit / suresi azalmis -> false (yenilenir)', () => {
  const now = Date.parse('2026-10-02T10:00:00.000Z');
  const exp = '2026-10-02T11:30:00.000Z';
  const pin = { pin: '123456', expires_at: exp };
  assert.equal(isServicePinUsable(pin, [{ status: 'used', expires_at: exp }], now), false, 'tuketilmis');
  assert.equal(isServicePinUsable(pin, [{ status: 'revoked', expires_at: exp }], now), false, 'iptal');
  assert.equal(isServicePinUsable(pin, [{ status: 'expired', expires_at: exp }], now), false, 'suresi dolmus');
  assert.equal(isServicePinUsable(pin, [{ status: 'active', expires_at: '2026-10-02T12:00:00.000Z' }], now), false, 'baska PIN\'in kaydi');
  assert.equal(isServicePinUsable(pin, [], now), false, 'sunucuda kayit yok');
  assert.equal(isServicePinUsable(pin, undefined, now), false);
  assert.equal(isServicePinUsable(undefined, [{ status: 'active', expires_at: exp }], now), false, 'accounts.json\'da PIN yok');
  assert.equal(isServicePinUsable({ pin: '', expires_at: exp }, [{ status: 'active', expires_at: exp }], now), false);
  assert.equal(isServicePinUsable({ pin: '123456', expires_at: 'bozuk' }, [{ status: 'active', expires_at: exp }], now), false);
  // son 15 dakika: kullaniciyi yarim birakmamak icin yenilenir
  const soon = new Date(now + SERVICE_PIN_REFRESH_MARGIN_MS - 1000).toISOString();
  assert.equal(isServicePinUsable({ pin: '123456', expires_at: soon }, [{ status: 'active', expires_at: soon }], now), false, 'bitmesine < 15 dk');
  const enough = new Date(now + SERVICE_PIN_REFRESH_MARGIN_MS + 1000).toISOString();
  assert.equal(isServicePinUsable({ pin: '123456', expires_at: enough }, [{ status: 'active', expires_at: enough }], now), true);
});
