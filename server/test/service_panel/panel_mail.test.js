'use strict';

// WP-B2: utils/panel_mail.js - Home Admin atama e-postalari (sahibe onay kodu, yeni sahibe bilgi, onceki sahibe bildirim).
//   - kullanici girdisi (ev adi, kisi adi) HTML'e KACIRILARAK girer
//   - kod yalnizca gonderilen iletide bulunur; sonuc nesnesinde DONMEZ ve log'a yazilmaz
//   - gonderim sonucu yuzeye cikar (sahte basari yok); teslim edilemez alici reddedilir

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.NODE_ENV = 'test';
const mailer = require('../../src/utils/mailer');
const panelMail = require('../../src/utils/panel_mail');

function capture() {
  const sent = [];
  mailer.setTransportFactory(() => ({ sendMail: async (msg) => { sent.push(msg); } }));
  return sent;
}
test.afterEach(() => mailer.setTransportFactory(null));

test('onay kodu e-postası: kod metin ve HTML iletisinde, hedef kişi ve ev adı görünür; sonuç nesnesinde kod YOK; Türkçe karakterler korunur', async () => {
  const sent = capture();
  const logs = [];
  const origErr = console.error;
  console.error = (...a) => logs.push(a.join(' '));
  let result;
  try {
    result = await panelMail.sendAssignAdminOtpEmail({
      to: 'sahip@example.test', homeName: 'Şişli Çınar Apt.', targetName: 'Gülşen Öztürk', targetHint: 'g***@e***.test', code: '482913',
    });
  } finally {
    console.error = origErr;
  }
  assert.deepEqual(result, { sent: true });
  assert.equal(sent.length, 1);
  const m = sent[0];
  assert.equal(m.to, 'sahip@example.test');
  assert.match(m.subject, /devir onay kodu/i);
  assert.ok(m.text.includes('482913'));
  assert.ok(m.html.includes('482913'));
  assert.ok(m.text.includes('Gülşen Öztürk') && m.text.includes('Şişli Çınar Apt.'));
  assert.ok(m.html.includes('charset="utf-8"') || m.html.includes('charset=utf-8'));
  assert.ok(m.text.includes('erişimi kaldırılır'), 'rıza metni: sahip ve ailesinin erişimi kalkar');
  assert.ok(!JSON.stringify(result).includes('482913'));
  assert.ok(!logs.join('\n').includes('482913'), 'kod loga yazılmaz');
});

test('HTML kaçışı: ev adı / kişi adı içindeki etiket ve tırnaklar etkisiz hale gelir (saklı HTML enjeksiyonu yok)', async () => {
  const sent = capture();
  const evil = '<script>alert(1)</script>"><img src=x onerror=alert(2)>';
  await panelMail.sendAssignAdminOtpEmail({ to: 'sahip@example.test', homeName: evil, targetName: evil, targetHint: 'x', code: '111111' });
  await panelMail.sendHomeAdminAssignedEmail({ to: 'yeni@example.test', fullName: evil, homeName: evil });
  await panelMail.sendOwnerReassignedNoticeEmail({ to: 'eski@example.test', fullName: evil, homeName: evil });
  assert.equal(sent.length, 3);
  for (const m of sent) {
    assert.ok(!m.html.includes('<script>'), m.subject);
    assert.ok(!m.html.includes('<img src=x'), m.subject);
    assert.ok(m.html.includes('&lt;script&gt;'), m.subject);
  }
});

test('bilgilendirme e-postaları: yeni sahibe "yetki verildi", önceki sahibe "devredildi"; kod içermez', async () => {
  const sent = capture();
  await panelMail.sendHomeAdminAssignedEmail({ to: 'yeni@example.test', fullName: 'Yeni Sahip', homeName: 'Ev A' });
  await panelMail.sendOwnerReassignedNoticeEmail({ to: 'eski@example.test', fullName: 'Eski Sahip', homeName: 'Ev A' });
  assert.match(sent[0].subject, /yetkisi verildi/i);
  assert.match(sent[1].subject, /devredildi/i);
  for (const m of sent) assert.ok(!/\b\d{6}\b/.test(m.text), 'altı haneli kod yok');
});

test('gönderim sonucu yüzeye çıkar: taşıyıcı hata verirse { sent:false }; teslim edilemez/başlık enjeksiyonlu alıcı reddedilir; SMTP yoksa SMTP_NOT_CONFIGURED', async () => {
  mailer.setTransportFactory(() => ({ sendMail: async () => { throw new Error('smtp down'); } }));
  const origErr = console.error;
  console.error = () => {};
  try {
    const failed = await panelMail.sendAssignAdminOtpEmail({ to: 'sahip@example.test', homeName: 'E', targetName: 'T', targetHint: 'x', code: '123456' });
    assert.equal(failed.sent, false);
    assert.equal(failed.reason, mailer.REASONS.SEND_FAILED);
    assert.ok(!JSON.stringify(failed).includes('123456'));

    const sent = capture();
    for (const bad of ['phone_905551110000@ahbu.local', 'x@ornek.invalid', 'a@b.test\r\nBcc: z@z.test', 'gecersiz']) {
      const r = await panelMail.sendAssignAdminOtpEmail({ to: bad, homeName: 'E', targetName: 'T', targetHint: 'x', code: '123456' });
      assert.equal(r.sent, false, bad);
      assert.equal(r.reason, mailer.REASONS.INVALID_RECIPIENT, bad);
    }
    assert.equal(sent.length, 0);

    mailer.setTransportFactory(null);
    const saved = { h: process.env.SMTP_HOST, u: process.env.SMTP_USER, p: process.env.SMTP_PASSWORD };
    process.env.SMTP_HOST = '';
    process.env.SMTP_USER = '';
    process.env.SMTP_PASSWORD = '';
    try {
      const none = await panelMail.sendAssignAdminOtpEmail({ to: 'sahip@example.test', homeName: 'E', targetName: 'T', targetHint: 'x', code: '123456' });
      assert.equal(none.reason, mailer.REASONS.SMTP_NOT_CONFIGURED);
    } finally {
      process.env.SMTP_HOST = saved.h || '';
      process.env.SMTP_USER = saved.u || '';
      process.env.SMTP_PASSWORD = saved.p || '';
    }
  } finally {
    console.error = origErr;
  }
});
