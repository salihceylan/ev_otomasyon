// Ortak yardimcilar: bekleme, rastgele sir uretimi, atomik JSON, log, surec yonetimi, HTTP/TCP yoklama.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { execFileSync, spawnSync } from 'node:child_process';

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * kosul() truthy donene kadar yoklar. Zaman asiminda aciklayici hata firlatir.
 */
export async function waitFor(fn, { timeoutMs = 10000, intervalMs = 50, label = 'kosul' } = {}) {
  const start = Date.now();
  let lastErr = null;
  for (;;) {
    try {
      const v = await fn();
      if (v) return v;
    } catch (e) {
      if (e && e.fatal) throw e;   // beklemeyi hemen kes
      lastErr = e;
    }
    if (Date.now() - start > timeoutMs) {
      throw new Error(`${label}: ${timeoutMs} ms icinde gerceklesmedi${lastErr ? ` (son hata: ${lastErr.message})` : ''}`);
    }
    await sleep(intervalMs);
  }
}

// ---------------------------------------------------------------- rastgelelik (yalnizca crypto)
export const randomHex = (bytes = 16) => crypto.randomBytes(bytes).toString('hex');
export const randomB64Url = (bytes = 24) => crypto.randomBytes(bytes).toString('base64url');

const ALNUM = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
export function randomToken(len = 16, alphabet = ALNUM) {
  let out = '';
  for (let i = 0; i < len; i++) out += alphabet[crypto.randomInt(0, alphabet.length)];
  return out;
}
export const randomPin6 = () => String(crypto.randomInt(0, 1000000)).padStart(6, '0');
/** Uygulama parola politikasini (>= 10 karakter, harf+rakam+sembol) saglayan rastgele parola. */
export function randomPassword() {
  return `${randomToken(10)}${crypto.randomInt(10, 99)}!${randomToken(4)}`;
}

// ---------------------------------------------------------------- dosya
export function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

export function readJson(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return fallback;
  }
}

/** Atomik JSON yazimi (gecici dosya + rename). Windows'ta rename kisa sureli kilitlenebilir: yeniden dener. */
export function writeJsonAtomic(file, obj, { mode = 0o600 } = {}) {
  ensureDir(path.dirname(file));
  const tmp = `${file}.${process.pid}.${randomHex(4)}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(obj, null, 2)}\n`, { mode });
  let lastErr;
  for (let i = 0; i < 8; i++) {
    try {
      fs.renameSync(tmp, file);
      return;
    } catch (e) {
      lastErr = e;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25 * (i + 1));
    }
  }
  try { fs.unlinkSync(tmp); } catch (_) { /* yok say */ }
  throw lastErr;
}

export function rmrf(target) {
  fs.rmSync(target, { recursive: true, force: true, maxRetries: 10, retryDelay: 150 });
}

/** Cok buyuyen log dosyasini bir kez .old'a cevirir. */
export function rotateIfBig(file, maxBytes = 5 * 1024 * 1024) {
  try {
    const st = fs.statSync(file);
    if (st.size > maxBytes) {
      fs.renameSync(file, `${file}.old`);
    }
  } catch (_) { /* dosya yok */ }
}

// ---------------------------------------------------------------- log
const redactKeys = /(pass(word)?|pwd|secret|token|key|otp|pin|authorization)/i;

function fmtValue(v) {
  if (v === undefined || v === null) return '-';
  const s = typeof v === 'string' ? v : (typeof v === 'object' ? JSON.stringify(v) : String(v));
  const clean = s.replace(/[\r\n\t]+/g, ' ');
  return /[\s="]/.test(clean) ? JSON.stringify(clean.length > 300 ? `${clean.slice(0, 300)}...` : clean) : clean;
}

/**
 * Satir tabanli, anahtar=deger bicimli dosya logu. Parola/anahtar benzeri alan adlari
 * otomatik maskelenir (savunma amacli; cagiranlar zaten sir yazmamalidir).
 */
export function createLogger(file, { echo = false, maxLines = 2000 } = {}) {
  if (file) ensureDir(path.dirname(file));
  const lines = [];
  const listeners = new Set();
  function log(event, fields = {}) {
    const parts = [new Date().toISOString(), event];
    for (const [k, v] of Object.entries(fields)) {
      parts.push(`${k}=${redactKeys.test(k) ? '***' : fmtValue(v)}`);
    }
    const line = parts.join(' ');
    lines.push(line);
    if (lines.length > maxLines) lines.splice(0, lines.length - maxLines);
    if (file) {
      try { fs.appendFileSync(file, `${line}\n`); } catch (_) { /* log hatasi sistemi durdurmaz */ }
    }
    if (echo) console.log(line);
    for (const l of listeners) {
      try { l(event, fields, line); } catch (_) { /* yok say */ }
    }
    return line;
  }
  log.lines = lines;
  log.on = (fn) => { listeners.add(fn); return () => listeners.delete(fn); };
  return log;
}

// ---------------------------------------------------------------- surec yonetimi
export function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

/** Surec agacini sonlandirir (Windows: taskkill /T /F). */
export function killTree(pid) {
  if (!pidAlive(pid)) return false;
  if (process.platform === 'win32') {
    spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
  } else {
    try { process.kill(-pid, 'SIGKILL'); } catch (_) {
      try { process.kill(pid, 'SIGKILL'); } catch (_e) { /* yok say */ }
    }
  }
  return true;
}

export async function waitForExit(pid, timeoutMs = 15000) {
  const start = Date.now();
  while (pidAlive(pid)) {
    if (Date.now() - start > timeoutMs) return false;
    await sleep(100);
  }
  return true;
}

/** Windows'ta bir imaj adina sahip surecin PID'ini komut satirinda gecen bir parcaya gore bulur. */
export function findPidsByCommandLine(imageName, needle) {
  if (process.platform !== 'win32') return [];
  try {
    const out = execFileSync(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-Command',
        `Get-CimInstance Win32_Process -Filter "Name='${imageName}'" | Where-Object { $_.CommandLine -like '*${needle.replace(/'/g, "''")}*' } | Select-Object -ExpandProperty ProcessId`],
      { encoding: 'utf8', windowsHide: true, timeout: 20000 },
    );
    return out.split(/\r?\n/).map((s) => Number.parseInt(s.trim(), 10)).filter((n) => Number.isInteger(n));
  } catch (_) {
    return [];
  }
}

// ---------------------------------------------------------------- ag yoklama
export function tcpProbe(host, port, timeoutMs = 1500) {
  return new Promise((resolve) => {
    const s = net.createConnection({ host, port });
    const done = (ok) => { s.destroy(); resolve(ok); };
    s.setTimeout(timeoutMs, () => done(false));
    s.once('connect', () => done(true));
    s.once('error', () => done(false));
  });
}

/** Bos bir TCP portu bulur (test/gecici kullanim). */
export function freePort(host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, host, () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

/** JSON dondurmeyi bekleyen kucuk fetch sarmalayici (zaman asimli). */
export async function fetchJson(url, { method = 'GET', headers = {}, body, timeoutMs = 8000 } = {}) {
  const init = { method, headers: { ...headers }, signal: AbortSignal.timeout(timeoutMs) };
  if (body !== undefined) {
    init.body = typeof body === 'string' ? body : JSON.stringify(body);
    if (!init.headers['Content-Type'] && !init.headers['content-type']) init.headers['Content-Type'] = 'application/json';
  }
  const res = await fetch(url, init);
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch (_) { /* JSON degil */ }
  return { status: res.status, ok: res.ok, headers: res.headers, json, text };
}

export function formatDuration(ms) {
  const s = Math.round(ms / 1000);
  if (s < 90) return `${s} sn`;
  return `${Math.floor(s / 60)} dk ${s % 60} sn`;
}

/** Sabit zamanli dize esitligi (uzunluk sizdirmaz: iki tarafin SHA-256 ozeti karsilastirilir). */
export function safeEqual(a, b) {
  const ha = crypto.createHash('sha256').update(String(a ?? ''), 'utf8').digest();
  const hb = crypto.createHash('sha256').update(String(b ?? ''), 'utf8').digest();
  return crypto.timingSafeEqual(ha, hb);
}
