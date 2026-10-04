import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../services/ev_cloud_api_service.dart';
import '../../../utils/friendly_error.dart';
import '../../common/app_dialogs.dart';
import '../../common/confirm_dialogs.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../theme/app_theme.dart';
import '../../widgets/settings/accent_button.dart';
import '../../theme/tokens.dart';
import '../../widgets/orb/orb.dart';
import '../../widgets/surface_card.dart';
import 'step_progress.dart';

/// Girilen/taranan davet veya devir kodunun normalleştirilmiş hâli.
class JoinCodeInput {
  const JoinCodeInput({required this.code, required this.isTransfer});

  /// Sunucuya gönderilecek kod (`AHBU-...` ya da `AHBU-TR-...`; büyük harf, boşluksuz).
  final String code;

  /// `true`: daire devir kodu (yıkıcı), `false`: aile/misafir davet kodu.
  final bool isTransfer;
}

final RegExp _inviteBody = RegExp(r'^AHBU-(?:G-)?[A-Z0-9]{4,24}$');
final RegExp _transferBody = RegExp(r'^AHBU-TR-[A-Z0-9]{6,32}$');

/// Kullanıcının yazdığı/QR'dan gelen kodu normalleştirir: kırp, boşlukları at, büyük harf,
/// `AHBU-INVITE:` / `AHBU-TRANSFER:` öneklerini çöz, eksik `AHBU-` önekini tamamla ve türünü belirle.
/// Geçersizse `null`.
JoinCodeInput? parseJoinCode(String? raw) {
  var s = (raw ?? '').trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
  if (s.isEmpty || s.length > 80) return null;
  if (s.startsWith('AHBU-TRANSFER:')) {
    s = s.substring('AHBU-TRANSFER:'.length);
    if (!s.startsWith('AHBU-TR-')) s = 'AHBU-TR-$s';
    return _transferBody.hasMatch(s) ? JoinCodeInput(code: s, isTransfer: true) : null;
  }
  if (s.startsWith('AHBU-TR-')) {
    return _transferBody.hasMatch(s) ? JoinCodeInput(code: s, isTransfer: true) : null;
  }
  if (s.startsWith('AHBU-INVITE:')) s = s.substring('AHBU-INVITE:'.length);
  if (!s.startsWith('AHBU-')) s = 'AHBU-$s';
  return _inviteBody.hasMatch(s) ? JoinCodeInput(code: s, isTransfer: false) : null;
}

/// Eve katıl / daireyi devral diyaloğu.
///
/// İki adım: (1) kod girişi (normalleştirilir), (2) **önizleme + onay**. Önizleme ev adı ve sakin
/// sayısını gösterir (sunucu `join-preview` ucunu sağlıyorsa; yoksa kodun türü ve sonuçları gösterilir).
/// Daire devri **yıkıcıdır** (mevcut tüm sakinlerin erişimi kalkar): `DEVRAL` yazılarak onaylanır.
class JoinHomeDialog extends StatefulWidget {
  const JoinHomeDialog({super.key, this.initialCode});

  /// QR taramasından gelen kod (girişe yazılır; kullanıcı önce önizlemeyi görür).
  final String? initialCode;

  static Future<bool?> show(BuildContext context, {String? initialCode}) {
    final state = context.read<AutomationState>();
    return showAppDialog<bool>(
      context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: JoinHomeDialog(initialCode: initialCode),
      ),
    );
  }

  @override
  State<JoinHomeDialog> createState() => _JoinHomeDialogState();
}

enum _JoinStep { enter, confirm }

class _JoinHomeDialogState extends State<JoinHomeDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _codeController;
  final TextEditingController _phraseController = TextEditingController();

  _JoinStep _step = _JoinStep.enter;
  bool _busy = false;
  String? _error;
  JoinCodeInput? _input;
  JoinCodePreview? _preview;
  bool _previewUnavailable = false;
  int _run = 0;

  /// İşlem (önizleme / katılım) bu süreyi aşarsa "Kapat" sunulur (PF-50); REST + ev listesi + ev seçimi
  /// zinciri yavaş ağda 30 sn'yi aşabilir ve diyalog o süre boyunca kapanmıyordu.
  static const Duration _slowAfter = Duration(seconds: 25);
  Timer? _slowTimer;
  bool _slow = false;

  static const String _transferPhrase = 'DEVRAL';

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController(text: widget.initialCode ?? '');
    _phraseController.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// Meşgul durumunu başlatır ve [_slowAfter] sonra "yavaş" bayrağını kurar (`setState` içinde çağrılır).
  /// Zamanlayıcı `Clock`'tandır (testlerde sahte saat).
  void _beginBusy() {
    _busy = true;
    _slow = false;
    _slowTimer?.cancel();
    _slowTimer = context.read<AutomationState>().clock.timer(_slowAfter, () {
      if (mounted && _busy) setState(() => _slow = true);
    });
  }

  /// Meşgul durumunu bitirir (`setState` içinde çağrılır).
  void _endBusy() {
    _busy = false;
    _slow = false;
    _slowTimer?.cancel();
    _slowTimer = null;
  }

  /// 25 sn sonra "Kapat": işlem sunucuda sürer, sonuç [_confirm] içinde yine bildirilir.
  void _closeWhileBusy() => Navigator.of(context).pop(false);

  @override
  void dispose() {
    _run++;
    _slowTimer?.cancel();
    _phraseController.removeListener(_rebuild);
    _codeController.dispose();
    _phraseController.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    final input = parseJoinCode(_codeController.text)!;
    final state = context.read<AutomationState>();
    final run = ++_run;
    setState(() {
      _beginBusy();
      _error = null;
    });
    JoinCodePreview? preview;
    var unavailable = false;
    try {
      preview = await state.previewJoinCode(input.code).timeout(const Duration(seconds: 12));
      unavailable = preview == null;
    } catch (e) {
      if (!mounted || run != _run) return;
      setState(() {
        _endBusy();
        _error = friendlyError(e, fallback: 'Kod doğrulanamadı. Lütfen tekrar deneyin.');
      });
      return;
    }
    if (!mounted || run != _run) return;
    setState(() {
      _endBusy();
      _input = input;
      _preview = preview;
      _previewUnavailable = unavailable;
      _phraseController.clear();
      _step = _JoinStep.confirm;
    });
  }

  void _back() {
    if (_busy) return;
    _run++;
    setState(() {
      _step = _JoinStep.enter;
      _error = null;
      _phraseController.clear();
    });
  }

  bool get _confirmEnabled {
    final input = _input;
    if (input == null || _busy) return false;
    return input.isTransfer ? confirmPhraseMatches(_phraseController.text, _transferPhrase) : true;
  }

  Future<void> _confirm() async {
    final input = _input;
    if (input == null || _busy || !_confirmEnabled) return; // çift dokunuş koruması
    final state = context.read<AutomationState>();
    // PF-50: kullanıcı 25 sn sonra "Kapat"a basarsa diyalog kapanır ama istek sürer; sonuç yine de bildirilsin.
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _beginBusy();
      _error = null;
    });
    try {
      final String message;
      if (input.isTransfer) {
        final res = await state.acceptHomeTransfer(input.code);
        message = res.message.isNotEmpty ? res.message : 'Daire mülkiyeti başarıyla devralındı!';
      } else {
        final res = await state.joinHome(input.code);
        message = res.alreadyMember
            ? 'Zaten bu evin üyesisiniz.'
            : (res.message.isNotEmpty ? res.message : 'Eve başarıyla katıldınız!');
      }
      _showResult(messenger, message, success: true);
      if (!mounted) return; // kullanıcı "Kapat"a bastı: sonuç yukarıda bildirildi
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) {
        _showResult(messenger, _joinErrorMessage(e, input.isTransfer), success: false);
        return;
      }
      setState(() {
        _endBusy();
        _error = _joinErrorMessage(e, input.isTransfer);
      });
    }
  }

  static void _showResult(ScaffoldMessengerState? messenger, String message, {required bool success}) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
        // Beyaz yazılı dolgu tonu (ham yeşil/kırmızı zeminde beyaz metin 2.5–3.8:1 idi).
        backgroundColor: AppTheme.filledAccent(success ? AppTheme.accentGreen : AppTheme.accentRed),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _joinErrorMessage(Object e, bool transfer) {
    if (e is ApiException) {
      if (e.isGone) return 'Bu kodun süresi dolmuş veya daha önce kullanılmış. Yeni bir kod isteyin.';
      if (e.isRateLimited) return 'Çok fazla deneme yapıldı. Biraz bekleyip tekrar deneyin.';
      if (e.isNetwork) return 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edip tekrar deneyin.';
      return e.message;
    }
    return friendlyError(e, fallback: transfer ? 'Devralma tamamlanamadı.' : 'Katılım tamamlanamadı.');
  }

  @override
  Widget build(BuildContext context) {
    // PF-06: yalnız servis oturumu izlenir; ilgisiz bildirim diyaloğu yeniden kurmaz.
    final forbidden = context.select<AutomationState, bool>((s) => s.isServiceSession);

    return PopScope(
      canPop: !_busy || _slow,
      // Yüzey ve şekil temanın diyalog stilinden gelir (yerel override yok). Yatay boşluk 16: içerik genişliği 280 → 328 dp.
      child: AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Row(
          children: [
            OrbIconBadge(
              icon: (_input?.isTransfer ?? false) ? Icons.swap_horiz_rounded : Icons.vpn_key_rounded,
              family: (_input?.isTransfer ?? false) ? AppFamilies.amber : AppFamilies.emerald,
              active: _step == _JoinStep.confirm,
              pending: _busy,
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                _step == _JoinStep.enter
                    ? 'Bir Eve Katıl'
                    : ((_input?.isTransfer ?? false) ? 'Daire Devrini Onayla' : 'Katılımı Onayla'),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
                // En çok 2 satır: büyük yazıda anlamı taşıyan "Onayla" kesilmesin.
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: SingleChildScrollView(
            child: forbidden
                ? const InlineMessage.error('Servis oturumuyla bir eve katılamazsınız.', key: Key('join_forbidden'))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      StepProgress(
                        step: _step == _JoinStep.enter ? 1 : 2,
                        total: 2,
                        color: (_input?.isTransfer ?? false) ? AppFamilies.amber : AppFamilies.emerald,
                        padding: const EdgeInsets.only(bottom: 14),
                      ),
                      _step == _JoinStep.enter ? _buildEnter(context) : _buildConfirm(context),
                    ],
                  ),
          ),
        ),
        actions: forbidden
            ? [
                TextButton(
                  key: const Key('btn_join_cancel'),
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Kapat'),
                ),
              ]
            : (_step == _JoinStep.enter ? _enterActions(context) : _confirmActions(context)),
      ),
    );
  }

  List<Widget> _enterActions(BuildContext context) => [
        TextButton(
          key: const Key('btn_join_cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text('İptal', style: TextStyle(color: AppTheme.getTextMuted(context))),
        ),
        ElevatedButton(
          key: const Key('btn_join_continue'),
          onPressed: _busy ? null : _continue,
          style: accentButtonStyle(AppFamilies.emerald),
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Devam', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ];

  List<Widget> _confirmActions(BuildContext context) {
    final transfer = _input?.isTransfer ?? false;
    return [
      if (_busy && _slow)
        TextButton(
          key: const Key('btn_join_close_pending'),
          onPressed: _closeWhileBusy,
          child: Text('Kapat', style: TextStyle(color: AppTheme.getTextMuted(context))),
        )
      else
        TextButton(
          key: const Key('btn_join_back'),
          onPressed: _busy ? null : _back,
          child: Text('Geri', style: TextStyle(color: AppTheme.getTextMuted(context))),
        ),
      ElevatedButton(
        key: const Key('btn_join_confirm'),
        onPressed: _confirmEnabled ? _confirm : null,
        style: accentButtonStyle(transfer ? AppFamilies.rose : AppFamilies.emerald),
        child: _busy
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Text(transfer ? 'Daireyi Devral' : 'Eve Katıl', style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    ];
  }

  Widget _buildEnter(BuildContext context) {
    final muted = AppTheme.getTextMuted(context);
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ev sahibinin sizinle paylaştığı aile/misafir davet kodunu ya da daire devir kodunu girin '
            '(QR kodun altındaki metin de olur).',
            style: TextStyle(color: muted, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 18),
          TextFormField(
            key: const Key('field_join_code'),
            controller: _codeController,
            enabled: !_busy,
            textCapitalization: TextCapitalization.characters,
            textAlign: TextAlign.center,
            autocorrect: false,
            enableSuggestions: false,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9:\- ]')),
              LengthLimitingTextInputFormatter(64),
            ],
            onFieldSubmitted: (_) => _continue(),
            style: TextStyle(
              color: AppTheme.getTextPrimary(context),
              fontSize: 18,
              letterSpacing: 2,
              fontWeight: FontWeight.bold,
            ),
            // Alan biçimi (dolgu, köşe, odak halkası) temanın giriş stilinden gelir.
            decoration: InputDecoration(
              labelText: 'Davet / Devir Kodu',
              hintText: 'AHBU-XXXXXXXXXX',
              hintStyle: TextStyle(color: muted, letterSpacing: 1, fontSize: 14),
              prefixIcon: Icon(Icons.tag, color: muted),
            ),
            validator: (val) {
              if (val == null || val.trim().isEmpty) return 'Lütfen davet kodunu girin';
              if (parseJoinCode(val) == null) return 'Geçerli bir davet veya devir kodu girin';
              return null;
            },
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            _busyNotice('Kod doğrulanıyor…'),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            InlineMessage.error(_error!, key: const Key('join_error')),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// İşlem sürerken belirgin ilerleme (PF-50); 25 sn sonra "Kapat" yolu açıklanır.
  Widget _busyNotice(String message) => DialogBusyNotice(
        key: const Key('join_busy_notice'),
        message: message,
        slow: _slow,
        slowMessage: 'Sunucu yanıtı gecikiyor. Beklemeye devam edebilir ya da "Kapat"a basabilirsiniz; '
            'işlem arka planda sürer ve sonucu bildirilir.',
      );

  Widget _buildConfirm(BuildContext context) {
    final input = _input!;
    final preview = _preview;
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);

    // Büyük yazı ölçeğinde (> 1.3) sabit 108 dp'lik etiket sütunu değer sütununu daraltıp "Yazlık Daire / 12"
    // ya da tarih/saat ayrılması gibi yetim satırlar üretiyordu: etiket üstte, değer altta.
    final stackedRows = MediaQuery.textScalerOf(context).scale(10) > 13;
    Widget row(String label, String value, {Key? key}) {
      final labelText = Text(label, style: TextStyle(color: muted, fontSize: 12.5));
      final valueText = Text(
        value,
        key: key,
        style: TextStyle(color: primary, fontSize: 13, fontWeight: FontWeight.w600),
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: stackedRows
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [labelText, valueText])
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 108, child: labelText),
                  Expanded(child: valueText),
                ],
              ),
      );
    }

    final roleText = switch (preview?.role) {
      'guest' => 'Süreli misafir',
      'owner' => 'Ev sahibi',
      'resident' => 'Aile üyesi',
      _ => null,
    };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SurfaceCard(
          padding: const EdgeInsets.all(12),
          radius: AppRadius.r16,
          child: Column(
            key: const Key('join_preview'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              row('İşlem', input.isTransfer ? 'Daire devri (mülkiyet)' : 'Aile / misafir daveti'),
              row('Ev', preview?.homeName ?? 'Onaydan sonra görünür', key: const Key('join_preview_home')),
              if (preview?.residentCount != null)
                row('Mevcut sakin', '${preview!.residentCount} kişi', key: const Key('join_preview_residents')),
              if (roleText != null) row('Rolünüz', roleText),
              if (preview?.guestValidFrom != null)
                row('Erişim başlangıcı', formatLocalDateTime(preview!.guestValidFrom!), key: const Key('join_preview_guest_from')),
              if (preview?.guestValidUntil != null)
                row('Erişim bitişi', formatLocalDateTime(preview!.guestValidUntil!), key: const Key('join_preview_guest_until')),
              if (preview?.expiresAt != null) row('Kod geçerliliği', formatLocalDateTime(preview!.expiresAt!)),
            ],
          ),
        ),
        if (preview?.alreadyMember ?? false) ...[
          const SizedBox(height: 10),
          const InlineMessage.info(
            'Bu dairenin zaten üyesisiniz. Devam etmeniz yeni bir üyelik oluşturmaz ve davet kodu kullanılmaz.',
            key: Key('join_already_member'),
          ),
        ],
        if (_previewUnavailable) ...[
          const SizedBox(height: 10),
          const InlineMessage.info(
            'Ev bilgileri bu kod için önceden gösterilemiyor; yalnızca onayladıktan sonra görünür.',
            key: Key('join_preview_unavailable'),
          ),
        ],
        const SizedBox(height: 12),
        if (input.isTransfer) ...[
          InlineMessage.error(
            'DİKKAT: Onaylarsanız bu dairenin TEK SAHİBİ siz olursunuz. Mevcut ev sahibi dahil '
            'tüm sakinlerin ve misafirlerin bu evdeki erişimi kalıcı olarak kaldırılır; servis erişimleri '
            've davetler iptal edilir. Bu işlem geri alınamaz.',
            key: const Key('join_transfer_warning'),
          ),
          const SizedBox(height: 12),
          Text.rich(
            TextSpan(
              style: TextStyle(color: primary, fontSize: 13),
              children: [
                const TextSpan(text: 'Onaylamak için '),
                TextSpan(
                  text: _transferPhrase,
                  // Okunur tehlike tonu (açık temada ham #EF4444 ≈3.8:1 idi).
                  style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.dangerText(context)),
                ),
                const TextSpan(text: ' yazın:'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('field_join_confirm_phrase'),
            controller: _phraseController,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(isDense: true, hintText: _transferPhrase),
          ),
        ] else
          Text(
            'Katılırsanız bu evin cihazlarını rolünüzün izin verdiği ölçüde kontrol edebilirsiniz.',
            style: TextStyle(color: muted, fontSize: 12.5, height: 1.4),
          ),
        if (_busy) ...[
          const SizedBox(height: 12),
          _busyNotice(input.isTransfer ? 'Devir isteği işleniyor…' : 'Katılım isteği işleniyor…'),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          InlineMessage.error(_error!, key: const Key('join_error')),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}
