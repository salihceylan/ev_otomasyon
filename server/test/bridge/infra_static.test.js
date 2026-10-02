'use strict';

// C8 - Altyapi dosyalari icin STATIK denetimler (bu makinede Docker / EMQX / nginx / PostgreSQL
// YOKTUR; yapilandirmalar calistirilamaz). Amac: sozdizimsel tutarlilik, sirsiz depo, sozlesme
// uyumu (kod SQL'i <-> migration semasi), silinmesi gereken dosyalarin gercekten silinmis olmasi.
// "Calisiyor" kaniti DEGILDIR; hazirlik ortami dogrulamasi gerekir (bkz. rapor).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { listMigrationFiles, maskSql, MIGRATIONS_DIR } = require('../../scripts/migrate');

const SERVER = path.join(__dirname, '..', '..');
const read = (...p) => fs.readFileSync(path.join(SERVER, ...p), 'utf8');
const exists = (...p) => fs.existsSync(path.join(SERVER, ...p));

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === 'node_modules' || e.name.startsWith('.')) continue;
    const full = path.join(dir, e.name);
    if (e.isDirectory()) walk(full, out);
    else out.push(full);
  }
  return out;
}

// ------------------------------------------------------------------------------
// Silinmesi gereken dosyalar (sabit parola / baglanti dizesi iceriyorlardi)
// ------------------------------------------------------------------------------
test('eski calistirma betikleri, tohumlar ve parolali altyapi dosyalari SILINMIS', () => {
  const removed = [
    ['run_migration_007.js'],
    ['run_migration_008.js'],
    ['run_migration_009.js'],
    ['run_migration_010.js'],
    ['init_mqtt_users.sql'],
    ['migrations', 'run_011.js'],
    ['migrations', 'run_012.js'],
    ['migrations', 'run_013.js'],
    ['migrations', 'run_016.js'],
    ['migrations', 'run_017.js'],
    ['migrations', 'list_tables.js'],
    ['migrations', 'list_demo_users.js'],
    ['migrations', 'seed_demo_credentials.js'],
    ['migrations', '002_seed_initial_data.sql'],
    ['emqx_config', 'add_users.sh'],
    ['emqx_config', 'import.sh'],
    ['emqx_config', 'auth-built-in-db-bootstrap.csv'],
    ['emqx_config', 'test_inspect.escript'],
    ['emqx_config', 'authn_pg.hocon'],
    ['emqx_config', 'authz.hocon'],
  ];
  for (const p of removed) assert.equal(exists(...p), false, `${p.join('/')} silinmis olmali`);
  // uretim migration dizininde calistirici betik kalmadi (yalnizca .sql + dev_seeds)
  const top = fs.readdirSync(MIGRATIONS_DIR, { withFileTypes: true }).filter((e) => e.isFile()).map((e) => e.name);
  assert.deepEqual(top.filter((n) => !n.endsWith('.sql')), []);
});

// ------------------------------------------------------------------------------
// Depoda sir yok (yapisal desenler; gercek sir DEGERLERI bu dosyada bulunmaz)
// ------------------------------------------------------------------------------
function ownedFiles() {
  const files = [];
  files.push(path.join(SERVER, 'docker-compose.yml'));
  for (const dir of ['emqx_config', 'nginx', 'scripts', path.join('migrations', 'dev_seeds')]) {
    files.push(...walk(path.join(SERVER, dir)));
  }
  // eski migration'lar (001-017) ve WP-C migration'lari (010b, 022+); 018-021 baska paketlerin
  for (const f of listMigrationFiles(MIGRATIONS_DIR)) {
    // WP-C'nin migration araligi: 010b ve 022-029 (baska paketlerin 018-021 / 030+ dosyalari kapsam disi)
    if (f.version <= 17 || (f.version >= 22 && f.version <= 29)) files.push(path.join(MIGRATIONS_DIR, f.name));
  }
  for (const rel of ['src/mqtt_bridge.js', 'src/scheduler.js', 'src/services/scheduled_rules_service.js', 'src/routes/scheduled_rules_routes.js']) {
    files.push(path.join(SERVER, rel));
  }
  return files;
}

test('sir taramasi: baglanti dizesinde parola, gomulu bcrypt/SHA-256 ozeti, duz metin parola atamasi YOK', () => {
  const issues = [];
  for (const file of ownedFiles()) {
    const text = fs.readFileSync(file, 'utf8');
    const rel = path.relative(SERVER, file);

    for (const m of text.matchAll(/postgres(?:ql)?:\/\/[^:\s'"@/]+:([^@\s'"]+)@/gi)) {
      if (!/^[$<{*%]/.test(m[1])) issues.push(`${rel}: baglanti dizesinde duz parola`);
    }
    if (/\$2[aby]\$\d{2}\$[./A-Za-z0-9]{53}/.test(text)) issues.push(`${rel}: gomulu bcrypt ozeti`);
    // 64 hex (SHA-256 / HMAC): script ve SQL'de gomulu olmamali (checksum yalniz calisma aninda uretilir)
    if (/\b[0-9a-f]{64}\b/i.test(text)) issues.push(`${rel}: gomulu 64 haneli hex ozet`);
    for (const m of text.matchAll(/\b(password|passwd|secret|api[_-]?key|token)\s*[:=]\s*(['"])([^'"\n]{6,})\2/gi)) {
      const v = m[3];
      if (/^[$<{]/.test(v) || /\b(ortam|environment|placeholder|degil)\b/i.test(v)) continue;
      issues.push(`${rel}: duz metin "${m[1]}" atamasi`);
    }
  }
  assert.deepEqual(issues, []);
});

test('depodaki yonetim betikleri sabit baglanti dizesi/varsayilan sunucu icermez (yalnizca DATABASE_URL)', () => {
  for (const file of walk(path.join(SERVER, 'scripts'))) {
    if (!file.endsWith('.js')) continue;
    const text = fs.readFileSync(file, 'utf8');
    // `|| 'postgres://...'` gibi yedek baglanti dizesi yok
    assert.doesNotMatch(text, /\|\|\s*['"`]postgres/i, `${file}: yedek baglanti dizesi`);
    assert.doesNotMatch(text, /localhost:5432|127\.0\.0\.1:543\d/, `${path.relative(SERVER, file)}: sabit sunucu`);
  }
  const target = read('scripts', 'lib', 'target.js');
  assert.match(target, /MIGRATE_CONFIRM/);
});

// ------------------------------------------------------------------------------
// docker-compose.yml
// ------------------------------------------------------------------------------
test('docker-compose: sir yok, ${VAR:?} ile zorunlu, kok kullanici yok, Redis yok, genis sertifika baglamasi yok', () => {
  const y = read('docker-compose.yml');
  const code = y.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');

  for (const v of ['POSTGRES_PASSWORD', 'EMQX_DASHBOARD_PASSWORD', 'EMQX_AUTHDB_PASSWORD', 'EMQX_CERT_DIR']) {
    assert.match(code, new RegExp(`\\$\\{${v}:\\?[^}]+\\}`), `${v} \${${v}:?...} ile zorunlu olmali`);
  }
  // her *_PASSWORD / *PASS anahtari degisken referansi olmali (duz deger yok)
  for (const m of code.matchAll(/^\s*([A-Z0-9_]*PASS(?:WORD)?[A-Z0-9_]*):\s*(.+)$/gm)) {
    assert.match(m[2].trim(), /^\$\{[A-Z0-9_]+(:[-?][^}]*)?\}$/, `${m[1]} duz metin deger iceremez`);
  }
  assert.doesNotMatch(code, /^\s*user:/m, 'kapsayici root/ozel kullanici zorlamasi olmamali (user: "0:0" kaldirildi)');
  assert.doesNotMatch(code, /redis/i, 'kullanilmayan Redis kaldirildi');
  assert.doesNotMatch(code, /\/etc\/letsencrypt/, 'tum /etc/letsencrypt baglanmamali');
  assert.doesNotMatch(code, /privileged:\s*true/);
  assert.match(code, /^name:\s*ev_otomasyon\s*$/m, 'proje adi sabit (dizin adina bagli olmasin)');
  assert.doesNotMatch(code, /^version:/m);
});

test('docker-compose: yalnizca MQTTS (8884) dis agda; Postgres / duz MQTT / panel yalnizca 127.0.0.1', () => {
  const y = read('docker-compose.yml').split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
  const ports = [...y.matchAll(/^\s*-\s*"([^"]*:\d+:\d+)"\s*$/gm)].map((m) => m[1]);
  assert.deepEqual(ports.sort(), ['${EMQX_TLS_BIND_ADDR:-0.0.0.0}:8884:8883', '127.0.0.1:1884:1883', '127.0.0.1:18084:18083', '127.0.0.1:5434:5432'].sort());
  const external = ports.filter((p) => !p.startsWith('127.0.0.1:'));
  assert.deepEqual(external, ['${EMQX_TLS_BIND_ADDR:-0.0.0.0}:8884:8883']);
  // uretimdeki kapi sisteminin portlari (1883/8883 Mosquitto) hicbir yerde yayinlanmaz
  assert.doesNotMatch(y, /"(0\.0\.0\.0:)?(1883|8883):/);
});

test('docker-compose: baglanan dosyalar mevcut; saglik kontrolu, kaynak siniri, guvenlik secenekleri var', () => {
  const y = read('docker-compose.yml').split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
  for (const m of y.matchAll(/^\s*-\s*(\.\/[^:\s]+):\/opt\/emqx\/[^\s]*$/gm)) {
    assert.ok(exists(m[1].replace('./', '')), `${m[1]} bulunamadi (compose yolu yanlis)`);
  }
  assert.match(y, /\.\/emqx_config\/acl\.conf:\/opt\/emqx\/etc\/acl\.conf:ro/);
  assert.match(y, /\.\/emqx_config\/emqx\.conf:\/opt\/emqx\/etc\/emqx\.conf:ro/);
  assert.match(y, /\$\{EMQX_CERT_DIR[^}]*\}:\/opt\/emqx\/etc\/certs:ro/);
  assert.equal((y.match(/healthcheck:/g) || []).length, 2);
  assert.equal((y.match(/mem_limit:/g) || []).length, 2);
  assert.equal((y.match(/no-new-privileges:true/g) || []).length, 2);
  // healthcheck icindeki degiskenler $$ ile kapsayici icinde cozulur
  assert.match(y, /pg_isready -U \\"\$\$\{POSTGRES_USER\}\\"/);
});

test('docker-compose <-> emqx.conf: conf\'taki her ${EV_AUTHDB_*} compose ortaminda tanimli', () => {
  const compose = read('docker-compose.yml');
  const conf = read('emqx_config', 'emqx.conf');
  const used = new Set([...conf.matchAll(/\$\{(EV_[A-Z0-9_]+)\}/g)].map((m) => m[1]));
  assert.deepEqual([...used].sort(), ['EV_AUTHDB_NAME', 'EV_AUTHDB_PASSWORD', 'EV_AUTHDB_SERVER', 'EV_AUTHDB_USER']);
  for (const v of used) assert.match(compose, new RegExp(`^\\s*${v}:`, 'm'), `${v} compose ortaminda yok`);
  // EMQX_ onekli rastgele degisken yok (EMQX bunlari yapilandirma gecersiz kilma sayar)
  for (const m of compose.matchAll(/^\s*(EMQX_[A-Z0-9_]+):/gm)) {
    assert.match(m[1], /^EMQX_(NODE__|DASHBOARD__)/, `${m[1]}: yalnizca bilinen EMQX gecersiz kilma anahtarlari`);
  }
});

// ------------------------------------------------------------------------------
// emqx.conf (HOCON) - sozdizimsel tutarlilik ve guvenlik ilkeleri
// ------------------------------------------------------------------------------
function hoconCode(text) {
  return text.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
}

test('emqx.conf: parantezler/koseli parantezler/tirnaklar dengeli, sekme yok, tek satirli degerler', () => {
  const text = read('emqx_config', 'emqx.conf');
  assert.doesNotMatch(text, /\t/, 'sekme karakteri yok');
  const code = hoconCode(text);
  // tirnaklar: her satirda kacissiz " sayisi cift
  for (const line of code.split('\n')) {
    const quotes = (line.match(/(?<!\\)"/g) || []).length;
    assert.equal(quotes % 2, 0, `tirnaklar dengesiz: ${line.slice(0, 80)}`);
  }
  // tirnak ici metni cikar, kalanda { } [ ] dengesi
  const stripped = code.replace(/"(?:[^"\\]|\\.)*"/g, '""');
  let brace = 0;
  let bracket = 0;
  for (const c of stripped) {
    if (c === '{') brace++;
    else if (c === '}') brace--;
    else if (c === '[') bracket++;
    else if (c === ']') bracket--;
    assert.ok(brace >= 0 && bracket >= 0, 'kapanis acilistan once');
  }
  assert.equal(brace, 0, '{ } dengeli degil');
  assert.equal(bracket, 0, '[ ] dengeli degil');
  assert.doesNotMatch(code, /^\s*[A-Za-z_.]+\s*=\s*$/m, 'bos deger atamasi yok');
});

test('emqx.conf: TLS 1.3/1.2, sinirlar, WebSocket kapali, no_match=deny, sirlar ortamdan', () => {
  const text = read('emqx_config', 'emqx.conf');
  const code = hoconCode(text);
  assert.match(code, /versions\s*=\s*\["tlsv1\.3",\s*"tlsv1\.2"\]/);
  assert.doesNotMatch(code, /tlsv1\.1|"tlsv1"/);
  assert.match(code, /max_packet_size\s*=\s*"16KB"/);
  assert.match(code, /no_match\s*=\s*deny/);
  assert.match(code, /mqueue_store_qos0\s*=\s*false/);
  assert.match(code, /certfile\s*=\s*"\/opt\/emqx\/etc\/certs\/fullchain\.pem"/);
  assert.match(code, /keyfile\s*=\s*"\/opt\/emqx\/etc\/certs\/privkey\.pem"/);
  // WebSocket dinleyicileri kapali
  assert.match(code, /ws\s*\{\s*default\s*\{\s*enable\s*=\s*false/);
  assert.match(code, /wss\s*\{\s*default\s*\{\s*enable\s*=\s*false/);
  // sirlar yalniz ortamdan: password = ${EV_AUTHDB_PASSWORD} (tirnaksiz yer koyma)
  const passwords = [...code.matchAll(/^\s*password\s*=\s*(.+)$/gm)].map((m) => m[1].trim());
  assert.ok(passwords.length >= 2);
  for (const p of passwords) assert.equal(p, '${EV_AUTHDB_PASSWORD}');
  // dis 8883 yalniz TLS: duz dinleyici 1883 (yalniz yerel baglanir) disinda 8883 TLS
  assert.match(code, /ssl\s*\{[\s\S]*?bind\s*=\s*"0\.0\.0\.0:8883"/);
});

test('emqx.conf kimlik: TEK PostgreSQL authenticator (bcrypt) + mqtt_credentials + yalniz yukseltilmis legacy', () => {
  const code = hoconCode(read('emqx_config', 'emqx.conf'));
  // EMQX 5: ayni (mechanism, backend) cifti zincirde YALNIZ BIR KEZ bulunabilir
  assert.equal((code.match(/mechanism\s*=/g) || []).length, 1);
  assert.match(code, /mechanism\s*=\s*password_based/);
  assert.match(code, /backend\s*=\s*postgresql/);
  assert.match(code, /password_hash_algorithm\s*\{\s*name\s*=\s*bcrypt\s*\}/);
  assert.doesNotMatch(code, /sha256|salt_position|plain|md5/, 'zayif ozet algoritmasi yok');

  const authn = /query\s*=\s*"(SELECT password_hash, is_superuser FROM \(.*?\) AS creds ORDER BY prio LIMIT 1)"/.exec(code);
  assert.ok(authn, 'kimlik sorgusu bulunamadi');
  const q = authn[1];
  assert.match(q, /FROM mqtt_credentials WHERE username = \$\{username\} AND \(expires_at IS NULL OR expires_at > NOW\(\)\)/);
  assert.match(q, /UNION ALL SELECT password_hash, FALSE AS is_superuser, 2 AS prio FROM mqtt_users WHERE username = \$\{username\}/);
  assert.match(q, /COALESCE\(is_superuser, FALSE\) = FALSE/, 'legacy superuser KABUL EDILMEZ');
  assert.match(q, /password_hash LIKE '\$2%'/, 'yalniz bcrypt\'e yukseltilmis legacy satirlar');
  assert.match(q, /ORDER BY prio LIMIT 1/);
  // yer tutucu sayisi: iki kaynak, ikisi de ${username}
  assert.equal((q.match(/\$\{username\}/g) || []).length, 2);
});

test('emqx.conf yetki: PostgreSQL mqtt_acl + dosya yedegi, sirasi PG -> dosya', () => {
  const code = hoconCode(read('emqx_config', 'emqx.conf'));
  const pg = code.indexOf('type = postgresql');
  const file = code.indexOf('type = file');
  assert.ok(pg > 0 && file > pg, 'PostgreSQL kaynagi dosyadan ONCE gelmeli');
  assert.match(code, /query\s*=\s*"SELECT permission, action, topic FROM mqtt_acl WHERE username = \$\{username\}"/);
  assert.match(code, /path\s*=\s*"\$\{EMQX_ETC_DIR\}\/acl\.conf"/);
});

test('sorgu sutunlari <-> 020/024 migration semasi (mqtt_credentials, mqtt_acl, mqtt_users)', () => {
  const schema = loadSchema();
  for (const c of ['username', 'password_hash', 'is_superuser', 'kind', 'expires_at']) assert.ok(schema.get('mqtt_credentials').has(c), `mqtt_credentials.${c}`);
  for (const c of ['username', 'permission', 'action', 'topic']) assert.ok(schema.get('mqtt_acl').has(c), `mqtt_acl.${c}`);
  for (const c of ['username', 'password_hash', 'is_superuser']) assert.ok(schema.get('mqtt_users').has(c), `mqtt_users.${c}`);
  // backend turu 020'de izinli (create_backend_mqtt_user.js)
  assert.match(read('migrations', '020_mqtt_credentials.sql'), /kind IN \('device', 'app', 'backend'\)/);
});

// ------------------------------------------------------------------------------
// acl.conf
// ------------------------------------------------------------------------------
test('acl.conf: her kural noktayla biter, genel izin yok, son kural deny all, legacy yalniz regex kisitli', () => {
  const lines = read('emqx_config', 'acl.conf').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('%'));
  assert.ok(lines.length >= 4);
  for (const l of lines) {
    assert.match(l, /^\{(allow|deny),.*\}\.$/, `gecersiz kural: ${l}`);
    // dengeli { } ve [ ]
    assert.equal((l.match(/\{/g) || []).length, (l.match(/\}/g) || []).length, l);
    assert.equal((l.match(/\[/g) || []).length, (l.match(/\]/g) || []).length, l);
  }
  assert.equal(lines[lines.length - 1], '{deny, all}.');
  assert.equal(lines.some((l) => /^\{allow,\s*all\b/.test(l)), false, '"allow all" kurali olmamali');
  const legacy = lines.filter((l) => /home_/.test(l));
  assert.equal(legacy.length, 1);
  assert.match(legacy[0], /^\{allow, \{username, \{re, "\^home_\[A-Za-z0-9\]\+\$"\}\}, all, \["ev\/\$\{username\}\/#"\]\}\.$/);
  assert.ok(lines.some((l) => /^\{allow, \{username, "backend_service"\}, all, \["ev\/#"\]\}\.$/.test(l)), 'backend kurali');
  assert.ok(lines.some((l) => /^\{deny, all, subscribe,/.test(l) && l.includes('$SYS/#') && l.includes('{eq, "#"}')), 'joker/sistem aboneligi yasagi');
  // eski paylasilan joker kural (herkes ev/<kullanici>/# her seyi yapar) kalmadi
  assert.equal(lines.some((l) => /^\{allow, all, all,/.test(l)), false);
});

// ------------------------------------------------------------------------------
// nginx
// ------------------------------------------------------------------------------
test('nginx: dengeli, dogru sonlanan direktifler, TLS/HSTS/sinirlar, yalniz 127.0.0.1:5000, benzersiz adlar', () => {
  const text = read('nginx', 'evotomasyon.gudeteknoloji.com.tr.conf');
  const code = text.split('\n').filter((l) => !/^\s*#/.test(l));
  for (const line of code.map((l) => l.trim()).filter(Boolean)) {
    assert.match(line, /(;|\{|\})$/, `direktif ; { } ile bitmeli: ${line}`);
  }
  let depth = 0;
  for (const c of code.join('\n')) {
    if (c === '{') depth++;
    else if (c === '}') depth--;
    assert.ok(depth >= 0);
  }
  assert.equal(depth, 0);
  const joined = code.join('\n');

  assert.match(joined, /listen 443 ssl http2;/);
  assert.match(joined, /ssl_protocols TLSv1\.2 TLSv1\.3;/);
  assert.doesNotMatch(joined, /TLSv1\.1|TLSv1;|SSLv/);
  assert.match(joined, /add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;/);
  assert.match(joined, /client_max_body_size 256k;/);
  assert.match(joined, /return 301 https:\/\/\$host\$request_uri;/);
  assert.doesNotMatch(joined, /default_server/, 'baska sitelerin varsayilan sunucusu olunmamali');
  assert.equal(((joined.match(/server_name\s+([^;]+);/g)) || []).every((s) => /evotomasyon\.gudeteknoloji\.com\.tr/.test(s)), true);

  // yalnizca yerel uygulamaya proxy
  const targets = [...joined.matchAll(/proxy_pass\s+([^;]+);/g)].map((m) => m[1]);
  assert.ok(targets.length >= 2);
  assert.equal(targets.every((t) => t === 'http://127.0.0.1:5000'), true);

  // zaman asimlari
  for (const d of ['proxy_connect_timeout', 'proxy_read_timeout', 'proxy_send_timeout', 'client_body_timeout', 'client_header_timeout', 'send_timeout', 'keepalive_timeout']) {
    assert.match(joined, new RegExp(`${d}\\s+\\d+s;`), d);
  }
  // hiz siniri bolgeleri ve map degiskeni EV'e ozgu adlar (http baglaminda cakismasin)
  for (const m of joined.matchAll(/limit_req_zone\s+\S+\s+zone=([a-z_]+):/g)) assert.match(m[1], /^evotomasyon_/);
  for (const m of joined.matchAll(/limit_req\s+zone=([a-z_]+)/g)) assert.match(m[1], /^evotomasyon_/);
  assert.match(joined, /map \$http_upgrade \$ev_connection_upgrade/);
  assert.doesNotMatch(joined, /\$connection_upgrade\b/, 'genel $connection_upgrade adi baska sitelerle cakisabilir');
  assert.match(joined, /ssl_session_cache shared:EVSSL:/);
  // limit_req_status http duzeyinde (girintisiz) OLMAMALI: baska sitelerin davranisini degistirir
  assert.equal(code.some((l) => /^limit_req_status/.test(l)), false);
  assert.match(joined, /^\s+limit_req_status 429;/m);
  // XFF sahteciligine karsi tek deger
  assert.match(joined, /proxy_set_header X-Forwarded-For \$remote_addr;/);
  assert.doesNotMatch(joined, /\$proxy_add_x_forwarded_for/);
});

// ------------------------------------------------------------------------------
// betikler
// ------------------------------------------------------------------------------
test('create_db_roles.sql: en az yetki (yalniz 3 tablo SELECT), parola ortamdan (\\getenv), idempotent', () => {
  const sql = read('scripts', 'create_db_roles.sql');
  assert.match(sql, /\\getenv emqx_password EMQX_AUTHDB_PASSWORD/);
  assert.match(sql, /NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION/);
  assert.match(sql, /default_transaction_read_only = on/);
  assert.match(sql, /REVOKE ALL ON ALL TABLES IN SCHEMA public FROM/);
  const grants = [...sql.matchAll(/GRANT\s+(\w+)\s+ON\s+([A-Z ]*?)(?:\s|\b)/g)].map((m) => m[1]);
  assert.ok(grants.every((g) => ['SELECT', 'CONNECT', 'USAGE'].includes(g)), `beklenmeyen GRANT: ${grants}`);
  assert.match(sql, /VALUES \('mqtt_credentials'\), \('mqtt_acl'\), \('mqtt_users'\)/);
  assert.doesNotMatch(sql, /GRANT\s+(ALL|INSERT|UPDATE|DELETE|TRUNCATE)/i);
  assert.doesNotMatch(sql, /PASSWORD\s+'[^']/, 'duz metin parola yok');
  assert.match(sql, /\\if :\{\?emqx_password\}/);
});

test('emqx_cert_deploy_hook.sh: set -eu, yalnizca EMQX_CERT_DIR\'e yazar, sertifika dizinini degistirmez, ortak servislere dokunmaz', () => {
  const sh = read('scripts', 'emqx_cert_deploy_hook.sh');
  assert.match(sh, /^#!\/bin\/sh/);
  assert.match(sh, /^set -eu$/m);
  assert.match(sh, /: "\$\{RENEWED_LINEAGE:\?/);
  assert.match(sh, /: "\$\{EMQX_CERT_DIR:\?/);
  assert.match(sh, /install -m 0600 .*privkey\.pem/);
  assert.match(sh, /mv -f .*\.new/);
  // yalnizca ev yiginin kapsayicisi; nginx/mosquitto/systemctl yok
  const shCode = sh.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
  assert.doesNotMatch(shCode, /\b(nginx|mosquitto|systemctl|service)\b/);
  assert.match(sh, /ev_otomasyon_emqx/);
  assert.match(sh, /listeners restart ssl:default/);
});

// ------------------------------------------------------------------------------
// Migration dosyalari
// ------------------------------------------------------------------------------
test('migrations/: tohum yok - 002 yok, 003 envanter INSERT yok, 014 super kullanici INSERT yok, hicbirinde users INSERT yok', () => {
  for (const f of listMigrationFiles(MIGRATIONS_DIR)) {
    const sql = maskSql(read('migrations', f.name));
    // kimlik/parola tohumu HICBIR migration'da olamaz (tum paketler)
    assert.doesNotMatch(sql, /INSERT\s+INTO\s+users\b/i, `${f.name}: kullanici tohumu`);
    assert.doesNotMatch(sql, /crypt\s*\(/i, `${f.name}: SQL icinde parola uretimi`);
    // ev/cihaz/envanter tohumu: eski (<=17) ve WP-C (010b, 022-029) dosyalarinda yasak; baska paketlerin sema disi
    // veri migration'lari bu testi kirmasin diye kapsam disi
    if (f.version <= 17 || (f.version >= 22 && f.version <= 29)) {
      assert.doesNotMatch(sql, /INSERT\s+INTO\s+device_inventory\b/i, `${f.name}: envanter tohumu`);
      assert.doesNotMatch(sql, /INSERT\s+INTO\s+(homes|home_users|devices|endpoints)\b/i, `${f.name}: ev/cihaz tohumu`);
    }
  }
  assert.match(read('migrations', '003_device_inventory_schema.sql'), /CREATE TABLE IF NOT EXISTS device_inventory/, '003 sema korunmali');
  assert.match(read('migrations', '014_super_user_and_service_management.sql'), /ADD COLUMN IF NOT EXISTS role VARCHAR\(50\)/, '014 sema korunmali');
});

test('WP-C migration dosyalari (010b, 022-029): sozdizimsel tutarli, BEGIN/COMMIT yok, dolar-tirnaklar esli', () => {
  for (const f of listMigrationFiles(MIGRATIONS_DIR)) {
    if (!(f.name.startsWith('010b_') || (f.version >= 22 && f.version <= 29))) continue;
    const raw = read('migrations', f.name);
    const masked = maskSql(raw);
    assert.doesNotMatch(masked, /(^|;)\s*(BEGIN|COMMIT)\s*;/i, `${f.name}: transaction sarmalayicisi yok (runner sarar)`);
    // parantez dengesi (yorum/metin/dolar-tirnak govdeleri disinda)
    let depth = 0;
    for (const c of masked) {
      if (c === '(') depth++;
      if (c === ')') depth--;
      assert.ok(depth >= 0, `${f.name}: ) ( oncesi`);
    }
    assert.equal(depth, 0, `${f.name}: parantez dengesiz`);
    // dolar-tirnak sayisi cift: DO $$ ... END $$; ve fonksiyon govdeleri
    assert.equal((raw.match(/\$\$/g) || []).length % 2, 0, `${f.name}: $$ sayisi cift olmali`);
    // her DO bloku END $$; ile kapanir
    assert.equal((raw.match(/\bDO \$\$/g) || []).length, (raw.match(/\bEND \$\$;/g) || []).length, `${f.name}: DO/END esli`);
    // son komut ; ile biter
    assert.match(raw.replace(/--[^\n]*/g, '').trimEnd(), /;$/, `${f.name}: son komut ; ile bitmeli`);
    // idempotent: CREATE TABLE/INDEX IF NOT EXISTS, ADD COLUMN IF NOT EXISTS
    assert.doesNotMatch(masked, /CREATE\s+(UNIQUE\s+)?INDEX\s+(?!IF\s+NOT\s+EXISTS)/i, `${f.name}: indeks IF NOT EXISTS olmali`);
    assert.doesNotMatch(masked, /ADD\s+COLUMN\s+(?!IF\s+NOT\s+EXISTS)/i, `${f.name}: ADD COLUMN IF NOT EXISTS olmali`);
  }
});

test('022: zamanli kural semasi - UUID tipleri, kanal kaydirma TEK SEFER, kisitlar NOT VALID, gunluk tablosu, indeksler', () => {
  const sql = read('migrations', '022_scheduled_rules_fix.sql');
  assert.match(sql, /ALTER TABLE homes ADD COLUMN IF NOT EXISTS timezone VARCHAR\(64\) NOT NULL DEFAULT 'Europe\/Istanbul'/);
  assert.match(sql, /column_name = 'last_run_at'/);
  assert.match(sql, /IF NOT had_last_run THEN\s+UPDATE scheduled_rules SET channel = channel \+ 1;/, 'kaydirma yalniz ilk uygulamada');
  assert.match(sql, /ALTER COLUMN %I TYPE UUID USING NULL/);
  assert.match(sql, /home_id\s+UUID NOT NULL REFERENCES homes\(id\) ON DELETE CASCADE/);
  assert.match(sql, /created_by\s+UUID NOT NULL REFERENCES users\(id\) ON DELETE CASCADE/);
  for (const c of ['scheduled_rules_channel_range_check', 'scheduled_rules_type_action_check', 'scheduled_rules_days_check']) {
    assert.match(sql, new RegExp(`ADD CONSTRAINT ${c}[\\s\\S]*?NOT VALID;`), `${c} NOT VALID olmali`);
  }
  assert.match(sql, /CREATE INDEX IF NOT EXISTS idx_scheduled_rules_due ON scheduled_rules \(hour, minute\) WHERE enabled = TRUE;/);
  assert.match(sql, /CREATE UNIQUE INDEX IF NOT EXISTS ux_scheduled_rule_runs_rule_slot ON scheduled_rule_runs \(rule_id, slot_at\);/);
  // kanal kaydirma: UPDATE kosulsuz oldugundan yalnizca had_last_run korumasi altinda olmali
  const updates = [...sql.matchAll(/UPDATE scheduled_rules SET channel = channel \+ 1/g)];
  assert.equal(updates.length, 1);
});

test('025 (C9): cocuk kilidi once geri doldurulur sonra NOT NULL; gece huzur saati HH:MM CHECK, NULL serbest, once normalize', () => {
  const raw = read('migrations', '025_child_lock_and_peace_constraints.sql');
  const sql = maskSql(raw);
  for (const table of ['homes', 'devices']) {
    const fill = raw.indexOf(`UPDATE ${table} SET child_lock_enabled = FALSE WHERE child_lock_enabled IS NULL;`);
    const notNull = raw.indexOf(`ALTER TABLE ${table} ALTER COLUMN child_lock_enabled SET NOT NULL;`);
    assert.ok(fill >= 0 && notNull > fill, `${table}: geri doldurma NOT NULL'dan ONCE olmali`);
    assert.match(raw, new RegExp(`ALTER TABLE ${table} ALTER COLUMN child_lock_enabled SET DEFAULT FALSE;`));
  }
  const norm = raw.indexOf('lpad(split_part(peace_notification_time');
  const nullify = raw.indexOf('SET peace_notification_time = NULL');
  const check = raw.indexOf('ADD CONSTRAINT homes_peace_time_format_check');
  assert.ok(norm >= 0 && nullify > norm && check > nullify, 'normalize -> gecersizleri NULL -> CHECK sirasi');
  assert.match(raw, /CHECK \(peace_notification_time IS NULL OR peace_notification_time ~ '\^\(\[01\]\[0-9\]\|2\[0-3\]\):\[0-5\]\[0-9\]\$'\)/);
  assert.doesNotMatch(sql, /DROP\s+TABLE|TRUNCATE|DELETE\s+FROM/i, 'yikici komut yok');
});

test('026 (C11): kalp atisiyla degisen last_seen_at/is_online indekslenmez - 023\'un indeksi kaldirilir, zincirin SON islemi DROP', () => {
  const raw = read('migrations', '026_devices_heartbeat_hot_updates.sql');
  assert.match(maskSql(raw), /DROP INDEX IF EXISTS idx_devices_online_last_seen;/);
  assert.doesNotMatch(maskSql(raw), /DROP\s+TABLE|TRUNCATE|DELETE\s+FROM|ALTER\s+TABLE/i, 'yalniz indeks kaldirilir');

  // Zincirde bu indeks uzerindeki islemleri sirayla topla: SON islem DROP olmali (yeniden yaratan migration olmamali)
  const events = [];
  for (const f of listMigrationFiles(MIGRATIONS_DIR)) {
    const sql = maskSql(read('migrations', f.name));
    for (const m of sql.matchAll(/\b(CREATE\s+(?:UNIQUE\s+)?INDEX|DROP\s+INDEX)\b(?:\s+IF\s+(?:NOT\s+)?EXISTS)?\s+idx_devices_online_last_seen\b/gi)) {
      events.push(/^CREATE/i.test(m[1]) ? 'create' : 'drop');
    }
  }
  assert.ok(events.includes('create'), '023 indeksi yaratir (zincir tutarliligi)');
  assert.equal(events[events.length - 1], 'drop', `zincirin son islemi DROP olmali: ${events.join(',')}`);

  // Bu indeksi hicbir baska migration, last_seen_at / is_online uzerinde yeniden tanimlamamali
  for (const f of listMigrationFiles(MIGRATIONS_DIR)) {
    if (f.name.startsWith('023_') || f.name.startsWith('026_')) continue;
    const sql = maskSql(read('migrations', f.name));
    assert.doesNotMatch(sql, /CREATE\s+(?:UNIQUE\s+)?INDEX[^;]*\bON\s+devices\b[^;]*\b(last_seen_at|is_online)\b/i, `${f.name}: devices.last_seen_at/is_online indekslenmemeli (HOT guncelleme)`);
  }
});

test('010b + 011: temiz kurulumda 011 DUSMEZ - tablo 010b ile dogru tiplerle onceden var', () => {
  const pre = read('migrations', '010b_scheduled_rules_uuid_prereq.sql');
  const old = read('migrations', '011_scheduled_rules.sql');
  assert.match(pre, /CREATE TABLE IF NOT EXISTS scheduled_rules/);
  assert.match(pre, /home_id\s+UUID NOT NULL REFERENCES homes\(id\)/);
  assert.match(pre, /device_id\s+UUID REFERENCES devices\(id\)/);
  assert.match(pre, /created_by\s+UUID NOT NULL REFERENCES users\(id\)/);
  // 011 hala INTEGER FK'li (degistirilmedi) ama IF NOT EXISTS: tablo varsa atlanir
  assert.match(old, /home_id\s+INTEGER NOT NULL REFERENCES homes\(id\)/);
  assert.match(old, /CREATE TABLE IF NOT EXISTS scheduled_rules/);
});

// ------------------------------------------------------------------------------
// Kod SQL'i <-> migration semasi (calisan bir PostgreSQL olmadan "kolon surukleme" denetimi)
// ------------------------------------------------------------------------------
function stripComments(sql) {
  return sql.replace(/\/\*[\s\S]*?\*\//g, '').replace(/--[^\n]*/g, '');
}

function loadSchema() {
  const tables = new Map();
  const add = (t, c) => {
    if (!tables.has(t)) tables.set(t, new Set());
    tables.get(t).add(c);
  };
  for (const f of listMigrationFiles(MIGRATIONS_DIR)) {
    const sql = stripComments(read('migrations', f.name));

    const re = /CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?([a-z_][a-z0-9_]*)\s*\(/gi;
    let m;
    while ((m = re.exec(sql)) !== null) {
      const name = m[1].toLowerCase();
      let depth = 1;
      let i = re.lastIndex;
      const start = i;
      while (i < sql.length && depth > 0) {
        if (sql[i] === '(') depth++;
        else if (sql[i] === ')') depth--;
        i++;
      }
      const body = sql.slice(start, i - 1);
      const parts = [];
      let d = 0;
      let cur = '';
      for (const c of body) {
        if (c === '(') d++;
        if (c === ')') d--;
        if (c === ',' && d === 0) {
          parts.push(cur);
          cur = '';
        } else {
          cur += c;
        }
      }
      if (cur.trim()) parts.push(cur);
      for (const p of parts) {
        const t = p.trim();
        if (!t || /^(CONSTRAINT|PRIMARY|UNIQUE|CHECK|FOREIGN|EXCLUDE|LIKE)\b/i.test(t)) continue;
        const col = /^"?([a-z_][a-z0-9_]*)"?/i.exec(t);
        if (col) add(name, col[1].toLowerCase());
      }
    }

    const alter = /ALTER\s+TABLE\s+(?:ONLY\s+)?(?:IF\s+EXISTS\s+)?(?:public\.)?([a-z_][a-z0-9_]*)\s+([\s\S]*?);/gi;
    while ((m = alter.exec(sql)) !== null) {
      for (const c of m[2].matchAll(/ADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?"?([a-z_][a-z0-9_]*)"?/gi)) {
        add(m[1].toLowerCase(), c[1].toLowerCase());
      }
    }
  }
  return tables;
}

test('sema cikarimi kendi kendini dogrular (bilinen kolonlar bulunur)', () => {
  const s = loadSchema();
  assert.ok(s.get('devices').has('device_uuid'));
  assert.ok(s.get('devices').has('child_lock_enabled'), '010 ALTER ... ADD COLUMN (cok kolonlu)');
  assert.ok(s.get('endpoints').has('shutter_pair_index'));
  assert.ok(s.get('scheduled_rule_runs').has('slot_at'), 'EXECUTE format icindeki CREATE TABLE de bulunur');
});

test('kopru SQL\'i yalnizca semada olan kolonlari kullanir (devices / endpoints / homes)', () => {
  const s = loadSchema();
  const need = {
    devices: ['id', 'home_id', 'device_uuid', 'ip_address', 'firmware_version', 'child_lock_enabled', 'is_online', 'last_seen_at', 'last_ack_id', 'last_ack_at'],
    endpoints: ['device_id', 'channel_index', 'type', 'shutter_pair_index', 'current_state', 'current_position', 'updated_at'],
    homes: ['id', 'mqtt_username', 'child_lock_enabled'],
  };
  for (const [table, cols] of Object.entries(need)) {
    for (const c of cols) assert.ok(s.get(table) && s.get(table).has(c), `${table}.${c} migration'larda tanimli degil`);
  }
});

test('zamanlayici/servis SQL\'i yalnizca semada olan kolonlari kullanir (scheduled_rules, scheduled_rule_runs, homes, users, home_users)', () => {
  const s = loadSchema();
  const need = {
    scheduled_rules: ['id', 'home_id', 'device_id', 'channel', 'channel_type', 'action', 'hour', 'minute', 'days_of_week', 'label', 'enabled', 'created_by', 'last_run_at', 'schedule_changed_at', 'created_at', 'updated_at'],
    scheduled_rule_runs: ['id', 'rule_id', 'home_id', 'device_id', 'slot_at', 'status', 'detail', 'command_id', 'attempts', 'created_at', 'updated_at'],
    homes: ['id', 'mqtt_username', 'timezone'],
    users: ['id', 'is_active', 'role', 'full_name', 'account_status'],
    home_users: ['home_id', 'user_id', 'role', 'installer_expires_at'],
    devices: ['id', 'home_id', 'is_online'],
  };
  for (const [table, cols] of Object.entries(need)) {
    for (const c of cols) assert.ok(s.get(table) && s.get(table).has(c), `${table}.${c} migration'larda tanimli degil`);
  }
});

test('kullanici silinince denetim/gecmis kayitlari korunur: 016 duzeltmesi A (019) ve B (021) migration\'larinda SET NULL ile kapsanmis', () => {
  const chain = listMigrationFiles(MIGRATIONS_DIR)
    .filter((f) => f.version >= 18)
    .map((f) => read('migrations', f.name))
    .join('\n');
  const pairs = [
    ['emergency_reset_logs', 'installer_user_id'],
    ['commissioning_logs', 'technician_id'],
    ['device_replacement_logs', 'replaced_by_user_id'],
    ['home_transfers', 'accepted_by'],
    ['home_invitations', 'used_by'],
  ];
  for (const [t, c] of pairs) {
    const found = listMigrationFiles(MIGRATIONS_DIR)
      .filter((f) => f.version >= 18)
      .some((f) => {
        const sql = read('migrations', f.name);
        return sql.includes(t) && sql.includes(c) && /ON DELETE SET NULL/.test(sql);
      });
    assert.ok(found, `${t}.${c}: ON DELETE SET NULL kapsami bulunamadi`);
  }
  assert.ok(chain.length > 0);
});
