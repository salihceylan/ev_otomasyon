import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../utils/magic_link_parser.dart';
import '../../common/app_dialogs.dart';
import '../../common/auth_form.dart';
import '../../common/confirm_dialogs.dart' show AuthDialogActions, AuthDialogShell, authPrimaryLabel, authSecondaryLabel;
import '../../common/inline_message.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'magic_link_page.dart';

/// E-postadaki bağlantıyı elle yapıştırma (derin bağlantı açılmadığında yedek yol).
///
/// Bağlantı `MagicLinkParser` ile **sıkı** doğrulanır (https, izinli ana makine, belirteç yalnızca
/// `#token=` parçasında); geçerliyse `MagicLinkPage` açılır. Yapıştırılan metin/belirteç saklanmaz.
class MagicLinkDialog extends StatefulWidget {
  const MagicLinkDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showAppDialog<void>(context, builder: (_) => const MagicLinkDialog());
  }

  @override
  State<MagicLinkDialog> createState() => _MagicLinkDialogState();
}

class _MagicLinkDialogState extends State<MagicLinkDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty || !mounted) return;
    setState(() {
      _controller.text = text.trim();
      _error = null;
    });
  }

  void _continue() {
    final result = MagicLinkParser.parseDetailed(_controller.text);
    final link = result.link;
    if (link == null) {
      setState(() => _error = result.error?.message ?? 'Bağlantı geçersiz.');
      return;
    }
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(MaterialPageRoute<void>(builder: (_) => MagicLinkPage(link: link)));
  }

  @override
  Widget build(BuildContext context) {
    // Giriş ekranı ve diyalogları temaya uyar (koyu + açık eşit kalite); ortak diyalog kabuğu ([AuthDialogShell]).
    return AuthDialogShell(
      icon: Icons.link_rounded,
      family: AppFamilies.cyan,
      title: 'E-postadaki Bağlantı',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Size e-posta ile gelen giriş veya şifre sıfırlama bağlantısını buraya yapıştırın.',
            style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('field_magic_link'),
            controller: _controller,
            minLines: 2,
            maxLines: 4,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 13),
            decoration: authInputDecoration(
              context,
              hint: 'https://.../reset-password#token=...',
              suffixIcon: IconButton(
                key: const Key('btn_paste_link'),
                tooltip: 'Panodan yapıştır',
                icon: Icon(Icons.content_paste_rounded, color: AppTheme.infoText(context)),
                onPressed: _paste,
              ),
            ).copyWith(hintStyle: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 12)),
          ),
          if (_error != null) ...[const SizedBox(height: 10), InlineMessage.error(_error!, key: const Key('magic_link_error'))],
        ],
      ),
      actions: AuthDialogActions(
        secondaryLabel: 'İptal',
        secondary: TextButton(
          key: const Key('btn_magic_link_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: authSecondaryLabel(context, 'İptal'),
        ),
        primaryLabel: 'Devam',
        primary: ElevatedButton(
          key: const Key('btn_magic_link_continue'),
          onPressed: _continue,
          child: authPrimaryLabel('Devam'),
        ),
      ),
    );
  }
}
