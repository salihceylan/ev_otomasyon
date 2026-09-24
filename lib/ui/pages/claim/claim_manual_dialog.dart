import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../services/automation_state.dart';
import '../../theme/app_theme.dart';

class ClaimManualDialog extends StatefulWidget {
  final String? initialUid;
  final String? initialPin;

  const ClaimManualDialog({
    super.key,
    this.initialUid,
    this.initialPin,
  });

  static Future<bool?> show(
    BuildContext context, {
    String? initialUid,
    String? initialPin,
  }) {
    final state = context.read<AutomationState>();
    return showDialog<bool>(
      context: context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: ClaimManualDialog(
          initialUid: initialUid,
          initialPin: initialPin,
        ),
      ),
    );
  }

  @override
  State<ClaimManualDialog> createState() => _ClaimManualDialogState();
}

class _ClaimManualDialogState extends State<ClaimManualDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _uidController;
  late final TextEditingController _pinController;
  late final TextEditingController _homeNameController;

  bool _obscurePin = true;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _uidController = TextEditingController(text: widget.initialUid ?? '');
    _pinController = TextEditingController(text: widget.initialPin ?? '');
    _homeNameController = TextEditingController(text: 'Evim');
  }

  @override
  void dispose() {
    _uidController.dispose();
    _pinController.dispose();
    _homeNameController.dispose();
    super.dispose();
  }

  Future<void> _handleClaim() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final state = context.read<AutomationState>();
      final res = await state.claimDevice(
        _uidController.text.trim(),
        _pinController.text.trim(),
        homeName: _homeNameController.text.trim().isNotEmpty
            ? _homeNameController.text.trim()
            : 'Evim',
      );

      if (!mounted) return;

      final message = res['message'] ?? 'Cihaz başarıyla evinize eşleştirildi!';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
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
                  'Eşleştirme başarısız: ${e.toString().replaceAll('Exception: ', '')}',
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
          Icon(Icons.qr_code_2_rounded, color: AppTheme.primaryBlueLight, size: 28),
          SizedBox(width: 10),
          Flexible(
            child: Text(
              'Cihaz Eşleştirme',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Pano kapağındaki karekod bilgilerini kontrol edin veya seri numarasını elle girin.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 20),

                // Cihaz UID
                TextFormField(
                  controller: _uidController,
                  style: const TextStyle(color: AppTheme.textPrimary),
                  decoration: _inputDecoration(
                    label: 'Cihaz UID / Seri No',
                    hintText: 'Örn: AHBU-PANEL-9A8B7C',
                    prefixIcon: Icons.fingerprint,
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Lütfen cihaz seri numarasını (UID) girin';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),

                // Kurulum PIN
                TextFormField(
                  controller: _pinController,
                  obscureText: _obscurePin,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: _inputDecoration(
                    label: 'Kurulum PIN Kodu (6 Hane)',
                    hintText: '••••••',
                    prefixIcon: Icons.lock_outline,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePin ? Icons.visibility_off : Icons.visibility,
                        color: AppTheme.textMuted,
                      ),
                      onPressed: () => setState(() => _obscurePin = !_obscurePin),
                    ),
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Lütfen 6 haneli kurulum PIN kodunu girin';
                    }
                    if (val.trim().length != 6) {
                      return 'PIN kodu tam 6 haneli olmalıdır';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 6),

                // Ev / Daire Adı
                TextFormField(
                  controller: _homeNameController,
                  style: const TextStyle(color: AppTheme.textPrimary),
                  decoration: _inputDecoration(
                    label: 'Ev / Daire Adı',
                    hintText: 'Örn: Evim, Yazlık, Daire 4',
                    prefixIcon: Icons.home_outlined,
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
          child: const Text('İptal', style: TextStyle(color: AppTheme.textMuted)),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _handleClaim,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
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
              : const Text('Eşle & Sahiplen', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration({
    required String label,
    required String hintText,
    required IconData prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hintText,
      counterText: '',
      labelStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
      hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
      prefixIcon: Icon(prefixIcon, color: AppTheme.textMuted, size: 20),
      suffixIcon: suffixIcon,
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
        borderSide: const BorderSide(color: AppTheme.primaryBlue, width: 1.8),
      ),
    );
  }
}

