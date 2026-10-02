# Önizleme düzeneği (tool/preview) — ekran görüntüsüyle önce/sonra doğrulama

> Bu belge, 2026-10-01 tarihli analiz ajanının kurduğu düzeneğin kendi açıklamasından derlendi. Düzenek **takip edilmeyen yeni bir dizindir** (`tool/preview/`; çıktıları `.gitignore` ile hariç). İstemezseniz `tool/preview/` ve `build/preview_*` silinebilir; uygulamanın hiçbir dosyası ona bağımlı değildir.
> Amaç: bulutsuz, MQTT'siz, cihazsız, emülatörsüz olarak GERÇEK sayfaları (Dashboard, Ayarlar, Giriş, açılış) GERÇEK temayla sahte (mock) `AutomationState` üstünde web olarak derleyip başsız Chrome ile PNG almak. Dalga 5'te "önce/sonra" karşılaştırması için tasarlandı.

## Nasıl çalışır (düzeneğin başlığından)

```text
tool/preview/preview.mjs  -  build + screenshot driver for the "preview" harness

The harness (tool/preview/preview_main.dart + preview_fixture.dart) renders the REAL DashboardPage /
DeviceSettingsPage / LoginPage / splash inside the REAL theme with a mocked AutomationState. No cloud,
no MQTT broker, no device, no emulator is needed.
  PRIMARY   `flutter build web` + headless Chrome (puppeteer-core)   -> build / shoot / all / serve
  FALLBACK  `flutter test` + real fonts, PNGs without a browser      -> golden

COMMANDS
  node tool/preview/preview.mjs build  [--src working|head|inplace] [--mode release|profile|debug] [--fast]
                                       [--skip-analyze] [--verbose]
  node tool/preview/preview.mjs shoot  [--src ...|--web <dir>] [--tag <name>] [--screens a,b] [--themes dark,light]
                                       [--viewports phone,tablet,desktop,phone-small,phone-long|WxH[@dpr]]
                                       [--scenarios default,locked,quiet,offline,empty,many,peace_off,peace_notime]
                                       [--shell page|app] [--insets [top,bottom]] [--query "textscale=1.3&freeze=1"]
                                       [--suffix name] [--scroll <px>] [--wait <ms>] [--gpu] [--perf] [--timeout <sec>]
  node tool/preview/preview.mjs all    (build, then shoot; same flags)
  node tool/preview/preview.mjs serve  [--src ...|--web <dir>] [--port 8765]   (open in a normal browser)
  node tool/preview/preview.mjs compare --a <tagA> --b <tagB>   (before | after | diff PNGs + % changed)
  node tool/preview/preview.mjs golden [--src working|head] [--tag golden] [--screens ..] [--themes ..] [--scenarios ..]

--src working  (default) snapshot-copies the CURRENT working tree (lib/ web/ assets/ pubspec.*) to
               build/preview_src_working and builds there. Isolated: concurrent edits by other agents
               cannot produce a half-written tree mid-compile, and it never touches the repo's
               .dart_tool / pubspec.lock. A `dart analyze lib tool/preview` preflight (~10 s) aborts early
               when the tree does not compile (a failing release build otherwise needs 2-3 minutes).
--src head     exports `git archive HEAD` (the last COMMITTED tree) to build/preview_src_head and builds it
               with --dart-define=PREVIEW_LEGACY_ROLES=true (old int-id models). Use it for a "before"
               baseline when the working tree is mid-refactor.
--src inplace  builds in the repo root (--no-pub, output build/web). Fastest, but reads files live.

OUTPUT   build/preview_shots/<tag>/<screen>-<theme>[-<scenario>][-<suffix>]-<viewport>.png  + report.json
ENV      CHROME_PATH            chrome.exe (default: Program Files Chrome, then Edge)
         PUPPETEER_CORE_DIR     a directory whose node_modules contains puppeteer-core
                                (or: npm i --prefix tool/preview puppeteer-core)
         PREVIEW_CACHE_DIR      record/replay cache for CDN resources. Default build/preview_cache
NETWORK  Page requests are intercepted: localhost -> served from disk; fonts.gstatic.com / www.gstatic.com /
         fonts.googleapis.com -> record/replay cache (first run downloads, later runs are offline and
         byte-identical); the production API host -> stubbed 503 (listed in report.json as a "leak");
         everything else -> blocked (e.g. accounts.google.com from google_sign_in_web).
```

## Notlar ve bilinen durum

- Üretilmiş örnekler (`git archive HEAD` = son commit edilen sürüm; çalışma ağacı yeniden yazılırken "önce" taban çizgisi): `build/preview_shots/head-baseline`, `head-scenarios`, `head-misc`, `head-v2`, `golden-head`. İlk koşuda CDN yazı tipleri `build/preview_cache` içine kaydedilir; sonraki koşular çevrimdışı ve bayt-bayt aynıdır.
- `--src working` çalışma ağacını `build/preview_src_working`'e KOPYALAYIP orada derler (eşzamanlı düzenleme yarım dosya üretmez; `.dart_tool`/`pubspec.lock` dokunulmaz). Önce `dart analyze lib tool/preview` ön kontrolü yapar; `lib/` derlenmiyorsa erken ve ucuz biçimde durur. Bu yüzden Dalga 1–2 bitmeden `--src working` çalışmaz; `--src head` çalışır.
- Sunucu rastgele (ephemeral) port seçer; QA yığınının portlarına (5000, 1883, 18083, 54329, 8081–8083) ve emülatöre dokunmaz.
- Senaryolar (`--scenarios`): `default, locked, quiet, offline, empty, many, peace_off, peace_notime`. Görünüm alanları: `phone, tablet, desktop, phone-small, phone-long` ya da `WxH@dpr`. `--query "textscale=1.3&freeze=1"` ile yazı ölçeği/animasyon dondurma.
- Bilinen sınır: web derlemesi `dart:io` MQTT, kamera ve biyometriyi çalıştırmaz; düzenek bunları sahte/devre dışı bırakır. Gerçek kare süresi (jank) ölçümü için profil modunda gerçek cihaz/emülatör gerekir (QA yığını sahibi: orkestratör).
- Dalga 5 önerisi: önce `node tool/preview/preview.mjs all --tag once` (mümkünse `--src working`, derlenmiyorsa `--src head`), tasarım değişikliklerinden sonra `--tag sonra`, ardından `compare --a once --b sonra` ile yan yana ve fark PNG'leri; her profilde (`phone`, `phone-small` + `textscale=1.5`, `tablet`, açık/koyu) bağımsız tasarım eleştirmenlerine gösterin.
