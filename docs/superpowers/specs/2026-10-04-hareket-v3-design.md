# Hareket v3 — ikincil ekranlar, diyaloglar ve durum geçişleri için animasyon katmanı (tasarım)

> Temel: `docs/superpowers/analysis/gorsel-tasarim-v2.md` (Neon Glass v2; §2.4 hareket belirteçleri, §3.3 yardımcılar,
> **§4 SERT kurallar**, §5 erişilebilirlik, §6 korunacak sözleşmeler). Bu belge v2'yi DEĞİŞTİRMEZ; v2'nin kapsamadığı
> ekranlara ve geçiş türlerine aynı dili taşır. v2'deki her sert kural burada da geçerlidir.

## 1. Neden

Pano kartları, orb'lar, durum hapları ve sayfa geçişi (FadeThrough) canlı; ama ikincil ekranlar (kurallar, cihaz ayarları,
aile/üyeler, servis paneli/envanter/aboneler, kimlik diyalogları, kurulum sihirbazı gövdesi) **statik açılıyor**: liste
öğeleri bir anda beliriyor, diyaloglar Material varsayılanıyla (düz ölçek+solma) geliyor, yükleme→içerik ve boş→dolu
geçişleri "zıplıyor", sihirbaz adımları arasında yön hissi yok. Kullanıcı isteği: arayüz **bütün olarak** animasyonlu,
modern bir havaya kavuşsun.

## 2. Kapsam (yapılacaklar) ve kapsam dışı

Yapılacak (yalnız Flutter `lib/ui/**`; yeni pub.dev bağımlılığı YOK):

1. **Giriş koreografisi** (`StaggeredEntrance`): ikincil sayfalardaki kart/liste öğeleri ilk açılışta kademeli belirir
   (`index` sırayla; en çok 8 kademe, sonrası aynı gecikme). Hedef ekranlar: `scheduled_rules_page` (`_RuleCard` listesi,
   boş durum, bant), `device_settings_page` (ayar kartları), `family/family_members_page` (üye kartları),
   `service_management_page`, `service_subscribers_page`, `device_inventory_page`, `service_mode_page` listeleri,
   `super_user_drawer` menü öğeleri, `welcome_cards`, panel/konsol kartları (`console_dashboards` zaten kullanıyorsa
   tutarlı kalır).
2. **Diyalog ve alt sayfa geçişi**: ortak yardımcı `showAppDialog<T>()` ve `showAppSheet<T>()` (`lib/ui/common/app_dialogs.dart`):
   `showGeneralDialog` + `transitionBuilder` → solma + hafif ölçek (0.96→1.0, `SpringCurve(damping: 0.72)`, `AppMotion.slow`);
   alt sayfa: aşağıdan kayma + solma (`AppMotion.slow`, `Curves.easeOutCubic`). `MotionScope.off` → `Duration.zero`
   (`transitionDuration: MotionScope.durationOf(...)`). **Mevcut `showDialog` çağrıları yardımcıya taşınır** (29 çağrı);
   `barrierDismissible`, `useRootNavigator`, dönüş türü ve `barrierLabel` aynen korunur; `Navigator.pop` davranışı değişmez.
   `showModalBottomSheet` 3 çağrı → `showAppSheet` (aynı `isScrollControlled`/`shape`). **Mevcut örnek:**
   `lib/ui/common/confirm_dialogs.dart` `ConfirmDialogEntrance` (ölçek 0.94→1 + solma, 220 ms) yalnız yıkıcı onay
   diyaloglarında kullanılıyor → genelleştirilir (`DialogEntrance` motion katmanına taşınır; `ConfirmDialogEntrance` adı
   takma ad olarak KALIR, import/test kırılmaz). Yardımcı, Material `showDialog`'un kendi 150 ms geçişini **değiştirir**
   (`showGeneralDialog`), üstüne ikinci bir animasyon bindirmez (çift geçiş yok).
3. **Durum geçişleri** (yükleme → içerik → boş/hata): `AnimatedSwitcher(duration: MotionScope.durationOf(ctx, AppMotion.base),
   reverseDuration: Duration.zero, switchInCurve: easeOutCubic, layoutBuilder: üst-sol hizalı)` ile **tek çocuk** aynı anda
   ağaçta (v2 §4.6: eski+yeni metin birlikte OLMAZ). Hedef: `family_members_page` (skeleton→liste), `scheduled_rules_page`
   (yükleme→kartlar/boş), `device_inventory_page`, `service_subscribers_page`, `dashboard_states` (zaten varsa dokunma).
   Küçük spinner'lar (`CircularProgressIndicator` 16–18 dp düğme içi) KALIR (belirsiz işlem göstergesi gereklidir); sayfa
   düzeyi spinner yerine `SkeletonCard`.
4. **Sihirbaz adım geçişi** (`service_setup/service_setup_wizard_page.dart:336`): fade-through + 0.04 kayma ZATEN VAR
   (`AnimatedSwitcher`, `reverseDuration: Duration.zero`). Eklenecek tek şey **yön**: ileri giderken gelen gövde sağdan
   (+0.04), geri giderken soldan (−0.04) kayar (`SharedAxisSwitcher`; önceki/şimdiki `currentStep` karşılaştırması).
   `Key('setup_step_<n>')` adım iskeletinde KALIR (testler `find.byKey` ile tek adım bulur → geçiş sırasında bile tek çocuk).
   Üstteki adım orb şeridi (`SetupStepStrip`) dokunulmaz.
5. **Mikro-etkileşimler**: (a) `SettingsCard`/`SurfaceCard` üstündeki düğme ve bağlantılar zaten `Pressable`; eksik olan
   `ChoiceChip`/`FilterChip` (gün seçimi `_DayChips`, filtreler) → tema düzeyinde seçili/seçimsiz geçişi `AnimatedContainer`
   benzeri değil, **`ChipThemeData` + `AnimatedScale`** sarmalayıcı (`Pressable(pressedScale: 0.94)`; chip türü KALIR:
   testler `find.byType(ChoiceChip)` kullanabilir — grep ile doğrula). (b) `Switch` türü KALIR (DeviceSettingsPage ilk
   `Switch` çocuk kilidi sözleşmesi); yalnız `SwitchThemeData.thumbIcon` ve `trackOutlineColor` ile canlı/aktif tonu;
   geçiş süresi Flutter yerleşiği. (c) Hata/uyarı bantları (`_StaleBanner`, `SetupProblemBox`, `peace_banner`) belirirken
   `StaggeredEntrance(index: 0, offset: 8)`; kaybolurken anında (geri yön animasyonu yok).
6. **Sayı/yüzde değişimi**: servis paneli/aboneler/envanter sayaçları `AnimatedCount` (zaten var; `off` kipinde anında).
7. **Üst çubuk**: `NeonAppBar` orb'u sayfa açılışında `StaggeredEntrance(index: 0)` ile belirir (başlık metni animasyonsuz;
   `find.text` kalıpları etkilenmez; `find.byType(AppBar)` KALIR).

Kapsam dışı: `Hero` paylaşımlı geçişler (anahtar çakışması ve test riskleri), `AnimatedList` ile ekle/sil animasyonu (kural
listesinde `ListView` türü ve anahtarlar korunur; ekleme/silme sonrası yeniden kurulur), sonsuz/ambient yeni animasyon
(v2 §4.2 bütçesi aynen), pano kartları (v2'de bitti), yeni renk/tipografi.

## 3. Ortak yardımcılar (yeni dosyalar)

- `lib/ui/common/app_dialogs.dart`: `showAppDialog<T>(context, {required WidgetBuilder builder, bool barrierDismissible = true,
  bool useRootNavigator = true, String? barrierLabel, Color? barrierColor, RouteSettings? settings})` ve
  `showAppSheet<T>(context, {required WidgetBuilder builder, bool isScrollControlled = false, bool isDismissible = true,
  bool enableDrag = true, ShapeBorder? shape, Color? backgroundColor, bool useRootNavigator = false})`.
  Uygulama: `showGeneralDialog` (diyalog) / `showModalBottomSheet` (alt sayfa; Flutter yerleşik `transitionAnimationController`
  ile süre `MotionScope.durationOf`), `transitionBuilder` içinde `FadeTransition` + `ScaleTransition(alignment: center,
  scale: Tween(0.96→1.0).chain(CurveTween(SpringCurve())))`. `off` kipinde `transitionDuration: Duration.zero` → tek karede
  görünür (mevcut `pumpAndSettle` ve `find.byType(AlertDialog)` kalıpları aynı).
- `lib/ui/motion/state_switcher.dart`: `StateSwitcher({required Object stateKey, required Widget child})` → `AnimatedSwitcher`
  sarmalayıcısı (yukarıdaki parametrelerle; çocuk `KeyedSubtree(key: ValueKey(stateKey))`), `off` kipinde `Duration.zero`.
- `lib/ui/motion/shared_axis.dart`: `SharedAxisSwitcher({required int index, required Widget child})` → yön `index`
  artış/azalışına göre; `reverseDuration: Duration.zero`; `off` kipinde anında.
- `lib/ui/motion/motion.dart` dışa aktarır: `state_switcher.dart`, `shared_axis.dart`.

## 4. Sert kurallar (v2 §4 + bu belge)

1. `MotionScope.off` (testlerin varsayılanı) → tüm yeni geçişler **0 süre**, ara durum yok, `pumpAndSettle` biter.
2. `Timer`/`Future.delayed` YASAK; gecikme `Interval`. Her `AnimationController` `dispose`.
3. Aynı anda eski+yeni metin ağaçta OLMAZ (`reverseDuration: Duration.zero`; `AnimatedSwitcher.layoutBuilder` tek çocuğu
   konumlar). `find.text(...)`/`findsOneWidget` kalıpları korunur: yeni görünür metin EKLENMEZ (grep `find.text('...')` test/).
4. Hiçbir animasyon `onTap`/`onPressed`/komut iletimini geciktirmez; `AbsorbPointer`/`IgnorePointer` eklenmez.
5. `Opacity` widget'ı liste öğesinde YASAK → `FadeTransition`; `BackdropFilter`/`saveLayer` yok; blur statik ≤ 24.
6. Key sözleşmesi aynen (`nav_/btn_/field_/setup_step_/card_/switch_/slider_/chip_`); `ElevatedButton`/`Switch`/`ChoiceChip`/
   `AlertDialog`/`AppBar` TÜRLERİ KALIR (testler türle bulur).
7. Yazı ölçeği 1.5/2.0 ve 320–360 dp'de taşma yok (animasyon düzeni değiştirmez: `Transform`/`FadeTransition` yalnız).
8. Süreler: giriş 220 ms + 40 ms/kademe; diyalog 320; durum geçişi 220; sihirbaz adımı 220; sayfa geçişi 260 (var).
9. Performans: giriş animasyonu tek seferlik (`_started` bayrağı), listeler `ListView.builder` ise `StaggeredEntrance`
   yalnız ilk 8 görünür öğeye uygulanır (`index >= staggerMaxItems` → `index: staggerMaxItems - 1`); kaydırmada yeniden
   tetiklenmez (öğe `Key` ile sabitlenir). `RepaintBoundary` yalnız parıltılı öğelerde (v2).

## 5. Testler (TDD; her yardımcı için kırmızı→yeşil)

- `test/ui/design/app_dialogs_test.dart`: `off` kipinde tek `pump` ile `AlertDialog` görünür; `full` kipinde 320 ms sonunda
  tam görünür ve ara karede hem eski hem yeni metin YOK; `barrierDismissible` ve dönüş değeri aynen; `pumpAndSettle` biter.
- `test/ui/design/state_switcher_test.dart`: `off` → anında; `full` → geçiş sırasında ağaçta tek çocuk (`findsOneWidget`).
- `test/ui/design/shared_axis_test.dart`: ileri/geri yön ofset işareti; `off` → anında; `Key('setup_step_<n>')` tek.
- Mevcut testler: tüm paket yeşil (taban 4063 geçti / ~485 atlandı [golden etiketli]); `flutter analyze` 0.
- Golden (`--tags visual`) varsayılan koşuda atlanır; görsel inceleme PNG üzerinden bağımsız eleştirmenle (uygulayan onaylamaz).

## 6. İş bölümü (ayrık dosya sahipliği; çakışma yok)

| Takım | Dosyalar |
| --- | --- |
| M1 (yardımcılar + diyaloglar) | `lib/ui/common/app_dialogs.dart` (yeni), `lib/ui/motion/state_switcher.dart`, `lib/ui/motion/shared_axis.dart`, `lib/ui/motion/motion.dart`; tüm `showDialog`/`showModalBottomSheet` çağrı yerlerinin yardımcıya taşınması (29+3 çağrı; **yalnız çağrı satırı**, çevresi dokunulmaz); ilgili testler |
| M2 (ikincil sayfalar) | `scheduled_rules_page.dart`, `device_settings_page.dart`, `family/family_members_page.dart`, `service_management_page.dart`, `service_subscribers_page.dart`, `device_inventory_page.dart`, `service_mode_page.dart`, `widgets/super_user_drawer.dart`, `dashboard/welcome_cards.dart`; testler |
| M3 (sihirbaz + kimlik) | `service_setup/service_setup_wizard_page.dart` (yalnız 336. satırdaki `AnimatedSwitcher` → `SharedAxisSwitcher`), `pages/auth/*` sayfa gövdeleri (register/magic_link_page/social_sign_in girişleri; `login_page` zaten animasyonlu), `widgets/neon_app_bar.dart` orb girişi, `dashboard/connection_status.dart`/`child_lock_status.dart`/`peace_banner.dart` belirme; testler |

M1'in yardımcıları M2/M3 tarafından kullanılır → **önce M1** (yardımcı API'leri bu belgede sabit; M2/M3 M1 bitmeden
başlayabilir ama yardımcı imzalarını değiştiremez).

## 7. Doğrulama ve teslim

`flutter analyze` 0 · `flutter test` tüm paket (4063+ geçti, 0 kırık) · `flutter build apk --debug` (derleme kanıtı) ·
PNG galeri (`test/visual`, `--tags visual --update-goldens`) üretilip bağımsız görsel eleştirmen (ajan) tarafından 360 dp
koyu/açık ekran görüntüleri üzerinden değerlendirilir · kullanıcı cihazda dener ("deneyebilirsiniz").
