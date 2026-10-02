import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../services/automation_state.dart';
import '../../../services/ev_cloud_api_service.dart';
import '../../../utils/friendly_error.dart';
import '../../common/confirm_dialogs.dart';
import '../../common/date_format.dart';
import '../../common/inline_message.dart';
import '../../theme/app_theme.dart';

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
    return showDialog<bool>(
      context: context,
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

  @override
  void dispose() {
    _run++;
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
      _busy = true;
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
        _busy = false;
        _error = friendlyError(e, fallback: 'Kod doğrulanamadı. Lütfen tekrar deneyin.');
      });
      return;
    }
    if (!mounted || run != _run) return;
    setState(() {
      _busy = false;
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
    setState(() {
      _busy = true;
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
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
          backgroundColor: AppTheme.accentGreen,
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _joinErrorMessage(e, input.isTransfer);
      });
    }
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
    final state = context.watch<AutomationState>();
    final forbidden = state.isServiceSession;

    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        backgroundColor: AppTheme.getSurfaceColor(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppTheme.getCardBorder(context), width: 1.2),
        ),
        title: Row(
          children: [
            const Icon(Icons.vpn_key_outlined, color: AppTheme.accentGreen, size: 26),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                _step == _JoinStep.enter
                    ? 'Bir Eve Katıl'
                    : ((_input?.isTransfer ?? false) ? 'Daire Devrini Onayla' : 'Katılımı Onayla'),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
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
                : (_step == _JoinStep.enter ? _buildEnter(context) : _buildConfirm(context)),
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
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentGreen,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
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
      TextButton(
        key: const Key('btn_join_back'),
        onPressed: _busy ? null : _back,
        child: Text('Geri', style: TextStyle(color: AppTheme.getTextMuted(context))),
      ),
      ElevatedButton(
        key: const Key('btn_join_confirm'),
        onPressed: _confirmEnabled ? _confirm : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: transfer ? AppTheme.accentRed : AppTheme.accentGreen,
          foregroundColor: Colors.white,
          disabledBackgroundColor: (transfer ? AppTheme.accentRed : AppTheme.accentGreen).withValues(alpha: 0.25),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
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
            decoration: InputDecoration(
              labelText: 'Davet / Devir Kodu',
              hintText: 'AHBU-XXXXXXXXXX',
              hintStyle: TextStyle(color: muted, letterSpacing: 1, fontSize: 14),
              prefixIcon: Icon(Icons.tag, color: muted),
              filled: true,
              fillColor: AppTheme.getCardColor(context),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppTheme.getCardBorder(context)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppTheme.getCardBorder(context)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.accentGreen, width: 1.8),
              ),
            ),
            validator: (val) {
              if (val == null || val.trim().isEmpty) return 'Lütfen davet kodunu girin';
              if (parseJoinCode(val) == null) return 'Geçerli bir davet veya devir kodu girin';
              return null;
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            InlineMessage.error(_error!, key: const Key('join_error')),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildConfirm(BuildContext context) {
    final input = _input!;
    final preview = _preview;
    final muted = AppTheme.getTextMuted(context);
    final primary = AppTheme.getTextPrimary(context);

    Widget row(String label, String value, {Key? key}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 108, child: Text(label, style: TextStyle(color: muted, fontSize: 12.5))),
              Expanded(
                child: Text(
                  value,
                  key: key,
                  style: TextStyle(color: primary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );

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
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.getCardColor(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.getCardBorder(context)),
          ),
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
              children: const [
                TextSpan(text: 'Onaylamak için '),
                TextSpan(text: _transferPhrase, style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.accentRed)),
                TextSpan(text: ' yazın:'),
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
        if (_error != null) ...[
          const SizedBox(height: 12),
          InlineMessage.error(_error!, key: const Key('join_error')),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}
