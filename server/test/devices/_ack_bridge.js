'use strict';

// ==============================================================================
// Test altyapisi: sahte kopruye cihaz ONAYI (state.last_id yankisi) taklidi ekler (DAIRE-03).
//
// Gercek kopru (src/mqtt_bridge.js expectAck/cancelAck) ile ayni sozlesme:
//   expectAck(topicId, commandId, timeoutMs) -> Promise<boolean>   YAYINDAN ONCE kurulmalidir
//   cancelAck(topicId, commandId)                                   bekleyeni false ile kapatir
//
// bridge.ackMode:
//   'auto'  (varsayilan) yayinlanan komutun `id`'si icin bekleyen onay true olur (pano komutu uyguladi)
//   'never' onay gelmez: bekleyici hemen false doner (zaman asimi taklidi; pano komutu reddetti)
// Once yayinlanip SONRA beklenen kimlik false doner: gercek koprude de erken gelen yanki kacirilir.
// Kayitlar: bridge.ackWaits [{ topicId, commandId, timeoutMs, afterPublish }], bridge.ackCancels [{ topicId, commandId }].
// ==============================================================================

function withAckSupport(bridge, { mode = 'auto' } = {}) {
  const waiters = new Map(); // `${topicId}|${commandId}` -> resolve
  const published = new Set();
  const key = (topicId, commandId) => `${topicId}|${commandId}`;

  bridge.ackMode = mode;
  bridge.ackWaits = [];
  bridge.ackCancels = [];

  const originalPublish = bridge.publishCommand;
  bridge.publishCommand = async function publishCommandWithAck(topicId, obj) {
    const out = await originalPublish.call(this, topicId, obj);
    const id = obj && typeof obj.id === 'string' ? obj.id : null;
    if (id) {
      const k = key(topicId, id);
      published.add(k);
      const resolve = waiters.get(k);
      if (resolve && this.ackMode === 'auto') {
        waiters.delete(k);
        resolve(true);
      }
    }
    return out;
  };

  bridge.expectAck = function expectAck(topicId, commandId, timeoutMs) {
    const k = key(topicId, commandId);
    this.ackWaits.push({ topicId, commandId, timeoutMs, afterPublish: published.has(k) });
    if (this.ackMode !== 'auto' || published.has(k)) return Promise.resolve(false);
    return new Promise((resolve) => waiters.set(k, resolve));
  };

  bridge.cancelAck = function cancelAck(topicId, commandId) {
    const k = key(topicId, commandId);
    this.ackCancels.push({ topicId, commandId });
    const resolve = waiters.get(k);
    if (resolve) {
      waiters.delete(k);
      resolve(false);
    }
  };

  return bridge;
}

module.exports = { withAckSupport };
