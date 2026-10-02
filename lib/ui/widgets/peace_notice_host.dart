import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../../services/peace_notice_controller.dart';
import '../../services/push/peace_notice.dart';
import '../theme/app_theme.dart';

typedef _BannerHandle =
    ScaffoldFeatureController<MaterialBanner, MaterialBannerClosedReason>;
typedef _SnackHandle =
    ScaffoldFeatureController<SnackBar, SnackBarClosedReason>;

/// Gece hatırlatması afişi, yumuşak izin istemi ve "Hepsini kapat" sonucu için kabuk (uygulama) köprüsü.
///
/// `MaterialApp.builder` içinde yaşar ama KENDİ BİR ŞEY ÇİZMEZ ([child]'ı aynen döndürür): yalnızca
/// [PeaceNoticeController]'ı dinler ve [ScaffoldMessenger] üzerinden gösterir:
/// * bekleyen bildirim afişi ve yumuşak izin istemi = [MaterialBanner]. Sayfa içeriğini AŞAĞI iter (üstüne
///   binmez: AppBar eylemleri ve dokunuşlar çalışır), rotanın odak kapsamındadır (Tab ile "Hepsini kapat" /
///   "Kapat"a ulaşılır) ve standart canlı bölge semantiğini taşır. Öncelik: bildirim afişi > yumuşak istem.
/// * [PeaceNoticeController.closeMessage] = [SnackBar]; gösterilince denetleyiciden TÜKETİLİR (bir kez).
///   Kalıcı DEĞİLDİR (8 sn; sayfaların kendi SnackBar'ları kuyrukta beklemesin), eylem yerine kapatma
///   simgesi taşır, metni yazı ölçeğinde 1.5 ile ve 6 satırla sınırlıdır (büyük yazıda ekranı kaplamaz).
///   Köprü kendi gösterdiği SnackBar'ın tutamağını saklar ve oturum bitince / denetleyici uygun olmayınca /
///   yeni bir bildirim afişi gelince / köprü ağaçtan kalkınca kaldırır.
///
/// Banner bir kez gösterilir; içerik ve eylemler denetleyiciye bağlıdır ("Hepsini kapat" sürerken ilerleme
/// göstergesi + devre dışı, yetki yoksa gizli): aynı bildirim sürdükçe yeniden gösterme/titreşim olmaz.
/// Banner yalnızca tür + `dedupeKey` (+ tema parlaklığı: arka plan renkleri gösterim anında verilir) değişince
/// yenilenir. Ardışık hızlı değişimler tek mikro görevde birleştirilir.
///
/// Gereksinimler: üstte bir [PeaceNoticeController] ve [AutomationState] sağlayıcısı (ikincisi yalnızca
/// "Hepsini kapat" yetkisi için), ve bir [ScaffoldMessenger] (`MaterialApp` her zaman sağlar). Hiçbir
/// [Scaffold] kayıtlı değilken (ör. açılış ekranı) debug'da `showMaterialBanner` assert verir: köprü bunu
/// yakalar ve kısa aralıklarla yeniden dener (release'te çağrı kuyruğa alınır ve Scaffold gelince görünür).
///
/// Sınırlar (çerçeve): banner'ın giriş animasyonu (250 ms) çerçevede sabittir, "hareketi azalt" yalnızca
/// çıkışı anında yapar; ekran okuyucu (erişilebilir gezinme) açıkken çerçeve zaten animasyonsuz kapatır.
/// Çerçeve banner içeriğinin yazı ölçeğini kendisi sınırlar; eylem düğmeleri 2.0 ile sınırlanır.
class PeaceNoticeHost extends StatefulWidget {
  const PeaceNoticeHost({super.key, required this.child});

  final Widget child;

  @override
  State<PeaceNoticeHost> createState() => _PeaceNoticeHostState();
}

class _PeaceNoticeHostState extends State<PeaceNoticeHost> {
  /// Hiç Scaffold yokken (debug assert) yeniden deneme aralığı.
  static const Duration _retryDelay = Duration(milliseconds: 500);

  /// Sonuç iletisinin ekranda kalma süresi (kapatma simgesiyle daha erken kapatılabilir).
  static const Duration _resultDuration = Duration(seconds: 8);

  late final PeaceNoticeController _controller;
  ScaffoldMessengerState? _messenger;
  Brightness? _brightness;

  _BannerHandle? _banner;

  /// Gösterilen banner'ın imzası (tür + dedupeKey + parlaklık); banner yoksa `null`.
  String? _bannerSig;
  bool _bannerIsNotice = false;

  /// Son gösterilen bildirim afişinin `dedupeKey`'i: başka bir bildirim gelince eski sonuç iletisi kalkar.
  String? _lastNoticeKey;

  /// Bu köprünün gösterdiği (hâlâ açık olabilecek) sonuç SnackBar'ı.
  _ResultSnack? _snack;

  Timer? _retry;
  bool _syncQueued = false;

  @override
  void initState() {
    super.initState();
    _controller = context.read<PeaceNoticeController>();
    _controller.addListener(_queueSync);
    _queueSync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
    final brightness = Theme.of(context).brightness;
    final changed = _brightness != null && _brightness != brightness;
    _brightness = brightness;
    if (changed) _queueSync();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _controller.removeListener(_queueSync);
    final messenger = _messenger;
    final hadBanner = _banner != null;
    final snack = _snack;
    _banner = null;
    _bannerSig = null;
    _snack = null;
    if (messenger != null && (hadBanner || snack != null)) {
      // Ağaç kilitliyken (dispose) messenger'a setState yapılamaz: temizlik mikro görevde. Uygulama
      // tümden kapanıyorsa messenger de gitmiştir (mounted == false) ve yapılacak bir şey kalmaz.
      scheduleMicrotask(() {
        if (!messenger.mounted) return;
        if (hadBanner) {
          messenger
            ..clearMaterialBanners()
            ..removeCurrentMaterialBanner();
        }
        snack?.hide();
      });
    }
    super.dispose();
  }

  /// Denetleyici bildirimi build/dispose sırasında gelebilir; messenger'a dokunmak için mikro göreve ertelenir
  /// ve ardışık bildirimler tek eşitlemede birleşir.
  void _queueSync() {
    if (_syncQueued) return;
    _syncQueued = true;
    scheduleMicrotask(() {
      _syncQueued = false;
      if (mounted) _sync();
    });
  }

  void _sync() {
    final messenger = _messenger;
    if (messenger == null || !messenger.mounted) return;
    final bannerOk = _syncBanner(messenger);
    // Oturum bitti / rol kaybı: bayat sonuç iletisi (giriş ekranında/sonraki kullanıcıda) kalmasın. Kilitliyken
    // de (biyometrik yeniden kilit, zorunlu parola değişimi) bu ekranlarda görünmesin; kilit açılınca / parola
    // değişince ileti denetleyicide kaldığı için gösterilir.
    if (!_controller.isEligible || _controller.isLocked) _hideResultSnack();
    final messageOk = _syncMessage(messenger);
    _retry?.cancel();
    _retry = null;
    if (!bannerOk || !messageOk) _retry = Timer(_retryDelay, _queueSync);
  }

  // ---------------------------------------------------------------------------
  // Banner
  // ---------------------------------------------------------------------------

  /// İstenen banner'ın imzası: bildirim afişi > yumuşak istem > yok.
  String? _wantedSignature() {
    // Kilit ekranında ve zorunlu parola ekranında (oturum verisi gizli) afiş/istem gösterilmez; kilit açılınca /
    // parola değişince denetleyici bildirir.
    if (_controller.isLocked) return null;
    final pending = _controller.pending;
    final String kind;
    if (pending != null) {
      kind = 'notice:${pending.dedupeKey}';
    } else if (_controller.softPromptVisible) {
      kind = 'soft';
    } else {
      return null;
    }
    return '$kind|${_brightness?.name}';
  }

  /// `false`: şimdilik gösterilemedi (Scaffold yok), yeniden denenmeli.
  bool _syncBanner(ScaffoldMessengerState messenger) {
    final wanted = _wantedSignature();
    if (wanted == _bannerSig) return true;
    if (_bannerSig != null) _removeBanner(messenger, immediate: wanted != null);
    if (wanted == null) return true;

    final isNotice = _controller.pending != null;
    final _BannerHandle handle;
    try {
      handle = messenger.showMaterialBanner(
        isNotice ? _noticeBanner() : _softPromptBanner(),
      );
    } on AssertionError {
      return false;
    }
    _banner = handle;
    _bannerSig = wanted;
    _bannerIsNotice = isNotice;
    if (isNotice) {
      // Yeni (başka) bildirim: önceki bildirimin sonuç iletisi bayattır. Aynı bildirimin yeniden gösterimi
      // (tema değişimi, harici kaldırma) iletiyi kaldırmaz.
      final key = _controller.pending?.dedupeKey;
      if (key != _lastNoticeKey) _hideResultSnack();
      _lastNoticeKey = key;
    }
    unawaited(handle.closed.then((reason) => _onBannerClosed(handle, reason)));
    return true;
  }

  /// Kendi gösterdiğimiz banner'ı kaldırır. Kuyruktaki ardışık banner'lar da silinir; [immediate] (başka bir
  /// banner geliyor) ya da "hareketi azalt" iken çıkış animasyonu atlanır.
  void _removeBanner(
    ScaffoldMessengerState messenger, {
    required bool immediate,
  }) {
    final handle = _banner;
    _banner = null;
    _bannerSig = null;
    if (handle == null) return;
    messenger.clearMaterialBanners();
    if (immediate || MediaQuery.disableAnimationsOf(context)) {
      messenger.removeCurrentMaterialBanner();
    }
  }

  /// Banner bizim dışımızda kapandı: ekran okuyucunun "kapat" eylemi kullanıcı kararıdır; başka bir kaldırma
  /// (örn. dışarıdan `clearMaterialBanners`) ise hâlâ gerekliyse yeniden gösterilir.
  void _onBannerClosed(
    _BannerHandle handle,
    MaterialBannerClosedReason reason,
  ) {
    if (!identical(handle, _banner)) return;
    _banner = null;
    _bannerSig = null;
    if (!mounted) return;
    if (reason == MaterialBannerClosedReason.dismiss) {
      if (_bannerIsNotice) {
        _controller.dismiss();
      } else {
        unawaited(_controller.dismissSoftPrompt());
      }
    } else {
      _queueSync();
    }
  }

  MaterialBanner _noticeBanner() {
    return MaterialBanner(
      key: const Key('banner_peace_notice'),
      backgroundColor: AppTheme.getCardColor(context),
      surfaceTintColor: Colors.transparent,
      dividerColor: AppTheme.accentAmber.withValues(alpha: 0.65),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 4),
      leadingPadding: const EdgeInsetsDirectional.only(end: 12),
      leading: Icon(
        Icons.lightbulb_outline,
        size: 22,
        color: AppTheme.warningText(context),
      ),
      forceActionsBelow: true,
      minActionBarHeight: 48,
      content: const _NoticeText(),
      actions: const [_CloseAllAction(), _DismissAction()],
    );
  }

  MaterialBanner _softPromptBanner() {
    return MaterialBanner(
      key: const Key('banner_peace_soft_prompt'),
      backgroundColor: AppTheme.getCardColor(context),
      surfaceTintColor: Colors.transparent,
      dividerColor: AppTheme.primaryBlue.withValues(alpha: 0.65),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 4),
      leadingPadding: const EdgeInsetsDirectional.only(end: 12),
      leading: Icon(
        Icons.notifications_active_outlined,
        size: 22,
        color: AppTheme.infoText(context),
      ),
      forceActionsBelow: true,
      minActionBarHeight: 48,
      content: const _TextBlock(
        title: 'Gece hatırlatması',
        body: 'Açık kalan lambalar için gece bildirimi almak ister misiniz?',
      ),
      actions: const [_AcceptAction(), _LaterAction()],
    );
  }

  // ---------------------------------------------------------------------------
  // Sonuç iletisi
  // ---------------------------------------------------------------------------

  /// [PeaceNoticeController.closeMessage]'ı SnackBar olarak gösterir ve (gösterilince) denetleyiciden tüketir.
  /// `false`: gösterilemedi (Scaffold yok); ileti denetleyicide kalır, yeniden denenir.
  bool _syncMessage(ScaffoldMessengerState messenger) {
    final message = _controller.closeMessage;
    if (message == null || _controller.isLocked) return true;
    final snack = _ResultSnack();
    try {
      messenger.hideCurrentSnackBar();
      snack.handle = messenger.showSnackBar(
        SnackBar(
          key: const Key('snack_peace_close_result'),
          content: _ResultSnackContent(snack: snack, message: message),
          behavior: SnackBarBehavior.floating,
          duration: _resultDuration,
          // Kalıcı DEĞİL (RR2-01/02): eylemsiz SnackBar kendiliğinden kapanır, sayfaların kendi SnackBar'ları
          // kuyrukta süresiz beklemez; erken kapatma için kapatma simgesi (eylem yok: "Tamam" ekran dışına
          // taşabiliyordu) vardır.
          persist: false,
          showCloseIcon: true,
        ),
      );
    } on AssertionError {
      return false;
    }
    _snack = snack;
    final handle = snack.handle;
    unawaited(
      handle.closed.then((_) {
        if (identical(_snack, snack)) _snack = null;
      }),
    );
    _controller.clearCloseMessage();
    return true;
  }

  /// Köprünün gösterdiği sonuç iletisini (varsa) kaldırır; başkasının SnackBar'ına dokunmaz.
  void _hideResultSnack() {
    final snack = _snack;
    _snack = null;
    snack?.hide();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// -----------------------------------------------------------------------------
// Sonuç iletisi (SnackBar)
// -----------------------------------------------------------------------------

/// Sonuç iletisi metninin en büyük yazı ölçeği (SnackBar çerçevede ölçeği sınırlamaz: 3.0'da ekranı kaplıyordu).
const double _maxResultTextScale = 1.5;

/// Sonuç iletisinin en çok satırı (aşarsa "…"; tam metin ekran okuyucuda kalır).
const int _maxResultLines = 6;

/// Köprünün gösterdiği bir sonuç SnackBar'ının tutamağı. İçeriği ağaçta olduğu sürece ([onScreen]) SnackBar
/// ekrandaki (sıranın başındaki) SnackBar'dır: yalnızca o zaman `close` güvenlidir (başkasının SnackBar'ını
/// ya da kuyruktaki bir SnackBar'ı kapatmaz). Kuyrukta beklerken kaldırılması istenirse görünür görünmez
/// kapatılır ([hideWhenShown]).
class _ResultSnack {
  late _SnackHandle handle;
  bool onScreen = false;
  bool hideWhenShown = false;

  void hide() {
    if (onScreen) {
      handle.close();
    } else {
      hideWhenShown = true;
    }
  }
}

/// Sonuç iletisi içeriği: yazı ölçeği 1.5 ile, satır sayısı 6 ile sınırlı; ağaçta olup olmadığını bildirir.
class _ResultSnackContent extends StatefulWidget {
  const _ResultSnackContent({required this.snack, required this.message});

  final _ResultSnack snack;
  final String message;

  @override
  State<_ResultSnackContent> createState() => _ResultSnackContentState();
}

class _ResultSnackContentState extends State<_ResultSnackContent> {
  @override
  void initState() {
    super.initState();
    final snack = widget.snack;
    snack.onScreen = true;
    if (snack.hideWhenShown) {
      // Kuyrukta beklerken kaldırılması istenmişti: yapı bitince kapat.
      scheduleMicrotask(() {
        if (mounted) snack.handle.close();
      });
    }
  }

  @override
  void dispose() {
    widget.snack.onScreen = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: _maxResultTextScale,
      child: Text(
        widget.message,
        maxLines: _maxResultLines,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Banner içeriği (Scaffold bağlamında kurulur; denetleyiciye bağlıdır)
// -----------------------------------------------------------------------------

/// Metin bloğunun ekran yüksekliğine oranla en büyük yüksekliği; aşınca kaydırılır.
const double _maxTextHeightFraction = 0.35;

const Size _minButton = Size(48, 48);

/// Eylem düğmelerinin en büyük yazı ölçeği (3.0'da banner sayfayı kullanılmaz kılmasın; %200 korunur).
const double _maxActionTextScale = 2.0;

TextStyle _titleStyle(BuildContext context) => TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w700,
  height: 1.25,
  color: AppTheme.getTextPrimary(context),
);

TextStyle _bodyStyle(BuildContext context) => TextStyle(
  fontSize: 14,
  height: 1.35,
  color: AppTheme.getTextPrimary(context),
);

/// Başlık + gövde; yüksekliği sınırlı ve kaydırılabilir (büyük yazıda eylemler her zaman erişilebilir kalır).
class _TextBlock extends StatelessWidget {
  const _TextBlock({
    required this.title,
    required this.body,
    this.titleKey,
    this.bodyKey,
  });

  final String title;
  final String body;
  final Key? titleKey;
  final Key? bodyKey;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * _maxTextHeightFraction,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, key: titleKey, style: _titleStyle(context)),
            const SizedBox(height: 2),
            Text(body, key: bodyKey, style: _bodyStyle(context)),
          ],
        ),
      ),
    );
  }
}

class _NoticeText extends StatelessWidget {
  const _NoticeText();

  @override
  Widget build(BuildContext context) {
    final notice = context.select<PeaceNoticeController, PeaceNotice?>(
      (c) => c.pending,
    );
    // Bildirim kalkmış ama banner henüz kaldırılmamış (aynı bildirim turu): boş bırak.
    if (notice == null) return const SizedBox.shrink();
    return _TextBlock(
      title: notice.title ?? 'Gece hatırlatması',
      body: notice.body ?? 'Açık lamba ve panjur var.',
      titleKey: const Key('text_peace_notice_title'),
      bodyKey: const Key('text_peace_notice_body'),
    );
  }
}

/// Eylem düğmesini yazı ölçeği sınırıyla sarar.
Widget _clamped(Widget button) => MediaQuery.withClampedTextScaling(
  maxScaleFactor: _maxActionTextScale,
  child: button,
);

ButtonStyle _textButtonStyle(BuildContext context) => TextButton.styleFrom(
  minimumSize: _minButton,
  tapTargetSize: MaterialTapTargetSize.padded,
  foregroundColor: AppTheme.infoText(context),
);

/// Dolgu düğme: koyu temada çerçevenin varsayılan `onPrimary` rengi siyahtır (mavi üstünde 4.06:1); beyaz 5.17:1.
ButtonStyle _filledButtonStyle() => FilledButton.styleFrom(
  minimumSize: _minButton,
  tapTargetSize: MaterialTapTargetSize.padded,
  backgroundColor: AppTheme.primaryBlue,
  foregroundColor: Colors.white,
);

/// "Hepsini kapat": yetki yoksa gizli; sürerken devre dışı + ilerleme göstergesi.
class _CloseAllAction extends StatelessWidget {
  const _CloseAllAction();

  @override
  Widget build(BuildContext context) {
    // Yetki: banner görünürken okunur. Sunucu yine esastır.
    final canClose = context.select<AutomationState, bool>(
      (s) => s.capabilities.canUseGroupCommands,
    );
    if (!canClose) return const SizedBox.shrink();
    final closing = context.select<PeaceNoticeController, bool>(
      (c) => c.closing,
    );
    final controller = context.read<PeaceNoticeController>();
    return _clamped(
      FilledButton(
        key: const Key('btn_peace_notice_close_all'),
        style: _filledButtonStyle(),
        onPressed: closing ? null : () => unawaited(controller.closeAll()),
        child: closing
            ? const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _BusyIndicator(),
                  SizedBox(width: 8),
                  Flexible(child: Text('Kapatılıyor…')),
                ],
              )
            // Ekran okuyucu etiketi neyin kapatıldığını söyler; görünen metni barındırır (WCAG 2.5.3).
            : const Text(
                'Hepsini kapat',
                semanticsLabel: 'Açık lambaların ve panjurların hepsini kapat',
              ),
      ),
    );
  }
}

class _DismissAction extends StatelessWidget {
  const _DismissAction();

  @override
  Widget build(BuildContext context) {
    final controller = context.read<PeaceNoticeController>();
    return _clamped(
      TextButton(
        key: const Key('btn_peace_notice_dismiss'),
        style: _textButtonStyle(context),
        onPressed: controller.dismiss,
        // "Kapat" tek başına belirsiz (lambayı mı kapatır?): bildirimi kapattığını söyler.
        child: const Text('Kapat', semanticsLabel: 'Bildirimi kapat'),
      ),
    );
  }
}

class _AcceptAction extends StatelessWidget {
  const _AcceptAction();

  @override
  Widget build(BuildContext context) {
    final controller = context.read<PeaceNoticeController>();
    return _clamped(
      FilledButton(
        key: const Key('btn_peace_soft_prompt_accept'),
        style: _filledButtonStyle(),
        onPressed: () => unawaited(controller.requestPermission()),
        child: const Text('Bildirimleri aç'),
      ),
    );
  }
}

class _LaterAction extends StatelessWidget {
  const _LaterAction();

  @override
  Widget build(BuildContext context) {
    final controller = context.read<PeaceNoticeController>();
    return _clamped(
      TextButton(
        key: const Key('btn_peace_soft_prompt_later'),
        style: _textButtonStyle(context),
        onPressed: () => unawaited(controller.dismissSoftPrompt()),
        child: const Text('Şimdi değil'),
      ),
    );
  }
}

/// İlerleme göstergesi; "hareketi azalt" açıkken dönen animasyon yerine durağan simge.
class _BusyIndicator extends StatelessWidget {
  const _BusyIndicator();

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.getTextMuted(context);
    if (MediaQuery.disableAnimationsOf(context)) {
      return Icon(Icons.hourglass_empty, size: 18, color: color);
    }
    return SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
  }
}
