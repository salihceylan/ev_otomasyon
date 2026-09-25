import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/automation_state.dart';
import '../theme/app_theme.dart';
import '../pages/family/invite_family_dialog.dart';
import '../pages/family/join_home_dialog.dart';
import '../pages/family/family_members_page.dart';
import '../pages/service_management_page.dart';

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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutomationState>();
    final user = state.currentUser;

    final roleLabel = switch (user?.role) {
      'super_user' => '👑 Süper Yönetici',
      'service_user' => '🛠️ Servis Sorumlusu',
      'owner' => 'Ev Sahibi',
      'member' => 'Aile Bireyi',
      'guest' => 'Süreli Misafir',
      _ => 'Kullanıcı',
    };

    final roleColor = switch (user?.role) {
      'super_user' => AppTheme.accentPurple,
      'service_user' => AppTheme.accentCyan,
      'owner' => AppTheme.primaryBlueLight,
      'guest' => AppTheme.accentPurple,
      _ => AppTheme.accentGreen,
    };

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
              // Avatar ve İsim Başlığı
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppTheme.getCardColor(context),
                    shape: BoxShape.circle,
                    border: Border.all(color: roleColor, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: roleColor.withValues(alpha: 0.2),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      (user?.fullName.isNotEmpty == true)
                          ? user!.fullName.substring(0, 1).toUpperCase()
                          : 'U',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: roleColor,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                user?.fullName.isNotEmpty == true ? user!.fullName : 'Kullanıcı Profili',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary,
                ),
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
                    style: TextStyle(
                      color: roleColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Divider(color: AppTheme.cardBorder, height: 1),
              const SizedBox(height: 16),

              // Bilgi Satırları
              _buildInfoTile(
                context,
                icon: Icons.email_outlined,
                title: 'E-Posta',
                value: user?.email ?? 'Belirtilmedi',
              ),
              if (user?.phone != null && user!.phone.isNotEmpty) ...[
                const SizedBox(height: 10),
                _buildInfoTile(
                  context,
                  icon: Icons.phone_outlined,
                  title: 'Telefon',
                  value: user.phone,
                ),
              ],
              const SizedBox(height: 10),
              _buildInfoTile(
                context,
                icon: Icons.home_outlined,
                title: 'Aktif Ev',
                value: state.activeHome?.name ?? 'Ev Seçilmedi',
              ),
              const SizedBox(height: 10),
              _buildInfoTile(
                context,
                icon: Icons.domain_outlined,
                title: 'Kayıtlı Ev Sayısı',
                value: '${state.homes.length} Ev Tanımlı',
              ),

              // Süper Yönetici & Servis Paneli (ADIM 19)
              if (state.isServiceManagerOrSuper) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ServiceManagementPage()),
                      );
                    },
                    icon: const Icon(Icons.admin_panel_settings_rounded, size: 18),
                    label: const Text('Servis & Yönetici Panelini Aç'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accentCyan,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],


              // Aile & Misafir Yönetimi (Yalnızca Ev Sahibi)
              if (state.isOwner && state.activeHome != null) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const FamilyMembersPage()),
                      );
                    },
                    icon: const Icon(Icons.group_outlined, size: 18),
                    label: const Text('Aile & Misafir Yönetimi'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      InviteFamilyDialog.show(context);
                    },
                    icon: const Icon(Icons.person_add_alt_1_outlined, size: 18, color: AppTheme.primaryBlueLight),
                    label: const Text('Hızlı Davet Kodu / QR Üret', style: TextStyle(color: AppTheme.primaryBlueLight)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: const BorderSide(color: AppTheme.primaryBlueLight),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],

              // Başka Bir Eve Katıl (Yalnızca sakin, misafir ve aile bireyleri için)
              if (!state.isServiceManagerOrSuper && !state.isInstaller) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      JoinHomeDialog.show(context);
                    },
                    icon: const Icon(Icons.vpn_key_outlined, size: 18, color: AppTheme.accentGreen),
                    label: const Text('Başka Bir Eve Katıl (Kod İle)', style: TextStyle(color: AppTheme.textPrimary)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      side: const BorderSide(color: AppTheme.cardBorder),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],

              // Tema Seçimi (Hızlı Geçiş)
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    final next = state.themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
                    state.setThemeMode(next);
                  },
                  icon: Icon(
                    state.themeMode == ThemeMode.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                    size: 18,
                    color: AppTheme.accentAmber,
                  ),
                  label: Text(
                    state.themeMode == ThemeMode.dark ? 'Aydınlık Moda Geç' : 'Karanlık Moda Geç',
                    style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(color: AppTheme.getCardBorder(context)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),

              const SizedBox(height: 18),

              // Oturumu Kapat Butonu
              ElevatedButton.icon(
                onPressed: () => _confirmLogout(context, state),
                icon: const Icon(Icons.logout_rounded, color: Colors.white, size: 20),
                label: const Text(
                  'Oturumu Kapat',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentRed,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Kapat', style: TextStyle(color: AppTheme.getTextMuted(context))),
        ),
      ],
    );
  }

  Widget _buildInfoTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.getCardColor(context),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.getCardBorder(context).withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.getTextMuted(context), size: 18),
          const SizedBox(width: 10),
          Text(
            title,
            style: TextStyle(color: AppTheme.getTextMuted(context), fontSize: 13),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                color: AppTheme.getTextPrimary(context),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _confirmLogout(BuildContext context, AutomationState state) {
    showDialog(
      context: context,
      builder: (confirmCtx) {
        return AlertDialog(
          backgroundColor: AppTheme.surfaceDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppTheme.cardBorder),
          ),
          title: Row(
            children: const [
              Icon(Icons.warning_amber_rounded, color: AppTheme.accentRed, size: 26),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Çıkış Yapılsın mı?',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: const Text(
            'Oturumunuz kapatılacak ve güvenli veriler temizlenecektir. Devam etmek istiyor musunuz?',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(confirmCtx).pop(),
              child: const Text('Vazgeç', style: TextStyle(color: AppTheme.textMuted)),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(confirmCtx).pop(); // Onay dialogunu kapat
                Navigator.of(context).pop(); // Profil dialogunu kapat
                await state.logout();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentRed,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Evet, Çıkış Yap', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }
}
