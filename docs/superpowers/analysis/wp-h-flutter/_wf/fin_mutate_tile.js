// FIN mutasyon sinamasi: PushStatusTile (RR3-02). Her mutasyon LIVE'daki tile dosyasina uygulanir, hedefli testler kosulur,
// sonuc kaydedilir ve dosya HER ZAMAN orijinal haline donurulur (sha256 ile dogrulanir).
const { spawnSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');

const SP = 'C:/Users/FINGON~1/AppData/Local/Temp/claude/g--site-site-kapi-kontrol/a379bdb3-93a0-4167-8a2c-eed43f0e926f/scratchpad';
const LIVE = SP + '/flutter_live2';
const WF = SP + '/wp-h-flutter-wf';
const TARGET = LIVE + '/lib/ui/widgets/push_status_tile.dart';
const TESTS = ['test/ui/push_status_tile_test.dart', 'test/ui/peace_card_integration_test.dart'];

const ARM = `      PushState.unsupported when view.eligible => _TileSpec(
        icon: Icons.info_outline,
        text: 'Bu sürümde bildirim telefona gönderilmez; uygulamayı açtığınızda hatırlatma görünür.',
        tone: _Tone.muted,
      ),
`;

const MUTANTS = [
  { id: 'M1', desc: 'uygunluk korumasi kaldirildi (unsupported her zaman satir cizer)', from: 'PushState.unsupported when view.eligible => _TileSpec(', to: 'PushState.unsupported when view.state == PushState.unsupported => _TileSpec(' },
  { id: 'M2', desc: 'yeni kol tamamen kaldirildi (eski davranis: unsupported hicbir sey cizmez)', from: ARM, to: '' },
  { id: 'M3', desc: 'idle + uygun da satir cizer', from: 'PushState.unsupported when view.eligible => _TileSpec(', to: 'PushState.unsupported || PushState.idle when view.eligible => _TileSpec(' },
  { id: 'M4', desc: 'metin anlami tersine cevrildi (gonderilmez -> gonderilir)', from: 'telefona gönderilmez;', to: 'telefona gönderilir;' },
  { id: 'M5', desc: 'secici kaydi uygunlugu hep true okur', from: 'eligible: c.isEligible,', to: 'eligible: true,' },
  { id: 'M6', desc: 'simge degistirildi (info_outline -> sync)', from: 'icon: Icons.info_outline,', to: 'icon: Icons.sync,' },
];

const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const original = fs.readFileSync(TARGET, 'utf8');
const originalSha = sha(original);
const results = [];
const log = [];
const say = (m) => { console.log(m); log.push(m); };

function runTests(label) {
  const r = spawnSync('flutter', ['test', ...TESTS], { cwd: LIVE, shell: true, encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 });
  const out = (r.stdout || '') + (r.stderr || '');
  fs.writeFileSync(`${WF}/FIN-mut-${label}.log`, out);
  const sums = [...out.matchAll(/\+(\d+)(?: ~(\d+))?(?: -(\d+))?: /g)];
  const last = sums.length ? sums[sums.length - 1] : null;
  const passed = last ? Number(last[1]) : null;
  const failed = last && last[3] ? Number(last[3]) : 0;
  const killers = [];
  for (const m of out.matchAll(/^\d\d:\d\d \+\d+(?: ~\d+)? -\d+: .*?\.dart: (.*?) \[E\]\s*$/gm)) killers.push(m[1].trim());
  return { exit: r.status, passed, failed, killers: [...new Set(killers)], tail: out.slice(-300) };
}

try {
  say(`Orijinal sha256: ${originalSha}`);
  for (const m of MUTANTS) {
    const count = original.split(m.from).length - 1;
    if (count !== 1) { say(`${m.id}: ATLANDI (eslesme sayisi ${count}, 1 olmali)`); results.push({ id: m.id, desc: m.desc, skipped: true }); continue; }
    fs.writeFileSync(TARGET, original.replace(m.from, () => m.to));
    const t0 = Date.now();
    const res = runTests(m.id);
    const sec = Math.round((Date.now() - t0) / 1000);
    const killed = res.exit !== 0 && res.failed > 0;
    say(`${m.id} [${m.desc}] -> ${killed ? 'YAKALANDI' : 'KACTI'} (cikis=${res.exit}, gecen=${res.passed}, basarisiz=${res.failed}, ${sec} sn)`);
    for (const k of res.killers.slice(0, 12)) say(`     kirilan: ${k}`);
    results.push({ id: m.id, desc: m.desc, killed, exit: res.exit, passed: res.passed, failed: res.failed, killers: res.killers });
  }
} finally {
  fs.writeFileSync(TARGET, original);
  const back = sha(fs.readFileSync(TARGET, 'utf8'));
  say(`Geri yukleme sha256: ${back} -> ${back === originalSha ? 'AYNI' : 'FARKLI (HATA!)'}`);
}
fs.writeFileSync(`${WF}/FIN-mutation-log.txt`, log.join('\n') + '\n');
fs.writeFileSync(`${WF}/FIN-mutation-results.json`, JSON.stringify(results, null, 1));
const caught = results.filter((r) => r.killed).length;
say(`Ozet: ${caught}/${results.length} mutasyon yakalandi`);
fs.writeFileSync(`${WF}/FIN-mutation-log.txt`, log.join('\n') + '\n');
