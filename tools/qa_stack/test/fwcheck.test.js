// lib/fwcheck.js: firmware kaynak surukenmesi denetimi. Ozet satir sonundan BAGIMSIZDIR: ana agac core.autocrlf=true ile calisir ve ayni
// kaynak bir checkout'ta CRLF, digerinde LF olabilir; bu fark "firmware degisti" sayilmamali (yanlis alarm). Icerik degisikligi ise yakalanir.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import * as fc from '../lib/fwcheck.js';
import { tmpDir } from './_helpers.js';

test('fwcheck: kaynak ozeti CRLF / LF farkindan etkilenmez; icerik degisikligini yakalar', () => {
  const dir = tmpDir('fwcheck_');
  try {
    const lfFile = path.join(dir, 'lf.h');
    const crlfFile = path.join(dir, 'crlf.h');
    const changed = path.join(dir, 'changed.h');
    fs.writeFileSync(lfFile, '#pragma once\nint a = 1;\n');
    fs.writeFileSync(crlfFile, '#pragma once\r\nint a = 1;\r\n');
    fs.writeFileSync(changed, '#pragma once\nint a = 2;\n');
    assert.equal(typeof fc.sourceHash, 'function');
    assert.equal(fc.sourceHash(crlfFile), fc.sourceHash(lfFile));
    assert.notEqual(fc.sourceHash(changed), fc.sourceHash(lfFile));
    assert.equal(fc.sourceHash(path.join(dir, 'yok.h')), null);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('fwcheck: kayitli ozetler (sim/fw/SOURCES.json) depodaki firmware kaynaklariyla AYNI; surum WiFiManager.h FW_VERSION', () => {
  const r = fc.checkDrift();
  assert.deepEqual(r.changed, [], 'firmware degisti: simulatoru esitleyip `node run.js fwcheck --update`');
  assert.equal(r.fw_version, fc.readFwVersion());
});
