// `run.js mails [N]` gercek semantigi (docs/QA_STACK.md §2): numarali liste (en yeni = 1, en cok 30) ve N. e-postanin ham govdesi;
// N yoksa hata + cikis kodu 1. Hem saf yardimci (lib/mails.js) hem gercek CLI (cikis kodu + stderr) sinanir.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { MAIL_LIST_LIMIT, listMailFiles, mailsCommand } from '../lib/mails.js';
import { ROOT } from '../lib/paths.js';
import { tmpDir } from './_helpers.js';

const T0 = 1790000000000; // 13 haneli epoch ms (dosya adi: <epoch ms>-<sayac>.eml)

function makeMailDir(count) {
  const dir = tmpDir('qa_mails_');
  for (let i = 1; i <= count; i++) {
    fs.writeFileSync(path.join(dir, `${T0 + i * 1000}-${i}.eml`),
      `Subject: Konu ${i}\r\nTo: kisi${i}@example.com\r\n\r\nGovde ${i}: kod ${String(100000 + i)}\r\n`);
  }
  fs.writeFileSync(path.join(dir, 'notlar.txt'), 'e-posta degil'); // .eml olmayan dosya yok sayilir
  return dir;
}

test('mails: en yeni <=30 e-posta, en yeni = 1; satir bicimi "<no>. <zaman damgasi>  To: ...  Subject: ..."', () => {
  const dir = makeMailDir(35);
  try {
    assert.equal(MAIL_LIST_LIMIT, 30);
    assert.equal(listMailFiles(dir).length, 35);
    const r = mailsCommand(dir);
    assert.equal(r.code, 0);
    assert.equal(r.err, undefined);
    const lines = r.out.split('\n');
    const rows = lines.filter((l) => /^\s*\d+\. /.test(l));
    assert.equal(rows.length, 30, 'en cok 30 satir');
    assert.equal(rows[0], ` 1. ${T0 + 35000}  To: kisi35@example.com  Subject: Konu 35`, 'en yeni basta');
    assert.equal(rows[29], `30. ${T0 + 6000}  To: kisi6@example.com  Subject: Konu 6`);
    assert.ok(!r.out.includes('kisi5@example.com'), '31. ve eskisi listelenmez');
    assert.match(r.out, /Govde icin: node run\.js mails <numara>$/);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('mails N: listedeki N. e-postanin HAM govdesi (1 = en yeni); listede gorunmeyen 31+ da numarayla okunur', () => {
  const dir = makeMailDir(35);
  try {
    const newest = mailsCommand(dir, ['1']);
    assert.equal(newest.code, 0);
    assert.match(newest.out, /Subject: Konu 35\r\n/);
    assert.match(newest.out, /Govde 35: kod 100035/);
    assert.match(mailsCommand(dir, ['30']).out, /Govde 6:/);
    assert.match(mailsCommand(dir, ['35']).out, /Govde 1:/, 'en eski; 30 satirlik listede gorunmese de okunur');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('mails N: olmayan numara / gecersiz arguman -> hata (stderr) + cikis kodu 1; hic e-posta yokken de', () => {
  const dir = makeMailDir(3);
  const empty = tmpDir('qa_mails_empty_');
  try {
    for (const bad of ['4', '999']) {
      const r = mailsCommand(dir, [bad]);
      assert.equal(r.code, 1, bad);
      assert.equal(r.out, undefined);
      assert.match(r.err, /^Boyle bir e-posta yok: /);
    }
    for (const bad of ['0', '-1', 'abc', '2x', '1.5', '']) {
      const r = mailsCommand(dir, [bad]);
      assert.equal(r.code, 1, `"${bad}"`);
      assert.match(r.err, /^Gecersiz e-posta numarasi/);
    }
    // hic e-posta yok: liste = bilgi (0); N istenirse hata (1)
    assert.deepEqual(mailsCommand(empty), { code: 0, out: 'E-posta yok.' });
    const none = mailsCommand(empty, ['1']);
    assert.equal(none.code, 1);
    assert.match(none.err, /^Boyle bir e-posta yok: 1 \(hic e-posta yok\)/);
    // dizin hic yoksa da bos kutu gibi davranir
    assert.deepEqual(mailsCommand(path.join(empty, 'yok')), { code: 0, out: 'E-posta yok.' });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(empty, { recursive: true, force: true });
  }
});

test('run.js mails: gercek CLI -> liste cikis 0; N yoksa stderr + cikis kodu 1 (QA_RUNTIME_DIR ile yalitilmis)', () => {
  const rt = tmpDir('qa_mails_cli_');
  try {
    fs.mkdirSync(path.join(rt, 'mail'), { recursive: true });
    fs.writeFileSync(path.join(rt, 'mail', `${T0}-1.eml`), 'Subject: Dogrulama\r\nTo: musteri@example.com\r\n\r\nKod: 482913\r\n');
    const env = { ...process.env, QA_RUNTIME_DIR: rt };
    delete env.NODE_TEST_CONTEXT;
    const run = (...args) => spawnSync(process.execPath, [path.join(ROOT, 'run.js'), 'mails', ...args], { env, encoding: 'utf8', timeout: 30000, windowsHide: true });

    const list = run();
    assert.equal(list.status, 0, list.stderr);
    assert.match(list.stdout, new RegExp(` 1\\. ${T0}  To: musteri@example\\.com  Subject: Dogrulama`));
    const body = run('1');
    assert.equal(body.status, 0, body.stderr);
    assert.match(body.stdout, /Kod: 482913/);
    const missing = run('2');
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /Boyle bir e-posta yok: 2/);
    assert.equal(missing.stdout.trim(), '');
    assert.equal(run('abc').status, 1);
  } finally { fs.rmSync(rt, { recursive: true, force: true }); }
});
