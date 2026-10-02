'use strict';

// ==============================================================================
// AHBU Akilli Ev - E-posta gonderim servisi (Nodemailer)
// ==============================================================================
//
// Kurallar (denetim 2026-10-01, A12):
//  - OTP / kod / token / baglanti icerigi ASLA log'a yazilmaz ve sonuc nesnesinde DONMEZ.
//  - Her fonksiyon gonderim sonucunu doner:
//        { sent: true }
//        { sent: false, reason: 'SMTP_NOT_CONFIGURED' | 'INVALID_RECIPIENT' | 'SEND_FAILED', error: '<genel metin>' }
//    Cagiran `sent === false` durumunda kullaniciya HATA dondurmelidir (sahte basari yok).
//  - SMTP yapilandirilmamissa sessizce "gonderildi" denmez: reason = SMTP_NOT_CONFIGURED.
//
// Ortam: SMTP_HOST, SMTP_PORT (587), SMTP_USER, SMTP_PASSWORD, SMTP_FROM (ops.)

const nodemailer = require('nodemailer');

const REASONS = Object.freeze({
  SMTP_NOT_CONFIGURED: 'SMTP_NOT_CONFIGURED',
  INVALID_RECIPIENT: 'INVALID_RECIPIENT',
  SEND_FAILED: 'SEND_FAILED',
});

const EMAIL_RE = /^[^\s@<>()[\]\\,;:"]+@[^\s@<>()[\]\\,;:"]+\.[^\s@<>()[\]\\,;:"]+$/;

let transportFactoryOverride = null;

function getSmtpConfig() {
  const host = process.env.SMTP_HOST;
  const user = process.env.SMTP_USER;
  const pass = process.env.SMTP_PASSWORD;
  const port = Number(process.env.SMTP_PORT || 587);
  if (!host || !user || !pass) return null;
  return { host, user, pass, port, from: process.env.SMTP_FROM || user };
}

function isMailerConfigured() {
  return transportFactoryOverride !== null || getSmtpConfig() !== null;
}

/** Geriye donuk uyumluluk: yapilandirma yoksa null doner. */
function createTransporter() {
  if (transportFactoryOverride) return transportFactoryOverride();
  const cfg = getSmtpConfig();
  if (!cfg) return null;
  return nodemailer.createTransport({
    host: cfg.host,
    port: cfg.port,
    secure: cfg.port === 465,
    requireTLS: cfg.port !== 465,
    auth: { user: cfg.user, pass: cfg.pass },
    tls: { minVersion: 'TLSv1.2' },
  });
}

/** Testler icin: () => ({ sendMail: async (msg) => ... }) . null ile sifirlanir. */
function setTransportFactory(factory) {
  transportFactoryOverride = typeof factory === 'function' ? factory : null;
}

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

// Kisisel veri log'a acik yazilmaz: a***@e***.com
function maskEmail(email) {
  const s = String(email || '');
  const at = s.indexOf('@');
  if (at < 1) return '***';
  const domain = s.slice(at + 1);
  const dot = domain.lastIndexOf('.');
  const tld = dot > 0 ? domain.slice(dot) : '';
  return `${s[0]}***@${domain[0] || ''}***${tld}`;
}

function isValidRecipient(to) {
  const s = String(to || '').trim();
  return s.length <= 254 && !/[\r\n]/.test(s) && EMAIL_RE.test(s) && !/\.(invalid|local)$/i.test(s);
}

/**
 * Genel gonderim. Govde/konu log'a yazilmaz.
 * @returns {Promise<{sent:boolean, reason?:string, error?:string}>}
 */
async function sendMail({ to, subject, text, html, tag = 'MAIL' }) {
  const recipient = String(to || '').trim();
  if (!isValidRecipient(recipient)) {
    return { sent: false, reason: REASONS.INVALID_RECIPIENT, error: 'Geçersiz alıcı adresi.' };
  }

  const cfg = getSmtpConfig();
  const transporter = createTransporter();
  if (!transporter) {
    console.error(`[${tag}] SMTP yapilandirilmamis; e-posta gonderilemedi (alici: ${maskEmail(recipient)}).`);
    return { sent: false, reason: REASONS.SMTP_NOT_CONFIGURED, error: 'E-posta servisi yapılandırılmamış.' };
  }

  try {
    // Turkce karakterler: Nodemailer string govdeleri "text/plain; charset=utf-8" ve
    // "text/html; charset=utf-8" olarak, konuyu RFC 2047 (UTF-8) ile kodlar (testte MIME ciktisi
    // dogrulanir). HTML ayrica <meta charset="utf-8"> tasir.
    await transporter.sendMail({
      from: (cfg && cfg.from) || process.env.SMTP_FROM || process.env.SMTP_USER,
      to: recipient,
      subject,
      text,
      html,
    });
    return { sent: true };
  } catch (err) {
    // Hata nesnesi SMTP yanitini (ve bazen icerigi) tasiyabilir: yalnizca kod/tur loglanir.
    const kind = (err && (err.code || err.responseCode || err.name)) || 'Error';
    console.error(`[${tag}] E-posta gonderim hatasi (${kind}) alici: ${maskEmail(recipient)}`);
    return { sent: false, reason: REASONS.SEND_FAILED, error: 'E-posta gönderilemedi.' };
  }
}

function wrapHtml(title, bodyHtml) {
  return `<!DOCTYPE html>
<html lang="tr">
<head><meta charset="utf-8"><meta http-equiv="Content-Type" content="text/html; charset=utf-8"><title>${escapeHtml(title)}</title></head>
<body>
    <div style="font-family: Arial, sans-serif; max-width: 520px; margin: 0 auto; padding: 24px; border: 1px solid #e2e8f0; border-radius: 12px; background-color: #ffffff;">
      <div style="text-align: center; margin-bottom: 20px;">
        <h2 style="color: #0f172a; margin: 0;">AHBU Akıllı Ev</h2>
        <p style="color: #64748b; font-size: 14px; margin-top: 4px;">${escapeHtml(title)}</p>
      </div>
      ${bodyHtml}
      <hr style="border: none; border-top: 1px solid #f1f5f9; margin: 20px 0;" />
      <p style="color: #94a3b8; font-size: 12px; text-align: center; margin: 0;">Bu işlemi siz talep etmediyseniz bu e-postayı dikkate almayın ve kodu kimseyle paylaşmayın.</p>
    </div>
</body>
</html>`;
}

function codeBlock(code) {
  return `<div style="text-align: center; margin: 26px 0;">
      <span style="display: inline-block; padding: 14px 28px; font-size: 32px; font-weight: 800; letter-spacing: 8px; color: #0284c7; background-color: #f0f9ff; border: 2px dashed #0284c7; border-radius: 10px;">${escapeHtml(code)}</span>
    </div>`;
}

/**
 * Servis sorumlusu kurulum yaparken musteriye onay OTP kodu (WP-B kullanir).
 * Imza korunmustur: { to, deviceUuid, code } -> { sent, reason?, error? } (kod DONMEZ).
 */
async function sendClaimOtpEmail({ to, deviceUuid, code, expiresMinutes = 15 }) {
  const safeUuid = escapeHtml(deviceUuid);
  return sendMail({
    to,
    tag: 'CLAIM-OTP',
    subject: 'AHBU Akıllı Ev - Pano kurulum onay kodu',
    text:
      `Merhaba, dairenize ${deviceUuid} panosu kurulmaktadır. Onay kodunuz: ${code}. ` +
      `Kod ${expiresMinutes} dakika geçerlidir. Bu kodu yalnızca kurulumu yapan yetkili servis sorumlusuna iletiniz.`,
    html: wrapHtml(
      'Pano Kurulum ve Daire Eşleme Onayı',
      `<p style="color: #475569; font-size: 14.5px; line-height: 1.5;">Dairenize yetkili servis tarafından <strong>${safeUuid}</strong> kimlikli pano kurulmaktadır. Aşağıdaki kodu yalnızca kurulumu yapan servis sorumlusuna iletiniz:</p>
       ${codeBlock(code)}
       <p style="color: #64748b; font-size: 13px; text-align: center;">Bu kod <strong>${escapeHtml(expiresMinutes)} dakika</strong> geçerlidir.</p>`
    ),
  });
}

/** Sifre sifirlama: 6 haneli kod + (varsa) uygulama baglantisi. */
async function sendPasswordResetEmail({ to, code, link, expiresMinutes = 15 }) {
  const linkHtml = link
    ? `<p style="text-align:center;"><a href="${escapeHtml(link)}" style="color:#0284c7;">Uygulamada şifremi yenile</a></p>`
    : '';
  return sendMail({
    to,
    tag: 'PASSWORD-RESET',
    subject: 'AHBU Akıllı Ev - Şifre sıfırlama kodu',
    text:
      `Şifre sıfırlama kodunuz: ${code}. Kod ${expiresMinutes} dakika geçerlidir.` +
      (link ? ` Uygulamada açmak için: ${link}` : ''),
    html: wrapHtml(
      'Şifre Sıfırlama',
      `<p style="color: #475569; font-size: 14.5px;">Şifre sıfırlama kodunuz:</p>${codeBlock(code)}${linkHtml}
       <p style="color: #64748b; font-size: 13px; text-align: center;">Kod <strong>${escapeHtml(expiresMinutes)} dakika</strong> geçerlidir.</p>`
    ),
  });
}

/** Hesap kurulum daveti (ornegin servis kurulumunda musteri adina acilan hesap). */
async function sendAccountSetupEmail({ to, fullName, code, link, expiresHours = 72 }) {
  const linkHtml = link
    ? `<p style="text-align:center;"><a href="${escapeHtml(link)}" style="color:#0284c7;">Hesabımı etkinleştir</a></p>`
    : '';
  return sendMail({
    to,
    tag: 'ACCOUNT-SETUP',
    subject: 'AHBU Akıllı Ev - Hesabınızı etkinleştirin',
    text:
      `Merhaba ${fullName || ''}, AHBU Akıllı Ev hesabınız oluşturuldu. Şifrenizi belirlemek için kodunuz: ${code}.` +
      (link ? ` Bağlantı: ${link}` : '') +
      ` Geçerlilik: ${expiresHours} saat.`,
    html: wrapHtml(
      'Hesap Etkinleştirme',
      `<p style="color: #475569; font-size: 14.5px;">Merhaba ${escapeHtml(fullName || '')}, hesabınız oluşturuldu. Şifrenizi belirlemek için kodunuz:</p>${codeBlock(code)}${linkHtml}
       <p style="color: #64748b; font-size: 13px; text-align: center;">Geçerlilik: <strong>${escapeHtml(expiresHours)} saat</strong>.</p>`
    ),
  });
}

module.exports = {
  REASONS,
  isMailerConfigured,
  createTransporter,
  setTransportFactory,
  sendMail,
  sendClaimOtpEmail,
  sendPasswordResetEmail,
  sendAccountSetupEmail,
  escapeHtml,
  maskEmail,
};
