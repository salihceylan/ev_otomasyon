import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// 4. adım (claim): sunucunun yanlış kurulum PIN'i yanıtı (403 FORBIDDEN, "Geçersiz kurulum PIN kodu…") genel "yetki yok"
/// hatası gibi DEĞİL, PIN hatası olarak 2. adıma yönlendirilir — `remaining_attempts` gelmese de.
void main() {
  for (final remaining in <int?>[3, null]) {
    test('403 FORBIDDEN yanlış PIN (kalan deneme: ${remaining ?? 'yok'}) -> "Kurulum PIN\'i hatalı", 2. adıma dön', () async {
      final env = await serviceHarness();
      addTearDown(env.dispose);
      final c = await startedController(env);
      c.continueNext();
      expect(await c.identify.acceptLabel(kLabelQr), isTrue);
      c.continueNext();
      expect(await c.customer.sendCode(kCustomerEmail), isTrue);
      c.customer.setCode(kCustomerOtp);
      c.continueNext();
      env.cloud.claimErrorOnce = ApiException(
        statusCode: 403,
        code: 'FORBIDDEN',
        message: remaining == null
            ? 'Geçersiz kurulum PIN kodu.'
            : 'Geçersiz kurulum PIN kodu. Kalan deneme hakkı: $remaining',
        remainingAttempts: remaining,
      );
      expect(await c.claim.claim(homeName: 'Daire 5'), isFalse);
      final problem = c.claim.problem!;
      expect(problem.title, 'Kurulum PIN\'i hatalı');
      expect(problem.why, startsWith('Geçersiz kurulum PIN kodu.'));
      expect(problem.fixStep, SetupSteps.identify);
      expect(problem.todo.contains('Kalan deneme hakkı'), remaining != null);
    });
  }
}
