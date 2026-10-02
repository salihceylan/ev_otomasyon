import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/api_models.dart';
import '../../../services/automation_state.dart';
import '../../common/confirm_dialogs.dart';
import 'device_link.dart';
import 'service_setup_controller.dart';
import 'service_target.dart';
import 'session_banner.dart';
import 'setup_store.dart';
import 'setup_style.dart';
import 'steps/step_10_handover.dart';
import 'steps/step_1_preparation.dart';
import 'steps/step_2_identify.dart';
import 'steps/step_3_customer.dart';
import 'steps/step_4_claim.dart';
import 'steps/step_5_wifi.dart';
import 'steps/step_6_cloud.dart';
import 'steps/step_7_relays.dart';
import 'steps/step_8_shutters.dart';
import 'steps/step_9_buttons.dart';
import 'steps/step_common.dart';

/// Servis sorumlusu için **adım adım kurulum sihirbazı** (10 adım).
///
/// * Yeni kurulum: `ServiceSetupWizardPage()`.
/// * Yarıda bırakılan kurulumu sürdürme: [resume] (cihaz bazlı kayıt).
/// * Mevcut cihazda kurulum (ör. pano değişimi sonrası): [existingTarget] (2-4. adımlar atlanır).
///
/// Testler için [store], [deviceApiFactory] ve [scanner] enjekte edilebilir.
class ServiceSetupWizardPage extends StatefulWidget {
  const ServiceSetupWizardPage({
    super.key,
    this.resume,
    this.existingTarget,
    this.startStep,
    this.initialCredential,
    this.store,
    this.deviceApiFactory,
    this.scanner = defaultSetupScanner,
  });

  final SetupProgressRecord? resume;
  final ServiceTarget? existingTarget;
  final int? startStep;

  /// Acil sıfırlama / pano değişimi yanıtındaki **tek seferlik** bulut kimliği: yalnızca bellekte tutulur,
  /// 6. adımda panoya yazılır (verilmezse 6. adım sunucudan yenisini üretir). Saklanmaz, loglanmaz.
  final DeviceMqttCredential? initialCredential;
  final SetupStore? store;
  final DeviceApiFactory? deviceApiFactory;
  final SetupScanner scanner;

  @override
  State<ServiceSetupWizardPage> createState() => _ServiceSetupWizardPageState();
}

class _ServiceSetupWizardPageState extends State<ServiceSetupWizardPage> {
  ServiceSetupController? _controller;
  String? _deniedReason;

  @override
  void initState() {
    super.initState();
    final state = context.read<AutomationState>();
    final access = ServiceSetupAccess.fromState(state);
    if (access == null) {
      _deniedReason = 'Bu sihirbaz yalnızca servis personeli, süper yönetici veya geçici servis oturumu içindir.';
      return;
    }
    final resume = widget.resume;
    final existing = widget.existingTarget;
    if (resume != null && resume.ownerKey != access.ownerKey) {
      _deniedReason = 'Bu kurulum kaydı başka bir hesaba/oturuma ait; açılamaz.';
      return;
    }
    final homeId = resume?.homeId ?? existing?.homeId;
    if (access.isPinSession && homeId != null && homeId != access.sessionHomeId) {
      _deniedReason = 'Geçici servis oturumu yalnızca kendi dairesinde kurulum yapabilir.';
      return;
    }
    _controller = ServiceSetupController(
      state: state,
      access: access,
      store: widget.store,
      deviceApiFactory: widget.deviceApiFactory,
      resume: resume,
      existingTarget: existing,
      startStep: widget.startStep,
      initialCredential: widget.initialCredential,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller?.start();
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<bool> _confirmExit() async {
    final c = _controller;
    if (c == null) return true;
    final saved = c.target != null;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('Sihirbazdan çıkılsın mı?'),
        content: Text(
          saved
              ? 'İlerlemeniz bu telefonda kaydedildi. "Devam eden kurulumlar" listesinden kaldığınız yerden sürdürebilirsiniz.'
              : 'Cihaz henüz daireye bağlanmadı; şimdi çıkarsanız baştan başlamanız gerekir.',
        ),
        actions: [
          TextButton(
            key: const Key('btn_exit_cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Devam et'),
          ),
          ElevatedButton(
            key: const Key('btn_exit_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Çık'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  /// Çıkmadan önce pano güvenli duruma getirilir (yarım panjur ölçümünün geçici süresi geri yüklenir ...).
  Future<void> _settleAndPop() async {
    final c = _controller;
    if (c != null) await c.settleBeforeExit();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _discard() async {
    final c = _controller;
    if (c == null) return;
    final ok = await ConfirmDestructiveDialog.show(
      context,
      title: 'Kurulum ilerlemesi silinsin mi?',
      message: 'Bu cihazın kurulum ilerlemesi bu telefondan silinir. Cihaz daireye bağlandıysa bağlantı sunucuda '
          'kalır; yalnızca test sonuçları ve adım ilerlemesi silinir.',
      confirmPhrase: 'SİL',
      confirmLabel: 'İlerlemeyi Sil',
    );
    if (!ok || !mounted) return;
    await c.settleBeforeExit();
    await c.discardProgress();
    if (mounted) Navigator.of(context).pop();
  }

  void _backToLogin() {
    final state = context.read<AutomationState>();
    final navigator = Navigator.of(context);
    if (state.isAuthenticated) unawaited(state.logout());
    navigator.popUntil((route) => route.isFirst);
  }

  Widget _step(ServiceSetupController c) {
    switch (c.currentStep) {
      case 1:
        return Step1Preparation(key: const ValueKey<int>(1), controller: c);
      case 2:
        return Step2Identify(key: const ValueKey<int>(2), controller: c, scanner: widget.scanner);
      case 3:
        return Step3Customer(key: const ValueKey<int>(3), controller: c);
      case 4:
        return Step4Claim(key: const ValueKey<int>(4), controller: c);
      case 5:
        return Step5Wifi(key: const ValueKey<int>(5), controller: c, scanner: widget.scanner);
      case 6:
        return Step6Cloud(key: const ValueKey<int>(6), controller: c);
      case 7:
        return Step7Relays(key: const ValueKey<int>(7), controller: c);
      case 8:
        return Step8Shutters(key: const ValueKey<int>(8), controller: c);
      case 9:
        return Step9Buttons(key: const ValueKey<int>(9), controller: c);
      default:
        return Step10Handover(
          key: const ValueKey<int>(10),
          controller: c,
          onFinish: () => Navigator.of(context).pop(),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Yeni Kurulum')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline_rounded, size: 56, color: SetupColors.warn),
                const SizedBox(height: 14),
                Text(
                  _deniedReason ?? 'Bu sihirbaza erişiminiz yok.',
                  key: const Key('setup_denied'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, height: 1.4, color: SetupColors.text(context)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final expired = c.sessionExpired;
        return PopScope(
          canPop: c.isFinished || expired,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final leave = await _confirmExit();
            if (leave && context.mounted) await _settleAndPop();
          },
          child: Scaffold(
            backgroundColor: SetupColors.background(context),
            appBar: AppBar(
              title: const Text('Yeni Kurulum', key: Key('nav_setup_title')),
              actions: [
                if (c.target != null && !c.isFinished)
                  PopupMenuButton<String>(
                    key: const Key('btn_setup_menu'),
                    tooltip: 'Kurulum menüsü',
                    onSelected: (value) {
                      if (value == 'discard') unawaited(_discard());
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem<String>(
                        value: 'discard',
                        child: Text('Kurulumu bırak (ilerlemeyi sil)'),
                      ),
                    ],
                  ),
              ],
            ),
            body: expired
                ? SessionExpiredPanel(
                    onBackToLogin: _backToLogin,
                    progressSaved: c.target != null,
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        // Sunucu doğrulama uyarısı adımın kaydırılan alanındadır (sabit alanı taşırmaz; bkz. stepScaffold).
                        child: const Column(children: [ServiceSessionBanner()]),
                      ),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          child: _step(c),
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}
