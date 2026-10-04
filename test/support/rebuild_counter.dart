import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget YENİDEN KURULUM (rebuild) sayacı: akıcılık kilit testlerinin kanıt aracı (ölçümsüz performans
/// iddiası yok; "bu bildirimde şu bileşenler yeniden kurulmaz" kodla sabitlenir).
///
/// Flutter'ın `debugOnRebuildDirtyWidget` kancasını kullanır: ağaçtaki her ELEMENT yeniden kurulduğunda
/// (kendi `setState`/`select` değişimi, üst widget'ın yeni örnek vermesi ya da ilk kurulum) bir kez çağrılır.
/// Yalnız debug derlemede (testler) çalışır.
///
/// ```dart
/// testWidgets('...', (tester) async {
///   final counter = RebuildCounter.install();        // test sonunda önceki kanca geri yüklenir
///   final h = await pumpReady(tester, const DashboardPage());
///   counter.reset();                                  // ilk kurulum da sayılır: ölçümden ÖNCE sıfırla
///   h.mqtt.emitStateJson(sameJson);
///   await tester.pump();
///   expect(counter.of<RelaySwitchCard>(), 0, reason: counter.describe());
/// });
/// ```
///
/// Notlar:
/// * Sayım TAM tür eşleşmesiyle yapılır (`widget.runtimeType`); alt sınıflar ayrı sayılır. Başka dosyadan
///   adlandırılamayan özel sınıflar için [ofName] kullanılır (`'_AuthSplashScreen'`).
/// * Flutter'ın `builtOnce` bayrağına GÜVENİLMEZ (yalnız `debugPrintRebuildDirtyWidgets` açıkken set edilir):
///   bu sayaç onu hiç okumaz, ilk kurulumu yeniden kurulumdan ayırmaz.
/// * Önceki kanca (varsa) zincirlenir ve [uninstall]'da geri yüklenir; iç içe kurulumlar birbirini bozmaz.
class RebuildCounter {
  RebuildCounter._();

  /// Sayacı kurar; test sonunda ([addTearDown]) otomatik [uninstall] edilir.
  factory RebuildCounter.install() {
    final counter = RebuildCounter._().._attach();
    addTearDown(counter.uninstall);
    return counter;
  }

  RebuildDirtyWidgetCallback? _previous;
  RebuildDirtyWidgetCallback? _callback;
  final Map<Type, int> _byType = <Type, int>{};
  final Map<Key, int> _byKey = <Key, int>{};
  int _total = 0;

  void _attach() {
    _previous = debugOnRebuildDirtyWidget;
    _callback = _onRebuild;
    debugOnRebuildDirtyWidget = _callback;
  }

  void _onRebuild(Element element, bool builtOnce) {
    // Sayım yalnız kuruluyken; kaldırıldıktan sonra (sırasız iç içe kaldırma) yalnız zincirleme yapılır.
    if (_callback != null) {
      final widget = element.widget;
      _total++;
      _byType[widget.runtimeType] = (_byType[widget.runtimeType] ?? 0) + 1;
      final key = widget.key;
      if (key != null) _byKey[key] = (_byKey[key] ?? 0) + 1;
    }
    _previous?.call(element, builtOnce);
  }

  /// Sayaçları sıfırlar (kurulum/ilk çizimden sonra, ölçümden ÖNCE çağırın).
  void reset() {
    _total = 0;
    _byType.clear();
    _byKey.clear();
  }

  /// Kancayı geri yükler. Başka biri bizden sonra kanca kurduysa dokunmaz (yalnız sayımı durdurur).
  void uninstall() {
    final callback = _callback;
    if (callback == null) return;
    if (identical(debugOnRebuildDirtyWidget, callback)) debugOnRebuildDirtyWidget = _previous;
    _callback = null;
  }

  /// Son [reset]'ten (ya da kurulumdan) beri yeniden kurulan TÜM elementler.
  int get total => _total;

  /// [T] türündeki widget'ların yeniden kurulum sayısı (tam tür eşleşmesi).
  int of<T extends Widget>() => ofType(T);

  /// [type] türündeki widget'ların yeniden kurulum sayısı.
  int ofType(Type type) => _byType[type] ?? 0;

  /// Tür adı [typeName] olan widget'ların yeniden kurulum sayısı (özel sınıflar için; ör. `'_PhaseBody'`).
  int ofName(String typeName) {
    var sum = 0;
    _byType.forEach((type, count) {
      if (type.toString() == typeName) sum += count;
    });
    return sum;
  }

  /// [key] anahtarlı widget'ın yeniden kurulum sayısı (aynı türden kartları ayırt etmek için).
  int ofKey(Key key) => _byKey[key] ?? 0;

  /// Tür adı -> sayı (hata mesajı/teşhis için; en çok kurulandan başlayarak).
  Map<String, int> get byName {
    final entries = _byType.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final result = <String, int>{};
    for (final entry in entries) {
      final name = entry.key.toString();
      result[name] = (result[name] ?? 0) + entry.value;
    }
    return result;
  }

  /// `expect(..., reason: counter.describe())` için kısa döküm.
  String describe({int top = 12}) {
    final parts = byName.entries.take(top).map((e) => '${e.key}×${e.value}').join(', ');
    return 'yeniden kurulanlar (toplam $_total): ${parts.isEmpty ? '-' : parts}';
  }
}
