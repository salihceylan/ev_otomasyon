import 'package:flutter/material.dart';

import 'service_setup_controller.dart';
import 'setup_problem.dart';
import 'setup_style.dart';
import 'setup_widgets.dart';

/// Sihirbaz adımlarının ortak iskeleti.
///
/// Üstte **n/10 ilerleme**, başlık ve durum rozeti; ortada "Ne yapacaksın?" maddeleri, (varsa) hata +
/// "Neden? / Ne yapmalıyım?" kutusu ve adımın gövdesi; altta başparmak bölgesinde tek büyük "Devam"
/// düğmesi. "Devam" yalnızca adımın geçiş koşulu **gerçek cihaz/sunucu yanıtıyla** sağlandığında etkindir.
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

  @override
  State<SetupStepScaffold> createState() => _SetupStepScaffoldState();
}

class _SetupStepScaffoldState extends State<SetupStepScaffold> {
  bool _instructionsOpen = true;

  /// Sabit üst (ilerleme) ve alt ("Devam") alanları ile kaydırılan ortanın sığması için gereken en az yükseklik
  /// (yazı ölçeği 1.0'da). Bundan az yükseklikte (küçük ekran + büyük yazı) sayfa **tümüyle kaydırılır**:
  /// sabit alanlar taşmaz, "Devam" düğmesi içeriğin sonunda erişilebilir kalır.
  static const double _compactBelow = 400;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(10) / 10;
        final compact = constraints.hasBoundedHeight && constraints.maxHeight < _compactBelow * scale;
        return compact ? _buildCompact(context) : _buildRegular(context);
      },
    );
  }

  /// Normal düzen: üstte ilerleme, ortada kaydırılan içerik, altta sabit "Devam" (başparmak bölgesi).
  Widget _buildRegular(BuildContext context) {
    return Column(
      children: [
        _buildHeader(context),
        if (widget.busyLabel != null) _buildBusy(context),
        // --- Orta: yönergeler + hata + gövde ---
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
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
    return Scrollbar(
      child: SingleChildScrollView(
        key: const Key('setup_compact_scroll'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            if (widget.busyLabel != null) _buildBusy(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: _buildContent(context),
            ),
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
        if (widget.problem != null)
          SetupProblemBox(
            problem: widget.problem!,
            onRetry: widget.onRetry,
            onFixStep: widget.onFixStep,
          ),
        widget.body,
      ],
    );
  }

  Widget _buildBusy(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: widget.busyLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LinearProgressIndicator(minHeight: 3),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Text(widget.busyLabel!, style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context))),
          ),
        ],
      ),
    );
  }

  /// Üst: n/10 ilerleme, başlık, durum rozeti.
  Widget _buildHeader(BuildContext context) {
    final muted = SetupColors.muted(context);
    final text = SetupColors.text(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: SetupColors.surface(context),
        border: Border(bottom: BorderSide(color: SetupColors.border(context))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.onBack != null)
                IconButton(
                  key: const Key('setup_back'),
                  tooltip: 'Önceki adım',
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back_rounded),
                  visualDensity: VisualDensity.compact,
                ),
              Expanded(
                child: Semantics(
                  header: true,
                  label: 'Adım ${widget.step} / ${widget.total}: ${widget.title}',
                  child: Text(
                    'Adım ${widget.step} / ${widget.total}',
                    key: const Key('setup_progress_text'),
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: muted, letterSpacing: 0.4),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(child: SetupStatusBadge(phase: widget.phase, label: widget.statusText)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            widget.title,
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: text),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              key: const Key('setup_progress_bar'),
              value: widget.step / widget.total,
              minHeight: 7,
              backgroundColor: SetupColors.border(context).withValues(alpha: 0.5),
              color: SetupColors.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructions(BuildContext context) {
    final text = SetupColors.text(context);
    return SetupCard(
      accent: SetupColors.info,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: const Key('setup_instructions_toggle'),
            onTap: () => setState(() => _instructionsOpen = !_instructionsOpen),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.checklist_rounded, size: 20, color: SetupColors.readable(context, SetupColors.info)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Ne yapacaksın?',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: SetupColors.readable(context, SetupColors.info),
                      ),
                    ),
                  ),
                  Icon(
                    _instructionsOpen ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    color: SetupColors.muted(context),
                  ),
                ],
              ),
            ),
          ),
          if (_instructionsOpen) ...[
            const SizedBox(height: 6),
            for (var i = 0; i < widget.instructions.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.only(right: 10, top: 1),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: SetupColors.info.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: SetupColors.readable(context, SetupColors.info)),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        widget.instructions[i],
                        style: TextStyle(fontSize: 14, height: 1.4, color: text),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildContinueBar(BuildContext context) {
    final enabled = widget.canContinue && widget.onContinue != null;
    final hint = widget.continueHint;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
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
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  hint,
                  key: const Key('setup_continue_hint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context), height: 1.3),
                ),
              ),
            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton(
                key: const Key('setup_continue'),
                onPressed: enabled ? widget.onContinue : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: SetupColors.ok,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: SetupColors.border(context).withValues(alpha: 0.6),
                  disabledForegroundColor: SetupColors.muted(context),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(child: Text(widget.continueLabel, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward_rounded),
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
