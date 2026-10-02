import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/capabilities.dart';
import '../../services/automation_state.dart';
import '../common/confirm_dialogs.dart';
import '../common/date_format.dart';
import '../pages/auth/change_password_page.dart';
import '../pages/auth/delete_account_dialog.dart';
import '../pages/auth/social_sign_in.dart';
import '../pages/family/family_members_page.dart';
import '../pages/family/invite_family_dialog.dart';
import '../pages/family/join_home_dialog.dart';
import '../pages/service_management_page.dart';
import '../theme/app_theme.dart';

/// Profil diyaloğu: kimlik bilgileri, rol, tema, hesap güvenliği ve çıkış.
///
/// * Rol etiketi **ev bazlı** rolden (ve küresel yönetici/servis rolünden) gelir.
/// * Avatar harfi grafem kümesinin ilk karakteridir (emoji/birleşik karakterde bozulmaz).
/// * Tema seçimi Sistem / Aydınlık / Karanlık'ı açıkça gösterir (sistem modunda doğru durum).
/// * Çıkış her yolda [confirmAndLogout] ile onaylıdır ve açık sayfaları kapatır.
class UserProfileDialog extends StatelessWidget {
  const UserProfileDialog({super.key});

  static Future<void> show(BuildContext context) {
    final state = context.read<AutomationState>();
    return showDialog(
      context: context,
      builder: (ctx) => ChangeNotifierProvider<AutomationState>.value(
        value: state,
        child: const UserProfileDialog(),
      ),
    );
  }

  /// Gösterilecek rol etiketi ve rengi.
  static (String, Color) roleBadge(AutomationState state) {
    final user = state.currentUser;
    final global = user?.globalRole;
    if (global == GlobalRole.superUser) return ('Süper Yönetici', AppTheme.accentPurple);
    if (global == GlobalRole.serviceUser) return ('Servis Sorumlusu', AppTheme.accentCyan);
    if (state.isServiceSession) return ('Servis Oturumu (PIN)', AppTheme.accentCyan);
    switch (state.activeHome?.homeRole) {
      case HomeRole.owner:
        return ('Ev Sahibi', AppTheme.primaryBlueLight);
      case HomeRole.resident:
        return ('Aile Bireyi', AppTheme.accentGreen);
      case HomeRole.guest:
        return ('Süreli Misafir', AppTheme.accentPurple);
      default:
        return ('Kullanıcı', AppTheme.accentGreen);
    }
  }

  /// Avatar harfi: ad boşsa `U`; aksi halde ilk grafem kümesi (büyük harf).
  static String avatarInitial(String? fullName) {
    final name = fullName?.trim() ?? '';
    if (name.isEmpty) return 'U';
    final first = name.characters.first;
    // Türkçe: noktalı küçük "i" büyük "İ" olur (Dart'ın toUpperCase'i "I" üretir); "ı" -> "I" doğrudur.
    if (first == 'i') return 'İ';
    return first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final user = state.currentUser;
    final caps = state.capabilities;
    final (roleLabel, roleColor) = roleBadge(state);
    final email = (user?.email.trim().isNotEmpty ?? false) ? user!.email.trim() : 'Belirtilmedi';
    final isSession = state.isServiceSession;
    final canAccountActions = state.isAuthenticated && !isSession;
    final remaining = state.serviceSessionRemaining;

    return AlertDialog(
      backgroundColor: AppTheme.getSurfaceColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppTheme.getCardBorder(context), width: 1.2),
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppTheme.getCardColor(context),
                    shape: BoxShape.circle,
                    border: Border.all(color: roleColor, width: 2),
                    boxShadow: [BoxShadow(color: roleColor.withValues(alpha: 0.2), blurRadius: 16, spreadRadius: 2)],
                  ),
                  child: Center(
                    child: Text(
                      avatarInitial(user?.fullName),
                      key: const Key('profile_avatar_initial'),
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: roleColor),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                (user?.fullName.trim().isNotEmpty ?? false) ? user!.fullName.trim() : 'Kullanıcı Profili',
                key: const Key('profile_name'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: roleColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    roleLabel,
                    key: const Key('profile_role'),
                    style: TextStyle(color: roleColor, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Divider(color: AppTheme.getCardBorder(context), height: 1),
              const SizedBox(height: 16),
              _buildInfoTile(context, icon: Icons.email_outlined, title: 'E-Posta', value: email, valueKey: const Key('profile_email')),
              if (user != null && user.phone.isNotEmpty) ...[
                const SizedBox(height: 10),
                _buildInfoTile(context, icon: Icons.phone_outlined, title: 'Telefon', value: user.phone),
              ],
              const SizedBox(height: 10),
              _buildInfoTile(context, icon: Icons.home_outlined, title: 'Aktif Ev', value: state.activeHome?.name ?? 'Ev Seçilmedi'),
              const SizedBox(height: 10),
              _buildInfoTile(context, icon: Icons.domain_outlined, title: 'Kayıtlı Ev Sayısı', value: '${state.homes.length} Ev Tanımlı'),
              if (isSession && remaining != null) ...[
                const SizedBox(height: 10),
                _buildInfoTile(
                  context,
                  icon: Icons.timer_outlined,
                  title: 'Oturum Süresi',
                  value: formatRemaining(remaining),
                ),
              ],
              if (caps.canOpenServiceManagement) ...[
                const SizedBox(height: 14),
                _wideButton(
                  context,
                  key: const Key('btn_open_service_panel'),
                  icon: Icons.admin_panel_settings_rounded,
                  label: 'Servis & Yönetici Panelini Aç',
                  background: AppTheme.accentCyan,
                  foreground: Colors.black,
                  onPressed: () {
                    Navigator.of(context).pop();
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const ServiceManagementPage()));
                  },
                ),
              ],
              if (caps.canInvite && state.activeHome != null) ...[
                const SizedBox(height: 14),
                _wideButton(
                  context,
                  key: const Key('btn_open_family'),
                  icon: Icons.group_outlined,
                  label: 'Aile & Misafir Yönetimi',
                  background: AppTheme.primaryBlue,
                  foreground: Colors.white,
                  onPressed: () {
                    Navigator.of(context).pop();
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const FamilyMembersPage()));
                  },
                ),
                const SizedBox(height: 10),
                _outlineButton(
                  context,
                  key: const Key('btn_quick_invite'),
                  icon: Icons.person_add_alt_1_outlined,
                  iconColor: AppTheme.primaryBlueLight,
                  label: 'Hızlı Davet Kodu / QR Üret',
                  onPressed: () {
                    Navigator.of(context).pop();
                    InviteFamilyDialog.show(context);
                  },
                ),
              ],
              if (state.isAuthenticated && !state.isServiceManagerOrSuper && !isSession) ...[
                const SizedBox(height: 10),
                _outlineButton(
                  context,
                  key: const Key('btn_join_home'),
                  icon: Icons.vpn_key_outlined,
                  iconColor: AppTheme.accentGreen,
                  label: 'Başka Bir Eve Katıl (Kod İle)',
                  onPressed: () {
                    Navigator.of(context).pop();
                    JoinHomeDialog.show(context);
                  },
                ),
              ],
              const SizedBox(height: 14),
              Text(
                'Tema',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.getTextMuted(context)),
              ),
              const SizedBox(height: 6),
              _buildThemeChoices(context, state),
              if (canAccountActions) ...[
                const SizedBox(height: 16),
                Divider(color: AppTheme.getCardBorder(context), height: 1),
                const SizedBox(height: 10),
                _outlineButton(
                  context,
                  key: const Key('btn_open_change_password'),
                  icon: Icons.lock_reset_rounded,
                  iconColor: AppTheme.primaryBlueLight,
                  label: 'Şifreyi Değiştir',
                  onPressed: () {
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    navigator.push(MaterialPageRoute(builder: (_) => const ChangePasswordPage()));
                  },
                ),
                const SizedBox(height: 10),
                _outlineButton(
                  context,
                  key: const Key('btn_logout_all'),
                  icon: Icons.devices_other_rounded,
                  iconColor: AppTheme.accentAmber,
                  label: 'Tüm Cihazlardan Çıkış Yap',
                  onPressed: () => _logoutAll(context, state),
                ),
                // Servis personeli ve yönetici hesapları bu menüden silinemez (sunucu 403): giriş sunulmaz.
                if (!state.isServiceManagerOrSuper) ...[
                  const SizedBox(height: 10),
                  _outlineButton(
                    context,
                    key: const Key('btn_delete_account_entry'),
                    icon: Icons.delete_forever_outlined,
                    iconColor: AppTheme.accentRed,
                    label: 'Hesabımı Sil',
                    onPressed: () => DeleteAccountDialog.show(context),
                  ),
                ],
              ],
              const SizedBox(height: 18),
              ElevatedButton.icon(
                key: const Key('btn_logout'),
                onPressed: () => confirmAndLogout(context, state),
                icon: const Icon(Icons.logout_rounded, color: Colors.white, size: 20),
                label: const Text('Oturumu Kapat', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentRed,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('btn_profile_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Kapat', style: TextStyle(color: AppTheme.getTextMuted(context))),
        ),
      ],
    );
  }

  Future<void> _logoutAll(BuildContext context, AutomationState state) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await showSimpleConfirm(
      context,
      title: 'Tüm Cihazlardan Çıkış',
      message: 'Bu hesabın tüm cihazlardaki oturumları kapatılacak ve bu cihazdan da çıkış yapılacak. Devam edilsin mi?',
      confirmLabel: 'Tümünden Çık',
      destructive: true,
      icon: Icons.devices_other_rounded,
    );
    if (!ok) return;
    try {
      // Sunucu işlemi başarısızsa çıkış YAPILMAZ (hata fırlatılır).
      await state.logoutAll();
      unawaited(SocialSignIn.signOutGoogle());
      navigator.popUntil((route) => route.isFirst);
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(e is ApiException ? e.message : 'Tüm cihazlardan çıkış yapılamadı. Lütfen tekrar deneyin.'),
          backgroundColor: AppTheme.accentRed,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _buildThemeChoices(BuildContext context, AutomationState state) {
    Widget chip(ThemeMode mode, String label, IconData icon, Key key) {
      final selected = state.themeMode == mode;
      return ChoiceChip(
        key: key,
        avatar: Icon(icon, size: 16, color: selected ? Colors.white : AppTheme.accentAmber),
        label: Text(label, style: TextStyle(fontSize: 12.5, color: selected ? Colors.white : AppTheme.getTextPrimary(context))),
        selected: selected,
        selectedColor: AppTheme.primaryBlue,
        backgroundColor: AppTheme.getCardColor(context),
        showCheckmark: false,
        side: BorderSide(color: selected ? AppTheme.primaryBlue : AppTheme.getCardBorder(context)),
        onSelected: (_) => state.setThemeMode(mode),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        chip(ThemeMode.system, 'Sistem', Icons.brightness_auto_outlined, const Key('theme_system')),
        chip(ThemeMode.light, 'Aydınlık', Icons.light_mode_outlined, const Key('theme_light')),
        chip(ThemeMode.dark, 'Karanlık', Icons.dark_mode_outlined, const Key('theme_dark')),
      ],
    );
  }

  Widget _wideButton(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String label,
    required Color background,
    required Color foreground,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        key: key,
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label, overflow: TextOverflow.ellipsis),
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget _outlineButton(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required Color iconColor,
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: key,
        onPressed: onPressed,
        icon: Icon(icon, size: 18, color: iconColor),
        label: Text(label, style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 13), overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          side: BorderSide(color: AppTheme.getCardBorder(context)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget _buildInfoTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String value,
    Key? valueKey,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.getCardBorder(context).withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, color: AppTheme.getTextMuted(context), size: 18),
          ),
          const SizedBox(width: 10),
          // Wrap: başlık + değer tek satıra sığmazsa (dar ekran / büyük yazı) değer alt satıra geçer ve
          // tam okunur; sığarsa eskisi gibi başlık solda, değer sağdadır (Row + yan yana metin taşardı).
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 2,
              children: [
                Text(title, style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13)),
                Text(
                  value,
                  key: valueKey,
                  textAlign: TextAlign.end,
                  style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
