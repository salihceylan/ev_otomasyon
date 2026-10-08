import 'dart:convert';

import '../../../../models/install_template_models.dart';
import '../../../../services/automation_api_service.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_steps.dart';

/// Şablonu kartta seçim aşaması.
enum TemplateStage {
  /// Kart kapalı ("Şablon Seç" düğmesi).
  closed,

  /// Site (ya da "Genel") seçimi.
  site,

  /// Seçilen sitedeki şablonlardan biri.
  template,

  /// Seçilen şablonun özeti ve "Panoya Uygula".
  preview,
}

/// Sihirbaz bulut kaydına yazdığı yol: Wi-Fi LAN (CONTRACTS §3e `template-writes.via`).
const String kTemplateWriteViaLan = 'lan';

/// 7. adımın başındaki **isteğe bağlı** "Şablon uygula" kartının mantığı (plan K-Ş10, İP-4.3).
///
/// Akış: pano şablonu destekliyor mu (`GET /api/template`; eski firmware 404) → site (ya da genel şablonlar) → şablon →
/// önizleme → `POST /api/template/apply` (LAN, cihaz anahtarıyla; K-Ş4) → yazım bulutta kaydedilir (`via: "lan"`, en iyi
/// çaba) → [onApplied] 7-9. adımları panonun yeni değerleriyle yeniden yükletir.
///
/// Yalnız [ServiceSetupAccess.canUseInstallTemplates] (servis personeli + süper kullanıcı) için vardır ([available]);
/// servis PIN oturumunda kart hiç görünmez ve sihirbaz bugünkü gibi çalışır. Adım tamamlanma koşullarını etkilemez.
class TemplateLogic extends SetupLogic {
  TemplateLogic(super.ctx);

  /// Kart 7. adımda gösterilir: hata metinleri ve ipuçları o adıma göre seçilir.
  @override
  int get number => SetupSteps.relays;

  /// İsteğe bağlı adımcık: tamamlanma koşulu yoktur.
  @override
  bool get isComplete => true;

  /// Şablon panoya yazılınca çağrılır (denetleyici 7-9. adımları sıfırlayıp röleleri yeniden okur).
  Future<void> Function()? onApplied;

  TemplateStage _stage = TemplateStage.closed;
  bool? _supported;
  BoardTemplateInfo? _board;
  List<InstallSite> _sites = const <InstallSite>[];
  bool _globalChosen = false;
  InstallSite? _site;
  List<InstallTemplateSummary> _templates = const <InstallTemplateSummary>[];
  InstallTemplate? _selected;
  InstallTemplate? _applied;
  bool _recordFailed = false;

  /// Bu oturum şablon kullanabilir ve hedef pano belli.
  bool get available => ctx.access.canUseInstallTemplates && ctx.target != null;

  TemplateStage get stage => _stage;

  /// Pano şablonu destekliyor mu: `null` = henüz denetlenmedi, `false` = eski firmware (v1.3.0 öncesi).
  bool? get supported => _supported;

  /// Panoda yüklü şablon (`GET /api/template`).
  BoardTemplateInfo? get board => _board;

  List<InstallSite> get sites => _sites;
  InstallSite? get site => _site;

  /// "Genel (standart) şablonlar" seçildi.
  bool get globalChosen => _globalChosen;
  List<InstallTemplateSummary> get templates => _templates;
  InstallTemplate? get selected => _selected;

  /// Bu oturumda panoya uygulanan son şablon.
  InstallTemplate? get applied => _applied;

  /// Yazım panoda başarılı oldu ama bulut kaydı ([recordTemplateWrite]) gönderilemedi.
  bool get recordFailed => _recordFailed;

  /// Kart açılır: önce panonun şablon desteği ve yüklü şablonu (LAN), sonra siteler (bulut) okunur.
  Future<bool> open() => run('Pano şablon desteği denetleniyor', () async {
        _stage = TemplateStage.closed;
        if (!await _readBoard()) return;
        _sites = await ctx.cloud.listInstallSites();
        ctx.ensureActive();
        _stage = TemplateStage.site;
      });

  /// Panonun yüklü şablonunu yeniden okur (en iyi çaba değil: eski firmware 404 -> [supported] `false`).
  Future<bool> _readBoard() async {
    try {
      _board = await ctx.deviceCall((api) => api.fetchTemplate());
      _supported = true;
      return true;
    } on LocalApiException catch (e) {
      if (e.statusCode == 404) {
        _supported = false;
        _board = null;
        return false;
      }
      rethrow;
    }
  }

  /// Kartı kapatır (seçim bırakılır; uygulanan şablon bilgisi kalır).
  void close() {
    _stage = TemplateStage.closed;
    _selected = null;
    _templates = const <InstallTemplateSummary>[];
    _site = null;
    _globalChosen = false;
    clearProblem();
    ctx.notify();
  }

  /// Bir önceki seçim aşamasına döner.
  void back() {
    switch (_stage) {
      case TemplateStage.preview:
        _selected = null;
        _stage = TemplateStage.template;
      case TemplateStage.template:
        _templates = const <InstallTemplateSummary>[];
        _site = null;
        _globalChosen = false;
        _stage = TemplateStage.site;
      case TemplateStage.site:
      case TemplateStage.closed:
        close();
        return;
    }
    clearProblem();
    ctx.notify();
  }

  /// Site seçildi ([site] `null` = genel/standart şablonlar): şablon listesi sunucudan okunur.
  Future<bool> chooseSite(InstallSite? site) => run('Şablonlar yükleniyor', () async {
        final list = await ctx.cloud.listInstallTemplates(siteId: site?.id, includeGlobal: site == null);
        ctx.ensureActive();
        _templates = List<InstallTemplateSummary>.unmodifiable(
          site == null ? list.where((t) => t.isGlobal) : list.where((t) => t.siteId == site.id),
        );
        _site = site;
        _globalChosen = site == null;
        _selected = null;
        _stage = TemplateStage.template;
      });

  /// Şablon seçildi: güncel sürümün gövdesi okunur, önizleme gösterilir.
  Future<bool> chooseTemplate(InstallTemplateSummary summary) => run('Şablon okunuyor', () async {
        final template = await ctx.cloud.installTemplate(summary.id);
        ctx.ensureActive();
        _selected = template;
        _stage = TemplateStage.preview;
      });

  /// Panoya yazılacak etiket (`device_name`): dairenin adı, en çok 31 bayt UTF-8 (CONTRACTS §3e zarfı).
  static String labelFor(String homeName) {
    var label = homeName.trim();
    while (utf8.encode(label).length > 31) {
      label = String.fromCharCodes(label.runes.toList()..removeLast());
    }
    return label;
  }

  /// Seçilen şablonu panoya LAN'dan uygular (K-Ş4: anahtarlı; gevşetme yasağı panoda denetlenir).
  Future<bool> apply() => run('Şablon panoya yazılıyor', () async {
        final template = _selected;
        if (template == null) return;
        final t = ctx.requireTarget;
        final label = labelFor(t.homeName);
        final envelope = <String, dynamic>{
          'template': template.body,
          if (label.isNotEmpty) 'label': label,
        };
        try {
          await ctx.deviceCall((api) => api.applyTemplate(envelope));
        } on LocalApiException catch (e) {
          // Pano isteği gerçekten değerlendirip reddettiyse (ağ / anahtar / iptal hariç) ret de kaydedilir.
          if (!e.isNetwork && !e.isUnauthorized && !e.isCancelled && !e.isLocked && e.code != 'not_configured') {
            await _record(template, ok: false, errorCode: e.code ?? 'http_${e.statusCode}');
          }
          throw SetupProblemException(applyProblem(e));
        }
        ctx.ensureActive();
        _applied = template;
        _board = BoardTemplateInfo(templateId: template.templateId, version: template.version, label: label);
        _selected = null;
        _templates = const <InstallTemplateSummary>[];
        _site = null;
        _globalChosen = false;
        _stage = TemplateStage.closed;
        await _record(template, ok: true);
        ctx.ensureActive();
        await onApplied?.call();
      });

  /// Yazım kaydı (`POST /template-writes`, `via: "lan"`): en iyi çaba; başarısızlık yazımı geri almaz.
  Future<void> _record(InstallTemplate template, {required bool ok, String? errorCode}) async {
    try {
      await ctx.cloud.recordTemplateWrite(
        deviceUuid: ctx.requireTarget.deviceUuid,
        templateId: template.id,
        version: template.version,
        via: kTemplateWriteViaLan,
        ok: ok,
        errorCode: errorCode,
      );
      if (ok) _recordFailed = false;
    } on Exception {
      if (ok) _recordFailed = true;
    }
  }

  /// Panonun şablon uygulama reddi → kullanıcıya açıklama (CONTRACTS §3e hata kodları).
  SetupProblem applyProblem(LocalApiException e) {
    if (e.statusCode == 404) {
      _supported = false;
      return unsupportedProblem;
    }
    switch (e.code) {
      case 'local_loosen_forbidden':
        return const SetupProblem(
          kind: SetupProblemKind.forbidden,
          title: 'Şablon bu bağlantıdan yazılamaz',
          why: 'Panodaki güvenlik ayarı bu şablonla gevşer; atölyede USB ile yazın. '
              'Güvenlik gereği yerel ağdan (Wi-Fi) güvenlik ayarı gevşetilemez; panoda hiçbir şey değişmedi.',
          todo: 'Şablonu atölyede servis yazılımıyla USB kablosundan yazın ya da bu kurulumda şablonsuz devam edin.',
          retryable: false,
        );
      case 'zone_latched':
        return const SetupProblem(
          kind: SetupProblemKind.deviceRejected,
          title: 'Panoda alarm sürüyor',
          why: 'Bir güvenlik bölgesi alarm verdi ve kilitli; alarm sürerken güvenlik ayarları değiştirilemez. '
              'Panoda hiçbir şey değişmedi.',
          todo: 'Sensörü kontrol edip alarmı onaylayın, sonra "Tekrar dene"ye basın.',
        );
      case 'armed':
        return const SetupProblem(
          kind: SetupProblemKind.deviceRejected,
          title: 'Hırsız alarmı kurulu',
          why: 'Alarm kuruluyken pano ayarları değiştirilemez. Panoda hiçbir şey değişmedi.',
          todo: 'Ev sahibinden alarmı çözmesini isteyin (servis hesapları alarmı çözemez), sonra "Tekrar dene"ye basın.',
        );
      case 'busy':
        return const SetupProblem(
          kind: SetupProblemKind.deviceRejected,
          title: 'Pano şu anda meşgul',
          why: 'Bir panjur hareket ediyor ya da pano başka bir işi bitiriyor. Panoda hiçbir şey değişmedi.',
          todo: 'Panjurların durmasını bekleyip "Tekrar dene"ye basın.',
        );
      case 'storage':
      case 'storage_error':
        return const SetupProblem(
          kind: SetupProblemKind.deviceRejected,
          title: 'Pano belleği yetersiz',
          why: 'Şablon için panonun ayar belleğinde yer yok. Panoda hiçbir şey değişmedi.',
          todo: 'Daha az öğeli bir şablon seçin ya da destek ekibine başvurun.',
          retryable: false,
        );
    }
    if (e.statusCode == 400) {
      final code = e.code ?? 'geçersiz';
      final path = e.path;
      return SetupProblem(
        kind: SetupProblemKind.validation,
        title: 'Pano şablonu kabul etmedi',
        why: 'Şablon pano kurallarına uymuyor (kod: $code${path == null ? '' : ', alan: $path'}). '
            'Panoda hiçbir şey değişmedi.',
        todo: 'Şablonu servis yazılımında düzeltip yeni sürüm kaydedin, sonra yeniden deneyin.',
        retryable: false,
      );
    }
    return SetupProblems.fromError(e, step: number);
  }

  /// Eski firmware (şablon ucu yok).
  static const SetupProblem unsupportedProblem = SetupProblem(
    kind: SetupProblemKind.deviceRejected,
    title: 'Pano yazılımı şablonu desteklemiyor',
    why: 'Pano yazılımı şablonu desteklemiyor, v1.3.0\'a güncelleyin.',
    todo: 'Pano yazılımını v1.3.0 ya da üstüne güncelleyin ya da bu kurulumda şablonsuz devam edin.',
    retryable: false,
  );
}
