import 'package:ev_otomasyon/models/safety_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// WP-A4: sihirbazın bölge testi sonucu `GET /api/events` içindeki `test_result {ok, fb_ms}` olayından okunur (§3.4).
void main() {
  test('test_result olayı ok ve fb_ms taşır; diğer olaylarda alanlar null', () {
    final e = DeviceEventRecord.fromJson(<String, dynamic>{
      'eid': '9f3a11c0-7',
      'type': 'test_result',
      'zone': 1,
      'ok': true,
      'fb_ms': 4200,
    });
    expect(e.ok, isTrue);
    expect(e.fbMs, 4200);
    final raised = DeviceEventRecord.fromJson(<String, dynamic>{'eid': '9f3a11c0-8', 'type': 'alarm_raised', 'zone': 1});
    expect(raised.ok, isNull);
    expect(raised.fbMs, isNull);
    expect(e == DeviceEventRecord.fromJson(<String, dynamic>{'eid': '9f3a11c0-7', 'type': 'test_result', 'zone': 1, 'ok': true}), isFalse);
  });
}
