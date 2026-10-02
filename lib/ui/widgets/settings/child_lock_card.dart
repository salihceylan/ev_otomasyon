import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../dashboard/child_lock_status.dart';
import '../../dashboard/command_retry.dart';
import '../../theme/app_theme.dart';
import 'child_lock_info_sheet.dart';
import 'hold_to_confirm_button.dart';

/// Ayarlar sayfasındaki **Çocuk Kilidi** kartı.
///
/// * Üç durumlu gösterim: bilinmiyor ("Durum alınıyor…", sonra "alınamadı" + yeniden dene),
///   kapalı, kilitli; ayrıca "uygulanıyor…", "son bilinen" ve "panolar farklı".
/// * Kilitlemek tek dokunuş + dokunsal geri bildirimdir; **kilidi KAPATMAK bilinçli eylemdir**
///   (kimlik doğrulama ya da 1,2 sn basılı tutma): çocuk açık bir telefonla kilidi tek dokunuşla
///   kaldıramaz.
/// * Yetki `capabilities.canChangeChildLock`'tan gelir; yetkisiz kullanıcı (ör. misafir) durumu
///   salt-okunur görür.
/// * Hatalar kabuktaki tek abone tarafından gösterilir; bu kart ayrıca snackbar çıkarmaz.
/// * Erişilebilirlik: tek birleşik düğüm (etiket + değer + ipucu), durum değişimi ekran okuyucuya
///   duyurulur. Açık tema için `getCardColor/getTextPrimary` kullanılır.
///
/// Anahtarlar: `Key('card_child_lock')`, `Key('switch_child_lock')`, `Key('btn_child_lock_info')`,
/// `Key('btn_child_lock_retry')`, `Key('text_child_lock_status')`, `Key('text_child_lock_readonly')`.
class ChildLockCard extends StatefulWidget {
  const ChildLockCard({super.key});

  @override
  State<ChildLockCard> createState() => _ChildLockCardState();
}

class _ChildLockCardState extends State<ChildLockCard> {
  /// "Durum alınıyor…" bu süreden sonra "alınamadı"ya döner (sonsuz bekleme yok).
  static const Duration _unknownTimeout = Duration(seconds: 8);

  Timer? _unknownTimer;
  bool _gaveUp = false;
  ChildLockVm? _previous;

  @override
  void dispose() {
    _unknownTimer?.cancel();
    super.dispose();
  }

  void _syncUnknownTimer(bool unknown) {
    if (!unknown) {
      _unknownTimer?.cancel();
      _unknownTimer = null;
      _gaveUp = false;
      return;
    }
    if (_gaveUp || _unknownTimer != null) return;
    final clock = context.read<AutomationState>().clock;
    _unknownTimer = clock.timer(_unknownTimeout, () {
      _unknownTimer = null;
      if (mounted) setState(() => _gaveUp = true);
    });
  }

  void _announceOnChange(ChildLockVm vm) {
    final previous = _previous;
    _previous = vm;
    if (previous == null) return;
    final changed = previous.status != vm.status || previous.pending != vm.pending;
    if (!changed) return;
    final message = childLockAnnouncement(vm);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final view = View.maybeOf(context);
      if (view == null) return;
      unawaited(SemanticsService.sendAnnouncement(view, message, Directionality.of(context)));
    });
  }

  Future<void> _enable() async {
    final state = context.read<AutomationState>();
    HapticFeedback.mediumImpact();
    // Sonuç ve hata kabuktaki tek aboneye düşer; burada ayrıca hata gösterilmez.
    await runCommand(context, 'childLock', () async => (await state.setChildLock(true)).ok);
  }

  Future<void> _disable() async {
    final state = context.read<AutomationState>();
    final registry = CommandRetryRegistry.maybeOf(context);
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: AppTheme.getSurfaceColor(context),
      builder: (_) => const ChildLockDisableSheet(),
    );
    if (confirmed != true || !mounted) return;
    HapticFeedback.heavyImpact();
    // Kilidi KALDIRMA başarısız olursa eski bir "kilitle" niyeti yeniden denenmesin.
    registry?.discard('childLock');
    await state.setChildLock(false);
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ChildLockVm>(childLockVmOf);
    final state = context.read<AutomationState>();

    final unknown = vm.status == ChildLockStatus.unknown;
    _syncUnknownTimer(unknown);
    _announceOnChange(vm);

    final locked = vm.status == ChildLockStatus.locked;
    final amber = AppTheme.warningText(context);
    final muted = AppTheme.getTextMuted(context);
    final canToggle = vm.canChange && !unknown && !vm.pending;

    final label = unknown && _gaveUp
        ? 'Durum alınamadı. Pano çevrimdışı olabilir.'
        : childLockStatusLabel(vm, now: state.clock.now());

    final hint = !vm.canChange
        ? 'Bu ayarı değiştirme yetkiniz yok'
        : unknown
            ? 'Durum alınıyor'
            : locked
                ? 'Kilidi kaldırmak için doğrulama gerekir'
                : 'Kilitlemek için dokunun';

    return Container(
      key: const Key('card_child_lock'),
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.cardDecoration(
        context,
        accent: locked ? Colors.amber : null,
        radius: 16,
        emphasized: locked,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: locked
                      ? Colors.amber.withValues(alpha: 0.2)
                      : AppTheme.primaryBlue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                    key: ValueKey<bool>(locked),
                    color: locked ? amber : AppTheme.infoText(context),
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Çocuk Kilidi',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.getTextPrimary(context),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                key: const Key('btn_child_lock_info'),
                tooltip: 'Çocuk kilidi nedir?',
                icon: Icon(Icons.info_outline, color: AppTheme.infoText(context)),
                onPressed: () => showChildLockInfoSheet(context),
              ),
            ],
          ),
          const SizedBox(height: 6),
          MergeSemantics(
            child: Semantics(
              label: 'Çocuk kilidi',
              hint: hint,
              liveRegion: true,
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (vm.pending || (unknown && !_gaveUp)) ...[
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.infoText(context),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            label,
                            key: const Key('text_child_lock_status'),
                            style: TextStyle(
                              fontSize: 13,
                              color: locked && !vm.stale ? amber : muted,
                              fontWeight: locked ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    key: const Key('switch_child_lock'),
                    value: locked,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    activeThumbColor: Colors.amber,
                    onChanged: canToggle
                        ? (value) {
                            if (value) {
                              unawaited(_enable());
                            } else {
                              unawaited(_disable());
                            }
                          }
                        : null,
                  ),
                ],
              ),
            ),
          ),
          if (unknown && _gaveUp) ...[
            const SizedBox(height: 4),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const Key('btn_child_lock_retry'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () {
                  setState(() => _gaveUp = false);
                  unawaited(state.refresh());
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Yeniden dene'),
              ),
            ),
          ],
          if (vm.awaitingDevices || vm.offlineDeviceCount > 0) ...[
            const SizedBox(height: 6),
            _Notice(
              icon: Icons.cloud_off_outlined,
              text: vm.offlineDeviceCount > 0
                  ? 'Bazı panolar çevrimdışı (${vm.offlineDeviceCount}). Kilit, çevrimiçi olunca onlara uygulanır.'
                  : 'İstek bekliyor: pano çevrimiçi olunca uygulanacak.',
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Kilitliyken evdeki duvar anahtarları ve butonlar çalışmaz. Uygulama, zamanlı kurallar '
            've diğer telefonlar kontrole devam eder.',
            style: TextStyle(fontSize: 12, color: muted, height: 1.35),
          ),
          if (!vm.canChange) ...[
            const SizedBox(height: 8),
            Text(
              'Bu ayarı yalnızca ev sahibi ve aile üyeleri değiştirebilir.',
              key: const Key('text_child_lock_readonly'),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: amber),
            ),
          ],
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.warningText(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color))),
      ],
    );
  }
}

/// Kilidi KALDIRMAK için bilinçli eylem sayfası: biyometrik/cihaz kimlik doğrulaması (destekleniyorsa)
/// ya da 1,2 sn basılı tutma. Doğrulanınca `true` ile kapanır.
///
/// Anahtarlar: `Key('child_lock_disable_sheet')`, `Key('btn_child_lock_verify')`,
/// `Key('btn_child_lock_hold')`, `Key('btn_child_lock_cancel')`.
class ChildLockDisableSheet extends StatefulWidget {
  const ChildLockDisableSheet({super.key});

  @override
  State<ChildLockDisableSheet> createState() => _ChildLockDisableSheetState();
}

class _ChildLockDisableSheetState extends State<ChildLockDisableSheet> {
  bool _verifying = false;
  String? _error;

  Future<void> _verify() async {
    final state = context.read<AutomationState>();
    setState(() {
      _verifying = true;
      _error = null;
    });
    final ok = await state.biometricService.authenticate(
      reason: 'Çocuk kilidini kaldırmak için kimliğinizi doğrulayın',
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _verifying = false;
        _error = 'Kimlik doğrulanamadı. Çocuk kilidi kaldırılmadı.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final useBiometric = context.select<AutomationState, bool>((s) => s.isBiometricSupported);
    final label = context.select<AutomationState, String>((s) => s.biometricLabel);
    final muted = AppTheme.getTextMuted(context);

    return SingleChildScrollView(
      key: const Key('child_lock_disable_sheet'),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.lock_open_rounded, color: AppTheme.warningText(context), size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Çocuk kilidi kaldırılsın mı?',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.getTextPrimary(context),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Kilit kalkınca evdeki tüm duvar anahtarları yeniden çalışır. Çocukların kilidi yanlışlıkla '
            'kaldırmaması için bu işlem bilinçli bir onay ister.',
            style: TextStyle(fontSize: 13, height: 1.4, color: muted),
          ),
          const SizedBox(height: 16),
          if (useBiometric)
            FilledButton.icon(
              key: const Key('btn_child_lock_verify'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: _verifying ? null : _verify,
              icon: _verifying
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.fingerprint_rounded),
              label: Text('$label ile doğrula'),
            )
          else
            HoldToConfirmButton(
              key: const Key('btn_child_lock_hold'),
              label: 'Kilidi kaldırmak için basılı tutun',
              onConfirmed: () => Navigator.of(context).pop(true),
            ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              key: const Key('text_child_lock_verify_error'),
              style: TextStyle(fontSize: 12.5, color: AppTheme.dangerText(context)),
            ),
          ],
          const SizedBox(height: 10),
          TextButton(
            key: const Key('btn_child_lock_cancel'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç (kilitli kalsın)'),
          ),
        ],
      ),
    );
  }
}
