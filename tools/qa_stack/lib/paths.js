// Yol sabitleri. Tum calisma zamani verisi (veritabani, sirlar, loglar, simulator durumu)
// YALNIZCA tools/qa_stack/.runtime/ altina yazilir (gitignore'lu). QA_RUNTIME_DIR ile
// (testler icin) baska bir dizine yonlendirilebilir.
import path from 'node:path';

export const ROOT = path.resolve(import.meta.dirname, '..');            // tools/qa_stack
export const REPO_ROOT = path.resolve(ROOT, '..', '..');                // ev_otomasyon
export const SERVER_DIR = path.join(REPO_ROOT, 'server');
export const DOCS_DIR = path.join(REPO_ROOT, 'docs');

/**
 * Calisma zamani dizin ve dosya yollari.
 * @param {string} [runtimeDir]
 */
export function runtimePaths(runtimeDir = process.env.QA_RUNTIME_DIR || path.join(ROOT, '.runtime')) {
  const dir = path.resolve(runtimeDir);
  return {
    dir,
    pgData: path.join(dir, 'pgdata'),
    simState: path.join(dir, 'sim'),
    mailDir: path.join(dir, 'mail'),
    mailTlsDir: path.join(dir, 'mail_tls'),
    apiCwd: path.join(dir, 'api_cwd'),
    secretsFile: path.join(dir, 'secrets.json'),
    accountsFile: path.join(dir, 'accounts.json'),
    stackFile: path.join(dir, 'stack.json'),
    pidsFile: path.join(dir, 'pids.json'),
    stateFile: path.join(dir, 'state.json'),
    logs: {
      daemon: path.join(dir, 'daemon.log'),
      broker: path.join(dir, 'broker.log'),
      pg: path.join(dir, 'pg.log'),
      api: path.join(dir, 'api.log'),
      sim: path.join(dir, 'sim.log'),
      mail: path.join(dir, 'mail.log'),
      migrate: path.join(dir, 'migrate.log'),
    },
  };
}

export const RT = runtimePaths();
