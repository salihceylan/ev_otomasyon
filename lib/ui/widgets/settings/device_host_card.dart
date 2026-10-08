import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../config/app_config.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../theme/app_theme.dart';
import '../../theme/feature_accent.dart';
import '../../theme/tokens.dart';
import 'accent_button.dart';
import 'settings_card.dart';

/// Cihaz yerel adresi (IP) ve yerel anahtar kartı (`canEditDeviceHost`).
///
/// * Adres **yalnızca yerel ağ adresi** olabilir (özel IPv4, `*.local`, `localhost`); başka adresler
///   `AutomationState.setHost` tarafından reddedilir ve hata alanın altında gösterilir (önceki adres
///   korunur).
/// * Başarı mesajı **yalnızca cihaza gerçekten bağlanıldığında** gösterilir; kaydedilip ulaşılamazsa
///   uyarı verilir. Bulut modunda adres yalnızca kaydedilir ("yerel moda geçince kullanılır").
/// * Cihaz anahtarı (8–32 karakter) gizli alanla girilir; hiçbir yerde gösterilmez/loglanmaz.
///
/// Anahtarlar: `Key('card_host')`, `Key('field_host')`, `Key('btn_save_host')`,
/// `Key('field_local_key')`, `Key('btn_toggle_local_key')`, `Key('btn_save_local_key')`,
/// `Key('text_host_result')`, `Key('chip_host_ap')`, `Key('chip_host_last')`.
class DeviceHostCard extends StatefulWidget {
  const DeviceHostCard({super.key});

  @override
  State<DeviceHostCard> createState() => _DeviceHostCardState();
}

class _DeviceHostCardState extends State<DeviceHostCard> {
  late final TextEditingController _hostCtrl;
  final TextEditingController _keyCtrl = TextEditingController();

  bool _busy = false;
  bool _keyBusy = false;
  bool _obscureKey = true;
  String? _hostError;
  String? _keyError;
  ({String text, bool ok})? _result;

  @override
  void initState() {
    super.initState();
    _hostCtrl = TextEditingController(text: context.read<AutomationState>().host);
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveHost() async {
    final state = context.read<AutomationState>();
    final value = _hostCtrl.text.trim();
    if (value.isEmpty) {
      setState(() {
        _hostError = 'Cihaz adresini girin (örn. 192.168.1.20).';
        _result = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _hostError = null;
      _result = null;
    });
    try {
      // Geçersiz/yerel olmayan adres burada `ApiException.validation` fırlatır; önceki adres korunur.
      await state.setHost(value);
      if (!mounted) return;
      if (state.mode == AppMode.direct) {
        final connected = state.status != null &&
            state.connState == ConnectionStateEnum.connected &&
            state.directError == null;
        setState(() {
          _result = connected
              ? (text: 'Cihaza bağlanıldı (${state.host}).', ok: true)
              : (
                  text: 'Adres kaydedildi ancak cihaza ulaşılamadı'
                      '${state.directError == null ? '.' : ': ${state.directError}'}',
                  ok: false,
                );
        });
      } else {
        setState(() {
          _result = (
            text: 'Adres kaydedildi. Yerel ağ moduna geçtiğinizde kullanılacak.',
            ok: true,
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _hostError = friendlyError(e, fallback: 'Adres kaydedilemedi. Lütfen kontrol edin.'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveKey() async {
    final state = context.read<AutomationState>();
    final value = _keyCtrl.text.trim();
    if (value.isEmpty) {
      setState(() => _keyError = 'Cihaz anahtarını girin.');
      return;
    }
    setState(() {
      _keyBusy = true;
      _keyError = null;
      _result = null;
    });
    try {
      await state.setLocalKey(value);
      if (!mounted) return;
      _keyCtrl.clear();
      unawaited(state.refresh());
      setState(() => _result = (text: 'Cihaz anahtarı kaydedildi.', ok: true));
    } catch (e) {
      if (mounted) {
        setState(() => _keyError = friendlyError(e, fallback: 'Anahtar kaydedilemedi.'));
      }
    } finally {
      if (mounted) setState(() => _keyBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.select<AutomationState, ({bool hasKey, String? lastIp, bool direct, bool hasUser})>(
      (s) => (
        hasKey: s.hasLocalKey,
        lastIp: s.lastKnownDeviceIp,
        direct: s.mode == AppMode.direct,
        hasUser: s.currentUser != null,
      ),
    );
    final apHost = AppConfig.current.deviceApHost;
    // Metin/simge yalnız okunur tonla (açık temada ham royal mavi/yeşil/amber ≈2–4.9:1 kalırdı).
    final blue = AppTheme.readableFamily(context, AppFeature.deviceHost.accentFamily);
    final muted = AppTheme.getTextMuted(context);

    // Hızlı adres çipi: hap + aile simgesi (dokunulabilirlik ipucu) + okunur etiket; sınırı bir KONTROL sınırı olarak ≥ 3:1
    // (alan çerçevesiyle aynı dil; dekoratif kart kenarı açıkta 1.4:1'di). Dokunma hedefi padded (≥ 48 dp).
    Widget chip(Key key, String label, String value, {IconData icon = Icons.wifi_tethering_rounded}) => ActionChip(
          key: key,
          avatar: Icon(icon, size: 16, color: blue),
          label: Text(
            label,
            style: TextStyle(fontSize: AppText.caption, fontWeight: FontWeight.w600, color: AppTheme.getTextPrimary(context)),
          ),
          backgroundColor: AppTheme.getInsetColor(context),
          side: BorderSide(color: AppTheme.getFieldBorder(context)),
          shape: const StadiumBorder(),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onPressed: () => setState(() {
            _hostCtrl.text = value;
            _hostError = null;
          }),
        );

    return KeyedSubtree(
      key: const Key('card_host'),
      child: SettingsCard(
        icon: Icons.lan_rounded,
        title: 'Cihaz Yerel Adresi (IP)',
        accent: AppFeature.deviceHost.accentFamily.base,
        children: [
          const CardCaption(
            'Cihazın ev modeminizden aldığı yerel IP adresini ya da kurtarma (AP) adresini girin. '
            'Yalnızca yerel ağ adresleri kabul edilir.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('field_host'),
            controller: _hostCtrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_hostError != null || _result != null) {
                setState(() {
                  _hostError = null;
                  _result = null;
                });
              }
            },
            onSubmitted: (_) => unawaited(_saveHost()),
            decoration: InputDecoration(
              labelText: 'Cihaz adresi',
              // Boşken etiket de ikincil metin tonunda (tam metin rengi alan dolu gibi görünüyordu).
              labelStyle: TextStyle(color: muted),
              hintText: 'Örn: 192.168.1.20 veya $apHost',
              errorText: _hostError,
              errorMaxLines: 3,
              prefixIcon: Icon(Icons.lan_outlined, color: blue),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              chip(const Key('chip_host_ap'), '$apHost (kurtarma ağı)', apHost),
              if (vm.lastIp != null && vm.lastIp!.isNotEmpty)
                chip(const Key('chip_host_last'), 'Son bilinen: ${vm.lastIp}', vm.lastIp!, icon: Icons.history_rounded),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const Key('btn_save_host'),
              onPressed: _busy ? null : () => unawaited(_saveHost()),
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check_circle_outline),
              label: Text(
                vm.direct ? 'Kaydet ve Bağlan' : 'Adresi Kaydet',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              style: accentButtonStyle(null),
            ),
          ),
          if (_result != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _result!.ok ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                  size: 18,
                  color: _result!.ok ? AppTheme.successText(context) : AppTheme.warningText(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _result!.text,
                    key: const Key('text_host_result'),
                    style: TextStyle(
                      fontSize: 12.5,
                      color: _result!.ok ? AppTheme.successText(context) : AppTheme.warningText(context),
                    ),
                  ),
                ),
              ],
            ),
          ],
          Divider(color: AppTheme.getCardBorder(context), height: 28),
          Row(
            children: [
              Icon(Icons.vpn_key_outlined, size: 18, color: AppTheme.getTextMuted(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  vm.hasKey ? 'Cihaz anahtarı kayıtlı' : 'Cihaz anahtarı kayıtlı değil',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: vm.hasKey ? AppTheme.successText(context) : AppTheme.warningText(context),
                  ),
                ),
              ),
            ],
          ),
          if (!vm.hasUser) ...[
            const SizedBox(height: 4),
            const CardCaption(
              'Cihaz anahtarı etikette yazmaz; hesabınızla giriş yaparsanız (ev sahibi/üye) anahtar otomatik alınır.',
              key: Key('text_local_key_hint'),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            key: const Key('field_local_key'),
            controller: _keyCtrl,
            obscureText: _obscureKey,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => unawaited(_saveKey()),
            onChanged: (_) {
              if (_keyError != null) setState(() => _keyError = null);
            },
            decoration: InputDecoration(
              // Uzun etiket 1.0'da bile "…" ile kesiliyordu: ayrıntı yardımcı metne taşındı.
              labelText: 'Cihaz anahtarı',
              helperText: '8–32 karakter',
              labelStyle: TextStyle(color: muted),
              helperStyle: TextStyle(color: muted),
              errorText: _keyError,
              errorMaxLines: 3,
              prefixIcon: Icon(Icons.vpn_key_outlined, color: blue),
              suffixIcon: IconButton(
                key: const Key('btn_toggle_local_key'),
                tooltip: _obscureKey ? 'Anahtarı göster' : 'Anahtarı gizle',
                icon: Icon(_obscureKey ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const Key('btn_save_local_key'),
              onPressed: _keyBusy ? null : () => unawaited(_saveKey()),
              icon: _keyBusy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(Icons.save_outlined, size: accentIconSize(context)),
              label: const Text('Anahtarı Kaydet', style: TextStyle(fontWeight: FontWeight.bold)),
              style: accentOutlinedButtonStyle(context, AppFeature.deviceHost.accentFamily),
            ),
          ),
        ],
      ),
    );
  }
}
