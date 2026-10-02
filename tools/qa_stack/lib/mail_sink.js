// Yerel SMTP "cukuru" (QA): sunucunun mailer'i (nodemailer) gercek SMTP hesabi yerine buraya gonderir; hicbir e-posta
// disari cikmaz. Mesajlar .runtime/mail/*.eml olarak saklanir (OTP/davet/sifirlama kodlarini QA'da okumak icin).
// Log (mail.log) YALNIZCA kime/konu/boyut yazar; govde (OTP) loga YAZILMAZ.
//
// Sunucunun mailer'i 465 disi portlarda STARTTLS'i ZORUNLU kilar (requireTLS) ve TLS dogrulamasini kapatmaz; bu yuzden
// cukur STARTTLS destekler ve kendinden imzali (127.0.0.1/localhost SAN) bir sertifika kullanir. Sunucu alt sureci
// NODE_EXTRA_CA_CERTS=<cert> ile bu sertifikaya guvenir (yalniz o surec; sistem deposuna dokunulmaz).
import fs from 'node:fs';
import path from 'node:path';
import selfsigned from 'selfsigned';
import smtp from 'smtp-server';
import { createLogger, ensureDir } from './util.js';

const { SMTPServer } = smtp;

function decodeHeader(v) {
  return String(v || '').replace(/=\?utf-8\?([bq])\?([^?]*)\?=/gi, (_, enc, text) => {
    try {
      if (enc.toLowerCase() === 'b') return Buffer.from(text, 'base64').toString('utf8');
      return Buffer.from(text.replace(/_/g, ' ').replace(/=([0-9A-F]{2})/gi, (_m, h) => String.fromCharCode(parseInt(h, 16))), 'latin1').toString('utf8');
    } catch (_) { return text; }
  });
}

export function headerOf(raw, name) {
  const m = new RegExp(`^${name}:[ \\t]*(.*(?:\\r?\\n[ \\t].*)*)`, 'im').exec(raw);
  return m ? decodeHeader(m[1].replace(/\r?\n[ \t]+/g, ' ').trim()) : '';
}

/**
 * Kendinden imzali TLS sertifikasi (bir kez uretilir, dizinde saklanir). SAN: 127.0.0.1, ::1, localhost.
 * @returns {Promise<{key:string, cert:string, certFile:string}>}
 */
export async function ensureMailTls(dir) {
  ensureDir(dir);
  const keyFile = path.join(dir, 'key.pem');
  const certFile = path.join(dir, 'cert.pem');
  if (fs.existsSync(keyFile) && fs.existsSync(certFile)) {
    return { key: fs.readFileSync(keyFile, 'utf8'), cert: fs.readFileSync(certFile, 'utf8'), certFile };
  }
  const notBeforeDate = new Date(Date.now() - 24 * 3600 * 1000);
  const notAfterDate = new Date(Date.now() + 3650 * 24 * 3600 * 1000);
  const pems = await selfsigned.generate([{ name: 'commonName', value: 'qa-smtp.localhost' }], {
    keySize: 2048,
    algorithm: 'sha256',
    notBeforeDate,
    notAfterDate,
    extensions: [
      { name: 'basicConstraints', cA: true },
      { name: 'keyUsage', keyCertSign: true, digitalSignature: true, keyEncipherment: true },
      { name: 'extKeyUsage', serverAuth: true },
      { name: 'subjectAltName', altNames: [{ type: 2, value: 'localhost' }, { type: 7, ip: '127.0.0.1' }, { type: 7, ip: '::1' }] },
    ],
  });
  fs.writeFileSync(keyFile, pems.private, { mode: 0o600 });
  fs.writeFileSync(certFile, pems.cert, { mode: 0o644 });
  return { key: pems.private, cert: pems.cert, certFile };
}

/**
 * @param {{dir:string, host?:string, port?:number, logFile?:string, log?:Function, tls?:{key:string, cert:string, certFile?:string}}} o
 * @returns {Promise<{port:number, close:()=>Promise<void>, list:()=>string[], caFile:string|null}>}
 */
export async function startMailSink({ dir, host = '127.0.0.1', port = 2525, logFile, log, tls = null }) {
  ensureDir(dir);
  const logger = log || createLogger(logFile || null);
  let counter = 0;

  const server = new SMTPServer({
    name: 'qa-smtp',
    banner: 'QA e-posta cukuru (disari e-posta cikmaz)',
    authOptional: true,
    allowInsecureAuth: true,           // STARTTLS sonrasi kimlik dogrulama; duz metin de kabul (yalniz loopback)
    disabledCommands: tls ? [] : ['STARTTLS'],
    size: 10 * 1024 * 1024,
    ...(tls ? { key: tls.key, cert: tls.cert, minVersion: 'TLSv1.2' } : {}),
    onAuth(auth, session, cb) {
      cb(null, { user: auth.username || 'qa' }); // kimlik bilgileri herhangi biri kabul
    },
    onData(stream, session, cb) {
      const chunks = [];
      stream.on('data', (c) => chunks.push(c));
      stream.on('end', () => {
        const body = Buffer.concat(chunks);
        const text = body.toString('utf8');
        const id = `${Date.now()}-${++counter}`;
        fs.writeFileSync(path.join(dir, `${id}.eml`), body, { mode: 0o600 });
        logger('mail_received', {
          id,
          from: session.envelope.mailFrom && session.envelope.mailFrom.address,
          to: session.envelope.rcptTo.map((r) => r.address).join(','),
          subject: headerOf(text, 'Subject'),
          bytes: body.length,
          tls: !!session.secure,
        });
        cb(null, `OK: message queued as ${id}`);
      });
    },
  });
  server.on('error', (err) => logger('mail_sink_error', { error: err && err.message }));

  await new Promise((resolve, reject) => {
    const onError = (e) => reject(e);
    server.server.once('error', onError);
    server.listen(port, host, () => { server.server.off('error', onError); resolve(); });
  });
  const actualPort = server.server.address().port;
  logger('mail_sink_started', { host, port: actualPort, dir, starttls: !!tls });

  return {
    server,
    port: actualPort,
    caFile: tls && tls.certFile ? tls.certFile : null,
    list: () => fs.readdirSync(dir).filter((f) => f.endsWith('.eml')).sort(),
    async close() {
      await new Promise((resolve) => server.close(() => resolve()));
      logger('mail_sink_stopped', {});
    },
  };
}
