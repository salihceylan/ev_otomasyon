// `run.js mails [N]`: SMTP cukurunun (.runtime/mail/*.eml) e-postalarini okur.
//   mails     EN YENI en cok 30 e-postayi (en yeni = 1) numarali listeler:  "<no>. <zaman damgasi>  To: ...  Subject: ..."
//             (zaman damgasi = .eml dosya adinin ilk 13 hanesi: epoch milisaniye). Hic e-posta yoksa "E-posta yok." (cikis 0).
//   mails N   Listedeki N. e-postanin HAM govdesini yazar (quoted-printable cozulmez). N yoksa (ya da hic e-posta yoksa)
//             "Boyle bir e-posta yok." hatasi (stderr) + cikis kodu 1; N pozitif tam sayi degilse hata + cikis kodu 1.
// Saf yardimci: dosyalari okur, yazdirmaz; run.js ciktiyi basar (test edilebilir).
import fs from 'node:fs';
import path from 'node:path';

export const MAIL_LIST_LIMIT = 30;

/** .eml dosya adlari, EN YENI basta. */
export function listMailFiles(dir) {
  try {
    return fs.readdirSync(dir).filter((f) => f.endsWith('.eml')).sort().reverse();
  } catch (_) {
    return [];
  }
}

/** @returns {{code:number, out?:string, err?:string}} */
export function mailsCommand(dir, args = []) {
  const files = listMailFiles(dir);
  const arg = args[0];

  if (arg !== undefined) {
    if (!/^\d+$/.test(String(arg)) || Number(arg) < 1) {
      return { code: 1, err: `Gecersiz e-posta numarasi: ${arg} (1 = en yeni; kullanim: node run.js mails [N])` };
    }
    const f = files[Number(arg) - 1];
    if (!f) {
      return { code: 1, err: `Boyle bir e-posta yok: ${arg} (${files.length ? `toplam ${files.length} e-posta` : 'hic e-posta yok'}).` };
    }
    return { code: 0, out: fs.readFileSync(path.join(dir, f), 'utf8') };
  }

  if (!files.length) return { code: 0, out: 'E-posta yok.' };
  const lines = files.slice(0, MAIL_LIST_LIMIT).map((f, i) => {
    const raw = fs.readFileSync(path.join(dir, f), 'utf8');
    const get = (h) => (new RegExp(`^${h}:[ \\t]*(.*)`, 'im').exec(raw) || [, ''])[1].trim();
    return `${String(i + 1).padStart(2)}. ${f.slice(0, 13)}  To: ${get('To')}  Subject: ${get('Subject')}`;
  });
  return { code: 0, out: `${lines.join('\n')}\n\nGovde icin: node run.js mails <numara>` };
}
