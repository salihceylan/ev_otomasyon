#!/usr/bin/env node
// =================================================================================================
// tool/preview/preview.mjs  -  build + screenshot driver for the "preview" harness
//
// The harness (tool/preview/preview_main.dart + preview_fixture.dart) renders the REAL DashboardPage /
// DeviceSettingsPage / LoginPage / splash inside the REAL theme with a mocked AutomationState. No cloud,
// no MQTT broker, no device, no emulator is needed.
//   PRIMARY   `flutter build web` + headless Chrome (puppeteer-core)   -> build / shoot / all / serve
//   FALLBACK  `flutter test` + real fonts, PNGs without a browser      -> golden
//
// COMMANDS
//   node tool/preview/preview.mjs build  [--src working|head|inplace] [--mode release|profile|debug] [--fast]
//                                        [--skip-analyze] [--verbose]
//   node tool/preview/preview.mjs shoot  [--src ...|--web <dir>] [--tag <name>] [--screens a,b] [--themes dark,light]
//                                        [--viewports phone,tablet,desktop,phone-small,phone-long|WxH[@dpr]]
//                                        [--scenarios default,locked,quiet,offline,empty,many,peace_off,peace_notime]
//                                        [--shell page|app] [--insets [top,bottom]] [--query "textscale=1.3&freeze=1"]
//                                        [--suffix name] [--scroll <px>] [--wait <ms>] [--gpu] [--perf] [--timeout <sec>]
//   node tool/preview/preview.mjs all    (build, then shoot; same flags)
//   node tool/preview/preview.mjs serve  [--src ...|--web <dir>] [--port 8765]   (open in a normal browser)
//   node tool/preview/preview.mjs compare --a <tagA> --b <tagB>   (before | after | diff PNGs + % changed)
//   node tool/preview/preview.mjs golden [--src working|head] [--tag golden] [--screens ..] [--themes ..] [--scenarios ..]
//
// --src working  (default) snapshot-copies the CURRENT working tree (lib/ web/ assets/ pubspec.*) to
//                build/preview_src_working and builds there. Isolated: concurrent edits by other agents
//                cannot produce a half-written tree mid-compile, and it never touches the repo's
//                .dart_tool / pubspec.lock. A `dart analyze lib tool/preview` preflight (~10 s) aborts early
//                when the tree does not compile (a failing release build otherwise needs 2-3 minutes).
// --src head     exports `git archive HEAD` (the last COMMITTED tree) to build/preview_src_head and builds it
//                with --dart-define=PREVIEW_LEGACY_ROLES=true (old int-id models). Use it for a "before"
//                baseline when the working tree is mid-refactor.
// --src inplace  builds in the repo root (--no-pub, output build/web). Fastest, but reads files live.
//
// OUTPUT   build/preview_shots/<tag>/<screen>-<theme>[-<scenario>][-<suffix>]-<viewport>.png  + report.json
// ENV      CHROME_PATH            chrome.exe (default: Program Files Chrome, then Edge)
//          PUPPETEER_CORE_DIR     a directory whose node_modules contains puppeteer-core
//                                 (or: npm i --prefix tool/preview puppeteer-core)
//          PREVIEW_CACHE_DIR      record/replay cache for CDN resources. Default build/preview_cache
// NETWORK  Page requests are intercepted: localhost -> served from disk; fonts.gstatic.com / www.gstatic.com /
//          fonts.googleapis.com -> record/replay cache (first run downloads, later runs are offline and
//          byte-identical); the production API host -> stubbed 503 (listed in report.json as a "leak");
//          everything else -> blocked (e.g. accounts.google.com from google_sign_in_web).
// =================================================================================================

import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const isWin = process.platform === 'win32';

// ----------------------------------------------------------------------------- args
function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) out[key] = true;
      else { out[key] = next; i++; }
    } else out._.push(a);
  }
  return out;
}
const args = parseArgs(process.argv.slice(2));
const cmd = args._[0] || 'help';
const csv = (v, d) => (typeof v === 'string' ? v.split(',').map((s) => s.trim()).filter(Boolean) : d);
const log = (...a) => console.log(`[preview ${new Date().toTimeString().slice(0, 8)}]`, ...a);

// ----------------------------------------------------------------------------- paths
function snapDir(src) { return path.join(repo, 'build', `preview_src_${src}`); }
function webDirFor(src) {
  if (args.web && typeof args.web === 'string') return path.resolve(args.web);
  return src === 'inplace' ? path.join(repo, 'build', 'web') : path.join(snapDir(src), 'build', 'web');
}

// ----------------------------------------------------------------------------- process helpers
function run(command, argv, opts = {}) {
  return new Promise((resolve) => {
    const started = Date.now();
    // Windows: flutter/dart are .bat shims and need a shell. Pass ONE quoted command line (passing an args
    // array together with shell:true is deprecated: DEP0190).
    const quote = (a) => (/[\s"&|<>^]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a);
    const env = { ...process.env, ...opts.env };
    const child = isWin
      ? spawn([command, ...argv].map(quote).join(' '), { cwd: opts.cwd, env, shell: true, stdio: ['ignore', 'pipe', 'pipe'] })
      : spawn(command, argv, { cwd: opts.cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    const lines = [];
    const sink = (buf) => {
      const text = buf.toString();
      lines.push(text);
      if (opts.echo) process.stdout.write(text);
    };
    child.stdout.on('data', sink);
    child.stderr.on('data', sink);
    child.on('close', (code) => resolve({ code, ms: Date.now() - started, output: lines.join('') }));
  });
}

function copyDir(from, to) {
  fs.rmSync(to, { recursive: true, force: true });
  fs.cpSync(from, to, { recursive: true });
}

// ----------------------------------------------------------------------------- snapshots
/** Copies (working) or exports (head) the app sources + the harness into an isolated directory. */
async function prepareSnapshot(src, dir = snapDir(src)) {
  fs.mkdirSync(dir, { recursive: true });
  if (src === 'head') {
    // Relative paths + cwd on purpose: GNU tar (Git for Windows) treats "G:\..." as a remote host:path.
    const tarRel = path.relative(repo, path.join(dir, '_head.tar')).replace(/\\/g, '/');
    const r = spawnSync('git', ['archive', '--format=tar', '-o', tarRel, 'HEAD', 'lib', 'web', 'assets', 'pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml'], { cwd: repo, encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`git archive failed: ${r.stderr}`);
    for (const d of ['lib', 'web', 'assets']) fs.rmSync(path.join(dir, d), { recursive: true, force: true });
    const x = spawnSync('tar', ['-xf', '_head.tar'], { cwd: dir, encoding: 'utf8' });
    if (x.status !== 0) throw new Error(`tar failed: ${x.stderr}`);
    fs.rmSync(path.join(dir, '_head.tar'), { force: true });
  } else {
    for (const d of ['lib', 'web', 'assets']) copyDir(path.join(repo, d), path.join(dir, d));
    for (const f of ['pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml']) fs.copyFileSync(path.join(repo, f), path.join(dir, f));
  }
  // the harness is always taken from the working tree
  copyDir(here, path.join(dir, 'tool', 'preview'));
  fs.rmSync(path.join(dir, 'tool', 'preview', 'node_modules'), { recursive: true, force: true });
  return dir;
}

/** (Re)resolve packages in a snapshot whenever pubspec.yaml / pubspec.lock changed since the last run. */
async function ensureDeps(cwd) {
  const sig = crypto.createHash('sha1')
    .update(fs.readFileSync(path.join(cwd, 'pubspec.yaml'))).update(fs.readFileSync(path.join(cwd, 'pubspec.lock'))).digest('hex');
  const sigFile = path.join(cwd, '.preview_pubspec_sig');
  const stale = !fs.existsSync(path.join(cwd, '.dart_tool', 'package_config.json')) || !fs.existsSync(sigFile) || fs.readFileSync(sigFile, 'utf8') !== sig;
  if (!stale) return;
  log('flutter pub get --offline (snapshot) ...');
  let r = await run('flutter', ['pub', 'get', '--offline'], { cwd });
  if (r.code !== 0) {
    log('offline pub get failed, trying online ...');
    r = await run('flutter', ['pub', 'get'], { cwd });
    if (r.code !== 0) { console.error(r.output); throw new Error('flutter pub get failed'); }
  }
  fs.writeFileSync(sigFile, sig);
}

/** Fail fast: a release dart2js run needs ~100-170 s just to report compile errors, `dart analyze` ~10 s. */
async function preflight(cwd, src) {
  const a = await run('dart', ['analyze', 'lib', 'tool/preview'], { cwd });
  const errors = a.output.split('\n').filter((l) => /^\s*error\b/.test(l));
  if (errors.length) {
    console.error(errors.slice(0, 40).map((l) => l.trim().slice(0, 230)).join('\n'));
    const hint = src === 'working' ? 'The tree is mid-refactor: wait until `dart analyze lib` is clean, or build a baseline with --src head. ' : '';
    console.error(`\nPREFLIGHT FAILED: ${errors.length} compile error(s) in the ${src === 'head' ? 'HEAD export' : 'working tree'} (lib/ or tool/preview/). ${hint}Skip with --skip-analyze.`);
    process.exit(2);
  }
  const noisy = a.output.split('\n').filter((l) => /^\s*(warning|info)\b/.test(l)).length;
  log(`preflight: dart analyze lib tool/preview -> no errors (${noisy} warnings/infos)`);
}

// ----------------------------------------------------------------------------- build (web)
async function build() {
  const src = String(args.src || 'working');
  if (!['working', 'head', 'inplace'].includes(src)) throw new Error('--src must be working|head|inplace');
  const mode = String(args.mode || 'release');
  const cwd = src === 'inplace' ? repo : await prepareSnapshot(src);
  const t0 = Date.now();

  if (src !== 'inplace') await ensureDeps(cwd);
  if (!args['skip-analyze']) await preflight(cwd, src);

  const fb = ['build', 'web', '-t', 'tool/preview/preview_main.dart', `--${mode}`, '--no-web-resources-cdn', '--no-pub'];
  if (args.fast) fb.push('-O1');
  if (src === 'head') fb.push('--dart-define=PREVIEW_LEGACY_ROLES=true');
  for (const d of csv(args.define, [])) fb.push(`--dart-define=${d}`);
  log(`flutter ${fb.join(' ')}   (cwd ${path.relative(repo, cwd) || '.'})`);
  const r = await run('flutter', fb, { cwd, echo: !!args.verbose });
  const logFile = path.join(src === 'inplace' ? path.join(repo, 'build') : cwd, 'preview_build.log');
  fs.writeFileSync(logFile, r.output);
  if (r.code !== 0) {
    const errs = r.output.split('\n').filter((l) => /error/i.test(l));
    console.error(r.output.split('\n').slice(-60).join('\n'));
    console.error(`\nBUILD FAILED after ${((Date.now() - t0) / 1000).toFixed(0)}s: ${errs.length} error line(s). Full log: ${logFile}`);
    process.exit(2);
  }
  log(`build OK in ${((Date.now() - t0) / 1000).toFixed(0)}s -> ${path.relative(repo, webDirFor(src))}`);
}

// ----------------------------------------------------------------------------- golden (flutter test fallback)
const INTER_NAMES = { 100: 'Thin', 200: 'ExtraLight', 300: 'Light', 400: 'Regular', 500: 'Medium', 600: 'SemiBold', 700: 'Bold', 800: 'ExtraBold', 900: 'Black' };

/**
 * google_fonts downloads Inter from fonts.gstatic.com at runtime (the app bundles NO fonts). A widget test has
 * no usable network/path_provider, so for the golden fallback the static TTFs are fetched once (URL + sha256 are
 * read from the google_fonts package source) into build/preview_fonts and bundled as `google_fonts/Inter-*.ttf`
 * assets of the throw-away snapshot - the exact lookup google_fonts performs first.
 */
async function ensureInterFonts(snap) {
  const fontsDir = path.join(repo, 'build', 'preview_fonts');
  fs.mkdirSync(fontsDir, { recursive: true });
  const pcFile = path.join(snap, '.dart_tool', 'package_config.json');
  const pc = JSON.parse(fs.readFileSync(pcFile, 'utf8'));
  const pkg = pc.packages.find((p) => p.name === 'google_fonts');
  if (!pkg) throw new Error('google_fonts is not a dependency of the app');
  const pkgRoot = fileURLToPath(new URL(pkg.rootUri.endsWith('/') ? pkg.rootUri : `${pkg.rootUri}/`, pathToFileURL(pcFile)));
  const src = fs.readFileSync(path.join(pkgRoot, 'lib', 'src', 'google_fonts_parts', 'part_i.g.dart'), 'utf8');
  const from = src.indexOf('static TextStyle inter({');
  const to = src.indexOf('static TextTheme interTextTheme');
  const re = /FontWeight\.w(\d+),\s*fontStyle: FontStyle\.normal,\s*\): GoogleFontsFile\(\s*'([0-9a-f]{64})',\s*(\d+),/g;
  const section = src.slice(from, to);
  let m;
  const wanted = (csv(args.weights, ['400', '500', '600', '700', '800', '900'])).map(Number);
  while ((m = re.exec(section))) {
    const [weight, hash, length] = [+m[1], m[2], +m[3]];
    if (!wanted.includes(weight)) continue;
    const file = path.join(fontsDir, `Inter-${INTER_NAMES[weight]}.ttf`);
    if (fs.existsSync(file) && fs.statSync(file).size === length) continue;
    const r = await fetch(`https://fonts.gstatic.com/s/a/${hash}.ttf`);
    if (!r.ok) throw new Error(`font download failed (${r.status}) for Inter w${weight}`);
    const buf = Buffer.from(await r.arrayBuffer());
    if (crypto.createHash('sha256').update(buf).digest('hex') !== hash) throw new Error(`sha256 mismatch for Inter w${weight}`);
    fs.writeFileSync(file, buf);
    log(`downloaded Inter ${INTER_NAMES[weight]} (${buf.length} bytes)`);
  }
  return fontsDir;
}

/** Adds `- google_fonts/` to the snapshot's flutter.assets list and copies the fonts there. */
function bundleFontsIntoSnapshot(snap, fontsDir) {
  const target = path.join(snap, 'google_fonts');
  copyDir(fontsDir, target);
  const pubspec = path.join(snap, 'pubspec.yaml');
  let text = fs.readFileSync(pubspec, 'utf8');
  if (text.includes('google_fonts/')) return;
  const eol = text.includes('\r\n') ? '\r\n' : '\n';
  const lines = text.split(/\r?\n/);
  const at = lines.findIndex((l) => /^ {2}assets:\s*$/.test(l));
  if (at >= 0) {
    let last = at;
    while (/^ {4}- /.test(lines[last + 1] || '')) last++;
    lines.splice(last + 1, 0, '    - google_fonts/');
  } else {
    const flutterAt = lines.findIndex((l) => /^flutter:\s*$/.test(l));
    if (flutterAt < 0) throw new Error('pubspec.yaml has no flutter: section');
    lines.splice(flutterAt + 1, 0, '  assets:', '    - google_fonts/');
  }
  text = lines.join(eol);
  fs.writeFileSync(pubspec, text);
}

async function golden() {
  const src = String(args.src || 'working');
  if (!['working', 'head'].includes(src)) throw new Error('golden: --src must be working|head');
  const dir = path.join(repo, 'build', `preview_golden_${src}`);
  const tag = String(args.tag || 'golden');
  const outDir = path.join(repo, 'build', 'preview_shots', tag);
  fs.mkdirSync(outDir, { recursive: true });
  const t0 = Date.now();

  await prepareSnapshot(src, dir);
  await ensureDeps(dir);
  if (!args['skip-analyze']) await preflight(dir, src);
  bundleFontsIntoSnapshot(dir, await ensureInterFonts(dir));

  const fa = ['test', 'tool/preview/golden/preview_golden_test.dart', '--no-pub', '--reporter', 'expanded'];
  if (src === 'head') fa.push('--dart-define=PREVIEW_LEGACY_ROLES=true');
  const env = {
    PREVIEW_GOLDEN_OUT: outDir,
    PREVIEW_GOLDEN_SCREENS: csv(args.screens, ['dashboard', 'settings', 'login']).join(','),
    PREVIEW_GOLDEN_THEMES: csv(args.themes, ['dark', 'light']).join(','),
    PREVIEW_GOLDEN_SCENARIOS: csv(args.scenarios, ['default']).join(','),
  };
  if (typeof args.size === 'string') env.PREVIEW_GOLDEN_SIZE = args.size;
  log(`flutter ${fa.join(' ')}   (cwd ${path.relative(repo, dir)})`);
  const r = await run('flutter', fa, { cwd: dir, env, echo: !!args.verbose });
  fs.writeFileSync(path.join(dir, 'preview_golden.log'), r.output);
  const wrote = r.output.split('\n').filter((l) => l.includes('PREVIEW_GOLDEN wrote'));
  wrote.forEach((l) => log(l.replace(/^.*PREVIEW_GOLDEN wrote /, 'wrote ')));
  if (r.code !== 0) {
    console.error(r.output.split('\n').slice(-60).join('\n'));
    console.error(`\nGOLDEN RUN FAILED after ${((Date.now() - t0) / 1000).toFixed(0)}s (exit ${r.code}). Log: build/preview_golden_${src}/preview_golden.log`);
    process.exit(2);
  }
  log(`golden OK in ${((Date.now() - t0) / 1000).toFixed(0)}s: ${wrote.length} PNG(s) -> ${path.relative(repo, outDir)}`);
}

// ----------------------------------------------------------------------------- static server
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.ico': 'image/x-icon', '.svg': 'image/svg+xml', '.css': 'text/css', '.ttf': 'font/ttf', '.otf': 'font/otf',
  '.woff': 'font/woff', '.woff2': 'font/woff2', '.txt': 'text/plain', '.map': 'application/json',
};

function startServer(root, port = 0) {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    let rel = decodeURIComponent(u.pathname);
    if (rel.endsWith('/')) rel += 'index.html';
    const file = path.normalize(path.join(root, rel));
    if (!file.startsWith(root)) { res.writeHead(403); return res.end(); }
    fs.stat(file, (err, st) => {
      if (err || !st.isFile()) { res.writeHead(404); return res.end('not found'); }
      res.writeHead(200, {
        'content-type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream',
        'content-length': st.size,
        'cache-control': 'no-store',
      });
      fs.createReadStream(file).pipe(res);
    });
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve({ server, port: server.address().port })));
}

// ----------------------------------------------------------------------------- puppeteer plumbing
async function loadPuppeteer() {
  const candidates = [
    here,
    process.env.PUPPETEER_CORE_DIR,
    path.join(repo, 'tools'),
    'C:/Users/FINGON~1/AppData/Local/Temp/claude/g--site-site-kapi-kontrol/a379bdb3-93a0-4167-8a2c-eed43f0e926f/scratchpad/promo',
  ].filter(Boolean);
  for (const dir of candidates) {
    const entry = path.join(dir, 'node_modules', 'puppeteer-core', 'lib', 'puppeteer', 'puppeteer-core.js');
    if (!fs.existsSync(entry)) continue;
    // NOTE: load the ESM entry with import(); require()-ing it made browser.close() hang for minutes (puppeteer-core 25, Node 24).
    const mod = await import(pathToFileURL(entry).href);
    return mod.default || mod;
  }
  throw new Error(`puppeteer-core not found. Run: npm i --prefix tool/preview puppeteer-core   (or set PUPPETEER_CORE_DIR). Tried: ${candidates.join(', ')}`);
}

/**
 * browser.close() with a safety net. On this setup (Windows, Chrome 154, puppeteer-core 25) the graceful
 * shutdown regularly stalls for 15 s .. minutes, so wait briefly and then kill the whole process tree.
 */
async function closeBrowser(browser) {
  const proc = browser.process?.();
  const pid = proc?.pid;
  await Promise.race([browser.close().catch(() => {}), new Promise((r) => setTimeout(r, 4000))]);
  if (pid && proc.exitCode === null) {
    if (isWin) spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
    else { try { process.kill(pid, 'SIGKILL'); } catch { /* already gone */ } }
  }
}

function findChrome() {
  const list = [
    process.env.CHROME_PATH,
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    '/usr/bin/google-chrome', '/usr/bin/chromium', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  ].filter(Boolean);
  const found = list.find((p) => fs.existsSync(p));
  if (!found) throw new Error('No Chrome/Edge found. Set CHROME_PATH.');
  return found;
}

const ANDROID_UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Mobile Safari/537.36';
const VIEWPORTS = {
  phone: { width: 390, height: 844, deviceScaleFactor: 2, isMobile: true, hasTouch: true, ua: ANDROID_UA },
  'phone-small': { width: 360, height: 740, deviceScaleFactor: 2, isMobile: true, hasTouch: true, ua: ANDROID_UA },
  'phone-long': { width: 390, height: 2000, deviceScaleFactor: 2, isMobile: true, hasTouch: true, ua: ANDROID_UA },
  tablet: { width: 820, height: 1180, deviceScaleFactor: 2, isMobile: true, hasTouch: true, ua: ANDROID_UA },
  desktop: { width: 1280, height: 800, deviceScaleFactor: 1, isMobile: false, hasTouch: false, ua: null },
};
function viewportFor(name) {
  if (VIEWPORTS[name]) return VIEWPORTS[name];
  const m = /^(\d+)x(\d+)(?:@(\d+(?:\.\d+)?))?$/.exec(name);
  if (!m) throw new Error(`unknown viewport "${name}" (use ${Object.keys(VIEWPORTS).join('|')} or WxH[@dpr])`);
  return { width: +m[1], height: +m[2], deviceScaleFactor: m[3] ? +m[3] : 1, isMobile: +m[1] < 700, hasTouch: +m[1] < 700, ua: +m[1] < 700 ? ANDROID_UA : null };
}

const API_HOST = 'evotomasyon.gudeteknoloji.com.tr';
const CACHEABLE_HOSTS = new Set(['fonts.gstatic.com', 'www.gstatic.com', 'fonts.googleapis.com']);
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS' };

function makeNetworkHandler(net) {
  const cacheDir = process.env.PREVIEW_CACHE_DIR || path.join(repo, 'build', 'preview_cache');
  fs.mkdirSync(cacheDir, { recursive: true });
  const bump = (host, kind) => { net[host] ||= {}; net[host][kind] = (net[host][kind] || 0) + 1; };
  return async (req) => {
    const url = new URL(req.url());
    const host = url.hostname;
    if (url.protocol === 'data:' || url.protocol === 'blob:' || host === 'localhost' || host === '127.0.0.1') return req.continue();
    if (req.method() === 'OPTIONS') return req.respond({ status: 204, headers: CORS });
    if (CACHEABLE_HOSTS.has(host)) {
      const key = crypto.createHash('sha1').update(req.url()).digest('hex');
      const body = path.join(cacheDir, `${key}.bin`);
      const meta = path.join(cacheDir, `${key}.json`);
      try {
        if (!fs.existsSync(body)) {
          const r = await fetch(req.url(), { headers: { 'user-agent': req.headers()['user-agent'] || 'Mozilla/5.0' } });
          if (!r.ok) { bump(host, `http${r.status}`); return req.respond({ status: r.status, headers: CORS, body: '' }); }
          fs.writeFileSync(body, Buffer.from(await r.arrayBuffer()));
          fs.writeFileSync(meta, JSON.stringify({ url: req.url(), type: r.headers.get('content-type') || 'application/octet-stream' }));
          bump(host, 'downloaded');
        } else bump(host, 'cache_hit');
        const type = JSON.parse(fs.readFileSync(meta, 'utf8')).type;
        return req.respond({ status: 200, headers: { ...CORS, 'content-type': type, 'cache-control': 'no-store' }, body: fs.readFileSync(body) });
      } catch {
        bump(host, 'error');
        return req.abort('failed');
      }
    }
    if (host === API_HOST) {
      bump(host, 'stubbed_503');
      net.__leaks ||= [];
      if (net.__leaks.length < 40) net.__leaks.push(`${req.method()} ${url.pathname}`);
      return req.respond({ status: 503, headers: { ...CORS, 'content-type': 'application/json' }, body: JSON.stringify({ success: false, message: 'preview: network disabled', code: 'PREVIEW_OFFLINE' }) });
    }
    bump(host, 'blocked');
    return req.abort('blockedbyclient');
  };
}

// ----------------------------------------------------------------------------- shoot
async function shoot() {
  const src = String(args.src || 'working');
  const web = webDirFor(src);
  if (!fs.existsSync(path.join(web, 'index.html'))) throw new Error(`no web build at ${web}. Run: node tool/preview/preview.mjs build --src ${src}`);
  const tag = String(args.tag || 'latest');
  const outDir = path.join(repo, 'build', 'preview_shots', tag);
  fs.mkdirSync(outDir, { recursive: true });

  const screens = csv(args.screens, ['dashboard', 'settings', 'login']);
  const themes = csv(args.themes, ['dark', 'light']);
  const viewports = csv(args.viewports, ['phone']);
  const scenarios = csv(args.scenarios, ['default']);
  const shell = args.shell ? String(args.shell) : '';
  const timeoutMs = (+args.timeout || 120) * 1000;
  const perf = !!args.perf;
  const extra = new URLSearchParams(typeof args.query === 'string' ? args.query : '');
  if (args.insets) extra.set('insets', args.insets === true ? '30,24' : String(args.insets));
  const suffix = args.suffix !== undefined
    ? (args.suffix === true ? '' : `-${args.suffix}`)
    : (extra.size ? `-${[...extra].map(([k, v]) => `${k}${v}`).join('-').replace(/[^A-Za-z0-9.-]+/g, '')}` : '');
  const scrollPx = +args.scroll || 0;
  const extraWaitMs = +args.wait || 0;

  const puppeteer = await loadPuppeteer();
  const chrome = findChrome();
  const { server, port } = await startServer(web, 0);
  log(`serving ${path.relative(repo, web)} on http://127.0.0.1:${port}  chrome=${chrome}`);

  const glArgs = args.gpu ? [] : ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'];
  const browser = await puppeteer.launch({
    executablePath: chrome,
    headless: true,
    args: ['--no-sandbox', '--hide-scrollbars', '--force-color-profile=srgb', '--disable-background-timer-throttling', '--disable-renderer-backgrounding', ...glArgs],
  });

  const report = { src, web: path.relative(repo, web), tag, startedAt: new Date().toISOString(), shots: [] };
  let failures = 0;
  try {
    for (const vpName of viewports) for (const scenario of scenarios) for (const screen of screens) for (const theme of themes) {
      const vp = viewportFor(vpName);
      const name = `${screen}-${theme}${scenario === 'default' ? '' : '-' + scenario}${shell === 'app' ? '-app' : ''}${suffix}${scrollPx ? '-scroll' + scrollPx : ''}-${vpName}`;
      const key = `${screen}:${theme}:${scenario}`;
      const ctx = await browser.createBrowserContext(); // fresh localStorage / IndexedDB per shot
      const page = await ctx.newPage();
      const net = {};
      const consoleErrors = [];
      const entry = { name, screen, theme, scenario, viewport: vpName, ok: false };
      try {
        await page.setViewport({ width: vp.width, height: vp.height, deviceScaleFactor: vp.deviceScaleFactor, isMobile: vp.isMobile, hasTouch: vp.hasTouch });
        if (vp.ua) await page.setUserAgent(vp.ua);
        await page.setBypassServiceWorker(true);
        await page.setRequestInterception(true);
        const handler = makeNetworkHandler(net);
        page.on('request', (r) => { handler(r).catch(() => { try { r.abort('failed'); } catch { /* already handled */ } }); });
        page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) consoleErrors.push(`[${m.type()}] ${m.text()}`.slice(0, 500)); });
        page.on('pageerror', (e) => consoleErrors.push(`[pageerror] ${String(e)}`.slice(0, 500)));

        const qs = new URLSearchParams({ screen, theme, scenario });
        if (shell) qs.set('shell', shell);
        if (perf) qs.set('perf', '1');
        for (const [k, v] of extra) qs.set(k, v);
        if (screen === 'splash' && !qs.has('freeze')) qs.set('freeze', '1'); // endless spinner: freeze for a stable frame
        entry.query = qs.toString();
        const t0 = Date.now();
        await page.goto(`http://127.0.0.1:${port}/?${qs}`, { waitUntil: 'load', timeout: timeoutMs });
        await page.waitForFunction((k) => window.__previewReady === k, { timeout: timeoutMs, polling: 100 }, key);
        entry.readyMs = Date.now() - t0;
        const info = await page.evaluate(() => { try { return JSON.parse(window.__previewInfo || '{}'); } catch { return {}; } });
        await new Promise((r) => setTimeout(r, 250 + extraWaitMs));
        if (scrollPx) {
          await page.mouse.move(vp.width / 2, vp.height / 2);
          for (let done = 0; done < scrollPx; done += 200) { await page.mouse.wheel({ deltaY: Math.min(200, scrollPx - done) }); await new Promise((r) => setTimeout(r, 60)); }
          await new Promise((r) => setTimeout(r, 600));
        }
        const file = path.join(outDir, `${name}.png`);
        await page.screenshot({ path: file, type: 'png' });
        entry.ok = true;
        entry.file = path.relative(repo, file);
        entry.info = info;
        if (perf) {
          // scroll while the harness hammers the state, then collect the frame timings
          await page.mouse.move(vp.width / 2, vp.height / 2);
          for (let i = 0; i < 12; i++) { await page.mouse.wheel({ deltaY: i < 6 ? 260 : -260 }); await new Promise((r) => setTimeout(r, 200)); }
          await page.waitForFunction(() => !!window.__previewPerf, { timeout: 30000, polling: 200 }).catch(() => {});
          entry.perf = await page.evaluate(() => { try { return JSON.parse(window.__previewPerf || 'null'); } catch { return null; } });
        }
        log(`OK  ${name}  ${entry.readyMs}ms  idle=${info.idle} fonts=${info.fontsOk} platform=${info.platform} dartErrors=${(info.errors || []).length}`);
      } catch (e) {
        failures++;
        entry.error = String(e.message || e);
        try { await page.screenshot({ path: path.join(outDir, `${name}.FAILED.png`) }); } catch { /* ignore */ }
        log(`FAIL ${name}: ${entry.error}`);
      } finally {
        entry.net = net;
        entry.consoleErrors = consoleErrors.slice(0, 30);
        report.shots.push(entry);
        await Promise.race([ctx.close().catch(() => {}), new Promise((r) => setTimeout(r, 8000))]);
      }
    }
  } finally {
    await closeBrowser(browser);
    server.closeAllConnections?.();
    server.close();
  }
  report.finishedAt = new Date().toISOString();
  report.failures = failures;
  fs.writeFileSync(path.join(outDir, 'report.json'), JSON.stringify(report, null, 2));
  const leaks = report.shots.flatMap((s) => s.net?.__leaks || []);
  log(`done: ${report.shots.length - failures}/${report.shots.length} shots -> ${path.relative(repo, outDir)}  (report.json: console errors + network summary)`);
  if (leaks.length) log(`NOTE: ${leaks.length} request(s) tried to reach the production API (stubbed 503): ${[...new Set(leaks)].slice(0, 5).join(', ')}`);
  if (failures) process.exitCode = 3;
}

// ----------------------------------------------------------------------------- compare (before/after)
async function compare() {
  const a = String(args.a || 'before');
  const b = String(args.b || 'after');
  const dirA = path.join(repo, 'build', 'preview_shots', a);
  const dirB = path.join(repo, 'build', 'preview_shots', b);
  const outDir = path.join(repo, 'build', 'preview_shots', `compare_${a}_vs_${b}`);
  fs.mkdirSync(outDir, { recursive: true });
  const names = fs.readdirSync(dirA).filter((f) => f.endsWith('.png') && !f.endsWith('.FAILED.png') && fs.existsSync(path.join(dirB, f)));
  const puppeteer = await loadPuppeteer();
  const browser = await puppeteer.launch({ executablePath: findChrome(), headless: true, args: ['--no-sandbox'] });
  const rows = [];
  try {
    const page = await browser.newPage();
    await page.goto('about:blank');
    for (const f of names) {
      const A = fs.readFileSync(path.join(dirA, f)).toString('base64');
      const B = fs.readFileSync(path.join(dirB, f)).toString('base64');
      const res = await page.evaluate(async (ab, bb) => {
        const load = (b64) => new Promise((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = no; i.src = 'data:image/png;base64,' + b64; });
        const [ia, ib] = await Promise.all([load(ab), load(bb)]);
        const w = Math.max(ia.width, ib.width), h = Math.max(ia.height, ib.height);
        const mk = (img) => { const c = document.createElement('canvas'); c.width = w; c.height = h; const x = c.getContext('2d', { willReadFrequently: true }); x.drawImage(img, 0, 0); return x; };
        const xa = mk(ia), xb = mk(ib);
        const da = xa.getImageData(0, 0, w, h).data, db = xb.getImageData(0, 0, w, h).data;
        const out = document.createElement('canvas'); out.width = w * 3; out.height = h;
        const xo = out.getContext('2d');
        xo.drawImage(ia, 0, 0); xo.drawImage(ib, w, 0);
        const diff = xo.createImageData(w, h);
        let changed = 0;
        for (let i = 0; i < da.length; i += 4) {
          const d = Math.abs(da[i] - db[i]) + Math.abs(da[i + 1] - db[i + 1]) + Math.abs(da[i + 2] - db[i + 2]);
          if (d > 24) { changed++; diff.data[i] = 255; diff.data[i + 1] = 0; diff.data[i + 2] = 80; diff.data[i + 3] = 255; }
          else { diff.data[i] = da[i] * 0.25; diff.data[i + 1] = da[i + 1] * 0.25; diff.data[i + 2] = da[i + 2] * 0.25; diff.data[i + 3] = 255; }
        }
        xo.putImageData(diff, w * 2, 0);
        return { w, h, changedPct: +(changed * 100 / (w * h)).toFixed(3), png: out.toDataURL('image/png').split(',')[1], sizeA: [ia.width, ia.height], sizeB: [ib.width, ib.height] };
      }, A, B);
      fs.writeFileSync(path.join(outDir, f), Buffer.from(res.png, 'base64'));
      rows.push({ name: f, changedPct: res.changedPct, sizeA: res.sizeA, sizeB: res.sizeB });
      log(`${f.padEnd(52)} ${res.changedPct}% pixels changed`);
    }
  } finally { await closeBrowser(browser); }
  fs.writeFileSync(path.join(outDir, 'compare.json'), JSON.stringify(rows, null, 2));
  log(`compare images (before | after | diff) -> ${path.relative(repo, outDir)}`);
}

// ----------------------------------------------------------------------------- serve
async function serve() {
  const src = String(args.src || 'working');
  const web = webDirFor(src);
  const { port } = await startServer(web, +args.port || 8765);
  log(`http://localhost:${port}/?screen=dashboard&theme=dark   (screens: dashboard settings login splash biometric; scenarios: default locked quiet offline empty many peace_off peace_notime)`);
  await new Promise(() => {});
}

// ----------------------------------------------------------------------------- main
try {
  if (cmd === 'build') await build();
  else if (cmd === 'shoot') await shoot();
  else if (cmd === 'all') { await build(); await shoot(); }
  else if (cmd === 'serve') await serve();
  else if (cmd === 'compare') await compare();
  else if (cmd === 'golden') await golden();
  else {
    console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1, 47).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
  }
  // Child processes (Chrome helpers, flutter) can keep the event loop alive for a long time: leave explicitly.
  process.exit(process.exitCode ?? 0);
} catch (e) {
  console.error(String(e.stack || e));
  process.exit(1);
}
