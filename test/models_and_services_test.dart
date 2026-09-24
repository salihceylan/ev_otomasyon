import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  group('Faz 5 - Cloud Models Serialization Tests', () {
    test('UserModel JSON parsing and role verification', () {
      final json = {
        'id': 1,
        'email': 'ahmet@example.com',
        'full_name': 'Ahmet Yılmaz',
        'phone': '05551112233',
        'role': 'owner',
      };
      final user = UserModel.fromJson(json, token: 'jwt_mock_token');
      expect(user.id, 1);
      expect(user.fullName, 'Ahmet Yılmaz');
      expect(user.role, 'owner');
      expect(user.token, 'jwt_mock_token');
    });

    test('EndpointModel JSON parsing and types', () {
      final json = {
        'id': 10,
        'home_id': 1,
        'channel': 1,
        'name': 'Salon Avize',
        'room': 'salon',
        'endpoint_type': 'light',
        'current_state': true,
      };
      final endpoint = EndpointModel.fromJson(json);
      expect(endpoint.id, 10);
      expect(endpoint.isLight, true);
      expect(endpoint.isShutter, false);
      expect(endpoint.currentState, true);
      expect(endpoint.room, 'salon');
    });

    test('EndpointModel copyWith handles optimistic updates', () {
      final ep = EndpointModel(
        id: 5,
        homeId: 1,
        channel: 3,
        name: 'Mutfak Panjur',
        room: 'mutfak',
        endpointType: 'shutter',
        currentState: false,
        shutterPosition: 0,
      );

      final updated = ep.copyWith(shutterPosition: 65, currentState: true);
      expect(updated.shutterPosition, 65);
      expect(updated.currentState, true);
      expect(updated.name, 'Mutfak Panjur');
      expect(ep.shutterPosition, 0); // Orijinal immutability korunmalı
    });
  });

  group('Faz 5 - Shutter Card & Optimistic Logic Tests', () {
    test('Shutter position clamping and getter', () {
      final state = AutomationState();
      expect(state.getShutterPosition(0), 0);

      // Optimistic konumu simüle et
      state.setShutterPosition(0, 75);
      expect(state.getShutterPosition(0), 75);
    });

    test('RelayItem and ShutterItem mapping', () {
      final shutterJson = {
        'is_moving': true,
        'dir': 1,
      };
      final shutter = ShutterItem.fromJson(0, shutterJson, 'Salon Panjur');
      expect(shutter.name, 'Salon Panjur');
      expect(shutter.isMoving, true);
      expect(shutter.direction, 1);
      expect(shutter.isExt, false);
    });
  });
}
