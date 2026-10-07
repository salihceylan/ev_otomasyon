import 'package:flutter/material.dart';

import '../../models/automation_models.dart';
import '../theme/tokens.dart';

// =============================================================================
// Güvenlik arayüzünün ortak metin / simge / renk eşlemeleri (WP-A3; tasarım §5.3.3).
//
// Kural: renk TEK ipucu değildir. Her durum bir simge + Türkçe metinle birlikte verilir (renk körlüğü, ekran okuyucu,
// güneş altında soluk ekran). Renk ailesi yalnız vurgudur.
// =============================================================================

/// Alarm türünün başlığı (`water` -> "Su baskını").
String safetyKindTitle(String kind) {
  switch (kind) {
    case 'water':
      return 'Su baskını';
    case 'gas':
      return 'Gaz kaçağı';
    case 'smoke':
      return 'Duman algılandı';
    case 'door':
      return 'Kapı açıldı';
    case 'window':
      return 'Pencere açıldı';
    case 'motion':
      return 'Hareket algılandı';
    case 'intrusion':
      return 'Hırsız alarmı';
  }
  return 'Güvenlik alarmı';
}

/// Kritik alarm kartının davranış talimatı (Faz 2 F2.A.6); su ve diğer türlerde `null` (satır çizilmez).
String? safetyKindInstruction(String kind) {
  switch (kind) {
    case 'gas':
      return 'Ortamı havalandırın. Elektrik anahtarlarına ve prizlere dokunmayın, ateş yakmayın. Kokuyu hâlâ alıyorsanız '
          "evden çıkın ve 187'yi arayın.";
    case 'smoke':
      return "Evde biri varsa hemen dışarı çıkın ve 112'yi arayın. Pano su vanasını kapatmaz; havalandırma fanları durduruldu.";
  }
  return null;
}

/// Vana arızası (kapanmadı) satırı, türe göre (F2.A.5 push metinleriyle aynı yönlendirme).
String valveFaultText(String kind) => kind == 'gas'
    ? "Gaz vanası kapanmadı! Sayaçtaki ana gaz vanasını elle kapatın, ortamı havalandırın ve 187'yi arayın."
    : 'Vana kapanmadı! Ana vanayı elle kapatın.';

/// Gaz vanası satırının kalıcı açıklaması ("Vanayı Aç" düğmesinin yerine; F2.A.6).
const String kGasValveLocalOnlyNote =
    'Gaz vanası güvenlik gereği yalnız yerinde açılır: vananın yanındaki düğme ya da vananın kurma kolu.';

IconData safetyKindIcon(String kind) {
  switch (kind) {
    case 'water':
      return Icons.water_drop_rounded;
    case 'gas':
      return Icons.local_fire_department_rounded;
    case 'smoke':
      return Icons.smoke_free_rounded;
    case 'door':
      return Icons.door_front_door_outlined;
    case 'window':
      return Icons.window_outlined;
    case 'motion':
      return Icons.directions_walk_rounded;
    case 'intrusion':
      return Icons.local_police_outlined;
  }
  return Icons.shield_outlined;
}

/// Sensörün okunur adı: yapılandırma adı varsa o; yoksa kimlikten ("d3" -> "Giriş 3", "b1" -> "Kablosuz sensör 1").
String sensorLabel(SensorItem sensor) {
  if (sensor.name != sensor.id) return sensor.name;
  return sensorIdLabel(sensor.id);
}

/// Kimlikten okunur ad (adı bilinmeyen kaynak listesi için).
String sensorIdLabel(String id) {
  final n = id.length > 1 ? id.substring(1) : '';
  if (id.startsWith('d') && int.tryParse(n) != null) return 'Giriş $n';
  if (id.startsWith('b') && int.tryParse(n) != null) return 'Kablosuz sensör $n';
  return id;
}

/// Sensör durumu: metin + simge + aile ("Islak" / "Kuru" / "Bağlantı yok").
({String label, IconData icon, AccentFamily family}) sensorStatusOf(SensorItem sensor) {
  if (!sensor.ok) return (label: 'Bağlantı yok', icon: Icons.link_off_rounded, family: AppFamilies.slate);
  if (sensor.active) {
    final wetLabel = sensor.kind == 'water' ? 'Islak' : 'Algılandı';
    return (label: wetLabel, icon: Icons.warning_rounded, family: AppFamilies.rose);
  }
  final idleLabel = sensor.kind == 'water' ? 'Kuru' : 'Normal';
  return (label: idleLabel, icon: Icons.check_circle_outline_rounded, family: AppFamilies.emerald);
}

/// Vana konumunun metni (§5.3.3): `closed` geri bildirimle doğrulanmış kapalıdır, `cmd_closed` yalnız komut.
String valvePosLabel(ValvePos? pos) {
  switch (pos) {
    case ValvePos.closed:
      return 'Kapalı (doğrulandı)';
    case ValvePos.cmdClosed:
      return 'Kapatıldı (geri bildirim yok)';
    case ValvePos.closing:
      return 'Kapanıyor…';
    case ValvePos.open:
      return 'Açık (doğrulandı)';
    case ValvePos.cmdOpen:
      return 'Açıldı (geri bildirim yok)';
    case ValvePos.opening:
      return 'Açılıyor…';
    case ValvePos.unknown:
    case null:
      return 'Konum bilinmiyor';
  }
}

IconData valvePosIcon(ValvePos? pos) {
  switch (pos) {
    case ValvePos.closed:
    case ValvePos.cmdClosed:
      return Icons.lock_rounded;
    case ValvePos.closing:
    case ValvePos.opening:
      return Icons.sync_rounded;
    case ValvePos.open:
    case ValvePos.cmdOpen:
      return Icons.lock_open_rounded;
    case ValvePos.unknown:
    case null:
      return Icons.help_outline_rounded;
  }
}

/// Vana konumunun ailesi: kapalı = emerald (güvenli), açık = sky (normal akış), belirsiz = amber.
AccentFamily valvePosFamily(ValvePos? pos) {
  switch (pos) {
    case ValvePos.closed:
    case ValvePos.cmdClosed:
      return AppFamilies.emerald;
    case ValvePos.open:
    case ValvePos.cmdOpen:
      return AppFamilies.sky;
    case ValvePos.closing:
    case ValvePos.opening:
    case ValvePos.unknown:
    case null:
      return AppFamilies.amber;
  }
}

/// Eylemci türünün adı ve simgesi.
({String label, IconData icon}) actuatorKindOf(ActuatorItem a) {
  switch (a.kind) {
    case ActuatorKind.valve:
      return (label: a.isGasValve ? 'Gaz vanası' : 'Su vanası', icon: a.isGasValve ? Icons.gas_meter_outlined : Icons.water_damage_outlined);
    case ActuatorKind.siren:
      return (label: 'Siren', icon: Icons.campaign_rounded);
    case ActuatorKind.fan:
      return (label: 'Fan', icon: Icons.mode_fan_off_outlined);
    case ActuatorKind.generic:
      return (label: 'Güvenlik cihazı', icon: Icons.power_settings_new_rounded);
    case ActuatorKind.unknown:
      return (label: 'Bilinmeyen cihaz', icon: Icons.help_outline_rounded);
  }
}

/// Bir zaman damgasından şimdiye geçen süre ("az önce", "12 dk önce", "3 sa önce", "2 gün önce").
String elapsedLabel(DateTime since, DateTime now) {
  final diff = now.difference(since);
  if (diff.isNegative || diff.inMinutes < 1) return 'az önce';
  if (diff.inHours < 1) return '${diff.inMinutes} dk önce';
  if (diff.inDays < 1) return '${diff.inHours} sa önce';
  return '${diff.inDays} gün önce';
}

/// Panodan gelen epoch saniyesi -> yerel saat (`time_ok` değilse pano `since` yazmaz; o zaman `null`).
DateTime? epochToDate(int? epoch) =>
    (epoch == null || epoch <= 0) ? null : DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);

/// LAN olay türünün metni (`GET /api/events`; §3.4 tablo).
String deviceEventLabel(DeviceEventRecord e) {
  switch (e.type) {
    case 'alarm_raised':
      return safetyKindTitle(e.kind ?? '');
    case 'alarm_silenced':
      return 'Alarm susturuldu';
    case 'alarm_cleared':
      return 'Alarm kalktı';
    case 'valve_fault':
      return 'Vana kapanmadı (arıza)';
    case 'valve_fault_cleared':
      return 'Vana arızası düzeldi';
    case 'test_result':
      return 'Bölge testi';
    case 'sensor_fault':
      return 'Sensör yanıt vermiyor';
    case 'sensor_fault_cleared':
      return 'Sensör yeniden yanıt veriyor';
    case 'actuator_fault':
      return 'Güvenlik cihazına ulaşılamıyor';
    case 'safe_mode':
      return 'Pano güvenli kipe girdi';
    case 'nvs_fail':
      return 'Alarm kaydı panoya yazılamadı';
    case 'policy_changed':
      return 'Güvenlik tepkisi ayarı değişti';
    case 'actuator_changed':
      return 'Güvenlik cihazı kullanıldı';
    case 'cfg_conflict':
      return 'Ayar çakışması';
    case 'intrusion_alarm':
      return 'Hırsız alarmı';
    case 'intrusion_cleared':
      return 'Hırsız alarmı çözüldü';
    case 'arm_changed':
      return 'Alarm kipi değişti';
  }
  return e.type;
}

/// Sunucu alarm kaydı durumunun metni ve ailesi (`latched|fault|silenced|cleared|lost`).
({String label, AccentFamily family, IconData icon}) alarmRecordStatusOf(AlarmRecord r) {
  switch (r.status) {
    case 'cleared':
      return (label: 'Kapandı', family: AppFamilies.emerald, icon: Icons.check_circle_outline_rounded);
    case 'lost':
      return (label: 'Doğrulanamadı', family: AppFamilies.amber, icon: Icons.help_outline_rounded);
    case 'silenced':
      return (label: 'Susturuldu', family: AppFamilies.amber, icon: Icons.volume_off_rounded);
    case 'fault':
      return (label: 'Vana arızası', family: AppFamilies.rose, icon: Icons.error_rounded);
  }
  return (label: 'Sürüyor', family: AppFamilies.rose, icon: Icons.warning_rounded);
}
