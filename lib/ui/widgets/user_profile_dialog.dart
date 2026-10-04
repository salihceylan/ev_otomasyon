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
import '../motion/motion.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_pill.dart' show AppPillTokens;
import 'glass_pill.dart';
import 'orb/avatar_orb.dart';
import 'orb/orb.dart';
import 'scroll_cue.dart';
import 'settings/accent_button.dart';
import 'settings/settings_card.dart' show familyForAccent;

// Eskiden bu dosyadaydı (WP-V9: paylaşımlı dosyalara taşındı); mevcut içe aktarma yolları KIRILMAZ.
export 'glass_pill.dart' show GlassPill;
export 'orb/avatar_orb.dart' show AvatarOrb;
export 'scroll_cue.dart' show ScrollCue;

/// Profil diyaloğunun durumdan okuduğu değerler (PF-06: `context.select`; ilgisiz bildirim diyaloğu yeniden
/// kurmaz). `Capabilities` yerine skalerler; kalan servis süresi yalnız GÖRÜNEN metin olarak izlenir.
typedef _ProfileView = ({
  String fullName,
  String email,
  String phone,
  String roleLabel,
  Color roleColor,
  String? activeHomeName,
  int homeCount,
  bool isSession,
  bool isAuthenticated,
  bool isServiceManagerOrSuper,
  String? sessionRemaining,
  bool canOpenServiceManagement,
  bool canInvite,
  ThemeMode themeMode,
});

/// Profil diyaloğu: kimlik bilgileri, rol, tema, hesap güvenliği ve çıkış.
///
/// * Rol etiketi **ev bazlı** rolden (ve küresel yönetici/servis rolünden) gelir.
/// * Avatar harfi grafem kümesinin ilk karakteridir (emoji/birleşik karakterde bozulmaz).
/// * Tema seçimi Sistem / Aydınlık / Karanlık'ı açıkça gösterir (sistem modunda doğru durum).
/// * Çıkış her yolda [confirmAndLogout] ile onaylıdır ve açık sayfaları kapatır.
///
/// Eylem hiyerarşisi (dar telefonda bile tek bakışta okunur): **en çok bir gradyan birincil düğme** (servis paneli
/// ya da aile yönetimi), ikincil eylemler çerçeveli düğme, hesap eylemleri tek "Hesap ve güvenlik" liste grubu ve
/// en altta tonlu (gradyansız) "Oturumu Kapat". Etiketler kesilmez, satıra sarılır (yazı ölçeği 1.5/2.0).
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

  static _ProfileView _viewOf(AutomationState state) {
    final user = state.currentUser;
    final caps = state.capabilities;
    final (roleLabel, roleColor) = roleBadge(state);
    final isSession = state.isServiceSession;
    final remaining = state.serviceSessionRemaining;
    return (
      fullName: user?.fullName ?? '',
      // Telefon / Apple-gizli hesapta sunucunun teknik yer tutucusu (`...@ahbu.local` vb.) e-posta sayılmaz:
      // "Belirtilmedi" görünür (UYELIK-07; yeni sunucu zaten `email:null` döner).
      email: user?.contactEmail ?? '',
      phone: user?.phone ?? '',
      roleLabel: roleLabel,
      roleColor: roleColor,
      activeHomeName: state.activeHome?.name,
      homeCount: state.homes.length,
      isSession: isSession,
      isAuthenticated: state.isAuthenticated,
      isServiceManagerOrSuper: state.isServiceManagerOrSuper,
      sessionRemaining: (isSession && remaining != null) ? formatRemaining(remaining) : null,
      canOpenServiceManagement: caps.canOpenServiceManagement,
      canInvite: caps.canInvite,
      themeMode: state.themeMode,
    );
  }

  @override
  Widget build(BuildContext context) {
    // PF-06: yalnız bu diyaloğun gösterdiği değerler izlenir; ilgisiz bildirim diyaloğu yeniden kurmaz.
    final v = context.select<AutomationState, _ProfileView>(_viewOf);
    final roleLabel = v.roleLabel;
    final roleColor = v.roleColor;
    final email = v.email.isNotEmpty ? v.email : 'Belirtilmedi';
    final isSession = v.isSession;
    final canAccountActions = v.isAuthenticated && !isSession;
    final fullName = v.fullName.trim();

    final family = familyForAccent(roleColor);
    final muted = AppTheme.getTextMuted(context);
    final showFamily = v.canInvite && v.activeHomeName != null;
    final showJoin = v.isAuthenticated && !v.isServiceManagerOrSuper && !isSession;
    // Tek birincil gradyan düğme: servis paneli varsa o (cyan), yoksa aile yönetimi (tema birincil). Aile yönetimi
    // servis panelinin yanında ikincil (çerçeveli) kalır: iki gradyan düğme birbiriyle yarışmaz.
    final familyIsPrimary = !v.canOpenServiceManagement;

    return AlertDialog(
      backgroundColor: AppTheme.getSurfaceColor(context),
      // Dar telefonda (360 dp) diyalog 328 dp genişler (varsayılan 40 dp kenar boşluğu 280 dp bırakıyordu): etiketler
      // satıra daha az sarılır, uzun e-posta/ad daha çok okunur.
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card + 4),
        side: BorderSide(color: roleColor.withValues(alpha: 0.30), width: 1.2),
      ),
      contentPadding: const EdgeInsetsDirectional.fromSTEB(20, 24, 8, 12),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      // Sabit GENİŞLİK isteği (AlertDialog `IntrinsicWidth` kullanır; kapsayıcı kısıt kadar kırpılır): diyalog içeriğin
      // doğal genişliğine büzülmez, telefonda (360 dp) 328 dp, tablette 408 dp olur ve düzen ölçeğe göre oynamaz.
      content: SizedBox(
        width: 380,
        child: ScrollCue(
          color: muted.withValues(alpha: 0.55),
          builder: (context, controller) => SingleChildScrollView(
            controller: controller,
            // Sağda kaydırma çubuğuna yer (içerik çubuğun altında kalmaz).
            padding: const EdgeInsetsDirectional.only(end: ScrollCue.gutter + 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: StaggeredEntrance(
                    index: 0,
                    child: AvatarOrb(
                      letter: avatarInitial(v.fullName),
                      letterKey: const Key('profile_avatar_initial'),
                      family: family,
                      size: 84,
                      ringed: true,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  fullName.isNotEmpty ? fullName : 'Kullanıcı Profili',
                  key: const Key('profile_name'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.getTextPrimary(context)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Center(
                  child: GlassPill(
                    color: roleColor,
                    label: roleLabel,
                    textKey: const Key('profile_role'),
                    leading: GlowDot(color: roleColor, size: 8),
                  ),
                ),
                const SizedBox(height: 18),
                _InfoGroup(
                  rows: [
                    _InfoRow(icon: Icons.email_rounded, title: 'E-Posta', value: email, valueKey: const Key('profile_email')),
                    if (v.phone.isNotEmpty) _InfoRow(icon: Icons.phone_rounded, title: 'Telefon', value: v.phone),
                    _InfoRow(icon: Icons.home_rounded, title: 'Aktif Ev', value: v.activeHomeName ?? 'Ev Seçilmedi'),
                    _InfoRow(icon: Icons.domain_rounded, title: 'Kayıtlı Ev Sayısı', value: '${v.homeCount} Ev Tanımlı'),
                    if (v.sessionRemaining != null)
                      _InfoRow(icon: Icons.timer_rounded, title: 'Oturum Süresi', value: v.sessionRemaining!),
                  ],
                ),
                if (v.canOpenServiceManagement) ...[
                  const SizedBox(height: 16),
                  _primaryButton(
                    key: const Key('btn_open_service_panel'),
                    icon: Icons.admin_panel_settings_rounded,
                    label: 'Servis & Yönetici Panelini Aç',
                    family: AppFamilies.cyan,
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const ServiceManagementPage()));
                    },
                  ),
                ],
                if (showFamily) ...[
                  SizedBox(height: v.canOpenServiceManagement ? 10 : 16),
                  if (familyIsPrimary)
                    _primaryButton(
                      key: const Key('btn_open_family'),
                      icon: Icons.group_rounded,
                      label: 'Aile & Misafir Yönetimi',
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const FamilyMembersPage()));
                      },
                    )
                  else
                    _outlineButton(
                      context,
                      key: const Key('btn_open_family'),
                      icon: Icons.group_rounded,
                      iconColor: AppTheme.primaryBlueLight,
                      label: 'Aile & Misafir Yönetimi',
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const FamilyMembersPage()));
                      },
                    ),
                  const SizedBox(height: 10),
                  _outlineButton(
                    context,
                    key: const Key('btn_quick_invite'),
                    icon: Icons.person_add_alt_1_rounded,
                    iconColor: AppTheme.primaryBlueLight,
                    label: 'Hızlı Davet Kodu / QR Üret',
                    onPressed: () {
                      Navigator.of(context).pop();
                      InviteFamilyDialog.show(context);
                    },
                  ),
                ],
                if (showJoin) ...[
                  SizedBox(height: showFamily ? 10 : 16),
                  _outlineButton(
                    context,
                    key: const Key('btn_join_home'),
                    icon: Icons.vpn_key_rounded,
                    iconColor: AppTheme.accentGreen,
                    label: 'Başka Bir Eve Katıl (Kod İle)',
                    onPressed: () {
                      Navigator.of(context).pop();
                      JoinHomeDialog.show(context);
                    },
                  ),
                ],
                const SizedBox(height: 18),
                Text('Tema', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: muted)),
                const SizedBox(height: 8),
                _buildThemeChoices(context, v.themeMode),
                if (canAccountActions) ...[
                  const SizedBox(height: 18),
                  Text('Hesap ve güvenlik', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: muted)),
                  const SizedBox(height: 8),
                  _InfoGroup(
                    rows: [
                      _ProfileRow(
                        key: const Key('btn_open_change_password'),
                        icon: Icons.lock_reset_rounded,
                        family: AppFamilies.sky,
                        label: 'Şifreyi Değiştir',
                        onTap: () {
                          final navigator = Navigator.of(context);
                          navigator.pop();
                          navigator.push(MaterialPageRoute(builder: (_) => const ChangePasswordPage()));
                        },
                      ),
                      _ProfileRow(
                        key: const Key('btn_logout_all'),
                        icon: Icons.devices_other_rounded,
                        family: AppFamilies.amber,
                        label: 'Tüm Cihazlardan Çıkış Yap',
                        onTap: () => _logoutAll(context),
                      ),
                      // Servis personeli ve yönetici hesapları bu menüden silinemez (sunucu 403): giriş sunulmaz.
                      if (!v.isServiceManagerOrSuper)
                        _ProfileRow(
                          key: const Key('btn_delete_account_entry'),
                          icon: Icons.delete_forever_rounded,
                          family: AppFamilies.rose,
                          label: 'Hesabımı Sil',
                          danger: true,
                          onTap: () => DeleteAccountDialog.show(context),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                // Yıkıcı ama sık kullanılan çıkış: tonlu rose çerçeveli düğme (gradyan değil): birincil eylemle yarışmaz.
                OutlinedButton.icon(
                  key: const Key('btn_logout'),
                  onPressed: () => confirmAndLogout(context, context.read<AutomationState>()),
                  icon: const Icon(Icons.logout_rounded, size: 20),
                  label: const Text(
                    'Oturumu Kapat',
                    textAlign: TextAlign.center,
                    textWidthBasis: TextWidthBasis.longestLine,
                    maxLines: 2,
                    softWrap: true,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.dangerText(context),
                    backgroundColor: AppFamilies.rose.base.withValues(alpha: 0.08),
                    // Kenar: tüm çerçeveli düğmelerle AYNI tek ton kuralı ([AppTheme.outlinedSide]; iki temada ≥ 3:1; eskiden
                    // rose@.60 beyazda ≈ 2.3:1 idi).
                    side: AppTheme.outlinedSide(context, AppFamilies.rose),
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('btn_profile_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Kapat', style: TextStyle(color: muted)),
        ),
      ],
    );
  }

  Future<void> _logoutAll(BuildContext context) async {
    final state = context.read<AutomationState>();
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

  /// Tema seçimi: üç [ChoiceChip] (tür KORUNUR: testler `ChoiceChip.selected` okur) ama stil [AppChip] diliyle AYNI —
  /// seçili = marka camgöbeği tonlu dolgu ([AppPillTokens.selectedTint]) + okunur tonun kalın kenarı + onay işareti
  /// (seçili durum yalnız dolgu rengiyle anlatılmaz) + w800 etiket; seçili değil = nötr yüzey + ≥ 3:1 alan kenarı
  /// ([AppTheme.getFieldBorder]; eskiden kart kenarı 1.4:1'di). Eskiden seçili çip düz #2563EB idi: diyalogun tek gradyan
  /// birincil düğmesinin yanında en doygun düz mavi alan olup hiyerarşiyi bozuyordu.
  Widget _buildThemeChoices(BuildContext context, ThemeMode current) {
    const family = AppFamilies.cyan;
    final ink = AppTheme.readableAccent(context, family.base);
    final primary = AppTheme.getTextPrimary(context);
    final fieldBorder = AppTheme.getFieldBorder(context);
    final selectedFill = Color.alphaBlend(
      family.base.withValues(alpha: AppPillTokens.selectedTint),
      AppTheme.getSurfaceColor(context),
    );

    Widget chip(ThemeMode mode, String label, IconData icon, Key key, {double? labelWidth}) {
      final selected = current == mode;
      // Simge + etiket TEK `FittedBox` içinde (ChoiceChip `avatar` alanı ≈ 33 dp yer tutup etiketi kırpıyordu): dar
      // çipte hafifçe küçülür, KESİLMEZ. Seçiliyken simge yerine onay işareti gelir ([AppChip] ile aynı; genişlik oynamaz).
      // Seçili değilken simge okunabilir ton (açık temada ham amber 2.1:1 idi).
      final content = FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? Icons.check_rounded : icon,
              size: 16,
              color: selected ? ink : AppTheme.readableAccent(context, AppTheme.accentAmber),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: AppText.caption,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? ink : primary,
              ),
            ),
          ],
        ),
      );
      return ChoiceChip(
        key: key,
        // [labelWidth] verilirse üç çip EŞİT genişlikte parçalı kontrol gibi durur (ChoiceChip kendi `Center`ı yüzünden
        // `Expanded` içinde bile doğal genişliğine büzülür).
        label: labelWidth == null ? content : SizedBox(width: labelWidth, child: Center(child: content)),
        selected: selected,
        selectedColor: selectedFill,
        backgroundColor: AppTheme.getCardColor(context),
        showCheckmark: false,
        // Kenar kalınlığı iki durumda AYNI (seçilince çip genişliği/yüksekliği oynamaz); renk: seçili okunur ton, değil ≥ 3:1.
        side: BorderSide(
          color: selected ? ink.withValues(alpha: AppPillTokens.selectedRim) : fieldBorder,
          width: AppPillTokens.selectedRimWidth,
        ),
        padding: EdgeInsets.zero,
        labelPadding: const EdgeInsets.symmetric(horizontal: _chipLabelPad),
        onSelected: (_) => context.read<AutomationState>().setThemeMode(mode),
      );
    }

    Widget chips({double? labelWidth}) => Row(
          children: [
            for (final (i, spec) in <(ThemeMode, String, IconData, Key)>[
              (ThemeMode.system, 'Sistem', Icons.brightness_auto_rounded, const Key('theme_system')),
              (ThemeMode.light, 'Aydınlık', Icons.light_mode_rounded, const Key('theme_light')),
              (ThemeMode.dark, 'Karanlık', Icons.dark_mode_rounded, const Key('theme_dark')),
            ].indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: chip(spec.$1, spec.$2, spec.$3, spec.$4, labelWidth: labelWidth)),
            ],
          ],
        );

    // Normal yazı ölçeğinde üç ÇİP eşit genişlikte tek sıra (parçalı denetim görünümü; 2+1 kırılması yok); büyük
    // yazıda (> 1.15x) çipler doğal genişliğinde satıra sarılır (etiket kesilmez, küçültülmez).
    if (MediaQuery.textScalerOf(context).scale(12.5) <= 12.5 * 1.15) {
      return LayoutBuilder(
        builder: (context, constraints) {
          // Her çipin payı: (genişlik - 2 aralık) / 3. Çip = etiket + yatay etiket dolgusu + kenar (en çok 1.4 dp x 2).
          final slot = (constraints.maxWidth - 2 * 8) / 3;
          final labelWidth = slot - 2 * _chipLabelPad - _chipBorderAllowance;
          return chips(labelWidth: labelWidth > 0 ? labelWidth : null);
        },
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip(ThemeMode.system, 'Sistem', Icons.brightness_auto_rounded, const Key('theme_system')),
        chip(ThemeMode.light, 'Aydınlık', Icons.light_mode_rounded, const Key('theme_light')),
        chip(ThemeMode.dark, 'Karanlık', Icons.dark_mode_rounded, const Key('theme_dark')),
      ],
    );
  }

  /// Tema çiplerinin yatay etiket dolgusu ve kenar payı (dp; kenar 1.4 x 2 + güvenlik payı).
  static const double _chipLabelPad = 6;
  static const double _chipBorderAllowance = 4;

  /// Birincil (gradyan) tam genişlik düğme. [family] verilirse o ailenin gradyanı ([accentButtonStyle]; yerel
  /// `backgroundColor` yerine: tema gradyanının altında düz plaka/yanlış renk bırakmaz), verilmezse tema birincil
  /// (sky → cyan) gradyanı. Etiket satıra sarılır (kesilmez); düğme içeriğe göre uzar (sabit yükseklik yok).
  Widget _primaryButton({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    AccentFamily? family,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        key: key,
        onPressed: onPressed,
        style: accentButtonStyle(family),
        icon: Icon(icon, size: 18),
        // `longestLine`: iki satıra sarılan etiket (1.5x) metin kutusunu tüm genişliğe yaymaz; simge + metin TEK grup olarak
        // ortalanır (eskiden simge düğmenin en soluna yapışık, metin kalan alanda ortalı kalıyordu).
        label: Text(
          label,
          textAlign: TextAlign.center,
          textWidthBasis: TextWidthBasis.longestLine,
          maxLines: 2,
          softWrap: true,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// İkincil çerçeveli tam genişlik düğme: çerçeve ve ön plan TEMA'dan (kontrastlı cyan/sky); yalnız simge rengi
  /// [iconColor]'ın **okunabilir tonudur** (açık temada ham vurgu 2.1-2.5:1 idi). Etiket satıra sarılır.
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
        icon: Icon(icon, size: 18, color: AppTheme.readableAccent(context, iconColor)),
        label: Text(
          label,
          textAlign: TextAlign.center,
          textWidthBasis: TextWidthBasis.longestLine,
          maxLines: 2,
          softWrap: true,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: AppTheme.getTextPrimary(context), fontSize: 13),
        ),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
      ),
    );
  }
}

/// Satırları ince çizgiyle ayrılmış TEK cam grup (kimlik bilgileri / hesap eylemleri): ayrı çerçeveli kutular yerine
/// tek yüzey; diyaloğun dikey yüksekliğini ve görsel gürültüyü azaltır.
class _InfoGroup extends StatelessWidget {
  const _InfoGroup({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final tokens = SurfaceTokens.of(Theme.of(context).brightness);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [tokens.cardTop, tokens.cardBottom],
        ),
        borderRadius: BorderRadius.circular(AppRadius.r16),
        border: Border.all(color: tokens.rimSolid),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: tokens.rimSolid),
            rows[i],
          ],
        ],
      ),
    );
  }
}

/// Kimlik bilgisi satırı (simge + başlık + değer). Başlık ve değer tek satıra sığmazsa değer alt satıra geçer ve
/// tam okunur; sığarsa başlık solda, değer sağdadır (Row + yan yana metin dar ekranda taşardı).
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.title, required this.value, this.valueKey});

  final IconData icon;
  final String title;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, color: AppTheme.getTextMuted(context), size: 18),
          ),
          const SizedBox(width: 10),
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

/// Hesap grubu satırı: orb simge rozeti ([OrbIconBadge]) + etiket (satıra sarılır) + ok; basınca ölçek geri bildirimi ([Pressable],
/// `onTap` gecikmesiz), dokunma hedefi ≥ 52 dp, tek `button` anlam düğümü. [danger] ⇒ rose etiket.
class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    super.key,
    required this.icon,
    required this.family,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final AccentFamily family;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final fg = danger ? AppTheme.dangerText(context) : AppTheme.getTextPrimary(context);
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        pressedScale: 0.985,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
            child: Row(
              children: [
                // Parlak orb rozet: avatar / çekmece / konsol satırlarıyla AYNI dil (eskiden düz tonlu disk idi). 44 dp'lik
                // orb 32 dp'ye ölçeklenir (NeonAppBar kalıbı); yoğun satırda parıltı yok.
                SizedBox.square(
                  dimension: 32,
                  child: FittedBox(
                    child: OrbIconBadge(icon: icon, family: family, size: OrbSize.sm, glow: false),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: fg)),
                ),
                Icon(Icons.chevron_right_rounded, size: 20, color: AppTheme.getTextMuted(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
