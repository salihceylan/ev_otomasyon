import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'setup_style.dart';

/// Sihirbazın metin alanı: tutarlı biçim, açık etiket, erişilebilirlik.
class SetupTextField extends StatelessWidget {
  const SetupTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.errorText,
    this.helperText,
    this.keyboardType,
    this.textInputAction,
    this.maxLength,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.textCapitalization = TextCapitalization.none,
    this.prefixIcon,
    this.suffixIcon,
    this.obscureText = false,
    this.autofillHints,
    this.maxLines = 1,
    this.monospace = false,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? errorText;
  final String? helperText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final int? maxLength;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final TextCapitalization textCapitalization;
  final IconData? prefixIcon;
  final Widget? suffixIcon;
  final bool obscureText;
  final Iterable<String>? autofillHints;
  final int maxLines;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: TextField(
        controller: controller,
        enabled: enabled,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        maxLength: maxLength,
        maxLines: obscureText ? 1 : maxLines,
        inputFormatters: inputFormatters,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textCapitalization: textCapitalization,
        obscureText: obscureText,
        autocorrect: false,
        enableSuggestions: !obscureText,
        autofillHints: autofillHints,
        style: TextStyle(
          fontSize: 15,
          color: SetupColors.text(context),
          fontFamily: monospace ? 'monospace' : null,
        ),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: errorText,
          helperText: helperText,
          helperMaxLines: 3,
          errorMaxLines: 3,
          counterText: '',
          prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, size: 20),
          suffixIcon: suffixIcon,
          filled: true,
          fillColor: SetupColors.isDark(context) ? const Color(0xFF0F172A) : Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
    );
  }
}

/// Gizli değer alanı (PIN, parola, anahtar): varsayılan olarak gizli, göz simgesiyle gösterilir.
class SecretField extends StatefulWidget {
  const SecretField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.errorText,
    this.helperText,
    this.maxLength,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
    this.prefixIcon = Icons.lock_outline_rounded,
    this.monospace = false,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? errorText;
  final String? helperText;
  final int? maxLength;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;
  final IconData prefixIcon;
  final bool monospace;

  @override
  State<SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<SecretField> {
  bool _hidden = true;

  /// Göz düğmesinin anahtarı: alanın `field_<ad>` anahtarından türetilir (`btn_secret_toggle_<ad>`);
  /// alan anahtarsızsa düğme de anahtarsızdır.
  Key? get _toggleKey {
    final k = widget.key;
    if (k is ValueKey<String> && k.value.startsWith('field_')) {
      return Key('btn_secret_toggle_${k.value.substring('field_'.length)}');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return SetupTextField(
      controller: widget.controller,
      label: widget.label,
      hint: widget.hint,
      errorText: widget.errorText,
      helperText: widget.helperText,
      maxLength: widget.maxLength,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      textInputAction: widget.textInputAction,
      obscureText: _hidden,
      prefixIcon: widget.prefixIcon,
      monospace: widget.monospace,
      suffixIcon: IconButton(
        key: _toggleKey,
        tooltip: _hidden ? 'Göster' : 'Gizle',
        icon: Icon(_hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 20),
        onPressed: () => setState(() => _hidden = !_hidden),
      ),
    );
  }
}

/// Yalnızca rakam kabul eden biçimlendirici.
final TextInputFormatter digitsOnly = FilteringTextInputFormatter.digitsOnly;
