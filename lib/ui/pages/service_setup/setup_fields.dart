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
    this.prefixText,
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

  /// Sabit önek metni (ör. telefon alanında "+90 ", karar 11).
  final String? prefixText;
  final Widget? suffixIcon;
  final bool obscureText;
  final Iterable<String>? autofillHints;
  final int maxLines;
  final bool monospace;

  /// Kimlik / PIN gibi sabit uzunluklu makine kodlarında (mono alan) yazı ölçeği bu çarpandan fazla büyümez: 1.5 ölçekte
  /// 14 karakterlik UID ('AHBU-S3-A1B2C3') iki yan simgenin arasındaki ≈ 168 dp'ye sığmayıp ilk harfi yarım kesiyordu
  /// ('AHBU' -> '\HBU'). Etiket/ipucu/yardımcı metin normal ölçeklenir; yalnız alanın içindeki kod sınırlanır.
  static const double monoMaxScale = 1.25;

  /// Alanın yazı stili: [monospace] ise etkin boyut en çok `15 x [monoMaxScale]`'dir ([TextScaler] `15`'i bu kadardan fazla
  /// büyütüyorsa taban boyut orantılı küçültülür; sonra ölçekleyici aynı değeri verir).
  TextStyle _inputStyle(BuildContext context) {
    final color = SetupColors.text(context);
    if (!monospace) return TextStyle(fontSize: 15, color: color);
    const base = 15.0;
    final scaled = MediaQuery.textScalerOf(context).scale(base);
    final cap = base * monoMaxScale;
    return SetupText.mono(fontSize: scaled > cap ? base * cap / scaled : base, color: color);
  }

  @override
  Widget build(BuildContext context) {
    final multiline = !obscureText && maxLines > 1;
    return Padding(
      // Yüzen etiket kenarlığın ~8 dp üstüne taşar: üst boşluk 18 (eskiden 10: etiket önceki öğeye yapışıyordu).
      padding: const EdgeInsets.only(top: 18),
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
        style: _inputStyle(context),
        decoration: InputDecoration(
          labelText: label,
          // Etiket HER ZAMAN kenarda (küçük): dar diyalogda / büyük yazıda tek satırlık etiket kesilmez, boş alan dolu
          // değer gibi okunmaz; örnek metin ([hint]) alanın içinde görünür kalır. Parantezli niteleyiciler etikete
          // değil [helperText]'e yazılır.
          floatingLabelBehavior: FloatingLabelBehavior.always,
          // Etiket çok satırlı alanda da kenar çentiğinde durur (`alignLabelWithHint` etiketi ön simgenin sağına, 36 dp içeri
          // kaydırıp aynı formdaki tek satırlı alanlardan farklı hizaya sokuyordu).
          alignLabelWithHint: false,
          hintText: hint,
          prefixText: prefixText,
          // İpucu tek satır: Flutter ipucunu görünmezken (alan DOLUYKEN) de yerleşime kattığından iki satırlık ipucu 1.5 ölçekte
          // dolu alanı bile 88 px'e şişiriyordu (değer üst satırda, altında ölü bant). Çok satırlı alan zaten çok satırlıdır.
          hintMaxLines: multiline ? 2 : 1,
          errorText: errorText,
          helperText: helperText,
          helperMaxLines: 6,
          errorMaxLines: 4,
          counterText: '',
          // Çok satırlı alanda ön simge ilk satırın hizasındadır: `prefixIcon` alanın DİKEY ORTASINA oturur (3 satırlı alanda
          // simge ilk satırdan ≈ 33 px aşağıda); satır içi `prefix` ise metnin ilk satırıyla aynı hizada (üstte) durur.
          // Etiket hep yüzen olduğundan (floatingLabelBehavior.always) `prefix` her zaman görünür.
          prefixIcon: (prefixIcon == null || multiline) ? null : Icon(prefixIcon, size: 20),
          prefixIconConstraints: monospace ? const BoxConstraints(minWidth: 40, minHeight: 48) : null,
          prefix: (prefixIcon != null && multiline)
              ? Padding(
                  padding: const EdgeInsetsDirectional.only(end: 10),
                  child: Icon(prefixIcon, size: 20, color: SetupColors.muted(context)),
                )
              : null,
          suffixIcon: suffixIcon,
          // Dolgu/kenar/odak halkası tema `inputDecorationTheme`'inden gelir (koyu + açık eşit).
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
