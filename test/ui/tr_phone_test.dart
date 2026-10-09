import 'package:ev_otomasyon/ui/common/validators.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Karar 11 (2026-10-09): TR telefonları tek biçimde: kullanıcı sabit "+90" önekinden sonra 10 haneyi
/// (5XX XXX XX XX) yazar, sunucuya `+905XXXXXXXXX` gider; yapıştırılan 0/90/+90/0090 önekleri ayıklanır.
void main() {
  group('AuthValidators.canonicalTrPhone', () {
    test('TR cep biçimleri +905XXXXXXXXX olur', () {
      for (final raw in <String>[
        '5551234567',
        '555 123 45 67',
        '0555 123 45 67',
        '05551234567',
        '905551234567',
        '+90 555 123 45 67',
        '+90 (555) 123-45-67',
        '0090 555 123 4567',
      ]) {
        expect(AuthValidators.canonicalTrPhone(raw), '+905551234567', reason: raw);
      }
    });

    test('TR cep olmayanlar null', () {
      for (final raw in <String>['', '12345', '4551234567', '555123456', '55512345678', '+1 202 555 0101', 'a@b.c']) {
        expect(AuthValidators.canonicalTrPhone(raw), isNull, reason: raw);
      }
    });

    test('normalizePhone: TR biçimi kanonik; başka ülke numarası eskisi gibi (yalnız ayırıcılar atılır)', () {
      expect(AuthValidators.normalizePhone('0555 123 45 67'), '+905551234567');
      expect(AuthValidators.normalizePhone('+1 (202) 555-0101'), '+12025550101');
    });

    test('parseIdentifier: telefon görünümlüyse kanonik, e-posta dokunulmaz', () {
      expect(AuthValidators.parseIdentifier('0555 123 45 67')!.value, '+905551234567');
      expect(AuthValidators.parseIdentifier(' Ayse@Ornek.com ')!.value, 'ayse@ornek.com');
    });

    test('trMobileError: 10 hane, 5 ile başlar', () {
      expect(AuthValidators.trMobileError(''), isNull);
      expect(AuthValidators.trMobileError('', required: true), 'Lütfen telefon numaranızı girin');
      expect(AuthValidators.trMobileError('555 123 45'), contains('10 hane'));
      expect(AuthValidators.trMobileError('455 123 45 67'), contains('5 ile'));
      expect(AuthValidators.trMobileError('555 123 45 67'), isNull);
    });
  });

  group('TrPhoneInputFormatter', () {
    const f = TrPhoneInputFormatter();
    TextEditingValue type(String text) =>
        f.formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length)));

    test('yazarken 3-3-2-2 gruplar, en çok 10 hane', () {
      expect(type('5').text, '5');
      expect(type('5551').text, '555 1');
      expect(type('5551234').text, '555 123 4');
      expect(type('555123456').text, '555 123 45 6');
      expect(type('5551234567').text, '555 123 45 67');
      expect(type('555123456789').text, '555 123 45 67');
      expect(type('5551234567').selection.baseOffset, '555 123 45 67'.length);
    });

    test('yapıştırılan 0 / 90 / +90 önekleri ayıklanır; harfler atılır', () {
      expect(type('0555 123 45 67').text, '555 123 45 67');
      expect(type('905551234567').text, '555 123 45 67');
      expect(type('+90 555 123 45 67').text, '555 123 45 67');
      expect(type('0').text, '');
      expect(type('tel: 0555-123 (45) 67').text, '555 123 45 67');
    });

    test('ortadan silme imleci rakamın yanında tutar', () {
      // '555 123 45 67' içinde 4. rakamdan ('1') önce imleç; '1' silinmiş yeni değer.
      const edited = TextEditingValue(text: '555 23 45 67', selection: TextSelection.collapsed(offset: 4));
      final out = f.formatEditUpdate(TextEditingValue.empty, edited);
      expect(out.text, '555 234 56 7');
      expect(out.selection.baseOffset, 3);
    });
  });
}
