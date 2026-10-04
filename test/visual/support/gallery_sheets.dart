// Galeri sayfaları: orb matrisi, bileşen sayfası, yüzeyler sayfası.
import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/accent_fab.dart';
import 'package:ev_otomasyon/ui/widgets/app_pill.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:ev_otomasyon/ui/widgets/settings/accent_button.dart';
import 'package:ev_otomasyon/ui/widgets/surface_card.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Orb matrisi sütunları (durumlar).
const List<String> orbStates = ['idle', 'pressed', 'active', 'pending', 'success', 'disabled'];

class GalleryVariant {
  const GalleryVariant(this.name, this.label, this.icon, this.family);
  final String name;
  final String label;
  final IconData icon;
  final AccentFamily family;
}

const List<GalleryVariant> orbVariants = [
  GalleryVariant('open', 'Aç', Icons.arrow_upward_rounded, AppFamilies.emerald),
  GalleryVariant('stop', 'Durdur', Icons.stop_rounded, AppFamilies.rose),
  GalleryVariant('close', 'Kapat', Icons.arrow_downward_rounded, AppFamilies.sky),
  GalleryVariant('lamp', 'Lamba', Icons.lightbulb_rounded, AppFamilies.amber),
  GalleryVariant('night', 'Gece', Icons.nightlight_round, AppFamilies.violet),
  GalleryVariant('pulse', 'Tetikle', Icons.bolt_rounded, AppFamilies.cyan),
  GalleryVariant('neutral', 'Nötr', Icons.tune_rounded, AppFamilies.slate),
];

/// Basılı sütunun anahtarı (golden testi bu orb'lara parmak koyar).
Key pressedOrbKey(String variant) => ValueKey('orb_${variant}_pressed');

TextStyle _caption(BuildContext context) =>
    TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.getTextMuted(context));

/// 7 varyant × 6 durum (lg 64).
class OrbMatrixSheet extends StatelessWidget {
  const OrbMatrixSheet({super.key, required this.status});

  final ValueListenable<OrbStatus> status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Orb matrisi (lg 64)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context))),
          const SizedBox(height: 10),
          Row(
            children: [
              const SizedBox(width: 64),
              for (final s in orbStates) SizedBox(width: 80, child: Center(child: Text(s, style: _caption(context)))),
            ],
          ),
          for (final v in orbVariants)
            SizedBox(
              height: 80,
              child: Row(
                children: [
                  SizedBox(width: 64, child: Text(v.label, style: _caption(context))),
                  for (final s in orbStates)
                    SizedBox(
                      width: 80,
                      child: Center(
                        child: ValueListenableBuilder<OrbStatus>(
                          valueListenable: status,
                          builder: (context, st, _) => OrbButton(
                            key: s == 'pressed' ? pressedOrbKey(v.name) : ValueKey('orb_${v.name}_$s'),
                            icon: v.icon,
                            family: v.family,
                            semanticLabel: v.label,
                            size: OrbSize.lg,
                            active: s == 'active',
                            pending: s == 'pending',
                            status: s == 'success' ? st : OrbStatus.none,
                            onTap: s == 'disabled' ? null : () {},
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Orb boyutları, toggle, rozet, cam düğme, nokta ve yay bileşenleri.
class ComponentsSheet extends StatelessWidget {
  const ComponentsSheet({super.key, required this.toggleValue, required this.ringTrigger});

  final ValueListenable<bool> toggleValue;
  final ValueListenable<int> ringTrigger;

  Widget _label(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context))),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(context, 'Boyutlar: xl 76 · lg 64 · md 52 · sm 44 (üst idle, alt active)'),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final s in OrbSize.values)
                OrbButton(icon: Icons.arrow_downward_rounded, family: AppFamilies.sky, semanticLabel: s.name, size: s, onTap: () {}),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final s in OrbSize.values)
                OrbButton(icon: Icons.lightbulb_rounded, family: AppFamilies.amber, semanticLabel: s.name, size: s, active: true, onTap: () {}),
            ],
          ),
          _label(context, 'OrbToggle: kapalı (cam) / açık (amber) / geçiş / pasif / bekliyor'),
          ValueListenableBuilder<bool>(
            valueListenable: toggleValue,
            builder: (context, on, _) => Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                OrbToggle(value: false, onChanged: (_) {}, icon: Icons.lightbulb_outline_rounded, activeIcon: Icons.lightbulb_rounded, family: AppFamilies.amber, semanticLabel: 'kapalı', size: OrbSize.lg),
                OrbToggle(value: true, onChanged: (_) {}, icon: Icons.lightbulb_outline_rounded, activeIcon: Icons.lightbulb_rounded, family: AppFamilies.amber, semanticLabel: 'açık', size: OrbSize.lg),
                OrbToggle(value: on, onChanged: (_) {}, icon: Icons.lightbulb_outline_rounded, activeIcon: Icons.lightbulb_rounded, family: AppFamilies.amber, semanticLabel: 'geçiş', size: OrbSize.md),
                OrbToggle(value: false, onChanged: null, icon: Icons.lightbulb_outline_rounded, family: AppFamilies.amber, semanticLabel: 'devre dışı', size: OrbSize.md),
                OrbToggle(value: true, onChanged: (_) {}, icon: Icons.lock_rounded, family: AppFamilies.rose, semanticLabel: 'bekliyor', size: OrbSize.md, pending: true),
              ],
            ),
          ),
          _label(context, 'Salt-okunur OrbToggle: AÇIK (soluk aile) · KAPALI (gri) — canControl:false'),
          Row(
            children: [
              OrbToggle(key: const ValueKey('toggle_ro_on'), value: true, onChanged: null, icon: Icons.lightbulb_outline_rounded, activeIcon: Icons.lightbulb_rounded, family: AppFamilies.amber, semanticLabel: 'salt-okunur açık', size: OrbSize.lg),
              const SizedBox(width: 16),
              OrbToggle(key: const ValueKey('toggle_ro_off'), value: false, onChanged: null, icon: Icons.lightbulb_outline_rounded, activeIcon: Icons.lightbulb_rounded, family: AppFamilies.amber, semanticLabel: 'salt-okunur kapalı', size: OrbSize.lg),
              const SizedBox(width: 16),
              OrbToggle(value: true, onChanged: null, icon: Icons.lock_outline_rounded, activeIcon: Icons.lock_rounded, family: AppFamilies.rose, semanticLabel: 'salt-okunur kilit', size: OrbSize.md),
              const SizedBox(width: 16),
              OrbToggle(value: true, onChanged: null, icon: Icons.power_settings_new_rounded, family: AppFamilies.emerald, semanticLabel: 'salt-okunur güç', size: OrbSize.md),
            ],
          ),
          _label(context, 'dimmed (çevrimdışı / son bilinen): ETKİN ama soluk, dokunuş çalışır'),
          Row(
            children: [
              OrbButton(icon: Icons.stop_rounded, family: AppFamilies.rose, semanticLabel: 'soluk durdur', size: OrbSize.md, dimmed: true, onTap: () {}),
              const SizedBox(width: 16),
              OrbToggle(value: true, onChanged: (_) {}, icon: Icons.lightbulb_outline_rounded, activeIcon: Icons.lightbulb_rounded, family: AppFamilies.amber, semanticLabel: 'soluk açık', size: OrbSize.md, dimmed: true),
              const SizedBox(width: 16),
              OrbToggle(value: false, onChanged: (_) {}, icon: Icons.lightbulb_outline_rounded, family: AppFamilies.amber, semanticLabel: 'soluk kapalı', size: OrbSize.md, dimmed: true),
              const SizedBox(width: 16),
              const OrbIconBadge(icon: Icons.router_rounded, family: AppFamilies.cyan, dimmed: true),
            ],
          ),
          _label(context, 'OrbIconBadge (sm 44): varsayılan = temaya göre soluk parıltı'),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              OrbIconBadge(icon: Icons.nightlight_round, family: AppFamilies.violet),
              OrbIconBadge(icon: Icons.wb_sunny_rounded, family: AppFamilies.amber),
              OrbIconBadge(icon: Icons.home_rounded, family: AppFamilies.cyan),
              OrbIconBadge(icon: Icons.check_rounded, family: AppFamilies.emerald, status: OrbStatus.success),
              OrbIconBadge(icon: Icons.warning_rounded, family: AppFamilies.rose, status: OrbStatus.error),
              OrbIconBadge(icon: Icons.router_rounded, family: AppFamilies.slate, enabled: false),
            ],
          ),
          _label(context, 'OrbIcons: dolu üçgen (yukarı/aşağı) ve harf G; ince çizgi ok yanında'),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              OrbButton(icon: Icons.arrow_upward_rounded, family: AppFamilies.emerald, semanticLabel: 'çizgi ok', size: OrbSize.md, onTap: () {}),
              OrbButton(iconBuilder: OrbIcons.triangle(up: true), family: AppFamilies.emerald, semanticLabel: 'dolu yukarı', size: OrbSize.md, onTap: () {}),
              OrbButton(icon: Icons.stop_rounded, family: AppFamilies.rose, semanticLabel: 'durdur', size: OrbSize.md, onTap: () {}),
              OrbButton(iconBuilder: OrbIcons.triangle(up: false), family: AppFamilies.sky, semanticLabel: 'dolu aşağı', size: OrbSize.md, onTap: () {}),
              OrbButton(iconBuilder: OrbIcons.letter('G'), family: AppFamilies.sky, semanticLabel: 'Google', size: OrbSize.md, onTap: () {}),
            ],
          ),
          _label(context, 'GlassIconButton (44 / hedef 48): normal · rozetli · pasif'),
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              GlassIconButton(icon: Icons.settings_outlined, semanticLabel: 'Ayarlar', onTap: () {}),
              const SizedBox(width: 16),
              GlassIconButton(icon: Icons.notifications_none_rounded, semanticLabel: 'Bildirimler', onTap: () {}, showBadge: true),
              const SizedBox(width: 16),
              GlassIconButton(icon: Icons.menu_rounded, semanticLabel: 'Menü', onTap: null),
              const SizedBox(width: 16),
              GlassIconButton(key: const ValueKey('glass_pressed'), icon: Icons.brightness_6_outlined, semanticLabel: 'Tema', onTap: () {}),
            ],
          ),
          _label(context, 'GlowDot · ProgressArc · PulseRing'),
          Row(
            children: [
              GlowDot(color: AppFamilies.emerald.base, breathing: true),
              const SizedBox(width: 22),
              GlowDot(color: AppFamilies.amber.base, pulses: 3),
              const SizedBox(width: 22),
              GlowDot(color: AppFamilies.rose.base),
              const SizedBox(width: 22),
              GlowDot(color: AppFamilies.slate.base),
              const SizedBox(width: 30),
              ProgressArc(diameter: 40, color: AppTheme.accentTone(context, AppFamilies.cyan)),
              const SizedBox(width: 30),
              ValueListenableBuilder<int>(
                valueListenable: ringTrigger,
                builder: (context, n, _) => SizedBox(
                  width: 44,
                  height: 44,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: AppFamilies.emerald.base),
                      ),
                      PulseRing(color: AppTheme.accentTone(context, AppFamilies.emerald), diameter: 28, trigger: n, maxScale: 1.6),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// SurfaceCard, panjur kartı örneği ve kaydırıcılar.
class CardsSheet extends StatelessWidget {
  const CardsSheet({super.key, required this.sliderValue});

  final ValueListenable<double> sliderValue;

  Widget _label(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context))),
      );

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label(context, 'SurfaceCard: idle · accent · active'),
          SurfaceCard(
            child: Row(
              children: [
                OrbIconBadge(icon: Icons.router_rounded, family: AppFamilies.cyan),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Ana pano', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: primary)),
                      Text('Sistem hazır', style: TextStyle(fontSize: 12.5, color: muted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SurfaceCard(
            accent: AppFamilies.sky.base,
            child: Text('Vurgulu (accent) kart: kenar accent@0.28', style: TextStyle(fontSize: 13, color: primary)),
          ),
          const SizedBox(height: 10),
          SurfaceCard(
            accent: AppFamilies.amber.base,
            active: true,
            onTap: () {},
            child: Row(
              children: [
                OrbToggle(value: true, onChanged: (_) {}, icon: Icons.lightbulb_outline_rounded, activeIcon: Icons.lightbulb_rounded, family: AppFamilies.amber, semanticLabel: 'Salon Avize', size: OrbSize.md),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Salon Avize', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: primary)),
                      Text('AÇIK', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppTheme.warningText(context))),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _label(context, 'Panjur kartı (SurfaceCard + 3 orb + kaydırıcı)'),
          SurfaceCard(
            accent: AppFamilies.emerald.base,
            active: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Salon Panjur', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: primary)),
                    const Spacer(),
                    AnimatedCount(value: 40, format: (v) => '%$v', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: primary)),
                  ],
                ),
                Text('Açılıyor…', style: TextStyle(fontSize: 12.5, color: muted)),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final e in [
                      ('Aç', Icons.arrow_upward_rounded, AppFamilies.emerald, true),
                      ('Durdur', Icons.stop_rounded, AppFamilies.rose, false),
                      ('Kapat', Icons.arrow_downward_rounded, AppFamilies.sky, false),
                    ])
                      Column(
                        children: [
                          OrbButton(icon: e.$2, family: e.$3, semanticLabel: e.$1, size: OrbSize.lg, active: e.$4, onTap: () {}),
                          Text(e.$1, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: primary)),
                        ],
                      ),
                  ],
                ),
                ValueListenableBuilder<double>(
                  valueListenable: sliderValue,
                  builder: (context, v, _) => Slider(value: v, onChanged: (_) {}),
                ),
              ],
            ),
          ),
          _label(context, 'Kaydırıcı: 0 · 40 · 100 · pasif'),
          Slider(value: 0.0, onChanged: (_) {}),
          Slider(value: 0.4, onChanged: (_) {}),
          Slider(value: 1.0, onChanged: (_) {}),
          const Slider(value: 0.55, onChanged: null),
        ],
      ),
    );
  }
}

/// Düğmeler, çipler, anahtarlar, durum hapları, iskelet.
class ControlsSheet extends StatelessWidget {
  const ControlsSheet({super.key});

  Widget _label(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context))),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label(context, 'Düğmeler: birincil · pasif · basılı · dolu · çerçeve · metin'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ElevatedButton(onPressed: () {}, child: const Text('Giriş Yap')),
              const ElevatedButton(onPressed: null, child: Text('Pasif')),
              ElevatedButton(key: const ValueKey('btn_pressed'), onPressed: () {}, child: const Text('Basılı')),
              FilledButton(onPressed: () {}, child: const Text('Dolu')),
              OutlinedButton(onPressed: () {}, child: const Text('Çerçeve')),
              TextButton(onPressed: () {}, child: const Text('Metin')),
            ],
          ),
          // WP-FX-A (3): pasif gradyan düğme OPAK cam: arkadaki devre izi etiketin altından geçmez; etiket ≥ 4.5:1.
          _label(context, 'Pasif gradyan düğme: opak cam (devre izi görünmez) · etiket ≥ 4.5:1'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              const ElevatedButton(onPressed: null, child: Text('Bekleyin (0:30)')),
              ElevatedButton(onPressed: null, style: accentButtonStyle(AppFamilies.emerald), child: const Text('Devreye Almayı Tamamla')),
            ],
          ),
          // WP-FX-A (1): çerçeveli düğme kenarı TEK ton kuralı (≥ 3:1): tema varsayılanı ve her aile aynı belirginlikte.
          _label(context, 'Çerçeveli düğme: tema varsayılanı · accentOutlinedButtonStyle(aile) — kenar ≥ 3:1'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton(onPressed: () {}, child: const Text('Varsayılan')),
              for (final f in [AppFamilies.sky, AppFamilies.cyan, AppFamilies.emerald, AppFamilies.amber, AppFamilies.rose, AppFamilies.violet, AppFamilies.slate])
                OutlinedButton(onPressed: () {}, style: accentOutlinedButtonStyle(context, f, minimumSize: const Size(48, 48)), child: Text(f.name)),
            ],
          ),
          _label(context, 'Çip: seçili (cyan kenar) · seçilmemiş · pasif'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ChoiceChip(label: const Text('Salon'), selected: true, onSelected: (_) {}),
              ChoiceChip(label: const Text('Mutfak'), selected: false, onSelected: (_) {}),
              ChoiceChip(label: const Text('Yatak odası'), selected: false, onSelected: (_) {}),
              const ChoiceChip(label: Text('Pasif'), selected: false, onSelected: null),
              FilterChip(label: const Text('Filtre'), selected: true, onSelected: (_) {}),
            ],
          ),
          _label(context, 'Anahtar: açık · kapalı · salt-okunur açık · salt-okunur kapalı'),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Switch(value: true, onChanged: (_) {}),
              Switch(value: false, onChanged: (_) {}),
              const Switch(value: true, onChanged: null),
              const Switch(value: false, onChanged: null),
            ],
          ),
          // WP-FX-A (2): birincil FAB = AccentFab (şeffaf FAB + ToneButtonSurface gradyanı + cila + 1 px kenar + renkli parıltı).
          _label(context, 'AccentFab: genişletilmiş · yuvarlak · pasif (düz #2563EB Material FAB değil)'),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AccentFab(onPressed: () {}, icon: Icons.person_add_alt_1_rounded, label: 'Hesap Ekle'),
              AccentFab(onPressed: () {}, icon: Icons.add_rounded, tooltip: 'Ekle'),
              const AccentFab(onPressed: null, icon: Icons.add_rounded, tooltip: 'Pasif'),
            ],
          ),
          // Üretim rozeti (AppPill): ton .14 + kenar .40, OPAK; AppChip: seçili = aile tonu + onay işareti.
          _label(context, 'Durum hapları (AppPill) · çip (AppChip)'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppPill(label: 'Sistem Hazır', family: AppFamilies.emerald, dot: true),
              AppPill(label: 'Bağlanıyor…', family: AppFamilies.amber, dot: true),
              AppPill(label: 'Çevrimdışı', family: AppFamilies.slate, active: false, icon: Icons.cloud_off_rounded),
              AppChip(label: 'Tümü', selected: true, onTap: () {}),
              AppChip(label: 'Stokta', selected: false, onTap: () {}),
            ],
          ),
          // WP-FX-A (5): dar yuvada tek sözcüklü rozet kırılmaz ('ENVANTE'+'R' regresyonu): tek satır, küçülür.
          _label(context, 'Rozet dar yuvada: sözcük ortasından KIRILMAZ (ENVANTER) · çok sözcüklü sözcük sınırında sarılır'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
              SizedBox(width: 118, child: AppPill(label: 'ENVANTER', family: AppFamilies.cyan)),
              SizedBox(width: 118, child: AppPill(label: 'YÖNETİCİ', family: AppFamilies.violet)),
              SizedBox(width: 118, child: AppPill(label: 'STOK & PANO', family: AppFamilies.amber)),
            ],
          ),
          _label(context, 'İskelet (SkeletonText: yazı ölçeğiyle büyür; gerçek 28 sp sayıyla aynı yükseklik)'),
          Row(
            children: [
              const SkeletonText(width: 64, fontSize: 28, lineHeight: 1.1),
              const SizedBox(width: 16),
              Text('48', style: TextStyle(fontSize: 28, height: 1.1, fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context))),
            ],
          ),
          const SizedBox(height: 8),
          const SkeletonCard(),
          const SizedBox(height: 8),
          const SkeletonCard(lines: 3, showLeading: false),
        ],
      ),
    );
  }
}

/// Diyalog, alt sayfa, snackbar ve giriş alanları (tema bileşenleri; gerçek yol `showDialog` vb. değil, statik).
class OverlaysSheet extends StatelessWidget {
  const OverlaysSheet({super.key, required this.focusNode});

  final FocusNode focusNode;

  Widget _label(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.getTextPrimary(context))),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label(context, 'Diyalog (dialogTheme)'),
          AlertDialog(
            title: const Text('Erişiminiz sona erdi'),
            content: const Text('Misafir erişim süreniz doldu. Yeniden erişim için ev sahibinden yeni bir davet isteyebilirsiniz.'),
            actions: [
              TextButton(onPressed: () {}, child: const Text('Vazgeç')),
              FilledButton(onPressed: () {}, child: const Text('Tamam')),
            ],
          ),
          _label(context, 'Alt sayfa (bottomSheetTheme)'),
          BottomSheet(
            onClosing: () {},
            enableDrag: false,
            // Gerçek `showModalBottomSheet` içeriği tam genişliktedir; statik örnekte de içerik genişliği sonsuz verilir
            // (aksi halde M3 `Align`+`ConstrainedBox` sayfayı içerik genişliğine büzüp ortalıyordu).
            builder: (context) => const SizedBox(
              width: double.infinity,
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text('Senaryo seç', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), SizedBox(height: 8), Text('Gece modu, Çıkış, Misafir')],
                ),
              ),
            ),
          ),
          _label(context, 'Snackbar (snackBarTheme)'),
          SnackBar(
            content: const Text('Komut geri alındı: panjur yanıt vermedi.'),
            action: SnackBarAction(label: 'Tekrar dene', onPressed: () {}),
            behavior: SnackBarBehavior.fixed,
            animation: const AlwaysStoppedAnimation<double>(1.0),
          ),
          _label(context, 'Giriş alanları: boş (soluk etiket) · dolu (yüzen etiket) · simgeli · hatalı · odaklı (cyan halka)'),
          const TextField(decoration: InputDecoration(labelText: 'E-posta', hintText: 'ornek@mail.com')),
          const SizedBox(height: 10),
          TextField(
            controller: TextEditingController(text: '192.168.1.40'),
            decoration: const InputDecoration(labelText: 'Cihaz adresi', prefixIcon: Icon(Icons.router_rounded)),
          ),
          const SizedBox(height: 10),
          const TextField(decoration: InputDecoration(labelText: 'Telefon', prefixIcon: Icon(Icons.phone_rounded), suffixIcon: Icon(Icons.visibility_rounded))),
          const SizedBox(height: 10),
          const TextField(decoration: InputDecoration(labelText: 'Şifre', errorText: 'En az 10 karakter olmalı')),
          const SizedBox(height: 10),
          TextField(focusNode: focusNode, decoration: const InputDecoration(labelText: 'Parola', hintText: '••••••••')),
        ],
      ),
    );
  }
}

/// Gerçek [CircuitBackground] (PCB fotoğrafı) üstünde DOĞRUDAN duran metinler: AppBar başlığı, alt başlık, bölüm
/// başlıkları, kart dışı açıklamalar ve yarı saydam uyarı kutusu. Üretimde TÜM ekranlar bu zeminin üstündedir; bu sayfa
/// `pumpGallery(realBackground: true)` ile çekilir ve metin/örtü kontrastını değerlendirir.
class RealBackgroundSheet extends StatelessWidget {
  const RealBackgroundSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.getTextPrimary(context);
    final muted = AppTheme.getTextMuted(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Yeni Hesap Oluşturun', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Evinizi ve tüm cihazlarınızı güvenle yönetin', style: TextStyle(fontSize: 14, color: muted)),
          const SizedBox(height: 18),
          Text('Panjurlar', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: primary)),
          const SizedBox(height: 4),
          Text('Hızlı Senaryolar', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: primary)),
          const SizedBox(height: 10),
          SurfaceCard(
            child: Row(
              children: [
                const OrbIconBadge(icon: Icons.router_rounded, family: AppFamilies.cyan),
                const SizedBox(width: 12),
                Expanded(child: Text('Ana pano — Sistem hazır', style: TextStyle(fontSize: 14, color: primary))),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text('Zaten bir hesabınız var mı? Giriş yapın', style: TextStyle(fontSize: 14, color: muted)),
          const SizedBox(height: 14),
          DecoratedBox(
            decoration: BoxDecoration(
              // OPAK (üretimdeki peace_notice_host gibi alphaBlend): PCB çip pimleri metnin altından geçmez.
              color: Color.alphaBlend(AppFamilies.amber.base.withValues(alpha: 0.12), AppTheme.getCardColor(context)),
              borderRadius: BorderRadius.circular(AppRadius.r12),
              border: Border.all(color: AppFamilies.amber.base.withValues(alpha: 0.5)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Güvenliğiniz için parolanızı değiştirmeniz gerekiyor.', style: TextStyle(fontSize: 13, color: AppTheme.warningText(context))),
            ),
          ),
          const SizedBox(height: 14),
          Text('Kısa bölüm başlığı • açıklama metni 12 sp', style: TextStyle(fontSize: 12, color: muted)),
        ],
      ),
    );
  }
}
