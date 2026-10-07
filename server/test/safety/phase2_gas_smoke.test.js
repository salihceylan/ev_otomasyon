'use strict';

// Faz 2 / WP-G1 (tasarim "Faz 2 tasarimi" F2.A.5): gaz/duman push metinleri ve tur bazli vana arizasi push'u.
// Su alarmi metni AYNEN kalir; bilinmeyen tur bugunku genel metni alir.

const test = require('node:test');
const assert = require('node:assert/strict');

const { createAlarmService, helpers } = require('../../src/services/alarm_service');

test('F2.A.5 alarm govdeleri: gaz ve duman yeni metin, su metni AYNEN', () => {
  assert.equal(
    helpers.alarmBody({ kind: 'gas', zone: 2 }),
    "Gaz kaçağı algılandı (bölge 2). Gaz vanası kapatıldı. Ortamı havalandırın, elektrik anahtarlarına dokunmayın; gerekirse 187'yi arayın."
  );
  assert.equal(
    helpers.alarmBody({ kind: 'smoke', zone: 1 }),
    "Duman algılandı (bölge 1). Evde biri varsa hemen dışarı çıkın ve 112'yi arayın. Pano su vanasını kapatmaz."
  );
  assert.equal(
    helpers.alarmBody({ kind: 'water', zone: 3 }),
    'Evinizde su algılandı (bölge 3). Vana pano tarafından kapatıldı; uygulamadan durumu kontrol edin.'
  );
  assert.equal(helpers.alarmTitle('gas'), 'Gaz kaçağı alarmı');
  assert.equal(helpers.alarmTitle('smoke'), 'Duman alarmı');
});

test('F2.A.5 vana arizasi: baslik ve govde ture gore; bilinmeyen tur genel metin', () => {
  assert.equal(helpers.faultTitle('water'), 'Vana kapanmadı!');
  assert.equal(helpers.faultBody('water'), 'Su vanası kapanmadı! Ana su vanasını elle kapatın ve panoyu kontrol edin.');
  assert.equal(helpers.faultTitle('gas'), 'Gaz vanası kapanmadı!');
  assert.equal(
    helpers.faultBody('gas'),
    "Gaz vanası kapanmadı! Sayaçtaki ana gaz vanasını elle kapatın, ortamı havalandırın ve 187'yi arayın."
  );
  assert.equal(helpers.faultTitle('generic'), 'Vana kapanmadı!');
  assert.equal(helpers.faultBody('generic'), 'Vana kapanmadı! Ana vanayı elle kapatın ve panoyu kontrol edin.');
  assert.equal(helpers.faultBody(), 'Vana kapanmadı! Ana vanayı elle kapatın ve panoyu kontrol edin.');
});

function scriptedDb(handlers) {
  const calls = [];
  const run = async (text, params) => {
    calls.push({ text, params });
    for (const h of handlers) if (h.match.test(text)) return h.reply(params, text);
    return { rows: [], rowCount: 0 };
  };
  return { calls, query: run, withTransaction: async (fn) => fn({ query: run }) };
}

async function faultPushFor(kind) {
  const db = scriptedDb([
    {
      match: /SET fault_push_status = 'claimed'/,
      reply: () => ({ rows: [{ id: 9, home_id: 'h1', device_id: 'd1', zone: 2, kind, status: 'fault' }], rowCount: 1 }),
    },
  ]);
  const sent = [];
  const push = {
    isConfigured: () => true,
    recipientsForHome: async () => [{ id: 'p1', token: 'tok-aaaaaaaaaaaaaaaaaaaaa' }],
    sendNotice: async (args) => {
      sent.push(args);
      return { sent: 1 };
    },
  };
  const svc = createAlarmService({
    db,
    publishCommand: async () => {},
    getPush: () => push,
    logger: { log() {}, warn() {}, error() {} },
    sleep: async () => {},
  });
  assert.equal(await svc.pushFault(9), 'sent');
  return sent[0];
}

test('pushFault: gaz alarmi icin gaz basligi/govdesi, su icin su metni (data.status=fault)', async () => {
  const gas = await faultPushFor('gas');
  assert.equal(gas.title, 'Gaz vanası kapanmadı!');
  assert.match(gas.body, /187/);
  assert.equal(gas.data.status, 'fault');
  assert.equal(gas.data.kind, 'gas');
  const water = await faultPushFor('water');
  assert.equal(water.title, 'Vana kapanmadı!');
  assert.equal(water.body, 'Su vanası kapanmadı! Ana su vanasını elle kapatın ve panoyu kontrol edin.');
});
