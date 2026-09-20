import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/automation_models.dart';

class AutomationApiService {
  String baseUrl;

  AutomationApiService({this.baseUrl = 'http://192.168.4.1'});

  void updateHost(String newHost) {
    if (!newHost.startsWith('http://') && !newHost.startsWith('https://')) {
      baseUrl = 'http://$newHost';
    } else {
      baseUrl = newHost;
    }
  }

  Future<DeviceStatus> fetchStatus() async {
    final uri = Uri.parse('$baseUrl/api/status');
    final res = await http.get(uri).timeout(const Duration(seconds: 4));
    if (res.statusCode == 200) {
      final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return DeviceStatus.fromJson(json);
    }
    throw Exception('Durum alınamadı (Kod: ${res.statusCode})');
  }

  Future<bool> toggleRelay(int channel) async {
    final uri = Uri.parse('$baseUrl/api/relay?ch=$channel&cmd=toggle');
    final res = await http.post(uri).timeout(const Duration(seconds: 4));
    return res.statusCode == 200;
  }

  Future<bool> triggerImpulse(int channel) async {
    final uri = Uri.parse('$baseUrl/api/relay?ch=$channel&state=1');
    final res = await http.post(uri).timeout(const Duration(seconds: 4));
    return res.statusCode == 200;
  }

  Future<bool> cmdShutter(int pairIndex, String action) async {
    // action: 'up', 'down', 'stop'
    final uri = Uri.parse('$baseUrl/api/relay?pair=$pairIndex&cmd=$action');
    final res = await http.post(uri).timeout(const Duration(seconds: 4));
    return res.statusCode == 200;
  }

  Future<bool> cmdAll(String command) async {
    // command: 'lightsoff', 'shuttersdown', 'shuttersup', 'shuttersstop'
    final uri = Uri.parse('$baseUrl/api/all?cmd=$command');
    final res = await http.post(uri).timeout(const Duration(seconds: 4));
    return res.statusCode == 200;
  }

  Future<Map<String, dynamic>> fetchConfig() async {
    final uri = Uri.parse('$baseUrl/api/config');
    final res = await http.get(uri).timeout(const Duration(seconds: 5));
    if (res.statusCode == 200) {
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    }
    throw Exception('Yapılandırma alınamadı');
  }

  Future<bool> saveConfig(Map<String, dynamic> config) async {
    final uri = Uri.parse('$baseUrl/api/config');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(config),
    ).timeout(const Duration(seconds: 5));
    return res.statusCode == 200;
  }
}
