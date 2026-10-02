'use strict';

// A12: mailer OTP/token LOG'LAMAZ, sonucu doner (kodu DONMEZ), SMTP yoksa acik hata.

const test = require('node:test');
const assert = require('node:assert');
const { setTestEnv } = require('./_helpers');

setTestEnv();
delete process.env.SMTP_HOST;
delete process.env.SMTP_USER;
delete process.env.SMTP_PASSWORD;

const mailer = require('../../src/utils/mailer');

function captureConsole() {
  const out = [];
  const saved = {};
  for (const level of ['log', 'info', 'warn', 'error']) {
    saved[level] = console[level];
    console[level] = (...a) => out.push(a.map(String).join(' '));
  }
  return {
    text: () => out.join('\n'),
    restore: () => { for (const [k, v] of Object.entries(saved)) console[k] = v; },
  };
}

test('SMTP yapilandirilmamis -> { sent:false, reason:SMTP_NOT_CONFIGURED }; kod sonucta ve log da YOK', async () => {
  const cap = captureConsole();
  try {
    const r = await mailer.sendClaimOtpEmail({ to: 'musteri@example.com', deviceUuid: 'AHBU-S3-1', code: '482913' });
    assert.strictEqual(r.sent, false);
    assert.strictEqual(r.reason, 'SMTP_NOT_CONFIGURED');
    assert.ok(!JSON.stringify(r).includes('482913'));
    assert.ok(!cap.text().includes('482913'));
    assert.ok(!cap.text().includes('musteri@example.com'));
  } finally {
    cap.restore();
  }
  assert.strictEqual(mailer.isMailerConfigured(), false);
});

test('gonderim basarili -> { sent:true }; kod govdede, KONUDA YOK; HTML kacislanir', async () => {
  const sent = [];
  mailer.setTransportFactory(() => ({ sendMail: async (m) => { sent.push(m); } }));
  try {
    const r = await mailer.sendClaimOtpEmail({ to: 'musteri@example.com', deviceUuid: '<script>x</script>', code: '123987' });
    assert.deepStrictEqual(r, { sent: true });
    assert.strictEqual(sent.length, 1);
    assert.ok(!sent[0].subject.includes('123987'));
    assert.ok(sent[0].text.includes('123987'));
    assert.ok(!sent[0].html.includes('<script>'));
    assert.ok(sent[0].html.includes('&lt;script&gt;'));
  } finally {
    mailer.setTransportFactory(null);
  }
});

test('gonderim hatasi -> { sent:false, reason:SEND_FAILED }; SMTP hata metni/kod log a DUSMEZ', async () => {
  mailer.setTransportFactory(() => ({
    sendMail: async (m) => { const e = new Error(`550 reddedildi: ${m.text}`); e.code = 'EENVELOPE'; throw e; },
  }));
  const cap = captureConsole();
  try {
    const r = await mailer.sendPasswordResetEmail({ to: 'kisi@example.com', code: '765432', link: 'https://x.example/reset#token=gizli-token' });
    assert.strictEqual(r.sent, false);
    assert.strictEqual(r.reason, 'SEND_FAILED');
    const logged = cap.text();
    assert.ok(logged.includes('EENVELOPE'));
    assert.ok(!logged.includes('765432'));
    assert.ok(!logged.includes('gizli-token'));
    assert.ok(!logged.includes('kisi@example.com'));
  } finally {
    cap.restore();
    mailer.setTransportFactory(null);
  }
});

test('gecersiz alici (CRLF / .invalid / .local / bos) -> INVALID_RECIPIENT, gonderim denenmez', async () => {
  let called = 0;
  mailer.setTransportFactory(() => ({ sendMail: async () => { called++; } }));
  try {
    for (const to of ['a@b.com\r\nBcc: x@y.com', 'apple.x@users.noreply.invalid', 'phone_905@ahbu.local', '', 'duz-metin']) {
      const r = await mailer.sendMail({ to, subject: 's', text: 't' });
      assert.strictEqual(r.sent, false, to);
      assert.strictEqual(r.reason, 'INVALID_RECIPIENT');
    }
    assert.strictEqual(called, 0);
  } finally {
    mailer.setTransportFactory(null);
  }
});

test('A17: Turkce karakterler UTF-8 MIME olarak kodlanir (charset=utf-8, konu RFC 2047, HTML meta charset)', async () => {
  const nodemailer = require('nodemailer');
  let raw = null;
  mailer.setTransportFactory(() => {
    const t = nodemailer.createTransport({ streamTransport: true, buffer: true, newline: 'unix' });
    return { sendMail: async (msg) => { const info = await t.sendMail({ ...msg, from: 'noreply@example.com' }); raw = info.message.toString('utf8'); } };
  });
  try {
    const r = await mailer.sendPasswordResetEmail({ to: 'kisi@example.com', code: '135790', link: 'https://x.example/reset#token=t' });
    assert.strictEqual(r.sent, true);
    assert.match(raw, /Content-Type: text\/plain; charset=utf-8/i);
    assert.match(raw, /Content-Type: text\/html; charset=utf-8/i);
    assert.match(raw, /^Subject: =\?UTF-8\?/im);
    // govde kodlamasini cozup Turkce metni dogrula
    const textPart = raw.split(/Content-Type: text\/plain; charset=utf-8/i)[1].split(/\n--/)[0];
    const decoded = textPart.includes('quoted-printable')
      ? Buffer.from(textPart.split('\n\n').slice(1).join('\n\n').replace(/=\n/g, '').replace(/=([0-9A-F]{2})/gi, (_, h) => String.fromCharCode(parseInt(h, 16))), 'latin1').toString('utf8')
      : Buffer.from(textPart.split('\n\n').slice(1).join(''), 'base64').toString('utf8');
    assert.ok(decoded.includes('Şifre sıfırlama kodunuz'), decoded.slice(0, 120));
  } finally {
    mailer.setTransportFactory(null);
  }
  const html = await (async () => {
    let captured;
    mailer.setTransportFactory(() => ({ sendMail: async (m) => { captured = m; } }));
    try { await mailer.sendAccountSetupEmail({ to: 'a@example.com', fullName: 'Ayşe Çelik', code: '111222' }); } finally { mailer.setTransportFactory(null); }
    return captured;
  })();
  assert.match(html.html, /<meta charset="utf-8">/);
  assert.ok(html.html.includes('Ayşe Çelik'));
  assert.ok(html.subject.includes('Hesabınızı etkinleştirin'));
});

test('maskEmail kisisel veriyi gizler', () => {
  assert.strictEqual(mailer.maskEmail('salih@example.com'), 's***@e***.com');
  assert.strictEqual(mailer.maskEmail('x'), '***');
});
