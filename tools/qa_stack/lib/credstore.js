// MQTT kimlik/ACL deposu arayuzu. Iki gerceklestirme:
//  - PgCredentialStore: gercek PostgreSQL'deki mqtt_credentials / mqtt_acl tablolari (CONTRACTS §2.2)
//  - MemoryCredentialStore: testler icin bellek ici sahte depo (ayni arayuz)
//
// Arayuz:
//   await store.findCredential(username) -> satir | null   (StoreUnavailableError firlatabilir)
//   await store.listAcl(username)        -> [{permission, action, topic}]
//   await store.isReady()                -> boolean         (tablolar var mi, DB erisilebilir mi)
//   await store.close()
import pg from 'pg';

export class StoreUnavailableError extends Error {
  constructor(reason, cause) {
    super(`kimlik deposu kullanilamiyor: ${reason}`);
    this.name = 'StoreUnavailableError';
    this.reason = reason;
    this.cause = cause;
  }
}

const SCHEMA_RE = /^[a-z_][a-z0-9_]*$/;

function classifyPgError(err) {
  const code = err && err.code;
  if (code === '42P01' || code === '3F000') return new StoreUnavailableError('tables_missing', err);
  if (code === '28P01' || code === '28000') return new StoreUnavailableError('db_auth_failed', err);
  if (code === 'ECONNREFUSED' || code === 'ECONNRESET' || code === 'ETIMEDOUT' || code === '57P01' || code === '57P03'
    || (typeof code === 'string' && code.startsWith('08'))) {
    return new StoreUnavailableError('db_unreachable', err);
  }
  if (err && /Connection terminated|timeout|ECONNREFUSED/i.test(String(err.message))) {
    return new StoreUnavailableError('db_unreachable', err);
  }
  return err;
}

export class PgCredentialStore {
  /**
   * @param {{connectionString:string, schema?:string, max?:number}} opts
   */
  constructor({ connectionString, schema, max = 3 }) {
    if (schema !== undefined && !SCHEMA_RE.test(schema)) throw new Error('gecersiz sema adi');
    this.schema = schema || null;
    this.pool = new pg.Pool({
      connectionString,
      max,
      idleTimeoutMillis: 10000,
      connectionTimeoutMillis: 3000,
      statement_timeout: 5000,
      ...(schema ? { options: `-c search_path=${schema}` } : {}),
    });
    // bosta duran istemci hatalari (DB yeniden baslatilirsa) sureci dusurmesin
    this.pool.on('error', () => {});
  }

  async #query(text, params) {
    try {
      return await this.pool.query(text, params);
    } catch (err) {
      throw classifyPgError(err);
    }
  }

  async findCredential(username) {
    const r = await this.#query('SELECT * FROM mqtt_credentials WHERE username = $1 LIMIT 1', [username]);
    return r.rows[0] || null;
  }

  async listAcl(username) {
    const r = await this.#query('SELECT permission, action, topic FROM mqtt_acl WHERE username = $1', [username]);
    return r.rows;
  }

  async isReady() {
    try {
      const r = await this.pool.query(
        "SELECT to_regclass('mqtt_credentials') IS NOT NULL AS c, to_regclass('mqtt_acl') IS NOT NULL AS a",
      );
      return r.rows[0].c === true && r.rows[0].a === true;
    } catch (_) {
      return false;
    }
  }

  async close() {
    try { await this.pool.end(); } catch (_) { /* yok say */ }
  }
}

export class MemoryCredentialStore {
  constructor() {
    this.creds = new Map();
    this.acl = [];
    this.available = true;
    this.unavailableReason = 'tables_missing';
    this.queries = 0;
  }

  /** @param {{username:string, password_hash:string, kind?:string, home_id?:string, user_id?:string, device_id?:string, expires_at?:Date|string|null}} row */
  addCredential(row) {
    this.creds.set(row.username, { kind: 'app', home_id: null, user_id: null, device_id: null, expires_at: null, ...row });
    return this;
  }

  removeCredential(username) {
    this.creds.delete(username);
    return this;
  }

  /** @param {{username:string, permission:'allow'|'deny', action:'publish'|'subscribe'|'all', topic:string}} row */
  addAcl(row) {
    this.acl.push({ ...row });
    return this;
  }

  clearAcl(username) {
    this.acl = this.acl.filter((r) => r.username !== username);
    return this;
  }

  setAvailable(flag, reason = 'tables_missing') {
    this.available = !!flag;
    this.unavailableReason = reason;
  }

  #guard() {
    this.queries++;
    if (!this.available) throw new StoreUnavailableError(this.unavailableReason);
  }

  async findCredential(username) {
    this.#guard();
    return this.creds.get(username) || null;
  }

  async listAcl(username) {
    this.#guard();
    return this.acl.filter((r) => r.username === username).map(({ permission, action, topic }) => ({ permission, action, topic }));
  }

  async isReady() {
    return this.available;
  }

  async close() { /* yok */ }
}
