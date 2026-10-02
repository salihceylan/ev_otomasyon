'use strict';

// ==============================================================================
// AHBU Akilli Ev - Servis paneli e-postalari (WP-B2)
// ==============================================================================
//
// Home Admin atama akisinin e-postalari: mevcut sahibe onay kodu (OTP), yeni sahibe bilgilendirme,
// zorla (super) atamada onceki sahibe bildirim. Gonderim `utils/mailer.sendMail` uzerinden yapilir;
// `{ sent, reason? }` doner (sahte basari YOK; cagiran sonucu yuzeye cikarir).
//
// Kurallar (mailer.js ile ayni):
//  - OTP / kod govdesi ASLA log'a yazilmaz ve sonuc nesnesinde DONMEZ.
//  - Kullanici girdisi (ev adi, kisi adi) HTML'e KACIRILARAK girer (escapeHtml).

const mailer = require('./mailer');

const esc = mailer.escapeHtml;

function wrapHtml(title, bodyHtml) {
  return `<!DOCTYPE html>
<html lang="tr">
<head><meta charset="utf-8"><meta http-equiv="Content-Type" content="text/html; charset=utf-8"><title>${esc(title)}</title></head>
<body>
    <div style="font-family: Arial, sans-serif; max-width: 520px; margin: 0 auto; padding: 24px; border: 1px solid #e2e8f0; border-radius: 12px; background-color: #ffffff;">
      <div style="text-align: center; margin-bottom: 20px;">
        <h2 style="color: #0f172a; margin: 0;">AHBU Akıllı Ev</h2>
        <p style="color: #64748b; font-size: 14px; margin-top: 4px;">${esc(title)}</p>
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
      <span style="display: inline-block; padding: 14px 28px; font-size: 32px; font-weight: 800; letter-spacing: 8px; color: #0284c7; background-color: #f0f9ff; border: 2px dashed #0284c7; border-radius: 10px;">${esc(code)}</span>
    </div>`;
}

const para = (html) => `<p style="color: #475569; font-size: 14.5px; line-height: 1.5;">${html}</p>`;

/**
 * Mevcut ev sahibine: "dairenizin yonetimi X kisisine devredilecek" onay kodu.
 * Kod hedef kisiye baglidir; sahip kimin icin onay verdigini bu e-postada gorur.
 *
 * @param {{to:string, homeName:string, targetName:string, targetHint:string, code:string, expiresMinutes?:number}} p
 * @returns {Promise<{sent:boolean, reason?:string, error?:string}>}
 */
async function sendAssignAdminOtpEmail({ to, homeName, targetName, targetHint, code, expiresMinutes = 15 }) {
  const home = String(homeName || 'Dairenizin');
  const who = `${targetName || ''} (${targetHint || ''})`.trim();
  return mailer.sendMail({
    to,
    tag: 'ASSIGN-ADMIN-OTP',
    subject: 'AHBU Akıllı Ev - Daire yönetimi devir onay kodu',
    text:
      `"${home}" dairenizin yönetici (Home Admin) yetkisi, yetkili servis tarafından ${who} kişisine devredilmek isteniyor. ` +
      `Onaylıyorsanız kodu yalnızca servis sorumlusuna iletin: ${code}. Kod ${expiresMinutes} dakika geçerlidir. ` +
      'Onaylarsanız sizin ve ailenizin bu daireye erişimi kaldırılır. Bu işlemi siz istemediyseniz kodu paylaşmayın.',
    html: wrapHtml(
      'Daire Yönetimi Devir Onayı',
      `${para(`<strong>${esc(home)}</strong> dairenizin yönetici (Home Admin) yetkisi, yetkili servis tarafından <strong>${esc(who)}</strong> kişisine devredilmek isteniyor.`)}
       ${para('Onaylıyorsanız aşağıdaki kodu yalnızca servis sorumlusuna iletin. <strong>Onaylarsanız sizin ve ailenizin bu daireye erişimi kaldırılır.</strong>')}
       ${codeBlock(code)}
       <p style="color: #64748b; font-size: 13px; text-align: center;">Bu kod <strong>${esc(expiresMinutes)} dakika</strong> geçerlidir.</p>`
    ),
  });
}

/** Yeni Home Admin'e (mevcut ve etkin hesap): "su daire icin yonetici yetkisi verildi". */
async function sendHomeAdminAssignedEmail({ to, fullName, homeName }) {
  const home = String(homeName || 'Daire');
  return mailer.sendMail({
    to,
    tag: 'ADMIN-ASSIGNED',
    subject: 'AHBU Akıllı Ev - Daire yönetici yetkisi verildi',
    text: `Merhaba ${fullName || ''}, "${home}" dairesinin yönetici (Home Admin) yetkisi hesabınıza tanımlandı. Daire uygulamada evler listenizde görünür.`,
    html: wrapHtml(
      'Daire Yönetici Yetkisi',
      para(`Merhaba ${esc(fullName || '')}, <strong>${esc(home)}</strong> dairesinin yönetici (Home Admin) yetkisi hesabınıza tanımlandı. Daire, uygulamadaki ev listenizde görünür.`)
    ),
  });
}

/** Onceki sahibe (yalniz zorla atamada): ona sorulmadan yonetim devredildigini bildirir. */
async function sendOwnerReassignedNoticeEmail({ to, fullName, homeName }) {
  const home = String(homeName || 'Daire');
  return mailer.sendMail({
    to,
    tag: 'ADMIN-REASSIGNED',
    subject: 'AHBU Akıllı Ev - Daire yönetimi devredildi',
    text:
      `Merhaba ${fullName || ''}, "${home}" dairesinin yönetici yetkisi yetkili servis tarafından başka bir hesaba devredildi ve bu daireye erişiminiz kaldırıldı. ` +
      'Bu işlemden haberiniz yoksa lütfen destek ile iletişime geçin.',
    html: wrapHtml(
      'Daire Yönetimi Devredildi',
      para(`Merhaba ${esc(fullName || '')}, <strong>${esc(home)}</strong> dairesinin yönetici yetkisi yetkili servis tarafından başka bir hesaba devredildi ve bu daireye erişiminiz kaldırıldı. Bu işlemden haberiniz yoksa lütfen destek ile iletişime geçin.`)
    ),
  });
}

module.exports = {
  sendAssignAdminOtpEmail,
  sendHomeAdminAssignedEmail,
  sendOwnerReassignedNoticeEmail,
};
