import 'dart:convert';

import 'package:ev_otomasyon/ui/pages/service_setup/logic/shutter_logic.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/service_setup_controller.dart';
import 'package:ev_otomasyon/ui/pages/service_setup/setup_steps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'f_flow_support.dart';
import 'f_support.dart';

/// servis_kurulum-3: motorlu panjuru olmayan dairede 8. adım "Bu dairede motorlu panjur yok" teknisyen beyanıyla dürüstçe
/// tamamlanır; bir çift geri alınınca beyan düşer; teslim ayrıntısı beyanı söyler; kayıt / geri yükleme.
void main() {
  late ServiceHarness env;
  late ServiceSetupController c;

  Future<void> atShutters() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    env = await serviceHarness();
    c = await reachStep(env, SetupSteps.shutters);
    await waitUntil(env, () => c.shutters.loaded && !c.isBusy);
    expect(c.shutters.shutters, hasLength(2));
  }

  tearDown(() => env.dispose());

  test('beyan: tüm çiftler kullanılmıyor + bayrak -> adım tamamlanır', () async {
    await atShutters();
    expect(c.shutters.isComplete, isFalse);
    expect(await drive(env, c.shutters.declareNoMotorizedShutters()), isTrue);
    expect(c.shutters.noMotorizedDeclared, isTrue);
    expect(c.shutters.shutters.every((s) => s.unused), isTrue);
    expect(c.shutters.isComplete, isTrue);
  });

  test('bir çift "kullanılmıyor"dan çıkarılınca beyan düşer ve adım tamamlanmaz', () async {
    await atShutters();
    await drive(env, c.shutters.declareNoMotorizedShutters());
    expect(await drive(env, c.shutters.setUnused(1, false)), isTrue);
    expect(c.shutters.noMotorizedDeclared, isFalse);
    expect(c.shutters.isComplete, isFalse);
  });

  test('beyansız "hepsi kullanılmıyor" eskisi gibi geçilemez', () async {
    await atShutters();
    for (final s in List<ShutterCheck>.of(c.shutters.shutters)) {
      await drive(env, c.shutters.setUnused(s.pair, true));
    }
    expect(c.shutters.isComplete, isFalse);
  });

  test('teslim ayrıntısı teknisyen beyanını söyler; kayıt / geri yükleme', () async {
    await atShutters();
    await drive(env, c.shutters.declareNoMotorizedShutters());
    expect(
      c.handover.buildChecks().shutters.detail,
      'Panoda 2 panjur çifti tanımlı; dairede motorlu panjur yok (teknisyen beyanı)',
    );
    final snap = jsonDecode(jsonEncode(c.shutters.snapshot())) as Map<String, dynamic>;
    expect(snap['no_shutters'], isTrue);
    final restored = ShutterLogic(c.shutters.ctx)..restore(snap);
    expect(await drive(env, restored.load()), isTrue);
    expect(restored.noMotorizedDeclared, isTrue);
    expect(restored.isComplete, isTrue);
  });

  test('şablon uygulanınca beyan temizlenir', () async {
    await atShutters();
    await drive(env, c.shutters.declareNoMotorizedShutters());
    c.shutters.resetForTemplate();
    expect(c.shutters.noMotorizedDeclared, isFalse);
  });
}
