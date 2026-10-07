import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../theme/tokens.dart';

// =============================================================================
// Gaz alarmında anahtarlama onayı (Faz 2 F2.A.4, karar F2-1).
//
// Gaz kaçağında elektrik anahtarlamak tutuşma kaynağıdır. Kullanıcının bilinçli komutu ENGELLENMEZ (karanlıkta tahliye
// için ışık gerekebilir); yalnız ilk dokunuşta onay istenir. Gaz alarmı yoksa diyalog açılmaz ve davranış bugünkü
// gibidir (anında `true`).
//
// Anahtarlar: `Key('btn_gas_switch_confirm')`, `Key('btn_gas_switch_cancel')`.
// =============================================================================

/// Gaz alarmı sürerken lamba / priz / panjur komutundan ya da hızlı senaryodan önce onay ister. Gaz alarmı yoksa
/// diyalogsuz `true`; kullanıcı vazgeçerse `false` (komut gönderilmez).
Future<bool> confirmSwitchingDuringGasAlarm(BuildContext context) async {
  final state = context.read<AutomationState>();
  if (!state.hasOpenGasAlarm) return true;
  return showSimpleConfirm(
    context,
    title: 'Gaz alarmı sürüyor.',
    message: 'Elektrik anahtarlamak kıvılcım oluşturabilir. Yine de uygulansın mı?',
    confirmLabel: 'Yine de Uygula',
    icon: Icons.local_fire_department_rounded,
    family: AppFamilies.rose,
    cancelKey: const Key('btn_gas_switch_cancel'),
    confirmKey: const Key('btn_gas_switch_confirm'),
  );
}
