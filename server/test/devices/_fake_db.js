'use strict';

// ==============================================================================
// Test altyapisi: bellek ici sahte veritabani cekirdegi (gercek PostgreSQL YOK).
//
// Ozellikler (servis davranisini gercekci sinamak icin):
//   * query(text, params)            : sorgu gunlugu + sorgu metnine gore (alt dize / RegExp / fonksiyon) isleyici
//   * withTransaction(fn)            : tek "baglanti"; hata firlatilirsa GERI ALMA GUNLUGU (undo) geri sarilir (ROLLBACK),
//                                      basariliysa COMMIT. Callback'in DONDURDUGU deger commit edilir
//                                      (commit-then-throw deseninin dogrulanmasi icin kritik).
//   * ctx.lock(key)                  : "FOR UPDATE" / advisory kilit taklidi; ayni anahtara ikinci islem, ilk islem
//                                      COMMIT/ROLLBACK olana kadar BEKLER (gercek satir kilidi gibi).
//   * ctx.undo(fn)                   : islem geri alinirsa calisacak ters islem
//   * eslesen isleyici yoksa HATA     : beklenmeyen sorgular sessizce gecmez (testi kirar)
// ==============================================================================

function norm(sql) {
  return String(sql).replace(/\s+/g, ' ').trim();
}

const tick = () => new Promise((resolve) => setImmediate(resolve));

class FakeDb {
  constructor() {
    this.handlers = [];
    this.log = []; // { sql, params, tx }
    this.txSeq = 0;
    this.commits = 0;
    this.rollbacks = 0;
    this.lockOwners = new Map();
    this.lockQueues = new Map();
    this.openTx = 0;
  }

  /** matcher: alt dize (sql.includes), RegExp veya (sql)=>bool. Ilk eslesen kazanir. */
  on(matcher, fn) {
    this.handlers.push({ matcher, fn });
    return this;
  }

  query(text, params = []) {
    return this._exec(null, text, params);
  }

  async withTransaction(fn) {
    const tx = { id: ++this.txSeq, undo: [], locks: new Set() };
    this.openTx += 1;
    const api = { query: (text, params = []) => this._exec(tx, text, params) };
    try {
      const result = await fn(api);
      this.commits += 1;
      this._release(tx);
      return result;
    } catch (err) {
      for (let i = tx.undo.length - 1; i >= 0; i--) tx.undo[i]();
      this.rollbacks += 1;
      this._release(tx);
      throw err;
    } finally {
      this.openTx -= 1;
    }
  }

  async _exec(tx, text, params) {
    const sql = norm(text);
    this.log.push({ sql, params: Array.isArray(params) ? params.slice() : params, tx: tx ? tx.id : null });
    for (const h of this.handlers) {
      const m = h.matcher;
      const hit =
        typeof m === 'string' ? sql.includes(m) : m instanceof RegExp ? m.test(sql) : typeof m === 'function' ? m(sql) : false;
      if (!hit) continue;
      const ctx = {
        sql,
        params,
        tx,
        db: this,
        lock: (key) => this._lock(tx, key),
        undo: (undoFn) => {
          if (tx) tx.undo.push(undoFn);
        },
      };
      const out = await h.fn(ctx);
      if (out === undefined || out === null) return { rows: [], rowCount: 0 };
      if (Array.isArray(out)) return { rows: out, rowCount: out.length };
      const rows = out.rows || [];
      return { rows, rowCount: out.rowCount !== undefined ? out.rowCount : rows.length };
    }
    throw new Error(`FakeDb: eslesen isleyici yok -> ${sql.slice(0, 200)}`);
  }

  async _lock(tx, key) {
    if (!tx) return;
    const owner = this.lockOwners.get(key);
    if (owner === undefined || owner === tx.id) {
      this.lockOwners.set(key, tx.id);
      tx.locks.add(key);
      return;
    }
    await new Promise((resolve) => {
      const queue = this.lockQueues.get(key) || [];
      queue.push({ tx, resolve });
      this.lockQueues.set(key, queue);
    });
  }

  _release(tx) {
    for (const key of tx.locks) {
      const queue = this.lockQueues.get(key) || [];
      const next = queue.shift();
      if (next) {
        this.lockOwners.set(key, next.tx.id);
        next.tx.locks.add(key);
        next.resolve();
      } else {
        this.lockOwners.delete(key);
      }
    }
    tx.locks.clear();
  }

  // --- sorgu gunlugu yardimcilari ---
  sqls() {
    return this.log.map((l) => l.sql);
  }
  find(fragment) {
    return this.log.filter((l) => l.sql.includes(fragment));
  }
  count(fragment) {
    return this.find(fragment).length;
  }
  /** Tum sorgular bir transaction icindeydi mi (db.query ile havuza dusen yok mu)? */
  nonTxQueries(filterFragment) {
    return this.log.filter((l) => l.tx === null && (!filterFragment || l.sql.includes(filterFragment)));
  }
}

module.exports = { FakeDb, norm, tick };
