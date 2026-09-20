import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/automation_models.dart';
import 'automation_api_service.dart';

enum ConnectionStateEnum { connecting, connected, offline }

class AutomationState extends ChangeNotifier {
  final AutomationApiService api = AutomationApiService();
  
  DeviceStatus? _status;
  ConnectionStateEnum _connState = ConnectionStateEnum.connecting;
  String _host = '192.168.4.1';
  Timer? _pollTimer;
  bool _isDisposed = false;

  DeviceStatus? get status => _status;
  ConnectionStateEnum get connState => _connState;
  String get host => _host;
  bool get isConnected => _connState == ConnectionStateEnum.connected;

  AutomationState() {
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _host = prefs.getString('saved_esp_host') ?? '192.168.4.1';
    api.updateHost(_host);
    await refresh();
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!_isDisposed) {
        refresh(silent: true);
      }
    });
  }

  Future<void> setHost(String newHost) async {
    _host = newHost.trim();
    api.updateHost(_host);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_esp_host', _host);
    _connState = ConnectionStateEnum.connecting;
    notifyListeners();
    await refresh();
  }

  Future<void> refresh({bool silent = false}) async {
    try {
      final st = await api.fetchStatus();
      _status = st;
      _connState = ConnectionStateEnum.connected;
      notifyListeners();
    } catch (e) {
      if (!silent || _status == null) {
        _connState = ConnectionStateEnum.offline;
        notifyListeners();
      }
    }
  }

  Future<void> toggleRelay(int channel) async {
    await api.toggleRelay(channel);
    await refresh(silent: true);
  }

  Future<void> triggerImpulse(int channel) async {
    await api.triggerImpulse(channel);
    await refresh(silent: true);
  }

  Future<void> cmdShutter(int pairIndex, String action) async {
    await api.cmdShutter(pairIndex, action);
    await refresh(silent: true);
  }

  Future<void> cmdAll(String command) async {
    await api.cmdAll(command);
    await refresh(silent: true);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }
}
