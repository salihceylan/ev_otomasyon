'use strict';

const test = require('node:test');
const assert = require('node:assert');
const express = require('express');
const request = require('supertest');

const { rejectNulBytes, containsNul, MAX_NODES } = require('../../src/middlewares/reject_nul');
const { errorHandler, notFoundHandler } = require('../../src/middlewares/error_handler');

// Gercek ara katman zinciri: json govde -> NUL reddi -> yankilayan rota -> hata yakalayici.
function buildApp() {
  const app = express();
  app.use(express.json({ limit: '256kb' }));
  app.use(rejectNulBytes);
  app.all('/echo/:id?', (req, res) => res.status(200).json({ ok: true, body: req.body, query: req.query }));
  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}

test('NUL iceren gövde alani 400 VALIDATION doner (500 degil)', async () => {
  const res = await request(buildApp()).post('/echo').send({ admin_notes: 'a\u0000b' });
  assert.strictEqual(res.status, 400);
  assert.strictEqual(res.body.success, false);
  assert.strictEqual(res.body.code, 'VALIDATION');
});

test('NUL iceren sorgu dizgisi (%00) 400 VALIDATION doner', async () => {
  const app = buildApp();
  for (const q of ['search=%00', 'q=a%00b', 'batch_no=%00']) {
    const res = await request(app).get('/echo?' + q);
    assert.strictEqual(res.status, 400, q);
    assert.strictEqual(res.body.code, 'VALIDATION', q);
  }
});

test('yol parametresindeki %00 (buyuk/kucuk harf) reddedilir', async () => {
  const app = buildApp();
  assert.strictEqual((await request(app).get('/echo/a%00b')).status, 400);
  assert.strictEqual((await request(app).get('/echo/%00')).status, 400);
});

test('ic ice nesne/dizi icindeki ve ANAHTARDAKI NUL de yakalanir', async () => {
  const app = buildApp();
  const bodies = [
    { a: { b: { c: ['x', 'y\u0000'] } } },
    { list: [{ n: 1 }, { n: 'ok' }, { n: '\u0000' }] },
    JSON.parse('{"a\\u0000b": 1}'),
  ];
  for (const b of bodies) {
    const res = await request(app).post('/echo').send(b);
    assert.strictEqual(res.status, 400, JSON.stringify(b).slice(0, 60));
  }
});

test('normal Turkce ve Unicode metin ETKILENMEZ', async () => {
  const body = { ad: 'Çağrı Öztürk', not: 'ğüşiöçİĞÜŞÖÇ 😀 — tamam', sayi: 5, bool: true, bos: null, liste: ['a', 'ı'] };
  const res = await request(buildApp()).post('/echo').send(body);
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(res.body.body, body);
  const q = await request(buildApp()).get('/echo?search=' + encodeURIComponent('Şişli İş'));
  assert.strictEqual(q.status, 200);
  assert.strictEqual(q.body.query.search, 'Şişli İş');
});

test('asiri buyuk yapi (dugum sayisi siniri) guvenli tarafta reddedilir; tarama yigin tasirmaz', () => {
  const wide = {};
  for (let i = 0; i < MAX_NODES + 5; i += 1) wide['k' + i] = { v: i };
  assert.strictEqual(containsNul(wide), true);
  // 50 bin derinlikte ic ice dizi: ozyinelemeli tarama yigin tasirirdi; iteratif tarama sorunsuz biter.
  let deep = 'x';
  for (let i = 0; i < 50000; i += 1) deep = [deep];
  assert.doesNotThrow(() => containsNul(deep));
});

test('temiz istekler (bos gövde / GET) gecer', async () => {
  const app = buildApp();
  assert.strictEqual((await request(app).get('/echo')).status, 200);
  assert.strictEqual((await request(app).post('/echo').send({})).status, 200);
  assert.strictEqual((await request(app).get('/echo/abc?x=1')).status, 200);
});
