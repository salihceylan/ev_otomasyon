// Gomulu web sayfasi (src/WebPortalPage.h; simulatore PORTLANMAZ, bkz. lib/fwcheck.js NOT_PORTED) ile yerel API hata kodlari:
// sayfa factory/init ve rekey'in dondurebilecegi her kodu Turkce metne cevirebilmeli; aksi halde "Islem basarisiz (kod)" gorunur.
// SERVIS-03: NVS yazma hatasi artik 503 {"error":"storage"} (rekey'de eskiden 500 storage_error idi).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { FIRMWARE_DIR } from '../lib/fwcheck.js';

test('web sayfasi ERR_TEXT: factory/init + rekey hata kodlarinin hepsi Turkce metne cevrilir (storage dahil)', () => {
  const page = fs.readFileSync(path.join(FIRMWARE_DIR, 'src', 'WebPortalPage.h'), 'utf8');
  const m = /const ERR_TEXT = \{([\s\S]*?)\n\};/.exec(page);
  assert.ok(m, 'WebPortalPage.h: ERR_TEXT bulunamadi');
  const keys = new Set([...m[1].matchAll(/^\s*([a-z_]+):\s*'[^']+'/gm)].map((x) => x[1]));
  for (const code of ['already_provisioned', 'invalid_key', 'invalid_ap_pass', 'storage', 'storage_error', 'unauthorized', 'locked',
    'unprovisioned', 'invalid_json', 'empty_body', 'too_large', 'unsupported_media_type', 'busy']) {
    assert.ok(keys.has(code), `ERR_TEXT'te '${code}' yok`);
  }
});
