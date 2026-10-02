import 'package:flutter/foundation.dart';

/// Gece hatırlatması bildiriminin uygulamaya ulaştığı yol.
enum PeaceNoticeSource {
  /// Uygulama açıkken geldi (`onMessage`); sistem bildirimi gösterilmez, uygulama kendi afişini çıkarır.
  foreground,

  /// Uygulama arka plandayken kullanıcı sistem bildirimine dokundu (`onMessageOpenedApp`).
  opened,

  /// Uygulama kapalıyken bildirime dokunularak açıldı (`getInitialMessage`).
  initial,

  /// Push gelmemiş ya da kaçırılmış olabilir (izin yok, FCM yapılandırılmamış, telefon kapalıydı); uygulama açılınca
  /// ayar yanıtındaki `last_notice`'tan üretildi ([PeaceNotice.fromSettings]).
  settings,
}

/// Sunucunun gönderdiği "açık lamba/panjur var" bildirimi (`data.type = peace_open_devices`).
///
/// FCM `data` alanı DIŞARIDAN gelen, güvenilmeyen bir girdidir (başka bir uygulama aynı
/// kanala yazamaz ama sunucu hatası, sürüm farkı ya da bozuk mesaj olabilir). Bu yüzden
/// yalnızca [tryParse] ile, sıkı doğrulamadan geçerek üretilir; geçersiz her şey `null` olur ve
/// hiçbir koşulda istisna fırlatılmaz.
@immutable
class PeaceNotice {
  const PeaceNotice({
    required this.homeId,
    required this.noticeId,
    required this.openLights,
    required this.openShutters,
    required this.source,
    required this.receivedAt,
    this.title,
    this.body,
  });

  /// Sunucunun `data.type` değeri; farklı türler (ileride eklenecek bildirimler) bu modelle işlenmez.
  static const String typeValue = 'peace_open_devices';

  /// Desteklenen tek eylem: açık lambaları/panjurları tek dokunuşla kapat.
  static const String closeAllAction = 'close_all';

  /// Desteklenen ileti sürümü (`data.v`). Bilinmeyen sürümün anlamını tahmin etmeyiz.
  static const String supportedVersion = '1';

  /// Sayaçların üst sınırı: bir evde bundan fazla uç nokta olamaz; aşırı değer bozuk veridir.
  static const int maxCount = 9999;

  static const int _maxHomeIdLength = 64;
  static const int _maxTitleLength = 120;
  static const int _maxBodyLength = 300;

  // UUID ve benzeri kimlikler: harf, rakam, tire, alt çizgi. Boşluk, yol ayırıcı, tırnak vb. YOK.
  static final RegExp _homeIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');
  static final RegExp _digitsPattern = RegExp(r'^[0-9]+$');

  // Denetim karakterleri (C0/C1), sıfır genişlikli ve çift yönlü biçim denetimi karakterleri:
  // afişte metni gizleyebilir/ters çevirebilir. Boşluğa çevrilip sonra sadeleştirilir.
  static final RegExp _unsafeChars = RegExp(
    r'[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u2028-\u202E\u2060-\u2069\uFEFF]',
  );
  static final RegExp _manySpaces = RegExp(r'\s+');

  /// Evin kimliği (UUID metni).
  final String homeId;

  /// Sunucudaki bildirim satırının kimliği; yoksa `null` (eski sunucu / elle üretilmiş mesaj).
  final int? noticeId;

  /// Açık lamba sayısı (0..[maxCount]).
  final int openLights;

  /// Açık panjur sayısı (0..[maxCount]).
  final int openShutters;

  /// Bildirimin ulaştığı yol.
  final PeaceNoticeSource source;

  /// İstemcinin bildirimi aldığı an (tekilleştirme ve "ne kadar önce" gösterimi için).
  final DateTime receivedAt;

  /// Ev adı (sunucu `notification.title`); temizlenmiş, kısaltılmış.
  final String? title;

  /// Özet cümle, örn. `Salonda 2 lamba, 1 panjur açık.`; temizlenmiş, kısaltılmış.
  final String? body;

  /// Aynı bildirimin iki kez iletilmesini önleyen anahtar.
  ///
  /// `noticeId` varsa o; yoksa ev + başlık + gövde (aynı içerik = aynı bildirim). Ayırıcı olarak
  /// denetim karakteri kullanılır: temizlenmiş metinde bulunamayacağı için çakışma çıkmaz.
  String get dedupeKey => noticeId != null ? 'n:$noticeId' : 'h:$homeId\u0000${title ?? ''}\u0000${body ?? ''}';

  /// Gece hatırlatmasının "hâlâ geçerli" sayılacağı en uzun süre: 23:30'da gelen hatırlatma ertesi sabaha kadar anlamlıdır.
  static const Duration defaultFallbackMaxAge = Duration(hours: 14);

  /// Bildirim izni yok / FCM yapılandırılmamış / telefon kapalıydı: push gelmemiş olabilir. Uygulama açılınca ayar
  /// yanıtından (`GET /devices/peace-notification/:home_id` -> `data`) uygulama içi afiş üretir.
  ///
  /// Afiş YALNIZCA şu koşulların hepsi sağlanırsa üretilir (bayat ya da yanıltıcı uyarı vermemek için):
  /// * `home_id` geçerli;
  /// * `stale == false`: en az bir cihaz canlı (bayat veriyle "lamba açık" denmez);
  /// * `last_notice` var, `status` `sent` ya da `no_recipients` ve `resolved_at` boş (kullanıcı henüz kapatmadı);
  /// * `created_at` geçerli bir zaman, en çok [maxAge] önce ve gelecekte değil (2 dk saat sapması payı);
  /// * CANLI sayılar (`open_lights_count` + `open_shutters_count`) > 0: lambalar bu arada kapatıldıysa afiş yoktur.
  ///   Sayılar ve özet gece kaydından değil CANLI veriden alınır (gece kaydındaki sayılar bayat olabilir).
  /// `noticeId` = `last_notice.id` olduğundan push'tan gelen kopyayla aynı [dedupeKey]'i taşır (çift afiş çıkmaz).
  /// Geçersiz her şey için `null`; hiçbir koşulda istisna fırlatmaz.
  static PeaceNotice? fromSettings(
    Map<String, dynamic> data, {
    String? homeName,
    DateTime? now,
    Duration maxAge = defaultFallbackMaxAge,
  }) {
    try {
      final homeId = data['home_id'];
      if (homeId is! String || homeId.isEmpty || homeId.length > _maxHomeIdLength || !_homeIdPattern.hasMatch(homeId)) {
        return null;
      }
      if (data['stale'] != false) return null;

      final last = data['last_notice'];
      if (last is! Map) return null;
      final status = last['status'];
      if (status != 'sent' && status != 'no_recipients') return null;
      if (last['resolved_at'] != null) return null;

      // JSON'da kimlik sayıdır; push verisindeki gibi rakam metni de kabul edilir.
      final rawId = last['id'];
      final noticeId = rawId is int ? rawId : _parseDigits(rawId, maxDigits: 18);
      if (noticeId == null || noticeId <= 0) return null;

      final createdRaw = last['created_at'];
      final created = createdRaw is String ? DateTime.tryParse(createdRaw) : null;
      if (created == null) return null;
      final reference = now ?? DateTime.now();
      final age = reference.difference(created);
      if (age > maxAge || age < const Duration(minutes: -2)) return null;

      final lights = _parseLiveCount(data['open_lights_count']);
      final shutters = _parseLiveCount(data['open_shutters_count']);
      if (lights == null || shutters == null || (lights == 0 && shutters == 0)) return null;

      final summary = data['summary_text'];
      return PeaceNotice(
        homeId: homeId,
        noticeId: noticeId,
        openLights: lights,
        openShutters: shutters,
        source: PeaceNoticeSource.settings,
        receivedAt: reference,
        title: _sanitize(homeName, _maxTitleLength),
        body: _sanitize(summary is String ? summary : null, _maxBodyLength),
      );
    } catch (_) {
      return null;
    }
  }

  /// JSON'dan gelen sayaç: tam sayı ya da rakam metni, 0..[maxCount].
  static int? _parseLiveCount(Object? raw) {
    if (raw is int) return (raw < 0 || raw > maxCount) ? null : raw;
    return _parseCount(raw);
  }

  /// FCM `data` haritasını sıkı doğrular; geçersizse `null`.
  ///
  /// Kurallar:
  /// * `type` tam olarak [typeValue]; `v` yoksa ya da [supportedVersion] olmalı;
  /// * `home_id` 1..64 karakter, yalnızca `[A-Za-z0-9_-]`;
  /// * `notice_id` yok/`null`/boş metin ya da pozitif tam sayı metni (rakamlardan oluşan, en çok 18 hane);
  /// * `open_lights` ve `open_shutters` 0..[maxCount] tam sayı metni, ikisi birden 0 olamaz
  ///   (sunucu açık bir şey yokken bildirim göndermez; "0 lamba açık" afişi yanıltıcıdır);
  /// * `action` yoksa ya da [closeAllAction] (bilinmeyen bir eylemi "Hepsini kapat" diye sunmayız);
  /// * bilinmeyen ek alanlar yok sayılır (ileri uyumluluk).
  ///
  /// Değerler FCM'de hep metindir; metin olmayan (ör. gerçek `int`) değer reddedilir: tür karışıklığı
  /// bozuk mesaj işaretidir ve "esnek" ayrıştırma sürpriz kabul yolları açar.
  static PeaceNotice? tryParse(
    Map<String, dynamic> data, {
    String? title,
    String? body,
    PeaceNoticeSource source = PeaceNoticeSource.foreground,
    DateTime? now,
  }) {
    try {
      if (data['type'] != typeValue) return null;

      final version = data['v'];
      if (version != null && version != supportedVersion) return null;

      final action = data['action'];
      if (action != null && action != closeAllAction) return null;

      final homeId = data['home_id'];
      if (homeId is! String || homeId.isEmpty || homeId.length > _maxHomeIdLength || !_homeIdPattern.hasMatch(homeId)) {
        return null;
      }

      final rawNoticeId = data['notice_id'];
      int? noticeId;
      // Sunucu bildirim kimliğini bilmiyorsa `notice_id: ''` yollar (push_service.js buildDataPayload): bu "yok" demektir, bozuk mesaj değil.
      if (rawNoticeId != null && rawNoticeId != '') {
        noticeId = _parseDigits(rawNoticeId, maxDigits: 18);
        if (noticeId == null || noticeId <= 0) return null;
      }

      final lights = _parseCount(data['open_lights']);
      final shutters = _parseCount(data['open_shutters']);
      if (lights == null || shutters == null || (lights == 0 && shutters == 0)) {
        return null;
      }

      return PeaceNotice(
        homeId: homeId,
        noticeId: noticeId,
        openLights: lights,
        openShutters: shutters,
        source: source,
        receivedAt: now ?? DateTime.now(),
        title: _sanitize(title, _maxTitleLength),
        body: _sanitize(body, _maxBodyLength),
      );
    } catch (_) {
      // Düşmanca/bozuk girdi (ör. okunurken fırlatan bir harita) hiçbir zaman uygulamayı düşürmez.
      return null;
    }
  }

  static int? _parseCount(Object? raw) {
    final value = _parseDigits(raw, maxDigits: 4);
    return (value == null || value > maxCount) ? null : value;
  }

  /// Yalnızca ASCII rakamlardan oluşan metni tam sayıya çevirir (işaret, boşluk, ondalık, üstel
  /// gösterim ve Unicode rakamlar `int.parse`/`tryParse` ile sızmasın diye elle denetlenir).
  static int? _parseDigits(Object? raw, {required int maxDigits}) {
    if (raw is! String || raw.isEmpty || raw.length > maxDigits) return null;
    if (!_digitsPattern.hasMatch(raw)) return null;
    return int.tryParse(raw);
  }

  /// Afişte gösterilecek metni temizler: tehlikeli karakterler boşluk olur, boşluklar sadeleşir,
  /// uzunluk kod noktası (rune) sınırında kırpılır (vekil çift ortasından bölünmez). Boşsa `null`.
  static String? _sanitize(String? text, int maxLength) {
    if (text == null) return null;
    final cleaned = text.replaceAll(_unsafeChars, ' ').replaceAll(_manySpaces, ' ').trim();
    if (cleaned.isEmpty) return null;
    final runes = cleaned.runes;
    if (runes.length <= maxLength) return cleaned;
    return String.fromCharCodes(runes.take(maxLength)).trimRight();
  }

  @override
  bool operator ==(Object other) =>
      other is PeaceNotice &&
      other.homeId == homeId &&
      other.noticeId == noticeId &&
      other.openLights == openLights &&
      other.openShutters == openShutters &&
      other.source == source &&
      other.receivedAt == receivedAt &&
      other.title == title &&
      other.body == body;

  @override
  int get hashCode => Object.hash(homeId, noticeId, openLights, openShutters, source, receivedAt, title, body);

  /// Ev kimliği, başlık ve gövde (kişisel veri) log'a düşmesin diye yazdırılmaz.
  @override
  String toString() =>
      'PeaceNotice(noticeId: $noticeId, lights: $openLights, shutters: $openShutters, source: ${source.name})';
}
