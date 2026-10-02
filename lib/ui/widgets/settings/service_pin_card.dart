import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/api_models.dart';
import '../../../services/automation_state.dart';
import '../../common/confirm_dialogs.dart';
import '../../dashboard/labels.dart';
import '../../theme/app_theme.dart';
import 'settings_card.dart';

enum _ListLoad { loading, ready, failed }

/// Ev sahibi için **servis PIN'i** ve servis erişimi yönetimi kartı (`canGenerateServicePin`).
///
/// * PIN üretildiğinde **yalnızca bir kez** gösterilir (sunucu yalnızca özetini saklar; geçmiş
///   listesi PIN göstermez): ekran kapanınca/gizlenince yeniden görüntülenemez, gerekirse yenisi üretilir.
/// * Geri sayım PIN'in kalan geçerlilik süresini gösterir; süre bitince PIN kendiliğinden silinir.
/// * Zaten etkin bir PIN varsa ya da bu ekranda üretilmişse **yeni PIN eskisini iptal eder** uyarısı
///   onay ister.
/// * Açık servis oturumları listelenir ve "Servis erişimini kapat" ile tüm PIN ve oturumlar iptal edilir.
///
/// Anahtarlar: `Key('card_service_pin')`, `Key('btn_generate_service_pin')`, `Key('text_service_pin')`,
/// `Key('text_pin_countdown')`, `Key('btn_hide_service_pin')`, `Key('btn_revoke_service_access')`,
/// `Key('card_service_session_<kimlik>')`, `Key('btn_sessions_retry')`.
class ServicePinCard extends StatefulWidget {
  const ServicePinCard({super.key});

  @override
  State<ServicePinCard> createState() => _ServicePinCardState();
}

class _ServicePinCardState extends State<ServicePinCard> {
  String? _pin;
  DateTime? _expiresAt;
  Timer? _ticker;
  bool _generating = false;
  bool _revoking = false;

  _ListLoad _load = _ListLoad.loading;
  List<ServiceSessionSummary> _sessions = const <ServiceSessionSummary>[];
  bool _hasActivePin = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadLists());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _loadLists() async {
    final state = context.read<AutomationState>();
    setState(() => _load = _ListLoad.loading);
    try {
      final results = await Future.wait<Object>([
        state.fetchServiceSessions(),
        state.fetchServiceTokens(),
      ]).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      final sessions = results[0] as List<ServiceSessionSummary>;
      final tokens = results[1] as List<ServiceTokenSummary>;
      setState(() {
        _sessions = sessions;
        _hasActivePin = tokens.any((t) => t.isActive);
        _load = _ListLoad.ready;
      });
    } catch (_) {
      if (mounted) setState(() => _load = _ListLoad.failed);
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    final clock = context.read<AutomationState>().clock;
    _ticker = clock.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final expires = _expiresAt;
      if (expires == null || !expires.isAfter(clock.now())) {
        _hidePin();
      } else {
        setState(() {});
      }
    });
  }

  void _hidePin() {
    _ticker?.cancel();
    _ticker = null;
    if (!mounted) return;
    setState(() {
      _pin = null;
      _expiresAt = null;
    });
  }

  Future<bool> _confirmReplace() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('dialog_replace_service_pin'),
        title: const Text('Yeni PIN üretilsin mi?'),
        content: const Text(
          'Daha önce üretilen ve henüz kullanılmamış servis PIN\'i yeni PIN üretildiğinde iptal olur. '
          'Teknisyene yeni PIN\'i iletmeniz gerekir.',
        ),
        actions: [
          TextButton(
            key: const Key('btn_replace_pin_cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            key: const Key('btn_replace_pin_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Yeni PIN Üret'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _generate() async {
    if (_generating) return;
    if (_pin != null || _hasActivePin) {
      final ok = await _confirmReplace();
      if (!ok || !mounted) return;
    }
    final state = context.read<AutomationState>();
    setState(() => _generating = true);
    try {
      final pin = await state.generateServicePin();
      if (!mounted) return;
      setState(() {
        _pin = pin;
        _expiresAt = state.servicePinExpiry ?? state.clock.now().add(const Duration(hours: 2));
        _hasActivePin = true;
      });
      _startTicker();
    } catch (e) {
      if (mounted) {
        showFriendlyError(context, e, fallback: 'Servis PIN\'i üretilemedi. Lütfen tekrar deneyin.');
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _revoke() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('dialog_revoke_service_access'),
        title: const Text('Servis erişimi kapatılsın mı?'),
        content: const Text(
          'Kullanılmamış tüm servis PIN\'leri ve açık servis oturumları iptal edilir. Teknisyen '
          'evinize erişemez.',
        ),
        actions: [
          TextButton(
            key: const Key('btn_revoke_cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            key: const Key('btn_revoke_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Erişimi Kapat'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final state = context.read<AutomationState>();
    setState(() => _revoking = true);
    try {
      final result = await state.revokeServiceAccess();
      if (!mounted) return;
      _hidePin();
      setState(() => _hasActivePin = false);
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Servis erişimi kapatıldı: ${result.revokedPins} PIN ve ${result.revokedSessions} oturum iptal edildi.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      unawaited(_loadLists());
    } catch (e) {
      if (mounted) {
        showFriendlyError(context, e, fallback: 'Servis erişimi kapatılamadı. Lütfen tekrar deneyin.');
      }
    } finally {
      if (mounted) setState(() => _revoking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AutomationState>();
    final purple = AppTheme.accentPurple;
    final success = AppTheme.successText(context);
    final remaining = _expiresAt?.difference(state.clock.now());

    return KeyedSubtree(
      key: const Key('card_service_pin'),
      child: SettingsCard(
        icon: Icons.key,
        title: 'Yetkili Servis İçin Geçici PIN',
        accent: purple,
        children: [
          const CardCaption(
            'Kurulum veya arıza için gelen yetkili servisin panoya erişebilmesi için 2 saat süreli '
            'tek kullanımlık bir PIN üretin.',
          ),
          const SizedBox(height: 12),
          if (_pin != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: AppTheme.accentGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.accentGreen.withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  Semantics(
                    liveRegion: false,
                    label: 'Servis PIN\'i: ${_pin!.split('').join(' ')}',
                    child: ExcludeSemantics(
                      child: Text(
                        groupDigits(_pin!),
                        key: const Key('text_service_pin'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 6,
                          color: success,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    remaining == null ? '' : 'Kalan süre ${formatRemaining(remaining)}',
                    key: const Key('text_pin_countdown'),
                    style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            CardCaption(
              'Bu PIN yalnızca şimdi gösterilir. Gizlerseniz ya da bu ekrandan çıkarsanız tekrar '
              'görüntüleyemezsiniz; gerekirse yeni PIN üretin.',
              color: AppTheme.warningText(context),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const Key('btn_hide_service_pin'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _hidePin,
                icon: const Icon(Icons.visibility_off_outlined, size: 18),
                label: const Text('PIN\'i gizle'),
              ),
            ),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('btn_generate_service_pin'),
              onPressed: _generating ? null : () => unawaited(_generate()),
              icon: _generating
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.readableAccent(context, purple)),
                    )
                  : const Icon(Icons.vpn_key_outlined, size: 16),
              label: Text(
                _pin == null && !_hasActivePin ? '6 Haneli Servis PIN\'i Üret' : 'Yeni PIN Üret',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: AppTheme.readableAccent(context, purple),
                side: BorderSide(color: purple),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Açık servis oturumları',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppTheme.getTextPrimary(context),
            ),
          ),
          const SizedBox(height: 6),
          if (_load == _ListLoad.loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_load == _ListLoad.failed)
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Oturumlar yüklenemedi.',
                    style: TextStyle(fontSize: 12.5, color: AppTheme.warningText(context)),
                  ),
                ),
                TextButton(
                  key: const Key('btn_sessions_retry'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => unawaited(_loadLists()),
                  child: const Text('Yeniden dene'),
                ),
              ],
            )
          else if (_sessions.isEmpty)
            const CardCaption('Şu an açık servis oturumu yok.')
          else
            for (final session in _sessions)
              Padding(
                key: Key('card_service_session_${session.id}'),
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.engineering_outlined, size: 18, color: AppTheme.getTextMuted(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        session.technicianName.isEmpty ? 'Servis teknisyeni' : session.technicianName,
                        style: TextStyle(fontSize: 13, color: AppTheme.getTextPrimary(context)),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (session.expiresAt != null)
                      Text(
                        'Bitiş ${formatWhen(session.expiresAt!, now: state.clock.now())}',
                        style: TextStyle(fontSize: 12, color: AppTheme.getTextMuted(context)),
                      ),
                  ],
                ),
              ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              key: const Key('btn_revoke_service_access'),
              onPressed: _revoking ? null : () => unawaited(_revoke()),
              icon: _revoking
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.block, size: 18),
              label: const Text('Servis erişimini kapat'),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: AppTheme.dangerText(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
