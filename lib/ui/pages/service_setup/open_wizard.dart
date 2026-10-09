import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/api_models.dart';
import '../../../services/automation_state.dart';
import '../../common/app_dialogs.dart';
import 'device_link.dart';
import 'service_setup_wizard_page.dart';
import 'service_target.dart';
import 'setup_store.dart';
import 'steps/step_common.dart';

/// Kurulum sihirbazının **tek açıcısı** (uygulama-ekranlar-1). Sihirbaz her zaman adlandırılmış rotayla
/// ([ServiceSetupWizardPage.routeName]) itilir: biyometrik yeniden kilit (AuthGate) sihirbazı kapatmaz, kilidi üstüne
/// koyar.
///
/// Mevcut cihaz kipinde ([existingTarget], [resume] yok) aynı hesap/oturum + pano için yarım kayıt varsa sessizce
/// ezilmez (servis_kurulum-8, uygulama-ekranlar-4): "Kaldığınız yerden devam / Baştan başla / Vazgeç" sorulur. Vazgeç:
/// sihirbaz açılmaz, kayıt aynen kalır.
///
/// Sihirbaz rotası kapanınca tamamlanır.
Future<void> openServiceSetupWizard(
  BuildContext context, {
  SetupProgressRecord? resume,
  ServiceTarget? existingTarget,
  int? startStep,
  DeviceMqttCredential? initialCredential,
  SetupStore? store,
  DeviceApiFactory? deviceApiFactory,
  SetupScanner scanner = defaultSetupScanner,
}) async {
  var record = resume;
  var existing = existingTarget;
  var start = startStep;
  if (existing != null && record == null) {
    final access = ServiceSetupAccess.fromState(context.read<AutomationState>());
    if (access != null) {
      final setupStore = store ?? SetupStore();
      final saved = await setupStore.load(access.ownerKey, existing.deviceUuid);
      if (!context.mounted) return;
      if (saved != null) {
        final choice = await askHalfSetupRecord(context, saved);
        if (!context.mounted || choice == null) return; // Vazgeç: kayıt aynen kalır
        if (choice) {
          record = saved;
          existing = null;
          start = null;
        } else {
          await setupStore.delete(access.ownerKey, saved.deviceUuid);
          if (!context.mounted) return;
        }
      }
    }
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: ServiceSetupWizardPage.routeName),
      builder: (_) => ServiceSetupWizardPage(
        resume: record,
        existingTarget: existing,
        startStep: start,
        initialCredential: initialCredential,
        store: store,
        deviceApiFactory: deviceApiFactory,
        scanner: scanner,
      ),
    ),
  );
}

/// Yarım kayıt sorusu: `true` = kaldığı yerden devam, `false` = baştan başla (kayıt silinir), `null` = vazgeç.
Future<bool?> askHalfSetupRecord(BuildContext context, SetupProgressRecord record) {
  return showAppDialog<bool>(
    context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text('Bu panonun yarım kalmış kurulumu var (Adım ${record.currentStep})'),
      content: const Text(
        'Kaldığınız yerden devam edebilir ya da baştan başlayabilirsiniz. Baştan başlarsanız yarım kalan kurulum kaydı '
        'silinir.',
      ),
      actions: [
        TextButton(
          key: const Key('btn_half_cancel'),
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Vazgeç'),
        ),
        TextButton(
          key: const Key('btn_half_restart'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Baştan Başla (kayıt silinir)'),
        ),
        ElevatedButton(
          key: const Key('btn_half_resume'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Kaldığınız Yerden Devam'),
        ),
      ],
    ),
  );
}
