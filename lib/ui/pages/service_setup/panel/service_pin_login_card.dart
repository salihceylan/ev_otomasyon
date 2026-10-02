import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../services/automation_state.dart';
import '../../../../utils/friendly_error.dart';
import '../../../common/confirm_dialogs.dart';
import '../setup_fields.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';

/// Ev sahibinin verdiği 6 haneli **geçici servis PIN'i** ile oturum açma.
///
/// * PIN alanı gizlidir (göz simgesiyle açılır) ve işlem biter bitmez **temizlenir** (başarıda da,
///   hatada da); PIN loglanmaz, ekranda gösterilmez.
/// * Oturum açmış başka bir kullanıcı varsa, hesabının kapanacağı **onaylatılır**.
/// * Hatalar kullanıcı diliyle gösterilir; kalan deneme hakkı ve kilit süresi belirtilir.
class ServicePinLoginCard extends StatefulWidget {
  const ServicePinLoginCard({super.key, this.onLoggedIn});

  /// Oturum açıldıktan sonra çağrılır.
  final VoidCallback? onLoggedIn;

  @override
  State<ServicePinLoginCard> createState() => _ServicePinLoginCardState();
}

class _ServicePinLoginCardState extends State<ServicePinLoginCard> {
  static const Duration _timeout = Duration(seconds: 30);

  final TextEditingController _pin = TextEditingController();
  final TextEditingController _name = TextEditingController();
  bool _busy = false;
  String? _fieldError;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _name.dispose();
    super.dispose();
  }

  String _loginError(Object error) {
    if (error is ApiException) {
      if (error.isPinLocked || error.isRateLimited) {
        final wait = error.retryAfter;
        final minutes = wait == null ? null : (wait.inSeconds / 60).ceil().clamp(1, 999);
        return minutes == null
            ? 'Çok fazla hatalı deneme yapıldı. Biraz bekleyip tekrar deneyin.'
            : 'Çok fazla hatalı deneme yapıldı. Yaklaşık $minutes dakika sonra tekrar deneyin.';
      }
      if (error.isNetwork) return error.message;
      final left = error.remainingAttempts;
      final base = (error.isUnauthorized || error.isForbidden || error.isInvalidCredentials || error.isNotFound)
          ? 'PIN hatalı ya da süresi dolmuş. Ev sahibinden yeni bir PIN isteyin.'
          : error.message;
      return left == null ? base : '$base Kalan deneme hakkı: $left.';
    }
    return friendlyError(error, fallback: 'Servis oturumu açılamadı. Lütfen tekrar deneyin.');
  }

  Future<void> _login() async {
    if (_busy) return;
    final state = context.read<AutomationState>();
    final pin = _pin.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      setState(() {
        _fieldError = 'PIN tam 6 rakam olmalıdır.';
        _error = null;
      });
      return;
    }
    // Oturum açmış başka bir hesap varsa (ev sahibi vb.) servis oturumu onun yerine geçer.
    if (state.isAuthenticated && !state.isServiceSession) {
      final ok = await showSimpleConfirm(
        context,
        title: 'Mevcut oturum kapatılsın mı?',
        message: 'Şu an başka bir hesapla giriş yapılmış. Servis oturumu açıldığında bu hesabın oturumu '
            'kapatılır; servis oturumu bitince yeniden giriş yapmanız gerekir.',
        confirmLabel: 'Evet, Servis Oturumu Aç',
        destructive: true,
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _busy = true;
      _fieldError = null;
      _error = null;
    });
    final technician = _name.text.trim();
    try {
      await state.loginWithServicePin(pin, technicianName: technician.isEmpty ? null : technician).timeout(_timeout);
      if (!mounted) return;
      _pin.clear();
      setState(() => _busy = false);
      widget.onLoggedIn?.call();
    } catch (e) {
      if (!mounted) return;
      _pin.clear();
      setState(() {
        _busy = false;
        _error = e is TimeoutException
            ? 'Sunucu zamanında yanıt vermedi. Bağlantınızı kontrol edip tekrar deneyin.'
            : _loginError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SetupCard(
      key: const Key('card_service_login'),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_open_rounded, color: SetupColors.readable(context, SetupColors.warn), size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Servis Girişi',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Ev sahibinin uygulamasından aldığı 6 haneli servis PIN\'ini girin. PIN yalnızca o daire için ve '
            '2 saat geçerlidir.',
            style: TextStyle(fontSize: 13, height: 1.35, color: SetupColors.muted(context)),
          ),
          SetupTextField(
            key: const Key('field_technician_name'),
            controller: _name,
            label: 'Adınız Soyadınız (isteğe bağlı)',
            prefixIcon: Icons.badge_outlined,
            textInputAction: TextInputAction.next,
            enabled: !_busy,
          ),
          SecretField(
            key: const Key('field_service_pin'),
            controller: _pin,
            label: 'Servis PIN\'i',
            hint: '6 rakam',
            maxLength: 6,
            keyboardType: TextInputType.number,
            inputFormatters: [digitsOnly],
            errorText: _fieldError,
            monospace: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _login(),
          ),
          if (_error != null)
            SetupCard(
              key: const Key('service_login_error'),
              accent: SetupColors.error,
              margin: const EdgeInsets.only(top: 12),
              child: SetupInfoRow(icon: Icons.error_outline_rounded, color: SetupColors.error, bold: true, text: _error!),
            ),
          const SizedBox(height: 14),
          SetupPrimaryButton(
            key: const Key('btn_service_login'),
            label: 'Servis Oturumu Aç',
            icon: Icons.login_rounded,
            busy: _busy,
            onPressed: _login,
          ),
        ],
      ),
    );
  }
}
