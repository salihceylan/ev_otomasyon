// Windows/libuv aralikli YEREL cokmesi (cikis kodu 0xC0000409 = 3221226505, 'UV_HANDLE_CLOSING'): bir node alt sureci
// `process.exit()` ile (ya da erken) bu kodla bitebilir. Normal basarisizlik (1, 2 ...) DEGILDIR ve yeniden DENENMEZ.
// `applyMigrations` migrate.js cokerse 2 kez yeniden calistirir (migration'lar idempotent + dosya basina islemdedir).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { applyMigrations, isNativeCrash } from '../lib/api_server.js';
import { runtimePaths } from '../lib/paths.js';
import { createLogger } from '../lib/util.js';
import { tmpDir } from './_helpers.js';

const CRASH = 3221226505;

test('isNativeCrash: NT yerel hata kodlari (0xC...) ve sinyaller coktur; 0/1/2 degildir', () => {
  assert.equal(isNativeCrash({ code: CRASH }), true);
  assert.equal(isNativeCrash({ code: 0xC0000005 }), true, 'erisim ihlali');
  assert.equal(isNativeCrash({ code: null, signal: 'SIGSEGV' }), true);
  assert.equal(isNativeCrash({ code: 0 }), false);
  assert.equal(isNativeCrash({ code: 1 }), false);
  assert.equal(isNativeCrash({ code: 2 }), false);
  assert.equal(isNativeCrash({ code: 137 }), false);
  assert.equal(isNativeCrash(undefined), false);
});

/** Sahte server/scripts/migrate.js: her calismada isaret dosyasina 1 bayt ekler, sonra `body`'yi calistirir. */
function fakeServer(dir, body) {
  const serverDir = path.join(dir, 'server');
  fs.mkdirSync(path.join(serverDir, 'scripts'), { recursive: true });
  const marker = path.join(dir, 'runs.txt');
  fs.writeFileSync(marker, '');
  const crash = process.platform === 'win32' ? `process.exit(${CRASH})` : "process.kill(process.pid, 'SIGKILL')";
  fs.writeFileSync(path.join(serverDir, 'scripts', 'migrate.js'),
    `const fs = require('fs'); fs.appendFileSync(${JSON.stringify(marker)}, 'x'); const runs = fs.readFileSync(${JSON.stringify(marker)}).length; const crash = () => { ${crash}; }; ${body}`);
  return { serverDir, runs: () => fs.readFileSync(marker).length };
}

async function runMigrations(body) {
  const dir = tmpDir('qa_mig_');
  try {
    const { serverDir, runs } = fakeServer(dir, body);
    const rt = runtimePaths(path.join(dir, 'rt'));
    const res = await applyMigrations({ rt, dbUrl: 'postgresql://x:y@127.0.0.1:1/z', serverDir, log: createLogger(null) });
    return { res, runs: runs(), migrateLog: fs.existsSync(rt.logs.migrate) ? fs.readFileSync(rt.logs.migrate, 'utf8') : '' };
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

test('applyMigrations: ilk calisma yerel cokerse yeniden calisir ve basarili olur (2 calisma)', async () => {
  const r = await runMigrations('if (runs === 1) crash(); process.exit(0);');
  assert.equal(r.res.ok, true);
  assert.equal(r.res.code, 0);
  assert.equal(r.runs, 2);
  assert.match(r.migrateLog, /yerel olarak coktu .*yeniden deneniyor \(1\/2\)/);
});

test('applyMigrations: hep cokerse 3 calismadan sonra BASARISIZ sayilir (sonsuz dongu yok)', async () => {
  const r = await runMigrations('crash();');
  assert.equal(r.res.ok, false);
  assert.equal(r.runs, 3);
  assert.ok(isNativeCrash({ code: r.res.code }) || r.res.code === null || r.res.code === undefined, `kod: ${r.res.code}`);
});

test('applyMigrations: normal hata kodu (1) YENIDEN DENENMEZ; basarida tek calisma', async () => {
  const bad = await runMigrations('process.exit(1);');
  assert.equal(bad.res.ok, false);
  assert.equal(bad.res.code, 1);
  assert.equal(bad.runs, 1);
  const good = await runMigrations('process.exit(0);');
  assert.equal(good.res.ok, true);
  assert.equal(good.runs, 1);
});
