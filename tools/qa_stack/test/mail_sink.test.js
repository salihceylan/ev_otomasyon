// Yerel SMTP cukuru: dis dunyaya e-posta cikmaz; govde loga yazilmaz; STARTTLS + sunucunun nodemailer ayari.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { ensureMailTls, startMailSink } from '../lib/mail_sink.js';
import { createLogger, sleep, waitFor } from '../lib/util.js';
import { SERVER_DIR } from '../lib/paths.js';
import { tmpDir } from './_helpers.js';

const CRLF = '\r\n';

/** Her sunucu yanitinin son satirindan (NNN <bosluk>) sonra siradaki istemci satirini gonderir. */
function smtpSession(port, lines) {
  return new Promise((resolve, reject) => {
    const s = net.createConnection({ host: '127.0.0.1', port });
    let buf = '';
    let transcript = '';
    let i = 0;
    s.setEncoding('utf8');
    s.on('data', (d) => {
      transcript += d;
      buf += d;
      let idx = buf.indexOf(CRLF);
      while (idx !== -1) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        if (/^\d{3} /.test(line) && i < lines.length) {
          const next = lines[i++];
          transcript += `>> ${next}${CRLF}`;
          s.write(`${next}${CRLF}`);
        }
        idx = buf.indexOf(CRLF);
      }
    });
    s.on('error', reject);
    s.on('close', () => resolve(transcript));
  });
}

test('SMTP cukuru: mesaj .eml olarak saklanir; log yalnizca kime/konu/boyut; govde (OTP) loga YAZILMAZ', async () => {
  const dir = tmpDir('qa_mail_');
  const logFile = path.join(dir, 'mail.log');
  const sink = await startMailSink({ dir: path.join(dir, 'mail'), port: 0, log: createLogger(logFile) });
  try {
    const subject = `=?UTF-8?B?${Buffer.from('Dogrulama kodunuz').toString('base64')}?=`;
    const message = [`Subject: ${subject}`, 'To: musteri@example.com', '', 'Kodunuz: 482913', '..nokta ile baslayan satir', '.'].join(CRLF);
    const out = await smtpSession(sink.port, ['EHLO test', 'MAIL FROM:<qa@qa.local>', 'RCPT TO:<musteri@example.com>', 'DATA', message, 'QUIT']);
    assert.match(out, /250 OK: message queued/);
    assert.match(out, /221/);
    assert.ok(!/STARTTLS/.test(out), 'TLS verilmediyse STARTTLS ilan edilmez');
    await waitFor(() => sink.list().length === 1, { timeoutMs: 2000 });
    const eml = fs.readFileSync(path.join(dir, 'mail', sink.list()[0]), 'utf8');
    assert.match(eml, /Kodunuz: 482913/);
    assert.match(eml, /^\.nokta ile baslayan satir/m, 'dot-stuffing geri alinir');
    await sleep(50);
    const log = fs.readFileSync(logFile, 'utf8');
    assert.match(log, /mail_received .*to=musteri@example\.com/);
    assert.match(log, /subject="Dogrulama kodunuz"/);
    assert.ok(!log.includes('482913'), 'OTP loga yazilmamali');
  } finally {
    await sink.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('SMTP cukuru: TLS sertifikasi bir kez uretilir (SAN 127.0.0.1/localhost) ve yeniden kullanilir', async () => {
  const dir = tmpDir('qa_mailtls_');
  try {
    const a = await ensureMailTls(dir);
    const b = await ensureMailTls(dir);
    assert.equal(a.cert, b.cert, 'ikinci cagri ayni sertifikayi dondurur');
    const { X509Certificate } = await import('node:crypto');
    const x = new X509Certificate(a.cert);
    assert.match(x.subjectAltName, /IP Address:127\.0\.0\.1/);
    assert.match(x.subjectAltName, /DNS:localhost/);
    assert.ok(new Date(x.validTo) > new Date(Date.now() + 365 * 24 * 3600 * 1000), 'en az 1 yil gecerli');
    assert.equal(x.verify(x.publicKey), true, 'kendinden imzali');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

/** Sunucunun mailer.js'indeki nodemailer ayarlariyla (requireTLS, minVersion TLSv1.2, 'ca' YOK) gonderir.
 *  Alt surec ASENKRON calistirilir: cukur bu (ust) surecte oldugu icin spawnSync olay dongusunu kilitler. */
function sendLikeServer({ port, caFile, text }) {
  const script = `
    const { createRequire } = require('node:module');
    const nodemailer = createRequire(${JSON.stringify(path.join(SERVER_DIR, 'package.json'))})('nodemailer');
    const t = nodemailer.createTransport({ host: '127.0.0.1', port: ${port}, secure: false, requireTLS: true,
      auth: { user: 'qa', pass: 'qa-pass' }, tls: { minVersion: 'TLSv1.2' } });
    t.sendMail({ from: 'AHBU QA <qa@qa.local>', to: 'owner@qa.local', subject: 'Davet', text: ${JSON.stringify(text)} })
      .then((i) => { console.log('SENT ' + i.response); }, (e) => { console.log('FAIL ' + (e.code || e.message)); });
  `;
  const env = { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot, ...(caFile ? { NODE_EXTRA_CA_CERTS: caFile } : {}) };
  return new Promise((resolve) => {
    const child = spawn(process.execPath, ['-e', script], { env, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    const timer = setTimeout(() => { child.kill(); resolve(`TIMEOUT ${out}`); }, 30000);
    child.on('exit', () => { clearTimeout(timer); resolve(out.trim()); });
  });
}

test('SMTP cukuru + STARTTLS: sunucunun nodemailer ayariyla (requireTLS, dogrulama ACIK) NODE_EXTRA_CA_CERTS ile gonderilir; guvenmeyen surec reddeder', async (t) => {
  try {
    createRequire(path.join(SERVER_DIR, 'package.json'))('nodemailer');
  } catch (_) {
    t.skip('server/node_modules/nodemailer yok');
    return;
  }
  const dir = tmpDir('qa_mail_');
  const tls = await ensureMailTls(path.join(dir, 'tls'));
  const sink = await startMailSink({ dir: path.join(dir, 'mail'), port: 0, log: createLogger(null), tls });
  try {
    const ok = await sendLikeServer({ port: sink.port, caFile: sink.caFile, text: 'Davet kodu: ABC123XYZ9' });
    assert.match(ok, /^SENT 250/, ok);
    await waitFor(() => sink.list().length === 1, { timeoutMs: 3000 });
    const eml = fs.readFileSync(path.join(dir, 'mail', sink.list()[0]), 'utf8');
    assert.match(eml, /ABC123XYZ9/);
    assert.match(eml, /^To: owner@qa\.local/m);

    // sertifikaya guvenmeyen surec (NODE_EXTRA_CA_CERTS yok) gonderemez: TLS dogrulamasi kapatilmamistir
    const bad = await sendLikeServer({ port: sink.port, caFile: null, text: 'gitmemeli' });
    assert.match(bad, /^FAIL /, bad);
    assert.equal(sink.list().length, 1);
  } finally {
    await sink.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
