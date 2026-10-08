import 'package:flutter/foundation.dart';

import 'json_utils.dart';

/// Kurulum şablonu modelleri (plan `2026-10-08-site-sablon-kurulum.md` Faz 4; sözleşme
/// `docs/contracts/template/README.md` ve CONTRACTS §3e).
///
/// Şablon gövdesi (`ahbu-template/1`) istemcide **yorumlanmaz ve değiştirilmez**: sunucudan geldiği gibi
/// ([InstallTemplate.body]) panoya gönderilir. Doğrulamanın son sözü panodadır (firmware); burada yalnız önizleme
/// için sayılar çıkarılır ([TemplatePreview]).

/// Panoda yüklü şablon (`/api/status` ve MQTT state `tpl: {id, ver}`; yalnız şablon yüklüyse vardır).
@immutable
class TemplateRef {
  const TemplateRef({required this.id, required this.version});

  final String id;
  final int version;

  /// `{"id": "...", "ver": N}`; alan yok / bozuksa `null` (eski firmware).
  static TemplateRef? tryParse(Object? raw) {
    final map = asMap(raw);
    if (map == null) return null;
    final id = asNonEmptyString(map['id']);
    if (id == null) return null;
    return TemplateRef(id: id, version: asInt(map['ver'] ?? map['version']) ?? 0);
  }

  @override
  bool operator ==(Object other) => other is TemplateRef && other.id == id && other.version == version;

  @override
  int get hashCode => Object.hash(id, version);

  @override
  String toString() => 'TemplateRef($id v$version)';
}

/// `GET /api/template` (KEYED) yanıtı: `{template_id|null, version, label, applied_at_uptime_s}`.
@immutable
class BoardTemplateInfo {
  const BoardTemplateInfo({this.templateId, this.version = 0, this.label = '', this.appliedAtUptimeS});

  final String? templateId;
  final int version;
  final String label;
  final int? appliedAtUptimeS;

  bool get hasTemplate => templateId != null;

  factory BoardTemplateInfo.fromJson(Map<String, dynamic> json) => BoardTemplateInfo(
        templateId: asNonEmptyString(json['template_id']),
        version: asInt(json['version']) ?? 0,
        label: asString(json['label']) ?? '',
        appliedAtUptimeS: asInt(json['applied_at_uptime_s']),
      );
}

/// Site (CONTRACTS §3e `GET /sites`); sihirbaz yalnız seçim için ad ve konumu kullanır.
@immutable
class InstallSite {
  const InstallSite({required this.id, required this.name, this.city = '', this.district = '', this.flatCount});

  final String id;
  final String name;
  final String city;
  final String district;
  final int? flatCount;

  /// "İlçe / İl" (boş parçalar atlanır).
  String get place => <String>[district, city].where((s) => s.trim().isNotEmpty).join(' / ');

  factory InstallSite.fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id']);
    if (id == null) throw const FormatException('Site: id yok');
    return InstallSite(
      id: id,
      name: asNonEmptyString(json['name']) ?? 'Adsız site',
      city: asString(json['city']) ?? '',
      district: asString(json['district']) ?? '',
      flatCount: asInt(json['flat_count']),
    );
  }
}

/// Şablon liste satırı (`GET /templates`): `id, site_id, name, flat_type, current_version, updated_at, created_by`.
@immutable
class InstallTemplateSummary {
  const InstallTemplateSummary({
    required this.id,
    required this.name,
    this.siteId,
    this.flatType = '',
    this.currentVersion = 0,
    this.updatedAt,
  });

  final String id;

  /// `null` = genel/standart şablon.
  final String? siteId;
  final String name;
  final String flatType;
  final int currentVersion;
  final DateTime? updatedAt;

  bool get isGlobal => siteId == null;

  factory InstallTemplateSummary.fromJson(Map<String, dynamic> json) {
    final id = asNonEmptyString(json['id']);
    if (id == null) throw const FormatException('Şablon: id yok');
    return InstallTemplateSummary(
      id: id,
      siteId: asNonEmptyString(json['site_id']),
      name: asNonEmptyString(json['name']) ?? 'Adsız şablon',
      flatType: asString(json['flat_type']) ?? '',
      currentVersion: asInt(json['current_version']) ?? 0,
      updatedAt: DateTime.tryParse(asString(json['updated_at']) ?? ''),
    );
  }
}

/// Şablonun güncel sürümü (`GET /templates/:id` -> `{..., body}`). [body] ham `ahbu-template/1` gövdesidir.
@immutable
class InstallTemplate {
  const InstallTemplate({required this.summary, required this.version, required this.body});

  final InstallTemplateSummary summary;

  /// Gövdenin sürümü (`body.meta.version`; yoksa `current_version`).
  final int version;
  final Map<String, dynamic> body;

  String get id => summary.id;
  String get name => summary.name;

  /// Panoya yazılacak şablon kimliği (`body.meta.template_id`; yoksa satır kimliği).
  String get templateId => asNonEmptyString(asMap(body['meta'])?['template_id']) ?? summary.id;

  TemplatePreview get preview => TemplatePreview.of(body);

  factory InstallTemplate.fromJson(Map<String, dynamic> json) {
    final body = asMap(json['body']);
    if (body == null) throw const FormatException('Şablon: body yok');
    final summary = InstallTemplateSummary.fromJson(json);
    final metaVersion = asInt(asMap(body['meta'])?['version']);
    return InstallTemplate(
      summary: summary,
      version: metaVersion ?? asInt(json['version']) ?? summary.currentVersion,
      body: body,
    );
  }
}

/// Önizleme sayıları (şablon gövdesinden; doğrulama DEĞİL).
@immutable
class TemplatePreview {
  const TemplatePreview({
    this.relayCount = 0,
    this.lights = 0,
    this.impulses = 0,
    this.shutters = 0,
    this.inputs = 0,
    this.buttons = 0,
    this.sensors = 0,
    this.actuators = 0,
    this.dimmers = 0,
    this.extChannels = 0,
    this.flatType = '',
  });

  final int relayCount;
  final int lights;
  final int impulses;

  /// Panjur sayısı (yukarı röleleri).
  final int shutters;

  /// Toplam giriş (DI) sayısı.
  final int inputs;

  /// Bir röleye bağlı (duvar butonu) girişler.
  final int buttons;
  final int sensors;
  final int actuators;
  final int dimmers;
  final int extChannels;
  final String flatType;

  bool get hasSafety => sensors > 0 || actuators > 0;

  factory TemplatePreview.of(Map<String, dynamic> body) {
    var lights = 0;
    var impulses = 0;
    var shutters = 0;
    final relays = asList(body['relays']) ?? const <dynamic>[];
    for (final raw in relays) {
      switch (asString(asMap(raw)?['type'])) {
        case 'light':
          lights++;
        case 'impulse':
          impulses++;
        case 'shutter_up':
          shutters++;
      }
    }
    final dis = asList(body['dis']) ?? const <dynamic>[];
    var buttons = 0;
    for (final raw in dis) {
      if ((asInt(asMap(raw)?['target_relay']) ?? 0) > 0) buttons++;
    }
    final safety = asMap(body['safety']);
    var dimmers = 0;
    for (final raw in asList(safety?['lights']) ?? const <dynamic>[]) {
      final dim = asMap(raw)?['dimmable'];
      if (dim == true || asInt(dim) == 1) dimmers++;
    }
    final ext = asMap(body['ext_module']);
    return TemplatePreview(
      relayCount: relays.length,
      lights: lights,
      impulses: impulses,
      shutters: shutters,
      inputs: dis.length,
      buttons: buttons,
      sensors: (asList(safety?['sensors']) ?? const <dynamic>[]).length,
      actuators: (asList(safety?['actuators']) ?? const <dynamic>[]).length,
      dimmers: dimmers,
      extChannels: asBool(ext?['enabled']) == true ? (asInt(ext?['channels']) ?? 0) : 0,
      flatType: asString(asMap(body['meta'])?['flat_type']) ?? '',
    );
  }
}

/// Şablon uygulama sonucu (`POST /api/template/apply` 200): `{ok, template_id, version, rev}`.
@immutable
class TemplateApplyResult {
  const TemplateApplyResult({this.templateId, this.version = 0, this.rev, this.pending = false});

  final String? templateId;
  final int version;
  final int? rev;

  /// 202 `{"pending":true}`: pano yazmayı sürdürüyor; sonuç `GET /api/template` ile denetlenir.
  final bool pending;

  factory TemplateApplyResult.fromJson(Map<String, dynamic> json) => TemplateApplyResult(
        templateId: asNonEmptyString(json['template_id']),
        version: asInt(json['version']) ?? 0,
        rev: asInt(json['rev']),
        pending: asBool(json['pending']) == true,
      );
}
