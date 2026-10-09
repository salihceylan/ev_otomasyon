import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/capabilities.dart';
import '../../../services/automation_state.dart';
import '../../../utils/friendly_error.dart';
import '../../common/confirm_dialogs.dart' show showSimpleConfirm;
import '../../theme/app_theme.dart';

/// Karar 13: "Evden Ayrıl" yalnız aktif evde **sakin** ya da **misafir** olan, personel olmayan kullanıcıya görünür
/// (ev sahibi önce devreder; servis personeli / süper kullanıcı ve servis PIN oturumu bu yoldan ayrılmaz).
bool canLeaveActiveHome(AutomationState state) {
  final home = state.activeHome;
  if (home == null || !state.isAuthenticated) return false;
  if (state.isServiceSession || state.isServiceManagerOrSuper) return false;
  final role = home.homeRole;
  return role == HomeRole.resident || role == HomeRole.guest;
}

/// Onay ister, `DELETE /homes/:id/members/me` çağırır ve sonucu bildirir. Başarıda ev yerelden düşer (başka eve ya da
/// evsiz duruma geçilir) ve `true` döner. Hata (ör. `409 OWNER_CANNOT_LEAVE`) sunucunun iletisiyle gösterilir.
Future<bool> confirmAndLeaveHome(BuildContext context) async {
  final state = context.read<AutomationState>();
  final home = state.activeHome;
  if (home == null) return false;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final confirmed = await showSimpleConfirm(
    context,
    title: 'Evden Ayrıl',
    message: '"${home.name}" evinden ayrılacaksınız. Bu evdeki cihazlara erişiminiz ve kontrol yetkiniz sona erecek; '
        'yeniden katılmak için ev sahibinden yeni bir davet gerekir. Devam etmek istiyor musunuz?',
    confirmLabel: 'Evden Ayrıl',
    cancelLabel: 'Vazgeç',
    destructive: true,
    icon: Icons.exit_to_app_rounded,
    cancelKey: const Key('btn_leave_home_cancel'),
    confirmKey: const Key('btn_leave_home_confirm'),
  );
  if (!confirmed) return false;

  String message;
  Color color;
  var left = false;
  try {
    await state.leaveHome(home.id);
    left = true;
    message = '"${home.name}" evinden ayrıldınız.';
    color = AppTheme.accentGreen;
  } on ApiException catch (e) {
    // 409 (OWNER_CANNOT_LEAVE vb.): sunucunun Türkçe iletisi olduğu gibi gösterilir.
    message = (e.statusCode == 409 && e.message.trim().isNotEmpty)
        ? e.message
        : friendlyError(e, fallback: 'Evden ayrılınamadı. Lütfen tekrar deneyin.');
    color = AppTheme.accentRed;
  } catch (e) {
    message = friendlyError(e, fallback: 'Evden ayrılınamadı. Lütfen tekrar deneyin.');
    color = AppTheme.accentRed;
  }
  messenger?.showSnackBar(
    SnackBar(
      key: const Key('snack_leave_home'),
      content: Text(message),
      backgroundColor: AppTheme.filledAccent(color),
      behavior: SnackBarBehavior.floating,
    ),
  );
  return left;
}
