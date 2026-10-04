import 'package:flutter/material.dart';

import '../../claim/qr_scanner_page.dart';
import '../service_setup_controller.dart';
import '../setup_context.dart';
import '../setup_problem.dart';
import '../setup_step_scaffold.dart';
import '../setup_steps.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';

/// Karekod tarayıcı üreticisi: testlerde sahte değer döndüren bir işlevle değiştirilir.
typedef SetupScanner = Future<String?> Function(
  BuildContext context, {
  required String title,
  required String hint,
});

/// Gerçek kamera tarayıcı sayfası.
Future<String?> defaultSetupScanner(
  BuildContext context, {
  required String title,
  required String hint,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(builder: (_) => QrScannerPage(title: title, hintText: hint)),
  );
}

/// Adım gövdesini ortak iskelete (başlık, yönergeler, hata, "Devam") yerleştirir.
///
/// [logic]: hata/yoğunluk durumunu veren adım mantığı (varsayılan: adımın kendi mantığı).
Widget stepScaffold(
  BuildContext context,
  ServiceSetupController c,
  int step, {
  required Widget body,
  required String continueHint,
  SetupLogic? logic,
  String? statusText,
  String continueLabel = 'Devam',
  bool? canContinue,
  VoidCallback? onContinue,
  Widget? banner,
  bool showBusy = true,
  bool retrySecondary = false,
}) {
  final info = SetupSteps.of(step);
  final l = logic ?? c.logicFor(step);
  return SetupStepScaffold(
    key: Key('setup_step_$step'),
    step: step,
    total: SetupSteps.total,
    title: info.title,
    instructions: info.instructions,
    phase: c.phaseOf(step),
    statusText: statusText,
    problem: l.problem,
    onRetry: l.canRetry ? () => l.retry() : null,
    retrySecondary: retrySecondary,
    onFixStep: c.goToStep,
    // [showBusy] false: adımın kendi bekleme kartı var (aynı bilgi sabit alanda ikinci kez yazılmasın; bkz. 6. adım).
    busyLabel: (showBusy && l.busy) ? l.busyLabel : null,
    canContinue: canContinue ?? c.canContinue,
    onContinue: onContinue ?? c.continueNext,
    continueLabel: continueLabel,
    continueHint: continueHint,
    onBack: step > 1 ? c.goBack : null,
    banner: banner ?? (step > 1 && !c.prep.isComplete && c.prep.problem != null ? PrepWarningBanner(controller: c) : null),
    body: body,
  );
}

/// İlerleme sürdürülürken ya da sunucuya ulaşılamadan (ör. kurulum ağında internet yok) başlandığında oturum/sunucu
/// doğrulaması başarısız kaldıysa ince uyarı. Adımın **kaydırılan alanında** gösterilir: küçük ekranda ve büyük
/// yazıda adım iskeletinin sabit üst/alt alanlarını taşırmaz.
class PrepWarningBanner extends StatelessWidget {
  const PrepWarningBanner({super.key, required this.controller});

  final ServiceSetupController controller;

  @override
  Widget build(BuildContext context) {
    final problem = controller.prep.problem;
    if (problem == null) return const SizedBox.shrink();
    return SetupCard(
      key: const Key('prep_warning'),
      accent: problem.kind == SetupProblemKind.expired ? SetupColors.warn : SetupColors.error,
      margin: const EdgeInsets.only(top: 8),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'Sunucu bağlantısı doğrulanamadı: ${problem.title}',
            style: TextStyle(fontWeight: FontWeight.w700, color: SetupColors.text(context)),
          ),
          TextButton(
            key: const Key('btn_prep_retry'),
            onPressed: controller.prep.busy ? null : () => controller.prep.verify(),
            child: const Text('Tekrar dene'),
          ),
        ],
      ),
    );
  }
}
