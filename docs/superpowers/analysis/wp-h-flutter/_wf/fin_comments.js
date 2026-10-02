// FIN adim 3: pakete giren dosyalarda Firebase'li yorum/belge metinlerini Firebase'siz gercege cevirir.
// Davranisa DOKUNMAZ (yalniz yorum, belge metni ve test adi). Her degisiklik tam 1 eslesme bekler; aksi halde HICBIR dosya yazilmaz.
// Kullanim: node fin_comments.js <KOK>   (KOK: flutter_live2 ya da flutter_integ)
const fs = require('fs');
const ROOT = process.argv[2];
if (!ROOT) throw new Error('KOK verilmedi');

const E = [];
const add = (file, from, to) => E.push({ file, from, to });

// 1) push_gateway_factory.dart
add('lib/services/push/push_gateway_factory.dart',
`/// Bu sürümde \`firebase_core\` / \`firebase_messaging\` paketleri projede yoktur: [config] ne olursa olsun
/// hiçbir şey yapmayan [UnsupportedPushGateway] döner ve push özelliği sessizce kapalı kalır
/// (uygulama push'suz sürümle birebir aynı davranır).
///
/// Firebase paketleri eklendiğinde (02-firebase yaması) bu dosya, [config] doluysa \`FirebasePushGateway\`
/// döndürecek şekilde değişir; [PushConfig] ve bu fonksiyonun imzası aynı kalır.
`,
`/// Push gönderim katmanı yapılandırılmadı: [config] ne olursa olsun hiçbir şey yapmayan [UnsupportedPushGateway]
/// döner (no-op). Firebase/APNs kullanılmaz; projede \`firebase_core\` / \`firebase_messaging\` paketleri yoktur,
/// push özelliği sessizce kapalı kalır ve uygulama push'suz sürümle birebir aynı davranır (bildirim yalnızca
/// uygulama açıkken ya da açılınca yedek afişle görünür).
///
/// İleride gerçek push istenirse ayrıca eklenir: yeni bir [PushGateway] gerçeklemesi yazılır ve bu fabrika
/// [config] doluysa onu döndürecek şekilde değiştirilir; [PushConfig] ve bu fonksiyonun imzası aynı kalabilir
/// (ayrıntı: ENTEGRASYON.md, "Ek: Firebase ileride istenirse").
`);

// 2) push_gateway_factory_test.dart
add('test/push/push_gateway_factory_test.dart',
`// Bu dosya Firebase paketlerine BAĞLI DEĞİLDİR (firebase_core/firebase_messaging import edilmez).
// Firebase'siz derlemede fabrika yapılandırma ne olursa olsun hareketsiz ağ geçidi verir. 02-firebase
// yamasında ikinci test \`FirebasePushGateway\` beklentisine çevrilir (bkz. SPL-dosya-ayrimi.txt).
`,
`// Push gönderim katmanı yapılandırılmadı: fabrika, yapılandırma ne olursa olsun hareketsiz (no-op) ağ geçidi verir.
// Firebase/APNs kullanılmaz; bu dosya Firebase paketlerine BAĞLI DEĞİLDİR (firebase_core/firebase_messaging import
// edilmez). İleride gerçek push istenirse ayrıca eklenir (ENTEGRASYON.md, "Ek: Firebase ileride istenirse").
`);
add('test/push/push_gateway_factory_test.dart',
String.raw`test('Firebase\'siz derlemede yapılandırma verilse bile hareketsiz ağ geçidi döner', () async {`,
String.raw`test('push katmanı yapılandırılmadığından, yapılandırma verilse bile hareketsiz ağ geçidi döner', () async {`);

// 3) push_gateway.dart
add('lib/services/push/push_gateway.dart',
`  /// Bu cihaz/derleme push desteklemiyor (web, masaüstü, Firebase yapılandırması yok).
`,
`  /// Bu cihaz/derleme push desteklemiyor (web, masaüstü) ya da push gönderim katmanı yapılandırılmadı
  /// (bu sürümde hep böyle).
`);
add('lib/services/push/push_gateway.dart',
`/// \`firebase_messaging\`'in \`RemoteMessage\` türü uygulamaya sızmasın diye (test edilebilirlik ve
/// paket değişimine dayanıklılık) yalnızca ihtiyaç duyulan alanlar taşınır.
`,
`/// Platform paketinin mesaj türü (ör. FCM istemcisinin \`RemoteMessage\`'ı) uygulamaya sızmasın diye (test
/// edilebilirlik ve paket değişimine dayanıklılık) yalnızca ihtiyaç duyulan alanlar taşınır.
`);
add('lib/services/push/push_gateway.dart',
`/// Koordinatör yalnızca bu arayüzü bilir: gerçek uygulamada \`FirebasePushGateway\` (\`firebase_push_gateway.dart\`), yapılandırma
/// yoksa/platform desteklenmiyorsa [UnsupportedPushGateway], testlerde sahte bir uygulama kullanılır.
`,
`/// Koordinatör yalnızca bu arayüzü bilir: bu sürümde her zaman [UnsupportedPushGateway] (push gönderim katmanı
/// yapılandırılmadı: no-op; Firebase/APNs kullanılmaz), testlerde sahte bir uygulama kullanılır. İleride gerçek
/// push istenirse bu arayüzün yeni bir gerçeklemesi ayrıca eklenir.
`);
add('lib/services/push/push_gateway.dart',
`  /// Firebase'i başlatır. Idempotent; \`Firebase.initializeApp\` yalnızca burada çağrılır.
  /// Başarısızlık istisna olarak değil, \`isSupported == false\` olarak bildirilir.
`,
`  /// Push istemcisini (gerçek bir gerçeklemede platform SDK'sını) başlatır. Idempotent; başlatma yalnızca
  /// burada yapılır. Başarısızlık istisna olarak değil, \`isSupported == false\` olarak bildirilir.
`);
add('lib/services/push/push_gateway.dart',
`/// Hiçbir şey yapmayan uygulama: yapılandırması olmayan derlemeler ve desteklenmeyen platformlar.
///
/// Firebase'e hiç dokunmaz; böylece \`firebase_core\` kanalları çağrılmaz ve uygulama davranışı
/// push eklenmeden önceki haliyle birebir aynı kalır.
`,
`/// Hiçbir şey yapmayan uygulama: push gönderim katmanı yapılandırılmadı (bu sürümde tüm derlemeler) ve
/// desteklenmeyen platformlar.
///
/// Hiçbir platform kanalına dokunmaz (Firebase/APNs kullanılmaz); uygulama davranışı push eklenmeden önceki
/// haliyle birebir aynı kalır.
`);

// 4) push_config.dart
add('lib/services/push/push_config.dart',
`/// Firebase / FCM istemci yapılandırması.
///
/// Değerler depoya yazılmaz; derleme sırasında \`--dart-define\` ile verilir (bkz. docs/PUSH_KURULUM.md):
/// \`FCM_API_KEY\`, \`FCM_APP_ID\`, \`FCM_SENDER_ID\`, \`FCM_PROJECT_ID\`.
///
/// Dört değerden biri bile eksikse [fromEnvironment] \`null\` döner ve push özelliği sessizce
/// devre dışı kalır: yapılandırması olmayan bir derleme (CI, geliştirici makinesi) eskisi gibi
/// çalışır, Firebase hiç başlatılmaz.
`,
`/// Push (FCM) istemci yapılandırması: yalnızca veri.
///
/// Bu sürümde push gönderim katmanı yapılandırılmadı (Firebase/APNs kullanılmaz): [createPushGateway] bu
/// yapılandırmayı yok sayar ve her zaman hareketsiz ağ geçidi döndürür. Sınıf, ileride gerçek push istenirse
/// diye saklanır (ENTEGRASYON.md, "Ek: Firebase ileride istenirse").
///
/// Değerler depoya yazılmaz; derleme sırasında \`--dart-define\` ile verilir (eski kurulum rehberi:
/// PUSH_KURULUM_ARSIV.md): \`FCM_API_KEY\`, \`FCM_APP_ID\`, \`FCM_SENDER_ID\`, \`FCM_PROJECT_ID\`.
///
/// Dört değerden biri bile eksikse [fromEnvironment] \`null\` döner; yapılandırması olmayan bir derleme (CI,
/// geliştirici makinesi) eskisi gibi çalışır.
`);
add('lib/services/push/push_config.dart',
`yarım yapılandırmayla
  /// Firebase başlatmak yerine hiç başlatmamak daha güvenlidir.`,
`yarım yapılandırmayla
  /// push başlatmak yerine hiç başlatmamak daha güvenlidir.`);

// 5) push_coordinator.dart
add('lib/services/push/push_coordinator.dart',
`  /// Bu cihaz/derleme push desteklemiyor ya da Firebase yapılandırılmamış (sessizce kapalı).
`,
`  /// Bu cihaz/derleme push desteklemiyor ya da push gönderim katmanı yapılandırılmamış (bu sürümde hep böyle:
  /// sessizce kapalı).
`);
add('lib/services/push/push_coordinator.dart',
`      // Firebase başlatılamadı (geçersiz yapılandırma vb.): sessizce kapalı.
`,
`      // Başlatma sonrası destek düştü (ör. geçersiz yapılandırma): sessizce kapalı.
`);
add('lib/services/push/push_coordinator.dart',
`(yeniden denemek Firebase'i düzeltmez).`,
`(yeniden denemek yapılandırmayı düzeltmez).`);

// 6) peace_notice_controller.dart
add('lib/services/peace_notice_controller.dart',
`/// * Firebase yapılandırması yoksa ([PushConfig.fromEnvironment] \`null\`) koordinatör \`unsupported\`
///   kalır ve Firebase'e hiç dokunulmaz: uygulama push'suz sürümle aynı davranır (yedek afiş yine çalışır).
`,
`/// * Push gönderim katmanı yapılandırılmadı (bu sürümde [createPushGateway] her zaman hareketsiz ağ geçidi
///   döndürür; Firebase/APNs kullanılmaz): koordinatör \`unsupported\` kalır, belirteç alınmaz ya da kaydedilmez
///   ve uygulama push'suz sürümle aynı davranır (yedek afiş yine çalışır).
`);
add('lib/services/peace_notice_controller.dart',
`      // Yapılandırma (FCM_*) yoksa Firebase'e hiç dokunmayan ağ geçidi: davranış push'suz sürümle aynıdır.
`,
`      // Push gönderim katmanı yapılandırılmadı: hiçbir platform kanalına dokunmayan (no-op) ağ geçidi; davranış
      // push'suz sürümle aynıdır. [config] bu sürümde yok sayılır.
`);
add('lib/services/peace_notice_controller.dart',
`(~60-75 karakter)`,
`(53-72 karakter)`);

// 7) test/push/fakes.dart
add('test/push/fakes.dart',
`/// Sahte gateway: gerçek Firebase/platform kanalı yok.`,
`/// Sahte gateway: gerçek platform kanalı yok.`);
add('test/push/fakes.dart',
`(Firebase başlatılamadı senaryosu için)`,
`(başlatma başarısız senaryosu için)`);

// 8) test/push/push_gateway_test.dart
add('test/push/push_gateway_test.dart',
`// Bu dosya Firebase paketlerine BAĞLI DEĞİLDİR (firebase_core/firebase_messaging import edilmez):
// Firebase'siz derlemede de çalışır. FirebasePushGateway testleri firebase_push_gateway_test.dart'tadır.
`,
`// Bu dosya Firebase paketlerine BAĞLI DEĞİLDİR (Firebase/APNs kullanılmaz; firebase_core/firebase_messaging import
// edilmez): yalnızca UnsupportedPushGateway ve PushMessage test edilir.
`);
add('test/push/push_gateway_test.dart',
`// hareketsiz: fırlatmaz, Firebase'e dokunmaz`,
`// hareketsiz: fırlatmaz, hiçbir kanala dokunmaz`);

// 9) test/push/push_coordinator_test.dart
add('test/push/push_coordinator_test.dart',
`initialize sonrası destek düşerse (Firebase başlatılamadı) unsupported olur`,
`initialize sonrası destek düşerse (ağ geçidi başlatılamadı) unsupported olur`);

// 10) test/services/peace_notice_controller_test.dart
add('test/services/peace_notice_controller_test.dart',
String.raw`test('push verilmezse kendi koordinatörü: yapılandırma yoksa unsupported, Firebase\'e dokunulmaz', () async {`,
String.raw`test('push verilmezse kendi koordinatörü: push katmanı yapılandırılmadı -> unsupported, hiçbir kanala dokunulmaz', () async {`);
add('test/services/peace_notice_controller_test.dart',
`reason: 'FCM_* verilmedi -> UnsupportedPushGateway'`,
`reason: 'push katmanı yapılandırılmadı -> UnsupportedPushGateway'`);

// ---- uygula (hepsi ya da hicbiri) ----
const byFile = new Map();
for (const e of E) { if (!byFile.has(e.file)) byFile.set(e.file, []); byFile.get(e.file).push(e); }
const out = new Map();
let bad = 0;
for (const [file, edits] of byFile) {
  const p = `${ROOT}/${file}`;
  if (!fs.existsSync(p)) { console.log('YOK:', p); bad++; continue; }
  let s = fs.readFileSync(p, 'utf8');
  if (s.includes('\r')) { console.log('CR VAR (LF bekleniyordu):', p); bad++; continue; }
  for (const e of edits) {
    const n = s.split(e.from).length - 1;
    if (n !== 1) { console.log(`ESLESME ${n} (1 olmali): ${file}\n   ${JSON.stringify(e.from.slice(0, 90))}`); bad++; continue; }
    s = s.replace(e.from, () => e.to);
  }
  out.set(file, s);
}
if (bad) { console.log(`HATA: ${bad} sorun; hicbir dosya yazilmadi.`); process.exit(1); }
for (const [file, s] of out) { fs.writeFileSync(`${ROOT}/${file}`, s); console.log('yazildi:', file, `(${byFile.get(file).length} degisiklik)`); }
