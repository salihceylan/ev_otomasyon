import 'package:flutter/material.dart';

import '../../motion/motion_scope.dart';
import '../../motion/staggered_entrance.dart';
import '../../theme/feature_accent.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/scroll_cue.dart';
import '../../widgets/settings/accent_button.dart';
import 'service_setup_controller.dart';
import 'setup_problem.dart';
import 'setup_style.dart';
import 'setup_widgets.dart';

/// Sihirbaz adımlarının ortak iskeleti.
///
/// Üstte **kompakt başlık bloğu** (geri düğmesi + "Adım n / 10" + durum rozeti + adım başlığı; 10 adımlı orb şeridi
/// sayfa düzeyindedir: `SetupStepStrip`); ortada "Ne yapacaksın?" maddeleri (cam kart, **varsayılan kapalı**), (varsa)
/// hata + "Neden? / Ne yapmalıyım?" kutusu ve adımın gövdesi; altta başparmak bölgesinde tek büyük "Devam" düğmesi.
/// "Devam" yalnızca adımın geçiş koşulu **gerçek cihaz/sunucu yanıtıyla** sağlandığında etkindir.
///
/// Sabit alanlar (üst + alt) kaydırılan ortayı daraltmasın diye küçük tutulur: başlık bloğu tek satırlık bir üst bant +
/// başlıktır (eskiden "Adım n / 10" ve başlık ayrı satırlardı), yönergeler kapalı başlar (1.5 yazı ölçeğinde açık
/// yönerge ilk ekranı tamamen kaplıyor, asıl eylem 800 dp'nin altına düşüyordu).
///
/// Erişilebilir test anahtarları: iskeletin kendisi adım anahtarını taşır (`Key('setup_step_<n>')`,
/// çağıran verir); `Key('setup_continue')`, `Key('setup_retry')`, `Key('setup_fix_step')`.
class SetupStepScaffold extends StatefulWidget {
  const SetupStepScaffold({
    super.key,
    required this.step,
    required this.total,
    required this.title,
    required this.instructions,
    required this.phase,
    required this.body,
    this.statusText,
    this.problem,
    this.onRetry,
    this.onFixStep,
    this.busyLabel,
    this.canContinue = false,
    this.onContinue,
    this.continueLabel = 'Devam',
    this.continueHint,
    this.onBack,
    this.banner,
    this.instructionsOpen = false,
    this.retrySecondary = false,
  });

  final int step;
  final int total;
  final String title;
  final List<String> instructions;
  final StepPhase phase;
  final Widget body;

  /// Rozetin yanındaki kısa durum cümlesi.
  final String? statusText;
  final SetupProblem? problem;
  final VoidCallback? onRetry;
  final void Function(int step)? onFixStep;

  /// Bir işlem sürerken gösterilen ilerleme etiketi.
  final String? busyLabel;
  final bool canContinue;
  final VoidCallback? onContinue;
  final String continueLabel;

  /// "Devam" pasifken neden pasif olduğunu açıklar.
  final String? continueHint;
  final VoidCallback? onBack;

  /// Başlığın altında (ör. oturum sayacı / sunucu doğrulama uyarısı).
  final Widget? banner;

  /// "Ne yapacaksın?" maddeleri ilk açılışta açık mı (varsayılan kapalı).
  final bool instructionsOpen;

  /// Hata kutusundaki "Tekrar dene" çerçeveli (ikincil) olsun mu: adımın kendi gradyan birincil eylemi ekrandaysa `true`
  /// (ekranda TEK gradyan birincil; bkz. [SetupProblemBox.retrySecondary]).
  final bool retrySecondary;

  /// Üst başlık bloğunun yarı saydam zemini: küresel devre kartı görseli üstünde başlık/alt yazı okunur kalsın (şeridin
  /// ve başlık bloğunun arkası aynı örtüyle boyanır, aralarında dikiş olmaz).
  static Color chromeScrim(BuildContext context) => SetupColors.background(context).withValues(alpha: 0.88);

  @override
  State<SetupStepScaffold> createState() => _SetupStepScaffoldState();
}

class _SetupStepScaffoldState extends State<SetupStepScaffold> {
  late bool _instructionsOpen = widget.instructionsOpen;

  /// Hata kutusunun anahtarı: hata göründüğünde kaydırma alanı kutuyu görünür alana getirir ([_revealProblem]).
  final GlobalKey _problemKey = GlobalKey(debugLabel: 'setup_problem_box');

  @override
  void initState() {
    super.initState();
    if (widget.problem != null) _revealProblem();
  }

  @override
  void didUpdateWidget(SetupStepScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    final problem = widget.problem;
    if (problem != null && !identical(problem, oldWidget.problem)) _revealProblem();
  }

  /// Yeni bir hata geldiğinde kaydırma alanında hata kutusunu görünür alana getirir. Hata kutusu içerikte EN ÜSTTE
  /// durur; hatayı tetikleyen düğme aşağıdaysa (7-10. adımlar) kutu sabit başlığın altında kalıp görünmüyordu: kullanıcı
  /// hatayı hiç görmüyordu. Hareket kapalıyken anında; açıkken kısa ve yumuşak (komutu geciktirmez, girdiyi bloklamaz).
  void _revealProblem() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _problemKey.currentContext;
      if (target == null || !target.mounted) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.04,
        duration: MotionScope.durationOf(context, AppMotion.base),
        curve: AppMotion.standard,
      );
    });
  }

  /// Sabit üst (ilerleme) ve alt ("Devam") alanları ile kaydırılan ortanın sığması için gereken en az yükseklik
  /// (yazı ölçeği 1.0'da). Bundan az yükseklikte (küçük ekran + büyük yazı) sayfa **tümüyle kaydırılır**:
  /// sabit alanlar taşmaz, "Devam" düğmesi içeriğin sonunda erişilebilir kalır.
  static const double _compactBelow = 400;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(10) / 10;
        // Klavyenin kapladığı yükseklik karara KATILMAZ: klavye açılınca düzen değişirse gövdedeki metin kutusu
        // yeniden kurulup odağını kaybediyor, klavye kapanıyor ve döngü oluşuyordu (saha: adım 3 e-posta yazılamıyordu).
        // Klavye açıkken normal düzenin orta alanı zaten kaydırılabilir.
        // Scaffold gövdesinin MediaQuery'si viewInsets'i SIFIRLAR (gövdeyi zaten küçültmüştür); ham değer görünümden okunur.
        final view = View.of(context);
        final keyboard = view.viewInsets.bottom / view.devicePixelRatio;
        final compact = constraints.hasBoundedHeight && constraints.maxHeight + keyboard < _compactBelow * scale;
        return compact ? _buildCompact(context) : _buildRegular(context);
      },
    );
  }

  /// Normal düzen: üstte başlık, ortada kaydırılan içerik, altta sabit "Devam" (başparmak bölgesi).
  Widget _buildRegular(BuildContext context) {
    return Column(
      children: [
        _buildHeader(context),
        if (widget.busyLabel != null) _buildBusy(context),
        // --- Orta: yönergeler + hata + gövde ---
        Expanded(
          // Temalı ince kaydırma çubuğu ([ScrollCue]; uygulamanın diğer uzun alanlarıyla — profil diyaloğu, çekmece — AYNI dil): eskiden
          // ham Material çubuğu koyuda parlak nötr gri, açıkta ≈ 1.5:1 soluk çiziliyordu. İçerik sağ dolgusu (16) çubuk şeridinden geniştir.
          child: ScrollCue(
            color: SetupColors.muted(context).withValues(alpha: 0.55),
            builder: (context, controller) => SingleChildScrollView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              child: _buildContent(context),
            ),
          ),
        ),
        // --- Alt: Devam ---
        _buildContinueBar(context),
      ],
    );
  }

  /// Sıkışık düzen (küçük ekran + büyük yazı): her şey tek kaydırma alanındadır; taşma olmaz.
  Widget _buildCompact(BuildContext context) {
    return ScrollCue(
      color: SetupColors.muted(context).withValues(alpha: 0.55),
      builder: (context, controller) => SingleChildScrollView(
        key: const Key('setup_compact_scroll'),
        controller: controller,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            if (widget.busyLabel != null) _buildBusy(context),
            Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), child: _buildContent(context)),
            _buildContinueBar(context),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.banner != null) widget.banner!,
        _buildInstructions(context),
        // Sorun kutusu BELİRİRKEN tek sefer kademeli girer (`MotionMode.off`'ta anında); kaybolurken anında kalkar.
        // Sorun değişse de (A -> B) aynı giriş öğesi kalır: yeniden oynamaz. Anahtar kutunun kendisinde (kaydırma hedefi).
        if (widget.problem != null)
          StaggeredEntrance(
            index: 0,
            offset: 8,
            child: SetupProblemBox(
              key: _problemKey,
              problem: widget.problem!,
              onRetry: widget.onRetry,
              onFixStep: widget.onFixStep,
              retrySecondary: widget.retrySecondary,
            ),
          ),
        widget.body,
      ],
    );
  }

  /// Süren işlem: dönen yay + etiket (cam hap). Ekran okuyucuya canlı bölge olarak duyurulur.
  Widget _buildBusy(BuildContext context) {
    final family = AppFamilies.sky;
    return Semantics(
      liveRegion: true,
      label: widget.busyLabel,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: SetupColors.background(context).withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: family.base.withValues(alpha: 0.4)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 18,
                  child: ProgressArc(
                    diameter: 18,
                    color: SetupColors.readable(context, family.light),
                    strokeWidth: 2.4,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.busyLabel!,
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: SetupColors.text(context)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Üst: [geri] + ("Adım n / 10" + durum rozeti) + adım başlığı. Rozet "Adım n / 10" satırının sağ ucundadır (alt
  /// satıra düşüp yetim kalmaz; uzun etiket kendi içinde 2 satıra sarar).
  Widget _buildHeader(BuildContext context) {
    final muted = SetupColors.muted(context);
    final text = SetupColors.text(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      decoration: BoxDecoration(
        color: SetupStepScaffold.chromeScrim(context),
        border: Border(bottom: BorderSide(color: SetupColors.border(context))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Geri yuvası HER adımda ayrılır: başlık/alt yazı adımdan adıma yatayda zıplamaz. 1. adımda (geri gidilecek adım yok)
          // yuva boş delik yerine servis modu (commissioning) orb'uyla dolar: üst 200 dp'de üç farklı sol kenar ve görünür boş
          // yuva kalmaz (Servis Paneli çubuğuyla AYNI orb; etkileşimsiz, anlamdan hariç).
          if (widget.onBack != null)
            GlassIconButton(
              key: const Key('setup_back'),
              icon: Icons.arrow_back_rounded,
              semanticLabel: 'Önceki adım',
              onTap: widget.onBack,
            )
          else
            SizedBox.square(
              dimension: AppTouch.minTarget,
              child: Center(
                child: OrbIconBadge(icon: Icons.engineering_rounded, family: AppFeature.commissioning.accentFamily),
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Wrap (Row DEĞİL): sığıyorsa "Adım n / 10" solda, rozet sağ uçta (spaceBetween); sığmıyorsa (dar ekran + büyük
                // yazı) rozet bir alt satıra iner ve hiçbir şey taşmaz. Tam genişlik: spaceBetween yalnız sabit genişlikte işler.
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Semantics(
                        header: true,
                        label: 'Adım ${widget.step} / ${widget.total}: ${widget.title}',
                        child: Text(
                          'Adım ${widget.step} / ${widget.total}',
                          key: const Key('setup_progress_text'),
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: muted,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                      SetupStatusBadge(phase: widget.phase, label: widget.statusText),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.title,
                  style: TextStyle(fontSize: 20, height: 1.2, fontWeight: FontWeight.w800, color: text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// "Ne yapacaksın?": varsayılan KAPALI tek satır ("Ne yapacaksın? · N madde" + ok), dokununca maddeler açılır.
  Widget _buildInstructions(BuildContext context) {
    final text = SetupColors.text(context);
    final muted = SetupColors.muted(context);
    final readable = SetupColors.readable(context, SetupColors.info);
    final count = widget.instructions.length;
    final open = _instructionsOpen;
    return SetupCard(
      accent: SetupColors.info,
      padding: EdgeInsets.fromLTRB(16, open ? 8 : 4, 16, open ? 12 : 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            onTap: () => setState(() => _instructionsOpen = !_instructionsOpen),
            label: open ? 'Ne yapacaksın? Yönergeleri gizle' : 'Ne yapacaksın? $count maddeyi göster',
            excludeSemantics: true,
            child: InkWell(
              key: const Key('setup_instructions_toggle'),
              onTap: () => setState(() => _instructionsOpen = !_instructionsOpen),
              borderRadius: BorderRadius.circular(AppRadius.r12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AppTouch.minTarget),
                child: Row(
                  children: [
                    const SetupMiniOrb(family: AppFamilies.cyan, icon: Icons.checklist_rounded, size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      // Wrap: başlık ile madde sayısı sığıyorsa yan yana, sığmıyorsa sayı alt satıra iner ("· 3 / madde" gibi yetim
                      // sözcük ve satır sonunda yalnız ayraç kalmaz).
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          Text('Ne yapacaksın?', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: readable)),
                          if (!open)
                            Text(
                              '$count madde',
                              style: TextStyle(fontSize: AppTouch.minFontSize, fontWeight: FontWeight.w600, color: muted),
                            ),
                        ],
                      ),
                    ),
                    Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: muted),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                for (var i = 0; i < widget.instructions.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 10, top: 0),
                          child: SetupMiniOrb(family: AppFamilies.cyan, text: '${i + 1}', size: 24),
                        ),
                        Expanded(
                          child: Text(widget.instructions[i], style: TextStyle(fontSize: 14, height: 1.4, color: text)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildContinueBar(BuildContext context) {
    final enabled = widget.canContinue && widget.onContinue != null;
    final hint = widget.continueHint;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      decoration: BoxDecoration(
        color: SetupColors.surface(context),
        border: Border(top: BorderSide(color: SetupColors.border(context))),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!enabled && hint != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  hint,
                  key: const Key('setup_continue_hint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: AppTouch.minFontSize, color: SetupColors.muted(context), height: 1.25),
                ),
              ),
            // Sabit yükseklik YOK (en az 56): büyük yazıda düğme büyür, etiket kesilmez.
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                key: const Key('setup_continue'),
                onPressed: enabled ? widget.onContinue : null,
                style: accentButtonStyle(AppFamilies.emerald, minimumSize: const Size(64, 56)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        widget.continueLabel,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.arrow_forward_rounded, size: accentIconSize(context, base: 24)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
