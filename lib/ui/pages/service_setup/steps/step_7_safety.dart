import 'package:flutter/material.dart';

import '../../../theme/tokens.dart';
import '../../../widgets/app_pill.dart';
import '../../../widgets/settings/accent_button.dart';
import '../logic/relay_logic.dart';
import '../setup_style.dart';
import '../setup_widgets.dart';

// =============================================================================
// Adım 7 genişletmesi (WP-A4; tasarım §4.4, §4.5): röle kartındaki "Bu kanala ne bağlı?" paneli, Girişler ve
// Sensörler kartı, panoya yazma kartı. Mantık [RelayLogic]'tedir; bu dosya yalnız çizer.
//
// Anahtarlar: `chip_use_<röle>_<light|valve|siren|fan|generic>`, `panel_valve_<röle>`, `chip_close_<röle>_<energize|
// deenergize|unknown>`, `chip_medium_<röle>_<water|gas>`, `chip_drive_<röle>_<single|dual>`, `dd_open_relay_<röle>`,
// `dd_fb_<röle>`, `chip_zone_<röle>_<1..4>`, `switch_atex_<röle>`, `chip_dim_<röle>_<yes|no>`, `panel_dimmer_<röle>`,
// `chip_dimsrc_<röle>_<modbus|bridge>`, `note_open_relay_<röle>`, `card_inputs`, `input_<d3|b1>`, `dd_role_<id>`,
// `chip_contact_<id>_<nc|no>`, `chip_inzone_<id>_<1..4>`, `btn_add_bridge`, `btn_remove_bridge_<n>`,
// `card_safety_save`, `btn_save_safety`, `safety_test_result_<bölge>`.
// =============================================================================

/// Seçim çipleri satırı (tek seçim). Renk tek ipucu değildir: seçili çip onay işareti taşır ([AppChip]).
class _Choices<T> extends StatelessWidget {
  const _Choices({required this.keyPrefix, required this.options, required this.selected, required this.onSelected, this.enabled = true});

  final String keyPrefix;
  final List<(T value, String wire, String label)> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in options)
          AppChip(
            key: Key('${keyPrefix}_${o.$2}'),
            label: o.$3,
            selected: o.$1 == selected,
            onTap: enabled ? () => onSelected(o.$1) : null,
          ),
      ],
    );
  }
}

class _Question extends StatelessWidget {
  const _Question(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(text, style: TextStyle(fontWeight: FontWeight.w800, color: SetupColors.text(context))),
      );
}

Widget _zoneChips(String keyPrefix, int zone, ValueChanged<int> onSelected, {bool enabled = true}) => _Choices<int>(
      keyPrefix: keyPrefix,
      options: <(int, String, String)>[for (var z = 1; z <= kMaxSafetyZones; z++) (z, '$z', 'Bölge $z')],
      selected: zone,
      onSelected: onSelected,
      enabled: enabled,
    );

/// Röle kartının atama paneli: "Bu kanala ne bağlı?" + türüne göre sorular + bu kanala ait doğrulama bulguları.
class RelayAssignmentPanel extends StatelessWidget {
  const RelayAssignmentPanel({super.key, required this.logic, required this.relay});

  final RelayLogic logic;
  final RelayCheck relay;

  @override
  Widget build(BuildContext context) {
    final id = relay.id;
    final a = relay.assign;
    final busy = logic.busy;
    final owner = logic.openRelayOwners[id];
    void set(ChannelAssignment next) => logic.setAssignment(id, next);

    if (owner != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: SetupInfoRow(
          key: Key('note_open_relay_$id'),
          icon: Icons.link_rounded,
          color: SetupColors.info,
          text: 'Bu röle, Röle $owner vanasının AÇMA rölesidir (iki röleli vana). Aç ve kapat röleleri aynı anda '
              'asla enerjilenmez.',
        ),
      );
    }

    final issues = <SafetyIssue>[for (final i in logic.safetyIssues) if (i.target == 'relay:$id') i];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Question('Bu kanala ne bağlı?'),
        _Choices<ChannelUse>(
          keyPrefix: 'chip_use_$id',
          options: <(ChannelUse, String, String)>[for (final u in ChannelUse.values) (u, u.wire, u.label)],
          selected: a.use,
          enabled: !busy,
          onSelected: (u) => set(u == ChannelUse.light
              ? ChannelAssignment(wantsDimming: a.wantsDimming, dimmerSource: a.dimmerSource)
              : a.copyWith(use: u, wantsDimming: false)),
        ),
        if (a.use == ChannelUse.light) _DimmerQuestion(logic: logic, relay: relay),
        if (a.isValve) _ValvePanel(logic: logic, relay: relay),
        if (a.use == ChannelUse.siren || a.use == ChannelUse.fan || a.use == ChannelUse.generic) ...[
          const _Question('Hangi bölgede?'),
          _zoneChips('chip_zone_$id', a.zone, (z) => set(a.copyWith(zone: z)), enabled: !busy),
          if (a.use == ChannelUse.siren)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SetupInfoRow(
                icon: Icons.timer_outlined,
                color: SetupColors.info,
                text: 'Alarmda en çok $kDefaultSirenRunSec sn çalar; onayla susturulur.',
              ),
            ),
          if (a.use == ChannelUse.fan)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SetupCheckTile(
                key: Key('switch_atex_$id'),
                value: a.fanExProof,
                onChanged: busy ? null : (v) => set(a.copyWith(fanExProof: v)),
                label: 'Bu fan gaz kaçağında çalıştırılabilir (ex-proof / ATEX onaylı). Emin değilseniz işaretlemeyin.',
              ),
            ),
        ],
        for (final issue in issues)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SetupInfoRow(
              icon: issue.blocking ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
              color: issue.blocking ? SetupColors.error : SetupColors.warn,
              text: issue.message,
            ),
          ),
      ],
    );
  }
}

class _ValvePanel extends StatelessWidget {
  const _ValvePanel({required this.logic, required this.relay});

  final RelayLogic logic;
  final RelayCheck relay;

  @override
  Widget build(BuildContext context) {
    final id = relay.id;
    final a = relay.assign;
    final busy = logic.busy;
    void set(ChannelAssignment next) => logic.setAssignment(id, next);
    final otherRelays = <int>[
      for (final r in logic.relays)
        if (r.id != id && !r.assign.use.isActuator) r.id,
    ];
    final dis = <int>[
      for (final i in logic.inputs)
        if (!i.isBridge) i.index,
    ];
    return Column(
      key: Key('panel_valve_$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Question('Vana, rölede enerji varken mi kapalı?'),
        _Choices<ValveCloseMode>(
          keyPrefix: 'chip_close_$id',
          options: const <(ValveCloseMode, String, String)>[
            (ValveCloseMode.energizeToClose, 'energize', 'Evet: enerji verince kapanır'),
            (ValveCloseMode.deenergizeToClose, 'deenergize', 'Hayır: enerji kesilince kapanır'),
            (ValveCloseMode.unknown, 'unknown', 'Bilmiyorum'),
          ],
          selected: a.closeMode,
          enabled: !busy,
          onSelected: (m) => set(a.copyWith(closeMode: m)),
        ),
        if (a.closeMode == ValveCloseMode.unknown)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: SetupInfoRow(
              icon: Icons.science_outlined,
              color: SetupColors.info,
              text: 'Yukarıdaki Aç / Kapat ile röleyi deneyin ve vananın konumunu gözleyin; sonra yanıtı seçin.',
            ),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: SetupInfoRow(
            icon: Icons.power_off_outlined,
            color: SetupColors.info,
            text: 'Elektrik kesildiğinde suyun da kesilmesini istiyorsanız enerji kesilince kapanan (NC) selenoid seçin. '
                'Motorlu vanalar kesintide konumunu korur.',
          ),
        ),
        const _Question('Bu vana neyi kesiyor?'),
        _Choices<String?>(
          keyPrefix: 'chip_medium_$id',
          options: const <(String?, String, String)>[('water', 'water', 'Su'), ('gas', 'gas', 'Gaz')],
          selected: a.medium,
          enabled: !busy,
          onSelected: (m) => set(a.copyWith(medium: m)),
        ),
        if (a.isGasValve)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: SetupInfoRow(
              icon: Icons.local_fire_department_outlined,
              color: SetupColors.warn,
              text: 'Gaz vanası yalnız yerinde düğmeyle açılır; her elektrik kesintisinden ve testten sonra kapalı kalır. '
                  'Açma düğmesini "Girişler ve Sensörler" bölümünde "Gaz vanası açma düğmesi" olarak seçin.',
            ),
          ),
        const _Question('Vana kaç röleyle sürülüyor?'),
        _Choices<ValveDrive>(
          keyPrefix: 'chip_drive_$id',
          options: const <(ValveDrive, String, String)>[
            (ValveDrive.single, 'single', 'Tek röle'),
            (ValveDrive.dual, 'dual', 'İki röle (aç + kapat)'),
          ],
          selected: a.drive,
          enabled: !busy,
          onSelected: (d) => set(d == ValveDrive.single ? a.copyWith(drive: d, clearOpenRelay: true) : a.copyWith(drive: d)),
        ),
        if (a.drive == ValveDrive.dual) ...[
          const _Question('Açma rölesi hangisi? (bu röle kapatır)'),
          DropdownButton<int?>(
            key: Key('dd_open_relay_$id'),
            isExpanded: true,
            value: otherRelays.contains(a.openRelay) ? a.openRelay : null,
            hint: const Text('Röle seçin'),
            items: <DropdownMenuItem<int?>>[
              for (final r in otherRelays) DropdownMenuItem<int?>(value: r, child: Text('Röle $r')),
            ],
            onChanged: busy ? null : (r) => set(r == null ? a.copyWith(clearOpenRelay: true) : a.copyWith(openRelay: r)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SetupInfoRow(
              icon: Icons.timer_outlined,
              color: SetupColors.info,
              text: 'Darbe süresi ${a.pulseSec} sn. Aç ve kapat röleleri aynı anda asla enerjilenmez.',
            ),
          ),
        ],
        const _Question('Konum geri bildirim kontağı var mı? Hangi girişe bağlı?'),
        DropdownButton<int?>(
          key: Key('dd_fb_$id'),
          isExpanded: true,
          value: dis.contains(a.fbDi) ? a.fbDi : null,
          items: <DropdownMenuItem<int?>>[
            const DropdownMenuItem<int?>(value: null, child: Text('Geri bildirim yok')),
            for (final d in dis) DropdownMenuItem<int?>(value: d, child: Text('Giriş $d')),
          ],
          onChanged: busy ? null : (d) => set(d == null ? a.copyWith(clearFbDi: true) : a.copyWith(fbDi: d)),
        ),
        const _Question('Hangi bölgede?'),
        _zoneChips('chip_zone_$id', a.zone, (z) => set(a.copyWith(zone: z)), enabled: !busy),
      ],
    );
  }
}

/// K4: "Bu lambanın parlaklığı ayarlanacak mı?" (varsayılan Hayır). Evet -> dimmer donanım yönergesi (§4.5).
class _DimmerQuestion extends StatelessWidget {
  const _DimmerQuestion({required this.logic, required this.relay});

  final RelayLogic logic;
  final RelayCheck relay;

  @override
  Widget build(BuildContext context) {
    final id = relay.id;
    final a = relay.assign;
    final busy = logic.busy;
    final guide = logic.dimmerGuide(id);
    final muted = SetupColors.muted(context);
    final text = SetupColors.text(context);
    Widget steps(List<String> items) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${i + 1}. ${items[i]}', style: TextStyle(fontSize: 13, height: 1.35, color: text)),
              ),
          ],
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Question('Bu lambanın parlaklığı ayarlanacak mı?'),
        _Choices<bool>(
          keyPrefix: 'chip_dim_$id',
          options: const <(bool, String, String)>[(false, 'no', 'Hayır'), (true, 'yes', 'Evet')],
          selected: a.wantsDimming,
          enabled: !busy,
          onSelected: (v) => logic.setAssignment(id, a.copyWith(wantsDimming: v)),
        ),
        if (a.wantsDimming)
          SetupCard(
            key: Key('panel_dimmer_$id'),
            accent: SetupColors.warn,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(guide.intro, style: TextStyle(fontWeight: FontWeight.w700, height: 1.35, color: text)),
                const SizedBox(height: 10),
                _Choices<DimmerSource>(
                  keyPrefix: 'chip_dimsrc_$id',
                  options: const <(DimmerSource, String, String)>[
                    (DimmerSource.modbus, 'modbus', 'Kablolu (RS485)'),
                    (DimmerSource.bridge, 'bridge', 'Kablosuz (Zigbee/Thread)'),
                  ],
                  selected: a.dimmerSource,
                  enabled: !busy,
                  onSelected: (src) => logic.setAssignment(id, a.copyWith(dimmerSource: src)),
                ),
                const SizedBox(height: 10),
                Text(guide.modbusTitle, style: TextStyle(fontWeight: FontWeight.w800, color: text)),
                steps(guide.modbusSteps),
                const SizedBox(height: 10),
                Text(guide.bridgeTitle, style: TextStyle(fontWeight: FontWeight.w800, color: text)),
                steps(guide.bridgeSteps),
                const SizedBox(height: 10),
                Text(guide.fallback, style: TextStyle(fontSize: 12.5, color: muted)),
              ],
            ),
          ),
      ],
    );
  }
}

/// "Girişler ve Sensörler" (§4.4 madde 2): her DI ve kablosuz yuva için rol, kontak tipi (NO/NC) ve bölge.
class SafetyInputsCard extends StatelessWidget {
  const SafetyInputsCard({super.key, required this.logic});

  final RelayLogic logic;

  @override
  Widget build(BuildContext context) {
    final busy = logic.busy;
    final bridges = logic.inputs.where((i) => i.isBridge).length;
    return SetupCard(
      key: const Key('card_inputs'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Girişler ve Sensörler',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context))),
          const SizedBox(height: 4),
          Text(
            'Her girişe ne bağlı olduğunu seçin. Duvar butonu bugünkü gibi çalışır; sensörler alarm üretir ve '
            'bölgelerindeki vanaları kapatır.',
            style: TextStyle(fontSize: 12.5, color: SetupColors.muted(context)),
          ),
          for (final input in logic.inputs) _InputRow(logic: logic, input: input),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('btn_add_bridge'),
              style: accentOutlinedButtonStyle(context, AppFamilies.cyan, minimumSize: const Size(48, 48)),
              onPressed: busy || bridges >= kMaxBridgeSlots ? null : logic.addBridgeSensor,
              icon: const Icon(Icons.sensors_rounded, size: 18),
              label: const Text('Kablosuz sensör ekle'),
            ),
          ),
        ],
      ),
    );
  }
}

class _InputRow extends StatelessWidget {
  const _InputRow({required this.logic, required this.input});

  final RelayLogic logic;
  final InputAssignment input;

  @override
  Widget build(BuildContext context) {
    final id = input.id;
    final busy = logic.busy;
    final roles = input.isBridge ? InputRole.bridgeRoles : InputRole.values;
    final hasZone = input.role.isSensor || input.role.isSafetyControl;
    final issues = <SafetyIssue>[for (final i in logic.safetyIssues) if (i.target == 'input:$id') i];
    return Padding(
      key: Key('input_$id'),
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  input.isBridge ? 'Kablosuz sensör ${input.index}' : 'Giriş ${input.index}',
                  style: TextStyle(fontWeight: FontWeight.w800, color: SetupColors.text(context)),
                ),
              ),
              if (input.isBridge)
                TextButton(
                  key: Key('btn_remove_bridge_${input.index}'),
                  style: setupInlineActionStyle(),
                  onPressed: busy ? null : () => logic.removeBridgeSensor(input.index),
                  child: const Text('Kaldır'),
                ),
            ],
          ),
          DropdownButton<InputRole>(
            key: Key('dd_role_$id'),
            isExpanded: true,
            value: roles.contains(input.role) ? input.role : roles.first,
            items: <DropdownMenuItem<InputRole>>[
              for (final r in roles) DropdownMenuItem<InputRole>(value: r, child: Text(r.label)),
            ],
            onChanged: busy ? null : (r) => r == null ? null : logic.setInput(input.copyWith(role: r)),
          ),
          if (input.role.isSensor) ...[
            const SizedBox(height: 6),
            if (input.role.requiresNc)
              const SetupInfoRow(
                icon: Icons.lock_outline_rounded,
                color: SetupColors.info,
                text: 'NC (normalde kapalı) bağlantı zorunlu: dedektörün enerjisi kesilir ya da kablo koparsa alarm olur.',
              )
            else
              _Choices<bool>(
                keyPrefix: 'chip_contact_$id',
                options: const <(bool, String, String)>[(true, 'nc', 'NC (önerilen)'), (false, 'no', 'NO')],
                selected: input.normallyClosed,
                enabled: !busy,
                onSelected: (nc) => logic.setInput(input.copyWith(normallyClosed: nc)),
              ),
          ],
          if (hasZone) ...[
            const SizedBox(height: 8),
            _zoneChips('chip_inzone_$id', input.zone, (z) => logic.setInput(input.copyWith(zone: z)), enabled: !busy),
          ],
          for (final issue in issues)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SetupInfoRow(
                icon: issue.blocking ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
                color: issue.blocking ? SetupColors.error : SetupColors.warn,
                text: issue.message,
              ),
            ),
        ],
      ),
    );
  }
}

/// Planı panoya yazma kartı: desteklenmeyen pano notu, genel bulgular, kayıt düğmesi ve bölge testi sonuçları.
class SafetySaveCard extends StatelessWidget {
  const SafetySaveCard({super.key, required this.logic});

  final RelayLogic logic;

  @override
  Widget build(BuildContext context) {
    final devices = hasSafetyDevices(logic.assignments, logic.inputs);
    final planIssues = <SafetyIssue>[for (final i in logic.safetyIssues) if (i.target == 'plan') i];
    final unsupported = !logic.safetySupported && devices;
    final enabled = !logic.busy && logic.canSaveSafety && logic.blockingIssues.isEmpty && logic.safetySupported;
    return SetupCard(
      key: const Key('card_safety_save'),
      accent: logic.needsSafetySave ? SetupColors.warn : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Güvenlik ayarları',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: SetupColors.text(context))),
              ),
              if (logic.needsSafetySave)
                const AppPill(label: 'Panoya yazılmadı', family: AppFamilies.amber, icon: Icons.edit_note_rounded, maxLines: 1)
              else if (!logic.safetyDirty && devices)
                const AppPill(label: 'Panoda kayıtlı', family: AppFamilies.emerald, icon: Icons.check_rounded, maxLines: 1),
            ],
          ),
          if (unsupported)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: SetupInfoRow(
                icon: Icons.system_update_alt_rounded,
                color: SetupColors.error,
                text: "Bu pano yazılımı güvenlik modülünü desteklemiyor, v1.2.0'a güncelleyin. O zamana kadar bu kanalları "
                    '"Lamba / priz" olarak bırakın.',
              ),
            ),
          for (final issue in planIssues)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SetupInfoRow(
                icon: issue.blocking ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
                color: issue.blocking ? SetupColors.error : SetupColors.warn,
                text: issue.message,
              ),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              key: const Key('btn_save_safety'),
              style: accentButtonStyle(AppFamilies.emerald, minimumSize: const Size(48, 52)),
              onPressed: enabled ? () => logic.saveSafety() : null,
              icon: const Icon(Icons.save_alt_rounded, size: 18),
              label: const Text('Güvenlik Ayarlarını Panoya Yaz ve Test Et'),
            ),
          ),
          for (final r in logic.testResults)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SetupInfoRow(
                key: Key('safety_test_result_${r.zone}'),
                icon: r.failed ? Icons.error_rounded : (r.fbMs != null ? Icons.verified_rounded : Icons.visibility_outlined),
                color: r.failed ? SetupColors.error : (r.fbMs != null ? SetupColors.ok : SetupColors.info),
                text: r.message,
              ),
            ),
        ],
      ),
    );
  }
}
