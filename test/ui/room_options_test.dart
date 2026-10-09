import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/endpoint_sections.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';

/// uygulama-ekranlar-7 (sözleşme C14): oda çipleri yalnız GÖSTERİLEN satırlardan türetilir. Panjurun ikincil (AŞAĞI)
/// satırı listede gösterilmez; eski veride odası farklı kalmışsa seçilince boş liste gösteren bir çip üretmemeli.
void main() {
  test('birincil panjur satırı "Yatak Odası", ikincil satır "Çocuk Odası": çiplerde Çocuk Odası yok', () {
    final h = StateHarness();
    addTearDown(h.dispose);
    final endpoints = <EndpointModel>[
      for (final e in testEndpoints())
        switch (e.id) {
          'e3' => e.copyWith(room: 'Yatak Odası'), // kanal 3: panjur 2'nin birincil (YUKARI) satırı
          'e4' => e.copyWith(room: 'Çocuk Odası'), // kanal 4: ikincil (AŞAĞI) satır, eski veri
          _ => e,
        },
    ];
    h.state
      ..setModeForTesting(AppMode.cloud)
      ..setCloudEndpointsForTesting(endpoints);

    final labels = roomOptionsOf(h.state).items.map((r) => r.label).toList();
    expect(labels, contains('Yatak Odası'));
    expect(labels, contains('Salon'));
    expect(labels, isNot(contains('Çocuk Odası')), reason: 'ikincil panjur satırı gösterilmez: çip üretmez');
  });
}
