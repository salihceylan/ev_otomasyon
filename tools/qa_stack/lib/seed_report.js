// Tohumlama (seed) adim sonuclari: durum modeli + ozet metni. SAF modul (bagimlilik yok): run.js durum/ozet
// ciktisi ve testler bunu yukler; pg/bcrypt/REST kodu (seed.js) buraya bagimli, tersi degil.
//
// Her adim su durumlardan birini tasir:
//   applied    gercekten bir sey yapildi (olusturuldu / yenilendi / onarildi)
//   unchanged  zaten istenen durumdaydi -> hicbir sey yazilmadi ("atlandi (zaten var)")
//   verified   salt-okunur kontrol gecti (sunucu hazir, ev listesi, cihaz cevrimici)
//   failed     adim hata verdi
//   blocked    onkosul adimi basarisiz/eksik oldugu icin calistirilmadi
// `ok` = failed/blocked DEGIL. "Tohumlama tamam (N/N adim)" N'si yalnizca ok adimlari sayar; ayrintisi
// "X yapildi, Y atlandi (zaten var), Z dogrulandi" olarak yazilir: ikinci/ucuncu calistirmada "0 yapildi" gorulmelidir.

export const STEP_STATUS = Object.freeze({
  APPLIED: 'applied',
  UNCHANGED: 'unchanged',
  VERIFIED: 'verified',
  FAILED: 'failed',
  BLOCKED: 'blocked',
});

const KNOWN = new Set(Object.values(STEP_STATUS));

/** Adim govdesinin donusunu {status, detail}'a cevirir: string / undefined -> applied; {status, detail} aynen. */
export function normalizeStepResult(r) {
  if (r && typeof r === 'object' && KNOWN.has(r.status)) {
    return { status: r.status, detail: typeof r.detail === 'string' ? r.detail : undefined };
  }
  return { status: STEP_STATUS.APPLIED, detail: typeof r === 'string' ? r : undefined };
}

/** Eski (durum alani olmayan) kayitlar icin: ok -> applied, degilse failed (ayrim bilinmez; bkz. hasStatuses). */
export function stepStatusOf(step) {
  if (step && KNOWN.has(step.status)) return step.status;
  return step && step.ok ? STEP_STATUS.APPLIED : STEP_STATUS.FAILED;
}

export const hasStatuses = (steps) => Array.isArray(steps) && steps.length > 0 && steps.every((s) => s && KNOWN.has(s.status));

export function summarizeSteps(steps) {
  const list = Array.isArray(steps) ? steps : [];
  const s = { total: list.length, applied: 0, unchanged: 0, verified: 0, failed: 0, blocked: 0 };
  for (const st of list) s[stepStatusOf(st)] += 1;
  s.done = s.applied + s.unchanged + s.verified;
  s.ok = s.failed === 0 && s.blocked === 0;
  return s;
}

/**
 * `up` ozeti ve `seed` sonu icin tek satirlik metin.
 *   tamam  (20/20 adim: 0 yapildi, 17 atlandi (zaten var), 3 dogrulandi)
 *   KISMEN BASARISIZ  (17/20 adim: 2 yapildi, 14 atlandi (zaten var), 1 dogrulandi; 2 basarisiz, 1 engellendi)
 * Durum alani olmayan eski stack.json kayitlarinda yalnizca "(N/M adim)" yazilir (ayrim uydurulmaz).
 */
export function formatSeedSummary(steps) {
  const s = summarizeSteps(steps);
  const head = s.ok ? 'tamam' : 'KISMEN BASARISIZ';
  if (!hasStatuses(steps)) return `${head}  (${s.done}/${s.total} adim)`;
  const detail = `${s.applied} yapildi, ${s.unchanged} atlandi (zaten var), ${s.verified} dogrulandi`;
  const bad = [s.failed ? `${s.failed} basarisiz` : '', s.blocked ? `${s.blocked} engellendi` : ''].filter(Boolean).join(', ');
  return `${head}  (${s.done}/${s.total} adim: ${detail}${bad ? `; ${bad}` : ''})`;
}

const LABEL = {
  [STEP_STATUS.APPLIED]: 'YAPILDI   ',
  [STEP_STATUS.UNCHANGED]: 'ATLANDI   ',
  [STEP_STATUS.VERIFIED]: 'DOGRULANDI',
  [STEP_STATUS.FAILED]: 'HATA      ',
  [STEP_STATUS.BLOCKED]: 'ENGELLENDI',
};

/** `run.js seed` adim satiri. */
export function formatStepLine(step) {
  return `${LABEL[stepStatusOf(step)]} ${step.name}${step.detail ? `  - ${step.detail}` : ''}`;
}
