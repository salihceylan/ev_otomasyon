// ==============================================================================
// AHBU Akıllı Ev & Bina Otomasyonu - E-Posta Gönderim Servisi (Nodemailer)
// ==============================================================================

const nodemailer = require('nodemailer');

function createTransporter() {
  const host = process.env.SMTP_HOST;
  const user = process.env.SMTP_USER;
  const pass = process.env.SMTP_PASSWORD;
  const port = Number(process.env.SMTP_PORT || 587);

  if (!host || !user || !pass) {
    return null; // SMTP yapılandırılmamışsa null döner
  }

  return nodemailer.createTransport({
    host,
    port,
    secure: port === 465,
    requireTLS: port !== 465,
    auth: { user, pass },
  });
}

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

/**
 * Servis sorumlusu kurulum yaparken müşteriye onay OTP kodu gönderme
 */
async function sendClaimOtpEmail({ to, deviceUuid, code }) {
  const safeTo = String(to).trim();
  const safeUuid = escapeHtml(deviceUuid);
  const safeCode = escapeHtml(code);
  const from = process.env.SMTP_FROM || process.env.SMTP_USER || 'destek@ahbu.com.tr';

  console.log(`[CLAIM-OTP] Alıcı: ${safeTo} | Pano: ${deviceUuid} | Onay Kodu: ${code}`);

  const transporter = createTransporter();
  if (!transporter) {
    // SMTP env tanımlı değilse konsola loglayıp başarıyla döner
    return { sent: false, fallback: 'console', code };
  }

  try {
    await transporter.sendMail({
      from,
      to: safeTo,
      subject: `AHBU Akıllı Ev - Pano Kurulum & Eşleme Onay Kodu: ${code}`,
      text: `Merhaba, dairenize ${deviceUuid} panosu kurulmaktadır. Onay kodunuz: ${code}. Bu kodu kurulum yapan servis sorumlusuna iletiniz.`,
      html: `
        <div style="font-family: Arial, sans-serif; max-width: 520px; margin: 0 auto; padding: 24px; border: 1px solid #e2e8f0; border-radius: 12px; background-color: #ffffff;">
          <div style="text-align: center; margin-bottom: 20px;">
            <h2 style="color: #0f172a; margin: 0;">🏠 AHBU Akıllı Ev</h2>
            <p style="color: #64748b; font-size: 14px; margin-top: 4px;">Pano Kurulum & Daire Eşleme Onayı</p>
          </div>
          <p style="color: #334155; font-size: 15px;">Merhaba,</p>
          <p style="color: #475569; font-size: 14.5px; line-height: 1.5;">
            Dairenize yetkili servis tarafından <strong>${safeUuid}</strong> kimlikli AHBU Akıllı Ev Panosu kurulmaktadır.
          </p>
          <p style="color: #475569; font-size: 14.5px; line-height: 1.5;">
            Cihazın ve akıllı ev kontrollerinin adınıza ve dairenize güvenle tanımlanabilmesi için aşağıdaki 6 haneli doğrulama kodunu yetkili servis sorumlusuna iletiniz:
          </p>
          <div style="text-align: center; margin: 26px 0;">
            <span style="display: inline-block; padding: 14px 28px; font-size: 32px; font-weight: 800; letter-spacing: 8px; color: #0284c7; background-color: #f0f9ff; border: 2px dashed #0284c7; border-radius: 10px;">${safeCode}</span>
          </div>
          <p style="color: #64748b; font-size: 13px; text-align: center;">⏱️ Bu kod <strong>15 dakika</strong> boyunca geçerlidir.</p>
          <hr style="border: none; border-top: 1px solid #f1f5f9; margin: 20px 0;" />
          <p style="color: #94a3b8; font-size: 12px; text-align: center; margin: 0;">Bu kurulumu siz talep etmediyseniz lütfen bu kodu kimseyle paylaşmayınız.</p>
        </div>
      `,
    });
    return { sent: true };
  } catch (err) {
    console.error('[CLAIM-OTP-MAIL-ERROR]', err.message);
    return { sent: false, error: err.message, code };
  }
}

module.exports = {
  createTransporter,
  sendClaimOtpEmail,
};
