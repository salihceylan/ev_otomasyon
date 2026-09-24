import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';

class JoinHomeDialog extends StatefulWidget {
  const JoinHomeDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    final state = context.read<AutomationState>();
    return showDialog<bool>(
      context: context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: const JoinHomeDialog(),
      ),
    );
  }

  @override
  State<JoinHomeDialog> createState() => _JoinHomeDialogState();
}

class _JoinHomeDialogState extends State<JoinHomeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _handleJoin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final state = context.read<AutomationState>();
      final inputCode = _codeController.text.trim();
      final isTransfer = inputCode.toUpperCase().startsWith('AHBU-TR-') ||
          inputCode.toUpperCase().startsWith('AHBU-TRANSFER:');

      final res = isTransfer
          ? await state.acceptHomeTransfer(inputCode)
          : await state.joinHome(inputCode);

      if (!mounted) return;

      final message = res['message'] ??
          (isTransfer ? 'Daire mülkiyeti başarıyla devralındı!' : 'Eve başarıyla katıldınız!');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.home_outlined, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message.toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          backgroundColor: AppTheme.accentGreen,
          behavior: SnackBarBehavior.floating,
        ),
      );

      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Katılım başarısız: ${e.toString().replaceAll('Exception: ', '')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          backgroundColor: AppTheme.accentRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surfaceDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppTheme.cardBorder, width: 1.2),
      ),
      title: Row(
        children: const [
          Icon(Icons.vpn_key_outlined, color: AppTheme.accentGreen, size: 26),
          SizedBox(width: 10),
          Flexible(
            child: Text(
              'Bir Eve Katıl',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Ev sahibinin sizinle paylaştığı 24 saat geçerli aile davet kodunu giriniz.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _codeController,
                  textCapitalization: TextCapitalization.characters,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 20,
                    letterSpacing: 3,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Davet Kodu',
                    hintText: 'AHBU-123456',
                    hintStyle: const TextStyle(color: AppTheme.textMuted, letterSpacing: 2, fontSize: 14),
                    prefixIcon: const Icon(Icons.tag, color: AppTheme.textMuted),
                    filled: true,
                    fillColor: AppTheme.cardDark,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppTheme.cardBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppTheme.cardBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppTheme.accentGreen, width: 1.8),
                    ),
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Lütfen davet kodunu girin';
                    }
                    if (val.trim().length < 5) {
                      return 'Geçerli bir davet kodu girin';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
          child: const Text('İptal', style: TextStyle(color: AppTheme.textMuted)),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _handleJoin,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.accentGreen,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: _isLoading
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Eve Katıl', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

