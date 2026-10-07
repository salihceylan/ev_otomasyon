'use strict';

// ==============================================================================
// AHBU Akilli Ev - Uc nokta YERLESIM esitleme servisi (pano -> bulut `endpoints`)      [WP-L, CONTRACTS §2.4b]
// ==============================================================================
//
// SORUN: daire kullanicisinin ekranindaki kontroller sahiplenme anindaki SABIT sablondan acilan `endpoints`
//   satirlarindan cizilir; servis sorumlusu panoda yerlesimi degistirirse (cift panjur yapildi, ek modul eklendi,
//   kanala ad verildi) bulut bunu ogrenmez. Pano ise her `state` mesajinda gercek yerlesimi zaten yayinlar.
//
// TASARIM (kopru `mqtt_bridge.js` bu modulu CANLI `state` COMMIT edildikten sonra cagirir; bkz. onLiveState):
//   * KARAR saf cekirdektedir (utils/endpoint_layout.js `planLayoutSync`); bu modul yalniz G/C yapar:
//     onbellek, hiz siniri, kuyruk, transaction, denetim kaydi, istatistik.
//   * YUK: imza (id+tip+ad) degismediyse HICBIR sorgu yapilmaz. Ayni imza icin cihaz basina RECHECK_MS'te bir
//     kilitsiz dogrulama okumasi yapilir (sifirlama / yeniden tohumlama sonrasi kendi kendini onarma). Cihaz basina
//     en sik MIN_RUN_INTERVAL_MS'te bir calisir.
//   * ESZAMANLILIK: once kilitsiz okuma + plan; yazilacak bir sey varsa TEK transaction icinde `devices` satiri,
//     ardindan `endpoints` satirlari kilitlenir (claim / sifirlama / pano degisimi ile ayni kilit sirasi) ve plan
//     kilitli taze veriyle YENIDEN hesaplanir. Yazilan her sey kilitli plana gore yazilir.
//   * KUCULME: bildirilen kanal sayisindan buyuk kanalli satirlar ancak ayni kuculme en az SHRINK_CONFIRM_MS
//     arayla IKINCI kez gorulunce silinir (tek bir tutarsiz mesaj satir silemez). Onay bilgisi bellektedir.
//   * GECICI PANO (D1): cihaz devreye alinmamis + taban bos + bildirim tam fabrika yerlesimi ise yikici adimlar
//     ertelenir (taban yazilmaz, onbellek "tamam" olmaz, `deferred` sayaci); bkz. planFor.
//   * KOTUYE KULLANIM (D10): hiz siniri, kuculme onayi ve saatlik yazma butcesi (APPLY_BUDGET_PER_HOUR) imza
//     onbelleginden AYRI haritadadir; invalidate / onOffline bunlari silmez.
//   * YETKI SINIRI: yalniz `homeId` ile eslesen cihazin satirlarina dokunulur; cihaz baska eve tasinmissa
//     (kilitsiz ya da kilitli okumada) hicbir sey yazilmaz.
//   * Hata IZOLASYONU: her hata yutulur ve sayilir; onLiveState ASLA firlatmaz, kuyruk isi ASLA reddetmez.
//     Hatada onbellek guncellenmez: sonraki mesaj (hiz siniri icinde) yeniden dener.
//   * GUNLUK / DENETIM: yalniz sayilar ve kisaltilmis kimlik; ad, konu kimligi, uid YAZILMAZ.
//   * Zamanlayici KURULMAZ: bellek temizligi onLiveState icinde, GC_INTERVAL_MS'te bir yapilir.
//
// Sinirlar (bilincli):
//   * Surec yeniden baslayinca onbellek ve kuculme onayi sifirlanir (ilk mesajda bir kilitsiz okuma; kuculme
//     yeniden iki kez gorulmelidir).
//   * `stop()` baslamis isi kesmez (transaction yarida birakilmaz); yalniz baslamamis isler atilir.

const { planLayoutSync, parseBase, isFactoryLayout, hasActuators, actuatorVector } = require('../utils/endpoint_layout');

// ------------------------------------------------------------------------------
// Sabitler (ortam degiskeni DEGIL)
// ------------------------------------------------------------------------------
const RECHECK_MS = 5 * 60 * 1000; // ayni imza icin kilitsiz dogrulama araligi (cihaz basina)
const MIN_RUN_INTERVAL_MS = 5 * 1000; // cihaz basina iki calisma arasi en az sure
const SHRINK_CONFIRM_MS = 20 * 1000; // kuculme ancak bu kadar sonra ikinci kez gorulunce silinir
const CACHE_IDLE_MS = 60 * 60 * 1000; // bu kadar gorulmeyen cihaz kaydi bellekten atilir
const GC_INTERVAL_MS = 60 * 1000;
const MAX_CONCURRENT_HOMES = 2;
const MAX_PENDING = 20000;
const AUDIT_EVENT = 'endpoint_layout_synced';
const LOG_THROTTLE_MS = 10 * 60 * 1000; // ayni hata turu icin tekrar eden uyari satiri
const APPLY_BUDGET_PER_HOUR = 30; // D10: cihaz basina saatte en cok bu kadar SATIR DEGISTIREN calisma
const BUDGET_WINDOW_MS = 60 * 60 * 1000;

// ------------------------------------------------------------------------------
// SQL (tek noktada; testler esitlikle eslestirir)
// ------------------------------------------------------------------------------
const SQL = Object.freeze({
  device: 'SELECT d.id, d.home_id, d.device_uuid, d.reported_layout, d.is_commissioned FROM devices d WHERE d.id = $1',
  deviceLocked:
    'SELECT d.id, d.home_id, d.device_uuid, d.reported_layout, d.is_commissioned FROM devices d WHERE d.id = $1 FOR UPDATE',
  rows:
    'SELECT e.id, e.channel_index, e.name, e.type, e.room, e.shutter_pair_index, e.shutter_duration_sec ' +
    'FROM endpoints e WHERE e.device_id = $1 ORDER BY e.channel_index',
  rowsLocked:
    'SELECT e.id, e.channel_index, e.name, e.type, e.room, e.shutter_pair_index, e.shutter_duration_sec ' +
    'FROM endpoints e WHERE e.device_id = $1 ORDER BY e.channel_index FOR UPDATE',
  insertRow:
    'INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, ' +
    'shutter_duration_sec, current_state, current_position) ' +
    'VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) ON CONFLICT (device_id, channel_index) DO NOTHING',
  updateRow:
    'UPDATE endpoints SET name = $3, type = $4, room = $5, shutter_pair_index = $6, shutter_duration_sec = $7, ' +
    'current_position = COALESCE($8::int, current_position), updated_at = CURRENT_TIMESTAMP ' +
    'WHERE id = $1 AND device_id = $2',
  deleteAbove: 'DELETE FROM endpoints WHERE device_id = $1 AND channel_index > $2',
  // D14: device_id NULL kural yalniz evde TEK cihaz varsa bu panonundur (cok panolu evde baska panoya ait olabilir)
  disableRules:
    'UPDATE scheduled_rules SET enabled = FALSE ' +
    'WHERE home_id = $1 AND enabled = TRUE ' +
    'AND (device_id = $2 OR (device_id IS NULL AND (SELECT COUNT(*) FROM devices dv WHERE dv.home_id = $1) = 1)) ' +
    "AND ((channel_type = 'relay' AND channel = ANY($3::int[])) OR (channel_type = 'shutter' AND channel = ANY($4::int[]))) " +
    'RETURNING id',
  saveBase: 'UPDATE devices SET reported_layout = $2::jsonb, reported_layout_at = CURRENT_TIMESTAMP WHERE id = $1',
  // WP-S2 [Y2]: endpoints.actuator_type = panonun relays[].act (yalniz bildirimde ya da tabanda eylemci varsa calisir).
  // Degisen satirlari dondurur; yeni eylemci kanallarinin role kurallari disableRules ile kapatilir [O6].
  syncActuators:
    'UPDATE endpoints e SET actuator_type = v.act, updated_at = CURRENT_TIMESTAMP ' +
    'FROM unnest($2::int[], $3::varchar[]) AS v(channel, act) ' +
    'WHERE e.device_id = $1 AND e.channel_index = v.channel AND e.actuator_type IS DISTINCT FROM v.act ' +
    'RETURNING e.channel_index, e.actuator_type',
  audit:
    'INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details) ' +
    "VALUES ($1, $2, $3, NULL, 'device', NULL, $4::jsonb)",
});

// ------------------------------------------------------------------------------
// Yardimcilar
// ------------------------------------------------------------------------------
function shortId(value) {
  return String(value || '-').slice(0, 8);
}

/** Gunluge yazilabilir hata turu: yalniz kod ya da sinif adi (ileti YAZILMAZ: ad/kimlik tasiyabilir). */
function errorKind(err) {
  const code = err && typeof err.code === 'string' && /^[A-Za-z0-9_]{1,40}$/.test(err.code) ? err.code : null;
  return code || (err && typeof err.name === 'string' && /^[A-Za-z0-9_$]{1,40}$/.test(err.name) ? err.name : 'Error');
}

function nullIfMissing(value) {
  return value === undefined ? null : value;
}

function byChannel(a, b) {
  return a.channel_index - b.channel_index;
}

/** Cihaz satiri bu evin mi? Degilse neden kodu doner (yazma yapilmaz). */
function deviceMismatch(dev, homeId) {
  if (!dev) return 'device_not_found';
  if (dev.home_id === null || dev.home_id === undefined || String(dev.home_id) !== String(homeId)) return 'home_mismatch';
  return null;
}

function validArgs(homeId, deviceId, layout) {
  return Boolean(homeId) && Boolean(deviceId) && layout !== null && typeof layout === 'object';
}

/**
 * D1: cihaz satiri + bildirimden plani hesaplar. GECICI mod: cihaz devreye alinmamis (is_commissioned IS NOT TRUE)
 * VE taban bos (bu cihaz satiriyla hic esitlenmemis: pano degisimi / sifirlama sonrasi) VE bildirim tam fabrika
 * yerlesimi. Bu modda yikici adimlar ertelenir (bkz. planLayoutSync `provisional`).
 */
function planFor(dev, rows, layout, confirmShrink) {
  const base = parseBase(dev.reported_layout);
  const provisional = dev.is_commissioned !== true && base === null && isFactoryLayout(layout);
  return planLayoutSync({ reported: layout, base, rows, confirmShrink, provisional });
}

function deferredOf(plan) {
  return Number.isInteger(plan && plan.deferred) && plan.deferred > 0 ? plan.deferred : 0;
}

// ------------------------------------------------------------------------------
// Servis
// ------------------------------------------------------------------------------
class EndpointLayoutSync {
  /**
   * @param {object} deps
   * @param {{query:Function, withTransaction:Function}} deps.db   (zorunlu; bkz. src/db.js)
   * @param {object} [deps.logger]            log/warn/error
   * @param {()=>number} [deps.now]           ms
   * @param {object} [deps.timers]            imza uyumu icin kabul edilir; servis zamanlayici KURMAZ
   * @param {Function} [deps.QueueClass]      KeyedWorkQueue (varsayilan: mqtt_bridge'den tembel)
   */
  constructor(deps = {}) {
    if (!deps.db || typeof deps.db.query !== 'function' || typeof deps.db.withTransaction !== 'function') {
      throw new TypeError('EndpointLayoutSync: db (query, withTransaction) zorunludur');
    }
    this.db = deps.db;
    this.logger = deps.logger || console;
    this.now = typeof deps.now === 'function' ? deps.now : Date.now;

    const QueueClass = deps.QueueClass || require('../mqtt_bridge').KeyedWorkQueue;
    this._queue = new QueueClass({ concurrency: MAX_CONCURRENT_HOMES, maxPending: MAX_PENDING });

    // IMZA ONBELLEGI: deviceId -> { sig, homeId, topicId, checkedAt, pendingShrink, touched }
    // (invalidate / onOffline / _skip yalniz bunu siler)
    this._devices = new Map();
    // D10 SINIRLAR (imza onbelleginden AYRI; invalidate/onOffline SILMEZ, yalniz GC ve stop):
    // deviceId -> { lastRunAt, shrink:{count,since}|null, windowStart, applies, warned, touched }
    this._limits = new Map();
    this._warnedAt = new Map(); // hata turu -> son uyari zamani
    this._stopped = false;
    this._lastGcAt = 0;
    this.counters = {
      checks: 0,
      applied: 0,
      noops: 0,
      skipped: 0,
      rateLimited: 0,
      errors: 0,
      inserted: 0,
      retyped: 0,
      renamed: 0,
      deleted: 0,
      rulesDisabled: 0,
      deferred: 0, // D1: ertelenen degisiklik iceren calisma sayisi
      throttled: 0, // D10: yazma butcesi asildigi icin yazilmayan calisma sayisi
    };
  }

  // -- Gunluk -------------------------------------------------------------------
  _log(level, message) {
    try {
      const fn = this.logger && (this.logger[level] || this.logger.log);
      if (typeof fn === 'function') fn.call(this.logger, `[LAYOUT] ${message}`);
    } catch (_) {
      /* gunluk hatasi esitlemeyi bozmasin */
    }
  }

  /** Hata sayaci + ayni hata turu icin LOG_THROTTLE_MS'te tek uyari satiri. ASLA firlatmaz. */
  _fail(err, homeId, deviceId) {
    this.counters.errors += 1;
    try {
      const kind = errorKind(err);
      const t = this.now();
      const last = this._warnedAt.get(kind);
      if (last !== undefined && t - last < LOG_THROTTLE_MS) return;
      if (this._warnedAt.size >= 50) this._warnedAt.clear();
      this._warnedAt.set(kind, t);
      this._log('warn', `esitleme hatasi cihaz=${shortId(deviceId)} ev=${shortId(homeId)}: ${kind}`);
    } catch (_) {
      /* saat/gunluk hatasi: yalniz sayac */
    }
  }

  // -- Kopru tarafi giris noktasi --------------------------------------------------
  /**
   * Canli (retained OLMAYAN) state islendikten ve COMMIT edildikten sonra kopru cagirir. Senkron ve ucuz: yalniz
   * bellek + kuyruga is atma. ASLA firlatmaz. `layout` = extractReportedLayout sonucu.
   */
  onLiveState(evt) {
    const { topicId, homeId, deviceId, layout } = evt || {};
    try {
      if (this._stopped || !validArgs(homeId, deviceId, layout)) return;
      const t = this.now();
      if (t - this._lastGcAt >= GC_INTERVAL_MS) this._gc(t);

      let entry = this._devices.get(deviceId);
      if (entry) {
        entry.touched = t;
        if (typeof topicId === 'string') entry.topicId = topicId;
        // 2) Onbellek: ayni imza + ayni ev + bekleyen kuculme yok + dogrulama suresi dolmadi -> sorgu YOK
        if (
          entry.sig !== null &&
          entry.sig === layout.signature &&
          entry.homeId === homeId &&
          !entry.pendingShrink &&
          t - entry.checkedAt < RECHECK_MS
        ) {
          return;
        }
      }
      // 3) Hiz siniri (cihaz basina; D10: onbellek kaydi yokken de - invalidate/onOffline sinirlari silmez);
      //    sonraki mesaj yeniden dener
      const limit = this._limits.get(deviceId);
      if (limit) {
        limit.touched = t;
        if (t - limit.lastRunAt < MIN_RUN_INTERVAL_MS) {
          this.counters.rateLimited += 1;
          return;
        }
      }
      if (!entry) {
        entry = this._newEntry(t);
        if (typeof topicId === 'string') entry.topicId = topicId;
        this._devices.set(deviceId, entry);
      }
      this._limitOf(deviceId, t).lastRunAt = t;

      // 4) Ev anahtarli kuyruk (ev basina sirali). Tur cihaza ozgudur: birlestirme yalniz AYNI cihazin bekleyen
      //    isinin yerine gecer (yalniz en yeni yerlesim anlamli), ayni evdeki baska panonun isini silmez.
      const job = { homeId, deviceId, layout };
      const pushed = this._queue.push(String(homeId), `layout|${deviceId}`, () => this._run(job), { coalesce: true });
      if (pushed && typeof pushed.catch === 'function') pushed.catch(() => {});
    } catch (err) {
      this._fail(err, homeId, deviceId);
    }
  }

  /**
   * Test / operator: onbellegi ve hiz sinirini atlayip esitlemeyi kuyrukta (ev basina sirali) calistirir.
   * Kuculme onayini ATLAMAZ. ASLA reddetmez.
   * @returns {Promise<{status:'applied'|'noop'|'skipped'|'error', reason?:string, summary?:object}>}
   */
  syncNow(evt) {
    const { homeId, deviceId, layout } = evt || {};
    try {
      if (this._stopped) return Promise.resolve({ status: 'skipped', reason: 'stopped' });
      if (!validArgs(homeId, deviceId, layout)) return Promise.resolve({ status: 'skipped', reason: 'invalid_args' });
      const job = { homeId, deviceId, layout };
      return Promise.resolve(this._queue.push(String(homeId), `layout-now|${deviceId}`, () => this._run(job))).then(
        (r) => {
          if (r && r.value) return r.value;
          if (r && r.dropped) return { status: 'skipped', reason: 'dropped' };
          return { status: 'error', reason: errorKind(r && r.error) };
        },
        (err) => ({ status: 'error', reason: errorKind(err) })
      );
    } catch (err) {
      this._fail(err, homeId, deviceId);
      return Promise.resolve({ status: 'error', reason: errorKind(err) });
    }
  }

  /**
   * Cihazin IMZA onbellegi kaydini atar: sonraki mesaj (hiz siniri icinde) yeniden kontrol eder. D10: hiz siniri,
   * kuculme onayi ve yazma butcesi ayri haritadadir ve SILINMEZ (kotuye kullanimla sifirlanamaz).
   */
  invalidate(deviceId) {
    this._devices.delete(deviceId);
  }

  /**
   * Canli `status: offline` (LWT): o konunun (evin) cihazlari icin cevrimici donem biter; onbellek kayitlari atilir.
   * Neden: acil sifirlama / pano degisimi satirlari yeniden tohumlar ve cihaz kimligini yeniler (pano atilir ->
   * LWT). Pano yeni kimlikle ayni imzayla donunce "tamam" kaydi RECHECK_MS boyunca tohum sablonunu birakirdi;
   * simdi ilk canli state (hiz siniri icinde) kontrol eder. Bilinmeyen / bos konu zararsizdir. ASLA firlatmaz.
   * D10: yalniz imza onbellegi silinir; hiz siniri / kuculme onayi / butce korunur (sahte "offline" ile atlatilamaz).
   */
  onOffline(topicId) {
    if (this._stopped || typeof topicId !== 'string' || !topicId) return;
    for (const [deviceId, entry] of this._devices) {
      if (entry.topicId === topicId) this._devices.delete(deviceId);
    }
  }

  /** Testler / operator: kuyruktaki isler bitene kadar bekler. */
  whenIdle(timeoutMs = 5000) {
    return this._queue.drain(timeoutMs);
  }

  /** Kopru kapanisi: baslamamis isler atilir, sonraki cagrilar yok sayilir. */
  stop() {
    this._stopped = true;
    this._devices.clear();
    this._limits.clear();
    try {
      this._queue.clear();
    } catch (_) {
      /* kapanis: yut */
    }
  }

  stats() {
    return { devices: this._devices.size, ...this.counters, queue: { ...this._queue.stats, pending: this._queue.pending } };
  }

  // -- Bellek -------------------------------------------------------------------
  _newEntry(t) {
    return { sig: null, homeId: null, topicId: null, checkedAt: 0, pendingShrink: false, touched: t };
  }

  /** D10: cihazin sinir kaydi (yoksa acilir). */
  _limitOf(deviceId, t) {
    let limit = this._limits.get(deviceId);
    if (!limit) {
      limit = { lastRunAt: -Infinity, shrink: null, windowStart: t, applies: 0, warned: false, touched: t };
      this._limits.set(deviceId, limit);
    }
    limit.touched = t;
    return limit;
  }

  /** D10: saatlik pencere dolduysa sayaci sifirlar. */
  _rollBudget(limit, t) {
    if (t - limit.windowStart >= BUDGET_WINDOW_MS) {
      limit.windowStart = t;
      limit.applies = 0;
      limit.warned = false;
    }
  }

  /** D10: yazma butcesi asildi: sayac + cihaz basina saatte tek uyari; hicbir sey yazilmaz, onbellek "tamam" olmaz. */
  _throttle(deviceId, homeId, entry, limit, t) {
    this.counters.throttled += 1;
    entry.sig = null;
    entry.checkedAt = t;
    if (!limit.warned) {
      limit.warned = true;
      this._log(
        'warn',
        `yazma butcesi doldu cihaz=${shortId(deviceId)} ev=${shortId(homeId)}: saatte en cok ${APPLY_BUDGET_PER_HOUR} calisma`
      );
    }
    return { status: 'skipped', reason: 'throttled' };
  }

  _gc(t) {
    this._lastGcAt = t;
    for (const [deviceId, entry] of this._devices) {
      if (t - entry.touched >= CACHE_IDLE_MS) this._devices.delete(deviceId);
    }
    for (const [deviceId, limit] of this._limits) {
      if (t - limit.touched >= CACHE_IDLE_MS) this._limits.delete(deviceId);
    }
    for (const [kind, at] of this._warnedAt) {
      if (t - at >= LOG_THROTTLE_MS) this._warnedAt.delete(kind);
    }
  }

  _skip(deviceId, entry, reason) {
    if (this._devices.get(deviceId) === entry) this._devices.delete(deviceId);
    this.counters.skipped += 1;
    return { status: 'skipped', reason };
  }

  // -- Calisma (ev basina sirali; ASLA reddetmez) -------------------------------------
  async _run({ homeId, deviceId, layout }) {
    if (this._stopped) return { status: 'skipped', reason: 'stopped' };
    this.counters.checks += 1;
    try {
      const t = this.now();
      let entry = this._devices.get(deviceId);
      if (!entry) {
        entry = this._newEntry(t);
        this._devices.set(deviceId, entry);
      }
      const limit = this._limitOf(deviceId, t);
      limit.lastRunAt = t;

      // 5) Kilitsiz on okuma
      const dres = await this.db.query(SQL.device, [deviceId]);
      const dev = dres && dres.rows && dres.rows[0];
      const mismatch = deviceMismatch(dev, homeId);
      if (mismatch) return this._skip(deviceId, entry, mismatch);
      const rres = await this.db.query(SQL.rows, [deviceId]);
      const rows = (rres && rres.rows) || [];

      // 8) Kuculme onayi: ayni sayi en az SHRINK_CONFIRM_MS once de kuculme olarak gorulmus olmali
      const confirmShrink =
        limit.shrink !== null && limit.shrink.count === layout.count && t - limit.shrink.since >= SHRINK_CONFIRM_MS;

      let plan = planFor(dev, rows, layout, confirmShrink);
      let wrote = false;
      let ruleIds = [];
      let actuatorChanges = [];
      if (plan.changed || plan.baseChanged) {
        // 6b) D10 yazma butcesi: satir degistiren calisma cihaz basina saatte en cok APPLY_BUDGET_PER_HOUR
        this._rollBudget(limit, t);
        if (plan.changed && limit.applies >= APPLY_BUDGET_PER_HOUR) return this._throttle(deviceId, homeId, entry, limit, t);
        // 7) Yazilacak bir sey var: karar KILITLI veriyle yeniden verilir
        const out = await this.db.withTransaction((tx) => this._apply(tx, { homeId, deviceId, layout, confirmShrink }));
        if (out.mismatch) return this._skip(deviceId, entry, out.mismatch);
        plan = out.plan;
        wrote = out.wrote;
        ruleIds = out.ruleIds;
        actuatorChanges = out.actuators || [];
        if (wrote && plan.changed) limit.applies += 1;
      }
      // Buradan sonrasi yalniz COMMIT edilmis (ya da hic yazmamis) calisma icindir.

      if (plan.pendingShrink) {
        if (limit.shrink === null || limit.shrink.count !== layout.count) limit.shrink = { count: layout.count, since: t };
      } else {
        limit.shrink = null; // bildirilen sayi satirlari kapsiyor (ya da fazlalar simdi silindi)
      }

      // D1: ertelenen degisiklik varsa (gecici pano) "tamam" yazilmaz: sonraki mesajlar hiz siniri icinde yeniden
      // degerlendirilir (pano yapilandirilinca ya da cihaz devreye alininca normal kurallar uygulanir).
      const deferred = deferredOf(plan);
      if (deferred > 0) this.counters.deferred += 1;

      // Onbellek "tamam" kaydi: yalniz basarili + bekleyen kuculmesi ve ertelenen degisikligi olmayan calisma. Kayit
      // calisma BASINDA alinan nesneye yazilir: calisma sirasinda invalidate/stop/GC edildiyse o nesne artik haritada
      // degildir, yani bayat sonuc onbellege girmez (sonraki mesaj yeniden kontrol eder).
      entry.homeId = homeId;
      entry.pendingShrink = plan.pendingShrink;
      entry.sig = !plan.pendingShrink && deferred === 0 && typeof layout.signature === 'string' ? layout.signature : null;
      entry.checkedAt = t;

      const s = plan.summary;
      const summary = {
        relays: layout.count,
        inserted: s.inserted,
        retyped: s.retyped,
        renamed: s.renamed,
        reroomed: s.reroomed,
        deleted: s.deleted,
        rulesDisabled: ruleIds.length,
        baseSaved: wrote && plan.baseChanged,
        pendingShrink: plan.pendingShrink,
      };
      if (deferred > 0) summary.deferred = deferred;
      if (actuatorChanges.length > 0) summary.actuators = actuatorChanges.length;
      if (!wrote) {
        this.counters.noops += 1;
        return { status: 'noop', summary };
      }
      this.counters.applied += 1;
      this.counters.inserted += s.inserted;
      this.counters.retyped += s.retyped;
      this.counters.renamed += s.renamed;
      this.counters.deleted += s.deleted;
      this.counters.rulesDisabled += ruleIds.length;
      if (plan.changed) {
        this._log(
          'log',
          `cihaz=${shortId(deviceId)} ev=${shortId(homeId)} eklendi=${s.inserted} tip=${s.retyped} ad=${s.renamed} ` +
            `oda=${s.reroomed} silindi=${s.deleted} kural=${ruleIds.length}` +
            (deferred > 0 ? ` ertelendi=${deferred}` : '')
        );
      }
      return { status: 'applied', summary };
    } catch (err) {
      // 9) Onbellek guncellenmez: sonraki mesaj yeniden dener (hiz siniri gecerli)
      this._fail(err, homeId, deviceId);
      return { status: 'error', reason: errorKind(err) };
    }
  }

  /**
   * Transaction govdesi. Kilit sirasi: devices -> endpoints. Plan kilitli veriyle yeniden hesaplanir.
   * Yazma sirasi: deleteAbove -> updateRow (kanal sirasi) -> insertRow (kanal sirasi) -> disableRules -> saveBase -> audit.
   */
  async _apply(tx, { homeId, deviceId, layout, confirmShrink }) {
    const dres = await tx.query(SQL.deviceLocked, [deviceId]);
    const dev = dres && dres.rows && dres.rows[0];
    const mismatch = deviceMismatch(dev, homeId);
    if (mismatch) return { mismatch }; // cihaz silinmis / baska eve tasinmis: hicbir sey yazma

    const rres = await tx.query(SQL.rowsLocked, [deviceId]);
    const rows = (rres && rres.rows) || [];
    const plan = planFor(dev, rows, layout, confirmShrink); // gecici mod da KILITLI cihaz satirina gore
    if (!plan.changed && !plan.baseChanged) return { plan, wrote: false, ruleIds: [] };

    if (plan.deleteAbove !== null) await tx.query(SQL.deleteAbove, [deviceId, plan.deleteAbove]);

    const rowById = new Map(rows.map((row) => [row.id, row]));
    for (const u of [...plan.updates].sort(byChannel)) {
      const v = { ...rowById.get(u.id), ...u.set }; // mevcut degerler + degisenler = TAM degerler
      await tx.query(SQL.updateRow, [
        u.id,
        deviceId,
        v.name,
        v.type,
        v.room,
        nullIfMissing(v.shutter_pair_index),
        nullIfMissing(v.shutter_duration_sec),
        Number.isInteger(u.set.current_position) ? u.set.current_position : null,
      ]);
    }

    for (const ins of [...plan.inserts].sort(byChannel)) {
      await tx.query(SQL.insertRow, [
        homeId,
        deviceId,
        ins.channel_index,
        ins.name,
        ins.type,
        ins.room,
        ins.shutter_pair_index,
        ins.shutter_duration_sec,
        ins.current_state,
        ins.current_position,
      ]);
    }

    // WP-S2 [Y2][O6]: eylemci rolu (act) -> endpoints.actuator_type. Yalniz bildirimde ya da tabanda eylemci varsa
    // calisir (v:2 yolu sorgu sayisi ve sirasi AYNEN). Yeni eylemci kanallarinin role kurallari kapatilir: "lambayi ac"
    // kurali vanayi acmasin (sunucu tarafinda ayrica scheduler _checkTarget reddeder).
    const actuators = [];
    let relayRuleChannels = plan.ruleRelayChannels;
    if (hasActuators(layout) || hasActuators(parseBase(dev.reported_layout))) {
      const vec = actuatorVector(layout);
      const ar = await tx.query(SQL.syncActuators, [deviceId, vec.channels, vec.acts]);
      for (const row of (ar && ar.rows) || []) {
        actuators.push({ channel: Number(row.channel_index), actuator_type: row.actuator_type || null });
      }
      actuators.sort((a, b) => a.channel - b.channel);
      const added = actuators.filter((a) => a.actuator_type).map((a) => a.channel);
      if (added.length > 0) relayRuleChannels = [...new Set([...relayRuleChannels, ...added])].sort((a, b) => a - b);
    }

    let ruleIds = [];
    if (relayRuleChannels.length > 0 || plan.ruleShutterPairs.length > 0) {
      const r = await tx.query(SQL.disableRules, [homeId, deviceId, relayRuleChannels, plan.ruleShutterPairs]);
      ruleIds = ((r && r.rows) || []).map((row) => row.id);
    }

    if (plan.baseChanged) await tx.query(SQL.saveBase, [deviceId, JSON.stringify(plan.newBase)]);

    if (plan.changed || actuators.length > 0) {
      const s = plan.summary;
      const details = {
        relays: layout.count,
        inserted: s.inserted,
        retyped: s.retyped,
        renamed: s.renamed,
        reroomed: s.reroomed,
        deleted: s.deleted,
        rules_disabled: ruleIds,
      };
      if (deferredOf(plan) > 0) details.deferred = plan.deferred; // D1: ertelenen degisiklik sayisi
      if (actuators.length > 0) details.actuators = actuators; // WP-S2: eylemci rolu degisen kanallar
      await tx.query(SQL.audit, [AUDIT_EVENT, dev.device_uuid, homeId, JSON.stringify(details)]);
    }
    return { plan, wrote: true, ruleIds, actuators };
  }
}

function createEndpointLayoutSync(deps) {
  return new EndpointLayoutSync(deps);
}

module.exports = {
  createEndpointLayoutSync,
  EndpointLayoutSync,
  SQL,
  constants: Object.freeze({
    RECHECK_MS,
    MIN_RUN_INTERVAL_MS,
    SHRINK_CONFIRM_MS,
    CACHE_IDLE_MS,
    GC_INTERVAL_MS,
    MAX_CONCURRENT_HOMES,
    MAX_PENDING,
    AUDIT_EVENT,
    LOG_THROTTLE_MS,
    APPLY_BUDGET_PER_HOUR,
  }),
};
